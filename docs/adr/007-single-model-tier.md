# ADR-007: Single Qwen3.5-35B-A3B instance replacing three specialized tiers

## Status

Accepted (2026-04-02), supersedes multi-tier architecture

## Context

The original stack ran three simultaneous llama-server containers: QwQ-32B for reasoning, Qwen2.5-Coder-32B for code, and Qwen2.5-14B for fast/embed. Each consumed ~19 GB VRAM plus KV cache, exhausting the 64 GB VRAM pool and causing OOM crashes and swap pressure. An intermediate consolidation to a single DeepSeek-R1-70B (40 GB, Q4_K_M) still left insufficient headroom.

Qwen3.5-35B-A3B uses Mixture of Experts (MoE) with only 3B active parameters from 35B total, achieving near-3B inference speed at 35B quality. It supports both thinking and non-thinking modes in a single model, eliminating the need for separate reasoning and code tiers.

## Decision

Run a single Qwen3.5-35B-A3B instance serving all four LiteLLM aliases (default, reasoning, code, fast) on port 8080. Remove the embedding tier — RAG embeddings are handled by sentence-transformers in the watcher and proxy containers.

## Consequences

- Memory freed: three containers (~57 GB) replaced by one (~22 GB), leaving ~42 GB VRAM for KV cache
- LiteLLM aliases all route to the same backend — alias selection is a client-side hint, not a model switch
- Thinking/non-thinking mode controlled by the model's chat template, not by running separate instances
- Context window: 131072 tokens with 4 parallel slots, q8_0 KV cache (1360 MiB)
- Embedding tier removed: the separate Qwen2.5-14B for embeddings was replaced by sentence-transformers running in the watcher and proxy containers
