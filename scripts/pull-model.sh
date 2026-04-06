#!/usr/bin/env bash
# scripts/pull-model.sh — Source of truth for which model is running
#
# Downloads the current production model (Qwen3.5-122B-A10B-Instruct Q4_K_M)
# and sets SELinux labels so containers can bind-mount it.
#
# The 122B model is a split GGUF (3 shards, ~76.5 GB total).
# llama.cpp auto-discovers shards when pointed to the first one.
#
# Hardware requirements:
#   - 125 GB GTT minimum (128 GB unified memory, BIOS UMA auto)
#   - Model footprint: ~76.5 GB Q4_K_M
#   - KV cache (f16, 65536 ctx, 2 slots): ~4-8 GB
#   - Other services (ragpipe, qdrant, postgres, etc.): ~16 GB
#   - Total: ~100 GB of 125 GB available
#
# Refs: issue #45

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
MODEL_REPO="unsloth/Qwen3.5-122B-A10B-GGUF"
MODEL_SUBFOLDER="Q4_K_M"
MODEL_FIRST_SHARD="Qwen3.5-122B-A10B-Q4_K_M-00001-of-00003.gguf"
MODEL_DIR="$HOME/.local/share/llm-models/Qwen3.5-122B-A10B-Q4_K_M"
MODEL_SIZE_HINT="~76.5 GB (3 shards)"

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo -e "\033[1;34m▸\033[0m $*"; }
ok()   { echo -e "\033[1;32m✓\033[0m $*"; }
warn() { echo -e "\033[1;33m⚠\033[0m $*"; }
fail() { echo -e "\033[1;31m✗\033[0m $*" >&2; exit 1; }

# ── Pre-flight checks ───────────────────────────────────────────────────────
python3 -c "import huggingface_hub" 2>/dev/null \
    || fail "huggingface_hub not found — pip install huggingface-hub"

log "Pulling $MODEL_REPO/$MODEL_SUBFOLDER ($MODEL_SIZE_HINT)"
log "Destination: $MODEL_DIR"

# Check available disk space (need ~80 GB free)
avail_gb=$(df --output=avail -BG "$HOME" | tail -1 | tr -d ' G')
if [[ "$avail_gb" -lt 80 ]]; then
    warn "Only ${avail_gb} GB free — need ~80 GB for download. Proceeding anyway..."
fi

# ── Download ─────────────────────────────────────────────────────────────────
mkdir -p "$MODEL_DIR"

# Use Python huggingface_hub API to download split GGUF shards.
# huggingface-cli may not be on PATH; the Python API is always available.
python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='$MODEL_REPO',
    allow_patterns='${MODEL_SUBFOLDER}/*.gguf',
    local_dir='$MODEL_DIR',
)
"

# snapshot_download creates a subfolder matching the repo structure.
# Move shards to the top level of MODEL_DIR.
if [[ -d "$MODEL_DIR/$MODEL_SUBFOLDER" ]]; then
    mv "$MODEL_DIR/$MODEL_SUBFOLDER"/*.gguf "$MODEL_DIR/" 2>/dev/null || true
    rmdir "$MODEL_DIR/$MODEL_SUBFOLDER" 2>/dev/null || true
fi

# ── Verify shards exist ─────────────────────────────────────────────────────
shard_count=$(find "$MODEL_DIR" -maxdepth 1 -name "*.gguf" -type f | wc -l)
if [[ "$shard_count" -lt 3 ]]; then
    fail "Expected 3 GGUF shards, found $shard_count in $MODEL_DIR"
fi
ok "Downloaded $shard_count GGUF shards"

if [[ ! -f "$MODEL_DIR/$MODEL_FIRST_SHARD" ]]; then
    fail "First shard not found: $MODEL_DIR/$MODEL_FIRST_SHARD"
fi
ok "First shard verified: $MODEL_FIRST_SHARD"

# ── SELinux labels ───────────────────────────────────────────────────────────
log "Setting SELinux labels on model files..."
label_count=$(find "$MODEL_DIR" -name "*.gguf" -type f -print0 \
    | xargs -0 --no-run-if-empty chcon -t container_ro_file_t -l s0 -v 2>/dev/null | wc -l)
if [[ "$label_count" -gt 0 ]]; then
    ok "SELinux labels set on $label_count files"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
total_size=$(du -sh "$MODEL_DIR" | cut -f1)
echo ""
ok "Model ready: $MODEL_DIR ($total_size)"
ok "First shard: $MODEL_DIR/$MODEL_FIRST_SHARD"
echo ""
log "Next steps:"
log "  1. Update ~/.config/llm-stack/tune.conf (or run ./llm-stack.sh tune)"
log "  2. ./llm-stack.sh install"
log "  3. systemctl --user restart llama-vulkan"
