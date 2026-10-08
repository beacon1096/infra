#!/usr/bin/env python3
"""Prepare or explicitly run C1 Thor benchmarks without managing model services.

Default: validate public assets offline. `plan` emits requests and a runtime-record
template without network access. `run` requires an operator-supplied runtime
record, endpoint and model; records are attestations, not live verification.
Authentication is read only from THOR_BENCHMARK_API_KEY (or --api-key-env).
JSONL omits endpoints, credentials and response text unless --include-response
is requested for private manual review. No generated Python or tools are executed.
Payload intervals are SSE-event intervals, not token TPOT. Missing server
acceptance, telemetry and cache counters are not estimated. Prefix isolation
does not flush model, PLE, disk or kernel caches, nor prove a cache miss.
"""

import argparse
import ast
import codecs
import copy
import datetime
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import socket
import statistics
import sys
import threading
import time
import urllib.parse
import uuid


ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "docs/inference/thor/benchmark"
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
REVISION = re.compile(r"[0-9a-f]{40}\Z")
METADATA_SETTINGS = {"patch_manifest", "model_pin_source", "engine_pin_source", "as_of"}
MAX_EVENT_BYTES = 1024 * 1024


class ProtocolError(ValueError):
    pass


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=True,
                                     separators=(",", ":")).encode()).hexdigest()


def unique_object(pairs):
    value = dict(pairs)
    if len(value) != len(pairs):
        raise ValueError("duplicate_json_key")
    return value


def load_json(path):
    with Path(path).open(encoding="utf-8") as handle:
        return json.load(handle, object_pairs_hook=unique_object)


def check_messages(messages):
    if not isinstance(messages, list) or not messages:
        raise ValueError("messages must be a nonempty list")
    for message in messages:
        if message.get("role") not in {"system", "user", "assistant", "tool"}:
            raise ValueError("unsupported message role")
        if not isinstance(message.get("content"), str):
            raise ValueError("fixtures must contain text messages")


def check_gate(gate):
    if not isinstance(gate, dict):
        raise ValueError("invalid correctness gate")
    kind = gate.get("kind")
    if kind == "ledger" and set(gate) == {"kind", "initial_balance", "transactions"}:
        transactions = gate["transactions"]
        if (type(gate["initial_balance"]) is int and isinstance(transactions, list) and transactions
                and all(isinstance(item, dict) and set(item) == {"id", "amount"}
                        and type(item["id"]) is int and type(item["amount"]) is int for item in transactions)
                and len({item["id"] for item in transactions}) == len(transactions)):
            return
    if kind == "sequence" and set(gate) == {"kind", "rows", "text"}:
        if (type(gate["rows"]) is int and gate["rows"] > 0
                and isinstance(gate["text"], str) and gate["text"]
                and "\n" not in gate["text"] and "\r" not in gate["text"]):
            return
    if kind == "exact" and isinstance(gate.get("expected"), str):
        return
    if kind == "json" and isinstance(gate.get("expected"), dict):
        return
    if kind == "tool" and isinstance(gate.get("name"), str) and isinstance(gate.get("arguments"), dict):
        return
    if kind == "python_ast" and isinstance(gate.get("function"), str):
        count = gate.get("minimum_asserts")
        if type(count) is int and count >= 0:
            return
    if kind == "python_exec":
        allowed = {"kind", "function", "minimum_asserts", "tests"}
        if (set(gate) <= allowed
                and isinstance(gate.get("function"), str) and gate["function"]
                and isinstance(gate.get("tests"), list) and gate["tests"]
                and all(isinstance(t, dict) and set(t) == {"call", "expected"}
                        and isinstance(t["call"], str) and t["call"]
                        for t in gate["tests"])
                and ("minimum_asserts" not in gate
                     or (type(gate["minimum_asserts"]) is int and gate["minimum_asserts"] >= 0))):
            return
    if kind == "manual" and gate.get("criteria") and all(isinstance(x, str) for x in gate["criteria"]):
        return
    if kind == "natural_prose" and set(gate) <= {"kind", "min_chars", "required_suffix"} and "min_chars" in gate:
        if (type(gate["min_chars"]) is int and gate["min_chars"] > 0
                and ("required_suffix" not in gate
                     or (isinstance(gate["required_suffix"], str) and gate["required_suffix"]))):
            return
    if kind == "none":
        return
    raise ValueError("invalid correctness gate")


