#!/usr/bin/env python3
"""Offline acceptance for the BEACO-216 Prometheus/Alertmanager preparation."""

import datetime as dt
import json
import os
import re
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/app"
STACK_KS = ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/ks.yaml"
MONITORING_KUSTOMIZATION = ROOT / "wanxiang/kubernetes/apps/monitoring/kustomization.yaml"
LONGHORN_RULE = ROOT / "wanxiang/kubernetes/apps/storage/longhorn/app/prometheusrule.yaml"
EXPECTED_PROMETHEUS = "3.15.0"
EXPECTED_ALERTMANAGER = "0.33.1"
EXPECTED_CHART_DIGEST = "sha256:ae5cd17378e9da8820fd3ea55ddfbd4bdd4d0c61f3b5bb4e04bb288b00f95f87"


def run(*command, check=True):
    completed = subprocess.run(command, capture_output=True, text=True)
    if check and completed.returncode:
        raise AssertionError(
            f"command failed ({completed.returncode}): {' '.join(command)}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed


def documents(path):
    return [item for item in yaml.safe_load_all(path.read_text(encoding="utf-8")) if item]


def one(path, kind=None):
    items = documents(path)
    if kind:
        items = [item for item in items if item.get("kind") == kind]
    if len(items) != 1:
        raise AssertionError(f"expected one {kind or 'document'} in {path}, got {len(items)}")
    return items[0]


def check_version(binary, expected):
    completed = run(binary, "--version")
    output = completed.stdout + completed.stderr
    match = re.search(r"version\s+v?([0-9]+\.[0-9]+\.[0-9]+)", output)
    if not match or match.group(1) != expected:
        raise AssertionError(f"{binary} version must be {expected}, got: {output.strip()}")


def validate_manifests():
    rendered = run("kubectl", "kustomize", str(APP)).stdout
    rendered_documents = [item for item in yaml.safe_load_all(rendered) if item]
    counts = {}
    for item in rendered_documents:
        counts[item["kind"]] = counts.get(item["kind"], 0) + 1
    expected = {
        "OCIRepository": 1,
        "HelmRelease": 1,
        "PodMonitor": 2,
        "PrometheusRule": 1,
    }
    if counts != expected:
        raise AssertionError(f"unexpected rendered kinds: {counts}")

    parent = one(MONITORING_KUSTOMIZATION, "Kustomization")
    if any("prometheus-stack" in resource for resource in parent["resources"]):
        raise AssertionError("prometheus-stack must remain disconnected from production Flux")
    stack = one(STACK_KS, "Kustomization")
    if stack["spec"]["path"] != "./wanxiang/kubernetes/apps/monitoring/prometheus-stack/app":
        raise AssertionError("unexpected prepared Flux path")

    source = one(APP / "ocirepository.yaml", "OCIRepository")
    if source["spec"]["ref"].get("digest") != EXPECTED_CHART_DIGEST:
        raise AssertionError("kube-prometheus-stack chart digest changed without review")

    release = one(APP / "helmrelease.yaml", "HelmRelease")
    values = release["spec"]["values"]
    if values.get("rbac", {}).get("create") is not True:
        raise AssertionError("chart RBAC must remain explicit for pre-enable review")
    prometheus = values["prometheus"]["prometheusSpec"]
    for selector in ("serviceMonitor", "podMonitor", "rule"):
        if prometheus[f"{selector}SelectorNilUsesHelmValues"] is not False:
            raise AssertionError(f"{selector} selector must not fall back to Helm labels")
        if prometheus[f"{selector}Selector"] != {}:
            raise AssertionError(f"{selector} selector must discover existing resources")
    if prometheus["retention"] != "7d" or prometheus["retentionSize"] != "15GB":
        raise AssertionError("Prometheus retention budget changed")
    prometheus_claim = prometheus["storageSpec"]["volumeClaimTemplate"]["spec"]
    if prometheus_claim["storageClassName"] != "longhorn-r3":
        raise AssertionError("Prometheus storage must use longhorn-r3")
    if prometheus_claim["resources"]["requests"]["storage"] != "20Gi":
        raise AssertionError("Prometheus PVC budget changed")

    alertmanager = values["alertmanager"]
    receivers = alertmanager["config"]["receivers"]
    if receivers != [{"name": "null"}]:
        raise AssertionError("prepared Alertmanager must have no external receiver")
    alertmanager_claim = alertmanager["alertmanagerSpec"]["storage"]["volumeClaimTemplate"]["spec"]
    if alertmanager_claim["resources"]["requests"]["storage"] != "2Gi":
        raise AssertionError("Alertmanager PVC budget changed")
    selector = alertmanager["alertmanagerSpec"]["alertmanagerConfigSelector"]["matchLabels"]
    if selector != {"observability.beacoworks.xyz/alertmanager": "wanxiang"}:
        raise AssertionError("private AlertmanagerConfig selector changed")


def expected_alert(labels, summary, description):
    return {
        "exp_labels": labels,
        "exp_annotations": {"summary": summary, "description": description},
    }


def validate_rules():
    custom = one(APP / "prometheusrule.yaml", "PrometheusRule")
    longhorn = one(LONGHORN_RULE, "PrometheusRule")
    alert_names = {
        rule["alert"]
        for group in custom["spec"]["groups"] + longhorn["spec"]["groups"]
        for rule in group["rules"]
        if "alert" in rule
    }
    expected_alert_names = {
        "WanxiangMonitoredTargetDown",
        "WanxiangNodeMetricsMissing",
        "WanxiangKubeStateMetricsMissing",
        "WanxiangLonghornMetricsMissing",
        "WanxiangCNPGMetricsMissing",
        "WanxiangEnvoyMetricsMissing",
        "WanxiangCertManagerMetricsMissing",
        "WanxiangNodeNotReady",
        "WanxiangNodeFilesystemLow",
        "WanxiangLonghornVolumeFaulted",
        "WanxiangLonghornBackupNeverSucceeded",
        "LonghornBackupStale",
        "LonghornBackupFailed",
        "WanxiangCNPGCollectorError",
        "WanxiangCNPGReplicationLagHigh",
        "WanxiangEnvoyUnavailable",
        "WanxiangCertificateExpiringSoon",
    }
    missing = expected_alert_names - alert_names
    if missing:
        raise AssertionError(f"required alert coverage is missing: {sorted(missing)}")
    groups = custom["spec"]["groups"] + longhorn["spec"]["groups"]
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        rule_file = directory / "rules.yaml"
        rule_file.write_text(yaml.safe_dump({"groups": groups}, sort_keys=False), encoding="utf-8")
        checked = run("promtool", "check", "rules", str(rule_file))
        if "SUCCESS" not in checked.stdout + checked.stderr:
            raise AssertionError("promtool did not report rule validation success")

        test_definition = {
            "rule_files": [str(rule_file)],
            "evaluation_interval": "1m",
            "tests": [
                {
                    "name": "targets, evidence, and domain failures resolve after recovery",
                    "interval": "1m",
                    "input_series": [
                        {
                            "series": 'up{job="podMonitor/monitoring/cnpg-instances/0",instance="fixture:9187"}',
                            "values": "0x5 1x60",
                        },
                        {
                            "series": 'longhorn_volume_last_backup_at{volume="fixture-volume",pvc="fixture",pvc_namespace="fixture"}',
                            "values": "0x30 1800x30",
                        },
                        {
                            "series": 'kube_node_status_condition{node="fixture-node",condition="Ready",status="true"}',
                            "values": "0x10 1x50",
                        },
                        {
                            "series": 'cnpg_collector_last_collection_error{namespace="fixture",cluster="fixture-pg",pod="fixture-pg-1"}',
                            "values": "1x5 0x55",
                        },
                        {
                            "series": 'cnpg_collector_collection_duration_seconds{namespace="fixture",cluster="fixture-pg"}',
                            "values": "_x11 0x49",
                        },
                        {
                            "series": 'envoy_server_live{pod="fixture-envoy"}',
                            "values": "0x5 1x55",
                        },
                        {
                            "series": 'certmanager_certificate_expiration_timestamp_seconds{name="fixture-cert",namespace="fixture"}',
                            "values": "86400x60 2000000x2",
                        },
                    ],
                    "alert_rule_test": [
                        {
                            "eval_time": "5m",
                            "alertname": "WanxiangMonitoredTargetDown",
                            "exp_alerts": [expected_alert(
                                {
                                    "component": "scrape",
                                    "instance": "fixture:9187",
                                    "job": "podMonitor/monitoring/cnpg-instances/0",
                                    "severity": "critical",
                                },
                                "A required Wanxiang metrics target is down",
                                "A selected Longhorn, CNPG, Envoy, or cert-manager target has failed scrapes for five minutes.",
                            )],
                        },
                        {"eval_time": "6m", "alertname": "WanxiangMonitoredTargetDown", "exp_alerts": []},
                        {
                            "eval_time": "10m",
                            "alertname": "WanxiangNodeNotReady",
                            "exp_alerts": [expected_alert(
                                {
                                    "component": "node",
                                    "condition": "Ready",
                                    "node": "fixture-node",
                                    "severity": "critical",
                                    "status": "true",
                                },
                                "A Wanxiang node is not Ready",
                                "kube-state-metrics reports that a node has remained non-Ready for ten minutes.",
                            )],
                        },
                        {"eval_time": "11m", "alertname": "WanxiangNodeNotReady", "exp_alerts": []},
                        {
                            "eval_time": "5m",
                            "alertname": "WanxiangCNPGCollectorError",
                            "exp_alerts": [expected_alert(
                                {
                                    "cluster": "fixture-pg",
                                    "component": "cnpg",
                                    "namespace": "fixture",
                                    "pod": "fixture-pg-1",
                                    "severity": "warning",
                                },
                                "CloudNativePG metrics collection is failing",
                                "A CNPG instance has reported collection errors for five minutes.",
                            )],
                        },
                        {"eval_time": "6m", "alertname": "WanxiangCNPGCollectorError", "exp_alerts": []},
                        {
                            "eval_time": "10m",
                            "alertname": "WanxiangCNPGMetricsMissing",
                            "exp_alerts": [expected_alert(
                                {"component": "cnpg", "severity": "critical"},
                                "CloudNativePG instance metrics are absent",
                                "CNPG health must be treated as unknown until instance collection recovers.",
                            )],
                        },
                        {"eval_time": "11m", "alertname": "WanxiangCNPGMetricsMissing", "exp_alerts": []},
                        {
                            "eval_time": "5m",
                            "alertname": "WanxiangEnvoyUnavailable",
                            "exp_alerts": [expected_alert(
                                {"component": "gateway", "pod": "fixture-envoy", "severity": "critical"},
                                "An Envoy gateway proxy is not live",
                                "Envoy has reported a non-live server state for five minutes.",
                            )],
                        },
                        {"eval_time": "6m", "alertname": "WanxiangEnvoyUnavailable", "exp_alerts": []},
                        {
                            "eval_time": "30m",
                            "alertname": "WanxiangLonghornBackupNeverSucceeded",
                            "exp_alerts": [expected_alert(
                                {
                                    "component": "longhorn",
                                    "pvc": "fixture",
                                    "pvc_namespace": "fixture",
                                    "severity": "warning",
                                    "volume": "fixture-volume",
                                },
                                "A Longhorn volume has no successful backup",
                                "Per-volume freshness is unhealthy until a completed backup timestamp exists.",
                            )],
                        },
                        {"eval_time": "31m", "alertname": "WanxiangLonghornBackupNeverSucceeded", "exp_alerts": []},
                        {
                            "eval_time": "1h",
                            "alertname": "WanxiangCertificateExpiringSoon",
                            "exp_alerts": [expected_alert(
                                {
                                    "component": "certificate",
                                    "name": "fixture-cert",
                                    "namespace": "fixture",
                                    "severity": "warning",
                                },
                                "A managed certificate expires within fourteen days",
                                "cert-manager reports less than fourteen days of certificate lifetime remaining.",
                            )],
                        },
                        {"eval_time": "61m", "alertname": "WanxiangCertificateExpiringSoon", "exp_alerts": []},
                    ],
                }
            ],
        }
        test_file = directory / "rules-test.yaml"
        test_file.write_text(yaml.safe_dump(test_definition, sort_keys=False), encoding="utf-8")
        run("promtool", "test", "rules", str(test_file))


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length))
        with self.server.condition:
            self.server.payloads.append(payload)
            self.server.condition.notify_all()
        self.send_response(200)
        self.end_headers()

    def log_message(self, *_arguments):
        return


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def wait_ready(url, process, log_path, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f"Alertmanager exited early:\n{log_path.read_text()}")
        try:
            with urllib.request.urlopen(url, timeout=0.5) as response:
                if response.status == 200:
                    return
        except (urllib.error.URLError, TimeoutError):
            time.sleep(0.1)
    raise AssertionError(f"Alertmanager readiness timed out:\n{log_path.read_text()}")


