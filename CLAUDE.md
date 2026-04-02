# framework-ai-stack

Local AI stack on harrison.home.arpa (Ryzen AI Max+ 395, Fedora 43). LLM inference with live RAG from Google Drive, git repos, and web URLs. Corpus-preferring grounding with citation validation.

## Architecture
```
clients → LiteLLM (:4000) → RAG proxy (:8090) → model (:8080)
                                  |
                          Qdrant search (:6333)
                                  |
                          docstore hydration (Postgres :5432)
                                  |
                          reranker (MiniLM-L-6-v2)
                                  |
                          grounding (citation labels + system prompt)
                                  |
                          forward to model → post-process response
                                  |
                          parse citations → validate → classify → audit

rag-watcher (polls Drive, git, web → extract → chunk → embed)
      |                    |
  docstore (Postgres)   Qdrant (reference payloads only)
```

## Key design decisions
- Corpus-preferring grounding: documents are primary source, general knowledge with ⚠️ prefix
- Citations: model cites as [doc_id:chunk_id], parsed and validated post-response
- Response metadata: `rag_metadata.grounding` = corpus | general | mixed
- Qdrant stores vectors + reference payloads only: {doc_id, chunk_id, source, created_at}
- Full chunk text lives in the Postgres document store (chunks table)
- Retrieval: Qdrant search → docstore hydration → reranker → grounding → LLM
- Qdrant collection uses int8 scalar quantization (always_ram for HNSW rescoring)
- doc_id is deterministic UUID5 from source URI — re-ingest is idempotent
- KV cache uses q8_0 quantization (1360 MiB vs 2560 MiB at f16)
- Empty retrieval is not an error — model answers from general knowledge with prefix
- Audit log captures grounding decisions without logging text content

## Endpoints
- LiteLLM proxy: http://localhost:4000 (key: sk-llm-stack-local)
- RAG proxy:     http://localhost:8090 (search + hydrate + rerank + ground + inject)
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
- `RERANKER_MODEL` — cross-encoder model (default: cross-encoder/ms-marco-MiniLM-L-6-v2)
- `RERANKER_DEVICE` — cpu/cuda (default: cpu — GPU segfaults on gfx1151, see ADR-013)
- `RERANKER_TOP_N` — results after reranking (default: 5)
- `RAG_TOP_K` — Qdrant candidates before reranking (default: 20)
- `EMBED_DEVICE` — cpu/cuda (default: cpu — same gfx1151 issue as reranker)
- `THINKING_BUDGET` — token budget for model reasoning (default: 1024)
- `DOCSTORE_BACKEND` — postgres or sqlite (default: postgres)

## Container images
- rag-proxy: localhost/rag-proxy (built from ubi9/python-311, deps + models baked in)
- rag-watcher: localhost/rag-watcher (built from ubi10, deps + models baked in)
- postgres: sclorg/postgresql-16-c9s (LiteLLM state + document store)
- qdrant, litellm, ramalama, open-webui: upstream images

## Documentation
- [Architecture](docs/architecture.md) — system design, data flow, components
- [Grounding](docs/grounding.md) — corpus-preferring grounding spec, citations, audit
- [Operations](docs/operations.md) — deployment, monitoring, troubleshooting
- [ADRs](docs/adr/) — architecture decision records

## Security notes
- LiteLLM: pinned to main-stable (v1.82.3-stable.patch.2). v1.82.7/v1.82.8 compromised. Upgrade to v1.83.0-stable when available. See ADR-009.
- Do NOT set LLAMA_HIP_UMA=1 — forces GTT instead of VRAM. See ADR-010.
- SELinux enforcing on all UBI containers. SecurityLabelDisable only on upstream Debian images + GPU access.