def load_assets(fixtures_path=ASSETS / "fixtures.json", profiles_path=ASSETS / "profiles.json"):
    fixtures, profiles = load_json(fixtures_path), load_json(profiles_path)
    for asset, key in ((fixtures, "cases"), (profiles, "profiles")):
        if type(asset.get("schema_version")) is not int or asset["schema_version"] != 1 or not isinstance(asset.get(key), list) or not asset[key]:
            raise ValueError("invalid asset schema")
        ids = [item.get("id") for item in asset[key]]
        if any(not isinstance(item, str) or not item for item in ids) or len(set(ids)) != len(ids):
            raise ValueError("asset IDs must be unique nonempty strings")
    for case in fixtures["cases"]:
        if case.get("mode") not in {"quality", "throughput", "stress", "cache"}:
            raise ValueError("invalid case mode")
        if case.get("provenance", {}).get("kind") not in {"historical-exact", "new-synthetic"}:
            raise ValueError("fixture provenance is required")
        request = case["request"]
        check_messages(request.get("messages"))
        if type(request.get("max_tokens")) is not int or request["max_tokens"] <= 0:
            raise ValueError("positive output budget is required")
        if request.get("temperature") != 0:
            raise ValueError("fixtures require explicit greedy sampling")
        template = request.get("chat_template_kwargs", {})
        if type(template.get("enable_thinking")) is not bool:
            raise ValueError("explicit template thinking switch is required")
        if template["enable_thinking"] and template.get("reasoning_effort") not in {"low", "medium", "high", "xhigh"}:
            raise ValueError("thinking effort must be inside chat_template_kwargs")
        if {"model", "stream", "reasoning_effort", "enable_thinking"} & request.keys():
            raise ValueError("model/stream are supplied by the client; thinking uses template kwargs")
        check_gate(case["check"])
        if ((case["check"]["kind"] == "sequence" and case["mode"] != "stress")
                or (case["check"]["kind"] == "ledger" and case["mode"] != "quality")
                or (case["check"]["kind"] == "natural_prose" and case["mode"] != "quality")):
            raise ValueError("invalid mode for continuous correctness gate")
        if "prefix" in case:
            prefix = case["prefix"]
            if not isinstance(prefix.get("line"), str) or type(prefix.get("repeat")) is not int or not 0 < prefix["repeat"] <= 10000:
                raise ValueError("invalid synthetic prefix")
        for followup in case.get("followups", []):
            check_messages(followup.get("messages"))
            check_gate(followup["check"])
    for profile in profiles["profiles"]:
        if profile.get("status") not in {"declared", "pending"}:
            raise ValueError("invalid profile status")
        if not isinstance(profile.get("pins"), dict) or not isinstance(profile.get("settings"), dict):
            raise ValueError("profile pins and settings are required")
        for key, value in profile["pins"].items():
            if value is not None and (not isinstance(value, str) or not value):
                raise ValueError("pins must be nonempty strings or null")
            if key in {"target_revision", "draft_revision"} and value is not None and not REVISION.fullmatch(value):
                raise ValueError("model revision must be a full immutable revision")
            if key == "image_id" and value is not None and not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
                raise ValueError("image must be pinned by SHA-256")
    return fixtures, profiles


def runtime_template(profile):
    settings = {key: value for key, value in profile["settings"].items()
                if key not in METADATA_SETTINGS and key != "model"}
    for key in ("context_length", "kv_cache_dtype", "max_running_requests", "prefix_caching"):
        settings.setdefault(key, None)
    return {"profile_id": profile["id"], "observed_at": None,
            "evidence_sha256": None, "pins": copy.deepcopy(profile["pins"]),
            "settings": settings}


