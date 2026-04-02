# Architecture

## Overview

framework-ai-stack is a local AI inference platform with live retrieval-augmented generation (RAG). It runs on a single Framework Desktop (AMD Ryzen AI Max+ 395, 128 GB unified memory, Fedora 43) as rootless Podman containers managed by systemd quadlets.

The system serves a Qwen3.5-35B-A3B model behind a RAG proxy that automatically enriches every query with relevant content from a curated document corpus. Documents are ingested from Google Drive, git repositories, and web URLs without requiring model restarts.

## Request flow

```
Client (Claude Code, Open WebUI, curl)
  │
  ▼  :4000
LiteLLM proxy
  │  Routes all aliases (default, reasoning, code, fast)
  ▼  :8090
RAG proxy
  │  1. Embed the user's query
  │  2. Search Qdrant for top-K candidate vectors
  │  3. Batch-hydrate chunk text from the document store
  │  4. Rerank with cross-encoder (cross-encoder/ms-marco-MiniLM-L-6-v2)
  │  5. Format top-N chunks with [doc_id:chunk_id] labels
  │  6. Inject corpus-preferring system prompt + context
  │  7. Forward to model
  │  8. Post-process: parse citations, validate, classify grounding
  │  9. Attach rag_metadata, emit audit log
  ▼  :8080
Qwen3.5-35B-A3B (llama-server via RamaLama)
  │  MoE, 3B active params, ~22 GB, q8_0 KV cache
  ▼
AMD Ryzen AI Max+ 395 (ROCm, gfx1151)
```

## Ingestion flow

```
Document sources (Google Drive, git repos, web URLs)
  │
  ▼
RAG watcher (polls every 15 minutes)
  │  1. Download new/modified documents
  │  2. Extract text (PDF, DOCX, PPTX, XLSX, HTML, Markdown)
  │  3. Chunk with RecursiveCharacterTextSplitter
  │  4. Persist chunks to document store (Postgres)
  │  5. Embed with sentence-transformers/all-mpnet-base-v2 (CPU-only)
  │  6. Upsert reference-only payloads to Qdrant
  ▼
Qdrant (vectors) + Postgres (chunk text)
```

## Components

### LiteLLM proxy (:4000)

OpenAI-compatible API gateway. Routes all model aliases to the RAG proxy. Provides a single endpoint for all clients. Backed by Postgres for state persistence.

**Image:** `ghcr.io/berriai/litellm:main-stable`

### RAG proxy (:8090)

The core intelligence layer. Intercepts chat completion requests, performs retrieval, reranking, and citation-aware context injection, then post-processes the response with grounding classification and citation validation. Both the embedding model and the reranker run on CPU — ROCm PyTorch segfaults on gfx1151 for sentence-transformers models (see ADR-013).

See [grounding.md](grounding.md) for the full grounding specification.

**Image:** `localhost/rag-proxy` (built from `ubi9/python-311`, deps + models baked in)

### Qdrant (:6333)

Vector similarity search engine. Stores only reference payloads — no document text. Each point contains `{doc_id, chunk_id, source, created_at}` plus the embedding vector. Uses int8 scalar quantization (quantile 0.99, always_ram) to reduce memory footprint.

See [ADR-002](adr/002-reference-only-indexing.md) for the design rationale.

**Image:** `docker.io/qdrant/qdrant`

### Document store (Postgres :5432)

Stores full chunk text and metadata. Shared with LiteLLM (same Postgres instance, separate table). Keyed on `(doc_id, chunk_id)` with upsert semantics so re-ingestion is idempotent.

The `doc_id` is a deterministic UUID5 derived from the source URI, ensuring the same document always gets the same ID regardless of when it's ingested.

**Image:** `quay.io/sclorg/postgresql-16-c9s`

### RamaLama / llama-server (:8080)

Serves the Qwen3.5-35B-A3B model via llama-server. The model uses Mixture of Experts (MoE) with 3B active parameters from 35B total. KV cache uses q8_0 quantization (1360 MiB vs 2560 MiB at f16), and flash attention is enabled for bandwidth efficiency on long 131072-token contexts.

**Image:** `quay.io/ramalama/rocm:latest`

### RAG watcher

Polls document sources on a configurable interval (default 15 minutes). Supports three source types:

- **Google Drive** — via service account, tracks file modification times
- **Git repos** — shallow clones with incremental pull, glob-based file filtering
- **Web URLs** — fetches and extracts text from HTML pages

After extraction and chunking, persists to the document store first (ensuring the source of truth is written before vectors), then embeds and upserts reference payloads to Qdrant.

**Image:** `localhost/rag-watcher` (built from `ubi10`, deps + models baked in)

### Open WebUI (:3000)

Chat interface. Connects to LiteLLM as its OpenAI backend, so all queries automatically flow through the RAG pipeline.

**Image:** `ghcr.io/open-webui/open-webui:v0.8.6`

## Port map

| Port | Service | Protocol |
|------|---------|----------|
| 3000 | Open WebUI | HTTP |
| 4000 | LiteLLM proxy | HTTP (OpenAI API) |
| 5432 | PostgreSQL | PostgreSQL |
| 6333 | Qdrant | HTTP |
| 8080 | llama-server | HTTP (OpenAI API) |
| 8090 | RAG proxy | HTTP (OpenAI API) |

## Data stores

| Store | What it holds | Why separate |
|-------|--------------|--------------|
| Qdrant | Vectors + reference payloads | Optimized for similarity search, quantized for memory efficiency |
| Postgres (chunks table) | Full chunk text, source, timestamps | Source of truth for document content, enables independent scaling |
| Postgres (litellm tables) | LiteLLM proxy state | Shared instance, separate concern |
| Qdrant volume | Persistent vector data | Survives container restarts |
| Model cache volume | HuggingFace model weights | Embedding + reranker models cached across restarts |

## Hardware

- **CPU:** AMD Ryzen AI Max+ 395 (Zen 5, 16 cores / 32 threads)
- **GPU:** Radeon 8060S (RDNA 3.5, gfx1151, ROCm)
- **Memory:** 128 GB unified (64 GB VRAM + 64 GB GTT + 62 GB system RAM at 64/64 BIOS split)
- **KV cache:** q8_0 quantized, 1360 MiB for 131072 context with 4 parallel slots
- **SELinux:** Enforcing on UBI containers. `SecurityLabelDisable=true` only on upstream Debian-based images (qdrant, litellm) and GPU-access containers (ramalama)

## Container images

| Container | Base image | SELinux | Reason |
|-----------|-----------|---------|--------|
| rag-proxy | `localhost/rag-proxy` (from ubi9/python-311) | Enforcing | Pre-built with deps + models |
| rag-watcher | `localhost/rag-watcher` (from ubi10) | Enforcing | Pre-built with deps + models |
| postgres | `sclorg/postgresql-16-c9s` | Enforcing | Red Hat ecosystem |
| qdrant | `qdrant/qdrant` | Disabled | Debian binary triggers SELinux execmem denial on Fedora 43 |
| litellm | `litellm:main-stable` | Disabled | Debian binary triggers SELinux execmem denial on Fedora 43 |
| ramalama | `ramalama/rocm:latest` | Disabled | Requires `/dev/kfd` access for ROCm GPU compute |
| open-webui | `open-webui:v0.8.6` | — | Upstream image |
