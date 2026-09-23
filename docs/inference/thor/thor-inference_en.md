# Thor inference through LiteLLM

Performance tuning is frozen at the validated Qwen3.8-27B DFlash2 block16 configuration. Stability and infrastructure handover take priority.

## Agent connection

- Tailnet base URL: `http://litellm.tail5d550.ts.net:4000/v1`.
- Model: `thor/qwen3.8-27b`.
- Use a LiteLLM virtual key authorized for this model. Never distribute the LiteLLM master key.
- The existing Nix agent credential at `/run/secrets/personal/beacoworks-models/api_key` was verified successfully. Its legacy `/v1/models` listing returns `all-team-models`; configure the model ID explicitly instead of relying on discovery.
- Context is **262144 tokens total**, shared by prompt, tool schemas, reasoning and output. Default output budget is 4096; advertised output budget is 8192. For daily use, keep input at or below **253952 tokens** to reserve 8192 for output. These are client budgets, not an independent hard output cap; the scheduler also reserves a few boundary positions. Up to four generations run at a time, sharing a 270336-token resident KV pool; additional or capacity-constrained requests queue. This is not four simultaneous full 256K contexts.
- Model request and stream timeouts are 2400 seconds, with automatic model retries disabled. Clients also need a matching HTTP idle timeout. A near-256K cold input took 25 minutes before first text; streaming cannot remove that delay. Long cold prefill and a queue of requests can still exceed this deadline. Four roughly 60K inputs plus 4K outputs fit the pool arithmetically; this is a planning budget, not a completed 4×60K qualification.
- The HTTP endpoint is carried over encrypted Tailscale transport and still requires LiteLLM authentication. It serves the existing LiteLLM instance and model database.
- The existing `https://models.beaco.works/v1` remains available, but on 2026-09-13 Cloudflare rejected Python/SDK user agents (403/1010), while curl worked. Prefer the Tailnet endpoint until the public API path's browser checks are corrected.

## Pi client settings

For Pi 0.85.1, merge into `~/.pi/agent/settings.json` or the project's
`.pi/settings.json` (project values override global settings):

```json
{
  "httpIdleTimeoutMs": 2400000,
  "retry": {
    "enabled": false,
    "provider": {
      "timeoutMs": 2400000,
      "maxRetries": 0
    }
  }
}
```

`httpIdleTimeoutMs` is top-level and controls undici headers/body idle
limits; changing only the provider timeout leaves the default 300000 ms
idle limit. Set provider `baseUrl` to the Tailnet URL above, model ID to
`thor/qwen3.8-27b`, `contextWindow` to 262144 and `maxTokens` to 8192.
Request 4096 output tokens for ordinary turns; reasoning consumes the same
output budget. Preserve the model's normal thinking behavior for coding.
The earlier capacity probes disabled thinking only to isolate retrieval.
Do not route these long requests through the public Cloudflare endpoint:
its own deadline is independent of the LiteLLM and Pi settings.

LiteLLM 1.90.0 uses model `stream_timeout` before `timeout` and honors
`num_retries: 0`. The shared gateway enables
`general_settings.cancel_on_disconnect: true`; this applies to all model
routes and cancels work when the client disconnects while awaiting the
initial upstream response. Client cancellation was tested through to Thor.
The setting is declared in public infra
`wanxiang/kubernetes/apps/ai/litellm/app/configmap.yaml`; restart the
Deployment after changing this subPath-mounted configuration. Thor also
backports an SGLang lifecycle fix so a dispatched request is aborted rather
than left running after the client disappears; see
[Thor SGLang client-disconnect abort fix](thor-sglang-abort-fix.md).

## Ownership and deployment

`hosts/personal/fixed/thor/inference.nix` declares the host service. Its `inference/` directory contains minimal patches and their source/result SHA256 checks. Startup extracts originals from the pinned local Docker image and verifies both hashes. Model snapshots and image must already exist under `/var/lib/thor-inference`; rebuilding Nix does not download these large prerequisites. The image is pinned by local image ID, not a registry digest; preserve it when cleaning Docker images.

`terraform/litellm-wanxiang/` owns the model row, the `ai/thor-inference` egress Service, and the `ai/litellm-tailscale` ingress Service. The existing Tailscale Operator owns their proxy pods. The explicit `tag:talos-ii-operator` matches working fleet Services; the operator's default `tag:talos-ii-svc` was rejected by its OAuth permissions. Do not overwrite the operator-generated `externalName`.

