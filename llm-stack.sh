#!/usr/bin/env bash
# llm-stack.sh — local LLM stack management
# Fedora 43 · Ryzen AI Max+ 395 · RamaLama + Podman Quadlets
#
# Usage: ./llm-stack.sh <command>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUADLET_DIR="$HOME/.config/containers/systemd"
CONFIG_DIR="$HOME/.config/llm-stack"
UNITS=(postgres qdrant ramalama ragpipe litellm ragstuffer open-webui)

# ── GPU detection ────────────────────────────────────────────────────────────
# Auto-detect GPU vendor and VRAM to select the right container image, model,
# and quadlet overrides. Per-profile overrides live in hosts/<profile>/quadlets/
# and are overlaid onto the base quadlets/ during install.
#
# Profiles:
#   nvidia  — NVIDIA GPU (CUDA)
#   rocm    — AMD GPU (ROCm)
#   gfx1151 — AMD Strix Halo (gfx1151) with Vulkan backend
# Model selection is controlled by MODEL_PREFERENCE (general or coder)
# combined with available VRAM. See env.example for details.
_detect_gpu() {
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        GPU_VENDOR="nvidia"
        GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    elif [[ -e /dev/kfd ]]; then
        GPU_VENDOR="rocm"
        local vram_bytes
        vram_bytes=$(cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | head -1)
        GPU_VRAM_MB=$(( ${vram_bytes:-0} / 1048576 ))
        GPU_NAME=$(rocminfo 2>/dev/null | grep -oP 'gfx[0-9a-f]+' | head -1 || echo "unknown")
    else
        GPU_VENDOR="cpu"
        GPU_VRAM_MB=0
        GPU_NAME="none"
    fi
}
_detect_gpu

GPU_PROFILE="$GPU_VENDOR"
if [[ "$GPU_VENDOR" == "rocm" && "$GPU_NAME" == "gfx1151" ]]; then
    GPU_PROFILE="gfx1151"
    # gfx1151 uses llama-vulkan instead of ramalama (Vulkan RADV, not ROCm)
    UNITS=("${UNITS[@]/ramalama/llama-vulkan}")
fi
HOST_DIR="$SCRIPT_DIR/hosts/$GPU_PROFILE"
if [[ -d "$HOST_DIR" ]]; then
    HOST_QUADLET_SRC="$HOST_DIR/quadlets"
else
    HOST_QUADLET_SRC=""
fi

# ── Tuning config ────────────────────────────────────────────────────────────
# Load tune.conf if it exists (written by cmd_tune), otherwise use safe defaults.
# Run ./llm-stack.sh tune to generate optimal settings for this hardware.
TUNE_CONF="$HOME/.config/llm-stack/tune.conf"
if [[ -f "$TUNE_CONF" ]]; then
    # shellcheck source=/dev/null
    source "$TUNE_CONF"
else
    # Safe defaults until tune is run — Q4 smallest model that fits
    if [[ "$GPU_VRAM_MB" -ge 32000 ]]; then
        MODEL_REPO="unsloth/Qwen3.5-35B-A3B-GGUF"
        MODEL_FILE="Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf"
        MODEL_SIZE_HINT="~22 GB"
        MODEL_DESC="Qwen3.5-35B-A3B Q4"
    else
        MODEL_REPO="unsloth/Qwen3.5-9B-GGUF"
        MODEL_FILE="Qwen3.5-9B-UD-Q4_K_XL.gguf"
        MODEL_SIZE_HINT="~6 GB"
        MODEL_DESC="Qwen3.5-9B Q4"
    fi
    TUNE_CTX_SIZE=32768
    TUNE_PARALLEL=2
    TUNE_THREADS=$(nproc)
    TUNE_BATCH_SIZE=2048
    TUNE_UBATCH_SIZE=512
    TUNE_CACHE_TYPE_K=q4_0
    TUNE_CACHE_TYPE_V=q4_0
    TUNE_FLASH_ATTN=on
    TUNE_MLOCK=""
    TUNE_EXTRA_ARGS=""
fi

# Registry candidates for the inference image, in preference order
ROCM_IMAGES=(
    "quay.io/ramalama/rocm:latest"
    "ghcr.io/ggml-org/llama.cpp:full-rocm"
)
CUDA_IMAGES=(
    "quay.io/ramalama/cuda:latest"
    "ghcr.io/ggml-org/llama.cpp:server-cuda"
)

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
    BOLD='\033[1m' RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

