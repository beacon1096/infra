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
EXPECTED_PROMETHEUS = "3.12.0"
EXPECTED_ALERTMANAGER = "0.31.1"
EXPECTED_CHART_VERSION = "83.7.0"
EXPECTED_OPERATOR_VERSION = "v0.90.1"
EXPECTED_CHART_DIGEST = "sha256:ae5cd17378e9da8820fd3ea55ddfbd4bdd4d0c61f3b5bb4e04bb288b00f95f87"
CHART = "oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack"


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


def named(items, kind, name):
    matches = [
        item for item in items
        if item.get("kind") == kind and item.get("metadata", {}).get("name") == name
    ]
    if len(matches) != 1:
        raise AssertionError(f"expected one {kind}/{name}, got {len(matches)}")
    return matches[0]


def render_chart(values):
    with tempfile.TemporaryDirectory() as directory:
        values_path = Path(directory) / "values.yaml"
        values_path.write_text(yaml.safe_dump(values, sort_keys=False), encoding="utf-8")
        rendered = run(
            "helm", "template", "kube-prometheus-stack", CHART,
            "--version", EXPECTED_CHART_VERSION,
            "--namespace", "monitoring",
            "--values", str(values_path),
        ).stdout
    return [item for item in yaml.safe_load_all(rendered) if item]


