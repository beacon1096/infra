#!/usr/bin/env bash
set -euo pipefail

run_id="${RUN_ID:-}"
openstatus_namespace="${OPENSTATUS_NAMESPACE:-monitoring}"
longhorn_namespace="${LONGHORN_NAMESPACE:-storage}"
max_age_hours="${MAX_BACKUP_AGE_HOURS:-26}"
baseline_file="${BASELINE_FILE:-}"
restore_namespace="openstatus-restore-${run_id}"
restore_label="openstatus.beaco.works/restore-run"
inspector_image="mirror.gcr.io/library/postgres:18-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873"

usage() {
  cat >&2 <<'EOF'
Render (do not apply) an isolated OpenStatus Longhorn restore drill.

Usage:
  RUN_ID=20261015a BASELINE_FILE=./openstatus-baseline.json \
    [MAX_BACKUP_AGE_HOURS=26] \
    bash utils/render-openstatus-restore-drill.sh > restore.yaml

The renderer is read-only. It refuses incomplete/stale backups, resolves the
three source PVCs to their latest Longhorn Backup objects, requires each
snapshot to be newer than the read-only pre-backup baseline, and pins the
three validation images to the digests currently running in the source
deployment. Applying the output creates storage and requires approval.
EOF
}

if [[ "$run_id" == "-h" || "$run_id" == "--help" ]]; then
  usage
  exit 0
fi

[[ "$run_id" =~ ^[a-z0-9]([a-z0-9-]{0,22}[a-z0-9])?$ ]] || {
  echo "restore renderer: RUN_ID must be 1-24 lowercase DNS-label characters" >&2
  usage
  exit 2
}
[[ "$max_age_hours" =~ ^[1-9][0-9]*$ ]] || {
  echo "restore renderer: MAX_BACKUP_AGE_HOURS must be a positive integer" >&2
  exit 2
}

[[ -r "$baseline_file" ]] || {
  echo "restore renderer: BASELINE_FILE is required and must be readable" >&2
  exit 2
}
for command in kubectl jq date sha256sum awk; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "restore renderer: $command is required" >&2
    exit 2
  }
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bash "$script_dir/validate-openstatus-restore-baseline.sh" "$baseline_file" "$baseline_file" >/dev/null
baseline_captured_at="$(jq -r '.captured_at // empty' "$baseline_file")"
[[ -n "$baseline_captured_at" ]] || {
  echo "restore renderer: baseline lacks captured_at" >&2
  exit 1
}
baseline_epoch="$(date -u -d "$baseline_captured_at" +%s)"
baseline_sha256="$(sha256sum "$baseline_file" | awk '{print $1}')"

if kubectl get namespace "$restore_namespace" >/dev/null 2>&1; then
  echo "restore renderer: namespace $restore_namespace already exists; choose a new RUN_ID" >&2
  exit 1
fi
if kubectl get pv -l "$restore_label=$run_id" -o name | grep -q .; then
  echo "restore renderer: PVs already carry $restore_label=$run_id; choose a new RUN_ID" >&2
  exit 1
fi
if kubectl -n "$longhorn_namespace" get volumes.longhorn.io \
  -l "$restore_label=$run_id" -o name | grep -q .; then
  echo "restore renderer: Longhorn volumes already carry $restore_label=$run_id; choose a new RUN_ID" >&2
  exit 1
fi

target_json="$(kubectl -n "$longhorn_namespace" get backuptargets.longhorn.io default -o json)"
job_json="$(kubectl -n "$longhorn_namespace" get recurringjobs.longhorn.io daily-backup -o json)"
backups_json="$(kubectl -n "$longhorn_namespace" get backups.longhorn.io -o json)"

jq -e '.status.available == true' <<<"$target_json" >/dev/null || {
  echo "restore renderer: BackupTarget/default is unavailable" >&2
  exit 1
}
jq -e '.spec.task == "backup" and (.spec.groups | index("default") != null)' \
  <<<"$job_json" >/dev/null || {
  echo "restore renderer: RecurringJob/daily-backup does not select group default" >&2
  exit 1
}

declare -A pvc_names=(
  [libsql]="openstatus-libsql-data"
  [tinybird]="openstatus-tinybird-data"
  [workflows]="openstatus-workflows-data"
)
declare -A backup_names backup_times backup_urls volume_sizes source_volumes
components=(libsql tinybird workflows)
now_epoch="$(date -u +%s)"
max_age_seconds="$((max_age_hours * 3600))"
logical_bytes=0
largest_volume_bytes=0

