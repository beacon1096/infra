# Forgejo runner maintenance

The three Harvester Nix builders each accept one Forgejo Actions job at a
time. Workflow jobs and the runner have the same 12-hour maximum runtime.
Store maintenance must not overlap a running job: garbage collection may
delete derivations retained only by an evaluation cache, while garbage
collection and store optimisation both generate enough Longhorn I/O to make
builds appear stalled.

## Rotation

Only one runner enters maintenance at a time. The other two remain available.

| Runner | Drain begins | Store maintenance | Runner resumes |
| --- | --- | --- | --- |
| `nixbuilder-01` | Sunday and Wednesday 15:00 | Monday and Thursday 03:15 | Monday and Thursday 04:25 |
| `nixbuilder-02` | Monday and Thursday 15:00 | Tuesday and Friday 03:15 | Tuesday and Friday 04:25 |
| `nixbuilder-03` | Tuesday and Friday 15:00 | Wednesday and Saturday 03:15 | Wednesday and Saturday 04:25 |

All times use the host timezone, `Asia/Shanghai`. Sunday has no store
maintenance window.

## Harvester placement

Each builder is pinned to a different physical Harvester node:

| Runner | Harvester node |
| --- | --- |
| `nixbuilder-01` | `mc4-01` |
| `nixbuilder-02` | `mc4-02` |
| `nixbuilder-03` | `mc5-01` |

This avoids two I/O-heavy Nix builds competing through the same VM host. The
mapping is declared in `terraform/harvester/variables.tf`; do not rely on
Harvester's default preferred anti-affinity because it is not a hard placement
constraint.

Node pinning deliberately trades VM-level failover for predictable build
capacity. If one Harvester node fails or is maintained, its builder remains
unavailable instead of migrating onto another builder's node, while the other
two runners continue accepting jobs. A manual live migration may temporarily
override placement during maintenance, but the declared mapping should be
restored afterward.

Longhorn keeps three replicas of each builder disk, one per storage node.
Moving a VM changes its compute placement and Longhorn volume frontend; it does
not rebalance replica allocation or reduce a node's storage reservation.

## Sequence and failure behavior

1. The drain timer writes `/run/nixbuilder-maintenance`, which prevents the
   runner from being restarted by an intervening system activation.
2. The runner stops accepting jobs and waits up to 12 hours for its current
   job to finish. A 15-minute gap remains before store maintenance begins.
3. At 03:15, maintenance runs only if the marker exists and the runner is
   fully inactive. Otherwise it is skipped rather than risking a live build.
4. `nix-collect-garbage --delete-older-than 7d` and `nix-store --optimise`
   share a one-hour systemd timeout. Daily automatic GC and optimisation are
   disabled on these builders.
5. At 04:25 the marker is removed and the runner is started. This resume timer
   is persistent, so a host that was unavailable at 04:25 recovers when it
   next boots.

If jobs routinely approach 12 hours, keep this window. Once long jobs have
been eliminated, reduce the workflow timeout, runner timeout, shutdown timeout,
and drain lead time together; changing only one of them can terminate an active
job or allow maintenance to overlap it.

## Verification

After changing the schedule, evaluate all three hosts and inspect their timers:

```bash
nix build \
  .#nixosConfigurations.nixbuilder-01.config.system.build.toplevel \
  .#nixosConfigurations.nixbuilder-02.config.system.build.toplevel \
  .#nixosConfigurations.nixbuilder-03.config.system.build.toplevel

systemctl list-timers 'nixbuilder-*'
```
