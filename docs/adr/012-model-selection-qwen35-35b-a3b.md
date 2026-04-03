# ADR-012: Qwen3.5-35B-A3B UD-Q4_K_XL as primary inference model

## Status

Accepted (2026-04-02), supersedes DeepSeek-R1-70B selection

## Context

Multiple models were evaluated for the single-model-tier architecture (see ADR-007):

- **QwQ-32B** (Q4_K_M, ~19 GB) — Strong reasoning but hallucination-prone and slow inference
- **Qwen2.5-Coder-32B** (Q4_K_M, ~19 GB) — Code-only, not general purpose
- **DeepSeek-R1-70B** (Q4_K_M, ~40 GB) — Excellent quality but dense architecture consumed too much memory, no vision support
- **Qwen2.5-72B** (Q4_K_M, ~43 GB) — Dense, same memory issue as DeepSeek
- **Qwen3.5-35B-A3B** (UD-Q4_K_XL, ~22 GB) — MoE with 3B active parameters, thinking + non-thinking modes, Apache 2.0

## Decision

Use Qwen3.5-35B-A3B with Unsloth's UD-Q4_K_XL quantization. The Unsloth quantization uses SOTA techniques that preserve more model quality than standard Q4_K_M at comparable file size.

## Consequences

- 3B active parameters delivers near-3B inference speed at 35B model quality due to MoE architecture
- ~22 GB VRAM with 131072 context window and q4_0 KV cache (360 MiB)
- `--jinja` flag required for thinking mode chat template support
- Thinking and non-thinking modes supported in a single model, controlled by the chat template
- Vision-capable architecture (`--mmproj`) available but deferred pending ramalama multimodal support
- Apache 2.0 license — no usage restrictions
- Model pulled via ramalama: `hf://unsloth/Qwen3.5-35B-A3B-GGUF/Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf`
