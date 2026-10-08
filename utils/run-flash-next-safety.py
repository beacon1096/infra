import csv
import datetime
import http.client
import json
from pathlib import Path
import subprocess
import sys
import threading
import time


BASE_URL = "http://127.0.0.1:8890/v1"
MODEL = "qwen3.8-flash-next-thor"
CANCEL_LIMIT_SECONDS = 20.0
MIN_CANCEL_EVENTS = 20


def consume_stream(next_line, monotonic, limit_seconds):
    content_events = 0
    finish_reason = None
    started = monotonic()
    while monotonic() - started < limit_seconds:
        line = next_line()
        if line == b"":
            break
        if not line.startswith(b"data: "):
            continue
        payload = line[5:].strip()
        if payload == b"[DONE]":
            finish_reason = "done"
            break
        try:
            event = json.loads(payload)
        except ValueError:
            continue
        choices = event.get("choices") or []
        if not choices:
            continue
        choice = choices[0]
        if (choice.get("delta") or {}).get("content"):
            content_events += 1
        if choice.get("finish_reason"):
            finish_reason = choice["finish_reason"]
    return {"content_delta_events": content_events, "finish_reason": finish_reason,
            "elapsed_seconds": monotonic() - started}


def cancel_probe(host, port, request_body, limit_seconds):
    connection = http.client.HTTPConnection(host, port, timeout=min(10.0, limit_seconds))
    connection.request("POST", "/v1/chat/completions", body=json.dumps(request_body).encode(),
                       headers={"Content-Type": "application/json", "Accept": "text/event-stream"})
    response = connection.getresponse()
    if response.status != 200:
        connection.close()
        raise RuntimeError(f"cancel probe HTTP {response.status}")
    result = consume_stream(response.fp.readline, time.monotonic, limit_seconds)
    connection.close()
    result["aborted_by_client"] = True
    return result


def active():
    return subprocess.run(["systemctl", "is-active", "--quiet", "thor-flash-next.service"]).returncode == 0


def sample(stop, phase_ref, output):
    started = time.monotonic()
    with (output / "telemetry.jsonl").open("x") as handle:
        while not stop.is_set():
            memory = {}
            for line in Path("/proc/meminfo").read_text().splitlines():
                key, value = line.split(":", 1)
                if key in {"MemAvailable", "MemFree", "SwapFree", "SwapTotal"}:
                    memory[key] = int(value.split()[0]) / 1024**2
            row = {"elapsed_seconds": time.monotonic() - started, "phase": phase_ref[0], "memory_gib": memory}
            try:
                text = subprocess.check_output(["nvidia-smi", "--query-gpu=clocks.current.sm,clocks.current.memory,"
                                                "temperature.gpu,power.draw,utilization.gpu",
                                                "--format=csv,noheader,nounits"], text=True, timeout=3)
                values = next(csv.reader(text.splitlines()))
                row["gpu"] = {key: float(value.strip()) if "N/A" not in value else None for key, value in
                              zip(("sm_clock_mhz", "memory_clock_mhz", "temperature_c", "power_w",
                                   "utilization_percent"), values)}
            except (OSError, ValueError, subprocess.SubprocessError):
                row["gpu"] = None
            handle.write(json.dumps(row) + "\n")
            handle.flush()
            stop.wait(1)


def parse_request_record(path):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    requests = [row for row in rows if row["type"] == "request"]
    if len(requests) != 1:
        raise RuntimeError(f"{path.name}: expected exactly one request record")
    return requests[0]


def run_benchmark(client, output, fixtures, case_id, tag, deadline=300, timeout=330):
    path = output / f"{tag}.jsonl"
    command = [sys.executable, "-B", str(client / "utils/benchmark-thor.py"), "run", "--profile", "G1",
               "--model", MODEL, "--base-url", BASE_URL, "--runtime-record", str(output / "runtime.json"),
               "--warmups", "0", "--repeats", "1", "--seed", "42", "--cache-policy", "shared-prefix",
               "--include-response", "--deadline", str(deadline), "--case", case_id]
    if fixtures is not None:
        command.extend(["--fixtures", str(fixtures)])
    with path.open("x") as stdout, path.with_suffix(".stderr").open("x") as stderr:
        completed = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=timeout)
    return completed.returncode, parse_request_record(path)


