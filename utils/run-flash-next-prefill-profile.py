import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


BASE = "http://127.0.0.1:8890"
MODEL = "qwen3.8-flash-next-thor"
ROOT = Path("/var/lib/thor-flash-next/observations/mtp-20261005/client")
DEPTH = int(sys.argv[2]) if len(sys.argv) > 2 else 64000
FILLER = ("The northern warehouse receives shipments every morning and the clerks record each crate "
          "in a ledger before moving it to the riverside depot where barges wait. ")
NEEDLE = "IMPORTANT NOTE: the vault code is six one eight three. "
QUESTION = "What is the vault code? Reply with only the four digits, no other text."


def post_json(path, body, timeout=900):
    data = json.dumps(body).encode()
    request = urllib.request.Request(BASE + path, data=data, method="POST",
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
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    repeats = max(1, DEPTH // 30)
    half = repeats // 2
    text = (FILLER * half) + NEEDLE + (FILLER * (repeats - half)) + QUESTION
    print("start_profile:", post_json("/start_profile", {}))
    wall, payload = ask(text)
    usage = payload.get("usage")
    content = payload["choices"][0]["message"].get("content")
    print("ask wall=%.3f prompt_tokens=%s content=%r" % (wall, (usage or {}).get("prompt_tokens"), content))
    print("stop_profile:", post_json("/stop_profile", {}))
    for command in (["docker", "exec", "thor-flash-next", "bash", "-lc", "ls -la /tmp/*.trace* 2>/dev/null"],
                    ["docker", "exec", "thor-flash-next", "bash", "-lc",
                     "find /tmp -maxdepth 3 -name '*trace*' 2>/dev/null"]):
        print("$", " ".join(command))
        subprocess.run(command, check=False)
    (output / "request.json").write_text(json.dumps({"wall_seconds": wall, "usage": usage, "content": content,
                                                    "depth": DEPTH}, indent=2) + "\n")


if __name__ == "__main__":
    main()
