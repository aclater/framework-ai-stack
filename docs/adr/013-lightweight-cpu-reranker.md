# ADR-013: CPU-only sentence-transformers on gfx1151

## Status

Accepted (2026-04-02). Superseded in part: PyTorch eliminated entirely by
switching to fastembed (ONNX Runtime). EMBED_DEVICE/RERANKER_DEVICE no
longer needed. Embedding model changed from all-mpnet-base-v2 to
BAAI/bge-base-en-v1.5. Reranker model changed from
cross-encoder/ms-marco-MiniLM-L-6-v2 to Xenova/ms-marco-MiniLM-L-6-v2
(same weights, ONNX format).

## Context

The initial reranker used BAAI/bge-reranker-v2-m3 (0.6B params, multilingual). On CPU, it took 60+ seconds to score 20 candidates (3s per candidate), causing Open WebUI to time out on every query.

Attempting GPU acceleration via ROCm PyTorch failed: the sentence-transformers CrossEncoder segfaults (exit 139) when loading on gfx1151, even with `HSA_OVERRIDE_GFX_VERSION=11.5.1`. This is a PyTorch ROCm compatibility issue specific to gfx1151 — the same setup works for llama.cpp inference but not for PyTorch model loading.

## Decision

Use `cross-encoder/ms-marco-MiniLM-L-6-v2` (22M params) as the default reranker. It runs sub-second on CPU with 20 candidates, making total query latency dominated by model inference (~40-50s with thinking mode) rather than reranking.

The model is configurable via `RERANKER_MODEL` env var. Swap back to `BAAI/bge-reranker-v2-m3` when either: (a) ROCm PyTorch stabilizes on gfx1151, or (b) the model is served via llama.cpp instead of PyTorch.

## Consequences

- Reranking latency dropped from 60s to <1s on CPU
- MiniLM is English-focused; bge-reranker-v2-m3 was multilingual — acceptable since the current corpus is English
- No GPU passthrough needed in the ragpipe container — simpler, SELinux enforcing
- The proxy container no longer needs SecurityLabelDisable=true
- 22M vs 600M params means the model loads instantly and uses negligible memory
- The embedding model (`sentence-transformers/all-mpnet-base-v2`) is also pinned to CPU via `EMBED_DEVICE=cpu` — the same PyTorch ROCm segfault affects all sentence-transformers models on gfx1151, not just the reranker
- Both `EMBED_DEVICE` and `RERANKER_DEVICE` env vars allow override if ROCm PyTorch stabilizes
