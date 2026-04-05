# framework-ai-stack

Local AI stack for Fedora 43 on the Framework Desktop (Ryzen AI Max+ 395, 128 GB unified memory). Qwen3.5-35B-A3B inference with live RAG — ragstuffer automatically imports documents from Google Drive, git repos, and web URLs into a Qdrant vector database backed by a Postgres document store. A ragpipe searches Qdrant, hydrates chunks from the document store, reranks with a cross-encoder, and injects the most relevant context into every query. All services run as rootless Podman containers managed by systemd quadlets.

![Architecture](architecture.svg)

## Stack

| Service | Image | Port | Notes |
|---|---|---|---|
| postgres | `quay.io/sclorg/postgresql-16-c9s` | 5432 | LiteLLM state + document store |
| qdrant | `docker.io/qdrant/qdrant:v1.17.1` | 6333 | Vector search (int8 scalar quantization) |
| ramalama | `quay.io/ramalama/rocm:latest` | 8080 | Qwen3.5 (model + quant selected by auto-tuner) |
| ragpipe | `ghcr.io/aclater/ragpipe:main-rocm` | 8090 | Search → hydrate → rerank → ground → cite → inject |
| litellm | `ghcr.io/berriai/litellm:main-stable` | 4000 | OpenAI-compatible proxy |
| open-webui | `ghcr.io/open-webui/open-webui:v0.8.12` | 3000 | Chat UI, pinned to v0.8.12 |
| ragstuffer | `localhost/ragstuffer:main` | 8091 | Admin API (ingest trigger, metrics) |
| ragstuffer-mpep | `localhost/ragstuffer:main` | 8093 | USPTO/MPEP patent ingestion |
| ragwatch | `localhost/ragwatch:main` | 9090 | Prometheus aggregation + /metrics/summary JSON |

