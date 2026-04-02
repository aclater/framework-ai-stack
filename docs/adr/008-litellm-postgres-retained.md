# ADR-008: Retain LiteLLM proxy with PostgreSQL backend

## Status

Accepted (2026-03-30)

## Context

With the consolidation to a single model tier, LiteLLM's routing capability became less critical — all aliases point to the same backend. The question was whether to keep it or have clients connect directly to the model endpoint.

LiteLLM provides a single OpenAI-compatible endpoint with API key authentication, alias routing, request logging, and rate limiting. Its `main-stable` image requires a PostgreSQL backend for state persistence (Prisma ORM).

## Decision

Retain LiteLLM as the client-facing proxy on port 4000. Use `quay.io/sclorg/postgresql-16-c9s` (Red Hat-maintained) as the PostgreSQL backend. Postgres also serves as the document store for the RAG pipeline (shared instance, separate `chunks` table).

## Consequences

- Two additional containers (litellm + postgres), but postgres is lightweight and serves double duty for the document store
- Single endpoint for all clients: Claude Code, Open WebUI, curl — no client reconfiguration if the model topology changes
- Alias routing preserved: if the stack returns to multiple models or adds new ones, LiteLLM handles it without client changes
- API key authentication (`sk-llm-stack-local`) provides a minimal access control layer
- Postgres image changed from `postgres:16-alpine` (Docker Hub) to `quay.io/sclorg/postgresql-16-c9s` (Red Hat) for ecosystem alignment
