#!/usr/bin/env python3
import contextlib
import copy
import importlib.util
import io
import itertools
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("benchmark_thor", Path(__file__).with_name("benchmark-thor.py"))
CLIENT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLIENT)
ASSET = CLIENT.ASSETS / "thinking-stability.json"


def response(text, finish="stop", tools=None):
    return {"content": text, "reasoning_content": "", "tool_calls": tools or [], "finish_reason": finish}


def transactions(count):
    return [{"id": 1000 + 37 * i, "amount": ((i * 53) % 97) - 48} for i in range(1, count + 1)]


def ledger_rows(gate):
    balances = itertools.accumulate((item["amount"] for item in gate["transactions"]), initial=gate["initial_balance"])
    next(balances)
    return [{"seq": seq, "id": item["id"], "balance": balance}
            for seq, (item, balance) in enumerate(zip(gate["transactions"], balances), 1)]


def ndjson(rows):
    return "\n".join(json.dumps(row, separators=(",", ":")) for row in rows)


class ThinkingChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures, cls.profiles = CLIENT.load_assets(ASSET)
        cls.cases = {case["id"]: case for case in cls.fixtures["cases"]}

    def check(self, gate, text, finish="stop", mode="quality", tools=None):
        return CLIENT.correctness(gate, response(text, finish, tools), mode)

    def sequence(self, rows=500):
        return "\n".join(f"RECORD {i}: amber blue cedar delta." for i in range(1, rows + 1))

    def test_asset_counts_provenance_and_budget_limits(self):
        self.assertEqual(len(self.cases), 13)
        self.assertEqual(sum(case["id"].startswith("thinking-") for case in self.cases.values()), 9)
        self.assertEqual(sum(case["check"]["kind"] == "ledger" for case in self.cases.values()), 2)
        self.assertEqual(sum(case["check"]["kind"] == "sequence" for case in self.cases.values()), 2)
        for case in self.cases.values():
            with self.subTest(case=case["id"]):
                request = case["request"]
                self.assertEqual(case["provenance"], {"kind": "new-synthetic", "source":
                    f"docs/inference/thor/benchmark/thinking-stability.json#{case['id']}"})
                self.assertEqual(set(request), {"messages", "max_tokens", "temperature", "chat_template_kwargs"})
                self.assertEqual(len(request["messages"]), 1)
                prompt = request["messages"][0]["content"]
                self.assertTrue(prompt.isascii())
                # Byte size is a conservative public prompt bound, not a usage estimate.
                self.assertLessEqual(len(prompt.encode("ascii")), 2048)
                self.assertLessEqual(request["max_tokens"], 4096)
                self.assertEqual(request["temperature"], 0)
                self.assertNotIn("prefix", case)
                self.assertNotIn("followups", case)
                if case["check"]["kind"] == "sequence":
                    self.assertEqual(case["mode"], "stress")
                else:
                    self.assertEqual(case["mode"], "quality")
        self.assertEqual(self.cases["continuous-sequence-1536-off"]["request"]["max_tokens"], 1536)
        self.assertTrue(all(case["request"]["max_tokens"] == 4096 for case in self.cases.values()
                            if case["id"] != "continuous-sequence-1536-off"))

    def test_paired_thinking_only_changes_template_kwargs(self):
        for task in ("digit", "workers", "ledger32"):
            off = self.cases[f"thinking-{task}-off"]
            self.assertEqual(off["request"]["chat_template_kwargs"], {"enable_thinking": False})
            for effort in ("low", "medium"):
                with self.subTest(task=task, effort=effort):
                    case = self.cases[f"thinking-{task}-{effort}"]
                    expected = copy.deepcopy(off["request"])
                    expected["chat_template_kwargs"] = {"enable_thinking": True, "reasoning_effort": effort}
                    self.assertEqual(case["request"], expected)
                    self.assertEqual(case["check"], off["check"])
        for case in self.cases.values():
            if case["id"].startswith("continuous-"):
                self.assertEqual(case["request"]["chat_template_kwargs"], {"enable_thinking": False})
        self.assertEqual(self.cases["continuous-sequence-1536-off"]["request"]["messages"],
                         self.cases["continuous-sequence-4096-off"]["request"]["messages"])

    def test_digit_oracle_independent_exhaustive_enumeration(self):
        candidates = []
        for number in range(100, 1000):
            hundreds, tens, units = number // 100, number // 10 % 10, number % 10
            if hundreds + tens + units == 15 and 100 * units + 10 * tens + hundreds == number + 198 and number % 7 == 0:
                candidates.append(number)
        self.assertEqual(candidates, [294])
        for effort in ("off", "low", "medium"):
            case = self.cases[f"thinking-digit-{effort}"]
            self.assertEqual(case["check"]["expected"], {"number": min(candidates)})
            self.assertNotIn(str(min(candidates)), case["request"]["messages"][0]["content"])

    def test_worker_oracle_lower_bound_and_valid_witness(self):
        tasks = {"A": (3, ()), "B": (2, ()), "C": (4, ("A",)), "D": (3, ("B",)),
                 "E": (2, ("C", "D")), "F": (1, ("E",)), "G": (4, ("B",)), "H": (5, ("G",))}
        witness = [[("A", 0, 3), ("C", 3, 7), ("H", 7, 12)],
                   [("B", 0, 2), ("G", 2, 6), ("D", 6, 9), ("E", 9, 11), ("F", 11, 12)]]
        assignments = [item for worker in witness for item in worker]
        self.assertEqual(len(assignments), len(tasks))
        self.assertEqual({name for name, _, _ in assignments}, set(tasks))
        ends = {name: end for name, _, end in assignments}
        for worker in witness:
            for previous, current in zip(worker, worker[1:]):
                self.assertLessEqual(previous[2], current[1])
            for name, start, end in worker:
                duration, dependencies = tasks[name]
                self.assertGreaterEqual(start, 0)
                self.assertEqual(end - start, duration)
                for dependency in dependencies:
                    self.assertLessEqual(ends[dependency], start)
        total = sum(duration for duration, _ in tasks.values())
        self.assertEqual(total, 24)
        bound = (total + 1) // 2
        self.assertEqual(max(ends.values()), bound)
        for effort in ("off", "low", "medium"):
            case = self.cases[f"thinking-workers-{effort}"]
            self.assertEqual(case["check"]["expected"], {"makespan": bound})
            prompt = case["request"]["messages"][0]["content"]
            parsed = {name: (int(duration), () if deps == "none" else tuple(deps.split(",")))
                      for name, duration, deps in re.findall(r"([A-H]):([0-9]+):([A-H,]+|none)", prompt)}
            self.assertEqual(parsed, tasks)
            self.assertNotIn(str(bound), prompt)

    def test_signed_ledger_summary_independent_oracle(self):
        txs = transactions(32)
        balances = list(itertools.accumulate((tx["amount"] for tx in txs), initial=37))
        expected = {"final_balance": balances[-1], "minimum_balance": min(balances),
                    "negative_steps": sum(balance < 0 for balance in balances[1:])}
        for effort in ("off", "low", "medium"):
            case = self.cases[f"thinking-ledger32-{effort}"]
            self.assertEqual(case["check"]["expected"], expected)
            prompt = case["request"]["messages"][0]["content"]
            pairs = [{"id": int(tid), "amount": int(amount)} for tid, amount in re.findall(r"(\d+):(-?\d+)", prompt)]
            self.assertEqual(pairs, txs)
            self.assertIn("includes the initial balance", prompt)
            self.assertIn("only post-transaction", prompt)

    def test_continuous_ledgers_match_explicit_prompts_and_formula(self):
        for count in (8, 96):
            case = self.cases[f"continuous-ledger{count}-off"]
            gate = case["check"]
            self.assertEqual(gate, {"kind": "ledger", "initial_balance": 37, "transactions": transactions(count)})
            prompt = case["request"]["messages"][0]["content"]
            self.assertEqual([(int(tid), int(amount)) for tid, amount in re.findall(r"(\d+):(-?\d+)", prompt)],
                             [(tx["id"], tx["amount"]) for tx in transactions(count)])
            self.assertIn(f"exactly {count} NDJSON", prompt)
            self.assertIn("Stop naturally", prompt)
            self.assertTrue(all(b["id"] - a["id"] == 37 for a, b in zip(gate["transactions"], gate["transactions"][1:])))

    def test_thinking_json_correctness_strict_semantics_and_natural_finish(self):
        for case in self.cases.values():
            if case["check"]["kind"] != "json":
                continue
            gate = case["check"]
            expected = gate["expected"]
            self.assertEqual(self.check(gate, json.dumps(expected))["status"], "passed")
            key = next(iter(expected))
            for replacement in (True, False, str(expected[key]), float(expected[key]), expected[key] + 1):
                wrong = dict(expected, **{key: replacement})
                self.assertEqual(self.check(gate, json.dumps(wrong))["status"], "failed")
            for finish in ("length", "content_filter", "function_call"):
                self.assertEqual(self.check(gate, json.dumps(expected), finish)["status"], "failed")
            self.assertEqual(self.check(gate, json.dumps(dict(expected, extra=1)))["status"], "failed")

    def test_ledger_complete_rows_and_independent_checksum(self):
        for count in (8, 96):
            gate = self.cases[f"continuous-ledger{count}-off"]["check"]
            rows = ledger_rows(gate)
            balances = list(itertools.accumulate((((i * 53) % 97) - 48 for i in range(1, count + 1)), initial=37))[1:]
            for ending in ("", "\n"):
                result = self.check(gate, ndjson(rows) + ending)
                self.assertEqual(result, {"status": "passed", "scope": "ledger", "full_task_completed": True,
                                          "rows_checked": count, "balance_checksum": sum(balances)})

    def test_ledger_wrong_seq_id_balance_and_strict_integer_types(self):
        gate = self.cases["continuous-ledger8-off"]["check"]
        for field in ("seq", "id", "balance"):
            for value in (True, False, "1", 1.0, None, -999, 999):
                with self.subTest(field=field, value=value):
                    rows = ledger_rows(gate)
                    rows[0][field] = value
                    self.assertEqual(self.check(gate, ndjson(rows))["status"], "failed")
        unit = {"kind": "ledger", "initial_balance": 0, "transactions": [{"id": 1, "amount": 1}]}
        for field in ("seq", "id", "balance"):
            row = {"seq": 1, "id": 1, "balance": 1}
            row[field] = True
            self.assertEqual(self.check(unit, json.dumps(row))["status"], "failed")

    def test_ledger_missing_extra_order_duplicate_keys_and_non_objects(self):
        gate = self.cases["continuous-ledger8-off"]["check"]
        rows = ledger_rows(gate)
        texts = [ndjson(rows[:-1]), ndjson(rows + [rows[-1]]), ndjson(rows[::-1]),
                 ndjson([rows[0], rows[0]] + rows[2:]), "\n" + ndjson(rows), ndjson(rows) + "\n\n",
                 ndjson(rows).replace("\n", "\n\n", 1), "```json\n" + ndjson(rows) + "\n```",
                 ndjson(rows) + "\nSummary", ndjson(rows)[:-1]]
        for first in ([1, 1037, 42], 1, None, dict(rows[0], extra=0), {"seq": 1, "balance": 42}):
            texts.append(ndjson([first] + rows[1:]))
        texts.append('{"seq":0,"seq":1,"id":1037,"balance":42}\n' + ndjson(rows[1:]))
        for text in texts:
            with self.subTest(text=text[:100]):
                self.assertEqual(self.check(gate, text)["status"], "failed")

    def test_ledger_requires_quality_and_natural_eos_even_for_complete_output(self):
        gate = self.cases["continuous-ledger8-off"]["check"]
        text = ndjson(ledger_rows(gate))
        for finish in ("length", "tool_calls", "content_filter", "function_call"):
            self.assertEqual(self.check(gate, text, finish)["status"], "failed")
        for mode in ("throughput", "stress", "cache"):
            self.assertEqual(self.check(gate, text, mode=mode)["status"], "failed")
        self.assertEqual(self.check(gate, text, tools=[{}])["status"], "failed")

    def test_ledger_checker_never_executes_output(self):
        gate = self.cases["continuous-ledger8-off"]["check"]
        with mock.patch("builtins.exec", side_effect=AssertionError("must not execute")), \
             mock.patch("builtins.eval", side_effect=AssertionError("must not evaluate")):
            self.assertEqual(self.check(gate, "raise RuntimeError('generated code')")["status"], "failed")
            self.assertEqual(self.check(gate, ndjson(ledger_rows(gate)))["status"], "passed")

    def test_sequence_all_500_complete_with_or_without_newline(self):
        gate = self.cases["continuous-sequence-4096-off"]["check"]
        for finish in ("stop", "length"):
            for ending in ("", "\n"):
                self.assertEqual(self.check(gate, self.sequence() + ending, finish, "stress"),
                                 {"status": "passed", "scope": "sequence", "full_task_completed": True, "rows_checked": 500})

    def test_sequence_length_complete_short_prefix_not_full_pass(self):
        gate = self.cases["continuous-sequence-4096-off"]["check"]
        for count in (1, 2, 499):
            for ending in ("", "\n"):
                result = self.check(gate, self.sequence(count) + ending, "length", "stress")
                self.assertEqual(result, {"status": "passed", "scope": "valid_prefix",
                                          "full_task_completed": False, "rows_checked": count})
                self.assertEqual(self.check(gate, self.sequence(count) + ending, "stop", "stress")["status"], "failed")

    def test_sequence_every_truncated_next_line_prefix_only_allowed_on_length(self):
        gate = self.cases["continuous-sequence-4096-off"]["check"]
        next_line = "RECORD 3: amber blue cedar delta."
        for size in range(1, len(next_line)):
            text = self.sequence(2) + "\n" + next_line[:size]
            with self.subTest(prefix=next_line[:size]):
                result = self.check(gate, text, "length", "stress")
                self.assertEqual(result["scope"], "valid_prefix")
                self.assertIs(result["full_task_completed"], False)
                self.assertEqual(result["rows_checked"], 2)
                for finish in ("stop", "tool_calls", "content_filter", "function_call"):
                    self.assertEqual(self.check(gate, text, finish, "stress")["status"], "failed")
                self.assertEqual(self.check(gate, text + "\n", "length", "stress")["status"], "failed")

    def test_sequence_format_loops_gaps_extra_rows_and_wrong_partial_fail(self):
        gate = self.cases["continuous-sequence-4096-off"]["check"]
        texts = ["", "\n", "Heading\n" + self.sequence(2), self.sequence(2) + "\n\n",
                 self.sequence(2) + "\nRECORD 2: amber blue cedar delta.",
                 self.sequence(2) + "\nRECORD 4: amber", self.sequence(2) + "\nRECORD 03: amber",
                 self.sequence(2) + "\nRECORD 3: amber blue cedar delta.x",
                 self.sequence(2).replace("\n", "\n\n"), self.sequence(2).replace("1:", "01:"),
                 self.sequence(2).replace("delta.", "delta!"), self.sequence(2).replace("\n", "\r\n"),
                 " " + self.sequence(2), self.sequence(2) + " ", self.sequence(501),
                 self.sequence() + "\nR", "```\n" + self.sequence(2) + "\n```"]
        for text in texts:
            for finish in ("stop", "length"):
                with self.subTest(text=text[-80:], finish=finish):
                    self.assertEqual(self.check(gate, text, finish, "stress")["status"], "failed")

    def test_sequence_mode_and_tool_rules(self):
        gate = self.cases["continuous-sequence-4096-off"]["check"]
        for mode in ("quality", "throughput", "cache"):
            self.assertEqual(self.check(gate, self.sequence(), mode=mode)["status"], "failed")
        self.assertEqual(self.check(gate, self.sequence(), mode="stress", tools=[{}])["status"], "failed")

    def test_check_gate_new_fields_are_strict(self):
        ledger = self.cases["continuous-ledger8-off"]["check"]
        sequence = self.cases["continuous-sequence-4096-off"]["check"]
        invalid = [None, [], {}, dict(ledger, extra=1), dict(sequence, extra=1)]
        for value in (True, False, "37", 37.0, None):
            invalid.append(dict(ledger, initial_balance=value))
        for value in (True, False, "500", 500.0, 0, -1, None):
            invalid.append(dict(sequence, rows=value))
        for value in (True, False, "", None, "text\n", "text\r"):
            invalid.append(dict(sequence, text=value))
        for value in ([], {}, None, [None], [{"id": 1}], [{"id": 1, "amount": 1, "extra": 0}],
                      [{"id": 1, "amount": 1}, {"id": 1, "amount": 2}]):
            invalid.append(dict(ledger, transactions=value))
        for field in ("id", "amount"):
            for value in (True, False, "1", 1.0, None):
                invalid.append(dict(ledger, transactions=[{"id": 1, "amount": 1} | {field: value}]))
        for gate in invalid:
            with self.subTest(gate=gate):
                with self.assertRaises(ValueError):
                    CLIENT.check_gate(gate)

    def test_load_assets_rejects_invalid_new_gate_modes_and_budgets(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            path = Path(directory) / "fixtures.json"
            for case_id, field, value in (("continuous-ledger8-off", "mode", "stress"),
                                         ("continuous-ledger8-off", "mode", "throughput"),
                                         ("continuous-sequence-1536-off", "mode", "quality"),
                                         ("continuous-sequence-1536-off", "mode", "throughput"),
                                         ("thinking-digit-off", "max_tokens", True),
                                         ("thinking-digit-off", "max_tokens", False),
                                         ("thinking-digit-off", "max_tokens", "4096"),
                                         ("thinking-digit-off", "max_tokens", 0),
                                         ("thinking-digit-low", "enable_thinking", 1),
                                         ("thinking-digit-low", "enable_thinking", 0)):
                fixtures = copy.deepcopy(self.fixtures)
                case = next(case for case in fixtures["cases"] if case["id"] == case_id)
                target = case if field == "mode" else (case["request"] if field == "max_tokens" else case["request"]["chat_template_kwargs"])
                target[field] = value
                path.write_text(json.dumps(fixtures))
                with self.subTest(case=case_id, field=field, value=value), self.assertRaises(ValueError):
                    CLIENT.load_assets(path)

    def test_cli_validate_and_plan_new_asset_offline(self):
        with mock.patch.object(CLIENT, "stream_request", side_effect=AssertionError("network forbidden")):
            for command in ("validate", "plan"):
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    code = CLIENT.main([command, "--fixtures", str(ASSET), "--suite", "all"])
                self.assertEqual(code, 0)
                record = json.loads(stdout.getvalue())
                if command == "validate":
                    self.assertEqual(record["case_count"], 13)
                else:
                    self.assertEqual(len(record["cases"]), 13)
                    for case in record["cases"]:
                        self.assertEqual(case["request"]["max_tokens"], self.cases[case["id"]]["request"]["max_tokens"])

    def test_cli_new_cases_and_first_failure_stop(self):
        profile = next(profile for profile in self.profiles["profiles"] if profile["id"] == "P")
        runtime = CLIENT.runtime_template(profile)
        runtime.update(observed_at="2026-10-05T00:00:00Z", evidence_sha256="a" * 64)
        runtime["settings"]["prefix_caching"] = False
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            path = Path(directory) / "runtime.json"
            path.write_text(json.dumps(runtime))
            argv = ["run", "--fixtures", str(ASSET), "--model", "test-model", "--base-url", "http://private.invalid/v1",
                    "--runtime-record", str(path), "--warmups", "0", "--repeats", "1"]
            for case in self.cases.values():
                gate = case["check"]
                if gate["kind"] == "json":
                    text, finish = json.dumps(gate["expected"]), "stop"
                elif gate["kind"] == "ledger":
                    text, finish = ndjson(ledger_rows(gate)), "stop"
                else:
                    text, finish = self.sequence(2) + "\nRECORD 3: am", "length"
                result = response(text, finish)
                result.update(usage=None, metrics={"content_decode_tokens_per_second_estimate": None})
                stdout = io.StringIO()
                with mock.patch.object(CLIENT, "stream_request", return_value=result), contextlib.redirect_stdout(stdout):
                    code = CLIENT.main(argv + ["--case", case["id"]])
                self.assertEqual(code, 0)
                record = json.loads(stdout.getvalue().splitlines()[1])
                self.assertEqual(record["correctness"]["status"], "passed")
                if gate["kind"] == "sequence":
                    self.assertEqual(record["correctness"]["scope"], "valid_prefix")
                    self.assertIs(record["correctness"]["full_task_completed"], False)
                self.assertNotIn("response", record)
                self.assertNotIn("private.invalid", stdout.getvalue())
            bad = response('{"number":295}')
            bad.update(usage=None, metrics={"content_decode_tokens_per_second_estimate": None})
            stdout = io.StringIO()
            with mock.patch.object(CLIENT, "stream_request", return_value=bad) as stream, contextlib.redirect_stdout(stdout):
                code = CLIENT.main(argv + ["--case", "thinking-digit-off", "--case", "thinking-digit-low"])
            self.assertEqual(code, 1)
            stream.assert_called_once()
            self.assertEqual(len(stdout.getvalue().splitlines()), 2)


if __name__ == "__main__":
    unittest.main()
