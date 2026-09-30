# ADR talos-ii/0015 — Self-hosted web archiving with ArchiveBox

**Scope:** talos-ii (wanxiang)
**Status:** accepted
**Date:** 2026-09-30

## Context

Our documentation cites external references — including ChatGPT share links — that rot,
change, or disappear. We need a self-hosted "wayback machine" that captures a URL and
keeps a replayable snapshot under our control, without depending on the Internet Archive
or another third-party archiving service.

Candidates considered:

- **ArchiveBox** — self-contained capture + replay, single container, SQLite collection.
- **wabarc/wayback** — thinner, but delegates capture to external archiving providers.
- **pywb / Browsertrix** — strong replay/crawl engines, but not a complete
  capture-and-manage application by themselves.

## Decision

Deploy **ArchiveBox** as a single Flux-managed container in a new `archive` namespace,
under the shared `bjw-s` `app-template` chart.

- Collection data lives on a `longhorn-r3` `ReadWriteOnce` PVC; `strategy: Recreate`
  enforces the single-writer contract.
- Exposed as `wayback.${SECRET_DOMAIN}` on `envoy-internal` (Tailscale) only. There is no
  public route in the MVP.
- `SERVER_SECURITY_MODE=safe-onedomain-nojsreplay`: the admin control plane stays behind
  its own login, archived pages do not execute risky replay JS, and no wildcard DNS/TLS
  is required.
- Admin credentials are SOPS-managed and the account is created on first init.

## Alternatives considered

- **wabarc/wayback** — rejected: relies on external archiving providers, so the snapshot
  is not really ours and can disappear with the provider.
- **Subdomain-per-snapshot isolation (`safe-subdomains-fullreplay`)** — stronger replay
  fidelity and origin isolation, but needs wildcard routing for snapshot subdomains.
  Deferred; revisit if `nojsreplay` proves too lossy for JS-heavy pages.
- **Public exposure on `envoy-external`** — deferred. Serving untrusted archived content
  publicly should be a reviewed decision, not a default.

## Consequences

Positive:
- Snapshots are self-contained and under our control.
- Uses existing patterns (app-template, Longhorn, Gateway API, SOPS, Zot).
- One container and one PVC keep the footprint small.

Negative:
- Chrome-based extraction is memory-heavy and the first snapshot is slow.
- `nojsreplay` reduces fidelity for interactive pages.
- A Flux revert prunes the PVC; keeping data requires prune protection or a snapshot.
- No dedicated backup job is added by this decision; Longhorn backup coverage must be
  confirmed separately.
