#!/usr/bin/env python3
import contextlib
import copy
import http.client
import http.server
import importlib.util
import io
import json
import pathlib
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


CLIENT_PATH = pathlib.Path(__file__).with_name("benchmark-thor.py")
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("benchmark_thor", CLIENT_PATH)
CLIENT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLIENT)


def event(delta=None, finish=None, usage=None, index=0):
    chunk = {"choices": [{"index": index, "delta": delta or {}, "finish_reason": finish}]}
    if usage is not None:
        chunk["usage"] = usage
    return "message", json.dumps(chunk, ensure_ascii=False)


def response(content="", finish="stop", tools=None):
    return {"content": content, "reasoning_content": "", "tool_calls": tools or [],
            "finish_reason": finish}


class BenchmarkChecks(unittest.TestCase):
    def setUp(self):
        self.fixtures, profiles = CLIENT.load_assets()
        self.cases = {case["id"]: case for case in self.fixtures["cases"]}
        self.profiles = {profile["id"]: profile for profile in profiles["profiles"]}

    def runtime(self, profile_id="P"):
        record = CLIENT.runtime_template(self.profiles[profile_id])
        record.update(observed_at="2026-10-04T12:00:00Z", evidence_sha256="a" * 64)
        record["settings"]["prefix_caching"] = False
        return record

    def collect(self, events, times=None):
        if times is None:
            times = range(1, len(events) + 2)
        clock = mock.Mock(side_effect=[100 + value for value in times])
        result = CLIENT.collect_stream(iter(events), 100, clock=clock)
        self.assertEqual(clock.call_count, len(events) + 1)
        return result

    def cli(self, argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = CLIENT.main(argv)
        return status, stdout.getvalue(), stderr.getvalue()

    def run_case(self, case_id, stream, base_url="http://127.0.0.1:1/v1"):
        with tempfile.TemporaryDirectory() as directory:
            runtime_path = pathlib.Path(directory, "runtime.json")
            runtime_path.write_text(json.dumps(self.runtime()), encoding="utf-8")
            with mock.patch.object(CLIENT, "stream_request", side_effect=stream), \
                 mock.patch.dict(CLIENT.os.environ, {"THOR_BENCHMARK_API_KEY": "SECRET"}):
                return self.cli(["run", "--case", case_id, "--model", "test-model",
                                 "--base-url", base_url, "--runtime-record", str(runtime_path),
                                 "--warmups", "0", "--repeats", "1"])

    def test_load_assets_counts_and_nested_thinking(self):
        self.assertEqual(len(self.cases), 16)
        self.assertEqual(set(self.profiles), {"P", "L", "S0", "G1", "M1", "M1M", "F0", "F1", "F2", "F3", "F4"})
        thinking = {}
        for case in self.cases.values():
            request = case["request"]
            self.assertFalse({"model", "stream", "enable_thinking", "reasoning_effort"} & request.keys())
            template = request["chat_template_kwargs"]
            self.assertIs(type(template["enable_thinking"]), bool)
            if template["enable_thinking"]:
                thinking[case["id"]] = template["reasoning_effort"]
        self.assertEqual(thinking, {"agent-plan-thinking-low": "low",
                                    "agent-plan-thinking-medium": "medium",
                                    "chinese-synthesis-thinking-low": "low"})

    def test_load_assets_rejects_top_level_or_missing_effort(self):
        with tempfile.TemporaryDirectory() as directory:
            fixtures_path = pathlib.Path(directory, "fixtures.json")
            for variant in ("top_level", "missing", "invalid", "duplicate"):
                with self.subTest(variant=variant):
                    fixtures = copy.deepcopy(self.fixtures)
                    case = next(case for case in fixtures["cases"] if case["id"] == "agent-plan-thinking-low")
                    request = case["request"]
                    if variant in {"top_level", "duplicate"}:
                        request["reasoning_effort"] = "low"
                    if variant in {"top_level", "missing"}:
                        del request["chat_template_kwargs"]["reasoning_effort"]
                    if variant == "invalid":
                        request["chat_template_kwargs"]["reasoning_effort"] = "automatic"
                    fixtures_path.write_text(json.dumps(fixtures), encoding="utf-8")
                    with self.assertRaises(ValueError):
                        CLIENT.load_assets(fixtures_path=fixtures_path)

    def test_historical_prompts_exact_unicode(self):
        expected = {
            "historical-device-tree-256": "\u7528\u4e2d\u6587\u8be6\u7ec6\u89e3\u91ca\u8bbe\u5907\u6811\u5982\u4f55\u5e2e\u52a9Linux\u542f\u52a8\uff0c\u5206\u4e94\u70b9\u8bf4\u660e\uff0c\u7ea6400\u5b57\u3002",
            "historical-prime-256": "\u8bf7\u5199\u4e00\u4e2aPython\u51fd\u6570\u5224\u65ad\u6574\u6570\u662f\u5426\u662f\u8d28\u6570\uff0c\u5e76\u7ed9\u51fa\u4e94\u4e2a\u6d4b\u8bd5\u7528\u4f8b\uff0c\u7136\u540e\u89e3\u91ca\u65f6\u95f4\u590d\u6742\u5ea6\u3002",
            "historical-lru-1024": "\u8bf7\u5b9e\u73b0\u4e00\u4e2a\u5b8c\u6574\u7684Python LRU\u7f13\u5b58\u7c7b\uff0c\u4f7f\u7528\u53cc\u5411\u94fe\u8868\u548c\u5b57\u5178\uff0c\u652f\u6301get\u548cput\uff0c\u63d0\u4f9b\u8be6\u5c3d\u7684\u5355\u5143\u6d4b\u8bd5\u3002\u76f4\u63a5\u8f93\u51fa\u4ee3\u7801\uff0c\u5c3d\u53ef\u80fd\u5b8c\u6574\u3002",
            "historical-water-cycle-128": "\u8bf7\u5199\u4e00\u7bc7\u8be6\u7ec6\u7684\u79d1\u666e\u6587\u7ae0\uff0c\u89e3\u91ca\u5730\u7403\u6c34\u5faa\u73af\u5982\u4f55\u8fde\u63a5\u6d77\u6d0b\u3001\u5927\u6c14\u3001\u9646\u5730\u548c\u5730\u4e0b\u6c34\uff0c\u5e76\u8ba8\u8bba\u4eba\u7c7b\u6d3b\u52a8\u7684\u5f71\u54cd\u3002",
            "historical-interval-256": "Write a Python function that merges overlapping integer intervals. Include type hints and three assert examples. Output only code.",
            "historical-json-80": "\u4ec5\u8f93\u51fa\u4e00\u4e2aJSON\u5bf9\u8c61\uff0c\u5305\u542bcity\u503c\u5317\u4eac\uff0ccountry\u503c\u4e2d\u56fd\uff0cnumber\u503c42\uff0c\u4e0d\u8981Markdown\u3002",
        }
        self.assertEqual({case["id"] for case in self.cases.values()
                          if case["provenance"]["kind"] == "historical-exact"}, set(expected))
        for case_id, text in expected.items():
            with self.subTest(case=case_id):
                case = self.cases[case_id]
                self.assertEqual(case["request"]["messages"], [{"role": "user", "content": text}])
                self.assertEqual(case["check"], {"kind": "none"})
        self.assertEqual(self.cases["historical-json-80"]["request"]["max_tokens"], 80)

    def test_chinese_synthesis_exact_unicode(self):
        text = ("\u8bf7\u7528\u4e2d\u6587\u5199\u4e00\u4efd\u9762\u5411\u516c\u4f17\u7684\u6c34\u5faa\u73af\u8bf4\u660e\uff1a\u89e3\u91ca\u6d77\u6d0b\u3001\u5927\u6c14\u3001\u9646\u5730\u548c\u5730\u4e0b\u6c34\u4e4b\u95f4\u7684\u8054\u7cfb\uff1b"
                "\u6bd4\u8f83\u57ce\u5e02\u786c\u5316\u5730\u9762\u4e0e\u690d\u6811\u5bf9\u5f84\u6d41\u548c\u8865\u7ed9\u7684\u5f71\u54cd\uff1b\u533a\u5206\u76f8\u5173\u6027\u4e0e\u56e0\u679c\u6027\uff1b"
                "\u7ed9\u51fa\u4e24\u9879\u53ef\u6d4b\u91cf\u7684\u89c2\u5bdf\u6307\u6807\u53ca\u5176\u5c40\u9650\u3002\u4e0d\u8981\u7f16\u9020\u7edf\u8ba1\u6570\u636e\u6216\u5f15\u7528\u3002")
        self.assertEqual(self.cases["chinese-synthesis-thinking-low"]["request"]["messages"][0]["content"], text)
        self.assertEqual(json.loads(json.dumps(text, ensure_ascii=True)), text)

    def test_fixed_output_protocol_does_not_force_quality_or_natural_json(self):
        for case_id in ("historical-water-cycle-128", "historical-interval-256"):
            self.assertIs(self.cases[case_id]["request"]["ignore_eos"], True)
            self.assertEqual(self.cases[case_id]["mode"], "throughput")
            self.assertEqual(self.cases[case_id]["check"]["kind"], "none")
        for case in self.cases.values():
            if case["mode"] == "quality" or case["id"] == "historical-json-80":
                self.assertNotIn("ignore_eos", case["request"])

    def test_profile_p_complete_pins(self):
        profile = self.profiles["P"]
        self.assertEqual(profile["status"], "declared")
        self.assertEqual(profile["pins"], {
            "engine": "sglang", "engine_revision": "5f55db35e926d50676f75b812640ea2410b0fe0e",
            "image_id": "sha256:b4625e472cec3abf4b811a7d308704e757e92c324db52f52b8dc5721877934da",
            "target_repository": "joshebbs/qwen3.8-27b-uncensored-nvfp4-modelopt",
            "target_revision": "e5ff4986938dcd0dd05ab4cce89da1b052be6ce3",
            "draft_repository": "maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal",
            "draft_revision": "bd7a934213c47a9e7ef69eef36bb3325f47fd1f1",
            "application_version": None,
        })

    def test_g1_only_changes_decode_graph_settings_from_s0(self):
        baseline, graph = self.profiles["S0"], self.profiles["G1"]
        excluded = {"id", "source", "purpose", "membership", "name", "settings"}
        self.assertEqual({key: value for key, value in baseline.items() if key not in excluded},
                         {key: value for key, value in graph.items() if key not in excluded})
        graph_keys = {"cuda_graph_backend_decode", "cuda_graph_max_bs_decode"}
        self.assertEqual({key: value for key, value in baseline["settings"].items() if key not in graph_keys},
                         {key: value for key, value in graph["settings"].items() if key not in graph_keys})
        self.assertEqual(baseline["settings"]["cuda_graph_backend_decode"], "disabled")
        self.assertNotIn("cuda_graph_max_bs_decode", baseline["settings"])
        self.assertEqual({key: graph["settings"][key] for key in graph_keys},
                         {"cuda_graph_backend_decode": "full", "cuda_graph_max_bs_decode": 1})
        self.assertEqual(graph["source"], "hosts/personal/fixed/thor/flash-next.nix")
        self.assertEqual(graph["status"], "declared")
        self.assertIn("generated", graph["purpose"])
        self.assertIn("Unmeasured", graph["purpose"])

    def test_pending_profiles_and_factor_settings(self):
        target_revision = "7b719225242aacd3dbd3f9407468c2ee9a9d2594"
        thor_repository = "manateelazycat/Qwen3.8-Flash-Next-SGLang-Thor"
        thor_revision = "b8c4002b44544436bfc16b1ff7fe6ebb3ced07a6"
        original = self.profiles["L"]
        self.assertEqual(original["status"], "pending")
        self.assertEqual(original["pins"], {
            "engine": "sglang", "engine_revision": None, "image_id": None,
            "target_repository": "RadixArk/Qwen3.8-Flash-Next-NVFP4",
            "target_revision": target_revision,
            "draft_repository": thor_repository, "draft_revision": thor_revision,
            "application_version": "0.2.8",
        })
        for key, value in {
            "runtime_image_tag": "registry.lazycat.cloud/catdogai/qwen38-flash-next-origin:runtime-sglang-0.2.4",
            "runtime_base_image": "lmsysorg/sglang:v0.5.20",
            "engine_build_prefix": "94602c9c",
            "target_quantization": "modelopt_mixed", "draft_quantization": "modelopt_mixed",
            "context_length": 262000, "max_total_tokens": 522176,
            "max_running_requests": 8, "mem_fraction_static": 0.92,
            "kv_cache_dtype": "fp8_e4m3", "mamba_ssm_dtype": "bfloat16",
            "max_mamba_cache_size": 40, "attention_backend": "fa4",
            "moe_runner_backend": "flashinfer_cutlass", "fp4_gemm_backend": "flashinfer_cutlass",
            "fp8_gemm_backend": "triton", "page_size": 64,
            "chunked_prefill_size": 4096, "max_prefill_tokens": 8192,
            "ple_offload_embedding": True, "ple_offload_backend": "file",
            "speculative_algorithm": "NEXTN", "speculative_num_steps": 3,
            "speculative_eagle_topk": 1, "speculative_num_draft_tokens": 4,
            "speculative_draft_model_path": "/mtp-nvfp4",
            "speculative_token_map": "/vocab-maps/vocab-32768-corpus.pt",
        }.items():
            self.assertEqual(original["settings"][key], value)
        for profile_id in ("L", "F0", "F1", "F2", "F3", "F4"):
            profile = self.profiles[profile_id]
            self.assertEqual(profile["source"],
                             "https://forgejo.beaco.works/infrastructure/infra/src/commit/"
                             "712df0cc348d9d05a58f87350e15c49a82c6eb76/"
                             "docs/inventory/guanggu/lcmd/thor-apps/qwen3.8-flash-next-origin.md")
            settings = profile["settings"]
            self.assertEqual(settings["target_config_repository"], thor_repository)
            self.assertEqual(settings["target_config_revision"], thor_revision)
            self.assertEqual(settings["target_config_files"], ["target/config.json", "target/hf_quant_config.json"])
            self.assertEqual(settings["target_config_mode"], "override RadixArk target configuration")
            if profile_id != "F0":
                self.assertEqual(settings["optimization_repository"], thor_repository)
                self.assertEqual(settings["optimization_revision"], thor_revision)
        for profile_id, algorithm, steps, topk, tokens, state, dense in (
            ("F0", "disabled", 0, 0, 0, "float32", "bfloat16"),
            ("F1", "NEXTN", 3, 1, 4, "float32", "bfloat16"),
            ("F2", "NEXTN", 3, 1, 4, "bfloat16", "bfloat16"),
            ("F3", "NEXTN", 3, 1, 4, "float32", "fp8"),
            ("F4", "NEXTN", 3, 1, 4, "bfloat16", "fp8"),
        ):
            with self.subTest(profile=profile_id):
                profile = self.profiles[profile_id]
                self.assertEqual(profile["status"], "pending")
                self.assertEqual(profile["pins"]["engine"], "sglang")
                self.assertEqual(profile["pins"]["target_repository"], "RadixArk/Qwen3.8-Flash-Next-NVFP4")
                self.assertEqual(profile["pins"]["target_revision"], target_revision)
                for key in ("engine_revision", "image_id"):
                    self.assertIsNone(profile["pins"][key])
                self.assertEqual(profile["pins"]["draft_repository"], None if profile_id == "F0" else thor_repository)
                self.assertEqual(profile["pins"]["draft_revision"], None if profile_id == "F0" else thor_revision)
                settings = profile["settings"]
                self.assertNotIn("mtp_draft_tokens", settings)
                self.assertEqual((settings["speculative_algorithm"], settings["speculative_num_steps"],
                                  settings["speculative_eagle_topk"], settings["speculative_num_draft_tokens"]),
                                 (algorithm, steps, topk, tokens))
                self.assertEqual((settings["state_dtype"], settings["dense_dtype"]), (state, dense))
                self.assertEqual(settings["precision_implementation"], "pending")
                self.assertEqual(settings["context_length"], 262000)
                self.assertEqual(settings["target_head_dtype"], "bfloat16")
                if dense == "fp8":
                    self.assertIsNone(settings["conversion_artifact_sha256"])
                    self.assertIsNone(settings["conversion_source_revision"])

    def test_runtime_template_excludes_metadata_and_copies_pins(self):
        profile = self.profiles["P"]
        original = copy.deepcopy(profile)
        template = CLIENT.runtime_template(profile)
        self.assertEqual(template["profile_id"], "P")
        self.assertIsNone(template["observed_at"])
        self.assertIsNone(template["evidence_sha256"])
        self.assertEqual(template["pins"], profile["pins"])
        expected = {key: value for key, value in profile["settings"].items()
                    if key not in CLIENT.METADATA_SETTINGS | {"model"}}
        self.assertEqual(template["settings"], dict(expected, prefix_caching=None))
        template["pins"]["image_id"] = "changed"
        template["settings"]["context_length"] = 1
        self.assertEqual(profile, original)
        pending = CLIENT.runtime_template(self.profiles["L"])
        self.assertEqual(pending["pins"], self.profiles["L"]["pins"])
        expected = {key: value for key, value in self.profiles["L"]["settings"].items()
                    if key not in CLIENT.METADATA_SETTINGS | {"model"}}
        self.assertEqual(pending["settings"], dict(expected, prefix_caching=None))
        self.assertEqual(pending["settings"]["context_length"], 262000)
        self.assertEqual(pending["settings"]["kv_cache_dtype"], "fp8_e4m3")
        self.assertEqual(pending["settings"]["max_running_requests"], 8)

    def test_runtime_p_observed_pins_and_settings_pass(self):
        for caching in (False, True):
            with self.subTest(prefix_caching=caching):
                record = self.runtime()
                record["settings"]["prefix_caching"] = caching
                self.assertIsNone(CLIENT.verify_runtime(self.profiles["P"], record))

    def test_runtime_requires_observation_evidence_and_prefix_caching(self):
        for section, key, value in (
            (None, "observed_at", None), (None, "observed_at", "2026-10-04T12:00:00"),
            (None, "evidence_sha256", None), (None, "evidence_sha256", "bad"),
            (None, "profile_id", "L"), ("settings", "prefix_caching", None),
            ("settings", "prefix_caching", 1), ("settings", "prefix_caching", "true"),
        ):
            with self.subTest(key=key, value=value):
                record = self.runtime()
                (record[section] if section else record)[key] = value
                with self.assertRaises(ValueError):
                    CLIENT.verify_runtime(self.profiles["P"], record)

    def test_runtime_rejects_wrong_or_mutable_image_target_and_settings(self):
        for section, key, value in (
            ("pins", "image_id", "sha256:" + "b" * 64), ("pins", "image_id", "latest"),
            ("pins", "target_revision", "b" * 40), ("pins", "target_revision", "main"),
            ("pins", "target_repository", "other/model"), ("pins", "engine_revision", "b" * 40),
            ("pins", "draft_revision", "main"), ("settings", "context_length", 1),
            ("settings", "kv_cache_dtype", "float32"), ("settings", "max_running_requests", None),
        ):
            with self.subTest(key=key, value=value):
                record = self.runtime()
                record[section][key] = value
                with self.assertRaises(ValueError):
                    CLIENT.verify_runtime(self.profiles["P"], record)

    def test_runtime_unresolved_l_and_f_pins_rejected(self):
        for profile_id in ("L", "F0", "F1", "F2", "F3", "F4"):
            with self.subTest(profile=profile_id):
                record = self.runtime(profile_id)
                for key, value in (("context_length", 262144), ("kv_cache_dtype", "bfloat16"),
                                   ("max_running_requests", 1), ("conversion_artifact_sha256", "a" * 64),
                                   ("conversion_source_revision", "b" * 40)):
                    if record["settings"].get(key) is None:
                        record["settings"][key] = value
                with self.assertRaisesRegex(ValueError, "unresolved pins"):
                    CLIENT.verify_runtime(self.profiles[profile_id], record)

    def test_fp8_conversion_artifact_and_source_revision(self):
        for profile_id in ("F3", "F4"):
            record = self.runtime(profile_id)
            record["pins"].update(engine_revision="a" * 40, image_id="sha256:" + "a" * 64)
            record["settings"].update(conversion_artifact_sha256="c" * 64,
                                      conversion_source_revision=record["pins"]["target_revision"])
            with self.subTest(profile=profile_id, variant="valid"):
                self.assertIsNone(CLIENT.verify_runtime(self.profiles[profile_id], record))
            for key, value in (("conversion_source_revision", "d" * 40),
                               ("conversion_artifact_sha256", "bad")):
                with self.subTest(profile=profile_id, variant=key):
                    invalid = copy.deepcopy(record)
                    invalid["settings"][key] = value
                    with self.assertRaises(ValueError):
                        CLIENT.verify_runtime(self.profiles[profile_id], invalid)

    def test_pending_f1_rejects_mutable_engine_revision(self):
        profile = self.profiles["F1"]
        record = self.runtime("F1")
        record["pins"].update(engine_revision="a" * 40, image_id="sha256:" + "b" * 64)
        self.assertIsNone(CLIENT.verify_runtime(profile, record))
        for revision in ("main", "master"):
            with self.subTest(revision=revision):
                invalid = copy.deepcopy(record)
                invalid["pins"]["engine_revision"] = revision
                with self.assertRaises(ValueError):
                    CLIENT.verify_runtime(profile, invalid)

    def test_build_request_expands_prefix_without_mutating_fixtures(self):
        original = copy.deepcopy(self.fixtures)
        case = self.cases["cache-public-archive-four-turns"]
        request = CLIENT.build_request(case, "test-model")
        self.assertEqual(request["messages"][0]["content"],
                         case["prefix"]["line"] * 500 + case["request"]["messages"][0]["content"])
        self.assertEqual(request["model"], "test-model")
        self.assertIs(request["stream"], True)
        self.assertEqual(request["stream_options"], {"include_usage": True})
        request["messages"].append({"role": "assistant", "content": "changed"})
        request["chat_template_kwargs"]["enable_thinking"] = True
        self.assertEqual(self.fixtures, original)

    def test_build_request_isolation_label_preserves_prefix(self):
        case = self.cases["cache-public-archive-four-turns"]
        shared = CLIENT.build_request(case, "test-model")
        isolated = CLIENT.build_request(case, "test-model", "run:case:0")
        self.assertEqual(isolated["messages"][0], {"role": "system", "content":
                         "Benchmark isolation label: run:case:0. Ignore this label when answering."})
        self.assertEqual(isolated["messages"][1:], shared["messages"])
        self.assertNotIn("Benchmark isolation label", shared["messages"][0]["content"])

    def test_build_request_seed_only_changes_copied_request(self):
        original = copy.deepcopy(self.fixtures)
        for case in self.cases.values():
            for isolation in (None, "run:case:0"):
                with self.subTest(case=case["id"], isolation=isolation):
                    default = CLIENT.build_request(case, "test-model", isolation)
                    self.assertNotIn("seed", default)
                    self.assertEqual(CLIENT.build_request(case, "test-model", isolation, seed=None), default)
                    for seed in (42, 0, -1):
                        seeded = CLIENT.build_request(case, "test-model", isolation, seed=seed)
                        self.assertEqual(seeded, dict(default, seed=seed))
        self.assertEqual(self.fixtures, original)
        self.assertEqual(CLIENT.digest(self.fixtures), CLIENT.digest(original))

    def test_iter_sse_utf8_bytewise_crlf_comments_multiline_usage_done(self):
        text = (": heartbeat\r\nid: ignored\r\nretry: 100\r\nevent: message\r\n"
                "data: {\"choices\":\r\ndata: [{\"index\": 0, \"delta\": {\"content\": \"\u5317\u4eac\"},"
                " \"finish_reason\": \"stop\"}]}\r\n\r\n"
                "data: {\"choices\": [], \"usage\": {\"completion_tokens\": 2}}\r\n\r\n"
                "data: [DONE]\r\n\r\n")
        events = list(CLIENT.iter_sse(bytes([byte]) for byte in text.encode("utf-8")))
        self.assertEqual(len(events), 3)
        self.assertEqual(events[0][0], "message")
        self.assertIn("\n", events[0][1])
        self.assertEqual(json.loads(events[0][1])["choices"][0]["delta"]["content"], "\u5317\u4eac")
        self.assertEqual(json.loads(events[1][1]), {"choices": [], "usage": {"completion_tokens": 2}})
        self.assertEqual(events[2], ("message", "[DONE]"))
        result = self.collect(events)
        self.assertEqual(result["content"], "\u5317\u4eac")
        self.assertEqual(result["metrics"]["completion_tokens_reported"], 2)

    def test_iter_sse_event_type_resets_after_blank_line(self):
        self.assertEqual(list(CLIENT.iter_sse([b": comment\n\nevent: error\ndata: bad\n\n"
                                               b"data: good\n\n"])),
                         [("error", "bad"), ("message", "good")])

    def test_iter_sse_missing_blank_line_at_eof(self):
        for data in (b"data: [DONE]", b"data: [DONE]\n", b"data: x\r\n\r", b"data: x\n\ndata: y"):
            with self.subTest(data=data):
                with self.assertRaisesRegex(CLIENT.ProtocolError, "truncated_sse_event"):
                    list(CLIENT.iter_sse([data]))

    def test_iter_sse_oversized_single_and_multiline_events(self):
        for chunks in ([b"data: " + b"x" * CLIENT.MAX_EVENT_BYTES],
                       [b"data: " + b"x" * (CLIENT.MAX_EVENT_BYTES // 2) + b"\n"] * 3):
            with self.subTest(parts=len(chunks)):
                with self.assertRaisesRegex(CLIENT.ProtocolError, "sse_event_too_large"):
                    list(CLIENT.iter_sse(chunks))

    def test_iter_sse_size_limit_applies_per_event_not_per_chunk(self):
        frame = b"data: " + b"x" * (CLIENT.MAX_EVENT_BYTES // 2) + b"\n\n"
        expected = [("message", "x" * (CLIENT.MAX_EVENT_BYTES // 2))] * 3
        self.assertEqual(list(CLIENT.iter_sse([frame, frame, frame])), expected)
        self.assertEqual(list(CLIENT.iter_sse([frame * 3])), expected)

    def test_iter_sse_invalid_or_incomplete_utf8(self):
        for data in (b"data: \xff\n\n", b"data: \xe5\x8c"):
            with self.subTest(data=data):
                with self.assertRaises(UnicodeError):
                    list(CLIENT.iter_sse([data]))

    def test_collect_content_reasoning_tools_and_deterministic_metrics(self):
        events = [
            event({"role": "assistant"}),
            event({"reasoning_content": "think "}),
            event({"reasoning": "again"}),
            event({"content": "hel", "tool_calls": [
                {"index": 1, "id": "call-b", "function": {"name": "get_", "arguments": '{"city":'}},
                {"index": 0, "id": "call-a", "function": {"name": "sum", "arguments": '{"n":'}},
            ]}),
            event({"content": "lo", "tool_calls": [
                {"index": 0, "function": {"arguments": "2}"}},
                {"index": 1, "function": {"name": "weather", "arguments": '"Beijing"}'}},
            ]}),
            event(finish="tool_calls"),
            ("message", json.dumps({"choices": [], "usage": {"completion_tokens": 10,
                "completion_tokens_details": {"reasoning_tokens": 4}}})),
            ("message", "[DONE]"),
        ]
        result = self.collect(events, [1, 2, 4, 7, 11, 12, 13, 14, 15])
        self.assertEqual(result["content"], "hello")
        self.assertEqual(result["reasoning_content"], "think again")
        self.assertEqual(result["tool_calls"], [
            {"id": "call-a", "type": "function", "function": {"name": "sum", "arguments": '{"n":2}'}},
            {"id": "call-b", "type": "function", "function": {"name": "get_weather", "arguments": '{"city":"Beijing"}'}},
        ])
        self.assertEqual(result["finish_reason"], "tool_calls")
        metrics = result["metrics"]
        expected = {"first_generation_seconds": 2, "first_reasoning_seconds": 2,
                    "first_content_seconds": 7, "first_tool_seconds": 7, "first_final_seconds": 7,
                    "wall_seconds": 15, "payload_events": 4, "payload_interval_p50_seconds": 3,
                    "payload_interval_p95_seconds": 4, "payload_interval_max_seconds": 4,
                    "completion_tokens_reported": 10, "reasoning_tokens_reported": 4,
                    "non_reasoning_tokens_reported": 6}
        for key, value in expected.items():
            with self.subTest(metric=key):
                self.assertEqual(metrics[key], value)
        self.assertAlmostEqual(metrics["end_to_end_tokens_per_second"], 10 / 15)
        for key in ("content_decode_tokens_per_second_estimate", "token_tpot_seconds",
                    "speculative_acceptance", "telemetry"):
            self.assertIsNone(metrics[key])

    def test_collect_length_stop_and_content_decode_estimate(self):
        events = [event({"content": "a"}), event({"content": "b"}),
                  event(finish="length", usage={"completion_tokens": 5}), ("message", "[DONE]")]
        result = self.collect(events, [1, 3, 4, 5, 6])
        self.assertEqual(result["finish_reason"], "length")
        self.assertEqual(result["content"], "ab")
        self.assertEqual(result["metrics"]["payload_events"], 2)
        self.assertEqual(result["metrics"]["payload_interval_p50_seconds"], 2)
        self.assertAlmostEqual(result["metrics"]["content_decode_tokens_per_second_estimate"], 4 / 5)
        self.assertIsNone(result["metrics"]["reasoning_tokens_reported"])
        self.assertIsNone(result["metrics"]["non_reasoning_tokens_reported"])

    def test_collect_reasoning_only_does_not_invent_final_output(self):
        events = [event({"reasoning_content": "only thought"}), event(finish="length"), ("message", "[DONE]")]
        result = self.collect(events)
        self.assertEqual(result["content"], "")
        self.assertEqual(result["reasoning_content"], "only thought")
        self.assertEqual(result["metrics"]["first_reasoning_seconds"], 1)
        for key in ("first_content_seconds", "first_tool_seconds", "first_final_seconds",
                    "content_decode_tokens_per_second_estimate", "completion_tokens_reported",
                    "reasoning_tokens_reported", "non_reasoning_tokens_reported"):
            self.assertIsNone(result["metrics"][key])

    def test_collect_tool_only_first_final_and_no_content_estimate(self):
        result = self.collect([event({"tool_calls": [{"index": 0, "function": {"name": "f", "arguments": "{}"}}]}),
                               event(finish="tool_calls", usage={"completion_tokens": 3}), ("message", "[DONE]")])
        self.assertEqual(result["metrics"]["first_final_seconds"], 1)
        self.assertEqual(result["metrics"]["first_tool_seconds"], 1)
        self.assertIsNone(result["metrics"]["first_content_seconds"])
        self.assertIsNone(result["metrics"]["content_decode_tokens_per_second_estimate"])

    def test_collect_missing_usage_tokens_not_inferred(self):
        for usage in (None, {}, {"prompt_tokens": 12},
                      {"completion_tokens_details": {"reasoning_tokens": 3}}):
            with self.subTest(usage=usage):
                result = self.collect([event({"content": "one two three"}), event(finish="stop", usage=usage),
                                       ("message", "[DONE]")])
                self.assertEqual(result["usage"], usage)
                for key in ("completion_tokens_reported", "reasoning_tokens_reported",
                            "non_reasoning_tokens_reported", "end_to_end_tokens_per_second",
                            "content_decode_tokens_per_second_estimate"):
                    self.assertIsNone(result["metrics"][key])

    def test_collect_missing_reasoning_tokens_not_inferred(self):
        result = self.collect([event({"reasoning": "thinking", "content": "answer"}),
                               event(finish="stop", usage={"completion_tokens": 7}), ("message", "[DONE]")])
        self.assertEqual(result["metrics"]["completion_tokens_reported"], 7)
        self.assertIsNone(result["metrics"]["reasoning_tokens_reported"])
        self.assertIsNone(result["metrics"]["non_reasoning_tokens_reported"])
        self.assertIsNone(result["metrics"]["content_decode_tokens_per_second_estimate"])

    def test_collect_invalid_token_counts_not_used(self):
        for completion, reasoning in ((True, 0), (-1, 0), ("5", 0), (5, -1), (5, 6), (5, True), (5, "2")):
            with self.subTest(completion=completion, reasoning=reasoning):
                usage = {"completion_tokens": completion, "completion_tokens_details": {"reasoning_tokens": reasoning}}
                result = self.collect([event(finish="stop", usage=usage), ("message", "[DONE]")])
                self.assertIsNone(result["metrics"]["reasoning_tokens_reported"])
                self.assertIsNone(result["metrics"]["non_reasoning_tokens_reported"])
                if type(completion) is not int or completion < 0:
                    self.assertIsNone(result["metrics"]["completion_tokens_reported"])

    def test_collect_usage_numeric_whitelist_and_no_source_mutation(self):
        usage = {"prompt_tokens": 20, "completion_tokens": 100, "total_tokens": 120,
                 "debug": "fakeendpoint Bearer SECRET PRIVATE_RESPONSE", "unknown_count": 999,
                 "prompt_tokens_details": {"cached_tokens": 12, "audio_tokens": 2,
                                            "debug": "fakeendpoint", "unknown_count": 999},
                 "completion_tokens_details": {"reasoning_tokens": 90, "audio_tokens": 1,
                                                "accepted_prediction_tokens": 3, "rejected_prediction_tokens": 4,
                                                "debug": "Bearer SECRET PRIVATE_RESPONSE", "unknown_count": 999}}
        original = copy.deepcopy(usage)
        result = self.collect([event({"content": "answer"}, finish="stop", usage=usage), ("message", "[DONE]")])
        self.assertEqual(result["usage"], {
            "prompt_tokens": 20, "completion_tokens": 100, "total_tokens": 120,
            "prompt_tokens_details": {"cached_tokens": 12, "audio_tokens": 2},
            "completion_tokens_details": {"reasoning_tokens": 90, "audio_tokens": 1,
                                          "accepted_prediction_tokens": 3, "rejected_prediction_tokens": 4},
        })
        self.assertEqual(result["metrics"]["reasoning_tokens_reported"], 90)
        self.assertEqual(result["metrics"]["non_reasoning_tokens_reported"], 10)
        self.assertEqual(usage, original)
        for text in ("fakeendpoint", "Bearer SECRET", "PRIVATE_RESPONSE", "unknown_count"):
            self.assertNotIn(text, json.dumps(result["usage"]))

    def test_collect_malicious_usage_details_and_malformed_counts_safe(self):
        for value in (True, -1, 1.5, "PRIVATE_RESPONSE", ["Bearer SECRET"], {"debug": "fakeendpoint"}, None):
            with self.subTest(value=value):
                usage = {"prompt_tokens": value, "completion_tokens": value, "total_tokens": value,
                         "prompt_tokens_details": {"cached_tokens": value, "debug": "fakeendpoint"},
                         "completion_tokens_details": {"reasoning_tokens": value, "audio_tokens": value,
                                                        "accepted_prediction_tokens": value, "rejected_prediction_tokens": value}}
                result = self.collect([event({"content": "answer"}, finish="stop", usage=usage), ("message", "[DONE]")])
                self.assertEqual(result["usage"], {"prompt_tokens_details": {}, "completion_tokens_details": {}})
                for key in ("completion_tokens_reported", "reasoning_tokens_reported", "non_reasoning_tokens_reported",
                            "end_to_end_tokens_per_second", "content_decode_tokens_per_second_estimate"):
                    self.assertIsNone(result["metrics"][key])
        for details in (["PRIVATE_RESPONSE"], "Bearer SECRET", 42, None):
            with self.subTest(details=details):
                result = self.collect([event(finish="stop", usage={"completion_tokens": 10,
                    "prompt_tokens_details": details, "completion_tokens_details": details}), ("message", "[DONE]")])
                self.assertEqual(result["usage"], {"completion_tokens": 10})
                self.assertIsNone(result["metrics"]["reasoning_tokens_reported"])

    def test_collect_hidden_reasoning_usage_excludes_content_decode_estimate(self):
        result = self.collect([event({"content": "final answer"}), event(finish="stop", usage={
            "completion_tokens": 100, "completion_tokens_details": {"reasoning_tokens": 90}}), ("message", "[DONE]")])
        self.assertEqual(result["reasoning_content"], "")
        self.assertIsNone(result["metrics"]["first_reasoning_seconds"])
        self.assertEqual(result["metrics"]["completion_tokens_reported"], 100)
        self.assertEqual(result["metrics"]["reasoning_tokens_reported"], 90)
        self.assertEqual(result["metrics"]["non_reasoning_tokens_reported"], 10)
        self.assertIsNone(result["metrics"]["content_decode_tokens_per_second_estimate"])

    def test_collect_root_reasoning_and_both_agree(self):
        for count in (0, 4, 10):
            for nested in (False, True):
                with self.subTest(count=count, nested=nested):
                    usage = {"completion_tokens": 10, "reasoning_tokens": count}
                    if nested:
                        usage["completion_tokens_details"] = {"reasoning_tokens": count}
                    result = self.collect([event({"content": "answer"}, finish="stop", usage=usage),
                                           ("message", "[DONE]")])
                    self.assertEqual(result["usage"], usage)
                    self.assertEqual(result["metrics"]["reasoning_tokens_reported"], count)
                    self.assertEqual(result["metrics"]["non_reasoning_tokens_reported"], 10 - count)
                    self.assertEqual(result["metrics"]["reasoning_tokens_source"], "both" if nested else "root")
                    if count:
                        self.assertIsNone(result["metrics"]["content_decode_tokens_per_second_estimate"])

    def test_collect_root_reasoning_invalid_values_are_not_signals(self):
        for value in (True, False, "3", -1, 3.0, None, [], {}):
            with self.subTest(value=value):
                result = self.collect([event({"content": "372"}, finish="stop", usage={
                    "completion_tokens": 10, "reasoning_tokens": value}), ("message", "[DONE]")])
                self.assertEqual(result["usage"], {"completion_tokens": 10})
                self.assertIsNone(result["metrics"]["reasoning_tokens_reported"])
                self.assertIsNone(result["metrics"]["non_reasoning_tokens_reported"])
                self.assertIsNotNone(result["metrics"]["content_decode_tokens_per_second_estimate"])

    def test_collect_root_reasoning_missing_completion_or_exceeds_completion(self):
        for completion in (None, True, "10", -1, 2):
            with self.subTest(completion=completion):
                result = self.collect([event({"content": "answer"}, finish="stop", usage={
                    "completion_tokens": completion, "reasoning_tokens": 3}), ("message", "[DONE]")])
                self.assertEqual(result["usage"]["reasoning_tokens"], 3)
                self.assertIsNone(result["metrics"]["reasoning_tokens_reported"])
                self.assertIsNone(result["metrics"]["non_reasoning_tokens_reported"])
                self.assertIsNone(result["metrics"]["content_decode_tokens_per_second_estimate"])

    def test_collect_root_detail_conflicts_never_invent_split(self):
        for root, detail in ((0, 3), (3, 0), (3, 4), (12, 2)):
            with self.subTest(root=root, detail=detail):
                usage = {"completion_tokens": 10, "reasoning_tokens": root,
                         "completion_tokens_details": {"reasoning_tokens": detail}}
                result = self.collect([event({"content": "answer"}, finish="stop", usage=usage),
                                       ("message", "[DONE]")])
                self.assertEqual(result["usage"], usage)
                self.assertEqual(result["metrics"]["reasoning_tokens_source"], "conflict")
                self.assertIsNone(result["metrics"]["reasoning_tokens_reported"])
                self.assertIsNone(result["metrics"]["non_reasoning_tokens_reported"])
                self.assertIsNone(result["metrics"]["content_decode_tokens_per_second_estimate"])

    def test_collect_valid_reasoning_source_survives_invalid_other_source(self):
        for invalid in (True, False, -1, "4"):
            for root_valid in (True, False):
                with self.subTest(invalid=invalid, root_valid=root_valid):
                    usage = {"completion_tokens": 10, "reasoning_tokens": 4 if root_valid else invalid,
                             "completion_tokens_details": {"reasoning_tokens": invalid if root_valid else 4}}
                    result = self.collect([event(finish="stop", usage=usage), ("message", "[DONE]")])
                    self.assertEqual(result["metrics"]["reasoning_tokens_reported"], 4)
                    self.assertEqual(result["metrics"]["non_reasoning_tokens_reported"], 6)

    def test_cli_root_hidden_reasoning_guard_and_default_redaction(self):
        for usage in ({"reasoning_tokens": 3}, {"reasoning_tokens": 3, "completion_tokens": 2},
                      {"reasoning_tokens": 3, "completion_tokens": 10},
                      {"reasoning_tokens": 0, "completion_tokens": 10,
                       "completion_tokens_details": {"reasoning_tokens": 3}},
                      {"reasoning_tokens": 3, "completion_tokens": 10,
                       "completion_tokens_details": {"reasoning_tokens": 0}}):
            with self.subTest(usage=usage):
                def stream(*args):
                    return self.collect([event({"content": "372"}, finish="stop", usage=dict(
                        usage, debug="fakeendpoint Bearer SECRET PRIVATE_RESPONSE", unknown_count=42,
                        thinking_observed=False, count_is_exact=True)), ("message", "[DONE]")])

                status, stdout, stderr = self.run_case("exact-short-output", stream, "http://fakeendpoint/v1")
                self.assertEqual((status, stderr), (1, ""))
                record = json.loads(stdout.splitlines()[1])
                self.assertIs(record["thinking_observed"], True)
                self.assertEqual(record["correctness"]["reason"], "thinking_disabled_but_observed")
                self.assertIsNone(record["metrics"]["content_decode_tokens_per_second_estimate"])
                self.assertNotIn("response", record)
                for private in ("fakeendpoint", "SECRET", "PRIVATE_RESPONSE", "unknown_count", "count_is_exact"):
                    self.assertNotIn(private, stdout)

    def test_cli_invalid_root_counts_do_not_fail_off_control(self):
        for count in (True, False, -1, "3"):
            with self.subTest(count=count):
                def stream(*args):
                    return self.collect([event({"content": "372"}, finish="stop", usage={
                        "reasoning_tokens": count}), ("message", "[DONE]")])

                status, stdout, stderr = self.run_case("exact-short-output", stream)
                self.assertEqual((status, stderr), (0, ""))
                record = json.loads(stdout.splitlines()[1])
                self.assertIs(record["thinking_observed"], False)
                self.assertEqual(record["correctness"]["status"], "passed")

    def test_collect_unknown_count_flags_and_missing_counts_not_estimated(self):
        result = self.collect([event({"content": "one two three"}, finish="stop", usage={
            "unknown_count": 99, "thinking_observed": True, "reasoning_tokens_reported": 3,
            "completion_tokens_details": {"count_is_exact": True}}), ("message", "[DONE]")])
        self.assertEqual(result["usage"], {"completion_tokens_details": {}})
        for key in ("completion_tokens_reported", "reasoning_tokens_reported", "non_reasoning_tokens_reported",
                    "end_to_end_tokens_per_second", "content_decode_tokens_per_second_estimate", "token_tpot_seconds"):
            self.assertIsNone(result["metrics"][key])

    def test_collect_missing_done_or_finish_rejected(self):
        for events in ([event({"content": "x"}, finish="stop")],
                       [event({"content": "x"}), ("message", "[DONE]")], []):
            with self.subTest(events=events):
                with self.assertRaisesRegex(CLIENT.ProtocolError, "incomplete_stream"):
                    CLIENT.collect_stream(iter(events), 0, clock=lambda: 1)

    def test_collect_error_events_invalid_json_and_usage(self):
        for item, message in ((("error", "{}"), "server_stream_error"),
                              (("message", '{"error": {"message": "bad"}}'), "server_stream_error"),
                              (("message", "[]"), "server_stream_error"),
                              (("message", "not json"), "invalid_stream_json"),
                              (("message", '{"usage": [], "choices": []}'), "invalid_usage")):
            with self.subTest(item=item):
                with self.assertRaisesRegex(CLIENT.ProtocolError, message):
                    CLIENT.collect_stream(iter([item]), 0, clock=lambda: 1)

    def test_collect_multiple_choice_indices_rejected(self):
        chunk = {"choices": [{"index": 0, "delta": {"content": "a"}},
                             {"index": 1, "delta": {"content": "b"}}]}
        with self.assertRaisesRegex(CLIENT.ProtocolError, "multiple_choices_not_supported"):
            CLIENT.collect_stream(iter([("message", json.dumps(chunk))]), 0, clock=lambda: 1)

    def test_collect_duplicate_choice_indices_rejected(self):
        chunk = {"choices": [{"index": 0, "delta": {"content": "a"}, "finish_reason": "stop"},
                             {"index": 0, "delta": {"content": "b"}, "finish_reason": "stop"}]}
        with self.assertRaisesRegex(CLIENT.ProtocolError, "multiple_choices_not_supported"):
            self.collect([("message", json.dumps(chunk)), ("message", "[DONE]")])

    def test_collect_invalid_text_and_tool_fragments_rejected(self):
        for delta, message in (({"content": 42}, "nontext_delta"),
                               ({"reasoning_content": ["x"]}, "nontext_delta"),
                               ({"tool_calls": [{"index": -1}]}, "invalid_tool_index"),
                               ({"tool_calls": [{"index": True}]}, "invalid_tool_index"),
                               ({"tool_calls": [{"index": 0, "function": {"arguments": 42}}]}, "nontext_tool_delta")):
            with self.subTest(delta=delta):
                with self.assertRaisesRegex(CLIENT.ProtocolError, message):
                    CLIENT.collect_stream(iter([event(delta)]), 0, clock=lambda: 1)

    def test_correctness_exact_is_not_whitespace_normalized(self):
        gate = self.cases["exact-short-output"]["check"]
        for text, expected in (("372", "passed"), ("372\n", "failed"), (" 372", "failed"), ("373", "failed")):
            with self.subTest(text=text):
                self.assertEqual(CLIENT.correctness(gate, response(text), "quality")["status"], expected)
        self.assertEqual(CLIENT.correctness(gate, response("372", tools=[{}]), "quality")["status"], "failed")

    def test_correctness_json_exact_structure(self):
        gate = self.cases["strict-json-schema"]["check"]
        for text, expected in (('{"label":"thor", "answer":42}', "passed"),
                               ('{"answer":42,"label":"thor","extra":0}', "failed"),
                               ('{"answer":"42","label":"thor"}', "failed"),
                                ('{"answer":42.0,"label":"thor"}', "failed"),
                                ('{"answer":0,"answer":42,"label":"thor"}', "failed"),
                               ('{"answer":42}', "failed"), ('```json\n{}\n```', "failed"), ("{", "failed")):
            with self.subTest(text=text):
                self.assertEqual(CLIENT.correctness(gate, response(text), "quality")["status"], expected)
        self.assertEqual(CLIENT.correctness(gate, response(json.dumps(gate["expected"]), tools=[{}]), "quality")["status"], "failed")

    def test_correctness_tool_exact_call_and_arguments(self):
        gate = self.cases["tool-get-weather"]["check"]
        call = {"id": "test-call", "type": "function", "function": {"name": "get_weather", "arguments": '{"city": "Beijing"}'}}
        self.assertEqual(CLIENT.correctness(gate, response(finish="tool_calls", tools=[call]), "quality")["status"], "passed")
        for content, calls in (("invented weather", [call]), ("", []), ("", [call, call]),
                               ("", [{"function": {"name": "other", "arguments": '{"city":"Beijing"}'}}]),
                               ("", [{"function": {"name": "get_weather", "arguments": '{"city":"Paris"}'}}]),
                                ("", [{"function": {"name": "get_weather", "arguments": '{"city":"Beijing","extra":1}'}}]),
                                ("", [{"function": {"name": "get_weather", "arguments": '{"city":"Paris","city":"Beijing"}'}}]),
                               ("", [{"function": {"name": "get_weather", "arguments": "{"}}])):
            with self.subTest(content=content, calls=calls):
                self.assertEqual(CLIENT.correctness(gate, response(content, "tool_calls", calls), "quality")["status"], "failed")

    def test_correctness_ast_only_never_executes_generated_code(self):
        gate = self.cases["python-interval-repair-ast"]["check"]
        with tempfile.TemporaryDirectory() as directory:
            marker = pathlib.Path(directory, "must-not-exist")
            code = (f"from pathlib import Path\nPath({str(marker)!r}).write_text('executed')\n"
                    "raise RuntimeError('must not execute')\n"
                    "def merge_intervals(intervals):\n    return intervals\n" + "assert False\n" * 5)
            with mock.patch("builtins.exec", side_effect=AssertionError("generated code executed")):
                self.assertEqual(CLIENT.correctness(gate, response(code), "quality"),
                                 {"status": "passed", "scope": "syntax_only"})
            self.assertFalse(marker.exists())
        for code in ("def merge_intervals(:", "def other():\n    pass\n" + "assert True\n" * 5,
                     "def merge_intervals(x):\n    return x\n" + "assert True\n" * 4):
            with self.subTest(code=code):
                self.assertEqual(CLIENT.correctness(gate, response(code), "quality")["status"], "failed")

    def test_correctness_manual_needs_review(self):
        gate = self.cases["agent-plan-thinking-low"]["check"]
        self.assertEqual(CLIENT.correctness(gate, response("a plan"), "quality"),
                         {"status": "needs_review", "scope": "manual", "criteria": gate["criteria"]})

    def test_correctness_manual_reasoning_only_fails(self):
        result = self.collect([event({"reasoning_content": "PRIVATE_RESPONSE"}, finish="stop"), ("message", "[DONE]")])
        for case_id in ("agent-plan-thinking-low", "stress-numbered-records-8192"):
            with self.subTest(case=case_id):
                case = self.cases[case_id]
                checked = CLIENT.correctness(case["check"], result, case["mode"])
                self.assertEqual(checked["status"], "failed")
                self.assertEqual(checked["reason"], "no_final_output")

    def test_correctness_length_does_not_automatically_pass(self):
        for case_id, content in (("exact-short-output", "372"),
                                 ("strict-json-schema", '{"answer":42,"label":"thor"}'),
                                 ("agent-plan-thinking-low", "a plan")):
            with self.subTest(case=case_id):
                result = CLIENT.correctness(self.cases[case_id]["check"], response(content, "length"), "quality")
                self.assertEqual(result["status"], "failed")
                self.assertEqual(result["reason"], "incomplete_generation")
        gate = self.cases["stress-numbered-records-8192"]["check"]
        self.assertEqual(CLIENT.correctness(gate, response("RECORD 1: amber", "length"), "stress")["status"], "needs_review")
        self.assertEqual(CLIENT.correctness({"kind": "none"}, response("", "length"), "throughput")["status"], "not_checked")

    def test_natural_prose_gate_validation(self):
        CLIENT.check_gate({"kind": "natural_prose", "min_chars": 10})
        CLIENT.check_gate({"kind": "natural_prose", "min_chars": 10, "required_suffix": "fin."})
        for invalid in ({"kind": "natural_prose"}, {"kind": "natural_prose", "min_chars": 0},
                        {"kind": "natural_prose", "min_chars": "10"},
                        {"kind": "natural_prose", "min_chars": 10, "extra": 1},
                        {"kind": "natural_prose", "min_chars": 10, "required_suffix": ""}):
            with self.subTest(gate=invalid):
                with self.assertRaises(ValueError):
                    CLIENT.check_gate(invalid)

    def test_natural_prose_correctness_natural_stop(self):
        gate = {"kind": "natural_prose", "min_chars": 5}
        self.assertEqual(CLIENT.correctness(gate, response("你" * 20, "stop"), "quality"),
                         {"status": "passed", "scope": "natural_prose", "chars": 20, "natural_stop": True})
        length = CLIENT.correctness(gate, response("你" * 20, "length"), "quality")
        self.assertEqual((length["status"], length["reason"]), ("failed", "incomplete_generation"))
        short = CLIENT.correctness(gate, response("你" * 3, "stop"), "quality")
        self.assertEqual((short["status"], short["reason"]), ("failed", "gate_mismatch"))
        tools = CLIENT.correctness(gate, response("你" * 20, "tool_calls", tools=[{}]), "quality")
        self.assertEqual(tools["status"], "failed")

    def test_natural_prose_correctness_required_suffix(self):
        gate = {"kind": "natural_prose", "min_chars": 5, "required_suffix": "完。"}
        self.assertEqual(CLIENT.correctness(gate, response("你" * 20 + "完。", "stop"), "quality")["status"], "passed")
        self.assertEqual(CLIENT.correctness(gate, response("你" * 20 + "毕。", "stop"), "quality")["status"], "failed")

    def test_generation_safety_fixtures_load(self):
        fixtures, _ = CLIENT.load_assets(fixtures_path=pathlib.Path(__file__).resolve().parent.parent
                                         / "docs/inference/thor/benchmark/generation-safety.json")
        cases = {case["id"]: case for case in fixtures["cases"]}
        self.assertEqual(set(cases), {"natural-prose-off", "natural-prose-low",
                                      "cancel-long-generation", "recovery-short-json"})
        self.assertEqual(cases["natural-prose-off"]["check"], {"kind": "natural_prose", "min_chars": 600})
        self.assertTrue(cases["natural-prose-low"]["request"]["chat_template_kwargs"]["enable_thinking"])
        self.assertTrue(cases["cancel-long-generation"]["request"]["ignore_eos"])
        self.assertEqual(cases["cancel-long-generation"]["mode"], "throughput")

    def test_natural_prose_requires_quality_mode(self):
        path = (pathlib.Path(__file__).resolve().parent.parent
                / "docs/inference/thor/benchmark/generation-safety.json")
        fixtures, _ = CLIENT.load_assets(fixtures_path=path)
        with tempfile.TemporaryDirectory() as directory:
            bad = pathlib.Path(directory, "fixtures.json")
            for case in fixtures["cases"]:
                if case["check"]["kind"] == "natural_prose":
                    case["mode"] = "stress"
            bad.write_text(json.dumps(fixtures), encoding="utf-8")
            with self.assertRaises(ValueError):
                CLIENT.load_assets(fixtures_path=bad)

    def test_cli_default_and_explicit_validate_never_stream(self):
        with mock.patch.object(CLIENT, "stream_request", side_effect=AssertionError("network forbidden")) as stream:
            for argv in ([], ["validate"]):
                with self.subTest(argv=argv):
                    status, stdout, stderr = self.cli(argv)
                    self.assertEqual((status, stderr), (0, ""))
                    result = json.loads(stdout)
                    self.assertEqual(result["status"], "valid")
                    self.assertEqual(result["case_count"], 16)
                    self.assertEqual(len(result["profiles"]), 11)
            stream.assert_not_called()

    def test_cli_plan_never_stream_and_preserves_assets(self):
        original = copy.deepcopy(self.fixtures)
        with mock.patch.object(CLIENT, "stream_request", side_effect=AssertionError("network forbidden")) as stream:
            status, stdout, stderr = self.cli(["plan", "--suite", "all"])
            stream.assert_not_called()
        self.assertEqual((status, stderr), (0, ""))
        result = json.loads(stdout)
        self.assertEqual(len(result["cases"]), 16)
        self.assertEqual(result["runtime_record_template"], CLIENT.runtime_template(self.profiles["P"]))
        self.assertTrue(all(case["request"]["stream"] for case in result["cases"]))
        self.assertNotIn("seed", result)
        self.assertTrue(all("seed" not in case["request"] for case in result["cases"]))
        budget = sum(case["request"]["max_tokens"] * (1 + len(case.get("followups", []))) for case in self.cases.values()) * 4
        self.assertEqual(result["maximum_completion_budget"], budget)
        self.assertEqual(CLIENT.load_assets()[0], original)

    def test_cli_seeded_plans_preserve_prompts_and_pair_profiles(self):
        original = copy.deepcopy(self.fixtures)
        for policy in ("isolated-prefix", "shared-prefix"):
            paired = []
            for profile in ("S0", "G1"):
                with self.subTest(policy=policy, profile=profile), \
                     mock.patch.object(CLIENT, "load_assets", return_value=(self.fixtures, {"profiles": list(self.profiles.values())})), \
                     mock.patch.object(CLIENT, "stream_request", side_effect=AssertionError("network forbidden")) as stream:
                    argv = ["plan", "--suite", "all", "--profile", profile,
                            "--model", "test-model", "--cache-policy", policy]
                    status, stdout, stderr = self.cli(argv)
                    self.assertEqual((status, stderr), (0, ""))
                    default = json.loads(stdout)
                    self.assertNotIn("seed", default)
                    status, stdout, stderr = self.cli(argv + ["--seed", "42"])
                    self.assertEqual((status, stderr), (0, ""))
                    seeded = json.loads(stdout)
                    self.assertEqual(seeded["seed"], 42)
                    paired.append(copy.deepcopy(seeded["cases"]))
                    del seeded["seed"]
                    for case in seeded["cases"]:
                        self.assertEqual(case["request"].pop("seed"), 42)
                        if policy == "shared-prefix":
                            self.assertEqual(case["request"], CLIENT.build_request(self.cases[case["id"]], "test-model"))
                    self.assertEqual(seeded, default)
                    stream.assert_not_called()
            self.assertEqual(paired[0], paired[1])
        self.assertEqual(self.fixtures, original)

    def test_cli_run_seed_all_cases_warmups_repeats_and_followups(self):
        original = copy.deepcopy(self.fixtures)
        expected_count = sum(1 + len(case.get("followups", [])) for case in self.cases.values()) * 3
        with tempfile.TemporaryDirectory() as directory:
            runtime_path = pathlib.Path(directory, "runtime.json")
            runtime_path.write_text(json.dumps(self.runtime()), encoding="utf-8")
            for seed in (None, 42):
                for policy in ("isolated-prefix", "shared-prefix"):
                    captured = []

                    def stream(base_url, request, *args):
                        captured.append(copy.deepcopy(request))
                        return self.collect([event({"content": "answer"}, finish="stop"), ("message", "[DONE]")])

                    with self.subTest(seed=seed, policy=policy), \
                         mock.patch.object(CLIENT, "load_assets", return_value=(self.fixtures, {"profiles": list(self.profiles.values())})), \
                         mock.patch.object(CLIENT, "stream_request", side_effect=stream), \
                         mock.patch.object(CLIENT, "correctness", return_value={"status": "passed"}):
                        argv = ["run", "--suite", "all", "--model", "test-model",
                                "--base-url", "http://127.0.0.1:1/v1", "--runtime-record", str(runtime_path),
                                "--warmups", "1", "--repeats", "2", "--cache-policy", policy]
                        if seed is not None:
                            argv += ["--seed", str(seed)]
                        status, stdout, stderr = self.cli(argv)
                        self.assertEqual((status, stderr), (0, ""))
                        header, *records = [json.loads(line) for line in stdout.splitlines()]
                        self.assertEqual(header["fixture_sha256"], CLIENT.digest(original))
                        self.assertEqual(len(captured), expected_count)
                        self.assertEqual(len(records), expected_count)
                        if seed is None:
                            self.assertNotIn("seed", header)
                        else:
                            self.assertEqual(header["seed"], seed)
                        prompts = {}
                        for record, request in zip(records, captured):
                            if seed is None:
                                self.assertNotIn("seed", request)
                            else:
                                self.assertEqual(request["seed"], seed)
                            self.assertEqual(record["request_sha256"], CLIENT.digest(request))
                            if policy == "shared-prefix":
                                key = (record["case_id"], record["turn"])
                                self.assertEqual(request["messages"], prompts.setdefault(key, request["messages"]))
                                if record["turn"] == 0:
                                    case = self.cases[record["case_id"]]
                                    self.assertEqual(request, CLIENT.build_request(case, "test-model", seed=seed))
                        self.assertEqual(self.fixtures, original)
        self.assertEqual(CLIENT.load_assets()[0], original)

    def test_cli_run_without_runtime_record_rejected_offline(self):
        with mock.patch.object(CLIENT, "stream_request", side_effect=AssertionError("network forbidden")) as stream:
            status, stdout, stderr = self.cli(["run", "--model", "test-model", "--base-url", "http://127.0.0.1:1/v1"])
            stream.assert_not_called()
        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertIn("benchmark preflight failed: ValueError", stderr)

    def test_cli_new_fixture_empty_default_selection_is_not_a_successful_run(self):
        fixture = CLIENT.ASSETS / "thinking-stability.json"
        with mock.patch.object(CLIENT, "stream_request", side_effect=AssertionError("network forbidden")) as stream:
            for command in ("plan", "run"):
                with self.subTest(command=command):
                    status, stdout, stderr = self.cli([command, "--fixtures", str(fixture), "--model", "test-model"])
                    self.assertEqual(status, 2)
                    self.assertEqual(stdout, "")
                    self.assertIn("preflight failed", stderr)
            stream.assert_not_called()

    def test_cli_stdout_omits_private_response_endpoint_and_usage_debug(self):
        usage = {"prompt_tokens": 20, "completion_tokens": 100, "total_tokens": 120,
                 "endpoint": "http://fakeendpoint.invalid/v1", "authorization": "Bearer SECRET",
                 "debug_response": "PRIVATE_RESPONSE", "unknown_count": 456,
                 "prompt_tokens_details": {"cached_tokens": 12, "debug": "fakeendpoint"},
                 "completion_tokens_details": {"reasoning_tokens": 90, "debug": "Bearer SECRET PRIVATE_RESPONSE"}}

        def stream(url, request, api_key, *args):
            self.assertEqual(url, "http://fakeendpoint.invalid/v1")
            self.assertEqual(api_key, "SECRET")
            return self.collect([event({"content": "PRIVATE_RESPONSE"}, finish="stop", usage=usage), ("message", "[DONE]")])

        status, stdout, stderr = self.run_case("historical-json-80", stream, "http://fakeendpoint.invalid/v1")
        self.assertEqual((status, stderr), (1, ""))
        for private in ("fakeendpoint", "Bearer SECRET", "PRIVATE_RESPONSE", "unknown_count"):
            self.assertNotIn(private, stdout)
        record = json.loads(stdout.splitlines()[1])
        self.assertEqual(record["correctness"]["reason"], "thinking_disabled_but_observed")
        self.assertNotIn("response", record)
        self.assertEqual(record["usage"], {"prompt_tokens": 20, "completion_tokens": 100, "total_tokens": 120,
                                          "prompt_tokens_details": {"cached_tokens": 12},
                                          "completion_tokens_details": {"reasoning_tokens": 90}})
        self.assertIsNone(record["metrics"]["content_decode_tokens_per_second_estimate"])

    def test_cli_invalid_usage_list_is_protocol_error_without_private_text(self):
        def stream(*args):
            return self.collect([event({"content": "PRIVATE_RESPONSE"}, finish="stop",
                                       usage=["fakeendpoint", "Bearer SECRET"]), ("message", "[DONE]")])

        status, stdout, stderr = self.run_case("historical-json-80", stream)
        self.assertEqual((status, stderr), (1, ""))
        record = json.loads(stdout.splitlines()[1])
        self.assertEqual(record["status"], "error")
        self.assertEqual(record["error"], "invalid_usage")
        for private in ("fakeendpoint", "Bearer SECRET", "PRIVATE_RESPONSE", "Traceback"):
            self.assertNotIn(private, stdout + stderr)

    def test_cli_thinking_off_reasoning_output_fails(self):
        def stream(*args):
            return self.collect([event({"content": "372", "reasoning_content": "PRIVATE_RESPONSE"}, finish="stop"),
                                 ("message", "[DONE]")])

        status, stdout, stderr = self.run_case("exact-short-output", stream)
        self.assertEqual((status, stderr), (1, ""))
        record = json.loads(stdout.splitlines()[1])
        self.assertEqual(record["correctness"]["status"], "failed")
        self.assertEqual(record["correctness"]["reason"], "thinking_disabled_but_observed")
        self.assertIs(record["thinking_observed"], True)
        self.assertNotIn("PRIVATE_RESPONSE", stdout)

    def test_cli_thinking_off_hidden_reasoning_without_completion_count_fails(self):
        def stream(*args):
            return self.collect([event({"content": "372"}, finish="stop",
                                       usage={"completion_tokens_details": {"reasoning_tokens": 3}}),
                                 ("message", "[DONE]")])

        status, stdout, stderr = self.run_case("exact-short-output", stream)
        self.assertEqual((status, stderr), (1, ""))
        record = json.loads(stdout.splitlines()[1])
        self.assertEqual(record["correctness"]["reason"], "thinking_disabled_but_observed")
        self.assertIs(record["thinking_observed"], True)
        self.assertIsNone(record["metrics"]["reasoning_tokens_reported"])

    def test_cli_interrupt_records_cancellation(self):
        def stream(*args):
            raise KeyboardInterrupt

        status, stdout, stderr = self.run_case("exact-short-output", stream)
        self.assertEqual((status, stderr), (130, ""))
        record = json.loads(stdout.splitlines()[1])
        self.assertEqual(record["status"], "cancelled")
        self.assertEqual(record["error"], "client_interrupted")
        self.assertGreaterEqual(record["metrics"]["wall_seconds"], 0)

    def test_cli_thinking_on_without_forwarded_reasoning_excludes_content_estimate(self):
        collected = []

        def stream(*args):
            result = self.collect([event({"content": "a plan"}, finish="stop", usage={"completion_tokens": 100}),
                                   ("message", "[DONE]")])
            collected.append(copy.deepcopy(result))
            return result

        status, stdout, stderr = self.run_case("agent-plan-thinking-low", stream)
        self.assertEqual((status, stderr), (0, ""))
        self.assertIsNotNone(collected[0]["metrics"]["content_decode_tokens_per_second_estimate"])
        record = json.loads(stdout.splitlines()[1])
        self.assertEqual(record["correctness"]["status"], "needs_review")
        self.assertIs(record["thinking_observed"], False)
        self.assertIsNone(record["metrics"]["content_decode_tokens_per_second_estimate"])

    def test_cli_manual_reasoning_only_fails(self):
        def stream(*args):
            return self.collect([event({"reasoning_content": "PRIVATE_RESPONSE"}, finish="stop"), ("message", "[DONE]")])

        status, stdout, stderr = self.run_case("agent-plan-thinking-low", stream)
        self.assertEqual((status, stderr), (1, ""))
        record = json.loads(stdout.splitlines()[1])
        self.assertEqual(record["correctness"]["status"], "failed")
        self.assertEqual(record["correctness"]["reason"], "no_final_output")
        self.assertNotIn("PRIVATE_RESPONSE", stdout)

    def test_cli_malformed_delta_tool_structure_is_protocol_error(self):
        for delta in ([], ["PRIVATE_RESPONSE"], "fakeendpoint", {"tool_calls": "Bearer SECRET"},
                      {"tool_calls": 42}, {"tool_calls": {}}, {"tool_calls": {"debug": "PRIVATE_RESPONSE"}},
                      {"tool_calls": ["PRIVATE_RESPONSE"]}, {"tool_calls": [None]},
                      {"tool_calls": [{"index": 0, "function": ["PRIVATE_RESPONSE"]}]},
                      {"tool_calls": [{"index": 0, "function": []}]},
                      {"tool_calls": [{"index": 0, "function": "Bearer SECRET"}]},
                      {"tool_calls": [{"index": 0, "id": {"debug": "fakeendpoint"}}]}):
            with self.subTest(delta=delta):
                def stream(*args):
                    chunk = {"choices": [{"index": 0, "delta": delta, "finish_reason": "stop"}]}
                    return self.collect([("message", json.dumps(chunk)), ("message", "[DONE]")])

                status, stdout, stderr = self.run_case("historical-json-80", stream)
                self.assertEqual((status, stderr), (1, ""))
                record = json.loads(stdout.splitlines()[1])
                self.assertEqual(record["status"], "error")
                self.assertEqual(record["correctness"]["status"], "not_checked")
                for private in ("Traceback", "AttributeError", "TypeError", "fakeendpoint", "Bearer SECRET", "PRIVATE_RESPONSE"):
                    self.assertNotIn(private, stdout + stderr)

    def test_cli_cache_followups_four_turns_and_isolation(self):
        case = self.cases["cache-public-archive-four-turns"]
        original = copy.deepcopy(self.fixtures)
        specs = [{"check": case["check"]}] + case["followups"]
        with tempfile.TemporaryDirectory() as directory:
            runtime_path = pathlib.Path(directory, "runtime.json")
            runtime_path.write_text(json.dumps(self.runtime()), encoding="utf-8")
            for policy in ("isolated-prefix", "shared-prefix"):
                captured = []

                def stream(base_url, request, *args):
                    captured.append(copy.deepcopy(request))
                    result = self.collect([event({"content": json.dumps(specs[(len(captured) - 1) % 4]["check"]["expected"])},
                                                 finish="stop"), ("message", "[DONE]")])
                    return result

                with self.subTest(policy=policy), mock.patch.object(CLIENT, "stream_request", side_effect=stream):
                    status, stdout, stderr = self.cli([
                        "run", "--case", case["id"], "--model", "test-model", "--base-url", "http://127.0.0.1:1/v1",
                        "--runtime-record", str(runtime_path), "--warmups", "0", "--repeats", "2", "--cache-policy", policy,
                    ])
                    self.assertEqual((status, stderr), (0, ""))
                    records = [json.loads(line) for line in stdout.splitlines()]
                    self.assertEqual(len(captured), 8)
                    self.assertEqual(len(records), 9)
                    self.assertEqual([record["turn"] for record in records[1:]], [0, 1, 2, 3] * 2)
                    self.assertTrue(all(record["correctness"]["status"] == "passed" for record in records[1:]))
                    offset = int(policy == "isolated-prefix")
                    for index, request in enumerate(captured):
                        turn = index % 4
                        self.assertEqual(len(request["messages"]), offset + 1 + 2 * turn)
                        self.assertEqual(request["messages"][offset]["content"],
                                         case["prefix"]["line"] * case["prefix"]["repeat"] + case["request"]["messages"][0]["content"])
                        for previous_turn in range(turn):
                            self.assertEqual(json.loads(request["messages"][offset + 1 + 2 * previous_turn]["content"]),
                                             specs[previous_turn]["check"]["expected"])
                            self.assertEqual(request["messages"][offset + 2 + 2 * previous_turn],
                                             case["followups"][previous_turn]["messages"][0])
                    if offset:
                        self.assertEqual(captured[0]["messages"][0], captured[3]["messages"][0])
                        self.assertNotEqual(captured[0]["messages"][0], captured[4]["messages"][0])
        self.assertEqual(self.fixtures, original)
        self.assertEqual(CLIENT.load_assets()[0], original)


class TransportChecks(unittest.TestCase):
    def test_connect_interrupt_closes_unowned_socket(self):
        transport = mock.Mock(spec=socket.socket)
        transport.connect.side_effect = KeyboardInterrupt
        addresses = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 1))]
        with mock.patch.object(CLIENT.socket, "getaddrinfo", return_value=addresses), \
             mock.patch.object(CLIENT.socket, "socket", return_value=transport):
            with self.assertRaises(KeyboardInterrupt):
                CLIENT.stream_request("http://connect-test.invalid/v1", {}, deadline=1)
        transport.close.assert_called_once()

    def test_blocked_dns_deadline_releases_and_joins_resolver(self):
        release, entered = threading.Event(), threading.Event()
        workers = []
        connection = mock.Mock()

        def blocked_dns(*args, **kwargs):
            workers.append(threading.current_thread())
            entered.set()
            if not release.wait(2):
                raise socket.gaierror("mock DNS was not released")
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 1))]

        with mock.patch.object(CLIENT.socket, "getaddrinfo", side_effect=blocked_dns), \
             mock.patch.object(CLIENT.socket, "socket", side_effect=AssertionError("network forbidden")), \
             mock.patch.object(CLIENT.http.client, "HTTPConnection", return_value=connection):
            start = time.monotonic()
            try:
                with self.assertRaises(TimeoutError):
                    CLIENT.stream_request("http://dns-test.invalid/v1", {}, idle_timeout=1, deadline=0.03)
                self.assertLess(time.monotonic() - start, 1.5)
                self.assertTrue(entered.is_set())
                connection.connect.assert_not_called()
                connection.close.assert_called_once()
            finally:
                release.set()
                for worker in workers:
                    worker.join(timeout=2)
                    self.assertFalse(worker.is_alive(), "mock DNS worker leaked")

    def test_multiple_address_attempts_share_one_deadline_budget(self):
        now, workers = [0.0], []
        addresses = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", port)) for port in (1, 2, 3)]
        transports = [mock.Mock(spec=socket.socket), mock.Mock(spec=socket.socket)]

        def resolve(*args, **kwargs):
            workers.append(threading.current_thread())
            return addresses

        def fail_connect(target):
            now[0] += 0.6
            raise OSError("mock address refused")

        for transport in transports:
            transport.connect.side_effect = fail_connect
        with mock.patch.object(CLIENT.socket, "getaddrinfo", side_effect=resolve), \
             mock.patch.object(CLIENT.socket, "socket", side_effect=transports) as sockets, \
             mock.patch.object(CLIENT.time, "monotonic", side_effect=lambda: now[0]):
            try:
                with self.assertRaises(TimeoutError):
                    CLIENT.stream_request("http://addresses-test.invalid/v1", {}, idle_timeout=10, deadline=1)
                self.assertEqual(sockets.call_count, 2, "third address received a fresh budget")
                self.assertAlmostEqual(transports[0].settimeout.call_args_list[0].args[0], 1)
                self.assertAlmostEqual(transports[1].settimeout.call_args_list[0].args[0], 0.4)
                for index, transport in enumerate(transports):
                    transport.connect.assert_called_once_with(addresses[index][4])
                    transport.close.assert_called_once()
            finally:
                for worker in workers:
                    worker.join(timeout=2)
                    self.assertFalse(worker.is_alive())

    def test_successful_second_address_preserves_remaining_budget(self):
        now, workers = [0.0], []
        addresses = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", port)) for port in (1, 2)]
        transports = [mock.Mock(spec=socket.socket), mock.Mock(spec=socket.socket)]
        connection = http.client.HTTPConnection("addresses-test.invalid")
        reply = mock.Mock(spec=http.client.HTTPResponse)
        reply.status = 200
        reply.getheader.return_value = "text/event-stream"
        reply.read1.side_effect = [b'data: {"choices": [{"index": 0, "delta": {"content": "ok"}, "finish_reason": "stop"}]}\n\ndata: [DONE]\n\n', b""]
        timer = mock.Mock()

        def resolve(*args, **kwargs):
            workers.append(threading.current_thread())
            return addresses

        def first_connect(target):
            now[0] += 0.4
            raise OSError("mock first address refused")

        def second_connect(target):
            now[0] += 0.35

        transports[0].connect.side_effect = first_connect
        transports[1].connect.side_effect = second_connect
        collect = CLIENT.collect_stream
        with mock.patch.object(CLIENT.socket, "getaddrinfo", side_effect=resolve), \
             mock.patch.object(CLIENT.socket, "socket", side_effect=transports), \
             mock.patch.object(CLIENT.time, "monotonic", side_effect=lambda: now[0]), \
             mock.patch.object(CLIENT.threading, "Timer", return_value=timer) as timers, \
             mock.patch.object(CLIENT.http.client, "HTTPConnection", return_value=connection), \
             mock.patch.object(CLIENT, "collect_stream", side_effect=lambda events, start: collect(events, start, clock=lambda: now[0])), \
             mock.patch.object(connection, "request"), mock.patch.object(connection, "getresponse", return_value=reply):
            try:
                result = CLIENT.stream_request("http://addresses-test.invalid/v1", {}, idle_timeout=10, deadline=1)
                self.assertEqual(result["content"], "ok")
                self.assertAlmostEqual(transports[1].settimeout.call_args_list[0].args[0], 0.6)
                self.assertAlmostEqual(transports[1].settimeout.call_args_list[1].args[0], 0.25)
                self.assertAlmostEqual(timers.call_args.args[0], 0.25)
                timer.start.assert_called_once()
                timer.cancel.assert_called_once()
                reply.close.assert_called_once()
                for transport in transports:
                    transport.close.assert_called_once()
                self.assertIsNone(connection.sock)
            finally:
                connection.close()
                for worker in workers:
                    worker.join(timeout=2)
                    self.assertFalse(worker.is_alive())

    @contextlib.contextmanager
    def mocked_response(self):
        workers = []
        connection = mock.Mock()
        reply = mock.Mock(spec=http.client.HTTPResponse)
        reply.status = 200
        reply.getheader.return_value = "text/event-stream"
        connection.getresponse.return_value = reply
        timer = mock.Mock()

        def resolve(*args, **kwargs):
            workers.append(threading.current_thread())
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 1))]

        with mock.patch.object(CLIENT.socket, "getaddrinfo", side_effect=resolve), \
             mock.patch.object(CLIENT.socket, "socket", side_effect=AssertionError("network forbidden")), \
             mock.patch.object(CLIENT.http.client, "HTTPConnection", return_value=connection), \
             mock.patch.object(CLIENT.threading, "Timer", return_value=timer):
            try:
                yield reply
            finally:
                for worker in workers:
                    worker.join(timeout=2)
                    self.assertFalse(worker.is_alive(), "mock resolver thread leaked")
                reply.close.assert_called_once()
                connection.close.assert_called_once()
                timer.cancel.assert_called_once()

    def test_http_response_explicit_close_after_keyboard_interrupt(self):
        with self.mocked_response() as reply:
            reply.read1.side_effect = KeyboardInterrupt
            with self.assertRaises(KeyboardInterrupt):
                CLIENT.stream_request("http://response-test.invalid/v1", {})

    def test_http_response_explicit_close_after_protocol_errors(self):
        for variant in ("http_status", "content_type", "invalid_event"):
            with self.subTest(variant=variant), self.mocked_response() as reply:
                if variant == "http_status":
                    reply.status = 503
                elif variant == "content_type":
                    reply.getheader.return_value = "application/json"
                else:
                    reply.read1.side_effect = [b"data: not-json\n\n", b""]
                with self.assertRaises(CLIENT.ProtocolError):
                    CLIENT.stream_request("http://response-test.invalid/v1", {})

    def test_http_response_explicit_close_after_success(self):
        with self.mocked_response() as reply:
            reply.read1.side_effect = [b'data: {"choices": [{"index": 0, "delta": {"content": "ok"}, "finish_reason": "stop"}]}\n\ndata: [DONE]\n\n', b""]
            result = CLIENT.stream_request("http://response-test.invalid/v1", {})
            self.assertEqual(result["content"], "ok")
            self.assertEqual(result["finish_reason"], "stop")


