# Claude Code Integration

Point Claude Code at the LiteLLM proxy:

```bash
export OPENAI_API_BASE=http://localhost:4000
export OPENAI_API_KEY=sk-llm-stack-local
```

## Available model aliases

All aliases route to Qwen3-32B on llama-vulkan (:8080) via LiteLLM → ragpipe:

| Alias | Use case |
|-------|----------|
| `default` | General use |
| `reasoning` | Multi-step problems, chain-of-thought |
| `code` | Completion, debugging, generation |
| `fast` | Quick queries, drafting |
| `nothink` | Structured output tasks (disables thinking mode) |

The `/nothink` model name is important for RAG queries — thinking mode should be disabled for retrieval tasks to avoid slow chain-of-thought on every token generation.

## ragorchestrator with Claude Code

ragorchestrator (:8095) provides agentic orchestration via LangGraph. It uses Self-RAG with adaptive complexity classification:
- `simple` — direct lookup, single retrieval pass
- `complex` — multi-hop reasoning, multiple retrieval passes
- `external` — requires web search (when Tavily is configured)

Configure Claude Code to use ragorchestrator:
```bash
export OPENAI_API_BASE=http://localhost:8095
export OPENAI_API_KEY=sk-llm-stack-local
```

Note: DISABLE_WEB_SEARCH=true is set by default until TAVILY_API_KEY is configured.

## ragdeck observability

Use ragdeck (:8092) to monitor both the RAG pipeline and agentic behavior:
- `/querylog-ui` — view queries, grounding decisions, citations
- `/metrics-ui` — Prometheus metrics from ragwatch
- `/agentic/stats` — CRAG retry rate, complexity distribution
- `/agentic/traces/{hash}` — full Self-RAG trace for a query