def natural_prose_row(case_id, repeat, returncode, record):
    return {"id": case_id, "repeat": repeat, "exit_code": returncode, "status": record["status"],
            "finish_reason": record.get("finish_reason"), "correctness": record["correctness"],
            "usage": record.get("usage"), "metrics": record.get("metrics")}


def main(argv):
    client, output, recorder = map(Path, argv[1:4])
    output.mkdir(parents=True, exist_ok=True)
    fixtures = client / "docs/inference/thor/benchmark/generation-safety.json"
    subprocess.run([sys.executable, "-B", str(recorder),
                    str(client / "docs/inference/thor/benchmark/profiles.json"), str(output), "G1"], check=True)
    phase = ["natural-prose"]
    stop = threading.Event()
    sampler = threading.Thread(target=sample, args=(stop, phase, output))
    sampler.start()
    prose, cancels = [], []
    try:
        for repeat in (1, 2):
            for case_id in ("natural-prose-off", "natural-prose-low"):
                phase[0] = case_id
                returncode, record = run_benchmark(client, output, fixtures, case_id, f"{case_id}-{repeat}")
                prose.append(natural_prose_row(case_id, repeat, returncode, record))
                if record["status"] != "completed" or not active():
                    raise RuntimeError("service failed during natural prose")
        cases = {case["id"]: case for case in json.loads(fixtures.read_text())["cases"]}
        for repeat in (1, 2):
            phase[0] = "cancel"
            body = dict(cases["cancel-long-generation"]["request"])
            body.update(model=MODEL, stream=True, stream_options={"include_usage": True})
            probe = cancel_probe("127.0.0.1", 8890, body, CANCEL_LIMIT_SECONDS)
            survived = active()
            phase[0] = "recovery"
            returncode, record = run_benchmark(client, output, fixtures, "recovery-short-json",
                                               f"recovery-short-json-after-cancel-{repeat}")
            recovery = {"exit_code": returncode, "status": record["status"],
                        "correctness": record["correctness"], "metrics": record.get("metrics")}
            cancels.append({"repeat": repeat, "content_delta_events": probe["content_delta_events"],
                            "finish_reason": probe["finish_reason"], "elapsed_seconds": probe["elapsed_seconds"],
                            "service_active_after_abort": survived, "recovery": recovery})
    finally:
        stop.set()
        sampler.join()
    telemetry = [json.loads(line) for line in (output / "telemetry.jsonl").read_text().splitlines()]
    gpu = [row["gpu"] for row in telemetry if row["gpu"]]
    summary = {
        "runtime_record": str(output / "runtime.json"),
        "natural_prose": prose,
        "cancels": cancels,
        "natural_prose_passed": sum(row["correctness"]["status"] == "passed" for row in prose),
        "natural_prose_count": len(prose),
        "cancel_survived": sum(row["service_active_after_abort"] for row in cancels),
        "cancel_count": len(cancels),
        "cancel_min_events": min((row["content_delta_events"] for row in cancels), default=0),
        "recovery_passed": sum(row["recovery"]["correctness"]["status"] == "passed" for row in cancels),
        "minimum_available_gib": min(row["memory_gib"]["MemAvailable"] for row in telemetry),
        "maximum_gpu_temperature_c": max(row["temperature_c"] for row in gpu) if gpu else None,
        "maximum_reported_gpu_power_w": max(row["power_w"] for row in gpu) if gpu else None,
        "transport_failures": sum(row["status"] != "completed" for row in prose),
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (output / "completed.json").write_text(json.dumps(
        {"status": "completed", "finished_at": datetime.datetime.now(datetime.timezone.utc).isoformat()},
        indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main(sys.argv)
