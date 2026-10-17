#!/usr/bin/env python3
"""Validate the import-only observability dashboard and its real PromQL schema."""

import json
import subprocess
import tempfile
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
DASHBOARD = (
    ROOT
    / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/dashboards/wanxiang-platform-overview.json"
)
HELM_RELEASE = (
    ROOT
    / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/app/helmrelease.yaml"
)
PARENT_KUSTOMIZATION = ROOT / "wanxiang/kubernetes/apps/monitoring/kustomization.yaml"
ENABLEMENT_PATCH = (
    ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/enable-parent.diff"
)

REQUIRED_TITLES = {
    "Collection state",
    "Discovery state",
    "Metric evidence state",
    "Active platform alerts",
    "Node readiness",
    "Node CPU busy",
    "Node memory available",
    "Node filesystem free",
    "Longhorn volume robustness",
    "Per-volume backup freshness",
    "Backup execution state",
    "CNPG collector state",
    "CNPG replication lag",
    "Gateway live state",
    "Certificate lifetime remaining",
    "Required targets",
}

REQUIRED_METRICS = {
    "ALERTS",
    "up",
    "kube_pod_container_status_ready",
    "kube_node_status_condition",
    "node_cpu_seconds_total",
    "node_memory_MemAvailable_bytes",
    "node_memory_MemTotal_bytes",
    "node_uname_info",
    "node_filesystem_avail_bytes",
    "node_filesystem_size_bytes",
    "longhorn_volume_robustness",
    "longhorn_volume_capacity_bytes",
    "longhorn_volume_last_backup_at",
    "longhorn_backup_state",
    "cnpg_collector_collection_duration_seconds",
    "cnpg_collector_last_collection_error",
    "cnpg_pg_replication_lag",
    "envoy_server_live",
    "certmanager_certificate_expiration_timestamp_seconds",
}


def run(*arguments):
    completed = subprocess.run(arguments, text=True, capture_output=True)
    if completed.returncode:
        raise AssertionError(
            f"command failed ({' '.join(arguments)}):\n{completed.stdout}{completed.stderr}"
        )
    return completed


def panel_map(dashboard):
    panels = {panel["title"]: panel for panel in dashboard["panels"]}
    if len(panels) != len(dashboard["panels"]):
        raise AssertionError("dashboard panel titles must be unique")
    return panels


def query(panels, title):
    targets = panels[title].get("targets", [])
    if len(targets) != 1 or not targets[0].get("expr"):
        raise AssertionError(f"{title!r} must have exactly one Prometheus query")
    return targets[0]["expr"]


