# Operations guide

## Service management

All services run as rootless Podman containers under systemd user units.

### Starting and stopping

```bash
# All inference services
./llm-stack.sh up          # start all
./llm-stack.sh down        # stop all
./llm-stack.sh restart     # restart all
./llm-stack.sh status      # show unit states

# Individual services
systemctl --user start ramalama
systemctl --user stop ragpipe
systemctl --user restart qdrant
systemctl --user restart rag-watcher
```

### Viewing logs

```bash
# Inference
./llm-stack.sh logs model   # llama-server
./llm-stack.sh logs proxy   # LiteLLM
./llm-stack.sh logs webui   # Open WebUI

# RAG pipeline
journalctl --user -u ragpipe -f
journalctl --user -u rag-watcher -f
journalctl --user -u qdrant -f

# Audit log (grounding decisions, no text content)
journalctl --user -u ragpipe -f | grep '"grounding"'
```

### Service dependencies

```
postgres
  ├── litellm (state store)
  ├── ragpipe (document store)
  └── rag-watcher (document store)
qdrant
  ├── ragpipe (vector search)
  └── rag-watcher (vector upsert)
ramalama
  └── ragpipe (model inference)
```

## Adding document sources

### Google Drive

1. Set `GDRIVE_FOLDER_ID` in `~/.config/llm-stack/env`
2. Place the service account key at `~/.config/ramalama/gdrive-sa.json`
3. Share the Drive folder with the service account email (Viewer access)
4. Restart the watcher: `systemctl --user restart rag-watcher`

See `rag-watcher/setup.sh` for interactive setup.

### Git repositories

Add to `~/.config/llm-stack/env`:

```bash
REPO_SOURCES='[{"url": "https://github.com/org/repo", "glob": "**/*.md"}, {"url": "https://github.com/org/other", "glob": "docs/**/*.rst"}]'
```

The watcher will shallow-clone each repo and pull incrementally on subsequent polls. Only files matching the glob pattern are ingested.

### Web URLs

Add to `~/.config/llm-stack/env`:

```bash
WEB_SOURCES='["https://example.com/docs/page1", "https://example.com/docs/page2"]'
```

HTML is fetched and text is extracted (script/style/nav tags are stripped).

### Forcing a re-ingest

Delete the state file and restart:

```bash
rm ~/.local/share/ramalama/rag-state.json
systemctl --user restart rag-watcher
```

This triggers a full re-download and re-embed of all documents.

## Monitoring

### Qdrant collection status

```bash
curl -s http://127.0.0.1:6333/collections/documents | python3 -m json.tool
```

Key fields: `points_count`, `status` (should be `green`).

### Document store chunk count

```bash
podman exec postgres psql -U litellm -c "SELECT COUNT(*) FROM chunks;"
```

### RAG proxy health

```bash
curl -s http://127.0.0.1:8090/v1/models
```

### Grounding audit analysis

Count grounding modes over the last hour:

```bash
journalctl --user -u ragpipe --since "1 hour ago" --no-pager \
  | grep '"grounding"' \
  | python3 -c "
import sys, json, collections
modes = collections.Counter()
for line in sys.stdin:
    try:
        # Extract JSON from log line
        start = line.index('{')
        entry = json.loads(line[start:])
        modes[entry['grounding']] += 1
    except (ValueError, json.JSONDecodeError, KeyError):
        pass
for mode, count in modes.most_common():
    print(f'{mode}: {count}')
"
```

Many `general` grounding entries indicate corpus gaps — the documents don't cover what users are asking.

### Memory usage

```bash
# System overview
free -h

# Per-container
podman stats --no-stream

# GPU / VRAM
cat /sys/class/drm/card1/device/mem_info_vram_used
cat /sys/class/drm/card1/device/mem_info_gtt_used
```

## Troubleshooting

### Model not responding

Check if llama-server is loaded:

```bash
podman logs ramalama 2>&1 | tail -5
# Should show: "main: model loaded" and "srv  update_slots: all slots are idle"
```

If the model is still loading, wait — Qwen3.5-35B-A3B takes ~15 seconds to load.

### RAG proxy returning empty responses

1. Check if Qdrant has data: `curl -s http://127.0.0.1:6333/collections/documents`
2. Check if the docstore has chunks: `podman exec postgres psql -U litellm -c "SELECT COUNT(*) FROM chunks;"`
3. Check proxy logs for errors: `journalctl --user -u ragpipe --since "5 min ago"`

If Qdrant is empty, the watcher hasn't run yet. Force it: `systemctl --user restart rag-watcher`

### Reranker model choice and latency

