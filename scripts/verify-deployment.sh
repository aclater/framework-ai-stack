#!/usr/bin/env bash
# scripts/verify-deployment.sh — post-deploy validation for the AI stack
#
# Checks systemd unit status, health endpoints, Qdrant collections,
# ragpipe test query, and GPU availability.  Prints a summary table.
#
# Usage:
#   scripts/verify-deployment.sh          # one-shot check
#   scripts/verify-deployment.sh --wait   # poll until healthy or 5-min timeout

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

WAIT=false
TIMEOUT_SECONDS=300
POLL_INTERVAL=10

# Services: name|port|health_path|systemd_unit
# Postgres has no HTTP health endpoint — checked via pg_isready
SERVICES=(
  "ragpipe|8090|/health|ragpipe"
  "ragstuffer|8091|/health|ragstuffer"
  "ragdeck|8092|/health|ragdeck"
  "ragstuffer-mpep|8093|/health|ragstuffer-mpep"
  "ragorchestrator|8095|/health|ragorchestrator"
  "ragwatch|9090|/health|ragwatch"
  "qdrant|6333|/readyz|qdrant"
  "litellm|4000|/health|litellm"
  "open-webui|3000||open-webui"
  "llama-vulkan|8080|/health|llama-vulkan"
)

QDRANT_COLLECTIONS=(personnel nato mpep documents)

# ── Argument parsing ──────────────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --wait) WAIT=true ;;
    --help|-h)
      echo "Usage: $0 [--wait]"
      echo "  --wait   Poll until all services healthy or 5-minute timeout"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

# ── Colours (disabled when not a terminal) ────────────────────────────────────

