#!/usr/bin/env python3
"""Run a bounded Prometheus versus VictoriaMetrics compatibility benchmark."""

from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import csv
import datetime as dt
import hashlib
import http.client
import json
import math
import os
import pathlib
import platform
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
PLATFORM_RULES = ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/app/prometheusrule.yaml"
LONGHORN_RULES = ROOT / "wanxiang/kubernetes/apps/storage/longhorn/app/prometheusrule.yaml"
DASHBOARD = ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/dashboards/wanxiang-platform-overview.json"
PRIVATE_TEMPLATE_PATH = "wanxiang/kubernetes/apps/monitoring/alertmanager-config/app/alertmanagerconfig.yaml"
EXPECTED_ALERTS = {
    "missing": "WanxiangNodeExporterMetricMissing",
    "stale": "LonghornBackupStale",
    "fault": "WanxiangLonghornVolumeFaulted",
    "backup_failed": "LonghornBackupFailed",
}
ROLE_LABELS = {
    "node": {"job": "node-exporter", "namespace": "monitoring", "pod": "node-exporter-fixture"},
    "ksm": {"job": "kube-state-metrics", "namespace": "monitoring", "pod": "ksm-fixture"},
    "longhorn": {"job": "longhorn-backend", "namespace": "storage", "pod": "longhorn-manager-fixture"},
    "cnpg": {"job": "monitoring/cnpg-instances", "namespace": "database", "pod": "fixture-pg-1"},
    "cnpg-operator": {"job": "monitoring/cnpg-operator", "namespace": "database", "pod": "cnpg-operator-fixture"},
    "envoy": {"job": "network/envoy-proxy", "namespace": "network", "pod": "envoy-fixture"},
    "cert-manager": {"job": "cert-manager", "namespace": "cert-manager", "pod": "cert-manager-fixture"},
    "cainjector": {"job": "cainjector", "namespace": "cert-manager", "pod": "cainjector-fixture"},
    "webhook": {"job": "webhook", "namespace": "cert-manager", "pod": "webhook-fixture"},
    "synthetic": {"job": "synthetic-load", "namespace": "benchmark", "pod": "synthetic-fixture"},
}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def run(command: list[str], *, timeout: float = 30, check: bool = True) -> subprocess.CompletedProcess:
    environment = os.environ.copy()
    if command and command[0] == "git":
        environment.pop("GIT_CONFIG_COUNT", None)
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, env=environment)
    if check and result.returncode:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def binary_version(command: list[str]) -> str:
    result = run(command, check=False)
    output = (result.stdout + result.stderr).strip()
    return output.splitlines()[0] if output else f"exit={result.returncode}"


def directory_size(path: pathlib.Path) -> int:
    total = 0
    if not path.exists():
        return 0
    for entry in path.rglob("*"):
        with contextlib.suppress(FileNotFoundError):
            if entry.is_file() and not entry.is_symlink():
                total += entry.stat().st_size
    return total


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low = math.floor(position)
    high = math.ceil(position)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


class BenchmarkInterrupted(BaseException):
    """Raised in the main thread so process cleanup runs on TERM/INT."""


def handle_termination(signum, _frame):
    raise BenchmarkInterrupted(f"received signal {signal.Signals(signum).name}")


class PhaseClock:
    def __init__(self, fault_start: float, fault_end: float, outage_start: float, outage_end: float):
        self.started: float | None = None
        self.fault_start = fault_start
        self.fault_end = fault_end
        self.outage_start = outage_start
        self.outage_end = outage_end

    def elapsed(self) -> float:
        return 0.0 if self.started is None else time.monotonic() - self.started

    def phase(self) -> str:
        elapsed = self.elapsed()
        if self.started is not None and self.fault_start <= elapsed < self.fault_end:
            return "fault"
        return "normal"

    def remote_write_available(self) -> bool:
        elapsed = self.elapsed()
        return self.started is None or not (self.outage_start <= elapsed < self.outage_end)


class SyntheticExporter:
    def __init__(self, clock: PhaseClock, stable_series: int, churn_series: int, churn_interval: int):
        self.clock = clock
        self.stable_series = stable_series
        self.churn_series = churn_series
        self.churn_interval = churn_interval
        self.lock = threading.Lock()
        self.scrapes: dict[str, int] = {}
        self.bytes_served: dict[str, int] = {}

    def render(self, role: str, user_agent: str) -> bytes:
        with self.lock:
            lowered_agent = user_agent.lower()
            key = "vmagent" if "vm_promscrape" in lowered_agent or "victoriametrics" in lowered_agent else "prometheus"
            self.scrapes[key] = self.scrapes.get(key, 0) + 1
        elapsed = self.clock.elapsed()
        fault = self.clock.phase() == "fault"
        now = time.time()
        lines = ["# benchmark synthetic input; no production data"]
        if role == "synthetic":
            for index in range(self.stable_series):
                lines.append(f'synthetic_load_value{{series="stable-{index:05d}",kind="stable"}} {index % 101}')
            epoch = int(elapsed // self.churn_interval)
            for index in range(self.churn_series):
                lines.append(
                    f'synthetic_load_value{{series="churn-{index:05d}",kind="churn",churn_epoch="{epoch}"}} '
                    f'{(index + epoch) % 101}'
                )
                lines.append(
                    f'synthetic_monotonic_counter_total{{series="churn-{index:05d}",churn_epoch="{epoch}"}} '
                    f'{int(elapsed) + index}'
                )
        elif role == "node":
            if not fault:
                lines.append('node_uname_info{machine="x86_64",nodename="fixture-node"} 1')
            lines.extend([
                'node_filesystem_avail_bytes{fstype="ext4",mountpoint="/var"} 80000000000',
                'node_filesystem_size_bytes{fstype="ext4",mountpoint="/var"} 100000000000',
                'node_filesystem_readonly{fstype="ext4",mountpoint="/var"} 0',
            ])
        elif role == "ksm":
            lines.append('kube_node_status_condition{node="fixture-node",condition="Ready",status="true"} 1')
            ready = [
                ("monitoring", "node-exporter-fixture", "node-exporter"),
                ("storage", "longhorn-manager-fixture", "longhorn-manager"),
                ("database", "fixture-pg-1", "postgres"),
                ("database", "cnpg-operator-fixture", "manager"),
                ("network", "envoy-fixture", "envoy"),
                ("cert-manager", "cert-manager-fixture", "cert-manager-controller"),
                ("cert-manager", "cainjector-fixture", "cert-manager-cainjector"),
                ("cert-manager", "webhook-fixture", "cert-manager-webhook"),
            ]
            for namespace, pod, container in ready:
                lines.append(
                    f'kube_pod_container_status_ready{{namespace="{namespace}",pod="{pod}",'
                    f'container="{container}",uid="fixture-{pod}"}} 1'
                )
        elif role == "longhorn":
            backup_time = now - 259200 if fault else now - 3600
            lines.extend([
                'longhorn_volume_capacity_bytes{volume="fixture-volume",pvc="fixture",pvc_namespace="benchmark"} 10737418240',
                f'longhorn_volume_last_backup_at{{volume="fixture-volume",pvc="fixture",pvc_namespace="benchmark"}} {backup_time:.3f}',
                f'longhorn_backup_state{{volume="fixture-volume",backup="fixture-backup"}} {4 if fault else 1}',
                f'longhorn_volume_robustness{{volume="fixture-volume",state="faulted"}} {1 if fault else 0}',
            ])
        elif role == "cnpg":
            lines.extend([
                'cnpg_collector_collection_duration_seconds{cluster="fixture",instance="fixture"} 0.05',
                f'cnpg_collector_last_collection_error{{cluster="fixture"}} {1 if fault else 0}',
                f'cnpg_pg_replication_lag{{cluster="fixture"}} {400 if fault else 5}',
            ])
        elif role == "envoy":
            lines.append(f'envoy_server_live{{gateway="fixture"}} {0 if fault else 1}')
        elif role == "cert-manager":
            expiry = now + (86400 if fault else 2592000)
            lines.append(
                f'certmanager_certificate_expiration_timestamp_seconds{{name="fixture-cert",namespace="network"}} {expiry:.3f}'
            )
        else:
            lines.append(f'benchmark_role_alive{{role="{role}"}} 1')
        payload = ("\n".join(lines) + "\n").encode()
        with self.lock:
            self.bytes_served[key] = self.bytes_served.get(key, 0) + len(payload)
        return payload


class ExporterHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        role = self.path.split("?", 1)[0].removeprefix("/metrics/")
        if role not in ROLE_LABELS:
            self.send_error(404)
            return
        payload = self.server.exporter.render(role, self.headers.get("User-Agent", ""))
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        return


class RemoteWriteProxyHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        elapsed = self.server.clock.elapsed()
        if not self.server.clock.remote_write_available():
            with self.server.lock:
                self.server.rejected += 1
                self.server.rejected_bytes += len(body)
            self.send_response(503)
            self.end_headers()
            return
        connection = http.client.HTTPConnection("127.0.0.1", self.server.target_port, timeout=10)
        headers = {
            key: value for key, value in self.headers.items()
            if key.lower() in {"content-type", "content-encoding", "x-prometheus-remote-write-version", "user-agent"}
        }
        try:
            connection.request("POST", self.path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read()
            with self.server.lock:
                self.server.forwarded += 1
                self.server.forwarded_bytes += len(body)
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() in {"content-type", "content-encoding"}:
                    self.send_header(key, value)
            self.end_headers()
            self.wfile.write(payload)
        except Exception as error:
            with self.server.lock:
                self.server.errors.append({"elapsed": elapsed, "error": str(error)})
            self.send_response(502)
            self.end_headers()
        finally:
            connection.close()

    def log_message(self, *_args):
        return


class NotificationHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length))
        stack = self.path.strip("/") or "unknown"
        record = {
            "received_at": utc_now(),
            "elapsed_seconds": self.server.clock.elapsed(),
            "stack": stack,
            "payload": payload,
        }
        with self.server.lock:
            self.server.records.append(record)
        with self.server.output.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        self.send_response(200)
        self.end_headers()

    def log_message(self, *_args):
        return


