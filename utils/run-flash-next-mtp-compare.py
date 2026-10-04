import datetime
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import threading
import time
import urllib.request


BASE_URL = "http://127.0.0.1:8890/v1"
METRICS_URL = "http://127.0.0.1:8890/metrics"
MODEL = "qwen3.8-flash-next-thor"
PROFILE = os.environ.get("THOR_PROFILE", "M1M")
REPEATS = int(os.environ.get("THOR_REPEATS", "3"))
WATCHED = ("sglang:spec_accept_length", "sglang:spec_accept_rate",
           "sglang:spec_verify_calls_total", "sglang:generation_tokens_total")
CASES = [
    ("natural-prose-off", "generation-safety.json"),
    ("natural-prose-low", "generation-safety.json"),
    ("natural-prose-narrative-off", "generation-safety.json"),
    ("python-interval-repair-ast", "fixtures.json"),
    ("thinking-digit-low", "thinking-stability.json"),
    ("thinking-ledger32-low", "thinking-stability.json"),
]


def parse_metrics(text):
    values = {}
    for line in text.splitlines():
        if not line.startswith("sglang:"):
            continue
        name = line.split("{", 1)[0].split(" ", 1)[0]
        if name not in WATCHED:
            continue
        try:
            values[name] = values.get(name, 0.0) + float(line.rsplit(" ", 1)[1])
        except (ValueError, IndexError):
            continue
    return values


def fetch_metrics():
    with urllib.request.urlopen(METRICS_URL, timeout=5) as response:
        return parse_metrics(response.read().decode())


def active():
    return subprocess.run(["systemctl", "is-active", "--quiet", "thor-flash-next.service"]).returncode == 0


def sample(stop, output, phase):
    started = time.monotonic()
    with (output / "metrics.jsonl").open("x") as handle:
        while not stop.is_set():
            try:
                values = fetch_metrics()
            except OSError:
                values = {}
            handle.write(json.dumps({"elapsed_seconds": time.monotonic() - started,
                                     "phase": phase[0], "metrics": values}) + "\n")
            handle.flush()
            stop.wait(1)


def request_records(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()
            and json.loads(line).get("type") == "request"]


def run_case(client, output, fixtures_dir, case_id, fixture_name, repeat, deadline=600):
    path = output / f"{case_id}-{repeat}.jsonl"
    command = [sys.executable, "-B", str(client / "utils/benchmark-thor.py"), "run", "--profile", PROFILE,
               "--model", MODEL, "--base-url", BASE_URL, "--runtime-record", str(output / "runtime.json"),
               "--warmups", "0", "--repeats", "1", "--seed", str(42 + repeat), "--cache-policy", "shared-prefix",
               "--deadline", str(deadline), "--case", case_id, "--fixtures", str(fixtures_dir / fixture_name)]
    with path.open("x") as stdout, path.with_suffix(".stderr").open("x") as stderr:
        subprocess.run(command, stdout=stdout, stderr=stderr, timeout=660)
    rows = request_records(path)
    if len(rows) != 1:
        raise RuntimeError(f"{case_id}-{repeat}: expected one request record")
    row = rows[0]
    usage = row.get("usage") or {}
    metrics = row["metrics"]
    return {"id": case_id, "repeat": repeat, "status": row["status"],
            "correctness": row["correctness"]["status"], "finish_reason": row.get("finish_reason"),
            "completion_tokens": usage.get("completion_tokens"),
            "reasoning_tokens": usage.get("reasoning_tokens"),
            "wall_seconds": metrics["wall_seconds"],
            "end_to_end_tokens_per_second": metrics["end_to_end_tokens_per_second"]}


def main(argv):
    client, output, recorder = map(Path, argv[1:4])
    output.mkdir(parents=True, exist_ok=True)
    fixtures_dir = client / "docs/inference/thor/benchmark"
    subprocess.run([sys.executable, "-B", str(recorder), str(fixtures_dir / "profiles.json"), str(output), PROFILE], check=True)
    phase = ["start"]
    stop = threading.Event()
    sampler = threading.Thread(target=sample, args=(stop, output, phase))
    sampler.start()
    rows = []
    try:
        for case_id, fixture_name in CASES:
            for repeat in range(1, REPEATS + 1):
                phase[0] = case_id
                rows.append(run_case(client, output, fixtures_dir, case_id, fixture_name, repeat))
                if rows[-1]["status"] != "completed" or not active():
                    raise RuntimeError("transport or model service failed; no further trials")
    finally:
        stop.set()
        sampler.join()
    samples = [json.loads(line) for line in (output / "metrics.jsonl").read_text().splitlines()]
    per_case = []
    for case_id, _ in CASES:
        case_rows = [row for row in rows if row["id"] == case_id]
        case_samples = [row["metrics"] for row in samples if row["phase"] == case_id]
        lengths = [s["sglang:spec_accept_length"] for s in case_samples if s.get("sglang:spec_accept_length")]
        rates = [s["sglang:spec_accept_rate"] for s in case_samples if s.get("sglang:spec_accept_rate")]
        per_case.append({
            "id": case_id, "observations": len(case_rows),
            "passed": sum(row["correctness"] == "passed" for row in case_rows),
            "statuses": [row["correctness"] for row in case_rows],
            "finish_reasons": [row["finish_reason"] for row in case_rows],
            "completion_tokens": [row["completion_tokens"] for row in case_rows],
            "wall_median": statistics.median(row["wall_seconds"] for row in case_rows),
            "tok_s_median": statistics.median(row["end_to_end_tokens_per_second"] for row in case_rows),
            "accept_len_median": statistics.median(lengths) if lengths else None,
            "accept_rate_median": statistics.median(rates) if rates else None,
        })
    summary = {"profile": PROFILE, "repeats": REPEATS, "acceptable_samples": len(samples),
               "transport_failures": sum(row["status"] != "completed" for row in rows), "cases": per_case}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (output / "completed.json").write_text(json.dumps(
        {"status": "completed", "finished_at": datetime.datetime.now(datetime.timezone.utc).isoformat()},
        indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main(sys.argv)
