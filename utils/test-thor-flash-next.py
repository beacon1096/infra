#!/usr/bin/env python3
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FLASH_NEXT = ROOT / "hosts/personal/fixed/thor/flash-next"
OWN_CID = "c" * 64
INVOCATION = "a" * 32
FAKE_COMMAND = '''
import json
import os
from pathlib import Path
import sys

if Path(sys.argv[0]).name == "awk":
    sys.exit(int(os.environ.get("FAKE_AWK_EXIT", "0")))
args = sys.argv[1:]
if Path(sys.argv[0]).name == "prepare":
    with open(os.environ["FAKE_PREPARE_LOG"], "a", encoding="utf-8") as log:
        log.write(json.dumps(args) + "\\n")
    image, patch_dir, destination = args
    destination = Path(destination)
    destination.mkdir(parents=True)
    (destination / "vocab_parallel_embedding.py").write_text("# Fake overlay\\n")
    sys.exit(0)
with open(os.environ["FAKE_DOCKER_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(args) + "\\n")
if args[:2] == ["image", "inspect"]:
    print(json.dumps({"Architecture": "arm64", "Os": "linux"}))
elif args[:2] == ["container", "inspect"]:
    exists = (args[2] == "thor-flash-next" and os.environ.get("FAKE_EXISTING") == "1"
              or args[2] == os.environ["FAKE_OWN_CID"] and os.environ.get("FAKE_OWNED") == "1")
    sys.exit(0 if exists else 1)
elif args[0] == "run":
    cidfile = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--cidfile="))
    Path(cidfile).write_bytes(os.environ["FAKE_OWN_CID"].encode("ascii"))
elif args[0] not in ("stop", "rm"):
    sys.exit("Unexpected fake Docker command")
'''


