#!/usr/bin/env python3
"""Extract the WanxiangCertificateExpiringSoon rule into a standalone rules file
so promtool can unit-test it without the cluster."""

import pathlib
import sys

import yaml

SOURCE = pathlib.Path(
    "wanxiang/kubernetes/apps/monitoring/prometheus-stack/app/prometheusrule.yaml"
)
ALERT = "WanxiangCertificateExpiringSoon"


def main() -> int:
    out = pathlib.Path(sys.argv[1])
    doc = yaml.safe_load(SOURCE.read_text())
    for group in doc["spec"]["groups"]:
        for rule in group.get("rules", []):
            if rule.get("alert") == ALERT:
                out.write_text(yaml.safe_dump({"groups": [{"name": "certificate-test", "rules": [rule]}]}))
                return 0
    print(f"rule {ALERT} not found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