def validate_dashboard(dashboard, panels):
    if dashboard.get("uid") != "wanxiang-platform-overview":
        raise AssertionError("dashboard uid changed")
    if dashboard.get("schemaVersion", 0) < 39:
        raise AssertionError("dashboard schema version is too old for the reviewed artifact")
    if {item.get("name") for item in dashboard.get("__inputs", [])} != {"DS_PROMETHEUS"}:
        raise AssertionError("dashboard must request exactly one Prometheus datasource on import")
    missing_panels = REQUIRED_TITLES - panels.keys()
    if missing_panels:
        raise AssertionError(f"required dashboard panels are missing: {sorted(missing_panels)}")

    expressions = []
    for title, panel in panels.items():
        if panel.get("datasource", {}).get("uid") != "${DS_PROMETHEUS}":
            raise AssertionError(f"{title!r} is not bound to the import datasource")
        if panel.get("fieldConfig", {}).get("defaults", {}).get("noValue") != "Unknown":
            raise AssertionError(f"{title!r} could render missing evidence as an implicit healthy value")
        expressions.append(query(panels, title))

    for title in ("Node CPU busy", "Node memory available"):
        target = panels[title]["targets"][0]
        if target.get("instant") is not True:
            raise AssertionError(f"{title} must evaluate the current instant, not the last value in a range")

    joined = "\n".join(expressions)
    missing_metrics = {metric for metric in REQUIRED_METRICS if metric not in joined}
    if missing_metrics:
        raise AssertionError(f"dashboard does not use required real metric schema: {sorted(missing_metrics)}")
    if 'condition="true"' in joined:
        raise AssertionError("KSM pod readiness does not expose a condition label")
    if 'longhorn_volume_robustness == 3' in joined:
        raise AssertionError("Longhorn 1.12.1 faulted robustness is a state label with value 1")

    for title, normal_text in (
        ("Collection state", "Healthy"),
        ("Discovery state", "Healthy"),
        ("Metric evidence state", "Present"),
    ):
        mappings = panels[title]["fieldConfig"]["defaults"]["mappings"]
        values = {
            key: value
            for mapping in mappings if mapping["type"] == "value"
            for key, value in mapping["options"].items()
        }
        for state, text, color in (
            ("0", normal_text, "green"),
            ("2", "Critical", "red"),
            ("3", "Unknown", "orange"),
        ):
            mapped = values.get(state, {})
            if mapped.get("text") != text or mapped.get("color") != color:
                raise AssertionError(f"{title}: query state {state} must display {text} in {color}")

    release = yaml.safe_load(HELM_RELEASE.read_text(encoding="utf-8"))
    if release["spec"]["values"]["grafana"]["enabled"] is not False:
        raise AssertionError("the dashboard preparation must not enable Grafana")
    parent = yaml.safe_load(PARENT_KUSTOMIZATION.read_text(encoding="utf-8"))
    if "./prometheus-stack/ks.yaml" not in parent.get("resources", []):
        raise AssertionError("enabled monitoring parent must reference prometheus-stack")
    patch = ENABLEMENT_PATCH.read_text(encoding="utf-8")
    if "prometheus-stack/ks.yaml" not in patch:
        raise AssertionError("enablement patch must record the prometheus-stack Flux reference")
    for kustomization in (ROOT / "wanxiang/kubernetes/apps/monitoring").rglob("kustomization.yaml"):
        if "enable-parent.diff" in kustomization.read_text(encoding="utf-8"):
            raise AssertionError(f"{kustomization} must not consume the enablement patch")


def expression_case(expression, labels, values):
    checks = []
    for minute, value in enumerate(values):
        check = {"expr": expression, "eval_time": f"{minute}m", "exp_samples": []}
        if value is not None:
            check["exp_samples"] = [{"labels": labels, "value": value}]
        checks.append(check)
    return checks


