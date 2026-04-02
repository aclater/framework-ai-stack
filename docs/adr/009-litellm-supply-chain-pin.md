# ADR-009: Pin LiteLLM to main-stable, never use v1.82.7 or v1.82.8

## Status

Accepted (2026-03)

## Context

In March 2026, LiteLLM PyPI packages v1.82.7 and v1.82.8 were found to contain credential-stealing code. The security advisory is at https://docs.litellm.ai/blog/security-update-march-2026. Version 1.83.0 was built on a hardened CI/CD pipeline but has not yet been promoted to a stable container tag on GHCR.

The `docker.litellm.ai` registry is stale (stops at v1.66). GHCR (`ghcr.io/berriai/litellm`) is the active registry.

## Decision

Pin LiteLLM to `ghcr.io/berriai/litellm:main-stable`, which currently resolves to v1.82.3-stable.patch.2 — a pre-compromise build. Never use versioned PyPI packages v1.82.7 or v1.82.8 or their corresponding container tags. Upgrade to `main-v1.83.0-stable` when it becomes available on GHCR.

## Consequences

- `main-stable` is a floating tag, which is a supply chain risk — but it tracks the last audited clean build and is the safest option until v1.83.0-stable is published
- Upgrade process must include security advisory review before changing the tag
- A scheduled monitor checks GHCR every 6 hours for the v1.83.0-stable tag
- When upgrading: update the quadlet image, the test assertion in `tests/run-tests.sh`, and the README version reference
- Long-term: move to digest-pinned images once v1.83.0-stable is available
