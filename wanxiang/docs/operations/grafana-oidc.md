# Grafana OIDC delivery

This document records the approved Grafana OIDC delivery for BEACO-216. The
BEACO-248 activation selects the create overlay, references both encrypted
namespace-local Secrets, and switches the two live Flux Kustomizations to the
reviewed paths. The create, verified-reentry, and rollback directories remain
separate Kustomize overlays.

## Fixed contract

- Authentik chart: `2026.2.2`.
- Authentik provider: `Grafana @ Beacoworks`, confidential client, client ID
  `grafana`, application slug `grafana`.
- Redirect URI: `https://grafana.beaco.works/login/generic_oauth` with strict
  matching.
- OIDC scopes: `openid profile email`.
- Authentik application access: group `Grafana Viewers` only. The create
  Blueprint creates this group empty; membership is an explicit production
  decision and is not inferred from restored users or from the admin group.
- Authentik worker Secret: `identity/authentik-grafana-oidc`, with
  `AUTHENTIK_GRAFANA_OIDC_CLIENT_ID` and
  `AUTHENTIK_GRAFANA_OIDC_CLIENT_SECRET`.
- Grafana Secret: `monitoring/grafana-oidc`, with
  `GF_AUTH_GENERIC_OAUTH_CLIENT_ID` and
  `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`.

The two Secrets must carry the same dedicated client pair. The secret value is
never a Terraform, Matrix, admin, Helm `--set`, Flux substitution, log, argv,
or issue-comment value.

## Preflight contract

Before choosing an activation overlay, create a local JSON evidence document
from a read-only Authentik metadata export. It may contain only non-secret
object IDs, names, relationships, membership IDs, and bindings; it must not
contain client secrets or tokens. Check it with:

```text
python3 utils/check_grafana_oidc_contract.py ./grafana-oidc-evidence.json
```

The checker accepts exactly two modes:

- `create`: the group, provider, and application are all absent. The
  `grafana-oidc-prep/` Blueprint uses `state: must_created` and rejects any
  existing target instead of taking it over.
- `reentry`: all three objects have stable non-secret IDs, the exact reviewed
  metadata and relationships, an empty `Grafana Viewers` group, and exactly one
  enabled non-negated binding from that group to the `grafana` application.
  The `grafana-oidc-reentry-prep/` Blueprint uses `state: present` only for
  this verified case.

Missing evidence, a same-name group with members, an extra user/policy/group
binding, or any other conflict rejects the mode. The checker does not query
Authentik or change identity objects, so an operator must retain the read-only
export and approval record alongside the activation review.

The repository checks are static Blueprint/YAML checks and disconnected
Kustomize renders. They do not exercise the Authentik 2026.2.2 serializer,
decrypt a Secret, or perform a live browser login; the serializer and browser
acceptance remain live-cluster checks.

## Activation procedure

Perform these steps only after the provider/application, access-group
membership, and Authentik database backup/restore conditions have been
approved. The activation change uses the create mode covered by the approved
BEACO-247 evidence.

1. Complete the preflight contract above. Use the create overlay for a new
   object set or the reentry overlay only for the verified reentry mode.
2. From the repository root, run
   `SOPS_CONFIG=wanxiang/.sops.yaml utils/prepare-grafana-oidc-secrets.sh --generate`,
   or run it without `--generate` and enter an already-approved secret at the
   hidden terminal prompt. The script writes only encrypted manifests to the
   two app directories and refuses to overwrite existing files.
3. Confirm encryption with `sops filestatus` and `git diff --check`. Do not run
   `sops -d`, print a decrypted value, or pass the value as a command argument.
4. In the same approved activation change, add both generated files to their
   app `kustomization.yaml` resources and change the Authentik and monitoring
   Flux `spec.path` values from `app` to the selected create/reentry and
   `grafana-oidc-prep` overlays. Review the rendered output before merge.
5. After merge, an authorized operator may reconcile the two Kustomizations.
   For the existing failed Grafana HelmRelease, issue exactly one
   `flux reconcile helmrelease kube-prometheus-stack -n monitoring --reset`.
   A Ready Kustomization is not a prerequisite for `--reset`; the controller
   may retry according to the existing remediation policy.

## Acceptance

Check the Authentik and Grafana HelmReleases and their Kustomizations are Ready,
then verify all of the following with a member of the approved group:

- OIDC login lands in Grafana as `Viewer`, not an administrator.
- Anonymous access and an unapproved Authentik user are rejected.
- The platform dashboard returns current data from the existing Prometheus.
- Existing Agent queries and the existing LAN/Tailscale/VPN mobile path still
  work.
- Authentik discovery and the exact callback do not return 404 or mismatch.

Do not claim login acceptance until the browser test is actually performed.
The existing 71/71 collection result is historical evidence, not a new
acceptance result for this change.

## Rollback

Do not directly revert an activation that leaves the baseline Grafana
HelmRelease enabled while its `grafana-oidc` Secret is being removed. Use the
reviewable rollback overlays in this order, keeping Prometheus, Alertmanager,
and their PVCs on the base app resources:

1. **Stop Grafana first.** Change only the monitoring Flux `spec.path` to
   `.../prometheus-stack/grafana-oidc-rollback`, retain both encrypted Secret
   manifests and leave the Authentik prep path in place. This overlay sets
   `grafana.enabled=false`, removes the Grafana `envFromSecret` reference, and
   deletes only the `grafana` HTTPRoute. Reconcile monitoring and verify that
   no Grafana workload or route consumes `monitoring/grafana-oidc`.
2. **Remove the Authentik worker consumer.** Change the identity Flux
   `spec.path` to `.../authentik/grafana-oidc-rollback` and reconcile identity.
   This overlay removes the Grafana Blueprint ConfigMap and sets worker
   `envFrom: []`; verify the worker rollout no longer references
   `identity/authentik-grafana-oidc`.
3. **Clean up only after both checks pass.** In a separate approved change,
   remove the two Secret resources from the app Kustomizations and delete the
   encrypted Secret manifests. Keep the rollback overlays active until a new
   Grafana activation is approved.

Removing a Blueprint file does not delete provider/application/group rows
already stored in Authentik. Disabling or deleting those rows is a separate,
bounded identity operation with its own approval; it must not clear group
members or bindings implicitly.

This activation change performs no Flux suspend/resume. Flux reconciliation and
the one HelmRelease reset are explicit post-merge actions.
