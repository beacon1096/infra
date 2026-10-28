#!/usr/bin/env python3
"""Exercise Grafana OIDC Secret preparation with disposable fake tools."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "utils/prepare-grafana-oidc-secrets.sh"
SECRET = 'abc #tail true 123: [x] "quoted"'


class SecretPreparationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = pathlib.Path(self.directory.name)
        self.bin = self.repo / "bin"
        self.bin.mkdir()
        (self.repo / ".sops.yaml").write_text("keys: []\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True, capture_output=True)

        self.count = self.repo / "sops.count"
        self.input_prefix = self.repo / "sops.input"
        self._write_fake(
            "sops",
            """#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -e "$FAKE_SOPS_COUNT" ]]; then
  count=$(<"$FAKE_SOPS_COUNT")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_SOPS_COUNT"
cat >"${FAKE_SOPS_INPUT_PREFIX}.${count}"
if [[ "${FAKE_SOPS_FAIL_ON:-}" == "$count" ]]; then
  printf 'fake sops failure\n' >&2
  exit 7
fi
printf 'encrypted\n'
""",
        )
        self._write_fake(
            "openssl",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${FAKE_OPENSSL_OUTPUT-abc #tail true 123: [x] \\\"quoted\\\"}"
""",
        )
        self.environment = dict(
            os.environ,
            PATH=f"{self.bin}{os.pathsep}{pathlib.Path(sys.executable).parent}{os.pathsep}{os.environ['PATH']}",
            FAKE_SOPS_COUNT=str(self.count),
            FAKE_SOPS_INPUT_PREFIX=str(self.input_prefix),
        )

    def _write_fake(self, name: str, content: str) -> None:
        path = self.bin / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def run_script(self, **environment):
        env = dict(self.environment)
        for key, value in environment.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        return subprocess.run(
            ["bash", str(SCRIPT), "--generate"],
            cwd=self.repo,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def output_paths(self):
        return (
            self.repo / "wanxiang/kubernetes/apps/identity/authentik/app/grafana-oidc.sops.yaml",
            self.repo / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/app/grafana-oidc.sops.yaml",
        )

    def test_special_string_is_quoted_and_identical(self):
        result = self.run_script(FAKE_OPENSSL_OUTPUT=SECRET)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        inputs = [(self.input_prefix.parent / f"{self.input_prefix.name}.{index}").read_text() for index in (1, 2)]
        expected_identity = f"  AUTHENTIK_GRAFANA_OIDC_CLIENT_SECRET: {json.dumps(SECRET)}\n"
        expected_monitoring = f"  GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET: {json.dumps(SECRET)}\n"
        self.assertIn(expected_identity, inputs[0])
        self.assertIn(expected_monitoring, inputs[1])
        self.assertEqual(inputs[0].split("CLIENT_SECRET: ", 1)[1].strip(), json.dumps(SECRET))
        self.assertEqual(inputs[1].split("CLIENT_SECRET: ", 1)[1].strip(), json.dumps(SECRET))
        for path in self.output_paths():
            self.assertEqual(path.read_text(), "encrypted\n")

    def test_empty_input_rejects_without_sops(self):
        result = self.run_script(FAKE_OPENSSL_OUTPUT="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not be empty", result.stderr)
        self.assertFalse(self.count.exists())
        self.assertFalse(any(path.exists() for path in self.output_paths()))

    def test_existing_file_is_not_overwritten(self):
        path = self.output_paths()[0]
        path.parent.mkdir(parents=True)
        path.write_text("keep\n")
        result = self.run_script(FAKE_OPENSSL_OUTPUT=SECRET)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to overwrite", result.stderr)
        self.assertEqual(path.read_text(), "keep\n")
        self.assertFalse(self.count.exists())

    def test_second_encryption_failure_cleans_both_outputs(self):
        result = self.run_script(FAKE_OPENSSL_OUTPUT=SECRET, FAKE_SOPS_FAIL_ON="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        self.assertEqual(self.count.read_text(), "2\n")
        self.assertFalse(any(path.exists() for path in self.output_paths()))


if __name__ == "__main__":
    unittest.main()