def validate_manifests():
    rendered = run("kubectl", "kustomize", str(APP)).stdout
    rendered_documents = [item for item in yaml.safe_load_all(rendered) if item]
    counts = {}
    for item in rendered_documents:
        counts[item["kind"]] = counts.get(item["kind"], 0) + 1
    expected = {
        "OCIRepository": 1,
        "HelmRelease": 1,
        "ClusterRole": 2,
        "ClusterRoleBinding": 2,
        "Role": 1,
        "RoleBinding": 1,
        "PodMonitor": 2,
        "PrometheusRule": 1,
    }
    if counts != expected:
        raise AssertionError(f"unexpected rendered kinds: {counts}")

    parent = one(MONITORING_KUSTOMIZATION, "Kustomization")
    if "./prometheus-stack/ks.yaml" not in parent["resources"]:
        raise AssertionError("enabled monitoring parent must reference prometheus-stack")
    stack = one(STACK_KS, "Kustomization")
    if stack["spec"]["path"] != "./wanxiang/kubernetes/apps/monitoring/prometheus-stack/app":
        raise AssertionError("unexpected prepared Flux path")

    source = one(APP / "ocirepository.yaml", "OCIRepository")
    if source["spec"]["ref"].get("digest") != EXPECTED_CHART_DIGEST:
        raise AssertionError("kube-prometheus-stack chart digest changed without review")

    release = one(APP / "helmrelease.yaml", "HelmRelease")
    values = release["spec"]["values"]
    if values.get("global", {}).get("rbac", {}).get("create") is not False:
        raise AssertionError("the chart's broad global RBAC must remain disabled")
    if values["prometheusOperator"]["admissionWebhooks"]["enabled"] is not False:
        raise AssertionError("unneeded operator admission webhook must remain disabled")
    if values["prometheusOperator"]["tls"]["enabled"] is not False:
        raise AssertionError("operator TLS must stay off when no admission certificate is produced")
    if values["prometheusOperator"]["kubeletService"]["namespace"] != "monitoring":
        raise AssertionError("operator kubelet synchronization must stay in monitoring")
    if values["kubelet"]["namespace"] != "monitoring":
        raise AssertionError("kubelet ServiceMonitor must stay beside its managed Service")
    if values["kube-state-metrics"].get("collectors") != ["nodes", "pods"]:
        raise AssertionError("kube-state-metrics collectors must remain minimal and Secret-free")
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
    namespace_selector = alertmanager["alertmanagerSpec"]["alertmanagerConfigNamespaceSelector"]
    if namespace_selector != {"matchLabels": {"kubernetes.io/metadata.name": "monitoring"}}:
        raise AssertionError("AlertmanagerConfig sources must remain namespace-restricted")
    strategy = alertmanager["alertmanagerSpec"].get("alertmanagerConfigMatcherStrategy")
    if strategy != {"type": "None"}:
        raise AssertionError("cross-namespace alerts require the reviewed None matcher strategy")

    discovery = named(
        rendered_documents,
        "ClusterRole",
        "kube-prometheus-stack-operator-discovery",
    )
    for rule in discovery["rules"]:
        if set(rule.get("resources", [])) & {"secrets", "configmaps"}:
            raise AssertionError("cluster-wide operator discovery must not read Secret/ConfigMap")
        if not set(rule["verbs"]) <= {"get", "list", "watch"}:
            raise AssertionError("cluster-wide operator discovery must remain read-only")
    reconcile = named(
        rendered_documents,
        "Role",
        "kube-prometheus-stack-operator-reconcile",
    )
    if reconcile["metadata"].get("namespace") != "monitoring":
        raise AssertionError("operator mutations must be scoped to monitoring")
    if any("*" in rule.get("verbs", []) for rule in reconcile["rules"]):
        raise AssertionError("namespace-local operator verbs must remain enumerated")

    chart_documents = render_chart(values)
    if any(
        item.get("kind") == "ClusterRole"
        and item.get("metadata", {}).get("name") == "kube-prometheus-stack-operator"
        for item in chart_documents
    ):
        raise AssertionError("chart rendered its broad operator ClusterRole")
    ksm_role = named(
        chart_documents,
        "ClusterRole",
        "kube-prometheus-stack-kube-state-metrics",
    )
    ksm_resources = {
        resource
        for rule in ksm_role["rules"]
        for resource in rule.get("resources", [])
    }
    if ksm_resources != {"nodes", "pods"}:
        raise AssertionError(f"unexpected kube-state-metrics cluster access: {ksm_resources}")
    operator = named(chart_documents, "Deployment", "kube-prometheus-stack-operator")
    operator_pod = operator["spec"]["template"]["spec"]
    operator_container = operator_pod["containers"][0]
    operator_image = operator_container["image"]
    if not operator_image.endswith(f":{EXPECTED_OPERATOR_VERSION}"):
        raise AssertionError(f"unexpected Prometheus Operator image: {operator_image}")
    operator_args = operator_container["args"]
    if "--web.enable-tls=false" not in operator_args:
        raise AssertionError("operator did not render its reviewed HTTP-only endpoint")
    if "--kubelet-service=monitoring/kube-prometheus-stack-kubelet" not in operator_args:
        raise AssertionError("operator kubelet target escaped the monitoring Role")
    if any(volume.get("secret") for volume in (operator_pod.get("volumes") or [])):
        raise AssertionError("HTTP-only operator unexpectedly requires a TLS Secret")
    for probe_name in ("livenessProbe", "readinessProbe"):
        probe = operator_container[probe_name]["httpGet"]
        if probe.get("scheme") != "HTTP" or probe.get("port") != "http":
            raise AssertionError(f"operator {probe_name} did not follow the HTTP endpoint")
    operator_monitor = named(
        chart_documents,
        "ServiceMonitor",
        "kube-prometheus-stack-operator",
    )
    if operator_monitor["spec"]["endpoints"] != [{"port": "http", "honorLabels": True}]:
        raise AssertionError("operator ServiceMonitor still expects admission TLS")
    kubelet_monitor = named(
        chart_documents,
        "ServiceMonitor",
        "kube-prometheus-stack-kubelet",
    )
    if kubelet_monitor["metadata"].get("namespace") != "monitoring":
        raise AssertionError("kubelet ServiceMonitor rendered outside monitoring")
    if kubelet_monitor["spec"].get("namespaceSelector") != {"matchNames": ["monitoring"]}:
        raise AssertionError("kubelet ServiceMonitor does not select the managed Service namespace")
    service_rule = next(
        (
            rule for rule in reconcile["rules"]
            if {"services", "endpoints"} <= set(rule.get("resources", []))
        ),
        None,
    )
    if service_rule is None or not {"get", "create", "update"} <= set(service_rule["verbs"]):
        raise AssertionError("monitoring Role cannot maintain the kubelet Service/Endpoints")
    named(chart_documents, "ServiceAccount", "kube-prometheus-stack-operator")
    named(chart_documents, "ServiceAccount", "kube-prometheus-stack-prometheus")
    alertmanager_resource = named(
        chart_documents,
        "Alertmanager",
        "kube-prometheus-stack-alertmanager",
    )
    if alertmanager_resource["spec"].get("alertmanagerConfigMatcherStrategy") != {"type": "None"}:
        raise AssertionError("rendered Alertmanager lost its cross-namespace matcher strategy")

    selected_labels = {"observability.beacoworks.xyz/alertmanager": "wanxiang"}
    if not (
        selector.items() <= selected_labels.items()
        and namespace_selector["matchLabels"] == {"kubernetes.io/metadata.name": "monitoring"}
    ):
        raise AssertionError("the approved private AlertmanagerConfig fixture was not selected")
    if selector.items() <= {"observability.beacoworks.xyz/alertmanager": "other"}.items():
        raise AssertionError("a wrong AlertmanagerConfig label was selected")


