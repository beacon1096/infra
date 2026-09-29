[中文](openviking-evaluation.md) | [English](openviking-evaluation_en.md)

# OpenViking deployment evaluation

Status: evaluated on 2026-09-27; not approved as the production Memoh memory backend.

## Decision

OpenViking can run as a single-node proof of concept in Wanxiang to test document ingestion, memory extraction, retrieval, persistence, and MCP. The deployed Memoh v0.20.0 cannot use it through a functional native Memory Provider, so the PoC must not take ownership of production bot memory.

The OpenViking adapter in Memoh v0.20.0 is a placeholder. Its chat hooks do not read or write memory, and its CRUD methods return `openviking provider is disabled`. The management UI still lists the provider type and the upstream documentation describes its configuration fields, but those surfaces do not make the runtime integration functional in this version.

References:

- [Memoh v0.20.0 OpenViking adapter](https://github.com/felinics/Memoh/blob/v0.20.0/internal/memory/adapters/openviking/openviking.go)
- [Memoh OpenViking documentation](https://github.com/felinics/memoh-docs/blob/main/docs/integrations/providers/memory/openviking.md)

## PoC scope

Keep the first deployment within these boundaries:

- Pin `ghcr.io/volcengine/openviking:v0.4.21`; do not use `latest`.
- Run one Deployment replica with the `Recreate` update strategy.
- Use one 20 GiB Longhorn RWO PVC.
- Expose port `1933` through a ClusterIP Service without a public route initially.
- Use API key authentication. Reserve the root key for administration and use a user key for routine access.
- Start with the local filesystem and local vector database without adding PostgreSQL, Qdrant, Redis, or remote object storage.
- Test through the generic MCP endpoint at `/mcp`; do not configure it as a Memoh Memory Provider.

The upstream chart also limits the local deployment to one replica with `Recreate` because local RocksDB and a PVC do not support concurrent pods. Its defaults request 500m CPU and 1 GiB memory, limit the pod to 2 CPU and 4 GiB memory, and allocate a 20 GiB PVC. Treat these values only as a PoC starting point.

References:

- [OpenViking v0.4.21 release](https://github.com/volcengine/OpenViking/releases/tag/v0.4.21)
- [OpenViking Helm Deployment](https://github.com/volcengine/OpenViking/blob/v0.4.21/deploy/helm/openviking/templates/deployment.yaml)
- [OpenViking MCP integration](https://docs.openviking.ai/en/guides/06-mcp-integration)

## Model dependencies

Embedding is required. Its output dimension must match both the OpenViking configuration and existing vector collections. Changing the model or dimension requires reindexing. A VLM supplies semantic summaries, memory extraction, and multimodal understanding; without one, L0/L1 content quality is reduced.

The PoC can start with the default local embedding and connect its VLM to the existing OpenAI-compatible gateway. If a remote embedding service is selected, keep its API key in a SOPS Secret and reference that Secret from the deployment configuration.

The Connect-It OpenAI connector is an MCP/SaaS connector rather than a model inference gateway. It cannot serve as the OpenViking embedding or VLM endpoint.

Reference: [OpenViking configuration](https://docs.openviking.ai/en/guides/01-configuration).

## Validation checklist

The PoC must verify at least:

1. `/health` and `/ready` remain stable across a restart.
2. API keys enforce the expected boundary between administration and tenant data.
3. English and Chinese Markdown, code, and one multimodal sample can be ingested.
4. A session commit produces memory that semantic search can retrieve.
5. An MCP client can find and write data, and reconnecting does not lose work.
6. PVC data survives pod recreation, and backup and restore steps are reproducible.
7. A fixed corpus records retrieval quality, indexing latency, query latency, CPU, memory, and disk growth.
8. One pinned-version upgrade and rollback leaves the old index readable.

## Production gates

Do not consider OpenViking a production Memoh backend until:

- The native Memoh OpenViking adapter implements automatic writes, automatic recall, and CRUD with versioned tests.
- The long-term hosts, model versions, embedding dimensions, and credential rotation procedures for embedding and VLM are defined.
- PVC snapshots, a restore exercise, capacity alerts, and upgrade rollback procedures exist.
- Shadow validation on production bots shows that memory writes and retrieval do not fail silently.
- Any multi-replica design first moves to shared file storage and a remote vector backend and passes concurrency tests.

Until these gates pass, Memoh built-in graph memory with its pgvector semantic index remains the production path, and OpenViking remains an isolated experiment.
