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

Per-GPU-profile overrides live in `hosts/<profile>/quadlets/` and are overlaid during install. Currently: `hosts/nvidia/` for CUDA systems, `hosts/gfx1151/` for AMD Strix Halo (Vulkan).

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


## Always verify current versions before using them

This is a hard requirement, not a suggestion. Using stale version numbers
wastes time, breaks builds, and has caused real incidents on this stack.

- BEFORE referencing any version number — for a container image, Python
  package, ROCm release, CUDA toolkit, npm package, system package, LLM
  model, or any other software — look it up. Do not use version numbers
  from training knowledge. They are outdated.
- For container images: check the registry (quay.io, ghcr.io,
  registry.access.redhat.com, docker.io) for the current stable tag
  before writing it. Verify the tag exists. Never use :latest in
  production quadlets.
- For Python packages: check PyPI for the current stable release
  before pinning.
- For ROCm: check https://rocm.docs.amd.com and
  https://github.com/RadeonOpenCompute/ROCm/releases for the current
  stable release. ROCm versions change frequently and using an old
  version is a primary cause of GPU acceleration failures on this stack.
- For CUDA: check https://developer.nvidia.com/cuda-downloads for the
  current stable release.
- For npm packages: check https://www.npmjs.com or run
  npm show <package> version.
- For LLM models: check Hugging Face and the model provider directly
  for current releases.
- For system packages (dnf/rpm/apt): do not pin versions unless
  explicitly asked — let the package manager resolve current stable.
- If you cannot verify a version, say so explicitly and ask.
  Do not guess. Do not use what you think the version is.


## GPU acceleration

- This system may have an AMD, NVIDIA, or Intel GPU. All services and
  scripts must detect the available GPU at runtime and select the
  appropriate acceleration stack — do not hardcode a vendor.
- Detection priority: NVIDIA CUDA > AMD ROCm > Intel XPU/OpenVINO > CPU.
  Fall back to CPU only when no GPU is available, and log a clear warning
  when doing so.
- Never default to CPU for any workload that can run on GPU. CPU fallback
  is acceptable only when a specific library or operation has no GPU
  support, and must be explicitly noted in a comment explaining why.
- For Python workloads: use torch.cuda.is_available(), torch.version.hip
  (ROCm), or torch.xpu.is_available() (Intel) to detect and select the
  correct device at runtime. Do not hardcode "cuda", "rocm", or "cpu".
- For ONNX Runtime: select ExecutionProvider based on runtime detection —
  CUDAExecutionProvider, ROCMExecutionProvider, OpenVINOExecutionProvider,
  or CPUExecutionProvider — in that priority order.
- For container workloads:
  - NVIDIA: pass --device /dev/nvidia0 (or --gpus all with
    nvidia-container-toolkit)
  - AMD ROCm: pass --device /dev/kfd --device /dev/dri
  - Intel: pass --device /dev/dri
  - Document any container that cannot use GPU and why.
- AMD ROCm on gfx1151: HSA_OVERRIDE_GFX_VERSION=11.5.1 is required.
  Set this env var in any quadlet, container, or script that uses ROCm
  on this hardware.
- Always verify the current stable ROCm release before using it — see
  "Always verify current versions" above. Using an old ROCm version is
  a primary cause of GPU failures on this stack.
- Do not recommend or implement CPU-only solutions without first
  investigating whether a GPU-accelerated alternative exists for all
  three vendors.
- When benchmarking or profiling, always compare GPU vs CPU and report
  both. Never present CPU-only results as the baseline.
- When writing GPU detection code, always write it once as a shared
  utility function — do not duplicate vendor detection logic across files.


## Repository location

All code, projects, and repositories live exclusively under ~/git/.

- Never clone, create, or initialize a repository anywhere else on this
  system — not in ~/, not in /tmp, not in ~/Documents, or any other path.
- Before cloning or creating any repo, verify the target path is under
  ~/git/. If it is not, stop and correct the path.
- If you find a repository outside ~/git/, do not work in it. Move it
  to ~/git/ first, update any remotes if needed, and confirm the old
  location is removed before proceeding.
- When referencing local repos, always use ~/git/<reponame> as the path.


## User scripts and tools

User scripts and tools live in ~/.local/bin/, not ~/bin/.

- Always install scripts to ~/.local/bin/
- When referencing or running user scripts, always use ~/.local/bin/<script>
- Never create or reference scripts in ~/bin/ — that path is not used on
  this system


## Working directory conventions

All git repositories and working directories must follow this structure:

- `~/git/` — permanent repositories only. Clone repos here when you intend
  to work in them long-term. Never create temporary work here.
- `~/git-work/<task-name>/` — temporary clones for PR work. Create a
  subdirectory named after the task (e.g. ~/git-work/fix-qdrant-ipv6/).
  Clean up after the PR is merged.
- `~/.local/bin/` — user scripts and tools. Never use ~/bin/.
- Never create git-* directories directly in ~/. They clutter the home
  directory and never get cleaned up.

When starting any task that requires cloning repos:
```bash
mkdir -p ~/git-work/
cd ~/git-work/
gh repo clone aclater/
```

When the PR is merged, clean up:
```bash
rm -rf ~/git-work/
```

Or run the cleanup script periodically:
```bash
~/.local/bin/cleanup-git-work.sh --dry-run
~/.local/bin/cleanup-git-work.sh
```


## GitHub issue workflow

Every task must be tracked in GitHub before work begins. This is mandatory.

**Before starting any implementation task:**
1. Check if a GitHub issue exists for the work:
```bash
   gh issue list --repo aclater/ --search ""
```
2. If no issue exists, create one first:
```bash
   gh issue create \
     --repo aclater/ \
     --title "" \
     --body "" \
     --label "priority: ,type: ,agent: "
```
3. Note the issue number before proceeding.

**All commits must reference the issue:**
```
feat(ragpipe): add prometheus metrics endpoint (fixes #14)
fix(ragstuffer): deduplicate cited chunks in streaming path (refs #8)
```

**All PR bodies must include:**
- `Closes #N` — if the PR fully resolves the issue
- `Refs #N` — if the PR partially addresses the issue

**Never start implementation without an issue number.**
This ensures work is discoverable across parallel agent sessions
without requiring conversation history.
