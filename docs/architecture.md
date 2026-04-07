# Architecture

## Overview

framework-ai-stack is a local AI inference platform with live retrieval-augmented generation (RAG). It runs on a single Framework Desktop (AMD Ryzen AI Max+ 395, 128 GB unified memory, Fedora 43) as rootless Podman containers managed by systemd quadlets.

The system serves a Qwen3-32B dense model behind a ragpipe that automatically enriches every query with relevant content from a curated document corpus. Documents are ingested from Google Drive, git repositories, and web URLs without requiring model restarts. An optional ragorchestrator layer adds adaptive complexity classification and Self-RAG for multi-pass retrieval.

## Request flow

```
Client (Claude Code, Open WebUI, curl)
  │
  ▼  :4000
LiteLLM proxy
  │  Routes all aliases (default, reasoning, code, fast)
  ▼  :8095 (optional agentic path)
ragorchestrator
  │  1. Complexity classification (simple/complex/external)
  │  2. Self-RAG adaptive retrieval loop (multi-pass when needed)
  │  3. Web search (when TAVILY_API_KEY configured)
  │  Falls back to direct → ragpipe when DISABLE_WEB_SEARCH=true
  ▼  :8090
ragpipe
  │  1. Embed the user's query
  │  2. Search Qdrant for top-K candidate vectors
  │  3. Batch-hydrate chunk text from the document store
  │  4. Rerank with cross-encoder (MiniLM-L-6-v2)
  │  5. Format top-N chunks with [doc_id:chunk_id] labels
  │  6. Inject corpus-preferring system prompt + context
  │  7. Forward to model
  │  8. Post-process: parse citations, validate, classify grounding
  │  9. Attach rag_metadata, emit audit log
  ▼  :8080
Qwen3-32B dense Q4_K_M (llama-vulkan via Vulkan RADV on gfx1151)
  │  ~19 GB GTT, 32B fully activated parameters per token
  ▼
AMD Ryzen AI Max+ 395 (gfx1151, Vulkan RADV)
```

## Ingestion flow

```
Document sources (Google Drive, git repos, web URLs)
  │
  ▼
ragstuffer (polls every 15 minutes)
  │  1. Download new/modified documents
  │  2. Extract text (PDF, DOCX, PPTX, XLSX, HTML, Markdown)
  │  3. Chunk with RecursiveCharacterTextSplitter
  │  4. Persist chunks to document store (Postgres)
  │  5. Embed with gte-modernbert-base (GPU auto-detect or ragpipe CPU)
  │  6. Upsert reference-only payloads to Qdrant
  ▼
Qdrant (vectors) + Postgres (chunk text)
```

## Components

### LiteLLM proxy (:4000)

OpenAI-compatible API gateway. Routes all model aliases to the ragpipe. Provides a single endpoint for all clients. Backed by Postgres for state persistence.

**Image:** `ghcr.io/berriai/litellm:main-stable`

### ragpipe (:8090)

The core intelligence layer. Intercepts chat completion requests, performs retrieval, reranking, and citation-aware context injection, then post-processes the response with grounding classification and citation validation. Uses raw ONNX Runtime (no fastembed/PyTorch) for both embedding and reranking — ~708 MB RSS, 370ms startup. Docstore hydration uses asyncpg connection pooling with an LRU chunk cache for 55% faster repeated queries.

