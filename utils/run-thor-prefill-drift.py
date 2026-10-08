"""Capture teacher-forced prefill logprobs/top-k for a fixed token stream.

Usage: run-thor-prefill-drift.py IDS_JSON BASE_URL OUTDIR

Sends the whole stream as input_ids with return_logprob so SGLang scores every
position in the (deterministic) prefill path -- unlike the decode path, which is
run-to-run nondeterministic on this build. The captured per-position logprobs
are used to compare two mamba/SSM state dtypes under an identical token stream.
"""

import json
import sys
import time
import urllib.error
import urllib.request


def post(url, body, retries=6, timeout=300):
    for attempt in range(retries):
        try:
            request = urllib.request.Request(
                url, data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json", "Connection": "close"})
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read().decode()
        except Exception:
            time.sleep(2)
    raise RuntimeError(f"request failed after {retries} attempts: {url}")


def main(argv):
    ids_path, base_url, outdir = argv[1:4]
    ids = json.load(open(ids_path))
    post(f"{base_url}/flush_cache", {})
    time.sleep(0.3)
    body = {"input_ids": ids, "return_logprob": True, "logprob_start_len": 0,
            "top_logprobs_num": 10,
            "sampling_params": {"temperature": 0, "top_k": 1, "max_new_tokens": 1}}
    payload = json.loads(post(f"{base_url}/generate", body))
    meta = payload["meta_info"]
    inputs = meta["input_token_logprobs"]
    tops = meta.get("input_top_logprobs") or []
    result = {
        "base_url": base_url,
        "prompt_tokens": meta.get("prompt_tokens"),
        "token_ids": [entry[1] for entry in inputs],
        "logprobs": [entry[0] for entry in inputs],
        "top_logprobs": [[[lp, tid] for lp, tid, _ in row] if row else None for row in tops],
    }
    import os
    os.makedirs(outdir, exist_ok=True)
    with open(f"{outdir}/prefill-drift.json", "w") as handle:
        json.dump(result, handle)
    print(json.dumps({"base_url": base_url, "prompt_tokens": result["prompt_tokens"],
                      "positions": len(result["logprobs"]),
                      "topk_rows": sum(1 for row in result["top_logprobs"] if row)}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
