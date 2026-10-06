"""Run a fixed capability case set against one served model via benchmark-thor.py
and summarize correctness + wall time. Used for the Flash-Next vs 27B A/B.

Usage: run-thor-capability.py CLIENT OUTPUT BASE_URL MODEL PROFILE RUNTIME_RECORD
"""

import json
from pathlib import Path
import subprocess
import sys
import time


CASES = [
    ("exact-short-output", "fixtures.json"),
    ("strict-json-schema", "fixtures.json"),
    ("tool-get-weather", "fixtures.json"),
    ("python-interval-repair-ast", "fixtures.json"),
    ("agent-plan-thinking-low", "fixtures.json"),
    ("thinking-digit-low", "thinking-stability.json"),
    ("thinking-workers-low", "thinking-stability.json"),
    ("thinking-ledger32-low", "thinking-stability.json"),
    ("natural-prose-off", "generation-safety.json"),
    ("natural-prose-low", "generation-safety.json"),
]


def request_records(path):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    return [row for row in rows if row.get("type") == "request"]


def main(argv):
    client, output, base_url, model, profile, runtime_record = argv[1:7]
    client, output = Path(client), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    fixtures_dir = client / "docs/inference/thor/benchmark"
    results = []
    for case_id, fixture in CASES:
        path = output / f"{case_id}.jsonl"
        command = [sys.executable, "-B", str(client / "utils/benchmark-thor.py"), "run",
                   "--profile", profile, "--model", model, "--base-url", base_url,
                   "--runtime-record", runtime_record, "--fixtures", str(fixtures_dir / fixture),
                   "--case", case_id, "--warmups", "0", "--repeats", "1", "--seed", "42",
                   "--cache-policy", "shared-prefix", "--include-response", "--deadline", "360"]
        started = time.monotonic()
        with path.open("x") as stdout, path.with_suffix(".stderr").open("x") as stderr:
            completed = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=420)
        rows = request_records(path)
        if len(rows) != 1:
            results.append({"id": case_id, "error": "no_request_record",
                            "stderr": path.with_suffix(".stderr").read_text()[:200]})
            continue
        row = rows[0]
        usage = row.get("usage") or {}
        metrics = row["metrics"]
        results.append({"id": case_id, "exit_code": completed.returncode, "status": row["status"],
                        "correctness": row["correctness"]["status"], "finish_reason": row.get("finish_reason"),
                        "completion_tokens": usage.get("completion_tokens"),
                        "reasoning_tokens": usage.get("reasoning_tokens"),
                        "wall_seconds": metrics["wall_seconds"],
                        "end_to_end_tokens_per_second": metrics["end_to_end_tokens_per_second"],
                        "elapsed_seconds": time.monotonic() - started})
        print(json.dumps(results[-1]), flush=True)
    summary = {"base_url": base_url, "model": model, "profile": profile,
               "passed": sum(row.get("correctness") == "passed" for row in results),
               "case_count": len(results), "results": results}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: summary[k] for k in ("profile", "passed", "case_count")}, indent=2))


if __name__ == "__main__":
    main(sys.argv)