Traffic: agent → LiteLLM → `thor-inference.ai.svc.cluster.local:8889` → Tailscale → Thor `100.88.133.23:8889` → loopback SGLang `127.0.0.1:8888`. Raw inference is accessible only through the Tailnet listener; the model server has no separate API key. Tailnet ACLs therefore remain part of the backend access boundary.

Apply model/network changes using `KUBECONFIG=<cluster-config> terraform/litellm-wanxiang/run.sh plan` and `apply` with `kubectl` and `tofu` available. The script obtains the management credential without printing it. Terraform state stays in the existing Kubernetes backend.

The management URL is an ephemeral Terraform variable because each invocation may use a different local port-forward port. A saved plan can therefore be applied through a fresh forwarding session.

The same stack owns the `astrbot` virtual key. Its `ephemeral_body` carries a `_terraform_body_revision` alongside the key value: LiteLLM addresses a virtual key by the key value itself in `/key/update`, while provider v0.25.2 only merge-patches `ephemeral_body` into an update request when the ephemeral value itself changed. An update driven by `body` alone would therefore drop the required `key` field and LiteLLM would answer HTTP 422 (`body.key: Field required`). The revision is a hash of the managed body, so any body change re-triggers the merge patch; LiteLLM ignores the extra field. Remove the revision only once the provider merges `ephemeral_body` on every write.

## Recovery

- `systemctl status thor-inference thor-inference-memwatch thor-inference-proxy.socket thor-inference-healthcheck.timer`
- `journalctl -u thor-inference -u thor-inference-memwatch -u thor-inference-healthcheck`
- `curl --fail http://127.0.0.1:8888/health_generate` on Thor checks generation health.
- Unexpected process exit restarts after 30 seconds, limited to three starts per 15 minutes. Manual stop stays stopped.
- A separate timer checks generation health after a 180-second grace period; three consecutive failures trigger a restart. It checks the service invocation before acting so a stale probe cannot resurrect a manually stopped service.
- Memory guard samples every second. Five consecutive samples below 12 GiB Available, or below 3 GiB Free while Available is below 18 GiB, stop inference and create `/run/thor-inference/memory-stop`. This deliberately prevents restart loops.
- After resolving memory pressure, remove that lock and run `systemctl reset-failed thor-inference; systemctl start thor-inference`. Restarting the watchdog does not clear the lock. A reboot clears `/run`, but the startup memory gate still applies.
- The stopped experimental `thor-27b-dflash16` container is retained for rollback. Stop the managed service before starting it, and restore its old watchdog; both containers bind the same loopback port.

The service preserves INT8 draft head, unquantized target BF16 head, and DFlash block16. The retained GDN patch applies only to block8 and is inactive at block16 (BV32 is used). OpenAI tool parsing uses `qwen3_coder`, matching the checkpoint's XML tool template; reasoning parsing remains `qwen3`.

