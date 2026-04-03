# ADR-011: SecurityLabelDisable=true as targeted workaround

## Status

Accepted (2026-04-02)

## Context

SELinux is enforcing on Fedora 43. Three containers fail to start without `SecurityLabelDisable=true`, each for a different reason:

1. **ramalama** — requires `/dev/kfd` access for ROCm GPU compute. SELinux blocks device access in the rootless user systemd context. No upstream SELinux policy module exists for rootless ROCm containers.

2. **qdrant** — Debian-based binary triggers `execmem` SELinux denial (`cannot apply additional memory protection after relocation: Permission denied`). This is a compatibility issue between Debian-compiled ELF binaries and Fedora 43's stricter memory protection policy.

3. **litellm** — Same Debian binary `execmem` issue as qdrant.

## Decision

Set `SecurityLabelDisable=true` only on these three containers, each with an explicit comment in the quadlet explaining the specific constraint. All other containers (ragpipe, rag-watcher, postgres) run with full SELinux enforcement.

## Consequences

- Reduced SELinux confinement on three containers — accepted as unavoidable given upstream image constraints
- Every `SecurityLabelDisable=true` has a comment citing the specific reason, making it auditable
- UBI-based containers (ragpipe on UBI9, rag-watcher on UBI10, postgres on sclorg) do not need the workaround
- The Debian binary issue affects any non-RHEL/Fedora container image — this will recur with other upstream images
- Must revisit when: (a) upstream ramalama provides an SELinux policy for `/dev/kfd`, (b) qdrant/litellm ship RHEL-compatible images, or (c) Fedora relaxes `execmem` policy for containers
