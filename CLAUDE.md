# framework-ai-stack

Local AI stack for Fedora 43. LLM inference with live RAG from Google Drive, git repos, and web URLs. Corpus-preferring grounding with citation validation.

## Stack services and ports

| Service | Port | Image | Notes |
|---------|------|-------|-------|
| open-webui | 3000 | ghcr.io/open-webui/open-webui:v0.8.12 | Chat UI |
| litellm | 4000 | ghcr.io/berriai/litellm:main-stable | OpenAI-compatible proxy |
| ragpipe | 8090 | ghcr.io/aclater/ragpipe:main-rocm | RAG proxy + semantic routing |
| ragstuffer | 8091 | localhost/ragstuffer:main | Document ingestion |
| ragwatch | 9090 | localhost/ragwatch:main | Prometheus aggregation |
| ragdeck | 8095 | localhost/ragdeck:main | Admin UI (scaffold) |
| ramalama | 8080 | quay.io/ramalama/rocm:latest | Qwen3.5-35B-A3B |
| qdrant | 6333 | docker.io/qdrant/qdrant:v1.17.1 | Vector search |
| postgres | 5432 | quay.io/sclorg/postgresql-16-c9s | Document store + LiteLLM state |

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
clients → LiteLLM (:4000) → ragpipe (:8090) → ramalama (:8080)
                                  │
                          Qdrant search (:6333)
                                  │
                          docstore hydration (Postgres :5432)
                                  │
                          reranker (MiniLM-L-6-v2, CPU)
                                  │
                          grounding (citation labels + system prompt)
                                  │
                          forward to model → post-process response
                                  │
                          parse citations → validate → classify → audit

ragstuffer (polls Drive, git, web → extract → chunk → embed)
      │
      ├→ docstore (Postgres :5432) — chunks + titles
      └→ Qdrant (:6333) — vectors + reference payloads

ragwatch (:9090) — scrapes ragpipe (:8090/metrics) + ragstuffer (:8091/metrics)
```

## Key design decisions
- Corpus-preferring grounding: documents are primary source, general knowledge with ⚠️ prefix
- Citations: model cites as [doc_id:chunk_id], parsed and validated post-response
- Response metadata: `rag_metadata.grounding` = corpus | general | mixed
- Qdrant stores vectors + reference payloads only: {doc_id, chunk_id, source, title, created_at}
- Full chunk text lives in the Postgres document store (chunks table)
- Titles extracted per source type, surfaced in rag_metadata.cited_chunks[].title
- Retrieval: Qdrant search → docstore hydration → reranker → grounding → LLM
- Qdrant collection uses int8 scalar quantization (always_ram for HNSW rescoring)
- doc_id is deterministic UUID5 from source URI — re-ingest is idempotent
- KV cache type and model quantization selected by auto-tuner (see tune.conf)
- Empty retrieval is not an error — model answers from general knowledge with prefix
- Audit log captures grounding decisions without logging text content
- MIGraphX for AMD GPU inference (gfx1151 only) — ~3 min startup
- Reranker runs on CPU (MiniLM-L-6-v2 fails on MIGraphX at inference)

## Endpoints
- LiteLLM proxy: http://localhost:4000 (key: sk-llm-stack-local)
- ragpipe:     http://localhost:8090 (search + hydrate + rerank + ground + inject)
- ramalama:     http://localhost:8080 (plain model)
- Qdrant:        http://localhost:6333
- Open WebUI:    http://localhost:3000
- ragwatch:      http://localhost:9090 (metrics + /metrics/summary)
- ragstuffer:    http://localhost:8091 (admin + metrics)

## Health checks

```bash
curl http://localhost:8090/health   # ragpipe
curl http://localhost:8091/health   # ragstuffer
curl http://localhost:9090/health   # ragwatch (degraded if upstream down)
curl http://localhost:4000/health   # litellm
curl http://localhost:6333/readyz   # qdrant
```

## Management
```
./llm-stack.sh up/down/restart/status/test
./llm-stack.sh logs <model|proxy|webui>
journalctl --user -u ragpipe -f
journalctl --user -u ragstuffer -f
journalctl --user -u ragwatch -f
journalctl --user -u qdrant -f
```

## Model aliases
All aliases route through ragpipe → Qwen3.5-35B-A3B on :8080:
- default: general use
- reasoning: multi-step problems, chain-of-thought
- code: completion, debugging, generation
- fast: quick queries, drafting

## Configuration mounts (hot-reloadable)

System prompt and routes are mounted from the host — no rebuild needed:
- `~/.config/ragpipe/system-prompt.txt` — hot-reload via `POST /admin/reload-prompt`
- `~/.config/ragpipe/routes.yaml` — hot-reload via `POST /admin/reload-routes`

RAG document sources configured in `~/.config/llm-stack/ragstack.env`:
- `GDRIVE_FOLDER_ID` — Google Drive folder to watch
- `REPO_SOURCES` — JSON list: `[{"url": "https://...", "glob": "**/*.md"}]`
- `WEB_SOURCES` — JSON list: `["https://example.com/docs"]`

## GPU requirements (MIGraphX on gfx1151)

- ROCm 7.x required
- `HSA_OVERRIDE_GFX_VERSION=11.5.1` required for gfx1151
- MIGraphXExecutionProvider only — ROCMExecutionProvider is ABI-incompatible with ROCm 7.x
- **⚠️ ~3 minute startup**: MIGraphX compiles the inference graph at first query
- Reranker (MiniLM-L-6-v2) runs on CPU — this is expected, not a bug

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
- Run `bash tests/run-tests.sh` before committing shell/quadlet/config changes

## Security notes
- LiteLLM: pinned to main-stable after supply chain incident. See ADR-009.
- Do NOT set LLAMA_HIP_UMA=1 — forces GTT instead of VRAM. See ADR-010.
- SELinux enforcing on all UBI containers. SecurityLabelDisable only on upstream Debian images + GPU access.