@dataclass
class ManagedProcess:
    name: str
    stack: str
    process: subprocess.Popen
    log_handle: object
    data_path: pathlib.Path | None


class ProcessManager:
    def __init__(self, logs: pathlib.Path, cpus: dict[str, set[int]]):
        self.logs = logs
        self.cpus = cpus
        self.processes: list[ManagedProcess] = []

    def start(
        self,
        name: str,
        stack: str,
        command: list[str],
        data_path: pathlib.Path | None,
        memory_limit: str,
    ) -> ManagedProcess:
        log_handle = (self.logs / f"{name}.log").open("w", encoding="utf-8")
        cpus = self.cpus[stack]

        def configure_child():
            os.setsid()
            os.sched_setaffinity(0, cpus)

        environment = os.environ.copy()
        environment.update({"GOMAXPROCS": str(len(cpus)), "GOMEMLIMIT": memory_limit})
        process = subprocess.Popen(
            command,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            env=environment,
            preexec_fn=configure_child,
        )
        managed = ManagedProcess(name, stack, process, log_handle, data_path)
        self.processes.append(managed)
        return managed

    def assert_running(self):
        exited = [item for item in self.processes if item.process.poll() is not None]
        if exited:
            details = []
            for item in exited:
                item.log_handle.flush()
                log = (self.logs / f"{item.name}.log").read_text(encoding="utf-8", errors="replace")
                details.append(f"{item.name} exited {item.process.returncode}:\n{log[-4000:]}")
            raise RuntimeError("\n".join(details))

    def stop(self):
        for item in reversed(self.processes):
            if item.process.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(item.process.pid, signal.SIGTERM)
                with contextlib.suppress(subprocess.TimeoutExpired):
                    item.process.wait(timeout=3)
            if item.process.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(item.process.pid, signal.SIGKILL)
                item.process.wait()
            item.log_handle.close()


def process_usage(pid: int) -> tuple[float, int]:
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()
    ticks = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
    cpu = (int(stat[11]) + int(stat[12])) / ticks
    rss = 0
    for line in pathlib.Path(f"/proc/{pid}/status").read_text().splitlines():
        if line.startswith("VmRSS:"):
            rss = int(line.split()[1]) * 1024
            break
    return cpu, rss


def write_yaml(path: pathlib.Path, value):
    path.write_text(yaml.safe_dump(value, sort_keys=False), encoding="utf-8")


def load_rule_groups(hold: str) -> tuple[list[dict], list[dict]]:
    groups = []
    timing_changes = []
    for path in (PLATFORM_RULES, LONGHORN_RULES):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        for group in document["spec"]["groups"]:
            copied = json.loads(json.dumps(group))
            copied["interval"] = "5s"
            for rule in copied["rules"]:
                if "alert" in rule and rule.get("for") != hold:
                    timing_changes.append({
                        "alert": rule["alert"],
                        "source_for": rule.get("for", "0s"),
                        "benchmark_for": hold,
                    })
                    rule["for"] = hold
            groups.append(copied)
    return groups, timing_changes


def load_queries() -> list[dict]:
    dashboard = json.loads(DASHBOARD.read_text(encoding="utf-8"))
    queries = []
    for panel in dashboard["panels"]:
        targets = [target for target in panel.get("targets", []) if target.get("expr")]
        if len(targets) != 1:
            raise RuntimeError(f"panel {panel.get('title')} does not have exactly one expression")
        target = targets[0]
        queries.append({
            "panel": panel["title"],
            "expression": target["expr"],
            "query_type": "instant" if target.get("instant") is True else "range",
        })
    return queries


def load_private_template(repository: pathlib.Path, revision: str) -> tuple[dict, str]:
    result = run(["git", "-C", str(repository), "show", f"{revision}:{PRIVATE_TEMPLATE_PATH}"])
    content = result.stdout
    manifest = yaml.safe_load(content)
    metadata = manifest.get("metadata", {})
    if metadata.get("namespace") != "monitoring":
        raise RuntimeError("private AlertmanagerConfig escaped the monitoring namespace")
    if metadata.get("labels") != {"observability.beacoworks.xyz/alertmanager": "wanxiang"}:
        raise RuntimeError("private AlertmanagerConfig no longer matches the public selector")
    route = manifest["spec"]["route"]
    matchers = route.get("matchers")
    if not isinstance(matchers, list) or not matchers or any(
        set(matcher) != {"name", "matchType", "value"} or not all(matcher.values())
        for matcher in matchers
    ):
        raise RuntimeError("unexpected private notification matcher")
    webhook = manifest["spec"]["receivers"][0]["webhookConfigs"][0]
    url_secret = webhook.get("urlSecret", {})
    credentials = webhook.get("httpConfig", {}).get("authorization", {}).get("credentials", {})
    if set(url_secret) != {"name", "key"} or not all(url_secret.values()) or "url" in webhook:
        raise RuntimeError("private notification URL is not an isolated Secret reference")
    if set(credentials) != {"name", "key"} or not all(credentials.values()):
        raise RuntimeError("private notification token is not an isolated Secret reference")
    if webhook.get("sendResolved") is not True:
        raise RuntimeError("private notification template disabled resolved delivery")
    return manifest, hashlib.sha256(content.encode()).hexdigest()


