# Architecture Decision Records

This is the ADR index for framework-ai-stack. There are 14 ADRs in the adr/ directory.

## Index

| # | Title | Status | Date |
|---|-------|--------|------|
| 001 | [Live Qdrant over OCI Images](./001-live-qdrant-over-oci-images.md) | accepted | 2024-10 |
| 002 | [Reference-Only Indexing](./002-reference-only-indexing.md) | accepted | 2024-10 |
| 003 | [Corpus-Preferring Grounding](./003-corpus-preferring-grounding.md) | accepted | 2024-10 |
| 004 | [UBI Container Strategy](./004-ubi-container-strategy.md) | accepted | 2024-10 |
| 005 | [Podman Quadlets over Docker Compose](./005-podman-quadlets-over-docker-compose.md) | accepted | 2024-11 |
| 006 | [llama.cpp/ROCm over vLLM](./006-llama-cpp-rocm-over-vllm.md) | accepted | 2024-11 |
| 007 | [Single Model Tier](./007-single-model-tier.md) | accepted | 2024-11 |
| 008 | [LiteLLM Postgres Retained](./008-litellm-postgres-retained.md) | accepted | 2024-11 |
| 009 | [LiteLLM Supply Chain Pin](./009-litellm-supply-chain-pin.md) | accepted | 2024-11 |
| 010 | [Unified Memory Configuration](./010-unified-memory-configuration.md) | accepted | 2024-11 |
| 011 | [SELinux SecurityLabelDisable Workaround](./011-selinux-securitylabeldisable-workaround.md) | accepted | 2024-11 |
| 012 | [Model Selection Qwen3.5-35B-A3B](./012-model-selection-qwen3.5-35b-a3b.md) | accepted | 2024-12 |
| 013 | [Lightweight CPU Reranker](./013-lightweight-cpu-reranker.md) | accepted | 2024-12 |
| 014 | [Vulkan on gfx1151](./014-vulkan-on-gfx1151.md) | accepted | 2025-01 |

## Categories

### Infrastructure
- [005 · Podman Quadlets over Docker Compose](./005-podman-quadlets-over-docker-compose.md)
- [006 · llama.cpp/ROCm over vLLM](./006-llama-cpp-rocm-over-vllm.md)
- [004 · UBI Container Strategy](./004-ubi-container-strategy.md)
- [010 · Unified Memory Configuration](./010-unified-memory-configuration.md)
- [011 · SELinux SecurityLabelDisable Workaround](./011-selinux-securitylabeldisable-workaround.md)

### Model and proxy
- [012 · Model Selection Qwen3.5-35B-A3B](./012-model-selection-qwen3.5-35b-a3b.md)
- [007 · Single Model Tier](./007-single-model-tier.md)
- [008 · LiteLLM Postgres Retained](./008-litellm-postgres-retained.md)
- [009 · LiteLLM Supply Chain Pin](./009-litellm-supply-chain-pin.md)

### RAG pipeline
- [001 · Live Qdrant over OCI Images](./001-live-qdrant-over-oci-images.md)
- [002 · Reference-Only Indexing](./002-reference-only-indexing.md)
- [003 · Corpus-Preferring Grounding](./003-corpus-preferring-grounding.md)
- [013 · Lightweight CPU Reranker](./013-lightweight-cpu-reranker.md)
