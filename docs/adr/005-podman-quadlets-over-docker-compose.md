# ADR-005: Rootless Podman quadlets over docker-compose

## Status

Accepted (2026-03-30)

## Context

The stack needed a container orchestration approach for a single-user Fedora 43 workstation with an eventual path to OpenShift. docker-compose is the common default but requires a Docker daemon, doesn't integrate with systemd, and has no direct path to Kubernetes manifests. Podman quadlets are systemd-native unit files that the Podman quadlet generator converts into systemd services at runtime.

## Decision

Use rootless Podman quadlets managed by systemd for all container lifecycle management. Each service gets a `.container` file in `~/.config/containers/systemd/` with `systemctl --user` for start/stop/enable.

## Consequences

- Systemd-native lifecycle: `systemctl --user start|stop|restart|status|enable` works directly
- SELinux integration: containers run with SELinux confinement by default, `SecurityLabelDisable=true` only where technically required
- No daemon dependency: Podman is daemonless, no Docker socket to manage
- Quadlet syntax constraints: `Exec=` lines don't support backslash continuation, multi-arg commands require `bash -c` wrapping
- OpenShift portability: quadlets can be converted to Kubernetes manifests via `podman generate kube` or rewritten as Deployments
- No compose dependency: the stack has zero runtime dependency on docker-compose or podman-compose
- User lingering (`loginctl enable-linger`) required for services to persist across logout
