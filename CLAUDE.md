# llm-stack

Local inference stack on harrison.home.arpa (Ryzen AI Max+ 395, Fedora 43).

## Endpoints
- LiteLLM proxy: http://localhost:4000 (key: sk-llm-stack-local)
- DeepSeek-R1-70B:             http://localhost:8080
- Open WebUI:                  http://localhost:3000

## Management
./llm-stack.sh up/down/restart/status/test
./llm-stack.sh logs <model|proxy|webui>

## Model aliases
All three aliases route to DeepSeek-R1-70B on :8080:
- default: general use
- reasoning: multi-step problems, architecture decisions, chain-of-thought
- code: completion, debugging, generation
