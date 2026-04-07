#!/usr/bin/env bash
# scripts/rag-status.sh — show health status of all rag-suite services
#
# Checks health endpoints, Qdrant collection counts, GTT memory usage,
# and provides a summary with exit code 0 (all healthy) or 1 (any down).

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Counters ─────────────────────────────────────────────────────────────────

TOTAL=0
HEALTHY=0
UNHEALTHY=0
UNHEALTHY_SERVICES=()

# ── Health check function ────────────────────────────────────────────────────

check_service() {
    local name="$1"
    local url="$2"
    local extra_curl_flags="${3:-}"

    TOTAL=$((TOTAL + 1))
    local start_ms end_ms elapsed_ms http_code

    start_ms=$(date +%s%N)
    # shellcheck disable=SC2086
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        $extra_curl_flags "$url" 2>/dev/null || echo "000")
    end_ms=$(date +%s%N)
    elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))

    if [[ "$http_code" =~ ^(200|204)$ ]]; then
        HEALTHY=$((HEALTHY + 1))
        printf "  ${GREEN}%-20s${RESET} %s  ${DIM}(%d ms)${RESET}\n" \
            "$name" "healthy" "$elapsed_ms"
    else
        UNHEALTHY=$((UNHEALTHY + 1))
        UNHEALTHY_SERVICES+=("$name")
        printf "  ${RED}%-20s${RESET} %s  ${DIM}(HTTP %s, %d ms)${RESET}\n" \
            "$name" "DOWN" "$http_code" "$elapsed_ms"
    fi
}

check_postgres() {
    TOTAL=$((TOTAL + 1))
    local start_ms end_ms elapsed_ms

    start_ms=$(date +%s%N)
    if command -v pg_isready &>/dev/null; then
        if pg_isready -h localhost -U litellm -q -t 5 2>/dev/null; then
            end_ms=$(date +%s%N)
            elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))
            HEALTHY=$((HEALTHY + 1))
            printf "  ${GREEN}%-20s${RESET} %s  ${DIM}(%d ms)${RESET}\n" \
                "postgres" "healthy" "$elapsed_ms"
        else
            end_ms=$(date +%s%N)
            elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))
            UNHEALTHY=$((UNHEALTHY + 1))
            UNHEALTHY_SERVICES+=("postgres")
            printf "  ${RED}%-20s${RESET} %s  ${DIM}(%d ms)${RESET}\n" \
                "postgres" "DOWN" "$elapsed_ms"
        fi
    elif systemctl --user is-active postgres.service &>/dev/null; then
        end_ms=$(date +%s%N)
        elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))
        HEALTHY=$((HEALTHY + 1))
        printf "  ${GREEN}%-20s${RESET} %s  ${DIM}(%d ms, via systemctl)${RESET}\n" \
            "postgres" "healthy" "$elapsed_ms"
    else
        end_ms=$(date +%s%N)
        elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))
        UNHEALTHY=$((UNHEALTHY + 1))
        UNHEALTHY_SERVICES+=("postgres")
        printf "  ${RED}%-20s${RESET} %s  ${DIM}(%d ms)${RESET}\n" \
            "postgres" "DOWN" "$elapsed_ms"
    fi
}

# ── Qdrant collections ──────────────────────────────────────────────────────

show_qdrant_collections() {
    local collections_json
    collections_json=$(curl -4 -s --max-time 5 http://localhost:6333/collections 2>/dev/null) || {
        echo -e "  ${YELLOW}Could not reach Qdrant — skipping collection counts${RESET}"
        return
    }

    local names
    names=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for c in data.get('result', {}).get('collections', []):
    print(c['name'])
" <<< "$collections_json" 2>/dev/null) || {
        echo -e "  ${YELLOW}Could not parse Qdrant collections response${RESET}"
        return
    }

    if [[ -z "$names" ]]; then
        echo -e "  ${YELLOW}No collections found${RESET}"
        return
    fi

    while IFS= read -r name; do
        local info
        info=$(curl -4 -s --max-time 5 "http://localhost:6333/collections/$name" 2>/dev/null) || continue
        local count
        count=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