Models are pulled and managed by [RamaLama](https://github.com/containers/ramalama). LiteLLM routes all aliases through the ragpipe. The proxy searches Qdrant for candidate vectors (reference payloads only — no text stored in Qdrant), hydrates chunk text from the Postgres document store, reranks with cross-encoder/ms-marco-MiniLM-L-6-v2, and injects the top results as context before forwarding to the model. Documents from Google Drive, git repos, and web URLs are automatically ingested — no model restart required.

### GPU requirements

- **GPU**: AMD Ryzen AI Max+ 395 (gfx1151) with ROCm 7.x
- **Required env**: `HSA_OVERRIDE_GFX_VERSION=11.5.1`
- **GPU provider**: MIGraphXExecutionProvider only — ROCMExecutionProvider is ABI-incompatible with ROCm 7.x
- **⚠️ Startup time**: ragpipe takes ~3 minutes on first query after startup while MIGraphX compiles the inference graph. Plan restarts accordingly.

## Prerequisites

- Fedora 43
- AMD Ryzen AI Max+ 395 (gfx1151) or similar AMD iGPU/dGPU with ROCm support
- ~25 GB free disk space for the model
- **BIOS: UMA frame buffer set to 64 GB — model size depends on auto-tuner selection — run tune to optimize**

## First-time setup

```bash
git clone https://github.com/aclater/framework-ai-stack
cd framework-ai-stack
chmod +x llm-stack.sh

# Configure credentials — copy the example and fill in real values
mkdir -p ~/.config/llm-stack
cp ragstack.env.example ~/.config/llm-stack/ragstack.env
# Edit ragstack.env with real passwords and tokens before starting services

./llm-stack.sh deps          # install system packages (sudo)
./llm-stack.sh groups        # add user to render/video groups
./llm-stack.sh setup         # verify GPU, configure dirs
./llm-stack.sh pull-image    # pull the RamaLama ROCm container image
./llm-stack.sh pull-models   # download model (size depends on tune)
./llm-stack.sh build         # build ragpipe (from ~/git/ragpipe) and ragstuffer images
./llm-stack.sh install       # install quadlets to systemd + fix SELinux labels
./llm-stack.sh up            # start everything

# Optional: set up ragstuffer for Google Drive polling
./ragstuffer/setup.sh       # interactive setup for Drive polling
```

## Usage

```
./llm-stack.sh <command>

  deps            install system packages via dnf
  groups          add user to render/video groups
  setup           verify GPU, configure dirs
  pull-image      pull RamaLama ROCm image (with registry fallback)
  pull-models     download model
  install         install quadlets + enable on boot
  up              start all services
  down            stop all services
  restart         restart all services
  status          show unit states
  test            smoke-test inference
  logs <service>  follow logs  (model|proxy|webui)
  swap <model>    hot-swap the model
  uninstall       remove quadlets (models kept)
```

## Configuration

### System prompt (hot-reloadable)

The ragpipe system prompt controls how the model cites documents and when it falls back to general knowledge. It is mounted from the host at runtime — no image rebuild required.

- **Location**: `~/.config/ragpipe/system-prompt.txt`
- **First install**: automatically copied from `config/ragpipe/system-prompt.txt` during `./llm-stack.sh setup`
- **Hot reload without restart**:
  ```bash
  curl -X POST http://localhost:8090/admin/reload-prompt \
    -H "Authorization: Bearer $RAGPIPE_ADMIN_TOKEN"
  ```

For the grounding rules this implements, see [Grounding](docs/grounding.md).

### Routes (hot-reloadable)

Semantic routing configuration. Mounted from the host at runtime.

- **Location**: `~/.config/ragpipe/routes.yaml`
- **Hot reload without restart**:
  ```bash
  curl -X POST http://localhost:8090/admin/reload-routes \
    -H "Authorization: Bearer $RAGPIPE_ADMIN_TOKEN"
  ```

### Environment variables for ragstuffer

Configured in `~/.config/llm-stack/ragstack.env`:

```bash
GDRIVE_FOLDER_ID=your-folder-id
REPO_SOURCES=[{"url": "https://github.com/org/repo", "glob": "**/*.md"}]
WEB_SOURCES=["https://example.com/docs"]
```

## Claude Code integration

Point Claude Code at the LiteLLM proxy:

```bash
export OPENAI_API_BASE=http://localhost:4000
export OPENAI_API_KEY=sk-llm-stack-local
```

Available model aliases (all route to Qwen3.5-35B-A3B on :8080):

| Alias | Use case |
|---|---|
| `default` | General use |
| `reasoning` | Multi-step problems, chain-of-thought |
| `code` | Completion, debugging, generation |
| `fast` | Quick queries, drafting |

## Health checks

All services expose health endpoints:

```bash
curl http://localhost:8090/health   # ragpipe
curl http://localhost:8091/health   # ragstuffer (documents collection)
curl http://localhost:8093/health   # ragstuffer-mpep (mpep collection)
curl http://localhost:9090/health   # ragwatch (returns "degraded" if upstream is down)
curl http://localhost:4000/health   # litellm
curl http://localhost:6333/readyz   # qdrant
```

## Observability

### Prometheus metrics

```bash
# ragpipe metrics
curl http://localhost:8090/metrics

# ragstuffer metrics
curl http://localhost:8091/metrics
# ragstuffer-mpep metrics
curl http://localhost:8093/metrics

# ragwatch aggregated metrics
curl http://localhost:9090/metrics
```

### ragwatch /metrics/summary

```bash
curl http://localhost:9090/metrics/summary | python3 -m json.tool
```

Returns JSON with parsed metrics from both ragpipe and ragstuffer.

## CI / code quality

GitHub Actions run on every push and PR:

| Workflow | Tools | What it checks |
|----------|-------|----------------|
| [CI](.github/workflows/ci.yml) | Ruff, ShellCheck, yamllint, pytest | Python lint + format, shell lint, YAML lint, unit tests |
| [Containerfile lint](.github/workflows/container.yml) | Hadolint | Containerfile best practices |
| [Security scan](.github/workflows/security.yml) | pip-audit | Known vulnerabilities in Python dependencies |

Run locally:

```bash
ruff check && ruff format --check   # Python lint + format
# ragpipe tests: cd ~/git/ragpipe && python -m pytest -v
cd ~/git-work/docs-audit/ragstuffer && python -m pytest -v # ragstuffer tests
bash tests/run-tests.sh             # shell tests
```

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/architecture.md) | System design, data flow, component responsibilities, port map |
| [Grounding](docs/grounding.md) | Corpus-preferring grounding rules, citation format, metadata schema, audit log |
| [Operations](docs/operations.md) | Deployment, monitoring, troubleshooting, adding document sources, configuration reference |