def verify_runtime(profile, record):
    if not isinstance(record, dict):
        raise ValueError("runtime record must be an object")
    if record.get("profile_id") != profile["id"]:
        raise ValueError("runtime record profile mismatch")
    if not isinstance(record.get("observed_at"), str):
        raise ValueError("runtime record requires an observation timestamp")
    stamp = datetime.datetime.fromisoformat(record["observed_at"].replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        raise ValueError("observation timestamp must include a timezone")
    if not SHA256.fullmatch(str(record.get("evidence_sha256", ""))):
        raise ValueError("runtime record requires the SHA-256 of collected evidence")
    pins, settings = record.get("pins", {}), record.get("settings", {})
    if not isinstance(pins, dict) or not isinstance(settings, dict):
        raise ValueError("runtime pins/settings must be objects")
    for key in ("engine", "engine_revision", "image_id", "target_repository", "target_revision"):
        if not isinstance(pins.get(key), str) or pins[key] in {"", "unknown", "latest"}:
            raise ValueError("runtime record has unresolved pins")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", pins["image_id"]) or not REVISION.fullmatch(pins["target_revision"]):
        raise ValueError("runtime image and target must be immutable")
    if not REVISION.fullmatch(pins["engine_revision"]):
        raise ValueError("runtime engine must have a full immutable Git revision")
    for key, expected in profile["pins"].items():
        if expected not in (None, "unknown") and pins.get(key) != expected:
            raise ValueError("runtime pins disagree with the selected profile")
    if pins.get("draft_repository") and not REVISION.fullmatch(str(pins.get("draft_revision", ""))):
        raise ValueError("runtime draft must have an immutable revision")
    for key, expected in runtime_template(profile)["settings"].items():
        if settings.get(key) is None or (expected is not None and (type(settings[key]) is not type(expected) or settings[key] != expected)):
            raise ValueError("runtime settings are missing or disagree with the profile")
    for key in ("context_length", "max_running_requests"):
        if type(settings[key]) is not int or settings[key] <= 0:
            raise ValueError("runtime capacity must be a positive integer")
    if not isinstance(settings["kv_cache_dtype"], str) or not settings["kv_cache_dtype"]:
        raise ValueError("runtime KV dtype must be explicitly observed")
    if type(settings["prefix_caching"]) is not bool:
        raise ValueError("prefix caching must be explicitly observed")
    if profile["settings"].get("dense_dtype") == "fp8":
        if not SHA256.fullmatch(str(settings.get("conversion_artifact_sha256", ""))):
            raise ValueError("FP8 conversion artifact is not pinned")
        if settings.get("conversion_source_revision") != pins["target_revision"]:
            raise ValueError("FP8 conversion must use the pinned target revision")


def iter_sse(chunks):
    decoder = codecs.getincrementaldecoder("utf-8")("strict")
    buffer, data, event, event_size = "", [], "message", 0
    for chunk in chunks:
        buffer += decoder.decode(chunk)
        while "\n" in buffer:
            line, buffer = buffer.split("\n", 1)
            line = line.removesuffix("\r")
            event_size += len(line.encode())
            if event_size > MAX_EVENT_BYTES:
                raise ProtocolError("sse_event_too_large")
            if not line:
                if data:
                    yield event, "\n".join(data)
                data, event, event_size = [], "message", 0
            elif line.startswith("data:"):
                data.append(line[5:].removeprefix(" "))
            elif line.startswith("event:"):
                event = line[6:].strip()
        if event_size + len(buffer.encode()) > MAX_EVENT_BYTES:
            raise ProtocolError("sse_event_too_large")
    buffer += decoder.decode(b"", final=True)
    if buffer or data:
        raise ProtocolError("truncated_sse_event")


def collect_stream(events, start, clock=time.monotonic):
    content, reasoning, tools, payload_times = [], [], {}, []
    first_content = first_reasoning = first_tool = None
    usage, finish_reason, done = None, None, False
    for event, data in events:
        elapsed = clock() - start
        if event == "error":
            raise ProtocolError("server_stream_error")
        if data == "[DONE]":
            done = True
            break
        try:
            chunk = json.loads(data, object_pairs_hook=unique_object)
        except ValueError as error:
            raise ProtocolError("invalid_stream_json") from error
        if not isinstance(chunk, dict) or "error" in chunk:
            raise ProtocolError("server_stream_error")
        if chunk.get("usage") is not None:
            if not isinstance(chunk["usage"], dict):
                raise ProtocolError("invalid_usage")
            usage = usage or {}
            for key in ("prompt_tokens", "completion_tokens", "total_tokens", "reasoning_tokens"):
                value = chunk["usage"].get(key)
                if type(value) is int and value >= 0:
                    usage[key] = value
            for key in ("prompt_tokens_details", "completion_tokens_details"):
                details = chunk["usage"].get(key)
                if isinstance(details, dict):
                    usage[key] = {name: value for name, value in details.items()
                                  if name in {"cached_tokens", "reasoning_tokens", "audio_tokens", "accepted_prediction_tokens", "rejected_prediction_tokens"}
                                  and type(value) is int and value >= 0}
        generated = False
        choices = chunk.get("choices", [])
        if not isinstance(choices, list) or len(choices) > 1:
            raise ProtocolError("multiple_choices_not_supported")
        for choice in choices:
            if not isinstance(choice, dict):
                raise ProtocolError("invalid_choice")
            if choice.get("index", 0) != 0:
                raise ProtocolError("multiple_choices_not_supported")
            delta = choice.get("delta")
            if delta is None:
                delta = {}
            if not isinstance(delta, dict):
                raise ProtocolError("invalid_delta")
            for field, parts in (("content", content), ("reasoning_content", reasoning), ("reasoning", reasoning)):
                text = delta.get(field)
                if text is not None:
                    if not isinstance(text, str):
                        raise ProtocolError("nontext_delta")
                    if not text:
                        continue
                    parts.append(text)
                    generated = True
                    if field == "content" and first_content is None:
                        first_content = elapsed
                    elif field != "content" and first_reasoning is None:
                        first_reasoning = elapsed
            fragments = delta.get("tool_calls")
            if fragments is None:
                fragments = []
            if not isinstance(fragments, list):
                raise ProtocolError("invalid_tool_calls")
            for fragment in fragments:
                if not isinstance(fragment, dict):
                    raise ProtocolError("invalid_tool_fragment")
                index = fragment.get("index")
                if type(index) is not int or index < 0:
                    raise ProtocolError("invalid_tool_index")
                tool = tools.setdefault(index, {"id": "", "type": "function", "function": {"name": "", "arguments": ""}})
                if fragment.get("id") is not None and not isinstance(fragment["id"], str):
                    raise ProtocolError("invalid_tool_id")
                if fragment.get("id"):
                    tool["id"] = fragment["id"]
                function = fragment.get("function")
                if function is None:
                    function = {}
                if not isinstance(function, dict):
                    raise ProtocolError("invalid_tool_function")
                for key in ("name", "arguments"):
                    text = function.get(key)
                    if text is not None:
                        if not isinstance(text, str):
                            raise ProtocolError("nontext_tool_delta")
                        if not text:
                            continue
                        tool["function"][key] += text
                        generated = True
                        if first_tool is None:
                            first_tool = elapsed
            if choice.get("finish_reason") is not None:
                if not isinstance(choice["finish_reason"], str) or choice["finish_reason"] not in {"stop", "length", "tool_calls", "content_filter", "function_call"}:
                    raise ProtocolError("invalid_finish_reason")
                finish_reason = choice["finish_reason"]
        if generated:
            payload_times.append(elapsed)
    elapsed = clock() - start
    if not done or finish_reason is None:
        raise ProtocolError("incomplete_stream")
    intervals = [right - left for left, right in zip(payload_times, payload_times[1:])]
    sorted_intervals = sorted(intervals)
    completion = (usage or {}).get("completion_tokens")
    if type(completion) is not int or completion < 0:
        completion = None
    root_reasoning = (usage or {}).get("reasoning_tokens")
    detail_reasoning = ((usage or {}).get("completion_tokens_details") or {}).get("reasoning_tokens")
    reasoning_source = None
    if root_reasoning is not None and detail_reasoning is not None:
        reasoning_source = "both" if root_reasoning == detail_reasoning else "conflict"
    elif root_reasoning is not None:
        reasoning_source = "root"
    elif detail_reasoning is not None:
        reasoning_source = "completion_tokens_details"
    reasoning_tokens = root_reasoning if root_reasoning is not None else detail_reasoning
    if reasoning_source == "conflict":
        reasoning_tokens = None
    if type(reasoning_tokens) is not int or completion is None or not 0 <= reasoning_tokens <= completion:
        reasoning_tokens = None
    first_final = min((x for x in (first_content, first_tool) if x is not None), default=None)
    estimate = None
    if completion is not None and completion > 1 and first_content is not None and not reasoning and not root_reasoning and not detail_reasoning and not tools and elapsed > first_content:
        estimate = (completion - 1) / (elapsed - first_content)
    return {
        "content": "".join(content), "reasoning_content": "".join(reasoning),
        "tool_calls": [tools[index] for index in sorted(tools)], "usage": usage,
        "finish_reason": finish_reason,
        "metrics": {
            "first_generation_seconds": payload_times[0] if payload_times else None,
            "first_reasoning_seconds": first_reasoning, "first_content_seconds": first_content,
            "first_tool_seconds": first_tool, "first_final_seconds": first_final,
            "wall_seconds": elapsed, "payload_events": len(payload_times),
            "payload_interval_p50_seconds": statistics.median(intervals) if intervals else None,
            "payload_interval_p95_seconds": sorted_intervals[math.ceil(0.95 * len(intervals)) - 1] if intervals else None,
            "payload_interval_max_seconds": max(intervals) if intervals else None,
            "completion_tokens_reported": completion, "reasoning_tokens_reported": reasoning_tokens,
            "reasoning_tokens_source": reasoning_source,
            "non_reasoning_tokens_reported": completion - reasoning_tokens if reasoning_tokens is not None else None,
            "end_to_end_tokens_per_second": completion / elapsed if completion is not None and elapsed > 0 else None,
            "content_decode_tokens_per_second_estimate": estimate,
            "token_tpot_seconds": None, "speculative_acceptance": None,
            "telemetry": None,
        },
    }


PYEXEC_TIMEOUT = 15


def extract_python_source(text):
    """Return the code from the first fenced block, or the whole text if unfenced."""
    fence = re.search(r"```[a-zA-Z0-9_+-]*\s*\n(.*?)```", text, re.S)
    return fence.group(1) if fence else text


def run_python_tests(code, tests):
    """Execute ``code`` in a best-effort sandbox and return the per-test booleans.

    Results are JSON-normalized before comparison, so a tuple result compares
    equal to a JSON-list ``expected`` (container type is not part of the task).
    Sandbox = isolated interpreter (``-I``), empty env, temp cwd, CPU/AS/FSIZE/
    NOFILE rlimits and a wall-clock timeout. This bounds runaway loops/OOM from
    our own model's generations; it is not a hard security boundary against
    adversarial code. Returns ``None`` if the code failed to run.
    """
    import resource
    import subprocess
    import sys
    import tempfile

    harness = (
        "import json as _j\n"
        + code
        + "\n\n_tests = _j.loads(r'''" + json.dumps(tests) + "''')\n"
        + "_out = []\n"
        + "for _t in _tests:\n"
        + "    try:\n"
        + "        _got = eval(_t['call'], globals())\n"
        + "        _out.append(bool(_j.loads(_j.dumps(_got, default=str)) == _t['expected']))\n"
        + "    except Exception:\n"
        + "        _out.append(False)\n"
        + "print('__PYEXEC__' + _j.dumps(_out))\n"
    )

    def limits():
        resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
        resource.setrlimit(resource.RLIMIT_AS, (2 << 30, 2 << 30))
        resource.setrlimit(resource.RLIMIT_FSIZE, (1 << 20, 1 << 20))
        resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))

    with tempfile.TemporaryDirectory() as workdir:
        try:
            proc = subprocess.run([sys.executable, "-I", "-"], input=harness.encode(),
                                  capture_output=True, timeout=PYEXEC_TIMEOUT, cwd=workdir,
                                  env={"LANG": "C.UTF-8"}, preexec_fn=limits)
        except subprocess.TimeoutExpired:
            return None
    if proc.returncode != 0:
        return None
    for line in proc.stdout.decode(errors="replace").splitlines():
        if line.startswith("__PYEXEC__"):
            return json.loads(line[len("__PYEXEC__"):])
    return None


