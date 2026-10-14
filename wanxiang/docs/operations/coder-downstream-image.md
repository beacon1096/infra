# Coder downstream image

Coder 2.36.5 generates ambiguous PostgreSQL predicates for resource-scoped
API tokens. The workspace and template SQL converters emit an unqualified
`id :: text`; joined queries then fail with `column reference "id" is
ambiguous`. A workspace-only token also cannot load the related template.

The temporary downstream image applies
[`coder-resource-allowlist-sql.patch`](../../../docs/ci-cd/patches/coder-resource-allowlist-sql.patch)
to the fixed upstream `v2.36.5` source. The patch qualifies the two predicates
as `workspaces.id` and `t.id` and adds focused SQL compiler tests.

## Build and publication

`coder-server-oci` builds the upstream enterprise Coder command, embedded Web
UI, and Terraform runtime as a reproducible OCI archive. The derivation lives
in the public flake; public CI only builds and inspects the archive and holds
no registry write credentials. The image is published solely by
`infra-private`, which pins the public flake and pushes the moving `latest`,
an immutable `private-<private-rev>-infra-<infra-rev>` tag (full 40-char
private and pinned public SHAs), and the downstream release tag:

```text
forgejo.beaco.works/infrastructure/nix-fleet/coder:2.36.5-beacon.2
```

The publisher records the resolved digest. The production image must be
anonymously pullable before the HelmRelease image override is merged. The Coder
chart remains the unmodified 2.36.5 chart mirrored in the in-cluster Zot
registry.

## Verification

After Flux reports the HelmRelease ready, verify:

1. `/api/v2/buildinfo`, OIDC login, PostgreSQL migrations, and existing
   workspace agents remain healthy.
2. A token allowing one workspace and its template can read that workspace by
   UUID and list only authorized workspaces.
3. The same token receives 404 for a workspace outside its allow-list.
4. Coder logs contain neither `column reference "id" is ambiguous` nor new
   authorization errors.

Rollback the Deployment to the official `ghcr.io/coder/coder:v2.36.5` image if
the patched image fails before any new database migration. Remove this package,
patch, CI job, image override, and document after an upstream Coder release
contains the equivalent qualified predicates and passes the same API tests.
