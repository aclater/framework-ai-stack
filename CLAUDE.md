# framework-ai-stack

Local AI stack on harrison.home.arpa (Ryzen AI Max+ 395, Fedora 43). LLM inference + Google Drive RAG watcher.

## Endpoints
- LiteLLM proxy: http://localhost:4000 (key: sk-llm-stack-local)
- Qwen3.5-35B-A3B:            http://localhost:8080
- Open WebUI:                  http://localhost:3000

## Management
./llm-stack.sh up/down/restart/status/test
./llm-stack.sh logs <model|proxy|webui>

## Model aliases
All four aliases route to Qwen3.5-35B-A3B on :8080:
- default: general use
- reasoning: multi-step problems, architecture decisions, chain-of-thought
- code: completion, debugging, generation
- fast: quick queries, drafting