def expected_alert(labels, summary, description):
    return {
        "exp_labels": labels,
        "exp_annotations": {"summary": summary, "description": description},
    }


def alert_count(alertname, eval_time, expected, extra_matchers=""):
    matchers = f'alertname="{alertname}",alertstate="firing"'
    if extra_matchers:
        matchers += f",{extra_matchers}"
    return {
        "expr": f"(count(ALERTS{{{matchers}}}) > bool 0) or vector(0)",
        "eval_time": eval_time,
        "exp_samples": [{"labels": "{}", "value": expected}],
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
        "WanxiangMonitoredTargetMissing",
        "WanxiangNodeMetricsMissing",
        "WanxiangNodeExporterMetricMissing",
        "WanxiangKubeStateMetricsMissing",
        "WanxiangLonghornMetricsMissing",
        "WanxiangCNPGMetricsMissing",
        "WanxiangEnvoyMetricsMissing",
        "WanxiangCertManagerMetricsMissing",
        "WanxiangNodeNotReady",
        "WanxiangNodeFilesystemLow",
        "WanxiangLonghornVolumeFaulted",
        "WanxiangLonghornBackupMetricMissing",
        "WanxiangLonghornBackupNeverSucceeded",
        "LonghornBackupStale",
        "LonghornBackupFailed",
        "WanxiangCNPGCollectorError",
        "WanxiangCNPGInstanceMetricMissing",
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
                            "series": 'up{job="monitoring/cnpg-instances",instance="fixture:9187"}',
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
                                    "job": "monitoring/cnpg-instances",
                                    "severity": "critical",
                                },
                                "A required Wanxiang metrics target is down",
                                "A selected node, Longhorn, CNPG, Envoy, or cert-manager target has failed scrapes for five minutes.",
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
                },
                {
                    "name": "real labels, partial evidence loss, and target removal recover",
                    "interval": "1m",
                    "input_series": [
                        {
                            "series": 'up{job="monitoring/cnpg-instances",namespace="fixture",pod="pg-down",instance="down:9187"}',
                            "values": "0x5 1x70",
                        },
                        {
                            "series": 'longhorn_volume_robustness{volume="bad-volume",state="faulted"}',
                            "values": "1x5 0x70",
                        },
                        {
                            "series": 'longhorn_volume_capacity_bytes{volume="missing-volume",pvc="missing",pvc_namespace="fixture"}',
                            "values": "100x75",
                        },
                        {
                            "series": 'longhorn_volume_capacity_bytes{volume="healthy-volume",pvc="healthy",pvc_namespace="fixture"}',
                            "values": "100x75",
                        },
                        {
                            "series": 'longhorn_volume_last_backup_at{volume="missing-volume",pvc="missing",pvc_namespace="fixture"}',
                            "values": "1 stale _x64 2x10",
                        },
                        {
                            "series": 'longhorn_volume_last_backup_at{volume="healthy-volume",pvc="healthy",pvc_namespace="fixture"}',
                            "values": "1+60x75",
                        },
                        {
                            "series": 'up{job="monitoring/cnpg-instances",namespace="fixture",pod="pg-metric-missing",instance="missing:9187"}',
                            "values": "1x75",
                        },
                        {
                            "series": 'cnpg_collector_collection_duration_seconds{job="monitoring/cnpg-instances",namespace="fixture",pod="pg-metric-missing",instance="missing:9187"}',
                            "values": "0.1 stale _x64 0.2x10",
                        },
                        {
                            "series": 'kube_pod_container_status_ready{namespace="fixture",pod="pg-target-missing",container="postgres",uid="fixture-uid"}',
                            "values": "1x75",
                        },
                        {
                            "series": 'kube_pod_owner{namespace="fixture",pod="pg-target-missing",owner_kind="Cluster",owner_name="fixture-pg",owner_is_controller="true"}',
                            "values": "1x75",
                        },
                        {
                            "series": 'up{job="monitoring/cnpg-instances",namespace="fixture",pod="pg-healthy",instance="healthy:9187"}',
                            "values": "1x75",
                        },
                        {
                            "series": 'kube_pod_container_status_ready{namespace="fixture",pod="pg-healthy",container="postgres",uid="fixture-healthy-uid"}',
                            "values": "1x75",
                        },
                        {
                            "series": 'kube_pod_owner{namespace="fixture",pod="pg-healthy",owner_kind="Cluster",owner_name="fixture-pg",owner_is_controller="true"}',
                            "values": "1x75",
                        },
                        {
                            "series": 'kube_pod_container_status_ready{namespace="ai",pod="memoh-postgres-0",container="postgres",uid="memoh-uid"}',
                            "values": "1x75",
                        },
                        {
                            "series": 'kube_pod_owner{namespace="ai",pod="memoh-postgres-0",owner_kind="StatefulSet",owner_name="memoh-postgres",owner_is_controller="true"}',
                            "values": "1x75",
                        },
                        {
                            "series": 'up{job="monitoring/cnpg-instances",namespace="fixture",pod="pg-target-missing",instance="removed:9187"}',
                            "values": "1 stale _x19 1x55",
                        },
                        {
                            "series": 'up{job="node-exporter",namespace="monitoring",pod="node-exporter-down",instance="down:9100"}',
                            "values": "0x5 1x70",
                        },
                        {
                            "series": 'kube_pod_container_status_ready{namespace="monitoring",pod="node-exporter-missing",container="node-exporter",uid="node-uid"}',
                            "values": "1x75",
                        },
                        {
                            "series": 'up{job="node-exporter",namespace="monitoring",pod="node-exporter-missing",instance="removed:9100"}',
                            "values": "1 stale _x19 1x55",
                        },
                        {
                            "series": 'up{job="node-exporter",namespace="monitoring",pod="node-exporter-metric-missing",instance="missing:9100"}',
                            "values": "1x75",
                        },
                        {
                            "series": 'node_uname_info{job="node-exporter",namespace="monitoring",pod="node-exporter-metric-missing",instance="missing:9100"}',
                            "values": "1 stale _x64 1x10",
                        },
                        {
                            "series": 'up{job="node-exporter",namespace="monitoring",pod="node-exporter-healthy",instance="healthy:9100"}',
                            "values": "1x75",
                        },
                        {
                            "series": 'node_uname_info{job="node-exporter",namespace="monitoring",pod="node-exporter-healthy",instance="healthy:9100"}',
                            "values": "1x75",
                        },
                    ],
                    "promql_expr_test": [
                        alert_count("WanxiangMonitoredTargetDown", "5m", 1, 'pod="pg-down"'),
                        alert_count("WanxiangMonitoredTargetDown", "6m", 0, 'pod="pg-down"'),
                        alert_count("WanxiangLonghornVolumeFaulted", "5m", 1, 'volume="bad-volume"'),
                        alert_count("WanxiangLonghornVolumeFaulted", "6m", 0, 'volume="bad-volume"'),
                        alert_count("WanxiangLonghornBackupMetricMissing", "65m", 1, 'volume="missing-volume"'),
                        alert_count("WanxiangLonghornBackupMetricMissing", "66m", 0, 'volume="missing-volume"'),
                        alert_count("WanxiangLonghornBackupMetricMissing", "65m", 0, 'volume="healthy-volume"'),
                        alert_count("WanxiangCNPGInstanceMetricMissing", "65m", 1, 'pod="pg-metric-missing"'),
                        alert_count("WanxiangCNPGInstanceMetricMissing", "66m", 0, 'pod="pg-metric-missing"'),
                        alert_count("WanxiangMonitoredTargetMissing", "20m", 1, 'pod="pg-target-missing"'),
                        alert_count("WanxiangMonitoredTargetMissing", "21m", 1, 'pod="pg-target-missing"'),
                        alert_count("WanxiangMonitoredTargetMissing", "22m", 0, 'pod="pg-target-missing"'),
                        alert_count("WanxiangMonitoredTargetMissing", "20m", 0, 'pod="pg-healthy"'),
                        alert_count("WanxiangMonitoredTargetMissing", "20m", 0, 'pod="memoh-postgres-0"'),
                        alert_count("WanxiangMonitoredTargetMissing", "21m", 0, 'pod="memoh-postgres-0"'),
                        alert_count("WanxiangMonitoredTargetDown", "5m", 1, 'pod="node-exporter-down"'),
                        alert_count("WanxiangMonitoredTargetDown", "6m", 0, 'pod="node-exporter-down"'),
                        alert_count("WanxiangMonitoredTargetMissing", "20m", 1, 'pod="node-exporter-missing"'),
                        alert_count("WanxiangMonitoredTargetMissing", "21m", 1, 'pod="node-exporter-missing"'),
                        alert_count("WanxiangMonitoredTargetMissing", "22m", 0, 'pod="node-exporter-missing"'),
                        alert_count("WanxiangNodeExporterMetricMissing", "65m", 1, 'pod="node-exporter-metric-missing"'),
                        alert_count("WanxiangNodeExporterMetricMissing", "66m", 0, 'pod="node-exporter-metric-missing"'),
                        alert_count("WanxiangNodeExporterMetricMissing", "65m", 0, 'pod="node-exporter-healthy"'),
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


def wait_webhook(server, status, expected_alertnames, timeout=10):
    deadline = time.monotonic() + timeout
    with server.condition:
        while time.monotonic() < deadline:
            observed = {
                alert.get("labels", {}).get("alertname")
                for payload in server.payloads
                if payload.get("status") == status
                for alert in payload.get("alerts", [])
            }
            if expected_alertnames <= observed:
                return
            server.condition.wait(deadline - time.monotonic())
    raise AssertionError(
        f"local stub did not receive {status} for {expected_alertnames}: {server.payloads}"
    )


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
                    "receiver": "null",
                    "group_by": ["alertname", "namespace"],
                    "group_wait": "0s",
                    "group_interval": "1s",
                    "repeat_interval": "1h",
                    # This is the route shape produced for the selected private
                    # AlertmanagerConfig when matcher strategy None is used.
                    # It intentionally has no namespace matcher.
                    "routes": [
                        {
                            "receiver": "local-stub",
                            "matchers": ['severity=~"warning|critical"'],
                        }
                    ],
                },
                "receivers": [
                    {"name": "null"},
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
            route_cases = [
                (["alertname=StorageRouteFixture", "namespace=storage", "severity=warning"], "local-stub"),
                (["alertname=CNPGRouteFixture", "namespace=ai", "severity=critical"], "local-stub"),
                (["alertname=NodeRouteFixture", "node=ms01-a", "severity=warning"], "local-stub"),
                (["alertname=RejectedInfoFixture", "namespace=monitoring", "severity=info"], "null"),
            ]
            for labels, receiver in route_cases:
                routed = run(
                    "amtool", "config", "routes", "test",
                    f"--config.file={config_path}", "--tree", *labels,
                )
                if receiver not in routed.stdout:
                    raise AssertionError(
                        f"route {labels} did not select {receiver}: {routed.stdout}"
                    )
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
            label_sets = [
                {"alertname": "StorageRouteFixture", "namespace": "storage", "severity": "warning"},
                {"alertname": "CNPGRouteFixture", "namespace": "ai", "severity": "critical"},
                {"alertname": "NodeRouteFixture", "node": "ms01-a", "severity": "warning"},
                {"alertname": "RejectedInfoFixture", "namespace": "monitoring", "severity": "info"},
            ]
            routed_alertnames = {
                "StorageRouteFixture", "CNPGRouteFixture", "NodeRouteFixture"
            }

            def alerts(ends_at):
                return [
                    {
                        "labels": labels,
                        "annotations": {"summary": "local-only delivery fixture"},
                        "startsAt": starts_at.isoformat(),
                        "endsAt": ends_at,
                        "generatorURL": "http://127.0.0.1/offline-fixture",
                    }
                    for labels in label_sets
                ]

            post_json(
                f"http://127.0.0.1:{port}/api/v2/alerts",
                alerts((now + dt.timedelta(minutes=5)).isoformat()),
            )
            wait_webhook(webhook, "firing", routed_alertnames)
            post_json(
                f"http://127.0.0.1:{port}/api/v2/alerts",
                alerts((dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=1)).isoformat()),
            )
            wait_webhook(webhook, "resolved", routed_alertnames)
            delivered = {
                alert.get("labels", {}).get("alertname")
                for payload in webhook.payloads
                for alert in payload.get("alerts", [])
            }
            if "RejectedInfoFixture" in delivered:
                raise AssertionError("the unselected info route reached the webhook stub")
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
        "observability preparation passed: parent references prometheus-stack; rules fire/resolve; "
        "Alertmanager delivered firing/resolved only to loopback stub"
    )


if __name__ == "__main__":
    main()
