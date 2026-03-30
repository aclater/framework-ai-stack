# llm-stack

Local inference stack on harrison.home.arpa (Ryzen AI Max+ 395, Fedora 43).

## Endpoints
- LiteLLM proxy: http://localhost:4000 (key: sk-llm-stack-local)
- Reasoning (QwQ-32B):         http://localhost:8080
- Code (Qwen2.5-Coder-32B):    http://localhost:8081
- Fast / Embed (Qwen2.5-14B):  http://localhost:8082
- Open WebUI:                  http://localhost:3000

## Management
./llm-stack.sh up/down/restart/status/test
./llm-stack.sh logs <reasoning|code|fast|proxy|webui>

## Model selection
- reasoning: hard multi-step problems, architecture decisions, chain-of-thought
- code:      anything you'd send to Claude Code — completion, debugging, generation
- fast:      general chat, drafting, quick queries, embeddings