if [[ -t 1 ]]; then
  GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[1;33m'
  BOLD='\033[1m' RESET='\033[0m'
else
  GREEN='' RED='' YELLOW='' BOLD='' RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

# http_check URL -> sets HTTP_CODE and RESPONSE_MS
# Uses curl -sf with IPv4 to avoid Qdrant IPv6 issues on Fedora
http_check() {
  local url="$1"
  local start_ns end_ns
  start_ns=$(date +%s%N)
  if HTTP_CODE=$(curl -4 -sf -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null); then
    end_ns=$(date +%s%N)
    RESPONSE_MS=$(( (end_ns - start_ns) / 1000000 ))
    return 0
  else
    HTTP_CODE=$(curl -4 -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    end_ns=$(date +%s%N)
    RESPONSE_MS=$(( (end_ns - start_ns) / 1000000 ))
    return 1
  fi
}

# ── Single-pass check ────────────────────────────────────────────────────────

# Results arrays (parallel indexed)
declare -a R_SERVICE R_PORT R_SYSTEMD R_HEALTH R_MS
OVERALL_OK=true

run_checks() {
  OVERALL_OK=true
  R_SERVICE=()
  R_PORT=()
  R_SYSTEMD=()
  R_HEALTH=()
  R_MS=()

  local idx=0

  # --- Systemd + health checks per service ---
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name port health_path unit <<< "$entry"
    R_SERVICE+=("$name")
    R_PORT+=("$port")

    # Systemd unit status
    if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
      R_SYSTEMD+=("active")
    else
      R_SYSTEMD+=("inactive")
      OVERALL_OK=false
    fi

    # Health endpoint
    if [[ -z "$health_path" ]]; then
      # No HTTP health path (e.g. open-webui) — just check port responds
      if http_check "http://127.0.0.1:${port}/"; then
        R_HEALTH+=("ok")
      else
        R_HEALTH+=("fail:${HTTP_CODE}")
        OVERALL_OK=false
      fi
    else
      if http_check "http://127.0.0.1:${port}${health_path}"; then
        R_HEALTH+=("ok")
      else
        R_HEALTH+=("fail:${HTTP_CODE}")
        OVERALL_OK=false
      fi
    fi
    R_MS+=("$RESPONSE_MS")

    idx=$((idx + 1))
  done

  # --- Postgres (no HTTP endpoint — use pg_isready) ---
  R_SERVICE+=("postgres")
  R_PORT+=("5432")
  if systemctl --user is-active --quiet postgres 2>/dev/null; then
    R_SYSTEMD+=("active")
  else
    R_SYSTEMD+=("inactive")
    OVERALL_OK=false
  fi

  local pg_start pg_end
  pg_start=$(date +%s%N)
  if pg_isready -h 127.0.0.1 -p 5432 -q 2>/dev/null; then
    pg_end=$(date +%s%N)
    R_HEALTH+=("ok")
    R_MS+=("$(( (pg_end - pg_start) / 1000000 ))")
  else
    pg_end=$(date +%s%N)
    R_HEALTH+=("fail")
    R_MS+=("$(( (pg_end - pg_start) / 1000000 ))")
    OVERALL_OK=false
  fi

  # --- Qdrant collections ---
  local collections_json missing_collections=""
  if collections_json=$(curl -4 -sf --max-time 5 "http://127.0.0.1:6333/collections" 2>/dev/null); then
    for coll in "${QDRANT_COLLECTIONS[@]}"; do
      if ! echo "$collections_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
names = [c['name'] for c in data.get('result', {}).get('collections', [])]
sys.exit(0 if '$coll' in names else 1)
" 2>/dev/null; then
        missing_collections="${missing_collections} ${coll}"
        OVERALL_OK=false
      fi
    done
  else
    missing_collections="(unreachable)"
    OVERALL_OK=false
  fi

  # Store for summary
  MISSING_COLLECTIONS="${missing_collections}"

  # --- ragpipe test query ---
  RAGPIPE_QUERY_OK=false
  local query_payload='{"model":"default","messages":[{"role":"user","content":"ping"}],"max_tokens":8,"stream":false}'
  local response
  if response=$(curl -4 -sf --max-time 30 \
      -H "Content-Type: application/json" \
      -d "$query_payload" \
      "http://127.0.0.1:8090/v1/chat/completions" 2>/dev/null); then
    if echo "$response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
assert 'choices' in data and len(data['choices']) > 0
" 2>/dev/null; then
      RAGPIPE_QUERY_OK=true
    else
      OVERALL_OK=false
    fi
  else
    OVERALL_OK=false
  fi

  # --- GPU check ---
  GPU_STATUS="n/a"
  if command -v rocm-smi &>/dev/null; then
    if rocm-smi --showmeminfo gtt &>/dev/null; then
      GPU_STATUS="ok (ROCm)"
    else
      GPU_STATUS="fail (ROCm)"
    fi
  elif command -v nvidia-smi &>/dev/null; then
    if nvidia-smi &>/dev/null; then
      GPU_STATUS="ok (NVIDIA)"
    else
      GPU_STATUS="fail (NVIDIA)"
    fi
  fi
}

# ── Print summary table ──────────────────────────────────────────────────────

print_summary() {
  echo ""
  printf "${BOLD}%-20s %-6s %-10s %-10s %s${RESET}\n" \
    "SERVICE" "PORT" "SYSTEMD" "HEALTH" "RESPONSE_MS"
  printf "%-20s %-6s %-10s %-10s %s\n" \
    "-------------------" "-----" "---------" "---------" "-----------"

  local i
  for i in "${!R_SERVICE[@]}"; do
    local systemd_color health_color
    if [[ "${R_SYSTEMD[$i]}" == "active" ]]; then
      systemd_color="${GREEN}"
    else
      systemd_color="${RED}"
    fi
    if [[ "${R_HEALTH[$i]}" == "ok" ]]; then
      health_color="${GREEN}"
    else
      health_color="${RED}"
    fi
    printf "%-20s %-6s ${systemd_color}%-10s${RESET} ${health_color}%-10s${RESET} %s\n" \
      "${R_SERVICE[$i]}" "${R_PORT[$i]}" "${R_SYSTEMD[$i]}" "${R_HEALTH[$i]}" "${R_MS[$i]}"
  done

  echo ""

  # Qdrant collections
  if [[ -z "$MISSING_COLLECTIONS" ]]; then
    echo -e "${GREEN}Qdrant collections:${RESET} all present (${QDRANT_COLLECTIONS[*]})"
  else
    echo -e "${RED}Qdrant collections missing:${RESET}${MISSING_COLLECTIONS}"
    echo "  Expected: ${QDRANT_COLLECTIONS[*]}"
  fi

  # ragpipe test query
  if $RAGPIPE_QUERY_OK; then
    echo -e "${GREEN}ragpipe test query:${RESET} ok (choices array present)"
  else
    echo -e "${RED}ragpipe test query:${RESET} failed"
  fi

  # GPU
  echo -e "GPU: ${GPU_STATUS}"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

if $WAIT; then
  echo "Waiting for all services to become healthy (timeout: ${TIMEOUT_SECONDS}s)..."
  elapsed=0
  while true; do
    run_checks
    if $OVERALL_OK; then
      echo ""
      echo -e "${GREEN}All services healthy after ${elapsed}s${RESET}"
      print_summary
      exit 0
    fi
    if [[ $elapsed -ge $TIMEOUT_SECONDS ]]; then
      echo ""
      echo -e "${RED}Timed out after ${TIMEOUT_SECONDS}s — not all services healthy${RESET}"
      print_summary
      exit 1
    fi
    echo "  ... not all healthy yet (${elapsed}s elapsed), retrying in ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
else
  run_checks
  print_summary
  if $OVERALL_OK; then
    echo -e "${GREEN}All checks passed.${RESET}"
    exit 0
  else
    echo -e "${RED}Some checks failed.${RESET}"
    exit 1
  fi
fi