The default reranker is `cross-encoder/ms-marco-MiniLM-L-6-v2` (22M params), which runs sub-second on CPU with 20 candidates. This was chosen after testing `BAAI/bge-reranker-v2-m3` (0.6B params), which:

- Takes 60+ seconds per request on CPU (3s per candidate x 20)
- Segfaults (exit 139) when loaded on GPU via ROCm PyTorch on gfx1151

The MiniLM model trades some multilingual quality for ~100x speed. To swap back to bge-reranker-v2-m3, set `RERANKER_MODEL=BAAI/bge-reranker-v2-m3` — but only if GPU reranking becomes stable on gfx1151 or you accept 60s+ reranking latency.

The first request after a ragpipe restart takes 5-10 seconds while the model downloads. Subsequent requests are sub-second.

### SELinux denials

UBI10 and UBI9 containers run with SELinux enforcing. Upstream Debian-based images (qdrant, litellm) require `SecurityLabelDisable=true` due to `execmem` denials. If you see:

```
cannot apply additional memory protection after relocation: Permission denied
```

This is a Debian binary incompatibility with Fedora 43's SELinux policy, not a misconfiguration. The workaround is `SecurityLabelDisable=true` with a comment in the quadlet.

### IPv6 connection issues

Some containers bind to `0.0.0.0` (IPv4 only). If `curl http://localhost:...` fails with "Connection reset by peer", try `http://127.0.0.1:...` instead.

### Streaming responses not appearing in Open WebUI

If queries show "thinking" but never produce visible output, check the ragpipe logs for `RuntimeError: Cannot send a request, as the client has been closed`. This was a bug where the httpx AsyncClient was created in an `async with` block that closed before the streaming response was consumed. Fixed in commit `e8aa982` — ensure you're running the latest proxy code.

### High idle GPU usage

If `ramalama` shows >100% CPU at idle, check that `GPU_MAX_HW_QUEUES=1` is set in the container environment. This is a gfx1151 busy-spin mitigation.

## Development

### Linting and formatting

Python code is linted and formatted by [Ruff](https://docs.astral.sh/ruff/) (`ruff.toml`). Shell scripts are checked by ShellCheck (`.shellcheckrc`). Containerfiles are validated by Hadolint (`.hadolint.yaml`).

```bash
ruff check                   # lint Python
ruff format --check          # check Python formatting
ruff check --fix && ruff format  # auto-fix everything
```

### Running tests

```bash
# ragpipe tests: cd ~/git/ragpipe && python -m pytest -v
cd rag-watcher && python -m pytest -v  # 11 tests — extraction, point IDs, state
bash tests/run-tests.sh                # 86 tests — script, quadlets, configs, URLs
```

### CI workflows

GitHub Actions run on every push to `main` and on pull requests:

- **CI** (`.github/workflows/ci.yml`) — Ruff lint/format, ShellCheck, yamllint, pytest (both components), shell tests
- **Containerfile lint** (`.github/workflows/container.yml`) — Hadolint on `rag-watcher/Containerfile` (ragpipe Containerfile linted in its own repo)
- **Security scan** (`.github/workflows/security.yml`) — pip-audit against both `requirements.txt` files, runs on PRs and weekly (Monday 08:00 UTC)

## Configuration reference

All configuration is via environment variables in `~/.config/llm-stack/env` and the individual quadlet files.

### ragpipe

See [ragpipe documentation](https://github.com/aclater/ragpipe) for the full configuration reference. Key overrides set in the quadlet:

| Variable | Quadlet value | Description |
|----------|---------------|-------------|
| `MODEL_URL` | `http://host.containers.internal:8080` | LLM endpoint |
| `QDRANT_URL` | `http://host.containers.internal:6333` | Qdrant endpoint |
| `QDRANT_COLLECTION` | `documents` | Collection name |
| `RAG_TOP_K` | `40` | Qdrant candidates before reranking |
| `RERANKER_TOP_N` | `15` | Results after reranking |
| `DOCSTORE_BACKEND` | `postgres` | `postgres` or `sqlite` |
| `DOCSTORE_URL` | `postgresql://litellm:litellm@.../litellm` | Postgres connection string |

### RAG watcher

| Variable | Default | Description |
|----------|---------|-------------|
| `GDRIVE_FOLDER_ID` | — | Google Drive folder to watch |
| `REPO_SOURCES` | — | JSON list of git repos |
| `WEB_SOURCES` | — | JSON list of web URLs |
| `WATCH_INTERVAL_MINUTES` | `15` | Poll interval |
| `CHUNK_SIZE` | `1024` | Max chunk size (characters) |
| `CHUNK_OVERLAP` | `128` | Overlap between chunks |
| `EMBED_URL` | `http://127.0.0.1:8090/v1/embeddings` | Embedding endpoint (delegates to ragpipe) |
