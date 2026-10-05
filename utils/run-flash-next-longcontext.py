import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request


BASE_URL = "http://127.0.0.1:8890/v1"
MODEL = "qwen3.8-flash-next-thor"
PROFILE = os.environ.get("THOR_PROFILE", "L32")
DEPTHS = [int(value) for value in os.environ.get("THOR_DEPTHS", "9000,24000,34000").split(",")]
FILLER = ("The northern warehouse receives shipments every morning and the clerks record each crate "
          "in a ledger before moving it to the riverside depot where barges wait. ")
NEEDLE = "IMPORTANT NOTE: the vault code is six one eight three. "
QUESTION = "What is the vault code? Reply with only the four digits, no other text."


def active():
    return subprocess.run(["systemctl", "is-active", "--quiet", "thor-flash-next.service"]).returncode == 0


def build_prompt(target_tokens):
    per_line = 30
    repeats = max(1, target_tokens // per_line)
    half = repeats // 2
    text = (FILLER * half) + NEEDLE + (FILLER * (repeats - half)) + QUESTION
    return text, repeats


def ask(text, timeout=600):
    body = {"model": MODEL, "messages": [{"role": "user", "content": text}], "max_tokens": 32,
            "temperature": 0, "chat_template_kwargs": {"enable_thinking": False}}
    request = urllib.request.Request(BASE_URL + "/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        return {"content": "", "finish_reason": None, "usage": None,
                "wall_seconds": time.monotonic() - started,
                "error": f"HTTP {error.code}: {error.read().decode()[:300]}"}
    elapsed = time.monotonic() - started
    choice = payload["choices"][0]
    return {"content": (choice["message"].get("content") or "").strip(), "finish_reason": choice.get("finish_reason"),
            "usage": payload.get("usage"), "wall_seconds": elapsed}


def sample(stop, output):
    started = time.monotonic()
    with (output / "telemetry.jsonl").open("x") as handle:
        while not stop.is_set():
            memory = {}
            for line in Path("/proc/meminfo").read_text().splitlines():
                key, value = line.split(":", 1)
                if key in {"MemAvailable", "MemFree"}:
                    memory[key] = int(value.split()[0]) / 1024**2
            row = {"elapsed_seconds": time.monotonic() - started, "memory_gib": memory}
            try:
                text = subprocess.check_output(["nvidia-smi", "--query-gpu=temperature.gpu,power.draw",
                                                "--format=csv,noheader,nounits"], text=True, timeout=3)
                temperature, power = (value.strip() for value in text.splitlines()[0].split(","))
                row["gpu"] = {"temperature_c": float(temperature), "power_w": float(power)}
            except (OSError, ValueError, subprocess.SubprocessError):
                row["gpu"] = None
            handle.write(json.dumps(row) + "\n")
            handle.flush()
            stop.wait(1)


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
        for depth in DEPTHS:
            text, repeats = build_prompt(depth)
            result = ask(text)
            result.update(target_tokens=depth, repeats=repeats,
                          needle_ok="6183" in result["content"], prompt_chars=len(text))
            results.append(result)
            if not active():
                raise RuntimeError("model service failed during long-context check")
    finally:
        stop.set()
        sampler.join()
    telemetry = [json.loads(line) for line in (output / "telemetry.jsonl").read_text().splitlines()]
    gpu = [row["gpu"] for row in telemetry if row["gpu"]]
    summary = {
        "profile": PROFILE,
        "depths": DEPTHS,
        "results": [{"target_tokens": row["target_tokens"], "prompt_tokens": (row["usage"] or {}).get("prompt_tokens"),
                     "completion_tokens": (row["usage"] or {}).get("completion_tokens"),
                     "finish_reason": row["finish_reason"], "needle_ok": row["needle_ok"],
                     "content": row["content"], "wall_seconds": row["wall_seconds"], "error": row.get("error")}
                    for row in results],
        "minimum_available_gib": min(row["memory_gib"]["MemAvailable"] for row in telemetry),
        "maximum_gpu_temperature_c": max(row["temperature_c"] for row in gpu) if gpu else None,
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (output / "completed.json").write_text(json.dumps(
        {"status": "completed", "finished_at": datetime.datetime.now(datetime.timezone.utc).isoformat()},
        indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main(sys.argv)
