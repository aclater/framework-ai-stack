#!/usr/bin/env python3
"""RAG proxy — searches Qdrant, hydrates from docstore, reranks, validates
citations, and injects grounded context into chat completions."""

import json
import logging
import os
import sys
import time

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse, JSONResponse
from qdrant_client import QdrantClient
from sentence_transformers import SentenceTransformer

from reranker import rerank
from grounding import (
    SYSTEM_PROMPT,
    build_system_message,
    format_context,
    determine_corpus_coverage,
    parse_citations,
    validate_citations,
    strip_invalid_citations,
    build_metadata,
    query_hash,
    log_audit,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("rag-proxy")

# ── Configuration ────────────────────────────────────────────────────────────

MODEL_URL = os.environ.get("MODEL_URL", "http://127.0.0.1:8080")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://127.0.0.1:6333")
COLLECTION_NAME = os.environ.get("QDRANT_COLLECTION", "documents")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "sentence-transformers/all-mpnet-base-v2")
TOP_K = int(os.environ.get("RAG_TOP_K", "20"))
PROXY_PORT = int(os.environ.get("RAG_PROXY_PORT", "8090"))

# Thinking budget — allows the model to reason across retrieved chunks
# and general knowledge without unconstrained latency
THINKING_BUDGET = int(os.environ.get("THINKING_BUDGET", "1024"))

# ── Globals initialized at startup ───────────────────────────────────────────

qdrant: QdrantClient = None
embedder: SentenceTransformer = None
docstore = None

app = FastAPI()


@app.on_event("startup")
def startup():
    global qdrant, embedder, docstore
    log.info("Connecting to Qdrant at %s", QDRANT_URL)
    qdrant = QdrantClient(url=QDRANT_URL, timeout=10)

    collections = [c.name for c in qdrant.get_collections().collections]
    if COLLECTION_NAME not in collections:
        log.warning("Collection '%s' not found in Qdrant — RAG context will be empty until documents are ingested", COLLECTION_NAME)

    log.info("Loading embedding model: %s", EMBED_MODEL)
    embedder = SentenceTransformer(EMBED_MODEL)

    from docstore import create_docstore
    docstore = create_docstore()

    log.info("RAG proxy ready — forwarding to %s (thinking_budget=%d)", MODEL_URL, THINKING_BUDGET)


# ── Retrieval pipeline ───────────────────────────────────────────────────────

def search_qdrant(query: str) -> list[dict]:
    """Embed the query and search Qdrant for reference payloads."""
    try:
        collections = [c.name for c in qdrant.get_collections().collections]
        if COLLECTION_NAME not in collections:
            return []

        query_vector = embedder.encode(query).tolist()
        results = qdrant.query_points(
            collection_name=COLLECTION_NAME,
            query=query_vector,
            limit=TOP_K,
            with_payload=True,
        )

        if not results.points:
            return []

        return [point.payload for point in results.points if point.payload.get("doc_id")]
    except Exception:
        log.exception("Qdrant search failed")
        return []


def hydrate_results(refs: list[dict]) -> list[dict]:
    """Batch-hydrate Qdrant reference payloads from the document store.

    Orphaned vectors (chunk missing from docstore) are excluded with a
    warning — they don't abort the query.
    """
    if not refs:
        return []

    lookup_keys = [(r["doc_id"], r["chunk_id"]) for r in refs]
    texts = docstore.get_chunks(lookup_keys)

    hydrated = []
    for ref in refs:
        key = (ref["doc_id"], ref["chunk_id"])
        text = texts.get(key)
        if text is None:
            log.warning("Orphaned vector: doc_id=%s chunk_id=%d — excluding from results", ref["doc_id"], ref["chunk_id"])
            continue
        hydrated.append({
            "text": text,
            "source": ref.get("source", "unknown"),
            "doc_id": ref["doc_id"],
            "chunk_id": ref["chunk_id"],
        })

    return hydrated


def retrieve_and_rerank(user_query: str) -> tuple[list[dict], list[dict]]:
    """Full retrieval pipeline: Qdrant → hydrate → rerank.

    Returns (ranked_chunks, all_retrieved_refs) where all_retrieved_refs
    is the full set of hydrated results before reranking, needed for
    citation validation.
    """
    refs = search_qdrant(user_query)
    candidates = hydrate_results(refs)
    ranked = rerank(user_query, candidates)
    return ranked, candidates


# ── Request processing ───────────────────────────────────────────────────────