class LoopbackChecks(unittest.TestCase):
    @contextlib.contextmanager
    def server(self, mode):
        requests, handlers = [], []
        read_closed, handler_done = threading.Event(), threading.Event()

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_POST(self):
                handlers.append(threading.current_thread())
                self.connection.settimeout(3)
                try:
                    body = self.rfile.read(int(self.headers["Content-Length"]))
                    requests.append((self.path, dict(self.headers), json.loads(body)))
                    if mode == "http_error":
                        self.send_response(503)
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    if mode == "partial_event":
                        self.wfile.write(b'data: {"choices":')
                        self.wfile.flush()
                        return
                    item = event({"content": "\u5317\u4eac"})
                    self.wfile.write(("data: " + item[1] + "\r\n\r\n").encode("utf-8"))
                    self.wfile.flush()
                    if mode == "eof":
                        return
                    if mode == "stall":
                        try:
                            if not self.connection.recv(1):
                                read_closed.set()
                        except (ConnectionResetError, BrokenPipeError):
                            read_closed.set()
                        return
                    if mode == "heartbeat":
                        self.connection.settimeout(0.03)
                        while True:
                            try:
                                if not self.connection.recv(1):
                                    read_closed.set()
                                    return
                            except socket.timeout:
                                try:
                                    self.wfile.write(b": heartbeat\n\n")
                                    self.wfile.flush()
                                except (ConnectionResetError, BrokenPipeError):
                                    read_closed.set()
                                    return
                            except ConnectionResetError:
                                read_closed.set()
                                return
                    if mode == "success":
                        item = event(finish="stop")
                        frames = ("data: " + item[1] + "\r\n\r\n"
                                  'data: {"choices": [], "usage": {"completion_tokens": 2}}\r\n\r\n'
                                  "data: [DONE]\r\n\r\n")
                        self.wfile.write(frames.encode("utf-8"))
                        self.wfile.flush()
                finally:
                    self.close_connection = True
                    handler_done.set()

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = False
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01},
                                  name="thor-test-loopback")
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}/v1", requests, read_closed, handler_done
        finally:
            server.shutdown()
            thread.join(timeout=4)
            server.server_close()
            self.assertFalse(thread.is_alive(), "loopback server thread leaked")
            for handler in handlers:
                self.assertFalse(handler.is_alive(), "loopback handler thread leaked")

    @contextlib.contextmanager
    def transport_tracking(self):
        timers, connections = [], []
        timer_class = threading.Timer
        connection_class = http.client.HTTPConnection

        def timer(*args, **kwargs):
            item = timer_class(*args, **kwargs)
            timers.append(item)
            return item

        def connection(*args, **kwargs):
            item = connection_class(*args, **kwargs)
            connections.append(item)
            return item

        with mock.patch.object(CLIENT.threading, "Timer", side_effect=timer), \
             mock.patch.object(CLIENT.http.client, "HTTPConnection", side_effect=connection):
            try:
                yield
            finally:
                for item in timers:
                    item.join(timeout=2)
                    self.assertFalse(item.is_alive(), "deadline timer thread leaked")
                self.assertEqual(len(connections), 1)
                self.assertIsNone(connections[0].sock, "HTTP connection not closed")

    def test_real_loopback_sse_success(self):
        request = {"model": "test-model", "messages": [{"role": "user", "content": "\u4e2d\u6587"}], "stream": True}
        with self.server("success") as (url, requests, _, done), self.transport_tracking():
            result = CLIENT.stream_request(url, request, api_key="loopback-only", idle_timeout=2, deadline=3)
            self.assertTrue(done.wait(2))
            self.assertEqual(result["content"], "\u5317\u4eac")
            self.assertEqual(result["finish_reason"], "stop")
            self.assertEqual(result["metrics"]["completion_tokens_reported"], 2)
            self.assertEqual(result["metrics"]["payload_events"], 1)
            self.assertEqual(len(requests), 1)
            path, headers, body = requests[0]
            self.assertEqual(path, "/v1/chat/completions")
            self.assertEqual(body, request)
            self.assertEqual(headers["Authorization"], "Bearer loopback-only")
            self.assertEqual(headers["Accept"], "text/event-stream")

    def test_real_loopback_http_error_closes_connection(self):
        with self.server("http_error") as (url, _, _, done), self.transport_tracking():
            with self.assertRaisesRegex(CLIENT.ProtocolError, "http_status_503"):
                CLIENT.stream_request(url, {}, idle_timeout=2, deadline=3)
            self.assertTrue(done.wait(2))

    def test_real_loopback_midstream_eof_rejected(self):
        for mode, error in (("eof", "incomplete_stream"), ("partial_event", "truncated_sse_event")):
            with self.subTest(mode=mode), self.server(mode) as (url, _, _, done), self.transport_tracking():
                with self.assertRaisesRegex(CLIENT.ProtocolError, error):
                    CLIENT.stream_request(url, {}, idle_timeout=2, deadline=3)
                self.assertTrue(done.wait(2))

    def test_real_loopback_idle_timeout_closes_blocked_read(self):
        with self.server("stall") as (url, _, closed, done), self.transport_tracking():
            start = time.monotonic()
            with self.assertRaises((TimeoutError, socket.timeout)):
                CLIENT.stream_request(url, {}, idle_timeout=0.15, deadline=3)
            self.assertLess(time.monotonic() - start, 3)
            self.assertTrue(closed.wait(2), "server did not observe client read closure")
            self.assertTrue(done.wait(2))

    def test_real_loopback_deadline_closes_blocked_read(self):
        with self.server("stall") as (url, _, closed, done), self.transport_tracking():
            start = time.monotonic()
            with self.assertRaises(TimeoutError):
                CLIENT.stream_request(url, {}, idle_timeout=3, deadline=0.15)
            self.assertLess(time.monotonic() - start, 3)
            self.assertTrue(closed.wait(2), "server did not observe deadline read closure")
            self.assertTrue(done.wait(2))

    def test_real_loopback_deadline_despite_ongoing_heartbeats(self):
        with self.server("heartbeat") as (url, _, closed, done), self.transport_tracking():
            start = time.monotonic()
            with self.assertRaises(TimeoutError):
                CLIENT.stream_request(url, {}, idle_timeout=1, deadline=0.3)
            self.assertLess(time.monotonic() - start, 3)
            self.assertTrue(closed.wait(2), "server did not observe deadline read closure")
            self.assertTrue(done.wait(2))


if __name__ == "__main__":
    unittest.main()
