# ADR-004: UBI container base images with SELinux enforcing

## Status

Accepted (2026-04-02)

## Context

The stack originally used `registry.fedoraproject.org/fedora:43` and `docker.io/library/python:3.12-slim` (Debian-based) as container base images. All containers ran with `SecurityLabelDisable=true`, effectively disabling SELinux confinement.

This approach had three problems:

1. **SELinux bypass** — disabling labels removes a key security layer. In a stack handling potentially sensitive documents (NATO briefings, strategic assessments), this is unacceptable.
2. **Non-Red Hat images** — Debian-based images don't align with the target platform (OpenShift) and lack Red Hat's security patching cadence.
3. **Fedora images in production** — Fedora images are development-oriented and not designed for production container workloads.

## Decision

Use UBI (Universal Base Image) containers wherever possible, with SELinux enforcing:

| Container | Image | SELinux | Rationale |
|-----------|-------|---------|-----------|
| ragpipe | `localhost/ragpipe` (from ubi9/python-311) | Enforcing | Pre-built with deps + models baked in |
| rag-watcher | `localhost/rag-watcher` (from ubi10) | Enforcing | Pre-built with deps + models baked in |
| postgres | `sclorg/postgresql-16-c9s` | Enforcing | Red Hat-maintained Postgres |

`SecurityLabelDisable=true` is only used where technically unavoidable:

| Container | Reason |
|-----------|--------|
| qdrant | Debian binary triggers `execmem` SELinux denial on Fedora 43 kernel |
| litellm | Same Debian binary issue |
| ramalama | Requires `/dev/kfd` access for ROCm GPU compute |

Each exception has a comment in the quadlet file explaining the specific constraint.

## Consequences

**Positive:**
- SELinux enforcing on all custom containers (ragpipe, rag-watcher, postgres)
- UBI images receive Red Hat security updates
- Pinned digests ensure reproducible builds
- Path to OpenShift: UBI images are pre-certified for RHEL/OKD
- Non-root execution (UID 1001) on ragpipe

**Negative:**
- UBI10 only has Python 3.12 (minimal variant); Python 3.11 required UBI9 for cross-encoder compatibility
- UBI10 minimal has no package manager, so the rag-watcher uses the full UBI10 base
- Upstream images (qdrant, litellm) can't be rebased without forking — SELinux exceptions will remain until these projects ship RHEL-compatible binaries or adopt UBI

**Why not UBI10 for ragpipe?**
UBI10 ships only `python-312-minimal`. The reranker cross-encoder (sentence-transformers `CrossEncoder`) has compatibility requirements with Python 3.11 that work better on UBI9. When UBI10 adds Python 3.11, the image can be rebased.

**Digest pinning policy:**
The ragpipe image is pinned to a verified digest. Other images use `:latest` or version tags. Over time, all images should move to digest pinning for supply chain security.
