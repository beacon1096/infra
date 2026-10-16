# Metrics backend benchmark

This harness compares the complete metric path used by the two candidate
backends:

- Prometheus + the pinned Alertmanager;
- VictoriaMetrics Single + vmagent + vmalert + the same Alertmanager.

It uses one synthetic exporter, identical scrape targets, 5-second scrape and
evaluation intervals, the repository's real alert rules and dashboard queries,
and an isolated loopback notification receiver. No cluster, production data,
Longhorn volume, real webhook, or Secret is accessed. The private
AlertmanagerConfig is read in memory only to validate and derive the isolated
route. The derived native configuration is written only to a temporary
directory outside the public result tree and is deleted on success, failure,
or TERM/INT; neither it nor the private manifest is saved in public results.

Each stack is restricted to a two-CPU affinity set. A watchdog stops the run if
either stack exceeds 1.5 GiB aggregate RSS or 2 GiB in its data directories;
the wrapper enforces a 60-minute wall-time limit. Temporary child processes and
data directories are removed before a successful run exits.

Run from the repository root with an authorized checkout of `infra-private`:

```bash
bash utils/run-metrics-backend-benchmark.sh \
  --output utils/metrics-backend-benchmark/results/$(date -u +%F) \
  --private-repo ../infra-private \
  --private-ref <reviewed-infra-private-commit>
```

The default five-minute scenario has a 90-second metric fault window and a
20-second vmagent remote-write outage. It keeps all alert expressions intact,
but shortens each rule's `for` to 15 seconds and the isolated Alertmanager
group timings to 0/1 seconds so firing and recovery fit inside the bounded run.
Those deviations are listed in `metadata.json`; they do not validate the
production waiting periods.

Dashboard targets retain their Grafana query mode: 11 targets use instant
queries and three time-series targets use five-minute range queries at a
five-second step. Each paired request uses the same evaluation time and range
boundaries. Final sample-count checks use one common historical evaluation
time outside VictoriaMetrics' default latency offset; freshness is calculated
separately as client wall clock minus the returned latest sample timestamp.

A run passes only when all dashboard requests succeed, common-time final data
matches, wall-clock freshness stays within the documented backend bounds,
required firing/resolved notifications arrive, healthy baseline windows have
no firing alerts, the forced queue outage fully replays without dropped or
pending bytes, and neither resource budget is exceeded.

The result directory contains generated public scrape/rule configurations,
component and stack summaries, compatibility findings, version/hardware
metadata, and the validation summaries. High-volume samples, full snapshots,
process logs, and transient backend state live under `raw/`, `logs/`, and
`data/`; those paths are ignored by Git and must be archived separately when
they are needed as review evidence. A failed run can retain its backend data
directory for diagnosis but never retains the private-derived Alertmanager
configuration; remove that known result directory before retrying.

For the recorded 2026-10-16 run, the repository keeps only the curated files
under `results/2026-10-16/`. Its 22-file raw evidence archive is attached to
BEACO-216 and is identified in the result report by its byte size and SHA-256.
