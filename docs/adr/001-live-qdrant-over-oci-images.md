# ADR-001: Live Qdrant over ramalama rag OCI images

## Status

Accepted (2026-04-02)

## Context

The original RAG pipeline used `ramalama rag` to bake document vectors into an OCI image (`localhost/rag-data:latest`). The inference container mounted this image at startup. When documents changed, the image had to be rebuilt and the inference container restarted — causing several minutes of downtime while the 22 GB model reloaded.

This created an inherent conflict: the RAG pipeline was designed for automated, continuous document ingestion from Google Drive, but every update required a service interruption.

## Decision

Replace the OCI image approach with a live Qdrant vector database. Documents are indexed into Qdrant directly and are available for queries immediately. The model never restarts when documents change.

## Consequences

**Positive:**
- Zero-downtime document updates — new documents available on the next query after ingestion
- No model reload when the corpus changes
- Standard vector database with HTTP API, queryable for debugging
- Path to production: Qdrant has managed cloud, Kubernetes operator, and Red Hat OpenShift integration

**Negative:**
- Additional container to manage (Qdrant)
- Qdrant data must be persisted via a volume (was implicit in the OCI image)
- More complex than a single mounted file

**Neutral:**
- `ramalama rag` is no longer used for indexing — we handle extraction, embedding, and upsert directly
- The `ramalama serve --rag` integration is no longer needed, removing the dependency on the port bug fix (containers/ramalama#2581)