def native_alertmanager_config(template: dict, webhook_url: str) -> dict:
    route = template["spec"]["route"]
    receiver = template["spec"]["receivers"][0]
    webhook = receiver["webhookConfigs"][0]
    matchers = [f'{item["name"]}{item["matchType"]}"{item["value"]}"' for item in route["matchers"]]
    return {
        "global": {"resolve_timeout": "15s"},
        "route": {
            "receiver": "null",
            "group_by": route["groupBy"],
            "group_wait": "0s",
            "group_interval": "1s",
            "repeat_interval": route["repeatInterval"],
            "routes": [{"receiver": route["receiver"], "matchers": matchers}],
        },
        "receivers": [
            {"name": "null"},
            {
                "name": receiver["name"],
                "webhook_configs": [{
                    "url": webhook_url,
                    "send_resolved": webhook["sendResolved"],
                    "timeout": webhook["timeout"],
                }],
            },
        ],
    }


def scrape_configs(exporter_port: int) -> list[dict]:
    configs = []
    for role, labels in ROLE_LABELS.items():
        target_labels = {key: value for key, value in labels.items() if key != "job"}
        config = {
            "job_name": labels["job"],
            "metrics_path": f"/metrics/{role}",
            "static_configs": [{"targets": [f"127.0.0.1:{exporter_port}"], "labels": target_labels}],
        }
        if role == "ksm":
            # Preserve the namespace/pod labels exported by kube-state-metrics;
            # otherwise Prometheus renames them to exported_* on collision with
            # this fixture target's own labels and creates false missing-target alerts.
            config["honor_labels"] = True
        configs.append(config)
    return configs


def wait_ready(url: str, managed: ManagedProcess, timeout: float = 20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if managed.process.poll() is not None:
            managed.log_handle.flush()
            log = pathlib.Path(managed.log_handle.name).read_text(encoding="utf-8", errors="replace")
            raise RuntimeError(f"{managed.name} exited during readiness:\n{log[-4000:]}")
        try:
            with urllib.request.urlopen(url, timeout=1) as response:
                if 200 <= response.status < 300:
                    return
        except (urllib.error.URLError, TimeoutError):
            time.sleep(0.2)
    raise RuntimeError(f"readiness timeout for {managed.name}: {url}")


def api_query(
    base_url: str,
    expression: str,
    *,
    evaluation_time: float | None = None,
    query_type: str = "instant",
    range_seconds: int = 300,
    step_seconds: int = 5,
) -> tuple[float, dict]:
    evaluation_time = evaluation_time if evaluation_time is not None else time.time()
    parameters: dict[str, str | float | int] = {"query": expression}
    if query_type == "range":
        endpoint = "query_range"
        parameters.update({
            "start": evaluation_time - range_seconds,
            "end": evaluation_time,
            "step": step_seconds,
        })
    elif query_type == "instant":
        endpoint = "query"
        parameters["time"] = evaluation_time
    else:
        raise ValueError(f"unsupported query type: {query_type}")
    url = f"{base_url}/api/v1/{endpoint}?{urllib.parse.urlencode(parameters)}"
    started = time.perf_counter()
    with urllib.request.urlopen(url, timeout=15) as response:
        payload = json.load(response)
    latency = (time.perf_counter() - started) * 1000
    if payload.get("status") != "success":
        raise RuntimeError(f"query failed: {payload}")
    return latency, payload


def normalized_result(payload: dict) -> list[dict]:
    result = payload.get("data", {}).get("result", [])
    normalized = []
    for item in result:
        normalized_item = {"metric": item.get("metric", {})}
        if "value" in item:
            normalized_item["value"] = item["value"]
        elif "values" in item:
            normalized_item["values"] = item["values"]
        else:
            normalized_item["value"] = [None, None]
        normalized.append(normalized_item)
    return sorted(normalized, key=lambda item: json.dumps(item["metric"], sort_keys=True))


def scalar_result(check: dict) -> float | None:
    result = check.get("result", [])
    if len(result) != 1:
        return None
    value = result[0].get("value", [None, None])
    try:
        return float(value[1])
    except (IndexError, TypeError, ValueError):
        return None


def fetch_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=5) as response:
        return json.load(response)


def fetch_text(url: str) -> str:
    with urllib.request.urlopen(url, timeout=5) as response:
        return response.read().decode()


def metric_value(text: str, prefix: str) -> float | None:
    values = []
    for line in text.splitlines():
        if line.startswith(prefix) and not line.startswith("#"):
            with contextlib.suppress(ValueError, IndexError):
                values.append(float(line.rsplit(" ", 1)[1]))
    return sum(values) if values else None


def allowed_cpus() -> list[int]:
    return sorted(os.sched_getaffinity(0))


def cpu_sets() -> dict[str, set[int]]:
    cpus = allowed_cpus()
    if len(cpus) < 2:
        raise RuntimeError("benchmark needs at least two allowed CPUs")
    if len(cpus) >= 4:
        return {"prometheus": set(cpus[:2]), "victoriametrics": set(cpus[2:4])}
    return {"prometheus": set(cpus[:2]), "victoriametrics": set(cpus[:2])}


def host_metadata() -> dict:
    model = "unknown"
    with contextlib.suppress(OSError):
        for line in pathlib.Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                model = line.split(":", 1)[1].strip()
                break
    mem_total = 0
    for line in pathlib.Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemTotal:"):
            mem_total = int(line.split()[1]) * 1024
            break
    return {
        "kernel": platform.release(),
        "architecture": platform.machine(),
        "cpu_model": model,
        "allowed_cpus": allowed_cpus(),
        "host_memory_bytes": mem_total,
        "cgroup_memory_max": pathlib.Path("/sys/fs/cgroup/memory.max").read_text().strip(),
        "filesystem": run(["df", "--output=fstype,size,avail", str(ROOT)]).stdout.splitlines()[-1].split(),
    }


def sanitize_artifacts(
    output: pathlib.Path,
    private_repository: pathlib.Path,
    private_runtime: pathlib.Path,
    private_receiver: str | None,
    private_match_values: list[str],
):
    replacements = [
        (str(private_repository), "<private-repo>"),
        (str(private_runtime), "<private-runtime>"),
        (str(ROOT), "<repo>"),
        (socket.gethostname(), "<benchmark-host>"),
    ]
    if private_receiver:
        replacements.append((private_receiver, "<isolated-receiver>"))
    replacements.extend((value, "<isolated-match>") for value in private_match_values)
    for path in output.rglob("*"):
        if not path.is_file():
            continue
        with contextlib.suppress(UnicodeDecodeError):
            content = path.read_text(encoding="utf-8")
            sanitized = content
            for source, replacement in replacements:
                sanitized = sanitized.replace(source, replacement)
            if sanitized != content:
                path.write_text(sanitized, encoding="utf-8")


def redact_notification_route(path: pathlib.Path):
    redacted = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            # A signal may interrupt the JSONL append. Discard an incomplete
            # notification rather than retaining private route fragments.
            continue
        payload = record.get("payload", {})
        payload["groupKey"] = "<isolated-route>"
        payload["groupLabels"] = {}
        redacted.append(json.dumps(record, sort_keys=True))
    path.write_text("\n".join(redacted) + "\n", encoding="utf-8")


