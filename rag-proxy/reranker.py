"""Reranker stage for the RAG proxy — scores and reorders retrieved chunks.

Runs after Qdrant vector search, before results are passed to the LLM.
Uses a cross-encoder model to score (query, document) pairs and returns
the top_n highest-scoring results in the same schema as the input.

Default model: BAAI/bge-reranker-v2-m3 (Apache 2.0, 0.6B, multilingual).
Configurable via RERANKER_MODEL env var.
"""

import logging
import os
import time
from typing import Any

log = logging.getLogger("rag-proxy.reranker")

RERANKER_ENABLED = os.environ.get("RERANKER_ENABLED", "true").lower() in ("true", "1", "yes")
RERANKER_MODEL = os.environ.get("RERANKER_MODEL", "BAAI/bge-reranker-v2-m3")
RERANKER_DEVICE = os.environ.get("RERANKER_DEVICE", "")
RERANKER_TOP_K = int(os.environ.get("RERANKER_TOP_K", "20"))
RERANKER_TOP_N = int(os.environ.get("RERANKER_TOP_N", "5"))

_model = None


def _detect_device() -> str:
    """Detect best available device: ROCm/CUDA GPU or CPU."""
    if RERANKER_DEVICE:
        return RERANKER_DEVICE

    try:
        import torch
        if torch.cuda.is_available():
            return "cuda"
    except ImportError:
        pass

    return "cpu"


def _get_model():
    """Lazy-load the cross-encoder model."""
    global _model
    if _model is not None:
        return _model

    from sentence_transformers import CrossEncoder

    device = _detect_device()
    log.info("Loading reranker model %s on %s", RERANKER_MODEL, device)
    _model = CrossEncoder(RERANKER_MODEL, device=device)
    log.info("Reranker model loaded")
    return _model


def rerank(query: str, results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Rerank retrieval results by cross-encoder relevance score.

    Args:
        query: The user's search query.
        results: List of dicts with at least a "text" key. Passed through
                 from Qdrant search output.

    Returns:
        The top_n results sorted by descending reranker score, in the same
        schema as the input. Each dict gets a "reranker_score" key added.
        If reranking is disabled, returns the input unchanged (up to top_n).
    """
    if not RERANKER_ENABLED:
        return results[:RERANKER_TOP_N]

    if not results:
        return results

    model = _get_model()

    pairs = [(query, r["text"]) for r in results]

    start = time.monotonic()
    scores = model.predict(pairs)
    elapsed_ms = (time.monotonic() - start) * 1000

    log.debug("Reranked %d candidates in %.1f ms", len(results), elapsed_ms)

    for result, score in zip(results, scores):
        result["reranker_score"] = float(score)

    ranked = sorted(results, key=lambda r: r["reranker_score"], reverse=True)
    return ranked[:RERANKER_TOP_N]