log()  { echo -e "  ${BOLD}→${RESET} $*"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
warn() { echo -e "  ${YELLOW}!${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}━━━  $*  ━━━${RESET}\n"; }

# ── Help ──────────────────────────────────────────────────────────────────────

cmd_help() {
    cat <<EOF

${BOLD}llm-stack.sh${RESET} — local LLM stack (Fedora 43 · $GPU_VENDOR · $MODEL_DESC)

${BOLD}First-time setup (run in order):${RESET}
  deps          install system packages via dnf       [needs sudo]
  groups        add user to render/video groups       [needs sudo + reboot]
  setup         verify GPU, write configs
  pull-image    pull the RamaLama ROCm container image
  tune          auto-detect hardware and compute optimal parameters
  pull-models   download model (size depends on tune)
  build         build ragpipe and ragstuffer container images
  install       install quadlets to systemd (applies tune.conf)
  up            start all services

${BOLD}Operations:${RESET}
  up            start all services
  down          stop all services
  restart       restart all services
  status        show unit states
  test          smoke-test inference

${BOLD}Logs:${RESET}
  logs <service>    follow logs (model|proxy|ragpipe|rag|qdrant|webui|postgres)

${BOLD}Models:${RESET}
  pull-image              pull ROCm container image (with registry fallback)
  swap <hf://…>           hot-swap the model

${BOLD}Tuning:${RESET}
  tune          auto-detect hardware, select model + quant + params
  retune        re-tune and restart ramalama (no model download)

${BOLD}Teardown:${RESET}
  uninstall     remove quadlets (models kept)

${BOLD}Endpoints (once running):${RESET}
  LiteLLM proxy  →  http://localhost:4000
  Open WebUI     →  http://localhost:3000
  Qwen3.5-35B    →  http://localhost:8080

EOF
}

# ── Dependency installation ───────────────────────────────────────────────────

cmd_deps() {
    header "Installing system dependencies"
    [[ "$(id -u)" == "0" ]] && fail "Run as your regular user, not root"

    local packages=(podman podman-compose ramalama curl python3 git)

    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
        log "NVIDIA GPU detected ($GPU_NAME, ${GPU_VRAM_MB} MB) — adding CUDA packages"
        packages+=(nvidia-container-toolkit)
    else
        log "AMD GPU detected ($GPU_NAME, $(( GPU_VRAM_MB / 1024 )) GB) — adding ROCm packages"
        packages+=(rocm rocm-hip rocm-runtime rocminfo amd-gpu-firmware)
    fi

    sudo dnf makecache --refresh
    sudo dnf install -y "${packages[@]}"
    sudo dnf install -y amd-smi 2>/dev/null || warn "amd-smi not available — skipping"

    log "Enabling systemd user lingering..."
    sudo loginctl enable-linger "$(whoami)"

    log "Starting user podman socket..."
    systemctl --user enable --now podman.socket

    echo ""
    ok "Dependencies installed"
    warn "Next: run './llm-stack.sh groups' then reboot"
}

# ── Group membership ──────────────────────────────────────────────────────────

cmd_groups() {
    log "Adding $(whoami) to render and video groups..."
    sudo usermod -aG render,video "$(whoami)"
    echo ""
    ok "Done — reboot for group changes to take effect"
    warn "After rebooting, run: ./llm-stack.sh setup"
}

# ── Setup ─────────────────────────────────────────────────────────────────────

cmd_setup() {
    header "Setup"
    [[ "$(id -u)" == "0" ]] && fail "Do not run as root — this stack is rootless"

    # Dependencies
    echo ""
    log "Checking installed commands..."
    local missing=()
    for cmd in podman ramalama curl python3; do
        if command -v "$cmd" &>/dev/null; then
            printf "  ${GREEN}✓${RESET} %-12s %s\n" "$cmd" "$("$cmd" --version 2>/dev/null | head -1)"
        else
            printf "  ${RED}✗${RESET} %-12s NOT FOUND\n" "$cmd"
            missing+=("$cmd")
        fi
    done
    [[ ${#missing[@]} -gt 0 ]] && fail "Missing: ${missing[*]}. Run './llm-stack.sh deps' first."

    # Groups
    echo ""
    log "Checking group membership..."
    local user
    user="$(whoami)"
    for grp in render video; do
        if grep -qP "^${grp}:.*\b${user}\b" /etc/group; then
            ok "$grp"
        else
            fail "Not in '$grp' group. Run './llm-stack.sh groups' then reboot."
        fi
    done

    # GPU
    echo ""
    log "Detected GPU: $GPU_VENDOR ($GPU_NAME, $(( GPU_VRAM_MB / 1024 )) GB VRAM)"
    log "Model selection: $MODEL_DESC ($MODEL_SIZE_HINT)"
    if [[ -n "$HOST_QUADLET_SRC" ]]; then
        log "Profile: hosts/$GPU_PROFILE/ (overlay active)"
    else
        log "Profile: base quadlets (no overlay)"
    fi
    echo ""

    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
        log "Checking GPU / CUDA..."
        ok "NVIDIA GPU: $GPU_NAME"
        ok "VRAM: $(( GPU_VRAM_MB )) MB"
        [[ -f /etc/cdi/nvidia.yaml ]] && ok "CDI config present" \
            || warn "CDI config missing — run: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
    else
        log "Checking GPU / ROCm..."
        for dev in /dev/kfd /dev/dri; do
            [[ -e "$dev" ]] && ok "$dev present" || warn "$dev MISSING"
        done

        if command -v rocminfo &>/dev/null; then
            local gfx
            gfx=$(rocminfo 2>/dev/null | grep -oP 'gfx[0-9a-f]+' | head -1)
            if [[ -n "$gfx" ]]; then
                ok "ROCm GPU: $gfx"
                if [[ "$gfx" == "gfx1151" ]]; then
                    echo ""
                    echo -e "  ${YELLOW}┌─ NOTE: gfx1151 (AI Max+ 395) ────────────────────────────────────┐${RESET}"
                    echo -e "  ${YELLOW}│${RESET} ROCm 6.4.x in Fedora 43 has known issues on gfx1151.           ${YELLOW}│${RESET}"
                    echo -e "  ${YELLOW}│${RESET} HSA_OVERRIDE_GFX_VERSION=11.5.1 is set in your env file.       ${YELLOW}│${RESET}"
                    echo -e "  ${YELLOW}│${RESET} Fix expected in ROCm 7.x (Fedora 44).                          ${YELLOW}│${RESET}"
                    echo -e "  ${YELLOW}└───────────────────────────────────────────────────────────────────┘${RESET}"
                fi
            else
                warn "rocminfo found no GPU — check: lsmod | grep amdgpu"
            fi
        else
            warn "No GPU tooling found — install nvidia-smi or rocminfo"
        fi
    fi

    if command -v ramalama &>/dev/null; then
        local accel
        accel=$(ramalama info 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('Accelerator','unknown'))" \
            2>/dev/null || echo "unknown")
        echo "  ramalama accelerator: $accel"
    fi

    # Directories and config
    echo ""
    log "Creating directories..."
    mkdir -p "$CONFIG_DIR" "$QUADLET_DIR" "$HOME/.local/share/ramalama/models"
    ok "$CONFIG_DIR"
    ok "$QUADLET_DIR"

    if [[ ! -f "$CONFIG_DIR/env" ]]; then
        cp "$SCRIPT_DIR/env.example" "$CONFIG_DIR/env"
        ok "Created $CONFIG_DIR/env — review before pulling models"
    else
        ok "$CONFIG_DIR/env already exists"
    fi

    cp "$SCRIPT_DIR/configs/litellm-config.yaml" "$CONFIG_DIR/litellm-config.yaml"
    ok "Copied litellm-config.yaml"

    # ragpipe system prompt — operator-editable without rebuilding the image
    mkdir -p "$HOME/.config/ragpipe"
    if [[ ! -f "$HOME/.config/ragpipe/system-prompt.txt" ]]; then
        cp "$SCRIPT_DIR/config/ragpipe/system-prompt.txt" "$HOME/.config/ragpipe/system-prompt.txt"
        ok "Copied system-prompt.txt — edit ~/.config/ragpipe/system-prompt.txt to customize"
    else
        ok "ragpipe system prompt already present"
    fi

    if [[ "$GPU_VENDOR" != "nvidia" ]]; then
        if ! grep -q 'HSA_OVERRIDE_GFX_VERSION' "$HOME/.bashrc" 2>/dev/null; then
            printf '\n# LLM Stack — AMD ROCm\nexport HSA_OVERRIDE_GFX_VERSION=11.5.1\n' \
                >> "$HOME/.bashrc"
            ok "Added ROCm env vars to ~/.bashrc"
        else
            ok "ROCm env vars already in ~/.bashrc"
        fi
    fi

    # Auto-tune on first setup
    echo ""
    cmd_tune

    echo ""
    ok "Setup complete — next: ./llm-stack.sh pull-image"
}

# ── Image pulling (with fallback) ─────────────────────────────────────────────

cmd_pull_image() {
    local -a candidates
    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
        header "Pulling llama.cpp CUDA container image"
        candidates=("${CUDA_IMAGES[@]}")
    else
        header "Pulling RamaLama ROCm container image"
        candidates=("${ROCM_IMAGES[@]}")
    fi

    local pulled=""
    for image in "${candidates[@]}"; do
        local registry="${image%%/*}"
        log "Trying: $image"
        log "Checking registry: $registry"

        local status
        status=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
            "https://$registry/v2/" 2>/dev/null || true)

        if [[ "$status" == "200" || "$status" == "401" ]]; then
            ok "Registry $registry reachable (HTTP $status)"
            if podman pull "$image"; then
                ok "Pulled: $image"
                pulled="$image"
                break
            else
                warn "Pull failed despite registry being up"
            fi
        else
            warn "Registry $registry returned HTTP $status — skipping"
        fi
        echo ""
    done

    if [[ -z "$pulled" ]]; then
        fail "All registries failed.\n  quay.io status: https://status.redhat.com\n  ghcr.io status:  https://www.githubstatus.com"
    fi

    # Update image reference in source and installed quadlets
    log "Updating quadlets to use: $pulled"
    for f in "$SCRIPT_DIR"/quadlets/ramalama*.container; do
        [[ -f "$f" ]] || continue
        sed -i "s|^Image=.*|Image=$pulled|" "$f"
        ok "Updated source: $(basename "$f")"
    done
    for f in "$QUADLET_DIR"/ramalama*.container; do
        [[ -f "$f" ]] || continue
        sed -i "s|^Image=.*|Image=$pulled|" "$f"
        ok "Updated installed: $(basename "$f")"
    done
    systemctl --user daemon-reload
}

# ── Auto-tuning ──────────────────────────────────────────────────────────────
# Detects hardware and computes optimal llama-server parameters.
# Writes ~/.config/llm-stack/tune.conf which is sourced at startup
# and consumed by install to template the quadlet Exec line.

# Known model sizes in MB for VRAM budget calculations
declare -A QWEN35_35B_SIZES=(
    [Q4_K_XL]=21200  [Q6_K_XL]=32870  [Q8_K_XL]=49900
)
declare -A QWEN35_9B_SIZES=(
    [Q4_K_XL]=5730   [Q6_K_XL]=8980   [Q8_0]=9750
)
declare -A QWEN3_CODER_30B_SIZES=(
    [Q2_K]=10500  [Q3_K_S]=12400  [Q3_K_M]=13700  [Q4_K_S]=16300  [Q4_K_M]=17300
)
# KV cache size per 1K context tokens (MB) at each quantization level
# These are approximate — actual size depends on model architecture
declare -A KV_PER_1K_CTX=(
    [q4_0_35b]=5.5   [q8_0_35b]=11.0
    [q4_0_9b]=8.8    [q8_0_9b]=17.6
    [q4_0_coder]=5.5  [q8_0_coder]=11.0
)

cmd_tune() {
    header "Auto-tuning for $(hostname -s)"

    local sys_ram_mb
    sys_ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    local cpu_cores
    cpu_cores=$(nproc)

    log "Hardware detected:"
    log "  GPU:      $GPU_VENDOR ($GPU_NAME)"
    log "  VRAM:     $(( GPU_VRAM_MB )) MB"
    log "  RAM:      $(( sys_ram_mb )) MB"
    log "  CPU:      $cpu_cores cores"
    echo ""

    # ── Model preference ─────────────────────────────────────────────────
    # Read MODEL_PREFERENCE from env file. If not set, ask interactively.
    # Persisted in tune.conf so future retunes honor it.
    local model_pref="${MODEL_PREFERENCE:-}"
    if [[ -z "$model_pref" ]]; then
        # Source env file to check for preference
        local env_file="$CONFIG_DIR/env"
        if [[ -f "$env_file" ]]; then
            model_pref=$(grep -oP '^MODEL_PREFERENCE=\K\S+' "$env_file" 2>/dev/null || true)
        fi
    fi

    if [[ -z "$model_pref" ]]; then
        echo ""
        echo "  Model families:"
        echo "    general — Qwen3.5 (best for RAG and general use)"
        echo "    coder   — Qwen3-Coder (code-focused, also handles general queries)"
        echo ""
        read -rp "  Select model family [general]: " model_pref
        model_pref="${model_pref:-general}"

        # Persist the preference so future tunes/deploys honor it
        local env_file="$CONFIG_DIR/env"
        if [[ -f "$env_file" ]]; then
            if grep -q '^MODEL_PREFERENCE=' "$env_file" 2>/dev/null; then
                sed -i "s/^MODEL_PREFERENCE=.*/MODEL_PREFERENCE=$model_pref/" "$env_file"
            elif grep -q '^# MODEL_PREFERENCE=' "$env_file" 2>/dev/null; then
                sed -i "s/^# MODEL_PREFERENCE=.*/MODEL_PREFERENCE=$model_pref/" "$env_file"
            else
                echo "MODEL_PREFERENCE=$model_pref" >> "$env_file"
            fi
            ok "Saved MODEL_PREFERENCE=$model_pref to env"
        fi
    fi
    ok "Model preference: $model_pref"

    # ── Model family selection ─────────────────────────────────────────
    local model_family
    if [[ "$model_pref" == "coder" ]]; then
        model_family="coder"
    elif [[ "$GPU_VRAM_MB" -ge 32000 ]]; then
        model_family="35b"
    else
        model_family="9b"
    fi

    # ── Quantization selection ──────────────────────────────────────────
    # Pick the highest quality quantization that fits in VRAM with room
    # for KV cache (~15% of remaining VRAM) and runtime overhead (~500 MB)
    local quant model_mb kv_budget_mb
    local overhead_mb=500
    local vram_available=$(( GPU_VRAM_MB - overhead_mb ))

    if [[ "$model_family" == "35b" ]]; then
        # ROCm on gfx1151 hangs during context allocation with Q8 (45 GB+).
        # Cap at Q6_K_XL for ROCm until upstream fixes large VRAM allocations.
        local max_quant_35b="Q8_K_XL"
        [[ "$GPU_VENDOR" == "rocm" ]] && max_quant_35b="Q6_K_XL"

        if [[ "$max_quant_35b" == "Q8_K_XL" ]] && [[ $(( vram_available )) -ge ${QWEN35_35B_SIZES[Q8_K_XL]} ]]; then
            quant="Q8_K_XL"; model_mb=${QWEN35_35B_SIZES[Q8_K_XL]}
        elif [[ $(( vram_available )) -ge ${QWEN35_35B_SIZES[Q6_K_XL]} ]]; then
            quant="Q6_K_XL"; model_mb=${QWEN35_35B_SIZES[Q6_K_XL]}
        else
            quant="Q4_K_XL"; model_mb=${QWEN35_35B_SIZES[Q4_K_XL]}
        fi
    elif [[ "$model_family" == "coder" ]]; then
        if [[ $(( vram_available )) -ge ${QWEN3_CODER_30B_SIZES[Q4_K_M]} ]]; then
            quant="Q4_K_M"; model_mb=${QWEN3_CODER_30B_SIZES[Q4_K_M]}
        elif [[ $(( vram_available )) -ge ${QWEN3_CODER_30B_SIZES[Q3_K_M]} ]]; then
            quant="Q3_K_M"; model_mb=${QWEN3_CODER_30B_SIZES[Q3_K_M]}
        elif [[ $(( vram_available )) -ge ${QWEN3_CODER_30B_SIZES[Q3_K_S]} ]]; then
            quant="Q3_K_S"; model_mb=${QWEN3_CODER_30B_SIZES[Q3_K_S]}
        else
            quant="Q2_K"; model_mb=${QWEN3_CODER_30B_SIZES[Q2_K]}
        fi
    else
        if [[ $(( vram_available )) -ge ${QWEN35_9B_SIZES[Q8_0]} ]]; then
            quant="Q8_0"; model_mb=${QWEN35_9B_SIZES[Q8_0]}
        elif [[ $(( vram_available )) -ge ${QWEN35_9B_SIZES[Q6_K_XL]} ]]; then
            quant="Q6_K_XL"; model_mb=${QWEN35_9B_SIZES[Q6_K_XL]}
        else
            quant="Q4_K_XL"; model_mb=${QWEN35_9B_SIZES[Q4_K_XL]}
        fi
    fi

    local model_display
    case "$model_family" in
        35b)   model_display="Qwen3.5-35B-A3B" ;;
        9b)    model_display="Qwen3.5-9B" ;;
        coder) model_display="Qwen3-Coder-30B-A3B" ;;
    esac
    local vram_after_model=$(( vram_available - model_mb ))
    ok "Model: $model_display $quant (${model_mb} MB) — ${vram_after_model} MB VRAM remaining"

    # ── KV cache type ───────────────────────────────────────────────────
    # Use q8_0 if we have >2 GB VRAM headroom after model, otherwise q4_0
    local cache_type
    if [[ "$vram_after_model" -ge 2048 ]]; then
        cache_type="q8_0"
    else
        cache_type="q4_0"
    fi
    ok "KV cache: $cache_type"

    # ── Context size and parallel slots ─────────────────────────────────
    # Budget: remaining VRAM after model, minus 500 MB safety margin
    # Each slot gets ctx_size/parallel tokens of KV cache
    local kv_family="$model_family"
    [[ "$kv_family" == "coder" ]] && kv_family="coder"
    local kv_key="${cache_type}_${kv_family}"
    local kv_per_1k=${KV_PER_1K_CTX[$kv_key]:-8}
    local kv_budget_mb=$(( vram_after_model - 500 ))
    [[ "$kv_budget_mb" -lt 256 ]] && kv_budget_mb=256

    # Start with 2 parallel slots, compute max context
    local parallel=2
    local max_ctx_1k=$(( kv_budget_mb * 10 / (${kv_per_1k%.*} * 10) ))
    # Round down to nearest 8K and cap at 65536
    local ctx_size=$(( max_ctx_1k * 1024 ))
    ctx_size=$(( (ctx_size / 8192) * 8192 ))
    [[ "$ctx_size" -gt 65536 ]] && ctx_size=65536
    [[ "$ctx_size" -lt 8192 ]] && ctx_size=8192

    ok "Context: $ctx_size total ($((ctx_size / parallel))K per slot, $parallel parallel)"

    # ── Batch sizes ─────────────────────────────────────────────────────
    # Larger batches = faster prompt processing, costs more memory
    local batch_size=2048
    local ubatch_size=512
    if [[ "$sys_ram_mb" -ge 32000 && "$GPU_VRAM_MB" -ge 16000 ]]; then
        batch_size=4096
        ubatch_size=1024
    fi
    ok "Batch: $batch_size / ubatch: $ubatch_size"

    # ── Thread count ────────────────────────────────────────────────────
    # Use physical cores, not hyperthreads — HT adds contention for
    # memory-bound inference workloads
    local threads=$(( cpu_cores / 2 ))
    [[ "$threads" -lt 4 ]] && threads=4
    [[ "$threads" -gt 32 ]] && threads=32
    ok "Threads: $threads (of $cpu_cores logical)"

    # ── mlock ───────────────────────────────────────────────────────────
    # Lock model in RAM to prevent swapping. Requires RLIMIT_MEMLOCK
    # to be raised (e.g. via /etc/security/limits.d/). Disabled by
    # default because rootless containers inherit the default 64K limit.
    # Enable manually in tune.conf after raising the ulimit.
    local mlock_flag=""
    ok "mlock: disabled (raise RLIMIT_MEMLOCK and edit tune.conf to enable)"

    # ── Sampling parameters ─────────────────────────────────────────────
    # Conservative defaults for RAG — prioritize accuracy over creativity
    local sampling="--temp 0.7 --top-p 0.95 --top-k 30 --min-p 0.05 --presence-penalty 0.8 --repeat-penalty 1.0"
    ok "Sampling: temp=0.7 top-p=0.95 top-k=30 min-p=0.05 presence=0.8"

    # ── Model file names ────────────────────────────────────────────────
    local model_repo model_file model_size_hint model_desc
    if [[ "$model_family" == "35b" ]]; then
        model_repo="unsloth/Qwen3.5-35B-A3B-GGUF"
        model_file="Qwen3.5-35B-A3B-UD-${quant}.gguf"
        model_size_hint="~$(( model_mb / 1024 )) GB"
        model_desc="Qwen3.5-35B-A3B ${quant}"
    elif [[ "$model_family" == "coder" ]]; then
        model_repo="unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
        if [[ "$quant" == "Q2_K" || "$quant" == "Q3_K_S" || "$quant" == "Q3_K_M" || "$quant" == "Q4_K_S" || "$quant" == "Q4_K_M" ]]; then
            model_file="Qwen3-Coder-30B-A3B-Instruct-${quant}.gguf"
        else
            model_file="Qwen3-Coder-30B-A3B-Instruct-UD-${quant}.gguf"
        fi
        model_size_hint="~$(( model_mb / 1024 )) GB"
        model_desc="Qwen3-Coder-30B-A3B ${quant}"
    else
        model_repo="unsloth/Qwen3.5-9B-GGUF"
        if [[ "$quant" == "Q8_0" ]]; then
            model_file="Qwen3.5-9B-${quant}.gguf"
        else
            model_file="Qwen3.5-9B-UD-${quant}.gguf"
        fi
        model_size_hint="~$(( model_mb / 1024 )) GB"
        model_desc="Qwen3.5-9B ${quant}"
    fi

    # ── Write tune.conf ─────────────────────────────────────────────────
    mkdir -p "$CONFIG_DIR"
    cat > "$TUNE_CONF" <<TUNEEOF
# Auto-generated by llm-stack.sh tune on $(date -Iseconds)
# Hardware: $GPU_VENDOR $GPU_NAME, ${GPU_VRAM_MB} MB VRAM, ${sys_ram_mb} MB RAM, ${cpu_cores} cores
# Re-run: ./llm-stack.sh tune

# Model preference (general or coder)
MODEL_PREFERENCE="$model_pref"

# Model
MODEL_REPO="$model_repo"
MODEL_FILE="$model_file"
MODEL_SIZE_HINT="$model_size_hint"
MODEL_DESC="$model_desc"

# llama-server parameters
TUNE_CTX_SIZE=$ctx_size
TUNE_PARALLEL=$parallel
TUNE_THREADS=$threads
TUNE_BATCH_SIZE=$batch_size
TUNE_UBATCH_SIZE=$ubatch_size
TUNE_CACHE_TYPE_K=$cache_type
TUNE_CACHE_TYPE_V=$cache_type
TUNE_FLASH_ATTN=on
TUNE_MLOCK="$mlock_flag"
TUNE_SAMPLING="$sampling"
TUNE_EXTRA_ARGS=""
TUNEEOF

    ok "Wrote $TUNE_CONF"
    echo ""
    log "To apply: ./llm-stack.sh pull-models && ./llm-stack.sh install"
    log "To apply without model change: ./llm-stack.sh retune"
}