def sanitize_output(
    output: pathlib.Path,
    private_repository: pathlib.Path,
    private_runtime: pathlib.Path,
    private_receiver: str | None,
    private_match_values: list[str],
):
    with contextlib.suppress(FileNotFoundError):
        redact_notification_route(output / "raw/notifications.jsonl")
    sanitize_artifacts(
        output,
        private_repository,
        private_runtime,
        private_receiver,
        private_match_values,
    )


def remove_private_runtime_state(output: pathlib.Path):
    # Alertmanager's binary nflog embeds route matchers/group keys. Keep other
    # failed-run backend data for diagnosis, but never retain this derived
    # private routing state in the public result tree.
    for relative in (
        "data/prometheus-alertmanager",
        "data/victoriametrics-alertmanager",
    ):
        shutil.rmtree(output / relative, ignore_errors=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=int, default=300)
    parser.add_argument("--fault-start", type=int, default=75)
    parser.add_argument("--fault-end", type=int, default=165)
    parser.add_argument("--outage-start", type=int, default=190)
    parser.add_argument("--outage-end", type=int, default=210)
    parser.add_argument("--stable-series", type=int, default=5000)
    parser.add_argument("--churn-series", type=int, default=1000)
    parser.add_argument("--churn-interval", type=int, default=30)
    parser.add_argument("--query-interval", type=int, default=10)
    parser.add_argument("--alert-hold", default="15s")
    parser.add_argument("--max-rss-bytes", type=int, default=1610612736)
    parser.add_argument("--max-disk-bytes", type=int, default=2147483648)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--private-repo", type=pathlib.Path, required=True)
    parser.add_argument("--private-ref", required=True)
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    if not 120 <= args.duration <= 3540:
        parser.error("duration must be between 120 and 3540 seconds")
    if min(
        args.stable_series,
        args.churn_series,
        args.churn_interval,
        args.query_interval,
        args.max_rss_bytes,
        args.max_disk_bytes,
    ) <= 0:
        parser.error("series, interval, and resource-budget arguments must be positive")
    if not (60 <= args.fault_start < args.fault_end < args.outage_start < args.outage_end < args.duration - 30):
        parser.error("phase boundaries must leave a 60s warmup, fault, recovery, outage, and final drain windows")
    return args


