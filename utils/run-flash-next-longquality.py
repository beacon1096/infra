import datetime
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request


BASE_URL = "http://127.0.0.1:8890/v1"
MODEL = "qwen3.8-flash-next-thor"
PROFILE = os.environ.get("THOR_PROFILE", "L64K")
REPEATS = int(os.environ.get("THOR_REPEATS", "3"))
LENGTH = int(os.environ.get("THOR_LENGTH", "32000"))
FACTS = int(os.environ.get("THOR_FACTS", "12"))
COLORS = ["amber", "blue", "cedar", "delta", "ember", "frost", "gold", "hazel", "ivory", "jade", "kite", "lily"]
FILLER = ("The northern warehouse receives shipments every morning and the clerks record each crate "
          "in a ledger before moving it to the riverside depot where barges wait. ")
INSTRUCTION = ("Based only on the document above, return only a JSON object with fields: pairs (an object "
               "mapping each color name to its integer code), count (the number of vaults) and total (the "
               "sum of all codes). No Markdown or explanation.")


def build_document(repeat):
    codes = {color: 100 + repeat * 13 + index * 7 for index, color in enumerate(COLORS[:FACTS])}
    total_lines = max(FACTS * 2, LENGTH // 30)
    positions = {int((index + 1) * total_lines / (FACTS + 1)): COLORS[index] for index in range(FACTS)}
    lines = []
    for line in range(total_lines):
        if line in positions:
            lines.append(f"The access code for the {positions[line]} vault is {codes[positions[line]]}.")
        else:
            lines.append(FILLER.rstrip())
    document = "\n".join(lines) + "\n\n" + INSTRUCTION
    truth = {"pairs": codes, "count": FACTS, "total": sum(codes.values())}
    return document, truth


def ask(text, timeout=600):
    body = {"model": MODEL, "messages": [{"role": "user", "content": text}], "max_tokens": 384,
            "temperature": 0, "chat_template_kwargs": {"enable_thinking": False}}
    request = urllib.request.Request(BASE_URL + "/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        return {"content": "", "usage": None, "wall_seconds": time.monotonic() - started,
                "error": f"HTTP {error.code}: {error.read().decode()[:200]}"}
    choice = payload["choices"][0]
    return {"content": (choice["message"].get("content") or "").strip(), "usage": payload.get("usage"),
            "wall_seconds": time.monotonic() - started}


def active():
    return subprocess.run(["systemctl", "is-active", "--quiet", "thor-flash-next.service"]).returncode == 0


def sample(stop, output):
    started = time.monotonic()
    with (output / "telemetry.jsonl").open("x") as handle:
        while not stop.is_set():
            memory = {}
            for line in Path("/proc/meminfo").read_text().splitlines():
                key, value = line.split(":", 1)
                if key == "MemAvailable":
                    memory[key] = int(value.split()[0]) / 1024**2
            handle.write(json.dumps({"elapsed_seconds": time.monotonic() - started, "memory_gib": memory}) + "\n")
            handle.flush()
            stop.wait(2)


def check(content, truth):
    try:
        parsed = json.loads(content)
    except ValueError:
        return False, "not_json"
    if not isinstance(parsed, dict) or set(parsed) != {"pairs", "count", "total"}:
        return False, "fields"
    if parsed["pairs"] != truth["pairs"] or parsed["count"] != truth["count"] or parsed["total"] != truth["total"]:
        return False, "value"
    return True, "ok"


def main(argv):
    client, output, recorder = map(Path, argv[1:4])
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, "-B", str(recorder),
                    str(client / "docs/inference/thor/benchmark/profiles.json"), str(output), PROFILE], check=True)
    stop = threading.Event()
    sampler = threading.Thread(target=sample, args=(stop, output))
    sampler.start()
    results = []
    try:
        for repeat in range(1, REPEATS + 1):
            document, truth = build_document(repeat)
            response = ask(document)
            passed, reason = check(response["content"], truth) if not response.get("error") else (False, "http")
            results.append({"repeat": repeat, "passed": passed, "reason": reason,
                            "prompt_tokens": (response["usage"] or {}).get("prompt_tokens"),
                            "completion_tokens": (response["usage"] or {}).get("completion_tokens"),
                            "wall_seconds": response["wall_seconds"], "error": response.get("error")})
            if not active():
                raise RuntimeError("model service failed during long-quality check")
    finally:
        stop.set()
        sampler.join()
    telemetry = [json.loads(line) for line in (output / "telemetry.jsonl").read_text().splitlines()]
    summary = {"profile": PROFILE, "length": LENGTH, "facts": FACTS, "repeats": REPEATS,
               "passed": sum(row["passed"] for row in results), "results": results,
               "minimum_available_gib": min(row["memory_gib"]["MemAvailable"] for row in telemetry),
               "wall_median_seconds": statistics.median(row["wall_seconds"] for row in results)}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (output / "completed.json").write_text(json.dumps(
        {"status": "completed", "finished_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main(sys.argv)
