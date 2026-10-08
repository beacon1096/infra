#!/usr/bin/env python3
"""Replay the fixed public source patch and exercise prepare with a fake Docker."""

import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "hosts/personal/fixed/thor/flash-next"
FILE = "vocab_parallel_embedding.py"
EAGLE_FILE = "eagle_worker_v2.py"
REVISION = "94602c9c2b7cbdb8efd5c52802dac6a1c180089e"
URL = f"https://raw.githubusercontent.com/sgl-project/sglang/{REVISION}/python/sglang/srt/layers/{FILE}"
EAGLE_URL = f"https://raw.githubusercontent.com/sgl-project/sglang/{REVISION}/python/sglang/srt/speculative/{EAGLE_FILE}"
ORIGINAL_HASH = "43ca7c6fabd7c66adf14c5c871cf6ec3070b23b53d7786a9d4cee7a4b68d0931"
EAGLE_ORIGINAL_HASH = "8fc9285c458d746874c96da7b16bef2733509dea3d1170cbad9e787bcde67754"
IMAGE = "lmsysorg/sglang@sha256:b0d8718a4424bb22e448e04407ab3ce5f7399a4c5fc702d6fbe36c3772ec8862"
CID = "c" * 64
SOURCE = b""
EAGLE_SOURCE = b""
FAKE_DOCKER = '''
import json
import os
from pathlib import Path
import shutil
import sys

args = sys.argv[1:]
with open(os.environ["DOCKER_LOG"], "a") as stream:
    stream.write(json.dumps(args) + "\\n")
if args[0] == os.environ.get("FAIL_COMMAND"):
    sys.exit(4)
if args[:2] == ["image", "inspect"]:
    digest = [] if os.environ.get("MISSING_DIGEST") else [os.environ["IMAGE"]]
    print(json.dumps([{"Id": "sha256:" + "d" * 64, "RepoDigests": digest}]))
elif args[0] == "create":
    print(os.environ["CID"])
elif args[0] == "cp":
    source = os.environ["SOURCE_FILE"]
    if args[1].endswith(os.environ["EAGLE_FILE"]):
        source = os.environ["EAGLE_SOURCE_FILE"]
    shutil.copyfile(source, args[2])
elif args != ["rm", os.environ["CID"]]:
    sys.exit("Unexpected Docker command")
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def replay(source, directory, filename=FILE):
    original = directory / filename
    original.write_bytes(source)
    result = subprocess.run(
        ["patch", "--batch", "--forward", "--fuzz=0", "--no-backup-if-mismatch",
         "-p0", "-d", str(directory), "-i", str(ASSETS / f"{filename}.patch")],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return original.read_bytes(), result.stdout


class HeadAssetsChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="flash-next-head-", dir="/tmp/opencode")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.source = self.directory / "source.py"
        self.source.write_bytes(SOURCE)
        self.eagle_source = self.directory / "eagle_source.py"
        self.eagle_source.write_bytes(EAGLE_SOURCE)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        docker = self.bin / "docker"
        docker.write_text(f"#!{sys.executable}\n" + FAKE_DOCKER)
        docker.chmod(0o755)
        self.log = self.directory / "docker.jsonl"
        self.env = dict(
            os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            DOCKER_LOG=str(self.log), IMAGE=IMAGE, CID=CID, SOURCE_FILE=str(self.source),
            EAGLE_FILE=EAGLE_FILE, EAGLE_SOURCE_FILE=str(self.eagle_source),
        )
        self.destination = self.directory / "overlay with spaces"
        manifest = json.loads((ASSETS / "manifest.json").read_text())
        self.patches = self.directory / "patches"
        self.patches.mkdir()
        (self.patches / "manifest.json").write_text(
            json.dumps([entry for entry in manifest if entry["file"] == FILE]))
        for name in (FILE, EAGLE_FILE):
            shutil.copyfile(ASSETS / f"{name}.patch", self.patches / f"{name}.patch")

    def prepare(self, image=IMAGE, patches=None, **overrides):
        return subprocess.run(
            ["bash", str(ASSETS / "prepare.sh"), image, str(patches or self.patches), str(self.destination)],
            env=dict(self.env, **overrides), capture_output=True, text=True, timeout=10,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_fixed_hash_replay_and_ordinary_loader_AST_unchanged(self):
        manifest = json.loads((self.patches / "manifest.json").read_text())[0]
        self.assertEqual(sha(SOURCE), ORIGINAL_HASH)
        self.assertEqual(manifest["original_sha256"], ORIGINAL_HASH)
        self.assertEqual(manifest["patch_sha256"], sha((ASSETS / f"{FILE}.patch").read_bytes()))
        patched, output = replay(SOURCE, self.directory)
        self.assertEqual(sha(patched), manifest["patched_sha256"])
        self.assertNotIn("fuzz", output.lower())
        self.assertNotIn("offset", output.lower())
        compile(patched, FILE, "exec")

        def loader(data):
            module = ast.parse(data)
            cls = next(node for node in module.body if isinstance(node, ast.ClassDef)
                       and node.name == "VocabParallelEmbedding")
            return next(node for node in cls.body if isinstance(node, ast.FunctionDef)
                        and node.name == "weight_loader")

        original_method = loader(SOURCE)
        patched_method = loader(patched)
        branches = [node for node in patched_method.body if isinstance(node, ast.If)
                    and ast.unparse(node.test) == "isinstance(param, BlockQuantScaleParameter)"]
        self.assertEqual(len(branches), 1)
        patched_method.body.remove(branches[0])
        self.assertEqual(ast.dump(original_method), ast.dump(patched_method))

    def test_eagle_patch_replay_hash_and_token_map_dequant(self):
        if not EAGLE_SOURCE:
            self.skipTest("eagle source not provided")
        manifest = next(entry for entry in json.loads((ASSETS / "manifest.json").read_text())
                        if entry["file"] == EAGLE_FILE)
        self.assertEqual(sha(EAGLE_SOURCE), EAGLE_ORIGINAL_HASH)
        self.assertEqual(manifest["original_sha256"], EAGLE_ORIGINAL_HASH)
        self.assertEqual(manifest["patch_sha256"], sha((ASSETS / f"{EAGLE_FILE}.patch").read_bytes()))
        patched, output = replay(EAGLE_SOURCE, self.directory, EAGLE_FILE)
        self.assertEqual(sha(patched), manifest["patched_sha256"])
        self.assertNotIn("fuzz", output.lower())
        self.assertNotIn("offset", output.lower())
        compile(patched, EAGLE_FILE, "exec")
        text = ast.unparse(ast.parse(patched))
        self.assertIn("dequantize_fp8", text)
        self.assertIn("float8_e4m3fn", text)
        self.assertIn("weight_scale_inv", text)

    def test_script_syntax_without_torch(self):
        subprocess.run(["bash", "-n", str(ASSETS / "prepare.sh")], check=True)
        compile((ASSETS / "head-probe.py").read_bytes(), "head-probe.py", "exec")

    def test_prepare_uses_RepoDigest_not_image_Id_and_only_own_container(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertEqual(calls[0], ["image", "inspect", IMAGE])
        self.assertEqual(calls[1], [
            "create", "--pull=never", "--network=none", "--read-only",
            "--entrypoint", "/bin/true", IMAGE,
        ])
        self.assertEqual(calls[2][0], "cp")
        self.assertEqual(calls[2][1], f"{CID}:/sgl-workspace/sglang/python/sglang/srt/layers/{FILE}")
        self.assertEqual(calls[3], ["rm", CID])
        installed = self.destination / FILE
        manifest = json.loads((self.patches / "manifest.json").read_text())[0]
        self.assertEqual(sha(installed.read_bytes()), manifest["patched_sha256"])
        self.assertEqual(installed.stat().st_mode & 0o777, 0o644)
        self.assertEqual([entry.name for entry in self.destination.iterdir()], [FILE])

    def test_missing_RepoDigest_does_not_create_container(self):
        result = self.prepare(MISSING_DIGEST="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [["image", "inspect", IMAGE]])

    def test_unpinned_image_does_not_touch_Docker(self):
        self.assertNotEqual(self.prepare(image="lmsysorg/sglang:v0.5.20").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_source_mismatch_removes_only_temp_container_and_installs_nothing(self):
        self.source.write_bytes(SOURCE + b"\n")
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA256 mismatch", result.stderr)
        self.assertEqual(self.calls()[-1], ["rm", CID])
        self.assertFalse(self.destination.exists())

    def test_copy_failure_cleans_temp_container(self):
        self.assertNotEqual(self.prepare(FAIL_COMMAND="cp").returncode, 0)
        self.assertEqual(self.calls()[-1], ["rm", CID])
        self.assertFalse(self.destination.exists())

    def test_create_failure_has_no_container_to_remove(self):
        self.assertNotEqual(self.prepare(FAIL_COMMAND="create").returncode, 0)
        self.assertEqual([call[0] for call in self.calls()], ["image", "create"])

    def test_corrupt_patch_rejected_before_Docker(self):
        patches = self.directory / "corrupt-patches"
        patches.mkdir()
        shutil.copyfile(self.patches / "manifest.json", patches / "manifest.json")
        (patches / f"{FILE}.patch").write_text("invalid patch\n")
        self.assertNotEqual(self.prepare(patches=patches).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_patched_hash_mismatch_cleans_container_and_installs_nothing(self):
        patches = self.directory / "mismatch-patches"
        patches.mkdir()
        manifest = json.loads((self.patches / "manifest.json").read_text())
        manifest[0]["patched_sha256"] = "0" * 64
        (patches / "manifest.json").write_text(json.dumps(manifest))
        shutil.copyfile(self.patches / f"{FILE}.patch", patches / f"{FILE}.patch")
        result = self.prepare(patches=patches)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA256 mismatch", result.stderr)
        self.assertEqual(self.calls()[-1], ["rm", CID])
        self.assertFalse(self.destination.exists())

    def test_model_destination_and_descendant_rejected(self):
        self.destination.mkdir()
        (self.destination / "config.json").write_text("{}")
        self.assertNotEqual(self.prepare().returncode, 0)
        self.destination = self.destination / "overlay"
        self.assertNotEqual(self.prepare().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_mixed_destination_rejected(self):
        self.destination.mkdir()
        (self.destination / "unrelated.py").write_text("untouched\n")
        self.assertNotEqual(self.prepare().returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertEqual((self.destination / "unrelated.py").read_text(), "untouched\n")

    def test_multi_entry_failure_installs_nothing(self):
        patches = self.directory / "multi-patches"
        patches.mkdir()
        manifest = json.loads((ASSETS / "manifest.json").read_text())
        for entry in manifest:
            shutil.copyfile(ASSETS / f"{entry['file']}.patch", patches / f"{entry['file']}.patch")
        next(entry for entry in manifest if entry["file"] == EAGLE_FILE)["patched_sha256"] = "0" * 64
        (patches / "manifest.json").write_text(json.dumps(manifest))
        result = self.prepare(patches=patches)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA256 mismatch", result.stderr)
        self.assertEqual(self.calls()[-1], ["rm", CID])
        self.assertFalse(self.destination.exists())

    def test_empty_manifest_rejected_before_Docker(self):
        patches = self.directory / "empty-patches"
        patches.mkdir()
        (patches / "manifest.json").write_text("[]")
        result = self.prepare(patches=patches)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid patch manifest", result.stderr)
        self.assertEqual(self.calls(), [])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sources = parser.add_mutually_exclusive_group(required=True)
    sources.add_argument("--source", type=Path, help="Original fixed-commit source file")
    sources.add_argument("--fetch-source", action="store_true", help="Fetch only the fixed public .py source")
    parser.add_argument("--print-hashes", action="store_true")
    args, tests = parser.parse_known_args()
    global SOURCE, EAGLE_SOURCE
    if args.fetch_source:
        with urllib.request.urlopen(URL, timeout=60) as response:
            SOURCE = response.read()
        with urllib.request.urlopen(EAGLE_URL, timeout=60) as response:
            EAGLE_SOURCE = response.read()
    else:
        SOURCE = args.source.read_bytes()
    if sha(SOURCE) != ORIGINAL_HASH:
        parser.error("Original source SHA256 does not match the fixed engine commit")
    if EAGLE_SOURCE and sha(EAGLE_SOURCE) != EAGLE_ORIGINAL_HASH:
        parser.error("Eagle source SHA256 does not match the fixed engine commit")
    if args.print_hashes:
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            patched, output = replay(SOURCE, Path(directory))
            print(output, end="", file=sys.stderr)
            print(json.dumps({
                "original_sha256": sha(SOURCE), "patched_sha256": sha(patched),
                "patch_sha256": sha((ASSETS / f"{FILE}.patch").read_bytes()),
            }, indent=2))
        return
    unittest.main(argv=[sys.argv[0], *tests])


if __name__ == "__main__":
    main()