for component in "${components[@]}"; do
  pvc="${pvc_names[$component]}"
  pvc_json="$(kubectl -n "$openstatus_namespace" get pvc "$pvc" -o json)"
  jq -e '.status.phase == "Bound" and (.spec.volumeName | length > 0)' \
    <<<"$pvc_json" >/dev/null || {
    echo "restore renderer: PVC/$pvc is not Bound" >&2
    exit 1
  }
  pv="$(jq -r '.spec.volumeName' <<<"$pvc_json")"
  volume="$(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}')"
  [[ -n "$volume" ]] || {
    echo "restore renderer: PV/$pv has no CSI volumeHandle" >&2
    exit 1
  }
  source_volumes[$component]="$volume"

  volume_json="$(kubectl -n "$longhorn_namespace" get volumes.longhorn.io "$volume" -o json)"
  jq -e '.metadata.labels["recurring-job-group.longhorn.io/default"] == "enabled"' \
    <<<"$volume_json" >/dev/null || {
    echo "restore renderer: Volume/$volume is not bound to recurring-job group default" >&2
    exit 1
  }

  backup_tsv="$(jq -r --arg volume "$volume" '
    [.items[] | select((.status.volumeName // .spec.volumeName // "") == $volume)]
    | sort_by(.status.snapshotCreatedAt // "")
    | last
    | if . == null then empty else [
        .metadata.name,
        (.status.state // ""),
        (.status.snapshotCreatedAt // ""),
        (.status.url // ""),
        (.status.volumeSize // ""),
        (.status.error // ""),
        ((.status.messages // []) | map(.message // tostring) | join(";"))
      ] | @tsv end
  ' <<<"$backups_json")"
  [[ -n "$backup_tsv" ]] || {
    echo "restore renderer: no Backup exists for Volume/$volume" >&2
    exit 1
  }
  IFS=$'\t' read -r backup state snapshot_time backup_url volume_size backup_error backup_messages \
    <<<"$backup_tsv"
  [[ "$state" == "Completed" && -z "$backup_error" && -z "$backup_messages" ]] || {
    echo "restore renderer: Backup/$backup is not a clean Completed backup (state=$state)" >&2
    exit 1
  }
  [[ -n "$snapshot_time" && -n "$backup_url" && "$volume_size" =~ ^[1-9][0-9]*$ ]] || {
    echo "restore renderer: Backup/$backup is missing timestamp, URL, or volume size" >&2
    exit 1
  }
  backup_epoch="$(date -u -d "$snapshot_time" +%s)"
  age_seconds="$((now_epoch - backup_epoch))"
  if (( age_seconds < 0 || age_seconds > max_age_seconds )); then
    echo "restore renderer: Backup/$backup for $component is stale ($((age_seconds / 3600))h > ${max_age_hours}h)" >&2
    exit 1
  fi
  if (( backup_epoch < baseline_epoch )); then
    echo "restore renderer: Backup/$backup predates the recorded baseline ($snapshot_time < $baseline_captured_at)" >&2
    exit 1
  fi

  backup_names[$component]="$backup"
  backup_times[$component]="$snapshot_time"
  backup_urls[$component]="$backup_url"
  volume_sizes[$component]="$volume_size"
  logical_bytes="$((logical_bytes + volume_size))"
  if (( volume_size > largest_volume_bytes )); then
    largest_volume_bytes="$volume_size"
  fi
done

resolve_running_image() {
  local app="$1"
  local image_id
  image_id="$(kubectl -n "$openstatus_namespace" get pods \
    -l "app.kubernetes.io/name=$app" -o json | jq -r '
      [.items[]
        | select(.status.phase == "Running")
        | .status.containerStatuses[]?
        | select(.ready == true)
        | .imageID
        | select(contains("@sha256:"))]
      | first // empty
    ')"
  [[ "$image_id" == *@sha256:* ]] || {
    echo "restore renderer: no ready digest-pinned imageID found for $app" >&2
    return 1
  }
  printf '%s' "$image_id"
}

libsql_image="$(resolve_running_image openstatus-libsql)"
tinybird_image="$(resolve_running_image openstatus-tinybird)"
workflows_image="$(resolve_running_image openstatus-workflows)"
logical_gib="$(((logical_bytes + 1073741823) / 1073741824))"
required_gib="$(((logical_bytes * 120 + 107374182400 - 1) / 107374182400))"
required_bytes="$((logical_bytes * 120 / 100))"
largest_required_bytes="$((largest_volume_bytes * 120 / 100))"
longhorn_nodes_json="$(kubectl -n "$longhorn_namespace" get nodes.longhorn.io -o json)"
eligible_available_bytes="$(jq '[
  .items[].status.diskStatus // {} | to_entries[] |
  select(any(.value.conditions[]?; .type == "Schedulable" and .status == "True")) |
  (.value.storageAvailable | tonumber)
] | add // 0' <<<"$longhorn_nodes_json")"
largest_eligible_bytes="$(jq '[
  .items[].status.diskStatus // {} | to_entries[] |
  select(any(.value.conditions[]?; .type == "Schedulable" and .status == "True")) |
  (.value.storageAvailable | tonumber)
] | max // 0' <<<"$longhorn_nodes_json")"
if (( eligible_available_bytes < required_bytes || largest_eligible_bytes < largest_required_bytes )); then
  echo "restore renderer: insufficient schedulable Longhorn capacity for the 20% headroom gate" >&2
  exit 1
fi
eligible_available_gib="$((eligible_available_bytes / 1073741824))"

cat <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${restore_namespace}
  labels:
    ${restore_label}: ${run_id}
    app.kubernetes.io/part-of: openstatus-restore-drill
  annotations:
    openstatus.beaco.works/storage-approval-required: "true"
    openstatus.beaco.works/logical-storage-gib: "${logical_gib}"
    openstatus.beaco.works/minimum-schedulable-gib: "${required_gib}"
    openstatus.beaco.works/baseline-sha256: "${baseline_sha256}"
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: ${restore_namespace}
  labels:
    ${restore_label}: ${run_id}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: restore-provenance
  namespace: ${restore_namespace}
  labels:
    ${restore_label}: ${run_id}
data:
  renderedAt: "$(date -u +%FT%TZ)"
  maxBackupAgeHours: "${max_age_hours}"
  logicalStorageGiB: "${logical_gib}"
  minimumSchedulableGiB: "${required_gib}"
  observedEligibleAvailableGiB: "${eligible_available_gib}"
  baselineCapturedAt: "${baseline_captured_at}"
  baselineSha256: "${baseline_sha256}"
  libsqlBackup: "${backup_names[libsql]}"
  libsqlSnapshotCreatedAt: "${backup_times[libsql]}"
  tinybirdBackup: "${backup_names[tinybird]}"
  tinybirdSnapshotCreatedAt: "${backup_times[tinybird]}"
  workflowsBackup: "${backup_names[workflows]}"
  workflowsSnapshotCreatedAt: "${backup_times[workflows]}"
EOF

for component in "${components[@]}"; do
  volume_name="osr-${run_id}-${component}"
  pvc_name="restore-${component}-data"
  size="${volume_sizes[$component]}"
  cat <<EOF
---
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: ${volume_name}
  namespace: ${longhorn_namespace}
  labels:
    ${restore_label}: ${run_id}
    app.kubernetes.io/component: ${component}
  annotations:
    openstatus.beaco.works/source-backup: "${backup_names[$component]}"
    openstatus.beaco.works/source-snapshot-created-at: "${backup_times[$component]}"
spec:
  accessMode: rwo
  dataEngine: v1
  frontend: blockdev
  fromBackup: "${backup_urls[$component]}"
  numberOfReplicas: 1
  revisionCounterDisabled: true
  size: "${size}"
  staleReplicaTimeout: 30
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${volume_name}
  labels:
    ${restore_label}: ${run_id}
    app.kubernetes.io/component: ${component}
spec:
  accessModes: [ReadWriteOnce]
  capacity:
    storage: "${size}"
  claimRef:
    namespace: ${restore_namespace}
    name: ${pvc_name}
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: ${volume_name}
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  volumeMode: Filesystem
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: ${restore_namespace}
  labels:
    ${restore_label}: ${run_id}
    app.kubernetes.io/component: ${component}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: "${size}"
  storageClassName: longhorn
  volumeMode: Filesystem
  volumeName: ${volume_name}
EOF
done

cat <<EOF
---
apiVersion: batch/v1
kind: Job
metadata:
  name: restore-inventory
  namespace: ${restore_namespace}
  labels:
    ${restore_label}: ${run_id}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 900
  template:
    metadata:
      labels:
        ${restore_label}: ${run_id}
        app.kubernetes.io/name: openstatus-restore-inventory
    spec:
      restartPolicy: Never
      containers:
        - name: inventory
          image: ${inspector_image}
          command: [/bin/sh, -ec]
          args:
            - |
              for component in libsql tinybird workflows; do
                root="/restore/\${component}"
                test -r "\${root}"
                files="\$(find "\${root}" -xdev -type f | wc -l | tr -d ' ')"
                kib="\$(du -sk "\${root}" | awk '{print \$1}')"
                test "\${files}" -gt 0
                printf 'RESTORE_INVENTORY component=%s files=%s kib=%s readable=true\\n' \
                  "\${component}" "\${files}" "\${kib}"
              done
              echo RESTORE_INVENTORY_OK
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
            runAsNonRoot: false
            runAsUser: 0
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 128Mi
          volumeMounts:
            - {name: libsql, mountPath: /restore/libsql, readOnly: true}
            - {name: tinybird, mountPath: /restore/tinybird, readOnly: true}
            - {name: workflows, mountPath: /restore/workflows, readOnly: true}
      volumes:
        - name: libsql
          persistentVolumeClaim: {claimName: restore-libsql-data, readOnly: true}
        - name: tinybird
          persistentVolumeClaim: {claimName: restore-tinybird-data, readOnly: true}
        - name: workflows
          persistentVolumeClaim: {claimName: restore-workflows-data, readOnly: true}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: restore-libsql
  namespace: ${restore_namespace}
  labels:
    ${restore_label}: ${run_id}
spec:
  replicas: 0
  selector:
    matchLabels: {app.kubernetes.io/name: restore-libsql}
  strategy: {type: Recreate}
  template:
    metadata:
      labels:
        ${restore_label}: ${run_id}
        app.kubernetes.io/name: restore-libsql
    spec:
      containers:
        - name: libsql
          image: ${libsql_image}
          env: [{name: SQLD_NODE, value: primary}]
          ports: [{name: http, containerPort: 8080}]
          volumeMounts: [{name: data, mountPath: /var/lib/sqld}]
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: restore-libsql-data}
---
apiVersion: v1
kind: Service
metadata:
  name: restore-libsql
  namespace: ${restore_namespace}
  labels:
    ${restore_label}: ${run_id}
spec:
  selector: {app.kubernetes.io/name: restore-libsql}
  ports: [{name: http, port: 8080, targetPort: http}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: restore-tinybird
  namespace: ${restore_namespace}
  labels:
    ${restore_label}: ${run_id}
spec:
  replicas: 0
  selector:
    matchLabels: {app.kubernetes.io/name: restore-tinybird}
  strategy: {type: Recreate}
  template:
    metadata:
      labels:
        ${restore_label}: ${run_id}
        app.kubernetes.io/name: restore-tinybird
    spec:
      containers:
        - name: tinybird
          image: ${tinybird_image}
          env: [{name: COMPATIBILITY_MODE, value: "1"}]
          ports: [{name: http, containerPort: 7181}]
          volumeMounts: [{name: data, mountPath: /data}]
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: restore-tinybird-data}
---
apiVersion: v1
kind: Service
metadata:
  name: restore-tinybird
  namespace: ${restore_namespace}
  labels:
    ${restore_label}: ${run_id}
spec:
  selector: {app.kubernetes.io/name: restore-tinybird}
  ports: [{name: http, port: 7181, targetPort: http}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: restore-workflows-reader
  namespace: ${restore_namespace}
  labels:
    ${restore_label}: ${run_id}
spec:
  replicas: 0
  selector:
    matchLabels: {app.kubernetes.io/name: restore-workflows-reader}
  strategy: {type: Recreate}
  template:
    metadata:
      labels:
        ${restore_label}: ${run_id}
        app.kubernetes.io/name: restore-workflows-reader
    spec:
      containers:
        - name: workflows-reader
          image: ${workflows_image}
          command: [/bin/sh, -ec]
          args:
            - |
              test -r /app/data
              find /app/data -xdev -type f | sed -n '1,20p'
              echo RESTORE_WORKFLOWS_READABLE
              sleep 3600
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
          volumeMounts:
            - {name: data, mountPath: /app/data, readOnly: true}
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: restore-workflows-data, readOnly: true}
EOF

printf 'restore renderer: selected fresh backups; logical=%sGi, minimum schedulable headroom=%sGi, replicas=1\n' \
  "$logical_gib" "$required_gib" >&2
printf 'restore renderer: eligible Longhorn disks report %sGi available in aggregate\n' \
  "$eligible_available_gib" >&2
jq -r '
  .items[] as $node | $node.status.diskStatus // {} | to_entries[] |
  select(any(.value.conditions[]?; .type == "Schedulable" and .status == "True")) |
  ["restore renderer: disk", $node.metadata.name, .key,
    ((.value.storageAvailable | tonumber) / 1073741824 | floor | tostring) + "Gi-available"] |
  @tsv
' <<<"$longhorn_nodes_json" >&2
for component in "${components[@]}"; do
  printf 'restore renderer: %s backup=%s snapshot=%s source_volume=%s bytes=%s\n' \
    "$component" "${backup_names[$component]}" "${backup_times[$component]}" \
    "${source_volumes[$component]}" "${volume_sizes[$component]}" >&2
done
