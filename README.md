# framework-ai-stack

Local AI stack for Fedora 43 on the Framework Desktop (Ryzen AI Max+ 395, 128 GB unified memory). Qwen3.5-35B-A3B inference with live RAG — a watcher automatically imports documents from Google Drive, git repos, and web URLs into a Qdrant vector database backed by a Postgres document store. A RAG proxy searches Qdrant, hydrates chunks from the document store, reranks with a cross-encoder, and injects the most relevant context into every query. All services run as rootless Podman containers managed by systemd quadlets.

![Architecture](architecture.svg)

## Stack

| Service | Image | Port | Notes |
|---|---|---|---|
| postgres | `quay.io/sclorg/postgresql-16-c9s` | 5432 | LiteLLM state + document store |
| qdrant | `docker.io/qdrant/qdrant` | 6333 | Vector search (int8 scalar quantization) |
| ramalama | `quay.io/ramalama/rocm:latest` | 8080 | Qwen3.5-35B-A3B UD-Q4\_K\_XL (~22 GB, q8\_0 KV cache) |
| rag-proxy | `ubi9/python-311` (pinned digest) | 8090 | Search → hydrate → rerank → ground → cite → inject |
| litellm | `ghcr.io/berriai/litellm:main-stable` | 4000 | OpenAI-compatible proxy |
| open-webui | `ghcr.io/open-webui/open-webui:v0.8.6` | 3000 | Chat UI, pinned to v0.8.6 |
| rag-watcher | `ubi10` | — | Ingests from Drive, git repos, and web URLs into docstore + Qdrant |

Models are pulled and managed by [RamaLama](https://github.com/containers/ramalama). LiteLLM routes all aliases through the RAG proxy. The proxy searches Qdrant for candidate vectors (reference payloads only — no text stored in Qdrant), hydrates chunk text from the Postgres document store, reranks with BAAI/bge-reranker-v2-m3, and injects the top results as context before forwarding to the model. Documents from Google Drive, git repos, and web URLs are automatically ingested — no model restart required.

## Prerequisites

- Fedora 43
- AMD Ryzen AI Max+ 395 (gfx1151) or similar AMD iGPU/dGPU with ROCm support
- ~25 GB free disk space for the model
- **BIOS: UMA frame buffer set to 64 GB — model uses ~22 GB VRAM, leaving ~42 GB VRAM headroom for KV cache and ~62 GB system RAM**

## First-time setup

```bash
git clone https://github.com/aclater/framework-ai-stack
cd framework-ai-stack
chmod +x llm-stack.sh

./llm-stack.sh deps          # install system packages (sudo)
./llm-stack.sh groups        # add user to render/video (sudo + reboot)
./llm-stack.sh setup         # verify GPU, write configs
./llm-stack.sh pull-image    # pull the RamaLama ROCm container image
./llm-stack.sh pull-models   # download model (~22 GB)
./llm-stack.sh install       # install quadlets to systemd + fix SELinux labels
./llm-stack.sh up            # start everything

# Optional: set up the Google Drive RAG watcher
./rag-watcher/setup.sh       # interactive setup for Drive polling
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
| [004](docs/adr/004-ubi-container-strategy.md) | UBI container base images with SELinux enforcing |
| [006](docs/adr/006-llamacpp-rocm-over-vllm.md) | llama.cpp/ROCm as inference backend over vLLM |
| [010](docs/adr/010-uma-memory-configuration.md) | Unified memory configuration — remove LLAMA\_HIP\_UMA=1 |

**RAG pipeline**

| ADR | Decision |
|-----|----------|
| [001](docs/adr/001-live-qdrant-over-oci-images.md) | Live Qdrant over ramalama rag OCI images |
| [002](docs/adr/002-reference-only-indexing.md) | Reference-only indexing — vectors in Qdrant, text in Postgres |
| [003](docs/adr/003-corpus-preferring-grounding.md) | Corpus-preferring grounding with transparent fallback |

## Acknowledgements

Document loading patterns (git shallow clone with incremental pull, web extraction, chunking with source attribution) are adapted from the [Red Hat Validated Patterns vector-embedder](https://github.com/validatedpatterns-sandbox/vector-embedder).

## License

MIT
