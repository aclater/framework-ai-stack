# Troubleshooting

## Cold start (~3:53)

First query after ragpipe startup takes ~3:53 while ONNX models compile. Warm start
(MXR cached): ~6 seconds. Do not restart ragpipe in production unless critical.

## ragpipe returning empty responses

1. Check Qdrant: `curl -s http://127.0.0.1:6333/collections`
2. Check docstore: `podman exec postgres psql -U litellm -c "SELECT COUNT(*) FROM chunks;"`
3. Check logs: `journalctl --user -u ragpipe --since "5 min ago"`
4. Force re-ingest: `systemctl --user restart ragstuffer`

## Qdrant IPv4 issue

Qdrant binds IPv4 only. Fedora resolves localhost to ::1 by default. Use:

```bash
curl -4 http://localhost:6333/...
# or set QDRANT__SERVICE__HOST=:: in the quadlet
```

## SELinux denials

UBI containers run with SELinux enforcing. If you see "cannot apply additional memory
protection after relocation: Permission denied", the Debian-based images (qdrant, litellm)
need `SecurityLabelDisable=true`. This is expected on Fedora 43.

## Stale container images

After updating, pull new images:

```bash
./llm-stack.sh down
podman pull ghcr.io/aclater/ragpipe:main-rocm
podman pull ghcr.io/aclater/ragstuffer:main
./llm-stack.sh up
```

## GTT memory display

GTT total on gfx1151: ~113 GB. Check:

```bash
cat /sys/class/drm/card1/device/mem_info_gtt_used
cat /sys/class/drm/card1/device/mem_info_vram_used
```

VRAM shows ~512 MB used (GPU housekeeping). GTT shows model + KV cache usage.

## LiteLLM supply chain

LiteLLM is pinned to `main-stable` after a supply chain incident (ADR-009). Do not
upgrade without verifying the release is clean.

## LiteLLM proxy not responding

1. Check: `curl http://localhost:4000/health`
2. Check litellm logs: `./llm-stack.sh logs proxy`
3. Check model service: `curl http://localhost:8080/health`

## ragorchestrator not responding

ragorchestrator runs at :8095. Check:

```bash
curl http://localhost:8095/health
```

If DISABLE_WEB_SEARCH is not set and TAVILY_API_KEY is missing, web search will fail
silently. ragorchestrator should be restarted after setting DISABLE_WEB_SEARCH=true.
