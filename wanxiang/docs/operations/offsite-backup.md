# Wanxiang off-site backups

Wanxiang stores Longhorn volume backups and cluster metadata outside the
cluster site. The endpoint, access paths, recovery keys, and host procedures
are kept in `infra-private`.

## Overlay transport

An overlay peer can report a "direct" endpoint even when the route to that
endpoint traverses another overlay subnet router. This nests the transport
inside itself. Encapsulation then reduces the path MTU and can cause heavy
fragmentation and retransmission during large backups.

A temporary reduction of the overlay interface MTU can help diagnose this
failure mode, but it does not remove the recursive route. The durable fix is
to prevent the overlay's own marked transport packets from selecting a
confirmed recursive endpoint. Ordinary application traffic and genuine
underlay routes must remain available. Private routing details, measurements,
and rollout checks are recorded in the private infrastructure inventory.

## Backup verification

Before relying on an off-site target:

1. Confirm the encrypted storage is unlocked and its backup service is
   reachable from the cluster.
2. Confirm Longhorn reports the backup target as available.
3. Create a `SystemBackup` with `volumeBackupPolicy: always` and wait for
   all referenced volume backups to complete.
4. Periodically restore a disposable volume and verify its contents. A backup
   listing alone is not a restore test.

Longhorn volume backups and `SystemBackup` objects cover volume data and
cluster metadata. Applications that need point-in-time recovery also need
their own backup strategy.
