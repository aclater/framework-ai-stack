# llm-stack

Local LLM inference stack for Fedora 43 on the Framework Desktop (Ryzen AI Max+ 395, 128 GB unified memory). Three inference tiers routed through a LiteLLM proxy, all running as rootless Podman containers managed by systemd quadlets.

![Architecture](architecture.svg)

## Stack

| Tier | Model | Size | Port |
|---|---|---|---|
| Reasoning | QwQ-32B Q4\_K\_M | 19 GB | 8080 |
| Code | Qwen2.5-Coder-32B Q4\_K\_M | 19 GB | 8081 |
| Fast / embed | Qwen2.5-14B Q4\_K\_M | 9 GB | 8082 |

All inference containers use the upstream llama.cpp ROCm image (`ghcr.io/ggml-org/llama.cpp:full-rocm`). Models are pulled and managed by [RamaLama](https://github.com/containers/ramalama). LiteLLM provides a single OpenAI-compatible endpoint at `:4000` that routes across all tiers.

## Prerequisites

- Fedora 43
- AMD Ryzen AI Max+ 395 (gfx1151) or similar AMD iGPU/dGPU with ROCm support
- ~55 GB free disk space for models

## First-time setup

```bash
git clone https://github.com/<you>/llm-stack
cd llm-stack
chmod +x llm-stack.sh

./llm-stack.sh deps          # install system packages (sudo)
./llm-stack.sh groups        # add user to render/video (sudo + reboot)
./llm-stack.sh setup         # verify GPU, write configs
./llm-stack.sh pull-image    # pull the RamaLama ROCm container image
./llm-stack.sh pull-models   # download all models (~50 GB)
./llm-stack.sh install       # install quadlets to systemd
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
| `embed` | nomic-embed-text on :8082 |

## Hardware notes

**gfx1151 (AI Max+ 395):** ROCm 6.4.x in Fedora 43 has known page-fault issues on gfx1151. `HSA_OVERRIDE_GFX_VERSION=11.5.1` is set automatically by `./llm-stack.sh setup`. A fix is expected in ROCm 7.x (Fedora 44). If you hit errors, check `./llm-stack.sh logs reasoning`.

**Unified memory:** `LLAMA_HIP_UMA=1` is set in all inference containers, which tells llama.cpp to treat the 128 GB unified pool as one flat allocation space rather than staging copies between system RAM and "VRAM."

**quay.io outages:** `pull-image` automatically falls back to `ghcr.io/ggml-org/llama.cpp:full-rocm` if quay.io is unreachable. quay.io status: https://status.redhat.com

## Security note

LiteLLM is pinned to `v1.82.6` — the last version audited clean following the [March 2026 supply chain incident](https://docs.litellm.ai/blog/security-update-march-2026) in which versions 1.82.7 and 1.82.8 were compromised. Do not upgrade without reviewing the security advisory.

## AIMI (Chatterbox Labs / Red Hat)

A stub service slot is reserved for the [AIMI](https://www.redhat.com/en/about/press-releases/red-hat-accelerates-ai-trust-and-security-chatterbox-labs-acquisition) guardrails platform once it becomes available via Red Hat channels. See the commented block in `quadlets/litellm.container`.

## License

MIT
