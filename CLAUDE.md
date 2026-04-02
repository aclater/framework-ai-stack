# framework-ai-stack

Local AI stack on harrison.home.arpa (Ryzen AI Max+ 395, Fedora 43). LLM inference with live RAG from Google Drive, git repos, and web URLs.

## Architecture
```
clients → LiteLLM (:4000) → RAG proxy (:8090) → model (:8080)
                                  |
                          Qdrant search (:6333)
                                  |
                          docstore hydration (Postgres :5432)
                                  |
                          reranker (bge-reranker-v2-m3)
                                  |
                          context injection → model

rag-watcher (polls Drive, git, web → extract → chunk → embed)
      |                    |
  docstore (Postgres)   Qdrant (reference payloads only)
```

## Key design decisions
- Qdrant stores vectors + reference payloads only: {doc_id, chunk_id, source, created_at}
- Full chunk text lives in the Postgres document store (chunks table)
- Retrieval: Qdrant vector search → batch docstore hydration → reranker → LLM
- Qdrant collection uses int8 scalar quantization (always_ram for HNSW rescoring)
- doc_id is deterministic UUID5 from source URI — re-ingest is idempotent
- KV cache uses q8_0 quantization (1360 MiB vs 2560 MiB at f16)

## Endpoints
- LiteLLM proxy: http://localhost:4000 (key: sk-llm-stack-local)
- RAG proxy:     http://localhost:8090 (search + hydrate + rerank + inject)
- Qwen3.5-35B:  http://localhost:8080 (plain model)
- Qdrant:        http://localhost:6333
- Open WebUI:    http://localhost:3000

## Management
```
./llm-stack.sh up/down/restart/status/test
./llm-stack.sh logs <model|proxy|webui>
journalctl --user -u rag-watcher -f
journalctl --user -u rag-proxy -f
journalctl --user -u qdrant -f
```

## Model aliases
All aliases route through RAG proxy → Qwen3.5-35B-A3B on :8080:
- default: general use
- reasoning: multi-step problems, chain-of-thought
- code: completion, debugging, generation
- fast: quick queries, drafting

## RAG document sources
Configured via environment variables in `~/.config/llm-stack/env`:
- `GDRIVE_FOLDER_ID` — Google Drive folder to watch
- `REPO_SOURCES` — JSON list: `[{"url": "https://...", "glob": "**/*.md"}]`
- `WEB_SOURCES` — JSON list: `["https://example.com/docs"]`

## RAG proxy configuration
- `RERANKER_ENABLED` — true/false (default: true)
- `RERANKER_MODEL` — cross-encoder model (default: BAAI/bge-reranker-v2-m3)
- `RERANKER_TOP_N` — results after reranking (default: 5)
- `RAG_TOP_K` — Qdrant candidates before reranking (default: 20)
- `DOCSTORE_BACKEND` — postgres or sqlite (default: postgres)

## Container images
- rag-proxy: ubi9/python-311 (pinned digest, SELinux enforcing)
- rag-watcher: ubi10 base (SELinux enforcing)
- postgres: sclorg/postgresql-16-c9s (LiteLLM state + document store)
- qdrant, litellm, ramalama, open-webui: upstream images