def post_json(url, payload):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=2) as response:
        if response.status not in (200, 202):
            raise AssertionError(f"unexpected Alertmanager response: {response.status}")


def wait_webhook(server, status, timeout=10):
    deadline = time.monotonic() + timeout
    with server.condition:
        while time.monotonic() < deadline:
            if any(payload.get("status") == status for payload in server.payloads):
                return
            server.condition.wait(deadline - time.monotonic())
    raise AssertionError(f"local stub did not receive {status}: {server.payloads}")


def validate_alert_delivery():
    webhook = ThreadingHTTPServer(("127.0.0.1", 0), WebhookHandler)
    webhook.payloads = []
    webhook.condition = threading.Condition()
    webhook_thread = threading.Thread(target=webhook.serve_forever, daemon=True)
    webhook_thread.start()
    alertmanager = None
    log_handle = None
    try:
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            webhook_url = f"http://127.0.0.1:{webhook.server_port}/alerts"
            config = {
                "global": {"resolve_timeout": "1m"},
                "route": {
                    "receiver": "local-stub",
                    "group_by": ["alertname"],
                    "group_wait": "0s",
                    "group_interval": "1s",
                    "repeat_interval": "1h",
                },
                "receivers": [
                    {
                        "name": "local-stub",
                        "webhook_configs": [{"url": webhook_url, "send_resolved": True}],
                    }
                ],
            }
            if not webhook_url.startswith("http://127.0.0.1:"):
                raise AssertionError("test notification destination must be loopback only")
            config_path = directory / "alertmanager.yaml"
            config_path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
            log_path = directory / "alertmanager.log"
            log_handle = log_path.open("w", encoding="utf-8")
            port = free_port()
            alertmanager = subprocess.Popen(
                [
                    "alertmanager",
                    f"--config.file={config_path}",
                    f"--storage.path={directory / 'data'}",
                    f"--web.listen-address=127.0.0.1:{port}",
                    "--cluster.listen-address=",
                ],
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            wait_ready(f"http://127.0.0.1:{port}/-/ready", alertmanager, log_path)

            now = dt.datetime.now(dt.timezone.utc)
            starts_at = now - dt.timedelta(minutes=5)
            labels = {"alertname": "OfflineDeliveryFixture", "severity": "warning"}
            base = {
                "labels": labels,
                "annotations": {"summary": "local-only delivery fixture"},
                "startsAt": starts_at.isoformat(),
                "generatorURL": "http://127.0.0.1/offline-fixture",
            }
            post_json(
                f"http://127.0.0.1:{port}/api/v2/alerts",
                [{**base, "endsAt": (now + dt.timedelta(minutes=5)).isoformat()}],
            )
            wait_webhook(webhook, "firing")
            post_json(
                f"http://127.0.0.1:{port}/api/v2/alerts",
                [{**base, "endsAt": (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=1)).isoformat()}],
            )
            wait_webhook(webhook, "resolved")
    finally:
        if alertmanager is not None and alertmanager.poll() is None:
            os.killpg(alertmanager.pid, 15)
            try:
                alertmanager.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(alertmanager.pid, 9)
                alertmanager.wait()
        if log_handle is not None:
            log_handle.close()
        webhook.shutdown()
        webhook.server_close()
        webhook_thread.join(timeout=2)


def main():
    check_version("promtool", EXPECTED_PROMETHEUS)
    check_version("alertmanager", EXPECTED_ALERTMANAGER)
    validate_manifests()
    validate_rules()
    validate_alert_delivery()
    print(
        "observability preparation passed: manifests disconnected; rules fire/resolve; "
        "Alertmanager delivered firing/resolved only to loopback stub"
    )


if __name__ == "__main__":
    main()
