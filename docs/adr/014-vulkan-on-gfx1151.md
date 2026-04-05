# ADR-014: Vulkan (RADV) over ROCm HIP on gfx1151

## Status

Accepted (2026-04-05). Supersedes ADR-010 (LLAMA_HIP_UMA removal) and
partial workaround for GTT placement. See also issue #26 (GTT issue) and
issue #28 (Vulkan evaluation).

## Context

The AI Max+ 395 (gfx1151/Strix Halo) is a UMA (Unified Memory Architecture)
APU. Initial configuration used ROCm HIP backend with `HSA_OVERRIDE_GFX_VERSION=11.5.1`
for compatibility. Investigation revealed that even without `LLAMA_HIP_UMA=1`,
the ROCm HIP backend places all tensors in GTT (GPU-accessible system RAM)
rather than VRAM because VMM (Virtual Memory Manager) is not supported on
UMA APUs — AMD confirms this is by-design.

Result: model weights (21 GB) and KV cache consume 42 GB of system RAM
instead of using the 64 GB VRAM carve-out. The 64 GB VRAM sits nearly empty
while system RAM is under pressure.

An alternative was investigated: Vulkan via RADV (Mesa's Vulkan driver).
Unlike ROCm HIP, Vulkan manages GPU memory directly without the VMM
requirement, allowing proper use of device-local memory on UMA APUs.

## Decision

Replace the ROCm HIP backend with Vulkan (RADV) for llama-server on gfx1151.

**New container architecture:**
- Build stage: `fedora:43` with cmake, gcc, glslc, vulkan-loader-devel —
  compiles llama.cpp with `-DGGML_VULKAN=ON -DGGML_RPC=ON -DLLAMA_CURL=ON`
- Runtime stage: `ubi10/ubi-minimal` with vulkan-loader, mesa-vulkan-drivers,
  libatomic, ca-certificates — non-root USER 1001

**Quadlet changes:**
- Image: `ghcr.io/aclater/llama-vulkan:latest` (replaces `quay.io/ramalama/rocm:0.18.0`)
- Device: `/dev/dri` only (no `/dev/kfd` — no ROCm compute stack needed)
- Removed: `HSA_OVERRIDE_GFX_VERSION`, `GPU_MAX_HW_QUEUES`, `ROCBLAS_USE_HIPBLASLT`
- Removed: `--flash-attn on`, `--cache-type-k q4_0`, `--cache-type-v q4_0`, `-dio`
- Note: SecurityLabelDisable removed — testing whether `container_t` can
  access `/dev/dri/renderD128` without override

**BIOS recommendation:**
AMD's Strix Halo optimization guide recommends keeping dedicated VRAM small
on UMA APUs (4-8 GB) and relying on GTT. With Vulkan managing VRAM+GTT
pool natively, consider reducing the 64 GB BIOS carve-out to free system
RAM and eliminate swap pressure.

## Consequences

**Positive:**
- Model weights and KV cache use device-local memory (VRAM) instead of GTT
- No ROCm dependency — simpler container, smaller attack surface
- No `HSA_OVERRIDE_GFX_VERSION` needed
- Fewer ROCm-specific tunables
- **No SecurityLabelDisable needed** — SELinux `container_t` can access
  `/dev/dri/renderD128` natively (verified on Fedora 43)

**Negative:**
- **No flash attention** — falls back to CPU attention kernel on AMD
  ([llama.cpp#12526](https://github.com/ggml-org/llama.cpp/issues/12526))
- **No KV cache quantization** — requires FA; using f16 KV cache instead
  ([llama.cpp#9551](https://github.com/ggml-org/llama.cpp/issues/9551))
- **Parallel slot perf issue** — inactive slots cause overhead
  ([llama.cpp#19523](https://github.com/ggml-org/llama.cpp/issues/19523))
- **gfx1151 specific issues** — model loading (#18741), PP perf with large
  ubatch (#18725), missing compute shaders (#20354)

**Benchmarks (2026-04-05, Qwen3.5-35B-A3B Q6_K_XL on gfx1151):**

| Metric | ROCm HIP + `-dio` | Vulkan RADV |
|--------|-------------------|-------------|
| Generation (700 tok) | 39 t/s | **43 t/s** |
| Prompt processing (2K tok) | ~1000 t/s | ~1000 t/s |
| VRAM used | 400 MB (GTT: 33 GB) | **34 GB** (GTT: 1.5 GB) |
| System RAM used | 40 GB + 2.5 GB swap | **8.4 GB** |
| SecurityLabelDisable | Required | **Not needed** |

Vulkan is 10% faster at generation, uses VRAM as intended, and frees
~32 GB of system RAM. The lack of flash attention and KV cache quantization
is offset by the massive memory improvement on UMA.

**Tradeoffs:**
- f16 KV cache uses ~2x more memory than q4_0, but on 128 GB UMA with
  proper VRAM placement this is acceptable — 34 GB VRAM still leaves
  ~30 GB free for larger contexts or models

## References

- [kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes)
- [llama.cpp Vulkan Dockerfile](https://github.com/ggml-org/llama.cpp/blob/master/.devops/vulkan.Dockerfile)
- [AMD Strix Halo optimization guide](https://rocm.docs.amd.com/en/latest/how-to/system-optimization/strixhalo.html)
- [Known-good Strix Halo stack](https://github.com/ggml-org/llama.cpp/discussions/20856)