cmd_retune() {
    cmd_tune
    header "Applying tuned configuration"

    # Re-source the freshly written config
    # shellcheck source=/dev/null
    source "$TUNE_CONF"

    # Re-install quadlets with new params and restart ramalama
    cmd_install
    log "Restarting ramalama with new parameters..."
    systemctl --user restart ramalama
    sleep 5
    if systemctl --user is-active ramalama &>/dev/null; then
        ok "ramalama running with tuned config"
    else
        warn "ramalama failed to start — check: ./llm-stack.sh logs model"
    fi
}

# ── Model pulling ─────────────────────────────────────────────────────────────

cmd_pull_models() {
    header "Pulling model ($MODEL_SIZE_HINT)"
    log "$MODEL_DESC ($MODEL_FILE)..."

    if command -v ramalama &>/dev/null; then
        ramalama pull "hf://$MODEL_REPO/$MODEL_FILE"
    else
        local model_dir="$HOME/.local/share/llm-models"
        mkdir -p "$model_dir"
        log "ramalama not found — using huggingface-cli"
        huggingface-cli download "$MODEL_REPO" "$MODEL_FILE" \
            --local-dir "$model_dir"
    fi
    echo ""

    log "Setting SELinux labels on model files..."
    local label_count
    label_count=$(find "$HOME/.local/share/ramalama/store" -name "*.gguf" -type f -print0 2>/dev/null \
        | xargs -0 --no-run-if-empty chcon -t container_ro_file_t -l s0 -v 2>/dev/null | wc -l)
    if [[ "$label_count" -gt 0 ]]; then
        ok "SELinux labels set on $label_count .gguf files"
    fi

    header "Model pulled"
    ramalama list
    echo ""
    ok "Next: ./llm-stack.sh install"
}

