#!/usr/bin/env python3
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest

import yaml


SCANNER_PATH = pathlib.Path(__file__).with_name("check-secrets.py")
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("check_secrets", SCANNER_PATH)
SCANNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCANNER)
ENCRYPTED = "ENC[AES256_GCM,data:ZmFrZQ==,iv:ZmFrZQ==,tag:ZmFrZQ==,type:str]"
PUBLIC_KEY = "age1" + "q" * 58
PLAINTEXT = "fictitious-test-credential"


class SecretChecks(unittest.TestCase):
    def check(self, path, content):
        if not isinstance(content, str):
            content = yaml.safe_dump(content)
        return SCANNER.check(path, content.encode())

    def test_plaintext_disguised_as_sops(self):
        for metadata in ({}, {"sops": {"mac": ENCRYPTED}}):
            with self.subTest(metadata=bool(metadata)):
                self.assertTrue(self.check("secrets/test.yaml", {"password": PLAINTEXT, **metadata}))

    def test_unknown_sops_metadata(self):
        self.assertTrue(self.check("secrets/test.yaml", {"sops": {"mac": ENCRYPTED, "password": PLAINTEXT}}))

    def test_duplicate_secret_keys(self):
        for content in (
            f"kind: Secret\nstringData:\n  password: {PLAINTEXT}\nstringData:\n  password: {ENCRYPTED}\n",
            f"kind: Secret\nstringData:\n  password: {PLAINTEXT}\n  password: {ENCRYPTED}\n",
        ):
            with self.subTest(content_length=len(content)):
                self.assertTrue(self.check("test.yaml", content))

    def test_plaintext_kubernetes_secret(self):
        for field in ("data", "stringData"):
            with self.subTest(field=field):
                self.assertTrue(self.check("test.yaml", {"kind": "Secret", field: {"password": PLAINTEXT}}))

    def test_nested_kubernetes_secret(self):
        secret = {"kind": "Secret", "stringData": {"password": PLAINTEXT}}
        for document in (
            {"kind": "List", "items": [secret]},
            {"kind": "List", "items": [{"kind": "List", "items": [secret]}]},
        ):
            self.assertTrue(self.check("test.yaml", document))

    def test_encrypted_kubernetes_secret(self):
        document = {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": "test"},
            "type": "Opaque",
            "stringData": {"password": ENCRYPTED},
            "sops": {"mac": ENCRYPTED, "age": [{"recipient": PUBLIC_KEY}]},
        }
        self.assertFalse(self.check("test.sops.yaml", document))

    def test_renamed_client_configs(self):
        documents = (
            {"kind": "Config", "users": [{"name": "test", "user": {"token": PLAINTEXT}}]},
            {"context": "test", "contexts": {"test": {"key": PLAINTEXT}}},
        )
        for suffix in (".yaml", ".conf", ".txt", ""):
            for document in documents:
                with self.subTest(suffix=suffix, kind=document.get("kind", "Talos")):
                    self.assertTrue(self.check("renamed" + suffix, document))

    def test_example_placeholders(self):
        for value in ("replace-me", "${SECRET_PASSWORD}", "hk.tails.${SECRET_DOMAIN}"):
            with self.subTest(value=value):
                self.assertFalse(self.check("secrets/test.example.yaml", {"password": value}))

    def test_example_plaintext(self):
        for value in (PLAINTEXT, PLAINTEXT + "${SECRET_PASSWORD}"):
            self.assertTrue(self.check("secrets/test.example.yaml", {"password": value}))

    def test_sops_empty_values(self):
        document = {"empty": "", "null": None, "password": ENCRYPTED, "sops": {"mac": ENCRYPTED}}
        self.assertFalse(self.check("secrets/test.yaml", document))

    def test_public_recipient(self):
        self.assertFalse(self.check(".sops.yaml", {"creation_rules": [{"path_regex": "secrets/.*", "age": PUBLIC_KEY}]}))

    def test_private_key_headers(self):
        for header in (
            "-----BEGIN " + "OPENSSH PRIVATE KEY-----",
            "-----BEGIN PGP " + "PRIVATE KEY BLOCK-----",
            "AGE-SECRET-KEY-" + "A" * 32,
        ):
            self.assertTrue(self.check("renamed.txt", header))

    def test_scanner_and_test_source_do_not_trigger(self):
        for path in (SCANNER_PATH, pathlib.Path(__file__)):
            with self.subTest(path=path.name):
                self.assertFalse(SCANNER.check("utils/" + path.name, path.read_bytes()))


class GitContentChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = pathlib.Path(self.directory.name)
        self.git("init", "-q")
        self.path = self.repo / "test.yaml"

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True)

    def write(self, secret):
        document = {"kind": "Secret", "stringData": {"password": PLAINTEXT}} if secret else {"kind": "ConfigMap"}
        self.path.write_text(yaml.safe_dump(document))

    def scan(self, *args):
        result = subprocess.run([sys.executable, str(SCANNER_PATH.resolve()), *args], cwd=self.repo, capture_output=True, text=True)
        self.assertNotIn(PLAINTEXT, result.stdout + result.stderr)
        return result.returncode

    def test_staged_secret_working_clean(self):
        self.write(True)
        self.git("add", "test.yaml")
        self.write(False)
        self.assertEqual(self.scan("--staged"), 1)

    def test_staged_clean_working_secret(self):
        self.write(False)
        self.git("add", "test.yaml")
        self.write(True)
        self.assertEqual(self.scan("--staged"), 0)

    def test_default_scans_head(self):
        self.write(True)
        self.git("add", "test.yaml")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        self.write(False)
        self.git("add", "test.yaml")
        self.assertEqual(self.scan(), 1)


if __name__ == "__main__":
    unittest.main()
