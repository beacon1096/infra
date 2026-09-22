#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


CHECKER_PATH = pathlib.Path(__file__).with_name("check-docs-i18n.py")
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("check_docs_i18n", CHECKER_PATH)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class DocsI18nChecks(unittest.TestCase):
    def setUp(self):
        self.previous = os.getcwd()
        self.directory = tempfile.TemporaryDirectory()
        os.chdir(self.directory.name)
        for args in (
            ["init", "-q"],
            ["config", "user.email", "test@example.invalid"],
            ["config", "user.name", "test"],
            ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", "/dev/null"],
        ):
            subprocess.run(["git", *args], check=True)
        self.write({"README.md": "中文", "README_en.md": "English", "docs/tpm.md": "中文", "my_notes.md": "x"})
        self.base = self.commit()

    def tearDown(self):
        os.chdir(self.previous)
        self.directory.cleanup()

    def write(self, files):
        for path, content in files.items():
            pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
            pathlib.Path(path).write_text(content)

    def commit(self):
        subprocess.run(["git", "add", "-A"], check=True)
        subprocess.run(["git", "commit", "-q", "--allow-empty", "-m", "change"], check=True)
        return subprocess.run(["git", "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()

    def check(self, skip=frozenset()):
        return CHECKER.check(self.base, self.commit(), skip)

    def test_family_keys(self):
        for path, key in (
            ("README.md", "README"),
            ("README_en.md", "README"),
            ("docs/thor_en.md", "docs/thor"),
            ("my_notes.md", "my_notes"),
            ("README_fr.md", "README_fr"),
            ("script.py", None),
        ):
            with self.subTest(path=path):
                self.assertEqual(CHECKER.family(path), key)

    def test_source_only_change_fails(self):
        self.write({"README.md": "中文更新"})
        self.assertEqual(self.check(), {"README": ["README_en.md"]})

    def test_translation_only_change_fails(self):
        self.write({"README_en.md": "English update"})
        self.assertEqual(self.check(), {"README": ["README.md"]})

    def test_paired_change_passes(self):
        self.write({"README.md": "中文更新", "README_en.md": "English update"})
        self.assertEqual(self.check(), {})

    def test_single_member_family_passes(self):
        self.write({"docs/tpm.md": "中文更新", "my_notes.md": "y"})
        self.assertEqual(self.check(), {})

    def test_adding_translation_requires_source_change(self):
        self.write({"docs/tpm_en.md": "English"})
        self.assertEqual(self.check(), {"docs/tpm": ["docs/tpm.md"]})

    def test_opting_in_with_both_files_passes(self):
        self.write({"docs/tpm.md": "中文更新", "docs/tpm_en.md": "English"})
        self.assertEqual(self.check(), {})

    def test_deleting_translation_requires_source_change(self):
        pathlib.Path("README_en.md").unlink()
        self.assertEqual(self.check(), {"README": ["README.md"]})

    def test_renamed_family_moves_together(self):
        subprocess.run(["git", "mv", "README.md", "INTRO.md"], check=True)
        subprocess.run(["git", "mv", "README_en.md", "INTRO_en.md"], check=True)
        self.assertEqual(self.check(), {})

    def test_skip_marker(self):
        self.write({"README.md": "中文更新"})
        event = pathlib.Path(self.directory.name, "event.json")
        event.write_text(json.dumps({"pull_request": {"body": "Fix typo.\n\ndoc-i18n-skip: README, docs/tpm\n"}}))
        os.environ["GITHUB_EVENT_PATH"] = str(event)
        try:
            skip = CHECKER.skip_from_event()
        finally:
            del os.environ["GITHUB_EVENT_PATH"]
        self.assertEqual(skip, {"README", "docs/tpm"})
        self.assertEqual(self.check(skip), {})

    def test_cli_exit_status(self):
        self.write({"README.md": "中文更新"})
        head = self.commit()
        result = subprocess.run([sys.executable, str(CHECKER_PATH), self.base, head], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("README: also update README_en.md", result.stdout)


if __name__ == "__main__":
    unittest.main()