# ── Container image build ────────────────────────────────────────────────────

cmd_build() {
    header "Building container images"

    log "Pulling ragpipe image..."
    podman pull ghcr.io/aclater/ragpipe:main \
        && ok "ghcr.io/aclater/ragpipe:main" \
        || fail "ragpipe pull failed"

    log "Building ragstuffer image..."
    local ragstuffer_dir="$HOME/git/ragstuffer"
    if [[ ! -d "$ragstuffer_dir" ]]; then
        fail "ragstuffer not found at $ragstuffer_dir — clone https://github.com/aclater/ragstuffer"
    fi

    # Select GPU-appropriate Containerfile
    local containerfile="Containerfile"
    if [[ "$GPU_VENDOR" == "nvidia" ]] && [[ -f "$ragstuffer_dir/Containerfile.cuda" ]]; then
        containerfile="Containerfile.cuda"
        log "Using CUDA Containerfile (NVIDIA GPU detected)"
    elif [[ "$GPU_VENDOR" == "rocm" ]] && [[ -f "$ragstuffer_dir/Containerfile.rocm" ]]; then
        containerfile="Containerfile.rocm"
        log "Using ROCm Containerfile (AMD GPU detected)"
    fi

    podman build -t localhost/ragstuffer:latest -f "$ragstuffer_dir/$containerfile" "$ragstuffer_dir/" \
        && ok "localhost/ragstuffer:latest ($containerfile)" \
        || fail "ragstuffer build failed"

    header "Images built"
    podman images --filter reference='localhost/*' --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.Created}}"
}