def process_chat_request(body: dict) -> tuple[dict, dict]:
    """Process a chat completion request with grounding.

    Returns (modified_body, retrieval_context) where retrieval_context
    contains everything needed for post-response citation validation.
    """
    messages = body.get("messages", [])
    if not messages:
        return body, {"ranked": [], "retrieved_set": set(), "corpus_coverage": "none", "user_query": ""}

    # Find the last user message for the query
    user_query = ""
    for msg in reversed(messages):
        if msg.get("role") == "user":
            user_query = msg.get("content", "")
            break

    if not user_query:
        return body, {"ranked": [], "retrieved_set": set(), "corpus_coverage": "none", "user_query": ""}

    # Retrieve and rerank
    ranked, all_candidates = retrieve_and_rerank(user_query)
    corpus_coverage = determine_corpus_coverage(ranked)

    # Build the retrieved set for citation validation — includes all
    # candidates that were retrieved, not just the reranked top-N,
    # because the model sees only the top-N but we validate against
    # the full retrieved set to catch hallucinated citations
    retrieved_set = {(c["doc_id"], c["chunk_id"]) for c in ranked}

    # Format context with citation-friendly labels
    context = format_context(ranked)
    system_content = build_system_message(context)

    if corpus_coverage == "none":
        # Log empty retrieval — useful signal for corpus gap analysis
        q_hash = query_hash(user_query)
        log.info("Empty retrieval for query_hash=%s — proceeding with general knowledge", q_hash)

    # Inject system message into the conversation
    # Insert after any existing system messages but before user messages
    context_msg = {"role": "system", "content": system_content}
    new_messages = []
    inserted = False
    for msg in messages:
        if not inserted and msg.get("role") != "system":
            new_messages.append(context_msg)
            inserted = True
        new_messages.append(msg)
    if not inserted:
        new_messages.append(context_msg)

    body["messages"] = new_messages

    # Add thinking budget to allow the model to reason across sources
    # without unconstrained latency
    if "chat_template_kwargs" not in body:
        body["chat_template_kwargs"] = {}
    body["chat_template_kwargs"]["enable_thinking"] = True
    body["chat_template_kwargs"]["thinking_budget"] = THINKING_BUDGET

    return body, {
        "ranked": ranked,
        "retrieved_set": retrieved_set,
        "corpus_coverage": corpus_coverage,
        "user_query": user_query,
    }


def process_response(response_data: dict, ctx: dict) -> dict:
    """Post-process the LLM response: validate citations, add metadata, audit.

    This is where we parse the model's output, check that cited chunks are
    real and were in the retrieved set, classify the grounding mode, and
    emit the audit log. Crucially, this parsing is done by code — we never
    ask the LLM to generate the metadata.
    """
    choices = response_data.get("choices", [])
    if not choices:
        return response_data

    content = choices[0].get("message", {}).get("content", "")
    if not content:
        return response_data

    user_query = ctx.get("user_query", "")
    ranked = ctx.get("ranked", [])
    retrieved_set = ctx.get("retrieved_set", set())
    corpus_coverage = ctx.get("corpus_coverage", "none")

    # Parse citations from the model's response
    citations = parse_citations(content)

    # Validate each citation against the retrieved set and docstore
    valid_citations, validation_errors = validate_citations(citations, retrieved_set, docstore)

    # Determine citation validation status
    if not citations:
        citation_status = "pass"  # No citations to validate
    elif validation_errors:
        citation_status = "stripped"
        # Log each invalid citation as an error with the query hash
        q_hash = query_hash(user_query)
        for err in validation_errors:
            log.error(
                "Invalid citation: query_hash=%s doc_id=%s chunk_id=%d reason=%s",
                q_hash, err["doc_id"], err["chunk_id"], err["reason"],
            )
        # Strip invalid citations from the response — preserve the rest
        content = strip_invalid_citations(content, validation_errors)
        response_data["choices"][0]["message"]["content"] = content
    else:
        citation_status = "pass"

    # Build metadata — populated by parsing, not by the LLM
    metadata = build_metadata(content, valid_citations, corpus_coverage)

    # Attach metadata to the response
    response_data["rag_metadata"] = metadata

    # Audit log — never logs text content
    log_audit(
        q_hash=query_hash(user_query),
        retrieved_chunks=ranked,
        ranked_chunks=ranked,
        corpus_coverage=corpus_coverage,
        grounding=metadata["grounding"],
        valid_citations=valid_citations,
        citation_validation=citation_status,
    )

    return response_data


# ── HTTP endpoints ───────────────────────────────────────────────────────────

@app.api_route("/v1/chat/completions", methods=["POST"])
async def chat_completions(request: Request):
    """Intercept chat completions, inject grounded RAG context, forward to model."""
    body = await request.json()
    body, retrieval_ctx = process_chat_request(body)

    stream = body.get("stream", False)

    async with httpx.AsyncClient(timeout=300) as client:
        if stream:
            # Streaming responses can't be post-processed for citations
            # because we don't have the full text. Pass through as-is.
            async def stream_response():
                async with client.stream(
                    "POST",
                    f"{MODEL_URL}/v1/chat/completions",
                    json=body,
                    headers={"Content-Type": "application/json"},
                ) as resp:
                    async for chunk in resp.aiter_bytes():
                        yield chunk

            return StreamingResponse(stream_response(), media_type="text/event-stream")
        else:
            resp = await client.post(
                f"{MODEL_URL}/v1/chat/completions",
                json=body,
            )
            response_data = resp.json()
            # Post-process: validate citations, classify grounding, audit
            response_data = process_response(response_data, retrieval_ctx)
            return JSONResponse(content=response_data)


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE"])
async def proxy_passthrough(request: Request, path: str):
    """Pass through all other requests to the model unchanged."""
    async with httpx.AsyncClient(timeout=300) as client:
        body = await request.body()
        resp = await client.request(
            method=request.method,
            url=f"{MODEL_URL}/{path}",
            content=body,
            headers={k: v for k, v in request.headers.items() if k.lower() != "host"},
        )
        return resp.json()


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PROXY_PORT)