class FlashNextChecks(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(shutil.which("bash"), "bash is required")
        self.assertIsNotNone(shutil.which("jq"), "real jq is required")
        self.temp = tempfile.TemporaryDirectory(prefix="thor-flash-next-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.model = self.directory / "models"
        self.runtime = self.directory / "runtime"
        self.layer = self.directory / "fa4"
        self.patch_dir = self.directory / "flash-next"
        self.bin = self.directory / "bin"
        for path in (self.model / "target", self.model / "draft", self.model / "optimization",
                     self.runtime, self.layer / "flash_attn", self.layer / "tvm_ffi",
                     self.patch_dir, self.bin):
            path.mkdir(parents=True)
        self.baseline = json.loads((FLASH_NEXT / "baseline.json").read_text())
        self.cache = (self.directory / "state" / Path(self.baseline["model_dir"]).name
                      / "runtime-cache")
        fixture = dict(self.baseline, model_dir=str(self.model))
        self.baseline_file = self.directory / "baseline.json"
        self.baseline_file.write_text(json.dumps(fixture))
        self.prepared = {
            "phase": "verified", "verified_files": 235, "total_files": 235,
            "total_bytes": 133414193791, "copied_bytes": 133414193791,
            "pins": {
                "target": {"revision": self.baseline["target_revision"]},
                "configuration_draft_optimization": {
                    "revision": self.baseline["configuration_revision"]},
            },
        }
        self.prepared_file = self.model / "prepared.json"
        self.prepared_file.write_text(json.dumps(self.prepared))
        (self.model / "target/config.json").write_text(json.dumps({
            "quantization_config": {"quant_method": "modelopt_mixed"}}))
        for name in ("hf_quant_config.json", "model.safetensors.index.json"):
            (self.model / "target" / name).write_text("{}")
        for name in ("docker", "awk", "prepare"):
            command = self.bin / name
            command.write_text(f"#!{sys.executable}\n" + FAKE_COMMAND)
            command.chmod(0o755)
        self.log = self.directory / "docker.jsonl"
        self.log.touch()
        self.prepare_log = self.directory / "prepare.jsonl"
        self.prepare_log.touch()
        self.cid_file = self.runtime / f"container-{INVOCATION}.cid"
        self.other_cid_file = self.runtime / f"container-{'b' * 32}.cid"
        self.other_cid_file.write_bytes(b"d" * 64)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        BASELINE_FILE=str(self.baseline_file), IMAGE=self.baseline["image"],
                        MODEL_DIR=str(self.model), RUNTIME_DIR=str(self.runtime),
                        CACHE_DIR=str(self.cache), FA4_LAYER=str(self.layer),
                        PREPARE_PROGRAM=str(self.bin / "prepare"), PATCH_DIR=str(self.patch_dir),
                        INVOCATION_ID=INVOCATION, FAKE_DOCKER_LOG=str(self.log),
                        FAKE_PREPARE_LOG=str(self.prepare_log),
                        FAKE_OWN_CID=OWN_CID, FAKE_OWNED="1", FAKE_EXISTING="0", FAKE_AWK_EXIT="0")
        self.assertEqual(shutil.which("jq", path=self.env["PATH"]), shutil.which("jq"))

    def run_script(self, action="run", **environment):
        env = dict(self.env, **environment)
        env = {key: value for key, value in env.items() if value is not None}
        return subprocess.run([shutil.which("bash"), str(FLASH_NEXT / "run.sh"), action],
                              env=env, capture_output=True, text=True, timeout=10)

    def calls(self, log=None):
        return [json.loads(line) for line in (log or self.log).read_text().splitlines()]

    def assert_no_load(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(call[0] in ("run", "stop", "rm") for call in self.calls()))
        self.assertFalse(self.cid_file.exists())
        self.assertFalse(self.cache.exists())
        self.assertEqual(self.calls(self.prepare_log), [])
        self.assertEqual(self.other_cid_file.read_bytes(), b"d" * 64)

    def test_existing_named_container_is_not_cleaned(self):
        result = self.run_script(FAKE_EXISTING="1")
        self.assert_no_load(result)
        self.assertIn("already exists", result.stderr)
        self.assertIn(["container", "inspect", "thor-flash-next"], self.calls())
        before = self.calls()
        cleanup = self.run_script("cleanup", FAKE_EXISTING="1")
        self.assertEqual(cleanup.returncode, 0, cleanup.stderr)
        self.assertEqual(self.calls(), before)
        self.assertEqual(self.calls(self.prepare_log), [])
        self.assertEqual(self.other_cid_file.read_bytes(), b"d" * 64)

    def test_early_prepared_failure_cleanup_does_not_touch_other_container(self):
        self.prepared_file.write_text(json.dumps(dict(self.prepared, phase="copied")))
        self.assert_no_load(self.run_script(FAKE_EXISTING="1"))
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.calls()[0][:2], ["image", "inspect"])
        before = self.calls()
        cleanup = self.run_script("cleanup", FAKE_EXISTING="1")
        self.assertEqual(cleanup.returncode, 0, cleanup.stderr)
        self.assertEqual(self.calls(), before)
        self.assertEqual(self.calls(self.prepare_log), [])
        self.assertEqual(self.other_cid_file.read_bytes(), b"d" * 64)

    def test_cleanup_uses_complete_newlineless_owned_cid_and_removes_marker(self):
        self.cid_file.write_bytes(OWN_CID.encode("ascii"))
        result = self.run_script("cleanup", FAKE_EXISTING="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [
            ["container", "inspect", OWN_CID],
            ["stop", "--time", "15", OWN_CID],
            ["rm", "--force", OWN_CID],
        ])
        self.assertFalse(self.cid_file.exists())
        before = self.calls()
        self.assertEqual(self.run_script("cleanup").returncode, 0)
        self.assertEqual(self.calls(), before)

    def test_cleanup_rejects_invalid_cid(self):
        for cid in ("", "c" * 63, "C" * 64, "thor-flash-next"):
            with self.subTest(cid=cid):
                self.cid_file.write_text(cid)
                result = self.run_script("cleanup", FAKE_EXISTING="1")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])
                self.assertTrue(self.cid_file.exists())

    def test_run_requires_valid_managed_invocation(self):
        for invocation in (None, "", "a" * 31, "A" * 32):
            with self.subTest(invocation=invocation):
                self.assert_no_load(self.run_script(INVOCATION_ID=invocation))
                self.assertEqual(self.calls(), [])

    def test_normal_run_is_target_only_offline_and_revision_cached(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.calls()[-1]
        self.assertEqual(call[0], "run")
        for flag in ("--rm", "--pull=never", "--memory=108g", "--memory-swap=108g",
                     "--shm-size=8g", "--device=nvidia.com/gpu=all", "--publish=127.0.0.1:8890:8890",
                     f"--cidfile={self.cid_file}"):
            self.assertIn(flag, call)
        self.assertFalse({"-d", "--detach"} & set(call))
        mounts = [call[index + 1] for index, arg in enumerate(call) if arg == "--mount"]
        self.assertCountEqual(mounts, [
            f"type=bind,src={self.model}/target,dst=/models/target,readonly",
            f"type=bind,src={self.cache}/ple,dst=/ple",
            f"type=bind,src={self.cache}/kernel-cache,dst=/root/.cache",
            f"type=bind,src={self.layer},dst=/opt/owned-fa4,readonly",
            f"type=bind,src={self.cache}/runtime-patches/vocab_parallel_embedding.py,"
            "dst=/sgl-workspace/sglang/python/sglang/srt/layers/vocab_parallel_embedding.py,readonly",
        ])
        environment = [call[index + 1] for index, arg in enumerate(call) if arg == "--env"]
        self.assertCountEqual(environment, [
            "HF_HOME=/root/.cache/huggingface", "HF_HUB_OFFLINE=1", "TRANSFORMERS_OFFLINE=1",
            "PYTHONPATH=/opt/owned-fa4", "SGLANG_INKLING_FA4_USE_PIP=1",
            "SGLANG_QWEN4_PLE_FILE_RSS_BUDGET_GB=4",
        ])
        self.assertEqual(call[call.index(self.baseline["image"]) + 1:],
                         ["python3", "-m", "sglang.launch_server"] + self.baseline["arguments"])
        self.assertFalse(any("speculative" in arg or "mtp" in arg.lower() for arg in call))
        self.assertTrue((self.cache / "ple").is_dir())
        self.assertTrue((self.cache / "kernel-cache").is_dir())
        self.assertEqual(self.calls(self.prepare_log), [
            [self.baseline["image"], str(self.patch_dir), str(self.cache / "runtime-patches")],
        ])
        self.assertEqual([path.name for path in (self.cache / "runtime-patches").iterdir()],
                         ["vocab_parallel_embedding.py"])
        self.assertEqual(self.cid_file.read_bytes(), OWN_CID.encode("ascii"))

    def test_unpinned_image_does_not_load(self):
        self.assert_no_load(self.run_script(IMAGE="lmsysorg/sglang:v0.5.20"))
        self.assertEqual(self.calls(), [])

    def test_wrong_prepared_counts_bytes_or_pins_do_not_load(self):
        for field in ("verified_files", "total_files", "total_bytes", "copied_bytes",
                      "target", "configuration_draft_optimization"):
            with self.subTest(field=field):
                prepared = copy.deepcopy(self.prepared)
                if field in prepared["pins"]:
                    prepared["pins"][field]["revision"] = "0" * 40
                else:
                    prepared[field] -= 1
                self.prepared_file.write_text(json.dumps(prepared))
                self.log.write_text("")
                self.assert_no_load(self.run_script())

    def test_memory_preflight_refuses_load(self):
        self.assert_no_load(self.run_script(FAKE_AWK_EXIT="1"))

    def test_baseline_c1_pins_and_all_parameters(self):
        for key, expected in {
            "name": "mixed-target-only baseline",
            "image": "lmsysorg/sglang@sha256:b0d8718a4424bb22e448e04407ab3ce5f7399a4c5fc702d6fbe36c3772ec8862",
            "engine_version": "0.5.20", "cuda_version": "13.0.3", "torch_version": "2.13",
            "flashinfer_version": "0.6.18",
            "engine_revision": "94602c9c2b7cbdb8efd5c52802dac6a1c180089e",
            "target_revision": "7b719225242aacd3dbd3f9407468c2ee9a9d2594",
            "configuration_revision": "b8c4002b44544436bfc16b1ff7fe6ebb3ced07a6",
            "target_repository": "RadixArk/Qwen3.8-Flash-Next-NVFP4",
            "configuration_repository": "manateelazycat/Qwen3.8-Flash-Next-SGLang-Thor",
            "model_dir": "/var/lib/thor-inference/flash-next/radixark-7b719225-sglang-b8c4002b",
            "target_quantization": "modelopt_mixed",
            "prepared_observation": {"phase": "verified", "files": 235, "bytes": 133414193791},
        }.items():
            with self.subTest(key=key):
                self.assertEqual(self.baseline[key], expected)
        arguments = self.baseline["arguments"].copy()
        self.assertEqual(arguments.count("--ple-offload-embedding"), 1)
        arguments.remove("--ple-offload-embedding")
        parameters = dict(zip(arguments[::2], arguments[1::2]))
        self.assertEqual(len(parameters) * 2, len(arguments))
        self.assertEqual(parameters, {
            "--model-path": "/models/target", "--served-model-name": "qwen3.8-flash-next-thor",
            "--quantization": "modelopt_mixed", "--dtype": "bfloat16",
            "--context-length": "262144", "--max-total-tokens": "8192",
            "--max-running-requests": "1", "--max-mamba-cache-size": "8",
            "--mamba-ssm-dtype": "float32", "--kv-cache-dtype": "bfloat16",
            "--page-size": "64", "--chunked-prefill-size": "512",
            "--prefill-decode-interval": "1", "--mem-fraction-static": "0.80",
            "--moe-runner-backend": "flashinfer_cutlass", "--fp4-gemm-backend": "flashinfer_cutlass",
            "--fp8-gemm-backend": "triton", "--attention-backend": "fa4",
            "--linear-attn-backend": "triton", "--linear-attn-prefill-backend": "triton",
            "--linear-attn-decode-backend": "triton", "--linear-attn-verify-backend": "triton",
            "--cuda-graph-backend-decode": "disabled", "--cuda-graph-backend-prefill": "disabled",
            "--ple-offload-backend": "file", "--ple-offload-dir": "/ple",
            "--reasoning-parser": "qwen3", "--tool-call-parser": "qwen3_coder",
            "--host": "0.0.0.0", "--port": "8890",
        })

    def test_guard_stops_when_unneeded(self):
        module = (FLASH_NEXT.parent / "flash-next.nix").read_text()
        marker = "systemd.services.thor-flash-next-memwatch = {"
        self.assertEqual(module.count(marker), 1)
        guard = module.split(marker, 1)[1]
        self.assertIn('partOf = [ "thor-flash-next.service" ];', guard)
        self.assertIn("unitConfig.StopWhenUnneeded = true;", guard)


@unittest.skipUnless(shutil.which("nix"), "nix is required for focused module evaluation")
class DecodeGraphModuleChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        expression = '''
          let
            root = builtins.toPath %s;
            nixpkgs = (builtins.getFlake ("path:" + toString root)).inputs.nixpkgs-thor;
            system = nixpkgs.lib.nixosSystem {
              system = builtins.currentSystem;
              modules = [ (root + "/hosts/personal/fixed/thor/flash-next.nix") ];
            };
            extract = evaluated:
              let
                service = evaluated.config.systemd.services.thor-flash-next;
                guard = evaluated.config.systemd.services.thor-flash-next-memwatch;
              in {
                enabled = evaluated.config.services.thorFlashNext.decodeGraph;
                optionDefault = evaluated.options.services.thorFlashNext.decodeGraph.default;
                optionType = evaluated.options.services.thorFlashNext.decodeGraph.type.name;
                baselineText = builtins.readFile service.environment.BASELINE_FILE;
                service = {
                  inherit (service) environment serviceConfig requires bindsTo after conflicts wantedBy;
                };
                guard = {
                  inherit (guard) partOf unitConfig serviceConfig wantedBy;
                };
              };
          in {
            default = extract system;
            explicitFalse = extract (system.extendModules {
              modules = [ { services.thorFlashNext.decodeGraph = false; } ];
            });
            graphFull = extract (system.extendModules {
              modules = [ { services.thorFlashNext.decodeGraph = true; } ];
            });
          }
        ''' % json.dumps(str(ROOT))
        result = subprocess.run(
            ["nix", "eval", "--impure", "--json", "--option", "builders", "",
             "--option", "max-jobs", "1",
             "--option", "allow-import-from-derivation", "true", "--expr", expression],
            capture_output=True, text=True, timeout=180,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        cls.evaluated = json.loads(result.stdout)

    def test_default_and_explicit_false_preserve_original_baseline_and_args(self):
        default = self.evaluated["default"]
        self.assertFalse(default["enabled"])
        self.assertFalse(default["optionDefault"])
        self.assertEqual(default["optionType"], "bool")
        self.assertEqual(default, self.evaluated["explicitFalse"])
        original = (FLASH_NEXT / "baseline.json").read_text()
        self.assertEqual(default["baselineText"], original)
        path = Path(default["service"]["environment"]["BASELINE_FILE"])
        self.assertTrue(path.name.endswith("-baseline.json"))
        self.assertEqual(path.read_text(), original)

    def test_graph_full_reads_generated_json_and_only_changes_two_settings(self):
        default, graph = self.evaluated["default"], self.evaluated["graphFull"]
        self.assertTrue(graph["enabled"])
        original = json.loads(default["baselineText"])
        generated = json.loads(graph["baselineText"])
        path = Path(graph["service"]["environment"]["BASELINE_FILE"])
        self.assertEqual(path.parent, Path("/nix/store"))
        self.assertTrue(path.name.endswith("-thor-flash-next-C1-decodeGraph.json"))
        self.assertEqual(json.loads(path.read_text()), generated)
        self.assertEqual(path.stat().st_mode & 0o222, 0)
        self.assertIn("C1 decodeGraph", generated["name"])
        self.assertEqual({key: value for key, value in original.items() if key not in {"name", "arguments"}},
                         {key: value for key, value in generated.items() if key not in {"name", "arguments"}})
        expected = original["arguments"].copy()
        self.assertEqual(expected.count("--cuda-graph-backend-decode"), 1)
        index = expected.index("--cuda-graph-backend-decode")
        self.assertEqual(expected[index + 1], "disabled")
        expected[index + 1] = "full"
        expected += ["--cuda-graph-max-bs-decode", "1"]
        self.assertEqual(generated["arguments"], expected)
        arguments = generated["arguments"].copy()
        self.assertEqual(arguments.count("--ple-offload-embedding"), 1)
        arguments.remove("--ple-offload-embedding")
        self.assertEqual(len(set(arguments[::2])), len(arguments[::2]))
        settings = dict(zip(arguments[::2], arguments[1::2]))
        self.assertEqual(settings["--cuda-graph-backend-prefill"], "disabled")
        self.assertFalse(any("speculative" in arg or "mtp" in arg.lower() for arg in arguments))

    def test_graph_full_preserves_on_demand_service_guard_and_limits(self):
        default = copy.deepcopy(self.evaluated["default"])
        graph = copy.deepcopy(self.evaluated["graphFull"])
        default["service"]["environment"].pop("BASELINE_FILE")
        graph["service"]["environment"].pop("BASELINE_FILE")
        self.assertEqual(default["service"], graph["service"])
        self.assertEqual(default["guard"], graph["guard"])
        service, guard = graph["service"], graph["guard"]
        self.assertEqual(service["wantedBy"], [])
        self.assertEqual(guard["wantedBy"], [])
        self.assertEqual(service["serviceConfig"]["RuntimeMaxSec"], 3600)
        self.assertEqual(service["serviceConfig"]["Restart"], "no")
        self.assertEqual(service["requires"], ["docker.service", "thor-flash-next-memwatch.service"])
        self.assertEqual(service["bindsTo"], ["thor-flash-next-memwatch.service"])
        self.assertEqual(service["conflicts"], [
            "thor-inference.service", "thor-inference-experiment.service",
            "thor-inference-memwatch.service", "thor-inference-experiment-memwatch.service",
            "thor-inference-healthcheck.service", "thor-inference-healthcheck.timer",
        ])
        self.assertEqual(service["after"], ["docker.service", "thor-flash-next-memwatch.service"]
                         + service["conflicts"])
        self.assertEqual(guard["partOf"], ["thor-flash-next.service"])
        self.assertTrue(guard["unitConfig"]["StopWhenUnneeded"])
        script = (FLASH_NEXT / "run.sh").read_text()
        self.assertIn("--memory=108g --memory-swap=108g", script)


if __name__ == "__main__":
    unittest.main()
