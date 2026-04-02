# ADR-002: Reference-only indexing in Qdrant

## Status

Accepted (2026-04-02)

## Context

The initial Qdrant implementation stored full chunk text in every point's payload alongside the vector. This meant Qdrant held a complete copy of the document corpus in memory, increasing resource usage and coupling the vector index tightly to the document content.

Enterprise RAG systems typically separate vector storage from document storage. Vectors are optimized for similarity search; document content is optimized for retrieval and served from a purpose-built store.

## Decision

Qdrant stores only reference payloads:

```json
{
  "doc_id": "UUID",
  "chunk_id": integer,
  "source": "filename or URI",
  "created_at": "ISO8601"
}
```

Full chunk text lives in a Postgres document store (the `chunks` table), keyed on `(doc_id, chunk_id)`. At query time, the RAG proxy batch-hydrates text from the document store after Qdrant returns candidate references.

Additionally, the Qdrant collection uses int8 scalar quantization (`quantile: 0.99`, `always_ram: true`) to further reduce vector memory footprint. `always_ram` is required because HNSW rescoring needs quantized vectors in RAM for accurate distance computation.

## Consequences

**Positive:**
- Qdrant memory footprint reduced significantly (no text payloads)
- Document content has a single source of truth (Postgres)
- Postgres supports SQL queries, backups, replication — capabilities Qdrant payloads don't have
- Scalar quantization further reduces vector memory by ~75%
- Re-ingestion is idempotent: `doc_id` is deterministic (UUID5 from source URI), upsert on `(doc_id, chunk_id)` prevents duplicates

**Negative:**
- Query-time hydration adds a Postgres round-trip per query (batched, typically <5ms)
- Two stores must be kept in sync — docstore write must succeed before Qdrant upsert
- Orphaned vectors (Qdrant points with no matching docstore entry) are possible if the docstore is wiped independently; these are handled gracefully (excluded with warning, not exception)

**Migration note:**
Qdrant does not support adding quantization to an existing collection. To apply this change, the collection must be dropped and recreated. The watcher performs a full rebuild on each poll cycle, so this happens automatically.
