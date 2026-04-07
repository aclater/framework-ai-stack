#!/bin/bash
# Deployment verification script for rag-suite quadlets

set -uo pipefail

QUADLET_DIR="${QUADLET_DIR:-$HOME/.config/containers/systemd}"
PASS=0
FAIL=0
FAILURES=()

log_pass() {
    echo "[PASS] $1"
    ((PASS++)) || true
}

log_fail() {
    echo "[FAIL] $1"
    ((FAIL++)) || true
    FAILURES+=("$1")
}

check_file_exists() {
    local file="$1"
    local desc="$2"
    if [[ -f "$QUADLET_DIR/$file" ]]; then
        log_pass "$desc"
    else
        log_fail "$desc"
    fi
}

check_no_latest() {
    local file="$1"
    local desc="$2"
    if grep -q ':latest' "$QUADLET_DIR/$file" 2>/dev/null; then
        log_fail "$desc"
    else
        log_pass "$desc"
    fi
}

check_has_healthcmd() {
    local file="$1"
    local desc="$2"
    if grep -q 'HealthCmd=' "$QUADLET_DIR/$file" 2>/dev/null; then
        log_pass "$desc"
    else
        log_fail "$desc"
    fi
}

check_env_var() {
    local file="$1"
    local var="$2"
    local desc="$3"
    if grep -q "$var" "$QUADLET_DIR/$file" 2>/dev/null; then
        log_pass "$desc"
    else
        log_fail "$desc"
    fi
}

echo "Verifying quadlet deployment..."
echo "================================"

echo ""
echo "--- Quadlet files ---"
check_file_exists "ragpipe.container" "ragpipe.container exists"
check_file_exists "ragstuffer.container" "ragstuffer.container exists"
check_file_exists "ragstuffer-mpep.container" "ragstuffer-mpep.container exists"
check_file_exists "ragwatch.container" "ragwatch.container exists"
check_file_exists "ragdeck.container" "ragdeck.container exists"
check_file_exists "ragorchestrator.container" "ragorchestrator.container exists"
check_file_exists "llama-vulkan.container" "llama-vulkan.container exists"
check_file_exists "qdrant.container" "qdrant.container exists"
check_file_exists "litellm.container" "litellm.container exists"
check_file_exists "postgres.container" "postgres.container exists"
check_file_exists "open-webui.container" "open-webui.container exists"

echo ""
echo "--- Quadlet configuration ---"
for f in "$QUADLET_DIR"/*.container; do
    [[ -f "$f" ]] || continue
    fname=$(basename "$f")
    check_no_latest "$fname" "No :latest tags in $fname"
    check_has_healthcmd "$fname" "HealthCmd defined in $fname"
done

if [[ -f "$HOME/.config/llm-stack/ragstack.env" ]]; then
    log_pass "ragstack.env exists"
else
    log_fail "ragstack.env exists"
fi

for f in "$QUADLET_DIR"/llama-vulkan.container "$QUADLET_DIR"/ragorchestrator.container; do
    [[ -f "$f" ]] || continue
    fname=$(basename "$f")
    check_env_var "$fname" "HSA_OVERRIDE_GFX_VERSION=11.5.1" "HSA_OVERRIDE_GFX_VERSION set in $fname"
done

echo ""
echo "--- Running containers ---"
RUNNING=$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)
if [[ "$RUNNING" -gt 0 ]]; then
    log_pass "Containers running ($RUNNING found)"
else
    log_fail "No containers running"
fi

UNHEALTHY_RAW=$(podman ps --format '{{.Status}}' 2>/dev/null | grep -cv '^Up' || echo "0")
UNHEALTHY=$(echo "$UNHEALTHY_RAW" | tr -d '[:space:]')
if [[ "$UNHEALTHY" -eq 0 ]]; then
    log_pass "All containers healthy"
else
    log_fail "Some containers unhealthy ($UNHEALTHY)"
fi

RESTARTED=$(podman ps -a --format '{{.Names}}={{.RestartCount}}' 2>/dev/null | awk -F= '$2 > 3 {print $1}' | wc -l)
if [[ "$RESTARTED" -eq 0 ]]; then
    log_pass "No containers restarted >3 times"
else
    log_fail "$RESTARTED containers restarted >3 times"
fi

echo ""
echo "--- GPU configuration ---"
if command -v rocm-smi &>/dev/null; then
    if rocm-smi --showgfxstats 2>/dev/null | grep -q "gfx1151"; then
        log_pass "ROCm recognizes gfx1151"
    else
        log_fail "ROCm does not recognize gfx1151"
    fi
else
    log_pass "rocm-smi not available (skipping GPU check)"
fi

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo "Failed checks:"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    exit 1
fi

echo "All checks passed!"
exit 0
