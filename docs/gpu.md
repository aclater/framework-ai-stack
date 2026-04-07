# GPU Guide — AMD Ryzen AI Max+ 395 (gfx1151)

## gfx1151 Memory Architecture

gfx1151 (Radeon 8060S, RDNA 3.5) is a UMA (Unified Memory Architecture) APU:
- VRAM: 512 MB (GPU housekeeping only)
- GTT: ~113 GB (all model weights, KV cache, inference data)
- GPU executes compute against GTT — full GPU inference, not CPU fallback
- GTT allocation is correct behavior for this APU — not a problem

## Required: HSA_OVERRIDE_GFX_VERSION

```bash
HSA_OVERRIDE_GFX_VERSION=11.5.1
```
Required for all ROCm workloads on gfx1151. Set in the llama-vulkan quadlet.

## Vulkan RADV (preferred)

llama-vulkan uses Vulkan RADV for inference on gfx1151. This provides:
- Faster model loading than ROCm HIP
- Full GPU inference via GTT
- No ROCm-specific tensor operations needed

Set in llama-vulkan quadlet via the Vulkan container image.

## MIGraphX (alternative, ROCm path)

For ONNX Runtime with MIGraphXExecutionProvider:
- `ORT_MIGRAPHX_MODEL_CACHE_PATH` enables MXR caching
- Warm start: ~6 seconds (MXR cached)
- Cold start: ~3m53s (ONNX model compilation)
- `MIGRAPHX_BATCH_SIZE=64` required — MIGraphX uses static shapes

Note: ROCMExecutionProvider was removed since ONNX Runtime 1.23. MIGraphXExecutionProvider is the only working AMD GPU path on ROCm 7.x.

## Embedder / Reranker on CPU

On gfx1151, both embedder (gte-modernbert-base) and reranker (MiniLM-L-6-v2) run on CPU. MIGraphX tensors land in GTT instead of VRAM on UMA APUs — CPU is faster for models this small. This is not a bug.

## gfx1151 Busy-Spin Mitigation

Set `GPU_MAX_HW_QUEUES=1` in the llama-vulkan container environment to prevent >100% CPU at idle.

## GPU Detection at Runtime

All services detect GPU at runtime:
- torch.cuda.is_available() → NVIDIA CUDA
- torch.version.hip → AMD ROCm
- torch.xpu.is_available() → Intel XPU
- Falls back to CPU with warning log

Never hardcode vendor-specific settings.