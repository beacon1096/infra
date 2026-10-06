"""Long autoregressive generation test for recurrent-state drift.

Sends one thinking-off, single-language, ignore-EOS request for a fixed token
budget, captures the streamed text, and reports anomaly indicators:
target-language purity, first foreign-script position, duplicate-line count,
longest identical-symbol run, and finish reason. Behavioural probe only; it does
not isolate the numeric mechanism (that would need teacher-forced state dumps).

Usage: run-thor-state-drift.py BASE_URL MODEL OUTPUT_DIR LANG TOKENS
  LANG in {en, zh}
"""

import collections
import http.client
import json
import sys
import time
import urllib.parse
from pathlib import Path

PROMPTS = {
    "en": ("Write a detailed, continuous technical reference about how Earth's water cycle connects "
           "the oceans, atmosphere, land and groundwater, and how human activity affects it. "
           "Use only English. Do not stop, summarise, or switch language; keep expanding the text."),
    "zh": ("请写一篇详尽的连续技术说明文，介绍地球水循环如何连接海洋、大气、陆地和地下水，"
           "以及人类活动的影响。只使用中文，不要停止、不要总结、不要切换语言，持续展开正文。"),
}

RANGES = {
    "cjk": [(0x4E00, 0x9FFF), (0x3400, 0x4DBF), (0xF900, 0xFAFF)],
    "kana": [(0x3040, 0x30FF)],
    "hangul": [(0xAC00, 0xD7A3), (0x1100, 0x11FF)],
    "cyrillic": [(0x0400, 0x04FF)],
    "arabic": [(0x0600, 0x06FF)],
    "hebrew": [(0x0590, 0x05FF)],
    "thai": [(0x0E00, 0x0E7F)],
    "devanagari": [(0x0900, 0x097F)],
}


def script_of(ch):
    code = ord(ch)
    for name, ranges in RANGES.items():
        for low, high in ranges:
            if low <= code <= high:
                return name
    return None


def analyze(text, lang):
    letters = [ch for ch in text if ch.isalpha()]
    foreign = 0
    first_foreign = None
    for index, ch in enumerate(text):
        name = script_of(ch)
        is_target = (name == "cjk") if lang == "zh" else (name is None and ch.isascii() and ch.isalpha())
        if not ch.isalpha():
            continue
        if lang == "zh":
            if name != "cjk":
                foreign += 1
                first_foreign = first_foreign if first_foreign is not None else index
        else:
            if name is not None:
                foreign += 1
                first_foreign = first_foreign if first_foreign is not None else index
    lines = [line for line in text.split("\n") if line.strip()]
    line_counts = collections.Counter(lines)
    max_duplicate_line = max(line_counts.values()) if line_counts else 0
    max_symbol_run = 0
    run = 0
    previous = None
    for ch in text:
        if ch == previous and not ch.isalnum() and not ch.isspace():
            run += 1
            max_symbol_run = max(max_symbol_run, run + 1)
        else:
            run = 0
        previous = ch
    ratio = foreign / len(letters) if letters else 0.0
    reasons = []
    if ratio > 0.001:
        reasons.append("foreign_script_ratio")
    if max_duplicate_line > 3:
        reasons.append("duplicate_lines")
    if max_symbol_run >= 20:
        reasons.append("symbol_loop")
    return {"letters": len(letters), "foreign_letters": foreign, "foreign_ratio": round(ratio, 5),
            "first_foreign_index": first_foreign, "max_duplicate_line": max_duplicate_line,
            "max_symbol_run": max_symbol_run, "anomaly": bool(reasons), "reasons": reasons}


def generate(base, model, prompt, tokens):
    parsed = urllib.parse.urlsplit(base)
    connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=600)
    body = {"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": tokens,
            "temperature": 0, "ignore_eos": True, "stream": True,
            "chat_template_kwargs": {"enable_thinking": False}}
    connection.request("POST", parsed.path + "/chat/completions", body=json.dumps(body).encode(),
                       headers={"Content-Type": "application/json", "Accept": "text/event-stream"})
    response = connection.getresponse()
    if response.status != 200:
        raise RuntimeError(f"HTTP {response.status}: {response.read()[:200]}")
    parts = []
    finish = None
    tokens_seen = 0
    started = time.monotonic()
    while True:
        line = response.fp.readline()
        if not line:
            break
        if not line.startswith(b"data: "):
            continue
        payload = line[5:].strip()
        if payload == b"[DONE]":
            break
        try:
            event = json.loads(payload)
        except ValueError:
            continue
        choices = event.get("choices") or []
        if not choices:
            continue
        delta = choices[0].get("delta") or {}
        if delta.get("content"):
            parts.append(delta["content"])
            tokens_seen += 1
        if choices[0].get("finish_reason"):
            finish = choices[0]["finish_reason"]
    connection.close()
    return "".join(parts), finish, tokens_seen, time.monotonic() - started


def main(argv):
    base, model, output, lang, tokens = argv[1], argv[2], Path(argv[3]), argv[4], int(argv[5])
    output.mkdir(parents=True, exist_ok=True)
    text, finish, tokens_seen, wall = generate(base, model, PROMPTS[lang], tokens)
    result = {"lang": lang, "target_tokens": tokens, "content_events": tokens_seen,
              "finish_reason": finish, "wall_seconds": round(wall, 2), "chars": len(text), **analyze(text, lang)}
    (output / f"drift-{lang}.json").write_text(json.dumps(result, indent=2) + "\n")
    (output / f"drift-{lang}.txt").write_text(text)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
