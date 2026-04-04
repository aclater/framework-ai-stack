# framework-ai-stack

Local AI stack for Fedora 43. LLM inference with live RAG from Google Drive, git repos, and web URLs. Corpus-preferring grounding with citation validation.

## Auto-tuning
`./llm-stack.sh tune` detects hardware and selects optimal parameters:
- GPU vendor + VRAM → model family (35B-A3B for ≥32 GB, 9B for smaller)
- VRAM budget → quantization (Q8 > Q6 > Q4, highest that fits)
- Remaining VRAM → KV cache type (q8_0 if headroom, q4_0 if tight)
- System RAM + VRAM → batch sizes, mlock, context size
- CPU cores → thread count (physical cores, not HT)
- Writes `~/.config/llm-stack/tune.conf`, consumed by `install`
- `retune` re-runs tuning + restart without re-downloading the model
- `setup` calls `tune` automatically on first run

Per-GPU-profile overrides live in `hosts/<profile>/quadlets/` and are overlaid during install. Currently: `hosts/nvidia/` for CUDA systems.

## Architecture
```
clients → LiteLLM (:4000) → ragpipe (:8090) → model (:8080)
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

ragstuffer (polls Drive, git, web → extract → chunk → embed)
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
- KV cache type and model quantization selected by auto-tuner (see tune.conf)
- Empty retrieval is not an error — model answers from general knowledge with prefix
- Audit log captures grounding decisions without logging text content

## Endpoints
- LiteLLM proxy: http://localhost:4000 (key: sk-llm-stack-local)
- ragpipe:     http://localhost:8090 (search + hydrate + rerank + ground + inject)
- Qwen3.5-35B:  http://localhost:8080 (plain model)
- Qdrant:        http://localhost:6333
- Open WebUI:    http://localhost:3000

## Management
```
./llm-stack.sh up/down/restart/status/test
./llm-stack.sh logs <model|proxy|webui>
journalctl --user -u ragstuffer -f
journalctl --user -u ragpipe -f
journalctl --user -u qdrant -f
```

## Model aliases
All aliases route through ragpipe → Qwen3.5-35B-A3B on :8080:
- default: general use
- reasoning: multi-step problems, chain-of-thought
- code: completion, debugging, generation
- fast: quick queries, drafting

## RAG document sources
Configured via environment variables in `~/.config/llm-stack/env`:
- `GDRIVE_FOLDER_ID` — Google Drive folder to watch
- `REPO_SOURCES` — JSON list: `[{"url": "https://...", "glob": "**/*.md"}]`
- `WEB_SOURCES` — JSON list: `["https://example.com/docs"]`

## ragpipe configuration
ragpipe is an external project (github.com/aclater/ragpipe). See its README for the full config reference. Key overrides in the quadlet: `RAG_TOP_K=40`, `RERANKER_TOP_N=15`.

## Container images
- ragpipe: ghcr.io/aclater/ragpipe (UBI9/python-311, ONNX models baked in)
- ragstuffer: localhost/ragstuffer — GPU-aware, auto-selected by `llm-stack.sh build`:
  - CPU: UBI10 (default, delegates embedding to ragpipe)
  - ROCm: rocm/pytorch (AMD GPU embedding via sentence-transformers)
  - CUDA: pytorch/pytorch (NVIDIA GPU embedding via sentence-transformers)
- postgres: sclorg/postgresql-16-c9s (LiteLLM state + document store)
- qdrant, litellm, ramalama, open-webui: upstream images

## Documentation
- [Architecture](docs/architecture.md) — system design, data flow, components
- [Grounding](docs/grounding.md) — corpus-preferring grounding spec, citations, audit
- [Operations](docs/operations.md) — deployment, monitoring, troubleshooting
- [ADRs](docs/adr/) — architecture decision records

## CI / code quality
- **Ruff** (`ruff.toml`) — Python linter + formatter
- **ShellCheck** (`.shellcheckrc`) — shell linter for `llm-stack.sh`, `tests/run-tests.sh`
- **yamllint** — YAML lint for `configs/`
- Python tests, Containerfile lint, and security scans run in the component repos:
  - [ragpipe](https://github.com/aclater/ragpipe) — RAG query proxy
  - [ragstuffer](https://github.com/aclater/ragstuffer) — document ingestion
- Run `bash tests/run-tests.sh` before committing shell/quadlet/config changes

## Security notes
- LiteLLM: pinned to main-stable (v1.82.3-stable.patch.2). v1.82.7/v1.82.8 compromised. Upgrade to v1.83.0-stable when available. See ADR-009.
- Do NOT set LLAMA_HIP_UMA=1 — forces GTT instead of VRAM. See ADR-010.
- SELinux enforcing on all UBI containers. SecurityLabelDisable only on upstream Debian images + GPU access.
