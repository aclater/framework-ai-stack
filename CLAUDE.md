# framework-ai-stack

Local AI stack on harrison.home.arpa (Ryzen AI Max+ 395, Fedora 43). LLM inference with live RAG from Google Drive, git repos, and web URLs.

## Architecture
```
clients → LiteLLM (:4000) → RAG proxy (:8090) → model (:8080)
                                  ↕
                              Qdrant (:6333)
                                  ↑
                             rag-watcher (polls Drive, git, web → embeds → Qdrant)
```

## Endpoints
- LiteLLM proxy: http://localhost:4000 (key: sk-llm-stack-local)
- RAG proxy:     http://localhost:8090 (Qdrant search + context injection)
- Qwen3.5-35B:  http://localhost:8080 (plain model, no RAG)
- Qdrant:        http://localhost:6333
- Open WebUI:    http://localhost:3000

## Management
```
./llm-stack.sh up/down/restart/status/test
./llm-stack.sh logs <model|proxy|webui>
journalctl --user -u rag-watcher -f
journalctl --user -u rag-proxy -f
journalctl --user -u qdrant -f
```

## Model aliases
All aliases route through RAG proxy → Qwen3.5-35B-A3B on :8080:
- default: general use
- reasoning: multi-step problems, architecture decisions, chain-of-thought
- code: completion, debugging, generation
- fast: quick queries, drafting

## RAG document sources
Configured via environment variables in `~/.config/llm-stack/env`:
- `GDRIVE_FOLDER_ID` — Google Drive folder to watch
- `REPO_SOURCES` — JSON list: `[{"url": "https://...", "glob": "**/*.md"}]`
- `WEB_SOURCES` — JSON list: `["https://example.com/docs"]`

## Container images
- rag-proxy, rag-watcher: UBI10 (SELinux enforcing)
- postgres: sclorg/postgresql-16-c9s
- qdrant, litellm, ramalama, open-webui: upstream images