The operator egress design follows [Tailscale's documentation](https://tailscale.com/docs/kubernetes-operator/egress). Cloudflare documents [1010 as a browser-signature check](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/); this is separate from LiteLLM key authorization.

## Validation — 2026-09-13

Built the exact private Thor system in an isolated checkout, excluding concurrent network work. `nix flake show --all-systems`, `nix build .#nixosConfigurations.thor.config.system.build.toplevel`, shell syntax/ShellCheck, patch replay SHA256 checks, and independent review passed. Dry activation showed only the expected firewall reload; the service switch completed successfully. Boot enablement was verified; no machine reboot was performed.

Through the Tailnet LiteLLM endpoint with the existing agent key:

| Check | Result |
| --- | --- |
| Model-list endpoint | HTTP 200; legacy wildcard listing noted above |
| Missing API key | HTTP 401 |
| Chat completion | Expected text, HTTP 200 |
| SSE chat completion | Expected assembled text, HTTP 200 |
| JSON object output | Parsed expected status/value |
| Tool call | Correct function and integer arguments |
| Tool result continuation | Correct final answer |
| SSE tool call | Reassembled valid function name and argument JSON |
| Unexpected container exit | systemd restarted it once; generation health and subsequent LiteLLM request passed |

The final eight API checks were repeated successfully after recovery and the final model metadata update. `supports_function_calling=true` is based on these checks. Terraform `fmt -check`, `validate`, and a full `plan -detailed-exitcode` passed; the plan reported no changes. The provider treats the backend's dummy API key as write-only because LiteLLM masks it in reads.

Raw local evidence remains outside Git at `/home/beacon/.cache/codex/thor-api/` (`smoke-results.json`, `recovery-result.json`, build and Terraform logs). No new client secret was created. This is a single Thor backend; model reloads temporarily interrupt service, and infrastructure redundancy remains future work.

## Incident — 2026-09-14: offline after booting an old generation

Thor was reachable over its reserved LAN addresses (`172.16.20.71` wired, `.81` wireless), but Tailscale reported it offline for about four hours and LiteLLM requests timed out. The old DHCP addresses `.201` and `.237` no longer responded.

`/run/booted-system` and `/run/current-system` pointed to generation 6, which had neither `tailscaled.service` nor `thor-inference.service`. The system profile still pointed to the deployed generation 8. `/boot/loader/loader.conf` correctly selected generation 8, but the EFI `LoaderEntryDefault` variable explicitly selected `nixos-generation-6.conf`, overriding the file. The evidence does not establish who or what originally set that EFI override.

Recovery: `bootctl set-default ""` cleared the persistent EFI override, allowing the declarative loader default to apply; `/nix/var/nix/profiles/system/bin/switch-to-configuration switch` restored the existing generation 8 services. `bootctl list` then marked generation 8 as default. Tailscale reconnected with the same `100.88.133.23` identity and direct LAN endpoint. No authentication reset or new Tailscale registration was needed. No additional reboot was performed; boot selection was verified through bootctl, while services were recovered in place.

When checking reboot persistence, verify both the system profile and `bootctl status`/`bootctl list`; enabled units in the currently activated system do not prove that firmware will select that generation next time. Evidence is in `/home/beacon/.cache/codex/thor-api/20260914/`.

Post-recovery verification passed all eight Tailnet API checks (chat 0.38 s, SSE chat 0.34 s, JSON and tool flows below one second in this short smoke test). A public-endpoint retry using curl's user agent returned HTTP 200 with complete SSE `OK` output in 1.32 s; this does not establish compatibility with all SDK user agents. The first public probe had a client-side JSON parsing failure, retained in the raw evidence. Both tailscaled and inference plus memory/health monitors were active at completion. The reported pi 524 cannot be conclusively attributed to this incident without its actual model/request details.

This documentation-only update ran `git diff --check`. The broad flake evaluation was attempted but blocked fetching the pinned public infra repository from Forgejo; no Nix configuration was changed during recovery.

## Deferred context expansion — 2026-09-14

The read-only capacity assessment and the manufacturer's technical lead's [768K YaRN report](https://manateelazycat.github.io/2026/08/28/qwen-3-8-27b-yarn-768k/) and [900K report](https://manateelazycat.github.io/2026/08/28/qwen-3-8-27b-900k-context/) are recorded in the public infra repository's `docs/thor/models/qwen3.8-27b.md`, including the reported figures, missing reproduction settings and deferred test checklist.

Our pinned target/draft both support native 262144 positions. Calculated BF16 KV is 21 GiB at that size; current host available memory is approximately 82 GiB. Candidate validation uses context262144/pool270336 while retaining existing safeguards. These are estimates, not a completed long-context test. Evidence remains at `/home/beacon/.cache/codex/thor-api/context-capacity/`. Validate native capacity first, then the reported YaRN ranges, before changing this service, LiteLLM metadata or agent budgets. Current deployment remains 4K.

The technical lead's [2026-08-27 concurrency report](https://manateelazycat.github.io/2026/08/27/qwen-3-8-27b-125-tokens/) (3754 TPS prefill, 125 TPS long-code decode, 231 TPS eight-session code decode, 70 GB memory) is also preserved there. It is not evidence for eight simultaneous 256K/900K requests. Current `max-running-requests=1` is an explicit service setting; requests beyond that queue.


## Native 256K trial — 2026-09-14

The temporary context262144/pool270336 trial completed native retrieval at
32769, 131072 and 261120 input tokens, plus identical-prefix reuse. All
returned three correct facts and finished normally. First-text latencies
were 31.367 s, 397.149 s, 1506.754 s and 11.613 s respectively; reuse hit
260096 cached tokens. Minimum sampled host available memory was 60.70 GiB,
with zero automatic inference restarts. Full parameters, output counts
and limitations are in the public model document.

A subsequent warm 261120-input archive request through the Tailnet LiteLLM
endpoint returned HTTP 200 and all facts, first text 3.237 s, complete
9.394 s. This proves the warm API path, not cold long-request viability:
the existing 300 s timeout is shorter than the measured cold 128K/256K
prefill. Public ingress and client deadlines also need qualification.

The trial used `switch-to-configuration test` from an isolated checkout;
boot profile generation 8 was retained and restored to runtime afterward.
Production remains 4K, default output 1024, one running request. No LiteLLM
metadata or permanent Nix parameter changes were made. Promote capacity
only together with timeout/client budgets and incremental/cache-eviction
tests; long cold prefill currently blocks other agents in the queue.
Evidence: `/home/beacon/.cache/codex/thor-api/context-capacity/evidence/`.

Restoration completed successfully; runtime again matches generation 8.
All eight Tailnet smoke checks passed afterward (chat, SSE, JSON,
tool/follow-up/stream, model listing and unauthenticated rejection).
Both repositories passed `nix flake show --all-systems` and diff checks;
private evaluation used the identical pinned infra revision via local Git
because the Forgejo HTTPS fetch was unavailable. The isolated trial's
exact Thor system also built successfully before activation.


## Long-request service qualification — 2026-09-14

The second trial used the OpenAI-compatible Tailnet endpoint, not direct
native generation. LiteLLM 1.90.0 model timeout and stream timeout were
raised to 2400 s and model retries disabled. A 131072-token cold request
returned HTTP 200, all three archive facts, 50 output tokens, first text
398.648 s and completion 401.928 s. A short request submitted ten seconds
later returned correctly after 392.852 s, demonstrating queue head-of-line
blocking rather than parallel execution.

Appending the actual assistant response and a follow-up question yielded
131149 input tokens, first text 2.225 s and completion 4.890 s. Backend
logs confirmed 131072 cached tokens and 77 new tokens. Retrieval remained
correct. Gateway usage did not include cache-token details in this test;
use backend evidence instead of assuming those usage fields are exposed.

A separate 128K request was disconnected before first text at 15.027 s.
Five seconds later, a short request completed in 0.364 s. This validates
slot release with the shared gateway's disconnect cancellation enabled;
it is not a complete cancellation test for every external provider.

Evidence and probe scripts are retained locally at
`/home/beacon/.cache/codex/thor-api/context-service/`.


The 32769-token archive returned correctly before and after explicit cache
flush (first text 32.070/31.698 s, complete 33.572/33.203 s). The first
32K request also missed cache despite the fixture label `warm-32k`.
This tests deliberate cache loss, not natural eviction under many agents.
An oversized 263169-token request returned HTTP 400 in 1.786 s.

After these checks, context262144/pool270336 was promoted persistently,
and LiteLLM metadata/default output updated to match. The operational
instructions at the top supersede the earlier temporary-trial restoration
notes. Output budget 8192 is advertised for clients; these short retrieval
outputs do not certify 8192-token generation quality at the context limit.


Persistent promotion completed to generation 9, system
`/nix/store/0fn7i9jw4jvf3vzdvaz80kmmhzx4kr2w-nixos-system-thor-26.05.20260910.d58a46e`.
Runtime and system profile match, and `bootctl list` selects generation 9
by default; no additional reboot was performed. The deployed closure is
the isolated, previously validated Thor configuration plus the two context
parameters, excluding concurrent unrelated repository changes.

Final eight API smoke checks passed. Inference and memory/health monitors
remain active, with zero automatic restarts during this trial. Terraform's
final full plan reports no changes. Both flake evaluations passed, the
exact isolated Thor closure built, ConfigMap server dry-run and rollout
passed, and repository diffs passed whitespace checks. Private evaluation
again used the identical pinned public revision through local Git.
Pi settings above were verified against installed source and are a handoff;
the separately maintained Pi extension was not edited or deployed here.


## Four active requests and an on-demand experiment — 2026-09-14

Production now sets `max-running-requests=4`, `max-mamba-cache-size=24`
and `cuda-graph-max-bs-decode=4`. The runtime requires five Mamba slots per
request with this overlap/extra-buffer configuration; changing only the
request limit would leave the old eight-slot setting capped at one.
Context262144, shared pool270336, block16 and existing memory guards remain.

Initial qualification observed four simultaneous CUDA-graph decode requests.
One/two/four short code requests each returned 384 output tokens without
API errors; the cap can truncate code, so these are concurrency checks,
not code-correctness or isolated performance benchmarks. Four independent
roughly 32K archives returned all three case-specific facts correctly.
Their first-text times were 32.520–129.091 s, with all four complete by
130.601 s. Prefill scheduling still affects latency even with four slots.
Eight-way service and four full 256K inputs were not qualified.

`thor-inference-experiment.service` is installed but not enabled at boot.
It launches another instance of the pinned model/draft with 4096 context,
8192 KV slots, one running request, eight Mamba slots and graph batch one.
It binds only `127.0.0.1:8890`, using backend model name
`qwen3.8-27b-thor`. It is not registered as an ordinary LiteLLM route.
The investigating agent keeps using the production LiteLLM model and
controls/probes the experiment over SSH.

On Thor:

```sh
sudo systemctl start thor-inference-experiment
curl --fail http://127.0.0.1:8890/health_generate
sudo journalctl -u thor-inference-experiment -n 50
sudo systemctl stop thor-inference-experiment
```

The experiment shares read-only model snapshots, but uses its own
`/var/lib/thor-inference/experiment/{kernel-cache,work,runtime-patches}`.
It prepares a fresh copy of the pinned patches at startup; manual edits
to those generated copies are not a persistent candidate definition.
Future candidate patches should be versioned and wired only into the
experiment's startup configuration, leaving the production patch inputs
unchanged. Starting the baseline experiment is not automatic optimization.

Admission requires 48 GiB host `MemAvailable`. While it runs, its own
watcher immediately kills the experiment container below 18 GiB Available,
or below 4 GiB Free with Available below 22 GiB. Production retains its
12/18 GiB guard. Failed startup also forcibly removes the experiment
container. There is no automatic restart, and a one-hour runtime limit
bounds forgotten experiments. Docker's 48 GiB memory setting is not a GPU
partition; the host memory watcher remains necessary on unified memory.

Coexistence is a functional test only. For performance comparisons, prepare
all candidate/reference commands and checks first; a separate bounded
orchestration job must stop production and other GPU workloads, run each
variant alone, and restore production on success or failure. The model
cannot issue another inference call while its own production server is
stopped, but its already-dispatched shell/systemd job can continue and
restore it before the next agent turn. Do not interpret coexistence timings
as isolated throughput results.


The full second DFlash instance did **not** pass coexistence qualification:
at 15:39:17 CST, sampled Available reached 21.746 GiB while Free reached
0.988 GiB, triggering the experiment's low-Free/Available guard. The
experiment was terminated and removed; production stayed active with zero
automatic restarts. This confirms the protection/failed-start cleanup path,
not successful dual-instance inference. No performance comparison was run.
The experiment remains stopped and disabled at boot. A proposed target-only
fallback was not deployed or tested and is not included in this change.
Further experiments were paused at the user's request.

The persisted configuration uses the already running four-request closure
`/nix/store/cvcc17f3dggib69hdf2znkf3ifwbr3la-nixos-system-thor-26.05.20260910.d58a46e`.
Only the system profile and boot configuration are updated during final
handoff; production is not restarted. LiteLLM's description now explicitly
states four active requests sharing 270336 resident tokens. Earlier
single-request and temporary-trial descriptions above are historical.

Final handoff selected generation 10 as the default boot entry. The production
InvocationID was identical before and after the boot-only update, confirming
no service restart. The exact closure rebuilt to the same store path, broad
flake evaluation and shell syntax checks passed, and the LiteLLM metadata
apply changed only this model description. Unrelated agent edits were excluded.


## NInfer follow-up and restoration — 2026-09-14

The Pi session had stopped `thor-inference` in one tool call and then lost
its own next model call with HTTP 500. No NInfer process remained running
when inspected, only the build container's idle `sleep`; production was
restored before continuing the user's authorized investigation.

The existing `/home/beacon/ninfer-port` source and
`/home/beacon/ninfer-artifacts/qwen3_8_27b.ninfer` artifact ran successfully
on Thor. This artifact is groupwise-int, not NVFP4. Nine short functional
checks across eager, Graph and DFlash2, and four relevant device tests,
passed with production stopped. The public model document records exact
scope, memory figures and remaining NVFP4 stub limitations.

Test orchestration used a bounded systemd task with `ExecStopPost` that
stops the `ninfer-build` container and starts `thor-inference`, including
failure/timeout. This lets a dispatched tool task restore inference without
requiring another model turn. Do not split stop/test/restore across separate
agent turns when that agent depends on the service being stopped.
The NInfer build container remains available, but is stopped by cleanup;
its source, artifact and result bind mounts persist.

Evidence: `/home/beacon/.cache/codex/thor-api/ninfer-followup/` locally and
`/home/beacon/ninfer-port/thor-followup/` on Thor. Production configuration
and the LiteLLM model route were not replaced by NInfer.

The first no-draft coexistence attempt failed at CUDA-free admission despite
56.65 GiB host Available. NInfer now uses a core integrated-GPU budget query
backed by Linux MemAvailable, with CUDA fallback and no SwapFree allowance.
The public model document archives the patch, provenance and test scope.

Rebuilding uncovered missing FFmpeg development files in the existing build
container. Matching Ubuntu arm64 6.1.1-3ubuntu5 development packages were
extracted into `thor-followup/dev-overlay`, without installing system packages;
CMake uses those headers and the existing versioned runtime libraries.
`ninfer-build-memory-fix.sh`, `dev-packages.sha256`, build logs and the CPU
test log in the evidence directory preserve the exact recovery procedure.
The CLI rebuilt successfully and `ninfer_memory_test` passed.

The corrected CLI passed all nine cases in `postfix-coexist/` with production
resident. Across 173 half-second samples, minimum Available was 35.71 GiB
and minimum Free 8.20 GiB. These are sampled separate minima, not a maximum
load qualification. Production InvocationID was unchanged with NRestarts=0;
two short LiteLLM checks during the run returned expected output (HTTP 200),
and the final post-cleanup check passed in 0.318 s. The experiment container
is stopped, production is active, and the four-request/256K configuration
is unchanged. Do not infer four-long-request headroom from this short trial.

### NInfer serving trial

The corrected `ninfer-serve` was relinked and exercised with 32K context,
64K shared Main KV, four active requests, FP8 KV and DFlash2. Host KV was
explicitly 1 GiB with four Host state slots; the temporary thinking budget
was 128 tokens. The listener stayed on container loopback and was never
added to LiteLLM. All twelve generation probes passed, covering SSE, tool
round trips, real four-row decode, thinking and a 27,916-token retrieval
followed by cached continuation. Exact results and limitations are in the
public model document.

Evidence is `/home/beacon/ninfer-port/thor-serving/` on Thor and
`/home/beacon/.cache/codex/thor-api/ninfer-serving/` locally. `command.json`
contains exact startup flags, `probe.py` the fixtures, `results.json` the
responses, and `requests.jsonl` the Engine counters. The bounded
`thor-ninfer-serving` task used the existing independent cleanup, plus an
experiment stop threshold at 20 GiB Available; minimum sampled Available
was 30.92 GiB. Cleanup succeeded, the build container is stopped and the
production service remained active with no restart.

### Exclusive NInfer comparison and NVFP4 port

The user explicitly authorized exclusive GPU use for this trial. The
`thor-ninfer-benchmark-full` task measured the resident SGLang baseline,
stopped it, and measured NInfer groupwise plain/draft7. A subsequent
`thor-ninfer-nvfp4-fixed` task measured the corrected NVFP4 A16 route.
`ExecStopPost` stops `ninfer-build` and restores `thor-inference` on every
exit, including failures. For a Pi agent using this backend, dispatch the
whole test/recovery job in one tool and wait for cleanup completion before
requesting another model turn; `systemd-run --wait` is appropriate.

The first SwiGLU boundary oracle exposed use of a generic 32-token limit
against a launcher table supporting only 2–16; the corrected shared
SwiGLU-specific limit and checked table lookup passed all existing and new
boundary cases. Five NVFP4/FP8 device tests and nine actual NVFP4 functional
cases passed. The public document archives a complete patch replayable from
the original tar, including the earlier Pi and memory changes.

The author's matched NVFP4 artifact is now at
`/home/beacon/ninfer-artifacts/qwen3_8_27b_nvfp4.ninfer`; its download was
pinned and SHA256-verified. It is a mixed recipe with FP8 output head, not
the production ModelOpt/BF16-head checkpoint. Source, bounded launchers and
raw evidence are under `ninfer-port/thor-benchmark/`, `ninfer-port/thor-nvfp4/`
and `/var/lib/thor-inference/work/ninfer-benchmark/`; local copies are under
`/home/beacon/.cache/codex/thor-api/ninfer-benchmark/`. The initial failing
oracle log was retained separately. No production configuration or LiteLLM
route was changed.

Final cleanup completed successfully: `thor-ninfer-nvfp4-fixed` is inactive
with Result=success, `ninfer-build` is stopped, and `thor-inference` is active
with NRestarts=0. The final LiteLLM short request returned HTTP 200 and
expected output in 0.463 s. NVFP4 draft7 code decode reached 25.51 tok/s,
versus 22.79 for groupwise draft7 and 66.47 for SGLang. NVFP4 draft15 reached
46.60 tok/s on counting but only 53.37 aggregate tok/s with four requests;
the 1843-token prefill TTFT remained about 25 s. These measured fallback
results do not justify replacing the daily SGLang service. The next native
kernel entry points and full comparison are recorded publicly.

### Native SM110 MLP down qualification

The exclusive `thor-ninfer-native-probe` task qualified a CUTLASS native
NVFP4 GEMM at `[5120,17408]`; the follow-up integrated BF16 activation
quantization and residual addition into the caller-owned LinearAdd Op.
Only the 27B MLP down policy and matching workspace plan select this route,
with `AllowA4` at T>=8. Enable the experimental build with
`-DNINFER_CUTLASS_INCLUDE_DIR=/opt/sglang/lib/python3.12/site-packages/flashinfer/data/cutlass/include`.
It uses the installed FlashInfer 0.6.17 vendored CUTLASS headers but has no
FlashInfer Python runtime dependency. Production configuration is unchanged.

The packed probe passed ten shapes. Complete LinearAdd passed independent
FP64 criteria, workspace guards and changing-input Graph replay; all nine
model cases passed. A first test fixture incorrectly borrowed zero bytes
for the A16 route and was fixed before the successful run. Complete Op
latency is 0.284 ms at T16 and 0.750 ms at T1024. Model code decode with
DFlash2 draft7 improved from 25.51 to 28.43 tok/s (+11.4%); no-draft 1843-token
TTFT improved from 25.00 to 17.84 s (-28.6%). No-draft code decode remains
10.46 tok/s. These results remain below the previous SGLang baseline.

The first supplementary four-request fixture returned incorrect JSON keys
in three responses, causing `thor-ninfer-native-model-fixed` to exit and
restore production. A bounded `thor-ninfer-native-batch` task then tested
four longer, explicit JSON objects: all four returned exactly 95 tokens,
and engine logs confirmed four running/decode-ready rows with batch size 4.
This is execution qualification, not a broad quality or throughput claim.
Failed fixtures and raw output remain in the evidence directory.

All jobs use the independent `ExecStopPost` cleanup. Final batch task is
inactive with Result=success; `ninfer-build` is stopped; `thor-inference`
is active with NRestarts=0. The final LiteLLM request returned HTTP 200,
expected `OK`, in 0.414 s. The main four-request, 256K service remains the
normal route. Remote evidence is `/home/beacon/ninfer-port/thor-native/`;
local evidence is `/home/beacon/.cache/codex/thor-api/ninfer-native/`.
The public model document archives measurements, the standalone probe and
the complete source patch replayed against the original tar. Further native
work can start with MLP gate/up; it is not implemented by this trial.

### Active Pi long-context slowdown — 2026-09-15

A passive investigation at approximately 03:30 CST located the local Pi
session `2026-09-14T15-33-22-132Z_01a0a08d-2e53-72ba-a3ae-9ce9950b2bb5.jsonl`
under `~/.pi/agent/sessions/--home-beacon-infra-private--/`. At the 03:26
snapshot it had 70 assistant messages, 92 tool results and no compaction;
reported input grew from 6680 to 140671 tokens. Cumulative reported output
was about 85009 tokens, including approximately 65766 reasoning tokens
(77%). One early upstream usage row is inconsistent, so these aggregates
are approximate. No session content, configuration or active process was
modified or interrupted.

Pi 0.85.1 registers this model with contextWindow=262144/maxTokens=8192.
Its effective default compaction settings are enabled, reserveTokens=16384
and keepRecentTokens=20000, triggering only above approximately 245760
context tokens. `openai-completions.js:1000–1006` replays this session's
thinking blocks as `reasoning_content`; the deployed model's
`chat_template.jinja:111–117` includes them by default. Even setting
preserve_thinking=false would retain thinking after the last user query,
so it is not a reliable remedy for an extended autonomous tool sequence.
Deleting arbitrary in-flight reasoning is not a qualified replacement for
semantic compaction.

Four hours of production logs show single-request decode samples with no
queued requests. Grouped medians are observations across different points
of a real task, not a controlled fixed-prompt benchmark:

| Full token count | Samples | Logged generation tok/s | Accept length |
|---|---:|---:|---:|
| 32768–65535 | 97 | 9.75 | 3.40 |
| 65536–99999 | 175 | 7.49 | 3.38 |
| 100000–124999 | 112 | 6.79 | 4.10 |
| 125000–149999 | 68 | 4.63 | 3.33 |

Only the production container was running; NRestarts=0, approximately
56 GiB MemAvailable and memory PSI averages zero. A brief passive
tegrastats sample showed GPU near 50 C, clocks 1385 MHz, and EMC utilization
18–20% at 4266 MHz. This does not establish a saturation or thermal limit.
The earlier short-prompt 66.47 tok/s result is not representative of this
140K-context reasoning workload. Capacity qualification at 256K did not
establish acceptable everyday latency at that occupancy.

The installed source identifies a strong performance hypothesis, not a
profiled attribution. In `triton_backend.py:196`, split-KV target verify is
limited to gfx95/ROCm. Thor's verify instead calls `extend_attention_fwd`
(:1417–1462). `extend_attention.py:462` scans the full prefix within each
query tile; its grid (:837) has no prefix-split dimension. For hd256 the
selected tile is M64/N64 while DFLASH verifies only 16 query tokens.
`dflash_worker_v2.py:1905–1952` also uses the full prefix for draft attention
and then runs target verification (:2005–2052). Historical K/V is not
recomputed each round: only the current hidden block is appended
(:2187–2201). Attention nevertheless rereads the long prefix each round.
Ordinary decode's num-kv-splits knob does not address this verify path.

Full-model FA4 remains blocked: the installed CuTe interface selects the
dedicated hd256 kernel on both SM100 and SM110 (:900) but rejects
seqused_q/seqused_k (:1458). The SGLang FA4 KV wrapper supplies
seqused_k=cache_seqlens (:276–283). Bottom-level SM110 support alone does
not remove this interface restriction. FP8 FA4 also has a separate SM100
architecture guard; neither change is ready for production.

Priorities for the next idle window:

1. Qualify a Pi semantic compaction target around 32–64K independently of
   the backend's retained 256K capacity. Investigate a model-specific soft
   threshold; do not invent a Pi setting or globally change other models.
   Routine inventory work can separately compare less reasoning, preserving
   medium for decisions that benefit from it. Neither change was applied.
2. At fixed 32K/64K/128K prompts, compare DFLASH16/8/4 and no draft, retaining
   KV dtype and attention backend. Measure round time, acceptance, TTFT,
   generation rate and correctness rather than assuming a shorter block wins.
3. Separately compare draft window 8192/32768 with the full-context baseline.
   The installed `--speculative-draft-window-size` limits the draft while
   leaving the target context intact; acceptance and retrieval must be
   checked. This behavior is also described in the upstream
   [server arguments](https://sgl-project.github.io/advanced_features/server_arguments.html).
4. Investigate a qualified CUDA split-KV verify implementation or repair
   the FA4 hd256 paged/varlen interface before deployment. Further NInfer
   gate/up work is secondary to this production long-context problem.

Raw production logs are local at
`~/.cache/codex/thor-api/production-slow/sglang.log`; the read-only installed
attention source snapshot is `/tmp/thor-installed-audit/`. No API workload,
GPU profiling, compilation, service restart or live Pi configuration change
was performed during this investigation.

## Controlled short-prompt comparison — 2026-09-18

After stopping the live official AI Pod request, the same single-request
benchmark was run against the official vLLM deployment and the earlier NixOS
SGLang deployment. Both used streaming, `max_tokens=512`, temperature 0 and
`enable_thinking=false`; no request was running in parallel.

| Case | Prompt tokens | NixOS/SGLang | Official AI Pod/vLLM |
| --- | ---: | ---: | ---: |
| Count integers 1–2000 | 43 | 119.4 tok/s | 114.4 tok/s |
| Python async HTTP queue module | 82 | 66.5 tok/s | 49.3 tok/s |

The count prompt was `Output the integers from 1 to 2000 in order, separated
by commas. Do not explain or stop before 2000.` The code prompt requested a
complete standard-library Python async HTTP job queue with retries,
cancellation, deadlines, JSONL persistence and six unittest cases. These are
short synthetic decode benchmarks, not long-context production tasks. The
official deployment was idle after the comparison.