print(data.get('result', {}).get('points_count', 'unknown'))
" <<< "$info" 2>/dev/null) || count="unknown"
        printf "  %-20s %s points\n" "$name" "$count"
    done <<< "$names"
}

# ── GTT memory ───────────────────────────────────────────────────────────────

show_gtt_memory() {
    if ! command -v rocm-smi &>/dev/null; then
        echo -e "  ${YELLOW}rocm-smi not available — skipping GTT display${RESET}"
        return
    fi

    local gtt_output
    gtt_output=$(rocm-smi --showmeminfo gtt 2>/dev/null) || {
        echo -e "  ${YELLOW}rocm-smi failed — skipping GTT display${RESET}"
        return
    }

    # Output format: "GPU[0]		: GTT Total Memory (B): 113246208000"
    local total_bytes used_bytes
    total_bytes=$(echo "$gtt_output" | sed -n 's/.*GTT Total Memory (B): *\([0-9]*\)/\1/p' | head -1)
    used_bytes=$(echo "$gtt_output" | sed -n 's/.*GTT Total Used Memory (B): *\([0-9]*\)/\1/p' | head -1)

    if [[ -z "$total_bytes" || -z "$used_bytes" ]]; then
        echo -e "  ${YELLOW}Could not parse GTT memory output${RESET}"
        return
    fi

    # Convert bytes to GB (divide by 1024^3)
    local total_gb used_gb free_gb pct
    total_gb=$(python3 -c "print(f'{$total_bytes / (1024**3):.1f}')")
    used_gb=$(python3 -c "print(f'{$used_bytes / (1024**3):.1f}')")
    free_gb=$(python3 -c "print(f'{($total_bytes - $used_bytes) / (1024**3):.1f}')")
    pct=$(python3 -c "print(f'{$used_bytes / $total_bytes * 100:.0f}')")

    printf "  Total:  %s GB\n" "$total_gb"
    printf "  Used:   %s GB (%s%%)\n" "$used_gb" "$pct"
    printf "  Free:   %s GB\n" "$free_gb"
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}rag-suite service health${RESET}"
echo -e "${BOLD}========================${RESET}"
echo ""

echo -e "${BOLD}Services${RESET}"
check_service "ragpipe"          "http://localhost:8090/health"
check_service "ragstuffer"       "http://localhost:8091/health"
check_service "ragstuffer-mpep"  "http://localhost:8093/health"
check_service "ragdeck"          "http://localhost:8092/health"
check_service "ragorchestrator"  "http://localhost:8095/health"
check_service "ragwatch"         "http://localhost:9090/health"
check_service "llama-vulkan"     "http://localhost:8080/health"
check_service "qdrant"           "http://localhost:6333/readyz" "-4"
check_service "litellm"          "http://localhost:4000/health"
check_service "open-webui"       "http://localhost:3000/health"
check_postgres

echo ""
echo -e "${BOLD}Qdrant collections${RESET}"
show_qdrant_collections

echo ""
echo -e "${BOLD}GTT memory${RESET}"
show_gtt_memory

echo ""
echo -e "${BOLD}Summary${RESET}"
echo -e "  Total:     $TOTAL services"
echo -e "  ${GREEN}Healthy:   $HEALTHY${RESET}"

if [[ "$UNHEALTHY" -gt 0 ]]; then
    echo -e "  ${RED}Unhealthy: $UNHEALTHY${RESET}"
    echo ""
    echo -e "  ${RED}Down services:${RESET}"
    for svc in "${UNHEALTHY_SERVICES[@]}"; do
        echo -e "    ${RED}- $svc${RESET}"
    done
    echo ""
    exit 1
else
    echo -e "  Unhealthy: 0"
    echo ""
    echo -e "  ${GREEN}All services healthy${RESET}"
    echo ""
    exit 0
fi
