# Grafana OIDC delivery

This is the non-effective delivery package for the Grafana OIDC dependency of
BEACO-216. The two `grafana-oidc-prep/` directories are Kustomize overlays, but
neither live Flux Kustomization points at them. This change does not create a
Secret, provider, application, RBAC object, or pod.

## Fixed contract

- Authentik chart: `2026.2.2`.
- Authentik provider: `Grafana @ Beacoworks`, confidential client, client ID
  `grafana`, application slug `grafana`.
- Redirect URI: `https://grafana.beaco.works/login/generic_oauth` with strict
  matching.
- OIDC scopes: `openid profile email`.
- Authentik application access: group `Grafana Viewers` only. The blueprint
  creates the group empty; membership is an explicit production decision and
  is not inferred from the restored users or from the admin group.
- Authentik worker Secret: `identity/authentik-grafana-oidc`, with
  `AUTHENTIK_GRAFANA_OIDC_CLIENT_ID` and
  `AUTHENTIK_GRAFANA_OIDC_CLIENT_SECRET`.
- Grafana Secret: `monitoring/grafana-oidc`, with
  `GF_AUTH_GENERIC_OAUTH_CLIENT_ID` and
  `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`.

The two Secrets must carry the same dedicated client pair. The secret value is
never a Terraform, Matrix, admin, Helm `--set`, Flux substitution, log, argv,
or issue-comment value.

## Approved delivery

Perform these steps only after the provider/application, access-group
membership, and Authentik database backup/restore conditions have been
approved. This PR deliberately does not run the command.

1. From the repository root, run
   `utils/prepare-grafana-oidc-secrets.sh --generate`, or run it without
   `--generate` and enter an already-approved secret at the hidden terminal
   prompt. The script writes only encrypted manifests to the two app
   directories and refuses to overwrite existing files.
2. Confirm encryption with `sops filestatus` and `git diff --check`. Do not run
   `sops -d`, print a decrypted value, or pass the value as a command argument.
3. In the same approved activation change, add both generated files to their
   app `kustomization.yaml` resources and change the Authentik and monitoring
   Flux `spec.path` values from `app` to their corresponding
   `grafana-oidc-prep` overlay. Review the rendered output before merge.
4. After merge, an authorized operator may reconcile the two Kustomizations.
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

Revert only the activation commit, reconcile Authentik and the monitoring
Kustomization, and keep Prometheus, Alertmanager, and their PVCs. Removing the
Blueprint file does not delete provider/application/group rows already stored
in Authentik; disabling or removing those rows requires a separate approved
identity operation. Do not delete the OIDC Secret until the Grafana workload no
longer references it.

This preparation change has no Flux suspend/resume or live-cluster action.
