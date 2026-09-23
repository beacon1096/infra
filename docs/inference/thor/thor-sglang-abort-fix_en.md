# Thor SGLang client-disconnect abort fix

## Summary

On 2026-09-15, Thor's pinned SGLang image could leave a generation running in the scheduler after Pi steered to a new turn or an HTTP client disconnected. The abandoned generation consumed one of the four scheduler slots and reduced useful throughput until it finished naturally. These scheduler-only generations are referred to here as ghost requests.

The fix backports the request-lifecycle changes from upstream SGLang commit [`f478b2bb2d582c09e7f1b4e49f0c2d039da8747a`](https://github.com/sgl-project/sglang/commit/f478b2bb2d582c09e7f1b4e49f0c2d039da8747a), "Fix: abort handling for dispatched requests after client disconnect (#35255)", with the scheduler condition adapted to Thor's pinned revision.

## Observed behavior

Two Pi processes and two active LiteLLM connections produced four running scheduler requests. The additional request IDs were:

- `120427ec3a94400e9de290668bb0754c`
- `20b85a89c6c6443daf24145f6072fbe3`

TokenizerManager logged the corresponding failure mode:

```text
Received output for rid='...' but the state was deleted in TokenizerManager.
```

The two ghost requests eventually completed, reducing the scheduler count from four to three and then two without any client reconnect or multica workload. This excluded multica as the source of the extra concurrency. GPU clocks, utilization, temperature and power mode were normal.

Observed aggregate generation throughput was approximately 28–30 token/s with four scheduler requests and 21–25 token/s with two. A brief single-request interval reached approximately 23.8 token/s. These figures diagnose concurrency effects only; DFlash acceptance-rate tuning remains frozen.

## Root cause

The pinned TokenizerManager created `rid_to_state` before tokenization and dispatch. Its broad request-handler exception path called `_discard_pending_req_states()`, which removed every remaining state without distinguishing between requests that had and had not reached the scheduler.

For a dispatched streaming request, disconnect handling could therefore follow this sequence:

1. The request reached the scheduler and began generation.
2. Pi steered or disconnected the old HTTP stream.
3. The handler exception removed its `rid_to_state` entry.
4. The delayed disconnect abort task ran two seconds later.
5. `abort_request()` saw no state for the RID and, with one tokenizer worker, returned without sending `AbortReq` to the scheduler.
6. The scheduler continued generation with no client until natural completion.
7. Any later scheduler output found no TokenizerManager state and emitted the warning above.

Deleting scheduler state directly is unsafe because abort must pass through the scheduler's normal finish path, including overlap scheduling, DFlash and hybrid Mamba state cleanup.

A related scheduler race existed for chunked prefill. If abort was deferred while the request was the active chunked request, and that request moved to another queue before deferred processing, the pending abort marker could be dropped without retrying the normal abort path.

## Backport

The declarative patches are:

- `hosts/personal/fixed/thor/inference/tokenizer_manager.py.patch`
- `hosts/personal/fixed/thor/inference/scheduler.py.patch`
- `hosts/personal/fixed/thor/inference/manifest.json`

TokenizerManager now:

- records whether each request was successfully dispatched;
- records whether an abort was already sent;
- deletes only states that failed before dispatch;
- sends an idempotent scheduler abort for dispatched requests and retains their state until scheduler cleanup;
- resets the idempotency marker if dispatching the abort itself fails;
- tracks generated RIDs for batch parallel sampling;
- marks both individual and batch dispatches only after transport dispatch succeeds;
- lets the delayed disconnect task abort only states that still exist.

The scheduler now retries `abort_request()` when a deferred chunked request has moved out of the chunked slot but still owns its request-pool allocation. Upstream uses `req.kv.holds_kv` at this point; Thor's pinned revision uses the equivalent available lifecycle signal, `req.req_pool_idx is not None`.

Startup extracts the original files from the image pinned in `hosts/personal/fixed/thor/inference.nix`, verifies their original SHA256 values, applies patches with zero fuzz, verifies the resulting SHA256 values and bind-mounts the patched files read-only. An image update must deliberately refresh both patches and manifest hashes.

## Validation

Validation performed on 2026-09-15:

- replayed both patches with `patch --batch --fuzz=0`;
- compiled both patched Python modules with `python3 -m py_compile`;
- built `.#nixosConfigurations.thor.config.system.build.toplevel`;
- deployed the resulting NixOS closure to Thor;
- verified the two mounted files against their manifest result hashes inside the running container;
- verified `thor-inference.service` was active and `/health` returned success;
- started one streaming request with `max_tokens=4096`, received 6899 bytes, then forced a client timeout after three seconds;
- observed no residual decode request during the following checks and a subsequent generation health probe reported zero running and queued requests;
- observed no `state was deleted in TokenizerManager`, traceback or scheduler error after restart and cancellation.

The cancellation check was intentionally limited to one request and was not a performance benchmark. Future image upgrades should repeat it, including a cancellation during chunked prefill if the pinned SGLang revision changes the relevant queue lifecycle.
