"""Capability A/B runner: auto-gated cases, N repeats, wall-to-valid-final focus.

Usage: run-thor-ab.py CLIENT OUTPUT BASE_URL MODEL PROFILE RUNTIME_RECORD
Env: THOR_REPEATS (default 3), THOR_CASES (comma-separated id filter)

Runs each case against a served model via the client benchmark-thor.py with a
shared-prefix cache policy, then reports per-case pass counts and the median
wall-to-valid time over passing repeats. Intended for Flash-Next vs 27B A/B:
run once per service and compare the summaries.
"""

import json
import os
from pathlib import Path
import statistics
import subprocess
import sys


REPEATS = int(os.environ.get("THOR_REPEATS", "3"))
CASES = [
    ("exact-short-output", "fixtures.json"),
    ("strict-json-schema", "fixtures.json"),
    ("tool-get-weather", "fixtures.json"),
    ("python-interval-repair-ast", "fixtures.json"),
    ("thinking-digit-low", "thinking-stability.json"),
    ("thinking-ledger32-low", "thinking-stability.json"),
    ("natural-prose-off", "generation-safety.json"),
    ("exact-arith-product", "held-out.json"),
    ("python-fill-memo-fib", "held-out.json"),
    ("strict-json-nested", "held-out.json"),
]


def request_records(path):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    return [row for row in rows if row.get("type") == "request"]


def main(argv):
    client, output, base_url, model, profile, runtime_record = argv[1:7]
    client, output = Path(client), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    fixtures_dir = client / "docs/inference/thor/benchmark"
    only = {name for name in os.environ.get("THOR_CASES", "").split(",") if name}
    selected = [(case_id, fixture) for case_id, fixture in CASES if not only or case_id in only]
    rows = []
    for case_id, fixture in selected:
        for repeat in range(1, REPEATS + 1):
            path = output / f"{case_id}-{repeat}.jsonl"
            command = [sys.executable, "-B", str(client / "utils/benchmark-thor.py"), "run",
                       "--profile", profile, "--model", model, "--base-url", base_url,
                       "--runtime-record", runtime_record, "--fixtures", str(fixtures_dir / fixture),
                       "--case", case_id, "--warmups", "0", "--repeats", "1", "--seed", "42",
                       "--cache-policy", os.environ.get("THOR_CACHE_POLICY", "shared-prefix"),
                       "--include-response", "--deadline", "360"]
            with path.open("x") as stdout, path.with_suffix(".stderr").open("x") as stderr:
                completed = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=420)
            records = request_records(path)
            if len(records) != 1:
                rows.append({"id": case_id, "repeat": repeat, "error": "no_request_record"})
                continue
            row = records[0]
            usage = row.get("usage") or {}
            metrics = row["metrics"]
            rows.append({"id": case_id, "repeat": repeat, "exit_code": completed.returncode,
                         "status": row["status"], "correctness": row["correctness"]["status"],
                         "finish_reason": row.get("finish_reason"),
                         "completion_tokens": usage.get("completion_tokens"),
                         "reasoning_tokens": usage.get("reasoning_tokens"),
                         "wall_seconds": metrics["wall_seconds"],
                         "tok_s": metrics["end_to_end_tokens_per_second"]})
            print(json.dumps(rows[-1]), flush=True)
    per_case = []
    for case_id, _ in selected:
        case_rows = [row for row in rows if row["id"] == case_id and "error" not in row]
        passing = [row for row in case_rows if row["correctness"] == "passed"]
        per_case.append({
            "id": case_id, "runs": len(case_rows), "passed": len(passing),
            "statuses": [row["correctness"] for row in case_rows],
            "finish_reasons": [row["finish_reason"] for row in case_rows],
            "wall_median_all": statistics.median(row["wall_seconds"] for row in case_rows) if case_rows else None,
            "wall_median_pass": statistics.median(row["wall_seconds"] for row in passing) if passing else None,
            "reasoning_tokens_median": statistics.median(row["reasoning_tokens"] for row in passing) if passing else None,
            "completion_tokens_median": statistics.median(row["completion_tokens"] for row in passing) if passing else None,
            "tok_s_median_pass": statistics.median(row["tok_s"] for row in passing) if passing else None,
        })
    pass_walls = [row["wall_seconds"] for row in rows if "error" not in row and row["correctness"] == "passed"]
    summary = {"base_url": base_url, "model": model, "profile": profile, "repeats": REPEATS,
               "total_runs": len(rows), "total_passed": sum(row.get("correctness") == "passed" for row in rows),
               "median_wall_to_valid_final": statistics.median(pass_walls) if pass_walls else None,
               "cases": per_case}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: summary[k] for k in ("profile", "total_runs", "total_passed", "median_wall_to_valid_final")}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
