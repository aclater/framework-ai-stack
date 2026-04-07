# Configuration Reference

This document enumerates all environment variables used across the framework-ai-stack.

## 1. Global / llm-stack (ragstack.env)

These variables are shared across multiple services and are typically stored in `ragstack.env`.

| Variable | Description | Example |
|----------|-------------|---------|
| `GDRIVE_FOLDER_ID` | Google Drive folder ID to watch for documents | `1a2b3c4d5e6f...` |
| `REPO_SOURCES` | JSON list of Git repositories to ingest | `[{"url":"https://github.com/org/repo","branch":"main"}]` |
| `WEB_SOURCES` | JSON list of web URLs to crawl | `["https://example.com/docs"]` |
| `WATCH_INTERVAL_MINUTES` | Polling interval for source watchers | `15` |
| `DATABASE_URL` | Postgres connection string for LiteLLM state | `postgresql://user:pass@host:5432/litellm` |

## 2. ragpipe

RAG proxy service handling embedding, reranking, grounding, and citations.

| Variable | Description | Default |
|----------|-------------|---------|
| `MODEL_URL` | LLM inference endpoint | `http://localhost:8080` |
| `QDRANT_URL` | Qdrant vector store URL | `http://localhost:6333` |
| `QDRANT_COLLECTION` | Collection name for vector storage | `documents` |
| `RAG_TOP_K` | Number of Qdrant candidates before reranking | `50` |
| `RERANKER_TOP_N` | Final result count after reranking | `10` |
| `DOCSTORE_BACKEND` | docstore backend (`postgres` or `sqlite`) | `postgres` |
| `DOCSTORE_URL` | Postgres connection string for docstore | `postgresql://user:pass@host:5432/docs` |

## 3. ragstuffer

Ingestion service for Drive, git, and web sources.

| Variable | Description | Default |
|----------|-------------|---------|
| `EMBED_URL` | Embedding endpoint | `http://localhost:8090/embed` |
| `CHUNK_SIZE` | Maximum chunk size in tokens | `512` |
| `CHUNK_OVERLAP` | Overlap between chunks | `50` |
| `GDRIVE_FOLDER_ID` | Google Drive folder to watch | (from ragstack.env) |
| `REPO_SOURCES` | JSON list of git repos | (from ragstack.env) |
| `WEB_SOURCES` | JSON list of web URLs | (from ragstack.env) |
| `WATCH_INTERVAL_MINUTES` | Poll interval | (from ragstack.env) |

## 4. llama-vulkan (GPU)

GPU inference configuration for AMD gfx1151 (Ryzen AI Max+ 395).

| Variable | Description | Value |
|----------|-------------|-------|
| `HSA_OVERRIDE_GFX_VERSION` | Override GPU architecture version | `11.5.1` |
| `MIGRAPHX_BATCH_SIZE` | Batch size for MIGraphX | `64` |
| `ORT_MIGRAPHX_MODEL_CACHE_PATH` | Path for MXR model caching | `/var/cache/migraphx` |

**Note:** Use MIGraphXExecutionProvider for AMD ROCm on gfx1151. ROCMExecutionProvider was removed in ONNX Runtime 1.23.

## 5. ragorchestrator

LangGraph agentic orchestration layer.

| Variable | Description | Default |
|----------|-------------|---------|
| `DISABLE_WEB_SEARCH` | Disable web search until TAVILY_API_KEY is configured | `true` |
| `RAGPIPE_URL` | ragpipe service URL | `http://localhost:8090` |

**Note:** Self-RAG should short-circuit on `grounding=general` for performance optimization.

## 6. qdrant

Vector store configuration.

| Variable | Description | Value |
|----------|-------------|-------|
| `QDRANT__SERVICE__HOST` | Qdrant service host for IPv4 binding | `::` |

**Note:** Use `::` for IPv4-only binding. Alternatively use `curl -4` or set `QDRANT__SERVICE__HOST=::` in the quadlet.

---

## Example ragstack.env

```env
# Global / llm-stack
GDRIVE_FOLDER_ID=1a2b3c4d5e6f7g8h9i0j
REPO_SOURCES=[{"url":"https://github.com/org/repo","branch":"main"}]
WEB_SOURCES=["https://example.com/docs"]
WATCH_INTERVAL_MINUTES=15
DATABASE_URL=postgresql://user:pass@localhost:5432/litellm

# ragpipe
MODEL_URL=http://localhost:8080
QDRANT_URL=http://localhost:6333
QDRANT_COLLECTION=documents
RAG_TOP_K=50
RERANKER_TOP_N=10
DOCSTORE_BACKEND=postgres
DOCSTORE_URL=postgresql://user:pass@localhost:5432/docs

# ragstuffer
EMBED_URL=http://localhost:8090/embed
CHUNK_SIZE=512
CHUNK_OVERLAP=50

# llama-vulkan (GPU)
HSA_OVERRIDE_GFX_VERSION=11.5.1
MIGRAPHX_BATCH_SIZE=64
ORT_MIGRAPHX_MODEL_CACHE_PATH=/var/cache/migraphx

# ragorchestrator
DISABLE_WEB_SEARCH=true
RAGPIPE_URL=http://localhost:8090

# qdrant
QDRANT__SERVICE__HOST=::
```
