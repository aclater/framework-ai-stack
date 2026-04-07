# framework-ai-stack

Local AI stack for Fedora 43 on the Framework Desktop (Ryzen AI Max+ 395, 128 GB unified memory). Qwen3-32B dense inference (~19 GB GTT) with live RAG — ragstuffer automatically imports documents from Google Drive, git repos, and web URLs into a Qdrant vector database backed by a Postgres document store. A ragpipe searches Qdrant, hydrates chunks from the document store, reranks with a cross-encoder, and injects the most relevant context into every query. Optional ragorchestrator layer adds adaptive complexity classification and Self-RAG multi-pass retrieval. All services run as rootless Podman containers managed by systemd quadlets.

![Architecture](docs/architecture.svg)

## Stack

| Service | Image | Port | Notes |
|---|---|---|---|
| postgres | `quay.io/sclorg/postgresql-16-c9s` | 5432 | LiteLLM state + document store |
| qdrant | `docker.io/qdrant/qdrant:v1.17.1` | 6333 | Vector search (int8 scalar quantization) |
| llama-vulkan | `ghcr.io/aclater/llama-vulkan:b8668` | 8080 | Qwen3-32B Q4_K_M via Vulkan RADV (gfx1151) |
| ragpipe | `ghcr.io/aclater/ragpipe:main-rocm` | 8090 | Search → hydrate → rerank → ground → cite → inject |
| ragorchestrator | `ghcr.io/aclater/ragorchestrator:main` | 8095 | LangGraph agentic layer (Self-RAG, complexity classification) |
| litellm | `ghcr.io/berriai/litellm:main-stable` | 4000 | OpenAI-compatible proxy |
| open-webui | `ghcr.io/open-webui/open-webui:v0.8.12` | 3000 | Chat UI, pinned to v0.8.12 |
| ragstuffer | `ghcr.io/aclater/ragstuffer:main` | 8091 | Admin API (ingest trigger, metrics) |
| ragstuffer-mpep | `ghcr.io/aclater/ragstuffer:main` | 8093 | USPTO/MPEP patent ingestion |
| ragwatch | `ghcr.io/aclater/ragwatch:main` | 9090 | Prometheus aggregation + /metrics/summary JSON |
| ragdeck | `ghcr.io/aclater/ragdeck:main` | 8092 | Admin UI |

## Hardware requirements

- **GPU**: AMD Ryzen AI Max+ 395 (gfx1151) with ROCm 7.x
- **Required env**: `HSA_OVERRIDE_GFX_VERSION=11.5.1`
- **UMA frame buffer**: BIOS set to auto — 125 GB GTT available (128 GB unified memory)
- **⚠️ Cold start**: ragpipe takes ~3:53 on first boot while ONNX models compile. Warm start (MXR cached): ~6 seconds (39x improvement)

## Quick start

```bash
git clone https://github.com/aclater/framework-ai-stack
cd framework-ai-stack
chmod +x llm-stack.sh
mkdir -p ~/.config/llm-stack
cp ragstack.env.example ~/.config/llm-stack/ragstack.env
# Edit ragstack.env with real passwords and tokens

./llm-stack.sh deps && ./llm-stack.sh groups && ./llm-stack.sh setup
./llm-stack.sh pull-image && ./llm-stack.sh pull-models
./llm-stack.sh build && ./llm-stack.sh install && ./llm-stack.sh up

# Verify
curl http://localhost:8090/health
curl http://localhost:4000/health
```

## Documentation

| Doc | Description |
|-----|-------------|
| [docs/getting-started.md](docs/getting-started.md) | First-time setup, service URLs, management commands |
| [docs/architecture.md](docs/architecture.md) | System design, request/ingestion flows, components, port map |
| [docs/operations.md](docs/operations.md) | Deployment, monitoring, container updates, model swap, troubleshooting |
| [docs/configuration.md](docs/configuration.md) | All environment variables with defaults |
| [docs/grounding.md](docs/grounding.md) | Corpus-preferring grounding rules, citation format, metadata schema |
| [docs/gpu.md](docs/gpu.md) | gfx1151 specifics, GTT memory model, Vulkan vs ROCm, HSA_OVERRIDE |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Cold start, Qdrant IPv4, SELinux, stale images, LiteLLM supply chain |
| [docs/claude-integration.md](docs/claude-integration.md) | LiteLLM proxy at :4000, model aliases, ragorchestrator with Claude Code |
| [docs/adr/README.md](docs/adr/README.md) | ADR index with 14 architecture decision records |

## License

AGPL-3.0-or-later