See [grounding.md](grounding.md) for the full grounding specification. Full configuration reference at [github.com/aclater/ragpipe](https://github.com/aclater/ragpipe).

**Image:** `ghcr.io/aclater/ragpipe` (UBI9/python-311, ONNX models baked in, ~708 MB RSS)

### Qdrant (:6333)

Vector similarity search engine. Stores only reference payloads — no document text. Each point contains `{doc_id, chunk_id, source, created_at}` plus the embedding vector. Uses int8 scalar quantization (quantile 0.99, always_ram) to reduce memory footprint.

See [ADR-002](adr/002-reference-only-indexing.md) for the design rationale.

**Image:** `docker.io/qdrant/qdrant`

### Document store (Postgres :5432)

Stores full chunk text and metadata. Shared with LiteLLM (same Postgres instance, separate table). Keyed on `(doc_id, chunk_id)` with upsert semantics so re-ingestion is idempotent.

The `doc_id` is a deterministic UUID5 derived from the source URI, ensuring the same document always gets the same ID regardless of when it's ingested.

**Image:** `quay.io/sclorg/postgresql-16-c9s`

### llama-vulkan (:8080)

Serves the Qwen3-32B dense model via llama.cpp with Vulkan RADV backend on gfx1151. Dense model — 32B parameters all activated per token, ~19 GB GTT. Thinking mode should be disabled for RAG queries (`/nothink` model alias) to avoid slow chain-of-thought. All model weights and KV cache reside in GTT (system RAM mapped for GPU access) — gfx1151 has no discrete VRAM, this is the intended architecture.

**Image:** `ghcr.io/aclater/llama-vulkan:b8668`

### ragorchestrator (:8095)

LangGraph-based agentic orchestration layer providing adaptive complexity classification and Self-RAG multi-pass retrieval. Classifies each query as simple/complex/external and decides whether to use direct retrieval or run the Self-RAG reflection loop. Short-circuits Self-RAG when ragpipe grounding=general (optimization pending).

`DISABLE_WEB_SEARCH=true` is set by default until `TAVILY_API_KEY` is configured.

**Source:** [github.com/aclater/ragorchestrator](https://github.com/aclater/ragorchestrator)
**Image:** `ghcr.io/aclater/ragorchestrator:main`

### ragstuffer

Polls document sources on a configurable interval (default 15 minutes). Supports three source types:

- **Google Drive** — via service account, tracks file modification times
- **Git repos** — shallow clones with incremental pull, glob-based file filtering
- **Web URLs** — fetches and extracts text from HTML pages

After extraction and chunking, persists to the document store first (ensuring the source of truth is written before vectors), then embeds and upserts reference payloads to Qdrant. Embedding can run via ragpipe's CPU endpoint or directly on GPU via `ingest-remote.py` (auto-detects NVIDIA CUDA, AMD ROCm, Intel XPU).

**Source:** [github.com/aclater/ragstuffer](https://github.com/aclater/ragstuffer)
**Image:** `localhost/ragstuffer` (built from `ubi10`)

### Open WebUI (:3000)

Chat interface. Connects to LiteLLM as its OpenAI backend, so all queries automatically flow through the RAG pipeline.

**Image:** `ghcr.io/open-webui/open-webui:v0.8.12`

## Port map

| Port | Service | Protocol |
|------|---------|----------|
| 3000 | Open WebUI | HTTP |
| 4000 | LiteLLM proxy | HTTP (OpenAI API) |
| 5432 | PostgreSQL | PostgreSQL |
| 6333 | Qdrant | HTTP |
| 8080 | llama-vulkan | HTTP (llama.cpp Vulkan) |
| 8090 | ragpipe | HTTP (OpenAI API) |
| 8091 | ragstuffer | HTTP (admin + metrics) |
| 8093 | ragstuffer-mpep | HTTP (MPEP collection) |
| 8092 | ragdeck | HTTP (admin UI) |
| 8095 | ragorchestrator | HTTP (LangGraph agentic) |
| 9090 | ragwatch | HTTP (Prometheus) |

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
- **GPU:** Radeon 8060S (RDNA 3.5, gfx1151, Vulkan RADV)
- **Memory:** 128 GB unified (512 MB VRAM housekeeping, ~113 GB GTT for model + KV cache)
- **KV cache:** type and size set by auto-tuner (tune.conf)
- **SELinux:** Enforcing on UBI containers. `SecurityLabelDisable=true` only on upstream Debian-based images (qdrant, litellm) and GPU-access containers

## Container images

| Container | Base image | SELinux | Reason |
|-----------|-----------|---------|--------|
| ragpipe | `ghcr.io/aclater/ragpipe` (UBI9/python-311) | Enforcing | Pre-built with deps + models |
| ragorchestrator | `ghcr.io/aclater/ragorchestrator` (UBI10) | Enforcing | LangGraph agentic layer |
| ragstuffer (CPU) | `localhost/ragstuffer` (from ubi10) | Enforcing | CPU-only poller, delegates embedding to ragpipe |
| ragstuffer (ROCm) | `localhost/ragstuffer` (from rocm/pytorch) | Disabled | GPU embedding for AMD (auto-selected by `llm-stack.sh build`) |
| ragstuffer (CUDA) | `localhost/ragstuffer` (from pytorch/pytorch) | Disabled | GPU embedding for NVIDIA (auto-selected by `llm-stack.sh build`) |
| postgres | `quay.io/sclorg/postgresql-16-c9s` | Enforcing | Red Hat ecosystem |
| qdrant | `docker.io/qdrant/qdrant:v1.17.1` | Disabled | Debian binary triggers SELinux execmem denial on Fedora 43 |
| litellm | `ghcr.io/berriai/litellm:main-stable` | Disabled | Debian binary triggers SELinux execmem denial on Fedora 43 |
| llama-vulkan | `ghcr.io/aclater/llama-vulkan:b8668` | Disabled | Vulkan RADV on gfx1151, requires `/dev/kfd` + `/dev/dri` |
| ragwatch | `ghcr.io/aclater/ragwatch:main` | Enforcing | Prometheus aggregation |
| ragdeck | `ghcr.io/aclater/ragdeck:main` | Enforcing | Admin UI |
| open-webui | `ghcr.io/open-webui/open-webui:v0.8.12` | — | Upstream image |
