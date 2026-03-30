# llm-stack

Local LLM inference stack for Fedora 43 on the Framework Desktop (Ryzen AI Max+ 395, 128 GB unified memory). Three inference tiers routed through a LiteLLM proxy, all running as rootless Podman containers managed by systemd quadlets.

![Architecture](architecture.svg)

## Stack

| Service | Image | Port | Notes |
|---|---|---|---|
| postgres | `postgres:16-alpine` | 5432 | Backing store for LiteLLM |
| litellm | `ghcr.io/berriai/litellm:main-stable` | 4000 | OpenAI-compatible proxy (v1.82.3-stable.patch.2) |
| ramalama-reasoning | `quay.io/ramalama/rocm:latest` | 8080 | QwQ-32B Q4\_K\_M (19 GB) |
| ramalama-code | `quay.io/ramalama/rocm:latest` | 8081 | Qwen2.5-Coder-32B Q4\_K\_M (19 GB) |
| ramalama-fast | `quay.io/ramalama/rocm:latest` | 8082 | Qwen2.5-14B Q4\_K\_M (9 GB), `--embeddings --pooling mean` |
| open-webui | `ghcr.io/open-webui/open-webui:v0.8.6` | 3000 | Chat UI, pinned to v0.8.6 |

Models are pulled and managed by [RamaLama](https://github.com/containers/ramalama). LiteLLM provides a single OpenAI-compatible endpoint at `:4000` that routes across all tiers.

## Prerequisites

- Fedora 43
- AMD Ryzen AI Max+ 395 (gfx1151) or similar AMD iGPU/dGPU with ROCm support
- ~55 GB free disk space for models
- **BIOS: UMA frame buffer must be set to full unified (not split 50/50) — GPU needs ~98 GB visibility**

## First-time setup

```bash
git clone https://github.com/aclater/llm-stack-final
cd llm-stack-final
chmod +x llm-stack.sh

./llm-stack.sh deps          # install system packages (sudo)
./llm-stack.sh groups        # add user to render/video (sudo + reboot)
./llm-stack.sh setup         # verify GPU, write configs
./llm-stack.sh pull-image    # pull the RamaLama ROCm container image
./llm-stack.sh pull-models   # download all models (~50 GB)
./llm-stack.sh install       # install quadlets to systemd + fix SELinux labels
./llm-stack.sh up            # start everything
```

## Usage

```
./llm-stack.sh <command>

  deps            install system packages via dnf
  groups          add user to render/video groups
  setup           verify GPU, configure dirs
  pull-image      pull RamaLama ROCm image (with registry fallback)
  pull-models     download all models
  install         install quadlets + enable on boot
  up              start all services
  down            stop all services
  restart         restart all services
  status          show unit states
  test            smoke-test all inference tiers
  logs <tier>     follow logs  (reasoning|code|fast|proxy|webui)
  swap <tier> <model>   hot-swap a model
  uninstall       remove quadlets (models kept)
```

## Claude Code integration

Point Claude Code at the LiteLLM proxy:

```bash
export OPENAI_API_BASE=http://localhost:4000
export OPENAI_API_KEY=sk-llm-stack-local
```

Available model aliases:

| Alias | Routes to |
|---|---|
| `reasoning` | QwQ-32B on :8080 |
| `code` | Qwen2.5-Coder-32B on :8081 |
| `fast` | Qwen2.5-14B on :8082 |
| `embed` | Qwen2.5-14B on :8082 (mean pooling) |

## Hardware notes

**gfx1151 (AI Max+ 395):** ROCm 6.4.x in Fedora 43 has known page-fault issues on gfx1151. `HSA_OVERRIDE_GFX_VERSION=11.5.1` is set automatically by `./llm-stack.sh setup`. A fix is expected in ROCm 7.x (Fedora 44). If you hit errors, check `./llm-stack.sh logs reasoning`.

**Unified memory:** `LLAMA_HIP_UMA=1` is set in all inference containers, which tells llama.cpp to treat the 128 GB unified pool as one flat allocation space rather than staging copies between system RAM and "VRAM."

**SELinux:** All ramalama quadlets require `SecurityLabelDisable=true` because SELinux blocks `/dev/kfd` access in the user systemd context. `cmd_install` automatically runs `chcon -t container_ro_file_t -l s0` on all `.gguf` model files.

**quay.io outages:** `pull-image` automatically falls back to `ghcr.io/ggml-org/llama.cpp:full-rocm` if quay.io is unreachable. quay.io status: https://status.redhat.com

## Implementation notes

**LiteLLM** uses `main-stable` (currently v1.82.3-stable.patch.2), backed by postgres:16-alpine. It is not pinned to a specific version tag.

**Open WebUI** is pinned to v0.8.6. It uses `DATABASE_URL=sqlite:////app/backend/data/webui.db` (not the postgres instance — that's for LiteLLM). It runs on port 3000 via `PORT=3000` because `Network=host` would otherwise conflict with ramalama-reasoning on :8080.

**Environment variables:** `OPENAI_API_KEY` and all shared secrets live in `env.example` / `~/.config/llm-stack/env`. Systemd does not expand `EnvironmentFile` vars inside `Environment=` lines, so all vars that need cross-referencing must be set directly in the env file.

**Embeddings:** ramalama-fast serves embeddings via `--embeddings --pooling mean`. Note that LiteLLM sends `encoding_format: null` to llama.cpp by default, which crashes it — the smoke test passes `encoding_format: "float"` explicitly.

## AIMI (Chatterbox Labs / Red Hat)

A stub service slot is reserved for the [AIMI](https://www.redhat.com/en/about/press-releases/red-hat-accelerates-ai-trust-and-security-chatterbox-labs-acquisition) guardrails platform once it becomes available via Red Hat channels. See the commented block in `configs/litellm-config.yaml`.

## License

MIT
