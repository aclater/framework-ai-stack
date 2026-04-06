#!/usr/bin/env bash
# scripts/pull-model.sh — Source of truth for which model is running
#
# Downloads the current production model (Qwen3-32B dense Q4_K_M)
# and sets SELinux labels so containers can bind-mount it.
#
# Hardware requirements:
#   - 125 GB GTT (128 GB unified memory, BIOS UMA auto)
#   - Model footprint: ~19 GB Q4_K_M
#   - KV cache (f16, 65536 ctx, 2 slots): ~4-8 GB
#   - ~90 GB GTT free after model + services
#
# Refs: issue #47

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
MODEL_REPO="unsloth/Qwen3-32B-GGUF"
MODEL_FILE="Qwen3-32B-Q4_K_M.gguf"
MODEL_SIZE_HINT="~19 GB"

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo -e "\033[1;34m▸\033[0m $*"; }
ok()   { echo -e "\033[1;32m✓\033[0m $*"; }
fail() { echo -e "\033[1;31m✗\033[0m $*" >&2; exit 1; }

# ── Pre-flight checks ───────────────────────────────────────────────────────
command -v ramalama &>/dev/null \
    || fail "ramalama not found — dnf install ramalama"

log "Pulling $MODEL_REPO/$MODEL_FILE ($MODEL_SIZE_HINT)"

# ── Download ─────────────────────────────────────────────────────────────────
ramalama pull "hf://$MODEL_REPO/$MODEL_FILE"

# ── SELinux labels ───────────────────────────────────────────────────────────
log "Setting SELinux labels on model files..."
label_count=$(find "$HOME/.local/share/ramalama/store" -name "*.gguf" -type f -print0 \
    | xargs -0 --no-run-if-empty chcon -t container_ro_file_t -l s0 -v 2>/dev/null | wc -l)
if [[ "$label_count" -gt 0 ]]; then
    ok "SELinux labels set on $label_count files"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
ramalama list | grep -i "qwen3-32b" || true
echo ""
ok "Model ready"
log "Next steps:"
log "  1. Update ~/.config/llm-stack/tune.conf (or run ./llm-stack.sh tune)"
log "  2. ./llm-stack.sh install"
log "  3. systemctl --user restart llama-vulkan"
