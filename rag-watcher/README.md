# RAG Watcher

Polls multiple document sources and ingests them into a Qdrant vector database backed by a Postgres document store. Supports Google Drive, git repos, and web URLs.

Supported file types: PDF, DOCX, PPTX, XLSX, HTML, Markdown, AsciiDoc, RST, plain text. Google Docs/Sheets/Slides are exported automatically.

## How it works

1. **Poll** — checks each source for new or modified documents
2. **Extract** — pulls text from supported file formats
3. **Chunk** — splits text using LangChain RecursiveCharacterTextSplitter (paragraph/sentence boundaries)
4. **Persist** — writes chunks to the Postgres document store with upsert semantics on `(doc_id, chunk_id)`
5. **Embed** — generates vectors with sentence-transformers
6. **Index** — upserts reference-only payloads `{doc_id, chunk_id, source, created_at}` to Qdrant (no text in Qdrant)

Documents are available for RAG queries immediately after ingestion — no model restart needed.

## Document sources

### Google Drive

Requires a Google Cloud service account. See [setup instructions](#google-drive-setup) below.

```bash
GDRIVE_FOLDER_ID=1aBcDeFgHiJkLmNoPqRsTuVwXyZ
```

### Git repos

JSON list of `{url, glob}` objects. Uses shallow clones with incremental pull.

```bash
REPO_SOURCES='[{"url": "https://github.com/org/repo", "glob": "**/*.md"}]'
```

### Web URLs

JSON list of URLs. Extracts text from HTML pages.

```bash
WEB_SOURCES='["https://example.com/docs", "https://example.com/faq"]'
```

## Deploy

```bash
cp quadlets/rag-watcher.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start rag-watcher
systemctl --user enable rag-watcher   # start on login
```

Check logs:

```bash
journalctl --user -u rag-watcher -f
```

## Configuration

All via environment variables in `~/.config/llm-stack/env`:

| Variable | Default | Description |
|---|---|---|
| `GDRIVE_FOLDER_ID` | — | Google Drive folder to watch |
| `REPO_SOURCES` | — | JSON list of git repos |
| `WEB_SOURCES` | — | JSON list of web URLs |
| `WATCH_INTERVAL_MINUTES` | 15 | Poll interval |
| `QDRANT_URL` | `http://127.0.0.1:6333` | Qdrant endpoint |
| `QDRANT_COLLECTION` | documents | Collection name |
| `EMBED_URL` | `http://127.0.0.1:8090/v1/embeddings` | Embedding endpoint (delegates to ragpipe) |
| `CHUNK_SIZE` | 1024 | Max chunk size in characters |
| `CHUNK_OVERLAP` | 128 | Overlap between chunks |
| `DOCSTORE_BACKEND` | postgres | `postgres` or `sqlite` |
| `DOCSTORE_URL` | `postgresql://litellm:litellm@...` | Postgres connection string |

## Google Drive setup

### 1. Create a Google Cloud service account

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a project (or select an existing one)
3. Enable the **Google Drive API**: APIs & Services -> Library -> search "Google Drive API" -> Enable
4. Create a service account: IAM & Admin -> Service Accounts -> Create Service Account
5. Give it a name (e.g. `ramalama-rag-reader`) — no roles needed
6. Click the service account -> Keys -> Add Key -> Create new key -> JSON
7. Save the downloaded JSON key file:

```bash
mkdir -p ~/.config/ramalama
mv ~/Downloads/your-project-*.json ~/.config/ramalama/gdrive-sa.json
chmod 600 ~/.config/ramalama/gdrive-sa.json
```

### 2. Share the Drive folder with the service account

1. Open the JSON key file and find the `client_email` field
2. In Google Drive, right-click the folder -> Share
3. Paste the service account email and grant **Viewer** access

### 3. Get the folder ID

Open the folder in Google Drive. The folder ID is the last segment of the URL:

```
https://drive.google.com/drive/folders/1aBcDeFgHiJkLmNoPqRsTuVwXyZ
```

## State tracking

Ingested Drive files are tracked in `~/.local/share/ramalama/rag-state.json`. Delete this file to force a full re-ingestion on the next poll cycle.

## Acknowledgements

Document loading patterns (git shallow clone with incremental pull, web extraction, chunking with source attribution) are adapted from the [Red Hat Validated Patterns vector-embedder](https://github.com/validatedpatterns-sandbox/vector-embedder).
