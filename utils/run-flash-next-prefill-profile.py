import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


BASE = "http://127.0.0.1:8890"
MODEL = "qwen3.8-flash-next-thor"
CONTAINER = "thor-flash-next"
FILLER = ("The northern warehouse receives shipments every morning and the clerks record each crate "
          "in a ledger before moving it to the riverside depot where barges wait. ")
NEEDLE = "IMPORTANT NOTE: the vault code is six one eight three. "
QUESTION = "What is the vault code? Reply with only the four digits, no other text."


def post_json(path, body, timeout=900):
    request = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode()[:300]
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()[:300]


def ask(text, max_tokens=8, timeout=900):
    body = {"model": MODEL, "messages": [{"role": "user", "content": text}], "max_tokens": max_tokens,
            "temperature": 0, "chat_template_kwargs": {"enable_thinking": False}}
    request = urllib.request.Request(BASE + "/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.load(response)
    return time.monotonic() - started, payload


def main():
    if len(sys.argv) < 2:
        print("Usage: %s OUTPUT_DIR [DEPTH]" % sys.argv[0], file=sys.stderr)
        return 2
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    depth = int(sys.argv[2]) if len(sys.argv) > 2 else 64000
    repeats = max(1, depth // 30)
    half = repeats // 2
    text = (FILLER * half) + NEEDLE + (FILLER * (repeats - half)) + QUESTION

    status, body = post_json("/start_profile", {})
    if status != 200:
        raise RuntimeError("start_profile failed: %s %s" % (status, body))
    wall, payload = ask(text)
    usage = payload.get("usage")
    content = payload["choices"][0]["message"].get("content")
    status, body = post_json("/stop_profile", {})
    if status != 200:
        raise RuntimeError("stop_profile failed: %s %s" % (status, body))
    print("ask wall=%.3f prompt_tokens=%s content=%r" % (wall, (usage or {}).get("prompt_tokens"), content))

    listed = subprocess.run(["docker", "exec", CONTAINER, "bash", "-lc",
                             "ls -1t /tmp/*.trace.json.gz 2>/dev/null | head -1"],
                            capture_output=True, text=True)
    trace = listed.stdout.strip()
    if trace:
        destination = output / "prefill.trace.json.gz"
        subprocess.run(["docker", "cp", "%s:%s" % (CONTAINER, trace), str(destination)], check=True)
        print("copied trace %s -> %s" % (trace, destination))
    else:
        print("no trace file found in container /tmp")
    (output / "request.json").write_text(json.dumps({"wall_seconds": wall, "usage": usage, "content": content,
                                                     "depth": depth}, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