# ── Quadlet install / uninstall ───────────────────────────────────────────────

# Resolve the actual .gguf path from ramalama's store structure.
# ramalama stores models as:
#   ~/.local/share/ramalama/store/<transport>/<org>/<repo>/<file>/snapshots/<sha>/<file>
# This function finds the snapshot path for a given store subdirectory.
_resolve_model_path() {
    local store_subpath="$1"   # e.g. huggingface/unsloth/Qwen3.5-35B-A3B-GGUF/Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf
    local filename="$2"        # e.g. Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf
    local store="$HOME/.local/share/ramalama/store"
    local snapdir="$store/$store_subpath/snapshots"

    if [[ ! -d "$snapdir" ]]; then
        echo ""
        return 1
    fi

    # Find the newest file if multiple snapshots exist
    local path
    path=$(find "$snapdir" -maxdepth 2 -name "$filename" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)
    echo "$path"
}

cmd_install() {
    log "Resolving model paths..."

    # Model path derived from auto-detected GPU/VRAM
    declare -A MODEL_STORE_PATH=(
        [ramalama]="huggingface/$MODEL_REPO/$MODEL_FILE"
    )
    declare -A MODEL_FILENAME=(
        [ramalama]="$MODEL_FILE"
    )

    local missing=()
    # shellcheck disable=SC2043
    for unit in ramalama; do
        local resolved
        resolved=$(_resolve_model_path "${MODEL_STORE_PATH[$unit]}" "${MODEL_FILENAME[$unit]}")
        # Also check ~/.local/share/llm-models/ for non-ramalama installs
        if [[ -z "$resolved" ]]; then
            resolved=$(find "$HOME/.local/share/llm-models" -name "${MODEL_FILENAME[$unit]}" -type f 2>/dev/null | head -1)
        fi
        if [[ -z "$resolved" ]]; then
            warn "Model not found for $unit — run './llm-stack.sh pull-models' first"
            missing+=("$unit")
        else
            ok "Resolved $unit → $resolved"
        fi
    done

    [[ ${#missing[@]} -gt 0 ]] && fail "Missing models: ${missing[*]}"

    # Fix SELinux labels on model files so containers can bind-mount them.
    # container_ro_file_t with no MCS categories (s0) avoids label mismatches
    # even when SecurityLabelDisable=true strips the container's label.
    log "Setting SELinux labels on model files..."
    local label_count
    label_count=$(find "$HOME/.local/share/ramalama/store" -name "*.gguf" -type f -print0 2>/dev/null \
        | xargs -0 --no-run-if-empty chcon -t container_ro_file_t -l s0 -v 2>/dev/null | wc -l)
    if [[ "$label_count" -gt 0 ]]; then
        ok "SELinux labels set on $label_count .gguf files"
    fi

    log "Installing quadlets to $QUADLET_DIR..."

    # Copy base quadlets, then overlay host-specific files
    cp "$SCRIPT_DIR"/quadlets/*.container "$QUADLET_DIR"/
    cp "$SCRIPT_DIR"/quadlets/*.volume    "$QUADLET_DIR"/
    if [[ -n "$HOST_QUADLET_SRC" && -d "$HOST_QUADLET_SRC" ]]; then
        log "Overlaying $GPU_PROFILE-specific quadlets from hosts/$GPU_PROFILE/"
        cp "$HOST_QUADLET_SRC"/*.container "$QUADLET_DIR"/ 2>/dev/null || true
        cp "$HOST_QUADLET_SRC"/*.volume    "$QUADLET_DIR"/ 2>/dev/null || true
    fi

    # shellcheck disable=SC2043
    for unit in ramalama; do
        local resolved
        resolved=$(_resolve_model_path "${MODEL_STORE_PATH[$unit]}" "${MODEL_FILENAME[$unit]}")
        local quadlet="$QUADLET_DIR/$unit.container"
        sed -i "s|src=MODEL_PATH_PLACEHOLDER|src=$resolved|" "$quadlet"

        # Template the Exec line from tune.conf if available
        if [[ -f "$TUNE_CONF" ]]; then
            local exec_line="llama-server --model /mnt/models/model.file --host 0.0.0.0 --port 8080"
            exec_line+=" --ctx-size ${TUNE_CTX_SIZE:-32768}"
            exec_line+=" --n-gpu-layers 999"
            exec_line+=" --threads ${TUNE_THREADS:-16}"
            exec_line+=" --parallel ${TUNE_PARALLEL:-2}"
            exec_line+=" --flash-attn ${TUNE_FLASH_ATTN:-on}"
            exec_line+=" --cache-type-k ${TUNE_CACHE_TYPE_K:-q4_0}"
            exec_line+=" --cache-type-v ${TUNE_CACHE_TYPE_V:-q4_0}"
            exec_line+=" --batch-size ${TUNE_BATCH_SIZE:-2048}"
            exec_line+=" --ubatch-size ${TUNE_UBATCH_SIZE:-512}"
            [[ -n "${TUNE_MLOCK:-}" ]] && exec_line+=" $TUNE_MLOCK"
            exec_line+=" --jinja"
            [[ -n "${TUNE_EXTRA_ARGS:-}" ]] && exec_line+=" $TUNE_EXTRA_ARGS"
            # Replace the Exec line and remove any continuation lines
            # (quadlet files may have multi-line Exec= with \ continuations)
            sed -i '/^Exec=/,/[^\\]$/{/^Exec=/!d}' "$quadlet"
            sed -i "s|^Exec=.*|Exec=$exec_line|" "$quadlet"
            ok "Templated Exec line from tune.conf"
        fi
    done

    systemctl --user daemon-reload

    # Copy config files (routes.yaml, system-prompt.txt) if not already present
    mkdir -p "$HOME/.config/ragpipe"
    if [[ -f "$SCRIPT_DIR/config/ragpipe/routes.yaml" ]]; then
        if [[ ! -f "$HOME/.config/ragpipe/routes.yaml" ]]; then
            cp "$SCRIPT_DIR/config/ragpipe/routes.yaml" "$HOME/.config/ragpipe/routes.yaml"
            ok "Copied routes.yaml to ~/.config/ragpipe/"
        else
            log "routes.yaml already exists in ~/.config/ragpipe/, keeping existing"
        fi
    fi
    if [[ -f "$SCRIPT_DIR/config/ragpipe/system-prompt.txt" ]]; then
        if [[ ! -f "$HOME/.config/ragpipe/system-prompt.txt" ]]; then
            cp "$SCRIPT_DIR/config/ragpipe/system-prompt.txt" "$HOME/.config/ragpipe/system-prompt.txt"
            ok "Copied system-prompt.txt to ~/.config/ragpipe/"
        else
            log "system-prompt.txt already exists in ~/.config/ragpipe/, keeping existing"
        fi
    fi

    # Verify generator is happy
    local errors
    errors=$(/usr/lib/systemd/user-generators/podman-user-generator -dryrun -user 2>&1 \
        | grep -ivE "^#" | grep -iE "error|unsupported" || true)
    if [[ -n "$errors" ]]; then
        warn "Quadlet generator reported issues:"
        printf "    %s\n" "$errors"
        fail "Fix the above errors before starting services"
    fi

    ok "Quadlets installed and validated"

    for u in "${UNITS[@]}"; do
        systemctl --user enable "$u" 2>/dev/null \
            && ok "enabled $u" \
            || warn "could not enable $u"
    done
    echo ""
    ok "Run: ./llm-stack.sh up"
}

cmd_uninstall() {
    cmd_down
    for u in "${UNITS[@]}"; do
        systemctl --user disable "$u" 2>/dev/null || true
        rm -f "$QUADLET_DIR/$u.container"
    done
    rm -f "$QUADLET_DIR"/*.volume
    systemctl --user daemon-reload
    ok "Quadlets removed — models preserved in ~/.local/share/ramalama/"
}

# ── Start / stop ──────────────────────────────────────────────────────────────

cmd_up() {
    local failed=()
    for u in "${UNITS[@]}"; do
        systemctl --user start "$u" 2>/dev/null \
            && ok "$u started" \
            || { warn "$u failed"; failed+=("$u"); }
    done
    echo ""
    if [[ ${#failed[@]} -gt 0 ]]; then
        warn "Some units failed: ${failed[*]}"
        warn "Diagnose: ./llm-stack.sh logs <model|proxy>"
    else
        ok "All services started"
        echo ""
        echo "    LiteLLM proxy  →  http://localhost:4000"
        echo "    Open WebUI     →  http://localhost:3000"
    fi
    echo ""
}

cmd_down() {
    for u in "${UNITS[@]}"; do
        systemctl --user stop "$u" 2>/dev/null \
            && ok "stopped $u" \
            || true
    done
}

cmd_restart() {
    for u in "${UNITS[@]}"; do
        systemctl --user restart "$u" \
            && ok "restarted $u" \
            || warn "failed $u"
    done
}

cmd_status() {
    echo ""
    printf "  ${BOLD}%-30s %-12s %s${RESET}\n" "Unit" "State" "Since"
    echo "  ──────────────────────────────────────────────────────────────"
    for u in "${UNITS[@]}"; do
        local state since
        state=$(systemctl --user is-active "$u" 2>/dev/null || echo "inactive")
        since=$(systemctl --user show "$u" --property=ActiveEnterTimestamp \
            --value 2>/dev/null | cut -d';' -f1 || echo "")
        local colour="$RESET"
        [[ "$state" == "active" ]]     && colour="$GREEN"
        [[ "$state" == "activating" ]] && colour="$YELLOW"
        [[ "$state" == "failed" ]]     && colour="$RED"
        printf "  %-30s ${colour}%-12s${RESET} %s\n" "$u" "$state" "$since"
    done
    echo ""
}

# ── Logs ─────────────────────────────────────────────────────────────────────

cmd_logs() {
    local target="${1:-}"
    case "$target" in
        model)       journalctl --user -u ramalama -f ;;
        proxy)       journalctl --user -u litellm -f ;;
        ragpipe)     journalctl --user -u ragpipe -f ;;
        rag|watcher) journalctl --user -u ragstuffer -f ;;
        qdrant)      journalctl --user -u qdrant -f ;;
        webui)       journalctl --user -u open-webui -f ;;
        postgres|db) journalctl --user -u postgres -f ;;
        *)           fail "Usage: ./llm-stack.sh logs <model|proxy|ragpipe|rag|qdrant|webui|postgres>" ;;
    esac
}

# ── Model swap ────────────────────────────────────────────────────────────────

cmd_swap() {
    local model="${1:-}"
    [[ -n "$model" ]] || \
        fail "Usage: ./llm-stack.sh swap <hf://...>"

    log "Pulling $model..."
    ramalama pull "$model"

    local pulled_path
    pulled_path=$(find "$HOME/.local/share/ramalama/store" -name "*.gguf" -type f \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    if [[ -n "$pulled_path" ]]; then
        ok "Model path: $pulled_path"
    fi
    warn "Update MODEL_STORE_PATH and MODEL_FILENAME in llm-stack.sh to match the new model"
    warn "Then run: ./llm-stack.sh install && systemctl --user restart ramalama"
}

# ── Smoke tests ───────────────────────────────────────────────────────────────

cmd_test() {
    local api="http://localhost:4000"
    local key="sk-llm-stack-local"
    local all_ok=true

    header "Smoke testing inference"

    log "Testing default model (Qwen3.5-35B-A3B on :8080)..."
    local resp
    if resp=$(curl -sf --max-time 90 "$api/chat/completions" \
        -H "Authorization: Bearer $key" \
        -H "Content-Type: application/json" \
        -d '{"model":"default","messages":[{"role":"user","content":"Reply with exactly one word: ready"}],"max_tokens":512}' \
        2>/dev/null); then
        local content
        content=$(echo "$resp" | python3 -c \
            "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'].strip())" \
            2>/dev/null || echo "?")
        ok "default: $content"
    else
        warn "default: no response — check: ./llm-stack.sh logs model"
        all_ok=false
    fi

    echo ""
    $all_ok && ok "Inference healthy" || warn "Inference failed — check logs"
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        help|--help|-h) cmd_help ;;
        deps)           cmd_deps ;;
        groups)         cmd_groups ;;
        setup)          cmd_setup ;;
        pull-image)     cmd_pull_image ;;
        tune)           cmd_tune ;;
        retune)         cmd_retune ;;
        pull-models)    cmd_pull_models ;;
        build)          cmd_build ;;
        install)        cmd_install ;;
        uninstall)      cmd_uninstall ;;
        up)             cmd_up ;;
        down)           cmd_down ;;
        restart)        cmd_restart ;;
        status)         cmd_status ;;
        logs)           cmd_logs "$@" ;;
        swap)           cmd_swap "$@" ;;
        test)           cmd_test ;;
        *)              warn "Unknown command: $cmd"; cmd_help; exit 1 ;;
    esac
}

main "$@"
