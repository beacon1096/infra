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

### Reuse the Forgejo builders as Nix remote builders

The three Forgejo builders are viable capacity because maintenance is rotated
and a majority remains online. Nix itself schedules derivations across multiple
remote builders according to platform, required features, `maxJobs`,
`speedFactor`, and load. A Multica workspace can therefore use its local Nix
daemon as the dispatcher and set local `max-jobs = 0` to prevent fallback to
the unsandboxed workspace.

The same separation can apply to Forgejo jobs. The runner remains the CI
control session: it checks out the exact commit, starts `nix build`, streams
logs, propagates cancellation, and reports the protected status. It does not
need to select or execute derivations itself. Its Nix client can submit them to
the same remote-builder pool with local builds disabled, leaving placement and
execution to Nix. The current builders instead use `distributedBuilds = false`
and build locally on whichever node Forgejo selected, so this is an explicit
future architecture change rather than a description of current behavior.

There are two materially different Nix layouts:

- With ordinary distributed builders, the runner or workspace daemon remains
  the primary store and scheduler. It sends derivations away but receives
  outputs into its own store. Local store growth, garbage collection, and some
  substituter configuration therefore remain on every client.
- With a dedicated remote store/dispatcher, CI and agents address that store
  for the whole operation, and its daemon may distribute builds to the worker
  pool. Store retention, garbage collection, optimisation, read-side binary
  cache configuration, and build admission can then be centralized. This is
  the intended end state if thin Forgejo runners are the goal.

The remote-store layout needs explicit tests for log retrieval, cancellation,
result-path handling, failed-build diagnostics, and OCI outputs. Workflows that
consume a result locally may still need an explicit copy or a remote execution
step.

Do not give the shared dispatcher an ambient Attic write credential merely to
remove workflow steps. Multica agents can submit builds to the same service, so
automatic upload would let agent-requested outputs enter the trusted cache.
Keep Attic reads and public verification keys in the builder configuration, but
retain cache publication as a Forgejo-authorized operation with a scoped write
credential. The repetitive login, path validation, and push logic can move to
a reviewed helper without moving that trust decision into the builder.

This is scheduling, but it is not one global queue. Every workspace has an
independent Nix daemon, and those daemons do not know the Forgejo Actions queue
or its runner drain state. If both systems share the machines, builder-side
admission must be the common boundary: entering maintenance drains the Forgejo
runner and rejects new Nix SSH sessions, waits for Actions jobs and leased Nix
sessions to finish, and only then changes the host. The remaining machines stay
available to both schedulers.

Before relying on this behavior, test that a new build is assigned elsewhere
when one endpoint is drained or unreachable, and test a connection loss both
before and during a build. Do not assume that every transport failure has the
same retry behavior. Apply builder-side concurrency and resource limits so
independent Nix clients cannot starve Forgejo jobs.

Estimated implementation cost is medium: roughly one to two engineering days
for restricted identities and client configuration, and another two to three
days for shared admission, drain integration, resource limits, and failover
tests. This does not require a custom scheduling service.

### Add a dedicated remote builder

A separate NixOS VM is the cleaner interactive-build design. It should enable
the Nix sandbox, expose only the restricted Nix SSH protocol, carry no Forgejo,
Multica, deployment, SOPS, or Attic-write credentials, and accept traffic only
from the coding-agent namespace or identity. Set client `max-jobs = 0` so PR
derivations cannot fall back to the unsandboxed local store. Add concurrency,
disk, build-time, and garbage-collection limits before enabling agent access.

Cleanup must be coordinated with build sessions rather than assigned a fixed
maintenance window:

1. The forced-command SSH wrapper holds a shared lease for the complete Nix
   protocol session and records when the final session ends.
2. A cleanup controller evaluates an idle grace period, a minimum interval
   between cleanups, and disk high/critical watermarks. A systemd timer may
   evaluate these predicates, but elapsed wall-clock time alone must not start
   cleanup.
3. Before cleanup it enters drain mode, rejects or queues new sessions, waits
   for all shared leases to end, and acquires an exclusive maintenance lease.
   Acquiring the exclusive lease closes the race between the idle check and a
   new connection.
4. It runs bounded garbage collection and store optimisation, records the
   result and space recovered, then clears drain mode even after failure. A
   pending non-critical cleanup can yield to a newly arriving agent request.

Nix temporary roots protect active realizations from garbage collection, but
they do not address admission races, disk and I/O contention, or service
availability. The external lease and drain protocol is therefore still
required. Emergency cleanup at the critical watermark should stop accepting
new work, but must not kill an active build unless a separately documented
resource or execution timeout has already expired.

The existing Harvester VM and NixOS module patterns can be reused, but this
still adds another machine lifecycle and capacity pool. Estimated
implementation cost: medium, roughly one to two engineering days for the
restricted builder and two to three days for admission, lease, cleanup,
observability, and failure tests. Strict availability during host maintenance
would require at least two builders and the same tested drain and admission
behavior. A dedicated pool avoids competing with Actions, but Nix can still
provide its derivation scheduling.

## Decision

Use Forgejo CI as the authoritative full-build environment now. A Nix remote
builder path may reuse the majority-online runner pool for exploratory agent
builds after shared admission and failover are tested; its result does not
replace the protected exact-commit CI status. Move to a dedicated builder pool
only if contention with Actions or stronger availability requirements justify
the extra capacity. Do not weaken the merge gate because a Coder-local
realization is unavailable.