def correctness(gate, response, mode):
    kind, text = gate["kind"], response["content"]
    if kind in {"ledger", "sequence"}:
        failed = {"status": "failed", "scope": kind, "full_task_completed": False}
        finish = response["finish_reason"]
        if response["tool_calls"] or not text:
            return failed
        if kind == "ledger":
            if mode != "quality" or finish != "stop":
                return failed
            lines = text.split("\n")
            if lines[-1] == "":
                lines.pop()
            if len(lines) != len(gate["transactions"]):
                return failed
            balance, checksum = gate["initial_balance"], 0
            try:
                for seq, (line, transaction) in enumerate(zip(lines, gate["transactions"]), 1):
                    row = json.loads(line, object_pairs_hook=unique_object)
                    balance += transaction["amount"]
                    checksum += balance
                    if (not isinstance(row, dict) or set(row) != {"seq", "id", "balance"}
                            or any(type(value) is not int for value in row.values())
                            or row != {"seq": seq, "id": transaction["id"], "balance": balance}):
                        return failed
            except (ValueError, TypeError):
                return failed
            return {"status": "passed", "scope": "ledger", "full_task_completed": True,
                    "rows_checked": len(lines), "balance_checksum": checksum}
        if mode != "stress" or finish not in {"stop", "length"}:
            return failed
        lines = text.split("\n")
        if lines[-1] == "":
            lines.pop()
        complete = 0
        for index, line in enumerate(lines, 1):
            expected = f"RECORD {index}: {gate['text']}"
            if index > gate["rows"]:
                return failed
            if line == expected:
                complete += 1
            elif not (finish == "length" and index == len(lines) and not text.endswith("\n")
                      and line and expected.startswith(line)):
                return failed
        full = complete == gate["rows"]
        if not full and finish != "length":
            return failed
        return {"status": "passed", "scope": "sequence" if full else "valid_prefix",
                "full_task_completed": full, "rows_checked": complete}
    if kind == "none":
        return {"status": "not_checked", "scope": "throughput_only"}
    if kind == "natural_prose":
        natural = response["finish_reason"] == "stop"
        suffix_ok = "required_suffix" not in gate or text.rstrip().endswith(gate["required_suffix"])
        passed = natural and not response["tool_calls"] and len(text) >= gate["min_chars"] and suffix_ok
        result = {"status": "passed" if passed else "failed", "scope": "natural_prose",
                  "chars": len(text), "natural_stop": natural}
        if not passed:
            result["reason"] = "incomplete_generation" if not natural else "gate_mismatch"
        return result
    if response["finish_reason"] not in {"stop", "tool_calls"} and mode != "stress":
        return {"status": "failed", "scope": kind, "reason": "incomplete_generation"}
    if not text and not response["tool_calls"]:
        return {"status": "failed", "scope": kind, "reason": "no_final_output"}
    if kind == "manual":
        return {"status": "needs_review", "scope": "manual", "criteria": gate["criteria"]}
    passed = False
    detail = {}
    try:
        if kind == "exact":
            passed = text == gate["expected"] and not response["tool_calls"]
        elif kind == "json":
            passed = digest(json.loads(text, object_pairs_hook=unique_object)) == digest(gate["expected"]) and not response["tool_calls"]
        elif kind == "tool":
            calls = response["tool_calls"]
            passed = (len(calls) == 1 and not text.strip()
                      and calls[0]["function"]["name"] == gate["name"]
                      and digest(json.loads(calls[0]["function"]["arguments"], object_pairs_hook=unique_object)) == digest(gate["arguments"]))
        elif kind in {"python_ast", "python_exec"}:
            code = extract_python_source(text)
            tree = ast.parse(code)
            ast_ok = (not response["tool_calls"]
                      and any(isinstance(node, ast.FunctionDef) and node.name == gate["function"] for node in tree.body)
                      and sum(isinstance(node, ast.Assert) for node in ast.walk(tree)) >= gate.get("minimum_asserts", 0))
            if kind == "python_ast":
                passed = ast_ok
            else:
                results = run_python_tests(code, gate["tests"]) if ast_ok else None
                detail = {"tests_passed": sum(results) if results else 0, "tests_total": len(gate["tests"])}
                passed = bool(ast_ok and results is not None and all(results))
    except (ValueError, SyntaxError, TypeError):
        passed = False
    result = {"status": "passed" if passed else "failed", "scope": "syntax_only" if kind == "python_ast" else kind}
    if kind == "python_exec":
        result.update(detail)
    return result


