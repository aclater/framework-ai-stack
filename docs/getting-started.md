# Getting Started — framework-ai-stack

First-time setup for the framework-ai-stack on Fedora 43 with AMD Ryzen AI Max+ 395 (gfx1151).

## Hardware prerequisites

- AMD Ryzen AI Max+ 395 (gfx1151)
- BIOS: UMA frame buffer set to auto (125 GB GTT available)
- ~25 GB free disk space for Qwen3-32B Q4_K_M model (~19 GB)
- ~90 GB GTT free for services + KV cache

## Prerequisites

- Fedora 43
- AMD Ryzen AI Max+ 395 (gfx1151) or similar AMD iGPU/dGPU with ROCm support
- ~25 GB free disk space
- BIOS: UMA frame buffer set to auto

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
./llm-stack.sh pull-image    # pull the llama-vulkan container image
./llm-stack.sh pull-models   # download model (size depends on tune)
./llm-stack.sh build         # build ragpipe (from ~/git/ragpipe) and ragstuffer images
./llm-stack.sh install       # install quadlets to systemd + fix SELinux labels
./llm-stack.sh up            # start everything

# Verify
curl http://localhost:8090/health
curl http://localhost:4000/health
```

## Service URLs

| Service | URL |
|---------|-----|
| ragpipe | http://localhost:8090 |
| LiteLLM proxy | http://localhost:4000 |
| ragstuffer | http://localhost:8091 |
| ragwatch | http://localhost:9090 |
| ragdeck | http://localhost:8092 |
| ragorchestrator | http://localhost:8095 |
| Qdrant | http://localhost:6333 |
| Open WebUI | http://localhost:3000 |
| llama-vulkan | http://localhost:8080 |

## Optional: Google Drive polling setup

```bash
./ragstuffer/setup.sh  # interactive setup for Drive polling
```

## Management commands

```bash
./llm-stack.sh up           # start all services
./llm-stack.sh down         # stop all services
./llm-stack.sh restart      # restart all services
./llm-stack.sh status       # show unit states
./llm-stack.sh test         # smoke-test inference
./llm-stack.sh logs <model|proxy|webui>  # follow logs
./llm-stack.sh uninstall    # remove quadlets (models kept)
```