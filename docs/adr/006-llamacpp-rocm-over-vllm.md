# ADR-006: llama.cpp/ROCm as inference backend over vLLM

## Status

Accepted (2026-03-30)

## Context

The AI Max+ 395 uses gfx1151 (RDNA 3.5), which has limited ROCm support. At the time of the decision, vLLM's ROCm backend did not support gfx1151 — builds targeted gfx90a (MI250) and gfx942 (MI300). llama.cpp had experimental gfx1151 support via `HSA_OVERRIDE_GFX_VERSION=11.5.1` and supported GGUF quantized models, which fit the unified memory architecture better than vLLM's full-precision or AWQ formats.

## Decision

Use llama.cpp as the inference runtime, served via RamaLama's ROCm container (`quay.io/ramalama/rocm:latest`). Set `HSA_OVERRIDE_GFX_VERSION=11.5.1` in the container environment to work around ROCm 6.4.x's missing native gfx1151 support. A fix is expected in ROCm 7.x (Fedora 44).

## Consequences

- GGUF quantized models (Q4_K_M, UD-Q4_K_XL) run efficiently on the unified memory architecture
- `HSA_OVERRIDE_GFX_VERSION=11.5.1` is required in every ROCm container and must not be removed until ROCm ships native gfx1151 support
- `GPU_MAX_HW_QUEUES=1` mitigates idle GPU busy-spin on gfx1151 (reduces idle CPU from 160% to ~15%)
- Flash attention and q8_0 KV cache quantization are supported, reducing KV cache from 2560 MiB to 1360 MiB
- vLLM may become viable when ROCm adds gfx1151 support and vLLM stabilizes its ROCm backend — revisit at that time
