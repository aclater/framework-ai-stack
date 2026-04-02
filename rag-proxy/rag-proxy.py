#!/usr/bin/env python3
"""RAG proxy — searches Qdrant and injects document context into chat completions."""

import json
import logging
import os
import sys
import time

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
from qdrant_client import QdrantClient
from sentence_transformers import SentenceTransformer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("rag-proxy")

# Configuration
MODEL_URL = os.environ.get("MODEL_URL", "http://127.0.0.1:8080")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://127.0.0.1:6333")
COLLECTION_NAME = os.environ.get("QDRANT_COLLECTION", "documents")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "sentence-transformers/all-mpnet-base-v2")
TOP_K = int(os.environ.get("RAG_TOP_K", "20"))
PROXY_PORT = int(os.environ.get("RAG_PROXY_PORT", "8090"))

# Reranker (imported lazily to avoid loading model at module level)
from reranker import rerank

# Globals initialized at startup
qdrant: QdrantClient = None
embedder: SentenceTransformer = None
docstore = None

SYSTEM_PROMPT_TEMPLATE = """You are a helpful assistant. Use the following document excerpts to answer the user's question. If the excerpts don't contain relevant information, say so and answer from your general knowledge.

--- DOCUMENT CONTEXT ---
{context}
--- END CONTEXT ---"""


app = FastAPI()


@app.on_event("startup")
def startup():
    global qdrant, embedder
    log.info("Connecting to Qdrant at %s", QDRANT_URL)
    qdrant = QdrantClient(url=QDRANT_URL, timeout=10)

    # Check if collection exists
    collections = [c.name for c in qdrant.get_collections().collections]
    if COLLECTION_NAME not in collections:
        log.warning("Collection '%s' not found in Qdrant — RAG context will be empty until documents are ingested", COLLECTION_NAME)

    log.info("Loading embedding model: %s", EMBED_MODEL)
    embedder = SentenceTransformer(EMBED_MODEL)

    global docstore
    from docstore import create_docstore
    docstore = create_docstore()

    log.info("RAG proxy ready — forwarding to %s", MODEL_URL)


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

    Each ref has {doc_id, chunk_id, source, created_at}. We look up the
    full chunk text via a single batched docstore query and merge it in.
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


def search_context(query: str) -> str:
    """Search Qdrant, hydrate from docstore, rerank, and format as context."""
    refs = search_qdrant(query)
    if not refs:
        return ""

    candidates = hydrate_results(refs)
    if not candidates:
        return ""

    ranked = rerank(query, candidates)

    chunks = []
    for r in ranked:
        source = r.get("source", "unknown")
        text = r.get("text", "")
        chunks.append(f"[Source: {source}]\n{text}")

    return "\n\n".join(chunks)


def inject_context(body: dict) -> dict:
    """Find the user's last message, search Qdrant, and prepend context as a system message."""
    messages = body.get("messages", [])
    if not messages:
        return body

    # Find the last user message for the query
    user_query = ""
    for msg in reversed(messages):
        if msg.get("role") == "user":
            user_query = msg.get("content", "")
            break

    if not user_query:
        return body

    context = search_context(user_query)
    if not context:
        return body

    log.info("Injecting %d chars of RAG context for query: %.80s...", len(context), user_query)

    # Prepend a system message with the context
    context_msg = {"role": "system", "content": SYSTEM_PROMPT_TEMPLATE.format(context=context)}

    # Insert context after any existing system messages but before user messages
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
    return body


@app.api_route("/v1/chat/completions", methods=["POST"])
async def chat_completions(request: Request):
    """Intercept chat completions, inject RAG context, forward to model."""
    body = await request.json()
    body = inject_context(body)

    stream = body.get("stream", False)

    async with httpx.AsyncClient(timeout=300) as client:
        if stream:
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
            return resp.json()


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