def build_request(case, model, isolation=None, seed=None):
    request = copy.deepcopy(case["request"])
    if seed is not None:
        request["seed"] = seed
    if "prefix" in case:
        request["messages"][0]["content"] = case["prefix"]["line"] * case["prefix"]["repeat"] + request["messages"][0]["content"]
    if isolation is not None:
        request["messages"].insert(0, {"role": "system", "content": f"Benchmark isolation label: {isolation}. Ignore this label when answering."})
    request.update(model=model, stream=True, stream_options={"include_usage": True})
    return request


def validate_url(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("base URL must be HTTP(S), with no credentials, query or fragment")
    return parsed


def stream_request(base_url, request, api_key=None, idle_timeout=60, deadline=600):
    parsed = validate_url(base_url)
    connection_class = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
    connection = connection_class(parsed.hostname, parsed.port, timeout=min(idle_timeout, deadline))
    headers = {"Content-Type": "application/json", "Accept": "text/event-stream"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    timer = response = None
    start = time.monotonic()
    expired = threading.Event()
    try:
        addresses, resolver_errors = [], []
        resolved = threading.Event()

        def resolve():
            try:
                addresses.extend(socket.getaddrinfo(parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80), type=socket.SOCK_STREAM))
            except OSError as error:
                resolver_errors.append(error)
            finally:
                resolved.set()

        resolver = threading.Thread(target=resolve, daemon=True)
        resolver.start()
        if not resolved.wait(max(0, deadline - (time.monotonic() - start))):
            raise TimeoutError("dns_deadline")
        if resolver_errors:
            raise resolver_errors[0]

        def connect_bounded(address, timeout, source_address=None):
            last_error = None
            for family, kind, protocol, _, target in addresses:
                remaining = deadline - (time.monotonic() - start)
                if remaining <= 0:
                    raise TimeoutError("connect_deadline")
                transport = socket.socket(family, kind, protocol)
                try:
                    transport.settimeout(min(idle_timeout, remaining))
                    if source_address:
                        transport.bind(source_address)
                    transport.connect(target)
                    remaining = deadline - (time.monotonic() - start)
                    if remaining <= 0:
                        raise TimeoutError("connect_deadline")
                    transport.settimeout(min(idle_timeout, remaining))
                    return transport
                except OSError as error:
                    last_error = error
                    transport.close()
                except BaseException:
                    transport.close()
                    raise
            if last_error:
                raise last_error
            raise OSError("no_resolved_address")

        # HTTPConnection's hook keeps its HTTP/TLS handling while bounding DNS
        # and all address attempts by one wall budget. DNS workers own no socket.
        connection._create_connection = connect_bounded
        connection.connect()
        transport = connection.sock

        def interrupt():
            expired.set()
            try:
                transport.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        remaining = deadline - (time.monotonic() - start)
        if remaining <= 0:
            raise TimeoutError("deadline")
        timer = threading.Timer(remaining, interrupt)
        timer.daemon = True
        timer.start()
        connection.request("POST", parsed.path.rstrip("/") + "/chat/completions",
                           json.dumps(request, ensure_ascii=True).encode(), headers)
        response = connection.getresponse()
        if response.status != 200:
            raise ProtocolError(f"http_status_{response.status}")
        if response.getheader("Content-Type", "").split(";")[0].strip().lower() != "text/event-stream":
            raise ProtocolError("expected_sse_content_type")

        def chunks():
            while True:
                remaining = deadline - (time.monotonic() - start)
                if remaining <= 0 or expired.is_set():
                    raise TimeoutError("deadline")
                transport.settimeout(min(idle_timeout, remaining))
                chunk = response.read1(65536)
                if not chunk:
                    if expired.is_set():
                        raise TimeoutError("deadline")
                    return
                yield chunk

        result = collect_stream(iter_sse(chunks()), start)
        if expired.is_set():
            raise TimeoutError("deadline")
        return result
    finally:
        if timer:
            timer.cancel()
        if response is not None:
            response.close()
        connection.close()


def select_cases(fixtures, names, suite):
    cases = fixtures["cases"]
    if names:
        unknown = set(names) - {case["id"] for case in cases}
        if unknown:
            raise ValueError("unknown case ID")
        return [case for case in cases if case["id"] in names]
    if suite == "smoke":
        return [case for case in cases if case["id"] in {"exact-short-output", "strict-json-schema", "tool-get-weather"}]
    return [case for case in cases if suite == "all" or case["mode"] == {"historical": "throughput"}.get(suite, suite)]


def source_hashes(profile):
    sources = [profile["source"]] + [value for key, value in profile["settings"].items() if key in METADATA_SETTINGS and key != "as_of"]
    hashes = {}
    for source in sources:
        if source.startswith("https://"):
            continue
        path = (ROOT / source).resolve()
        if not path.is_relative_to(ROOT):
            raise ValueError("profile source must stay inside the public repository")
        hashes[source] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", nargs="?", choices=("validate", "plan", "run"), default="validate")
    parser.add_argument("--fixtures", type=Path, default=ASSETS / "fixtures.json")
    parser.add_argument("--profiles", type=Path, default=ASSETS / "profiles.json")
    parser.add_argument("--profile", default="P")
    parser.add_argument("--case", action="append", dest="cases")
    parser.add_argument("--suite", choices=("smoke", "quality", "historical", "stress", "cache", "all"), default="smoke")
    parser.add_argument("--model")
    parser.add_argument("--seed", type=int, default=None, help="Explicit sampling seed for paired runs")
    parser.add_argument("--base-url", help="Explicit OpenAI base URL including /v1; never stored in results")
    parser.add_argument("--runtime-record", type=Path, help="Observed deployment record; obtain the template from plan")
    parser.add_argument("--route", choices=("backend", "gateway"), default="backend")
    parser.add_argument("--api-key-env", default="THOR_BENCHMARK_API_KEY")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--idle-timeout", type=float, default=60)
    parser.add_argument("--deadline", type=float, default=600, help="Per-request wall deadline in seconds")
    parser.add_argument("--cache-policy", choices=("isolated-prefix", "shared-prefix"), default="isolated-prefix")
    parser.add_argument("--include-response", action="store_true", help="Include generated text for PRIVATE manual review; never commit result JSONL")
    args = parser.parse_args(argv)
    try:
        fixtures, profiles = load_assets(args.fixtures, args.profiles)
        profile = next((item for item in profiles["profiles"] if item["id"] == args.profile), None)
        if profile is None:
            raise ValueError("unknown profile ID")
        hashes = source_hashes(profile)
        cases = select_cases(fixtures, args.cases, args.suite)
        if args.command != "validate" and not cases:
            raise ValueError("no cases selected; specify --case or a matching --suite")
        if args.repeats <= 0 or args.warmups < 0 or not all(math.isfinite(x) and x > 0 for x in (args.idle_timeout, args.deadline)):
            raise ValueError("invalid repeat or timeout settings")
        model = args.model or profile["settings"].get("model")
        if args.command == "validate":
            print(json.dumps({"schema_version": 1, "status": "valid", "case_count": len(fixtures["cases"]),
                              "profiles": {item["id"]: item["status"] for item in profiles["profiles"]},
                              "fixture_sha256": digest(fixtures), "profile_sha256": digest(profile), "source_sha256": hashes}))
            return 0
        if not model:
            raise ValueError("plan/run require --model when a served name is unknown")
        if args.command == "plan":
            print(json.dumps({"schema_version": 1, "profile": profile, "runtime_record_template": runtime_template(profile),
                              "source_sha256": hashes, "warmups": args.warmups, "repeats": args.repeats,
                               "cache_policy": args.cache_policy, "route": args.route,
                               **({"seed": args.seed} if args.seed is not None else {}),
                              "idle_timeout": args.idle_timeout, "deadline": args.deadline,
                              "maximum_completion_budget": sum(case["request"]["max_tokens"] * (1 + len(case.get("followups", []))) for case in cases) * (args.repeats + args.warmups),
                               "cases": [{"id": case["id"], "request": build_request(case, model, f"PLAN:{case['id']}:<iteration>" if args.cache_policy == "isolated-prefix" else None, seed=args.seed),
                                         "check": case["check"], "followups": case.get("followups", [])} for case in cases]}, ensure_ascii=True))
            return 0
        if not args.base_url or not args.runtime_record or not args.model:
            raise ValueError("run requires explicit --base-url, --model and --runtime-record")
        validate_url(args.base_url)
        runtime = load_json(args.runtime_record)
        verify_runtime(profile, runtime)
        run_id = uuid.uuid4().hex
        print(json.dumps({"schema_version": 1, "type": "run", "run_id": run_id, "profile_id": profile["id"],
                          "fixture_sha256": digest(fixtures), "profile_sha256": digest(profile),
                          "runtime_record_sha256": digest(runtime), "source_sha256": hashes,
                          "model": model, "route": args.route, "cache_policy": args.cache_policy,
                          **({"seed": args.seed} if args.seed is not None else {}),
                          "warmups": args.warmups, "repeats": args.repeats,
                          "idle_timeout": args.idle_timeout, "deadline": args.deadline,
                          "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}), flush=True)
        for case in cases:
            for iteration in range(args.warmups + args.repeats):
                phase = "warmup" if iteration < args.warmups else "measured"
                isolation = f"{run_id}:{case['id']}:{iteration}" if args.cache_policy == "isolated-prefix" else None
                request = build_request(case, model, isolation, seed=args.seed)
                turns = [{"check": case["check"]}] + case.get("followups", [])
                for turn, spec in enumerate(turns):
                    if turn:
                        request["messages"].extend(copy.deepcopy(spec["messages"]))
                    record = {"schema_version": 1, "type": "request", "run_id": run_id, "case_id": case["id"],
                              "phase": phase, "iteration": iteration, "turn": turn,
                              "request_sha256": digest(request), "mode": case["mode"]}
                    attempt_start = time.monotonic()
                    try:
                        response = stream_request(args.base_url, request, os.environ.get(args.api_key_env), args.idle_timeout, args.deadline)
                        gate = correctness(spec["check"], response, case["mode"])
                        thinking_observed = bool(response["reasoning_content"] or
                                                 (response["usage"] or {}).get("reasoning_tokens") or
                                                 ((response["usage"] or {}).get("completion_tokens_details") or {}).get("reasoning_tokens"))
                        if request["chat_template_kwargs"]["enable_thinking"]:
                            response["metrics"]["content_decode_tokens_per_second_estimate"] = None
                        elif thinking_observed:
                            gate = {"status": "failed", "reason": "thinking_disabled_but_observed"}
                        record.update(status="completed", metrics=response["metrics"], usage=response["usage"],
                                      finish_reason=response["finish_reason"], correctness=gate,
                                      response_sha256=digest({key: response[key] for key in ("content", "reasoning_content", "tool_calls")}),
                                      thinking_observed=thinking_observed)
                        if args.include_response:
                            record["response"] = {key: response[key] for key in ("content", "reasoning_content", "tool_calls")}
                        print(json.dumps(record, ensure_ascii=True), flush=True)
                        if gate["status"] == "failed":
                            return 1
                        assistant = {"role": "assistant", "content": response["content"]}
                        if response["reasoning_content"]:
                            assistant["reasoning_content"] = response["reasoning_content"]
                        if response["tool_calls"]:
                            assistant["tool_calls"] = response["tool_calls"]
                        request["messages"].append(assistant)
                    except KeyboardInterrupt:
                        record.update(status="cancelled", error="client_interrupted",
                                      metrics={"wall_seconds": time.monotonic() - attempt_start},
                                      correctness={"status": "not_checked"})
                        print(json.dumps(record), flush=True)
                        return 130
                    except (ProtocolError, OSError, http.client.HTTPException, UnicodeError, ValueError) as error:
                        code = str(error) if isinstance(error, ProtocolError) else type(error).__name__
                        record.update(status="error", error=code,
                                      metrics={"wall_seconds": time.monotonic() - attempt_start},
                                      correctness={"status": "not_checked"})
                        print(json.dumps(record), flush=True)
                        return 1
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"benchmark preflight failed: {type(error).__name__}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