def run_benchmark(args: argparse.Namespace, private_runtime: pathlib.Path) -> int:
    output = args.output.resolve()
    raw = output / "raw"
    configs = output / "configs"
    logs = output / "logs"
    data = output / "data"
    for directory in (raw, configs, logs, data):
        directory.mkdir()

    started_at = utc_now()
    groups, timing_changes = load_rule_groups(args.alert_hold)
    rules_path = configs / "rules.yaml"
    write_yaml(rules_path, {"groups": groups})
    queries = load_queries()
    template, template_hash = load_private_template(args.private_repo.resolve(), args.private_ref)
    rate_expressions = [
        {"kind": "dashboard", **query}
        for query in queries if re.search(r"\b(?:rate|irate|increase)\s*\(", query["expression"])
    ]
    for group in groups:
        for rule in group["rules"]:
            if re.search(r"\b(?:rate|irate|increase)\s*\(", rule.get("expr", "")):
                rate_expressions.append({"kind": "rule", "name": rule.get("alert", rule.get("record")), "expression": rule["expr"]})

    validation = {
        "promtool": run(["promtool", "check", "rules", str(rules_path)], check=False).__dict__,
        "vmalert": run(["vmalert", f"-rule={rules_path}", "-dryRun"], check=False).__dict__,
    }
    validation_slim = {
        name: {"returncode": result["returncode"], "stdout": result["stdout"], "stderr": result["stderr"]}
        for name, result in validation.items()
    }
    (output / "rule-validation.json").write_text(json.dumps(validation_slim, indent=2), encoding="utf-8")
    if any(item["returncode"] for item in validation_slim.values()):
        raise RuntimeError(f"rule validation failed: {validation_slim}")
    if args.validate_only:
        print(json.dumps({"rules": sum(len(group["rules"]) for group in groups), "queries": len(queries), "rate_expressions": len(rate_expressions)}))
        shutil.rmtree(data)
        return 0

    ports = {name: free_port() for name in (
        "exporter", "proxy", "notifications", "prometheus", "prom-am", "vmsingle", "vmagent", "vmalert", "vm-am"
    )}
    clock = PhaseClock(args.fault_start, args.fault_end, args.outage_start, args.outage_end)
    exporter = SyntheticExporter(clock, args.stable_series, args.churn_series, args.churn_interval)

    exporter_server = ThreadingHTTPServer(("127.0.0.1", ports["exporter"]), ExporterHandler)
    exporter_server.exporter = exporter
    proxy_server = ThreadingHTTPServer(("127.0.0.1", ports["proxy"]), RemoteWriteProxyHandler)
    proxy_server.clock = clock
    proxy_server.target_port = ports["vmsingle"]
    proxy_server.lock = threading.Lock()
    proxy_server.rejected = 0
    proxy_server.rejected_bytes = 0
    proxy_server.forwarded = 0
    proxy_server.forwarded_bytes = 0
    proxy_server.errors = []
    notification_server = ThreadingHTTPServer(("127.0.0.1", ports["notifications"]), NotificationHandler)
    notification_server.clock = clock
    notification_server.lock = threading.Lock()
    notification_server.records = []
    notification_server.output = raw / "notifications.jsonl"
    servers = [exporter_server, proxy_server, notification_server]
    server_threads = []
    for server in servers:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        server_threads.append(thread)

    prom_am_config = private_runtime / "prometheus-alertmanager.yaml"
    vm_am_config = private_runtime / "victoriametrics-alertmanager.yaml"
    write_yaml(prom_am_config, native_alertmanager_config(template, f"http://127.0.0.1:{ports['notifications']}/prometheus"))
    write_yaml(vm_am_config, native_alertmanager_config(template, f"http://127.0.0.1:{ports['notifications']}/victoriametrics"))
    scrapes = scrape_configs(ports["exporter"])
    prometheus_config = configs / "prometheus.yaml"
    write_yaml(prometheus_config, {
        "global": {"scrape_interval": "5s", "scrape_timeout": "4s", "evaluation_interval": "5s"},
        "rule_files": [str(rules_path)],
        "alerting": {"alertmanagers": [{"static_configs": [{"targets": [f"127.0.0.1:{ports['prom-am']}"]}]}]},
        "scrape_configs": scrapes,
    })
    vmagent_config = configs / "vmagent.yaml"
    write_yaml(vmagent_config, {"global": {"scrape_interval": "5s", "scrape_timeout": "4s"}, "scrape_configs": scrapes})

    subprocess_validation = {
        "prometheus_config": run(["promtool", "check", "config", str(prometheus_config)], check=False),
        "prometheus_alertmanager": run(["amtool", "check-config", str(prom_am_config)], check=False),
        "victoriametrics_alertmanager": run(["amtool", "check-config", str(vm_am_config)], check=False),
        "vmagent_config": run(["vmagent", f"-promscrape.config={vmagent_config}", "-promscrape.config.dryRun", "-loggerLevel=ERROR"], check=False),
    }
    config_validation = {
        name: {"returncode": item.returncode, "stdout": item.stdout, "stderr": item.stderr}
        for name, item in subprocess_validation.items()
    }
    (output / "config-validation.json").write_text(json.dumps(config_validation, indent=2), encoding="utf-8")
    if any(item["returncode"] for item in config_validation.values()):
        raise RuntimeError(f"configuration validation failed: {config_validation}")

    stack_paths = {
        "prometheus": {
            "prometheus": data / "prometheus",
            "prometheus-alertmanager": data / "prometheus-alertmanager",
        },
        "victoriametrics": {
            "vmsingle": data / "vmsingle",
            "vmagent": data / "vmagent-queue",
            "vmalert": data / "vmalert-state",
            "victoriametrics-alertmanager": data / "victoriametrics-alertmanager",
        },
    }
    for paths in stack_paths.values():
        for path in paths.values():
            path.mkdir(parents=True)

    cpus = cpu_sets()
    manager = ProcessManager(logs, cpus)
    resource_rows: list[dict] = []
    query_rows: list[dict] = []
    query_raw = raw / "queries.jsonl"
    alert_raw = raw / "alerts-timeline.jsonl"
    snapshots = {}
    final_checks = {}
    budget_violation = None
    result = "failed"
    try:
        prom_am = manager.start("prometheus-alertmanager", "prometheus", [
            "alertmanager", f"--config.file={prom_am_config}",
            f"--storage.path={stack_paths['prometheus']['prometheus-alertmanager']}",
            f"--web.listen-address=127.0.0.1:{ports['prom-am']}", "--cluster.listen-address=",
        ], stack_paths["prometheus"]["prometheus-alertmanager"], "192MiB")
        vm_am = manager.start("victoriametrics-alertmanager", "victoriametrics", [
            "alertmanager", f"--config.file={vm_am_config}",
            f"--storage.path={stack_paths['victoriametrics']['victoriametrics-alertmanager']}",
            f"--web.listen-address=127.0.0.1:{ports['vm-am']}", "--cluster.listen-address=",
        ], stack_paths["victoriametrics"]["victoriametrics-alertmanager"], "192MiB")
        vmsingle = manager.start("vmsingle", "victoriametrics", [
            "victoria-metrics", f"-storageDataPath={stack_paths['victoriametrics']['vmsingle']}",
            f"-httpListenAddr=127.0.0.1:{ports['vmsingle']}", "-retentionPeriod=1d",
            "-memory.allowedBytes=700MiB", "-loggerLevel=INFO",
        ], stack_paths["victoriametrics"]["vmsingle"], "768MiB")
        wait_ready(f"http://127.0.0.1:{ports['prom-am']}/-/ready", prom_am)
        wait_ready(f"http://127.0.0.1:{ports['vm-am']}/-/ready", vm_am)
        wait_ready(f"http://127.0.0.1:{ports['vmsingle']}/health", vmsingle)

        prometheus = manager.start("prometheus", "prometheus", [
            "prometheus", f"--config.file={prometheus_config}",
            f"--storage.tsdb.path={stack_paths['prometheus']['prometheus']}",
            f"--web.listen-address=127.0.0.1:{ports['prometheus']}",
            "--storage.tsdb.retention.time=1d", "--storage.tsdb.retention.size=2GB",
            "--storage.tsdb.wal-compression", "--query.lookback-delta=30s",
        ], stack_paths["prometheus"]["prometheus"], "1200MiB")
        vmagent = manager.start("vmagent", "victoriametrics", [
            "vmagent", f"-promscrape.config={vmagent_config}",
            f"-remoteWrite.url=http://127.0.0.1:{ports['proxy']}/api/v1/write",
            f"-remoteWrite.tmpDataPath={stack_paths['victoriametrics']['vmagent']}",
            "-remoteWrite.maxDiskUsagePerURL=512MB", "-remoteWrite.retryMinInterval=1s",
            "-remoteWrite.retryMaxInterval=5s", "-remoteWrite.flushInterval=1s",
            "-remoteWrite.queues=2", f"-httpListenAddr=127.0.0.1:{ports['vmagent']}",
            "-memory.allowedBytes=256MiB",
        ], stack_paths["victoriametrics"]["vmagent"], "320MiB")
        vmalert = manager.start("vmalert", "victoriametrics", [
            "vmalert", f"-rule={rules_path}", f"-datasource.url=http://127.0.0.1:{ports['vmsingle']}",
            "-datasource.queryStep=5s", f"-notifier.url=http://127.0.0.1:{ports['vm-am']}",
            f"-remoteWrite.url=http://127.0.0.1:{ports['vmsingle']}", "-evaluationInterval=5s",
            f"-httpListenAddr=127.0.0.1:{ports['vmalert']}",
        ], stack_paths["victoriametrics"]["vmalert"], "256MiB")
        wait_ready(f"http://127.0.0.1:{ports['prometheus']}/-/ready", prometheus)
        wait_ready(f"http://127.0.0.1:{ports['vmagent']}/health", vmagent)
        wait_ready(f"http://127.0.0.1:{ports['vmalert']}/health", vmalert)

        clock.started = time.monotonic()
        bases = {
            "prometheus": f"http://127.0.0.1:{ports['prometheus']}",
            "victoriametrics": f"http://127.0.0.1:{ports['vmsingle']}",
        }
        next_query = 5.0
        next_alert = 5.0
        snapshot_times = {
            "normal": max(30, args.fault_start - 10),
            "fault": args.fault_end - 10,
            "recovered": args.outage_start - 10,
            "queue_outage": args.outage_start + 5,
            "queue_drained": args.outage_end + 20,
        }
        taken_snapshots = set()
        while clock.elapsed() < args.duration:
            loop_started = time.monotonic()
            elapsed = clock.elapsed()
            manager.assert_running()

            stack_totals = {stack: {"cpu": 0.0, "rss": 0, "disk": 0} for stack in stack_paths}
            for item in manager.processes:
                cpu, rss = process_usage(item.process.pid)
                disk = directory_size(item.data_path) if item.data_path else 0
                resource_rows.append({
                    "elapsed_seconds": round(elapsed, 3), "stack": item.stack, "component": item.name,
                    "cpu_seconds": cpu, "rss_bytes": rss, "disk_bytes": disk,
                })
                stack_totals[item.stack]["cpu"] += cpu
                stack_totals[item.stack]["rss"] += rss
                stack_totals[item.stack]["disk"] += disk
            for stack, values in stack_totals.items():
                resource_rows.append({
                    "elapsed_seconds": round(elapsed, 3), "stack": stack, "component": "TOTAL",
                    "cpu_seconds": values["cpu"], "rss_bytes": values["rss"], "disk_bytes": values["disk"],
                })
                if values["rss"] > args.max_rss_bytes:
                    budget_violation = f"{stack} RSS {values['rss']} exceeded {args.max_rss_bytes}"
                if values["disk"] > args.max_disk_bytes:
                    budget_violation = f"{stack} disk {values['disk']} exceeded {args.max_disk_bytes}"
            if budget_violation:
                raise RuntimeError(budget_violation)

            if elapsed >= next_query:
                cycle = int(next_query // args.query_interval)
                query_evaluation_time = math.floor(time.time() / 5) * 5
                with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                    for query in queries:
                        futures = {
                            stack: pool.submit(
                                api_query,
                                base,
                                query["expression"],
                                evaluation_time=query_evaluation_time,
                                query_type=query["query_type"],
                            )
                            for stack, base in bases.items()
                        }
                        for stack, future in futures.items():
                            try:
                                latency, payload = future.result()
                                normalized = normalized_result(payload)
                                record = {
                                    "timestamp": utc_now(), "elapsed_seconds": elapsed, "cycle": cycle,
                                    "phase": clock.phase(), "stack": stack, "panel": query["panel"],
                                    "expression": query["expression"], "query_type": query["query_type"],
                                    "evaluation_time": query_evaluation_time, "latency_ms": latency,
                                    "success": True, "result_count": len(normalized), "result": normalized,
                                }
                            except Exception as error:
                                record = {
                                    "timestamp": utc_now(), "elapsed_seconds": elapsed, "cycle": cycle,
                                    "phase": clock.phase(), "stack": stack, "panel": query["panel"],
                                    "expression": query["expression"], "query_type": query["query_type"],
                                    "evaluation_time": query_evaluation_time, "latency_ms": None,
                                    "success": False, "result_count": 0, "error": str(error),
                                }
                            with query_raw.open("a", encoding="utf-8") as handle:
                                handle.write(json.dumps(record, sort_keys=True) + "\n")
                            query_rows.append({key: record.get(key) for key in (
                                "elapsed_seconds", "cycle", "phase", "stack", "panel", "query_type",
                                "evaluation_time", "latency_ms", "success", "result_count"
                            )})
                while next_query <= elapsed:
                    next_query += args.query_interval

            if elapsed >= next_alert:
                for stack, url in {
                    "prometheus": f"http://127.0.0.1:{ports['prometheus']}/api/v1/alerts",
                    "victoriametrics": f"http://127.0.0.1:{ports['vmalert']}/api/v1/alerts",
                }.items():
                    try:
                        payload = fetch_json(url)
                        record = {"elapsed_seconds": elapsed, "stack": stack, "payload": payload}
                    except Exception as error:
                        record = {"elapsed_seconds": elapsed, "stack": stack, "error": str(error)}
                    with alert_raw.open("a", encoding="utf-8") as handle:
                        handle.write(json.dumps(record, sort_keys=True) + "\n")
                while next_alert <= elapsed:
                    next_alert += 5

            for name, due in snapshot_times.items():
                if name not in taken_snapshots and elapsed >= due:
                    snapshot_evaluation_time = math.floor(time.time() / 5) * 5
                    snapshot = {
                        "elapsed_seconds": elapsed,
                        "phase": clock.phase(),
                        "evaluation_time": snapshot_evaluation_time,
                        "queries": {},
                    }
                    for query in queries:
                        snapshot["queries"][query["panel"]] = {}
                        for stack, base in bases.items():
                            try:
                                latency, payload = api_query(
                                    base,
                                    query["expression"],
                                    evaluation_time=snapshot_evaluation_time,
                                    query_type=query["query_type"],
                                )
                                snapshot["queries"][query["panel"]][stack] = {
                                    "query_type": query["query_type"],
                                    "latency_ms": latency,
                                    "result": normalized_result(payload),
                                }
                            except Exception as error:
                                snapshot["queries"][query["panel"]][stack] = {"error": str(error)}
                    snapshots[name] = snapshot
                    taken_snapshots.add(name)

            remaining = 1 - (time.monotonic() - loop_started)
            if remaining > 0:
                time.sleep(remaining)

        manager.assert_running()
        final_evaluation_time = math.floor((time.time() - 40) / 5) * 5
        final_expressions = {
            "active_series": "count(synthetic_load_value)",
            "samples_last_2m": "sum(count_over_time(synthetic_load_value[2m]))",
        }
        for stack, base in bases.items():
            final_checks[stack] = {}
            for name, expression in final_expressions.items():
                latency, payload = api_query(base, expression, evaluation_time=final_evaluation_time)
                final_checks[stack][name] = {
                    "latency_ms": latency,
                    "evaluation_time": final_evaluation_time,
                    "result": normalized_result(payload),
                }
        freshness_evaluation_time = time.time()
        for stack, base in bases.items():
            latency, payload = api_query(
                base,
                "max(timestamp(synthetic_load_value))",
                evaluation_time=freshness_evaluation_time,
            )
            check = {
                "latency_ms": latency,
                "evaluation_time": freshness_evaluation_time,
                "observed_wall_time": time.time(),
                "result": normalized_result(payload),
            }
            latest_timestamp = scalar_result(check)
            check["latest_sample_timestamp"] = latest_timestamp
            check["wall_clock_freshness_seconds"] = (
                check["observed_wall_time"] - latest_timestamp
                if latest_timestamp is not None else None
            )
            final_checks[stack]["freshness"] = check
        prometheus_metrics = fetch_text(f"http://127.0.0.1:{ports['prometheus']}/metrics")
        vmsingle_metrics = fetch_text(f"http://127.0.0.1:{ports['vmsingle']}/metrics")
        vmagent_metrics = fetch_text(f"http://127.0.0.1:{ports['vmagent']}/metrics")
        final_checks["engine_counters"] = {
            "prometheus_head_samples_appended_total": metric_value(
                prometheus_metrics, "prometheus_tsdb_head_samples_appended_total"
            ),
            "victoriametrics_rows_inserted_total": metric_value(vmsingle_metrics, "vm_rows_inserted_total"),
            "vmagent_rows_inserted_total": metric_value(vmagent_metrics, "vmagent_rows_inserted_total"),
            "vmagent_rows_pushed_total": metric_value(
                vmagent_metrics, "vmagent_remotewrite_rows_pushed_after_relabel_total"
            ),
            "vmagent_scraped_samples_total": metric_value(
                vmagent_metrics, "vm_promscrape_scraped_samples_sum"
            ),
            "vmagent_pending_data_bytes": metric_value(
                vmagent_metrics, "vmagent_remotewrite_pending_data_bytes"
            ),
            "vmagent_queue_bytes_written_total": metric_value(
                vmagent_metrics, "vm_persistentqueue_bytes_written_total"
            ),
            "vmagent_queue_bytes_read_total": metric_value(
                vmagent_metrics, "vm_persistentqueue_bytes_read_total"
            ),
            "vmagent_queue_bytes_dropped_total": metric_value(
                vmagent_metrics, "vm_persistentqueue_bytes_dropped_total"
            ),
        }
        result = "completed"
    finally:
        manager.stop()
        for server in servers:
            server.shutdown()
            server.server_close()
        for thread in server_threads:
            thread.join(timeout=2)

    resource_csv = raw / "resources.csv"
    with resource_csv.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "elapsed_seconds", "stack", "component", "cpu_seconds", "rss_bytes", "disk_bytes"
        ], lineterminator="\n")
        writer.writeheader()
        writer.writerows(resource_rows)
    query_csv = raw / "query-latency.csv"
    with query_csv.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "elapsed_seconds", "cycle", "phase", "stack", "panel", "query_type", "evaluation_time",
            "latency_ms", "success", "result_count"
        ], lineterminator="\n")
        writer.writeheader()
        writer.writerows(query_rows)
    (raw / "snapshots.json").write_text(json.dumps(snapshots, indent=2, sort_keys=True), encoding="utf-8")
    (output / "final-checks.json").write_text(json.dumps(final_checks, indent=2, sort_keys=True), encoding="utf-8")

    component_summary = []
    for stack in sorted({row["stack"] for row in resource_rows}):
        components = sorted({row["component"] for row in resource_rows if row["stack"] == stack})
        for component in components:
            rows = [row for row in resource_rows if row["stack"] == stack and row["component"] == component]
            elapsed_span = rows[-1]["elapsed_seconds"] - rows[0]["elapsed_seconds"]
            cpu_delta = rows[-1]["cpu_seconds"] - rows[0]["cpu_seconds"]
            cpu_peaks = []
            for previous, current in zip(rows, rows[1:]):
                interval = current["elapsed_seconds"] - previous["elapsed_seconds"]
                if interval > 0:
                    cpu_peaks.append((current["cpu_seconds"] - previous["cpu_seconds"]) / interval)
            component_summary.append({
                "stack": stack, "component": component,
                "cpu_average_cores": cpu_delta / elapsed_span if elapsed_span else 0,
                "cpu_peak_cores": max(cpu_peaks, default=0),
                "rss_average_bytes": statistics.fmean(row["rss_bytes"] for row in rows),
                "rss_peak_bytes": max(row["rss_bytes"] for row in rows),
                "disk_initial_bytes": rows[0]["disk_bytes"],
                "disk_final_bytes": rows[-1]["disk_bytes"],
                "disk_peak_bytes": max(row["disk_bytes"] for row in rows),
                "disk_growth_bytes": rows[-1]["disk_bytes"] - rows[0]["disk_bytes"],
            })
    with (output / "resource-summary.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(component_summary[0]), lineterminator="\n")
        writer.writeheader()
        writer.writerows(component_summary)

    query_summary = []
    for stack in sorted({row["stack"] for row in query_rows}):
        successes = [float(row["latency_ms"]) for row in query_rows if row["stack"] == stack and row["success"]]
        failures = [row for row in query_rows if row["stack"] == stack and not row["success"]]
        query_summary.append({
            "stack": stack, "requests": len(successes) + len(failures), "failures": len(failures),
            "latency_mean_ms": statistics.fmean(successes), "latency_p50_ms": percentile(successes, 0.5),
            "latency_p95_ms": percentile(successes, 0.95), "latency_p99_ms": percentile(successes, 0.99),
            "latency_max_ms": max(successes),
        })
    with (output / "query-summary.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(query_summary[0]), lineterminator="\n")
        writer.writeheader()
        writer.writerows(query_summary)

    notifications = notification_server.records
    notification_matrix = {}
    for stack in ("prometheus", "victoriametrics"):
        notification_matrix[stack] = {}
        for category, alertname in EXPECTED_ALERTS.items():
            statuses = set()
            for record in notifications:
                if record["stack"] != stack:
                    continue
                payload = record["payload"]
                for alert in payload.get("alerts", []):
                    if alert.get("labels", {}).get("alertname") == alertname:
                        statuses.add(alert.get("status", payload.get("status")))
            notification_matrix[stack][category] = sorted(status for status in statuses if status)

    completeness = {}
    for stack in ("prometheus", "victoriametrics"):
        relevant = [row for row in query_rows if row["stack"] == stack and row["success"]]
        completeness[stack] = {
            "successful_dashboard_queries": len(relevant),
            "failed_dashboard_queries": len([
                row for row in query_rows if row["stack"] == stack and not row["success"]
            ]),
            "final": final_checks.get(stack, {}),
        }

    normal_window_firing = {"prometheus": set(), "victoriametrics": set()}
    healthy_window_polls = {
        stack: {
            "baseline": {"successful": 0, "errors": 0},
            "recovered": {"successful": 0, "errors": 0},
        }
        for stack in normal_window_firing
    }
    recovered_start = max(args.fault_end + 60, args.outage_end + 30)
    for record in (
        json.loads(line) for line in alert_raw.read_text(encoding="utf-8").splitlines() if line
    ):
        elapsed = record["elapsed_seconds"]
        # vmalert intentionally evaluates 30s behind wall time. Its startup
        # missing-data alerts can therefore persist through the 15s test hold;
        # begin the healthy baseline only after that 45s warmup.
        window = None
        if 45 <= elapsed < args.fault_start:
            window = "baseline"
        elif recovered_start <= elapsed < args.duration:
            window = "recovered"
        stack = record.get("stack")
        if window is None or stack not in normal_window_firing:
            continue
        if "error" in record or record.get("payload", {}).get("status") != "success":
            healthy_window_polls[stack][window]["errors"] += 1
            continue
        healthy_window_polls[stack][window]["successful"] += 1
        for alert in record.get("payload", {}).get("data", {}).get("alerts", []):
            if alert.get("state") == "firing":
                normal_window_firing[stack].add(alert.get("labels", {}).get("alertname", "<unnamed>"))

    semantic_differences = []
    for snapshot_name, snapshot in snapshots.items():
        for panel, stacks in snapshot["queries"].items():
            left = stacks.get("prometheus", {})
            right = stacks.get("victoriametrics", {})
            if "result" not in left or "result" not in right:
                semantic_differences.append({"snapshot": snapshot_name, "panel": panel, "reason": "query_error"})
                continue
            left_result = left["result"]
            right_result = right["result"]
            if len(left_result) != len(right_result):
                semantic_differences.append({
                    "snapshot": snapshot_name, "panel": panel, "reason": "result_count",
                    "prometheus": len(left_result), "victoriametrics": len(right_result),
                })
                continue
            for left_item, right_item in zip(left_result, right_result):
                if left_item["metric"] != right_item["metric"]:
                    semantic_differences.append({
                        "snapshot": snapshot_name, "panel": panel, "reason": "labels",
                        "prometheus": left_item["metric"], "victoriametrics": right_item["metric"],
                    })
                    break
                result_key = "values" if "values" in left_item or "values" in right_item else "value"
                left_points = left_item.get(result_key, [])
                right_points = right_item.get(result_key, [])
                if result_key == "value":
                    left_points = [left_points]
                    right_points = [right_points]
                if len(left_points) != len(right_points):
                    semantic_differences.append({
                        "snapshot": snapshot_name, "panel": panel, "reason": "point_count",
                        "prometheus": len(left_points), "victoriametrics": len(right_points),
                    })
                    break
                for left_point, right_point in zip(left_points, right_points):
                    if len(left_point) != 2 or len(right_point) != 2:
                        semantic_differences.append({
                            "snapshot": snapshot_name, "panel": panel, "reason": "point_shape",
                        })
                        break
                    if not math.isclose(float(left_point[0]), float(right_point[0]), abs_tol=0.001):
                        semantic_differences.append({
                            "snapshot": snapshot_name, "panel": panel, "reason": "timestamp",
                            "prometheus": left_point[0], "victoriametrics": right_point[0],
                        })
                        break
                    try:
                        left_value = float(left_point[1])
                        right_value = float(right_point[1])
                    except (TypeError, ValueError):
                        values_equal = left_point[1] == right_point[1]
                        tolerance = None
                        compared_left = left_point[1]
                        compared_right = right_point[1]
                    else:
                        tolerance = max(0.05, abs(left_value) * 0.0001)
                        values_equal = math.isclose(
                            left_value, right_value, abs_tol=tolerance, rel_tol=0.0001
                        )
                        compared_left = left_value
                        compared_right = right_value
                    if not values_equal:
                        semantic_differences.append({
                            "snapshot": snapshot_name, "panel": panel, "reason": "value",
                            "prometheus": compared_left, "victoriametrics": compared_right,
                            "absolute_tolerance": tolerance,
                        })
                        break
                else:
                    continue
                break

    compatibility = {
        "result": result,
        "notification_matrix": notification_matrix,
        "all_required_notifications_observed": all(
            {"firing", "resolved"} <= set(statuses)
            for stack in notification_matrix.values() for statuses in stack.values()
        ),
        "dashboard_snapshot_shape_differences": semantic_differences,
        "normal_window_firing_alerts": {
            stack: sorted(names) for stack, names in normal_window_firing.items()
        },
        "healthy_window_alert_polls": healthy_window_polls,
        "rate_increase_expressions": rate_expressions,
        "queue_outage": {
            "window_seconds": [args.outage_start, args.outage_end],
            "rejected_requests": proxy_server.rejected,
            "rejected_bytes": proxy_server.rejected_bytes,
            "forwarded_requests": proxy_server.forwarded,
            "forwarded_bytes": proxy_server.forwarded_bytes,
            "proxy_errors": [item for item in proxy_server.errors if item["elapsed"] < args.duration],
            "cleanup_proxy_errors": [item for item in proxy_server.errors if item["elapsed"] >= args.duration],
            "queue_peak_bytes": max(
                (row["disk_bytes"] for row in resource_rows if row["component"] == "vmagent"), default=0
            ),
            "queue_final_bytes": next(
                (row["disk_bytes"] for row in reversed(resource_rows) if row["component"] == "vmagent"), 0
            ),
            "pending_data_bytes": final_checks.get("engine_counters", {}).get("vmagent_pending_data_bytes"),
        },
        "engine_counters": final_checks.get("engine_counters", {}),
        "final_data_equal": (
            final_checks.get("prometheus", {}).get("active_series", {}).get("result")
            == final_checks.get("victoriametrics", {}).get("active_series", {}).get("result")
            and final_checks.get("prometheus", {}).get("samples_last_2m", {}).get("result")
            == final_checks.get("victoriametrics", {}).get("samples_last_2m", {}).get("result")
        ),
        "completeness": completeness,
        "budget_violation": budget_violation,
    }
    counters = compatibility["engine_counters"]
    freshness = {
        stack: final_checks.get(stack, {}).get("freshness", {}).get("wall_clock_freshness_seconds")
        for stack in ("prometheus", "victoriametrics")
    }
    queue_outage = compatibility["queue_outage"]
    acceptance = {
        "run_completed": result == "completed",
        "resource_budgets_respected": budget_violation is None,
        "dashboard_queries_succeeded": all(
            item["failed_dashboard_queries"] == 0 and item["successful_dashboard_queries"] > 0
            for item in completeness.values()
        ),
        "final_data_equal_at_common_historical_time": compatibility["final_data_equal"],
        "freshness_within_documented_bounds": (
            freshness["prometheus"] is not None and freshness["prometheus"] <= 15
            and freshness["victoriametrics"] is not None and freshness["victoriametrics"] <= 45
        ),
        "required_notifications_observed": compatibility["all_required_notifications_observed"],
        "normal_windows_have_successful_error_free_polls_and_no_firing_alerts": (
            all(not names for names in normal_window_firing.values())
            and all(
                window["successful"] > 0 and window["errors"] == 0
                for stack in healthy_window_polls.values() for window in stack.values()
            )
        ),
        "queue_outage_exercised_and_replayed": (
            queue_outage["rejected_requests"] > 0
            and not queue_outage["proxy_errors"]
            and queue_outage["pending_data_bytes"] == 0
            and counters.get("vmagent_queue_bytes_written_total") is not None
            and counters.get("vmagent_queue_bytes_written_total") > 0
            and counters.get("vmagent_queue_bytes_written_total")
            == counters.get("vmagent_queue_bytes_read_total")
            and counters.get("vmagent_queue_bytes_dropped_total") == 0
        ),
    }
    compatibility["acceptance"] = acceptance
    result = "passed" if all(acceptance.values()) else "failed"
    compatibility["result"] = result
    (output / "compatibility.json").write_text(json.dumps(compatibility, indent=2, sort_keys=True), encoding="utf-8")

    metadata = {
        "result": result, "started_at": started_at, "finished_at": utc_now(),
        "source": {
            "public_commit": run(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).stdout.strip(),
            "platform_rules": str(PLATFORM_RULES.relative_to(ROOT)),
            "longhorn_rules": str(LONGHORN_RULES.relative_to(ROOT)),
            "dashboard": str(DASHBOARD.relative_to(ROOT)),
            "private_commit": args.private_ref,
            "private_template_path": PRIVATE_TEMPLATE_PATH,
            "private_template_sha256": template_hash,
        },
        "versions": {
            "prometheus": binary_version(["prometheus", "--version"]),
            "alertmanager": binary_version(["alertmanager", "--version"]),
            "victoriametrics": binary_version(["victoria-metrics", "--version"]),
            "vmagent": binary_version(["vmagent", "--version"]),
            "vmalert": binary_version(["vmalert", "--version"]),
        },
        "host": host_metadata(),
        "workload": {
            "duration_seconds": args.duration, "scrape_interval_seconds": 5, "evaluation_interval_seconds": 5,
            "retention": "1d", "stable_series": args.stable_series, "churn_series": args.churn_series,
            "churn_interval_seconds": args.churn_interval, "query_interval_seconds": args.query_interval,
            "dashboard_query_count": len(queries), "fault_window_seconds": [args.fault_start, args.fault_end],
            "dashboard_query_modes": {
                mode: sum(query["query_type"] == mode for query in queries)
                for mode in ("instant", "range")
            },
            "queue_outage_window_seconds": [args.outage_start, args.outage_end],
            "exporter_scrapes": exporter.scrapes, "exporter_bytes": exporter.bytes_served,
        },
        "budgets": {
            "cpu_affinity": {stack: sorted(values) for stack, values in cpus.items()},
            "cpu_cores_per_stack": 2, "rss_bytes_per_stack": args.max_rss_bytes,
            "disk_bytes_per_stack": args.max_disk_bytes, "wall_time_seconds": 3600,
        },
        "controlled_deviations": {
            "rule_timing": timing_changes,
            "notification_timing": {
                "source_timing": "validated from the private template and intentionally not reproduced here",
                "benchmark_group_wait": "0s",
                "benchmark_group_interval": "1s",
            },
        },
        "cleanup": {"child_processes_stopped": all(item.process.poll() is not None for item in manager.processes)},
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True), encoding="utf-8")
    shutil.rmtree(data)
    sanitize_output(
        output,
        args.private_repo.resolve(),
        private_runtime,
        template["spec"]["receivers"][0]["name"],
        [matcher["value"] for matcher in template["spec"]["route"]["matchers"]],
    )

    if result != "passed":
        print(json.dumps({"result": result, "acceptance": acceptance}, sort_keys=True))
        return 1
    print(json.dumps({"result": "passed", "output": str(output)}))
    return 0


def main() -> int:
    args = parse_args()
    signal.signal(signal.SIGTERM, handle_termination)
    signal.signal(signal.SIGINT, handle_termination)
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        # This check must remain outside the exception cleanup scope: the
        # existing directory belongs to another run and must not be rewritten.
        raise RuntimeError(f"output directory must be absent or empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="metrics-backend-private-") as private_runtime:
        private_runtime_path = pathlib.Path(private_runtime)
        try:
            return run_benchmark(args, private_runtime_path)
        except BaseException:
            private_receiver = None
            private_match_values = []
            with contextlib.suppress(Exception):
                template, _ = load_private_template(args.private_repo.resolve(), args.private_ref)
                private_receiver = template["spec"]["receivers"][0]["name"]
                private_match_values = [
                    matcher["value"] for matcher in template["spec"]["route"]["matchers"]
                ]
            remove_private_runtime_state(args.output.resolve())
            sanitize_output(
                args.output.resolve(),
                args.private_repo.resolve(),
                private_runtime_path,
                private_receiver,
                private_match_values,
            )
            raise


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"benchmark failed: {error}", file=sys.stderr)
        raise