### Architecture Decision Records

**Infrastructure**

| ADR | Decision |
|-----|----------|
| [005](docs/adr/005-podman-quadlets-over-docker-compose.md) | Rootless Podman quadlets over docker-compose |
| [006](docs/adr/006-llamacpp-rocm-over-vllm.md) | llama.cpp/ROCm as inference backend over vLLM |
| [004](docs/adr/004-ubi-container-strategy.md) | UBI container base images with SELinux enforcing |
| [010](docs/adr/010-uma-memory-configuration.md) | Unified memory configuration — remove LLAMA\_HIP\_UMA=1 |
| [011](docs/adr/011-selinux-securitylabeldisable-workaround.md) | SecurityLabelDisable=true as targeted workaround |

**Model and proxy**

| ADR | Decision |
|-----|----------|
| [012](docs/adr/012-model-selection-qwen35-35b-a3b.md) | Qwen3.5-35B-A3B as primary inference model |
| [007](docs/adr/007-single-model-tier.md) | Single model tier replacing three specialized tiers |
| [008](docs/adr/008-litellm-postgres-retained.md) | Retain LiteLLM proxy with PostgreSQL backend |
| [009](docs/adr/009-litellm-supply-chain-pin.md) | Pin LiteLLM to main-stable after supply chain incident |

**RAG pipeline**

| ADR | Decision |
|-----|----------|
| [001](docs/adr/001-live-qdrant-over-oci-images.md) | Live Qdrant over ramalama rag OCI images |
| [002](docs/adr/002-reference-only-indexing.md) | Reference-only indexing — vectors in Qdrant, text in Postgres |
| [003](docs/adr/003-corpus-preferring-grounding.md) | Corpus-preferring grounding with transparent fallback |
| [013](docs/adr/013-lightweight-cpu-reranker.md) | CPU-only sentence-transformers on gfx1151 (embedder + reranker) |

## Known issues

1. **MIGraphX startup (~3 min):** ragpipe takes ~3 minutes on the first query after startup while MIGraphX compiles the inference graph. This is expected behavior. Do not restart ragpipe in production unless critical.

2. **gfx1151 ROCm compatibility:** MIGraphX is the only supported AMD GPU provider on ROCm 7.x. ROCMExecutionProvider fails with ABI errors. Do not attempt to use it.

3. **Reranker on CPU:** The cross-encoder reranker (MiniLM-L-6-v2) runs on CPU because MIGraphX fails at inference for this model. This is not a bug — the reranker is small (87 MB) and fast enough on CPU (~10ms for 40 candidates).

4. **LiteLLM supply chain:** LiteLLM is pinned to `main-stable` after a supply chain incident. See ADR-009. Do not upgrade without verifying the release is clean.

5. **UMA frame buffer:** BIOS must have UMA frame buffer set to 64 GB for the model to fit in unified memory. Without this, the model will not load.

## Acknowledgements

Document loading patterns (git shallow clone with incremental pull, web extraction, chunking with source attribution) are adapted from the [Red Hat Validated Patterns vector-embedder](https://github.com/validatedpatterns-sandbox/vector-embedder).

## License

AGPL-3.0-or-later
