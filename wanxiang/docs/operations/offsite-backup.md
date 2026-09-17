# Wanxiang off-site backups

Wanxiang uses the TrueNAS system in Jinyintan as its off-site backup target.
The primary cluster is in Optics Valley, so this protects against loss of the
cluster site rather than only loss of one Longhorn replica.

## Data path

```text
Longhorn manager
  -> UDM-Pro static route (172.16.19.0/24 via 172.16.80.240)
  -> ms-r1
  -> Tailscale
  -> beaco-vault subnet router
  -> TrueNAS NFS (172.16.19.254)
```

Both subnet routers must accept routes. `ms-r1` advertises
`172.16.80.0/20`; `beaco-vault` advertises `172.16.19.0/24`. The TrueNAS NFS
export is restricted to the Wanxiang node subnet and the exact Tailscale
address of `ms-r1`.

The UDM-Pro route is managed by `terraform/unifi-wanxiang`. The `ms-r1`
Tailscale setting and the encrypted TrueNAS dataset recovery key are managed
in `infra-private`.

## Storage layout

- Dataset: `beaco-01/Backups/wanxiang/longhorn`
- Encryption root: `beaco-01/Backups`
- Encryption: AES-256-GCM with the recovery key stored through SOPS
- Parent quota: 4 TiB
- Dataset properties: LZ4 compression, 1 MiB records, atime disabled
- TrueNAS snapshots: recursive daily snapshots at 03:00, retained for 30 days
- Longhorn target: `nfs://172.16.19.254:/mnt/beaco-01/Backups/wanxiang/longhorn`

Longhorn backups and Longhorn `SystemBackup` objects cover volume data and
Longhorn/Kubernetes metadata. They do not replace application-native backup
and point-in-time recovery. CloudNativePG databases should additionally archive
WAL and base backups to an S3-compatible target on the off-site system.

## Verification

Before relying on the target:

1. Confirm the TrueNAS encrypted dataset is unlocked and the NFS share is
   enabled.
2. Confirm both subnet routes are approved in Tailscale.
3. Confirm `172.16.19.254:2049` is reachable from every Talos node.
4. Confirm the Longhorn `default` BackupTarget reports `Available`.
5. Create a `SystemBackup` using `volumeBackupPolicy: always` and wait for all
   referenced volume backups to complete.
6. Periodically restore a disposable volume and verify its contents. A backup
   listing alone is not a restore test.

Do not put the ZFS recovery key, Tailscale keys, or UniFi credentials in this
repository.