def validate_queries(panels):
    series = [
        {
            "series": 'up{job="node-exporter",namespace="monitoring",pod="node-exporter-ms01-a",instance="ms01-a:9100"}',
            "values": "1 0 stale 1",
        },
        {
            "series": 'kube_pod_container_status_ready{namespace="monitoring",pod="node-exporter-ms01-a",container="node-exporter",uid="fixture-uid"}',
            "values": "1 1 stale 1",
        },
        {
            "series": 'node_uname_info{job="node-exporter",namespace="monitoring",pod="node-exporter-ms01-a",instance="ms01-a:9100"}',
            "values": "1 1 stale 1",
        },
        {
            "series": 'node_cpu_seconds_total{job="node-exporter",namespace="monitoring",pod="node-exporter-ms01-a",instance="ms01-a:9100",mode="idle",cpu="0"}',
            "values": "0 30 stale 90",
        },
        {
            "series": 'node_memory_MemAvailable_bytes{job="node-exporter",namespace="monitoring",pod="node-exporter-ms01-a",instance="ms01-a:9100"}',
            "values": "800 200 stale 800",
        },
        {
            "series": 'node_memory_MemTotal_bytes{job="node-exporter",namespace="monitoring",pod="node-exporter-ms01-a",instance="ms01-a:9100"}',
            "values": "1000 1000 1000 1000",
        },
        {
            "series": 'kube_node_status_condition{node="ms01-a",condition="Ready",status="true"}',
            "values": "1 0 stale 1",
        },
        {
            "series": 'node_filesystem_avail_bytes{instance="ms01-a:9100",fstype="ext4",mountpoint="/var"}',
            "values": "80 10 stale 80",
        },
        {
            "series": 'node_filesystem_size_bytes{instance="ms01-a:9100",fstype="ext4",mountpoint="/var"}',
            "values": "100 100 100 100",
        },
        {
            "series": 'longhorn_volume_robustness{volume="pvc-fixture",state="faulted"}',
            "values": "0 1 stale 0",
        },
        {
            "series": 'longhorn_volume_last_backup_at{volume="pvc-fixture",pvc="fixture",pvc_namespace="monitoring"}',
            "values": "0 -172740 stale 180",
        },
        {
            "series": 'longhorn_backup_state{volume="pvc-fixture",backup="backup-fixture"}',
            "values": "1 4 stale 1",
        },
        {
            "series": 'cnpg_collector_collection_duration_seconds{job="monitoring/cnpg-instances",namespace="database",cluster="fixture",pod="fixture-1",instance="fixture:9187"}',
            "values": "0.1 0.1 stale 0.1",
        },
        {
            "series": 'cnpg_collector_last_collection_error{namespace="database",cluster="fixture",pod="fixture-1"}',
            "values": "0 1 stale 0",
        },
        {
            "series": 'cnpg_pg_replication_lag{namespace="database",cluster="fixture",pod="fixture-1"}',
            "values": "5 400 stale 5",
        },
        {
            "series": 'envoy_server_live{namespace="network",pod="envoy-fixture"}',
            "values": "1 0 stale 1",
        },
        {
            "series": 'certmanager_certificate_expiration_timestamp_seconds{namespace="network",name="fixture-cert"}',
            "values": "864000 86460 stale 2592180",
        },
    ]

    tests = []
    tests += expression_case(query(panels, "Collection state"), "{}", [0, 2, 3, 0])
    tests += expression_case(query(panels, "Discovery state"), "{}", [0, 0, 3, 0])
    tests += expression_case(query(panels, "Metric evidence state"), "{}", [0, 0, 3, 0])
    tests += expression_case(query(panels, "Active platform alerts"), "{}", [0, 0, -1, 0])
    tests += expression_case(
        query(panels, "Node readiness"),
        '{__name__="kube_node_status_condition",condition="Ready",node="ms01-a",status="true"}',
        [1, 0, None, 1],
    )
    tests += expression_case(
        query(panels, "Node CPU busy"),
        '{instance="ms01-a:9100"}',
        [None, None, None, 70],
    )
    tests += expression_case(
        query(panels, "Node memory available"),
        '{instance="ms01-a:9100",job="node-exporter",namespace="monitoring",pod="node-exporter-ms01-a"}',
        [80, None, None, 80],
    )
    tests += expression_case(
        query(panels, "Node filesystem free"),
        '{fstype="ext4",instance="ms01-a:9100",mountpoint="/var"}',
        [80, 10, None, 80],
    )
    tests += expression_case(
        query(panels, "Longhorn volume robustness"),
        '{__name__="longhorn_volume_robustness",state="faulted",volume="pvc-fixture"}',
        [0, 1, None, 0],
    )
    tests += expression_case(
        query(panels, "Per-volume backup freshness"),
        '{pvc="fixture",pvc_namespace="monitoring",volume="pvc-fixture"}',
        [0, 48, None, 0],
    )
    tests += expression_case(
        query(panels, "Backup execution state"),
        '{__name__="longhorn_backup_state",backup="backup-fixture",volume="pvc-fixture"}',
        [1, 4, None, 1],
    )
    tests += expression_case(
        query(panels, "CNPG collector state"),
        '{__name__="cnpg_collector_last_collection_error",cluster="fixture",namespace="database",pod="fixture-1"}',
        [0, 1, None, 0],
    )
    tests += expression_case(
        query(panels, "CNPG replication lag"),
        '{__name__="cnpg_pg_replication_lag",cluster="fixture",namespace="database",pod="fixture-1"}',
        [5, 400, None, 5],
    )
    tests += expression_case(
        query(panels, "Gateway live state"),
        '{__name__="envoy_server_live",namespace="network",pod="envoy-fixture"}',
        [1, 0, None, 1],
    )
    tests += expression_case(
        query(panels, "Certificate lifetime remaining"),
        '{name="fixture-cert",namespace="network"}',
        [10, 1, None, 30],
    )
    tests += expression_case(
        query(panels, "Required targets"),
        '{__name__="up",instance="ms01-a:9100",job="node-exporter",namespace="monitoring",pod="node-exporter-ms01-a"}',
        [1, 0, None, 1],
    )

    partial_series = [
        {
            "series": 'up{job="node-exporter",namespace="monitoring",pod="node-partial",instance="node-partial:9100"}',
            "values": "1 1 1 1",
        },
        {
            "series": 'node_uname_info{job="node-exporter",namespace="monitoring",pod="node-partial",instance="node-partial:9100"}',
            "values": "1 stale 1 1",
        },
        {
            "series": 'node_uname_info{job="node-exporter",namespace="monitoring",pod="node-peer",instance="node-peer:9100"}',
            "values": "1 1 1 1",
        },
        {
            "series": 'node_cpu_seconds_total{job="node-exporter",namespace="monitoring",pod="node-partial",instance="node-partial:9100",mode="idle",cpu="0"}',
            "values": "0 60 stale 180",
        },
        {
            "series": 'node_cpu_seconds_total{job="node-exporter",namespace="monitoring",pod="node-peer",instance="node-peer:9100",mode="idle",cpu="0"}',
            "values": "0 60 120 180",
        },
        {
            "series": 'node_memory_MemAvailable_bytes{job="node-exporter",namespace="monitoring",pod="node-partial",instance="node-partial:9100"}',
            "values": "1 stale 1 1",
        },
        {
            "series": 'node_memory_MemAvailable_bytes{job="node-exporter",namespace="monitoring",pod="node-peer",instance="node-peer:9100"}',
            "values": "1 1 1 1",
        },
        {
            "series": 'node_memory_MemTotal_bytes{job="node-exporter",namespace="monitoring",pod="node-partial",instance="node-partial:9100"}',
            "values": "100 100 100 100",
        },
        {
            "series": 'node_memory_MemTotal_bytes{job="node-exporter",namespace="monitoring",pod="node-peer",instance="node-peer:9100"}',
            "values": "100 100 100 100",
        },
        {
            "series": 'kube_node_status_condition{node="node-peer",condition="Ready",status="true"}',
            "values": "1 1 1 1",
        },
        {
            "series": 'longhorn_volume_capacity_bytes{volume="volume-partial"}',
            "values": "100 100 100 100",
        },
        {
            "series": 'longhorn_volume_last_backup_at{volume="volume-partial"}',
            "values": "1 1 stale 1",
        },
        {
            "series": 'longhorn_volume_last_backup_at{volume="volume-peer"}',
            "values": "1 1 1 1",
        },
        {
            "series": 'up{job="monitoring/cnpg-instances",namespace="database",pod="cnpg-partial",instance="cnpg-partial:9187"}',
            "values": "1 1 1 1",
        },
        {
            "series": 'cnpg_collector_collection_duration_seconds{job="monitoring/cnpg-instances",namespace="database",pod="cnpg-partial",instance="cnpg-partial:9187"}',
            "values": "0.1 0.1 0.1 stale",
        },
        {
            "series": 'cnpg_collector_collection_duration_seconds{job="monitoring/cnpg-instances",namespace="database",pod="cnpg-peer",instance="cnpg-peer:9187"}',
            "values": "0.1 0.1 0.1 0.1",
        },
        {
            "series": 'envoy_server_live{namespace="network",pod="envoy-peer"}',
            "values": "1 1 1 1",
        },
        {
            "series": 'certmanager_certificate_expiration_timestamp_seconds{namespace="network",name="cert-peer"}',
            "values": "2592000 2592000 2592000 2592000",
        },
    ]
    partial_tests = expression_case(
        query(panels, "Metric evidence state"), "{}", [0, 2, 2, 2]
    )

    memtotal_series = [
        {
            "series": 'up{job="node-exporter",namespace="monitoring",pod="node-partial",instance="node-partial:9100"}',
            "values": "1 1",
        },
        {
            "series": 'up{job="node-exporter",namespace="monitoring",pod="node-peer",instance="node-peer:9100"}',
            "values": "1 1",
        },
        {
            "series": 'node_uname_info{job="node-exporter",namespace="monitoring",pod="node-partial",instance="node-partial:9100"}',
            "values": "1 1",
        },
        {
            "series": 'node_uname_info{job="node-exporter",namespace="monitoring",pod="node-peer",instance="node-peer:9100"}',
            "values": "1 1",
        },
        {
            "series": 'node_cpu_seconds_total{job="node-exporter",namespace="monitoring",pod="node-partial",instance="node-partial:9100",mode="idle",cpu="0"}',
            "values": "1 1",
        },
        {
            "series": 'node_cpu_seconds_total{job="node-exporter",namespace="monitoring",pod="node-peer",instance="node-peer:9100",mode="idle",cpu="0"}',
            "values": "1 1",
        },
        {
            "series": 'node_memory_MemAvailable_bytes{job="node-exporter",namespace="monitoring",pod="node-partial",instance="node-partial:9100"}',
            "values": "800 800",
        },
        {
            "series": 'node_memory_MemAvailable_bytes{job="node-exporter",namespace="monitoring",pod="node-peer",instance="node-peer:9100"}',
            "values": "800 800",
        },
        {
            "series": 'node_memory_MemTotal_bytes{job="node-exporter",namespace="monitoring",pod="node-partial",instance="node-partial:9100"}',
            "values": "1000 stale",
        },
        {
            "series": 'node_memory_MemTotal_bytes{job="node-exporter",namespace="monitoring",pod="node-peer",instance="node-peer:9100"}',
            "values": "1000 1000",
        },
        {
            "series": 'kube_node_status_condition{node="node-peer",condition="Ready",status="true"}',
            "values": "1 1",
        },
        {
            "series": 'longhorn_volume_capacity_bytes{volume="volume-peer"}',
            "values": "100 100",
        },
        {
            "series": 'longhorn_volume_last_backup_at{volume="volume-peer"}',
            "values": "1 1",
        },
        {
            "series": 'up{job="monitoring/cnpg-instances",namespace="database",pod="cnpg-peer",instance="cnpg-peer:9187"}',
            "values": "1 1",
        },
        {
            "series": 'cnpg_collector_collection_duration_seconds{job="monitoring/cnpg-instances",namespace="database",pod="cnpg-peer",instance="cnpg-peer:9187"}',
            "values": "0.1 0.1",
        },
        {
            "series": 'envoy_server_live{namespace="network",pod="envoy-peer"}',
            "values": "1 1",
        },
        {
            "series": 'certmanager_certificate_expiration_timestamp_seconds{namespace="network",name="cert-peer"}',
            "values": "2592000 2592000",
        },
    ]
    memtotal_tests = []
    def at(minute, samples):
        return {
            "eval_time": f"{minute}m",
            "exp_samples": [
                {"labels": labels, "value": value} for labels, value in samples
            ],
        }

    cpu = query(panels, "Node CPU busy")
    memory = query(panels, "Node memory available")
    cpu_a = '{instance="node-a:9100"}'
    cpu_b = '{instance="node-b:9100"}'
    mem_a = '{instance="node-a:9100",job="node-exporter",namespace="monitoring",pod="node-a"}'
    mem_b = '{instance="node-b:9100",job="node-exporter",namespace="monitoring",pod="node-b"}'
    mem_partial = '{instance="node-partial:9100",job="node-exporter",namespace="monitoring",pod="node-partial"}'
    mem_peer = '{instance="node-peer:9100",job="node-exporter",namespace="monitoring",pod="node-peer"}'
    steady = "0 54 108 162 216 270"
    busy = "0 6 12 18 24 30"
    # promtool preserves the binary rate result; 54 idle-seconds per minute is 10% busy.
    idle_busy = 9.999999999999998
    partial_window_busy = 27.999999999999993

    def pair(up_a, cpu_a_values, memtotal_a):
        return [
            {"series": 'up{job="node-exporter",namespace="monitoring",pod="node-a",instance="node-a:9100"}', "values": up_a},
            {"series": 'up{job="node-exporter",namespace="monitoring",pod="node-b",instance="node-b:9100"}', "values": "1 1 1 1 1 1"},
            {"series": 'node_cpu_seconds_total{job="node-exporter",namespace="monitoring",pod="node-a",instance="node-a:9100",mode="idle",cpu="0"}', "values": cpu_a_values},
            {"series": 'node_cpu_seconds_total{job="node-exporter",namespace="monitoring",pod="node-b",instance="node-b:9100",mode="idle",cpu="0"}', "values": steady},
            {"series": 'node_memory_MemAvailable_bytes{job="node-exporter",namespace="monitoring",pod="node-a",instance="node-a:9100"}', "values": "800 800 800 800 800 800"},
            {"series": 'node_memory_MemTotal_bytes{job="node-exporter",namespace="monitoring",pod="node-a",instance="node-a:9100"}', "values": memtotal_a},
            {"series": 'node_memory_MemAvailable_bytes{job="node-exporter",namespace="monitoring",pod="node-b",instance="node-b:9100"}', "values": "500 500 500 500 500 500"},
            {"series": 'node_memory_MemTotal_bytes{job="node-exporter",namespace="monitoring",pod="node-b",instance="node-b:9100"}', "values": "1000 1000 1000 1000 1000 1000"},
        ]

    node_cases = [
        {
            "name": "node cpu and memory normal with a healthy peer",
            "interval": "1m",
            "input_series": pair("1 1 1 1 1 1", steady, "1000 1000 1000 1000 1000 1000"),
            "promql_expr_test": [
                {"expr": cpu, **at(5, [(cpu_a, idle_busy), (cpu_b, idle_busy)])},
                {"expr": memory, **at(5, [(mem_a, 80), (mem_b, 50)])},
            ],
        },
        {
            "name": "high cpu on one node does not change its peer",
            "interval": "1m",
            "input_series": pair("1 1 1 1 1 1", busy, "1000 1000 1000 1000 1000 1000"),
            "promql_expr_test": [
                {"expr": cpu, **at(5, [(cpu_a, 90), (cpu_b, idle_busy)])},
            ],
        },
        {
            "name": "a down target is unknown while its cpu samples and peer remain",
            "interval": "1m",
            "input_series": pair("1 1 1 1 1 0", steady, "1000 1000 1000 1000 1000 1000"),
            "promql_expr_test": [
                {"expr": cpu, **at(5, [(cpu_b, idle_busy)])},
                {"expr": memory, **at(5, [(mem_b, 50)])},
            ],
        },
        {
            "name": "stale idle cpu is unknown even when the rate window and peer remain",
            "interval": "1m",
            "input_series": pair("1 1 1 1 1 1", "0 54 108 162 216 stale", "1000 1000 1000 1000 1000 1000"),
            "promql_expr_test": [
                {"expr": cpu, **at(5, [(cpu_b, idle_busy)])},
                {"expr": memory, **at(5, [(mem_a, 80), (mem_b, 50)])},
            ],
        },
        {
            "name": "current cpu sample restores the node view after a stale minute",
            "interval": "1m",
            "input_series": pair("1 1 1 1 1 1", "0 54 108 162 stale 270", "1000 1000 1000 1000 1000 1000"),
            "promql_expr_test": [
                {"expr": cpu, **at(4, [(cpu_b, partial_window_busy)])},
                {"expr": cpu, **at(5, [(cpu_a, idle_busy), (cpu_b, idle_busy)])},
            ],
        },
        {
            "name": "missing MemTotal is not hidden by a healthy peer",
            "interval": "1m",
            "input_series": memtotal_series,
            "promql_expr_test": expression_case(query(panels, "Metric evidence state"), "{}", [0, 2]) + [
                {"expr": memory, **at(0, [(mem_partial, 80), (mem_peer, 80)])},
                {"expr": memory, **at(1, [(mem_peer, 80)])},
            ],
        },
    ]

    definition = {
        "rule_files": [],
        "evaluation_interval": "1m",
        "tests": [
            {
                "name": "dashboard normal failure no-data and recovery states",
                "interval": "1m",
                "input_series": series,
                "promql_expr_test": tests,
            },
            {
                "name": "healthy peers do not hide per-target metric loss",
                "interval": "1m",
                "input_series": partial_series,
                "promql_expr_test": partial_tests,
            },
            *node_cases,
        ],
    }
    with tempfile.TemporaryDirectory() as directory:
        test_file = Path(directory) / "dashboard-promql-test.yaml"
        test_file.write_text(yaml.safe_dump(definition, sort_keys=False), encoding="utf-8")
        checked = run("promtool", "test", "rules", str(test_file))
        if "SUCCESS" not in checked.stdout + checked.stderr:
            raise AssertionError("promtool did not report dashboard query validation success")


def main():
    dashboard = json.loads(DASHBOARD.read_text(encoding="utf-8"))
    panels = panel_map(dashboard)
    validate_dashboard(dashboard, panels)
    validate_queries(panels)
    print(
        "observability dashboard passed: import artifact, real schema, normal/failure/no-data/recovery and partial-loss queries"
    )


if __name__ == "__main__":
    main()
