# Agent Nix build trust boundary

Coder coding-agent workspaces use a minimal single-user Nix installation. The
image intentionally sets `sandbox = false` and leaves `build-users-group`
empty because an ordinary Kubernetes Pod does not provide the mount and user
namespace capabilities required by Nix's Linux sandbox. This is sufficient for
Home Manager activation, evaluation, and trusted interactive work. It is not a
security boundary for derivations supplied by a pull request.

Without the Nix sandbox, a builder can observe more of the workspace
filesystem, use the Pod's network, and affect writable runtime state. The
workspace currently runs as root inside its container, so container isolation,
not Nix, is the remaining boundary. `/homeless-shelter` must remain absent:
Nix uses it as a deliberately invalid build HOME, and refuses an unsandboxed
build if the path exists because it would make host state visible to builders.

## Short-term policy

Coding agents may run:

- `nix flake show`, `nix eval`, parsing, and other evaluation-only checks;
- focused tests that do not realize PR-controlled Nix derivations;
- ordinary language, schema, formatting, and shell validation.

They must not locally realize complete NixOS or nix-darwin closures from a PR.
The Forgejo required status for the exact head SHA supplies full-build evidence.
If required CI is missing or inconclusive, the agent returns `human_required`
instead of substituting an unsandboxed local build.

The image trusts only caches that work without a workspace secret. It includes
the official `cache.nixos.org` signing key and removes the private Attic cache
from its substituters. A private cache must not be advertised until a scoped,
read-only credential can be injected without exposing broader infrastructure
authority to PR-controlled code.

The Coder template pins the coding-agent image by digest. After changing this
configuration, wait for `build-and-push-coding-agent-oci` to publish the image,
resolve the new registry digest, update the template pin, and recreate or
restart the affected workspace. Publishing `latest` alone does not change an
existing workspace or its pinned template revision.

## Medium-term options

### Continue using Forgejo CI

This is the default and lowest-cost option. The existing protected status is
already bound to the exact commit, and the merge gate fails closed while CI is
pending or failed. No new credential or scheduler is required. The trade-off
is that an agent cannot request exploratory builds beyond the workflow matrix.

Estimated implementation cost: configuration and runbook changes only; no new
service. Add workflow-dispatch inputs later if agents need a bounded selection
of extra build targets.

### Reuse the three Forgejo builders

This requires a restricted `nixremote` SSH identity, a key available to Coder,
network access, client `buildMachines` configuration, and builder-side
sandbox verification. A stolen key should permit only Nix store/build protocol
operations, never a shell or deployment action.

This option is operationally awkward. Remote jobs would currently bypass the
runner drain marker, compete with Actions jobs, and evade the maintenance
coordination documented in `runner-maintenance.md`. It therefore also needs a
shared admission/drain mechanism, resource limits, disk-pressure handling, and
audit coverage.

Estimated implementation cost: medium to high, roughly two to four engineering
days plus load testing. Do not enable it by adding an SSH key alone.

### Add a dedicated remote builder

A separate NixOS VM is the cleaner interactive-build design. It should enable
the Nix sandbox, expose only the restricted Nix SSH protocol, carry no Forgejo,
Multica, deployment, SOPS, or Attic-write credentials, and accept traffic only
from the coding-agent namespace or identity. Set client `max-jobs = 0` so PR
derivations cannot fall back to the unsandboxed local store. Add concurrency,
disk, build-time, and garbage-collection limits before enabling agent access.

The existing Harvester VM and NixOS module patterns can be reused, but this
still adds another machine lifecycle and capacity pool. Estimated
implementation cost: medium, roughly one to three engineering days for a
prototype and another day for failure, isolation, and maintenance tests.

## Decision

Use Forgejo CI as the authoritative full-build environment now. Revisit a
dedicated remote builder only when review latency or missing ad-hoc build
targets becomes a recurring problem. Do not weaken the merge gate because a
Coder-local realization is unavailable.
