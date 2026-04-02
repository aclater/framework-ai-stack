# ADR-010: Unified memory configuration — remove LLAMA_HIP_UMA=1

## Status

Accepted (2026-04-02), supersedes initial configuration

## Context

The AI Max+ 395 has 128 GB of unified memory. The BIOS splits this into a GPU VRAM pool and a system RAM pool. The initial configuration set the BIOS to 64/64 (64 GB VRAM, 64 GB system RAM) and set `LLAMA_HIP_UMA=1` in the llama-server container, which was documented as "critical for AI Max+ 395 iGPU."

Investigation revealed this was wrong. `LLAMA_HIP_UMA=1` tells llama.cpp to allocate model weights via GTT (GPU-accessible system RAM) instead of dedicated VRAM. With a 64 GB VRAM carve-out in BIOS, this flag bypasses the VRAM entirely, placing the 21 GB model in GTT and consuming system RAM. The 64 GB of dedicated VRAM sat nearly empty while the CPU side was under memory pressure (42 GB used, 4.2 GB swap).

## Decision

Remove `LLAMA_HIP_UMA=1` from all containers, the setup script, `env.example`, and `~/.bashrc`. The model weights should land in dedicated VRAM, not GTT. The 64/64 BIOS split is appropriate — 64 GB VRAM for model weights + KV cache, 62 GB system RAM for applications and containers.

Set `HSA_OVERRIDE_GFX_VERSION=11.5.1` (required for gfx1151 until ROCm 7.x) and `GPU_MAX_HW_QUEUES=1` (reduces idle GPU busy-spin).

## Consequences

- Model weights load into dedicated VRAM as intended by the BIOS split
- System RAM freed from ~42 GB used to ~35 GB, swap reduced
- `LLAMA_HIP_UMA=1` must not be re-added — it is harmful on this hardware with a dedicated VRAM carve-out
- The `env.example` includes a comment warning against setting it
- KV cache (q8_0, 1360 MiB) also resides in the GPU memory pool
