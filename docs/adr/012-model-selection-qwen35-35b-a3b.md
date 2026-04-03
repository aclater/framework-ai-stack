# ADR-012: Qwen3.5-35B-A3B as primary inference model

## Status

Accepted (2026-04-02), supersedes DeepSeek-R1-70B selection.
Updated (2026-04-03): quantization now selected by auto-tuner (`./llm-stack.sh tune`)

## Context

Multiple models were evaluated for the single-model-tier architecture (see ADR-007):

- **QwQ-32B** (Q4_K_M, ~19 GB) — Strong reasoning but hallucination-prone and slow inference
- **Qwen2.5-Coder-32B** (Q4_K_M, ~19 GB) — Code-only, not general purpose
- **DeepSeek-R1-70B** (Q4_K_M, ~40 GB) — Excellent quality but dense architecture consumed too much memory, no vision support
- **Qwen2.5-72B** (Q4_K_M, ~43 GB) — Dense, same memory issue as DeepSeek
- **Qwen3.5-35B-A3B** (UD-Q4_K_XL, ~22 GB) — MoE with 3B active parameters, thinking + non-thinking modes, Apache 2.0

## Decision

Use Qwen3.5-35B-A3B with Unsloth quantization. The specific quantization level (Q4_K_XL, Q6_K_XL, or Q8_K_XL) is selected by the auto-tuner based on available VRAM — highest quality that fits with room for KV cache.

On systems with <32 GB VRAM, the auto-tuner selects Qwen3.5-9B instead (same architecture family, dense 9B).

## Consequences

- 3B active parameters delivers near-3B inference speed at 35B model quality due to MoE architecture
- VRAM usage and KV cache type set by auto-tuner based on hardware
- `--jinja` flag required for thinking mode chat template support
- Thinking and non-thinking modes supported in a single model, controlled by the chat template
- Vision-capable architecture (`--mmproj`) available but deferred pending ramalama multimodal support
- Apache 2.0 license — no usage restrictions
- Model pulled via ramalama: repo and file selected by auto-tuner (see tune.conf)
