#!/usr/bin/env bash
# llm-stack.sh — local LLM stack management
# Fedora 43 · Ryzen AI Max+ 395 · RamaLama + Podman Quadlets
#
# Usage: ./llm-stack.sh <command>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUADLET_DIR="$HOME/.config/containers/systemd"
CONFIG_DIR="$HOME/.config/llm-stack"
UNITS=(postgres ramalama-reasoning ramalama-code ramalama-fast litellm open-webui)

# Registry candidates for the ROCm image, in preference order
ROCM_IMAGES=(
    "quay.io/ramalama/rocm:latest"
    "ghcr.io/ggml-org/llama.cpp:full-rocm"
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

${BOLD}llm-stack.sh${RESET} — local LLM stack (Fedora 43 · AI Max+ 395)

${BOLD}First-time setup (run in order):${RESET}
  deps          install system packages via dnf       [needs sudo]
  groups        add user to render/video groups       [needs sudo + reboot]
  setup         verify GPU, write configs
  pull-image    pull the RamaLama ROCm container image
  pull-models   download all models (~50 GB)
  install       install quadlets to systemd
  up            start all services

${BOLD}Operations:${RESET}
  up            start all services
  down          stop all services
  restart       restart all services
  status        show unit states
  test          smoke-test all inference tiers

${BOLD}Logs:${RESET}
  logs reasoning    follow reasoning model logs
  logs code         follow code model logs
  logs fast         follow fast/draft model logs
  logs proxy        follow LiteLLM proxy logs

${BOLD}Models:${RESET}
  pull-image              pull ROCm container image (with registry fallback)
  swap reasoning <hf://…> hot-swap reasoning model
  swap code      <hf://…> hot-swap code model

${BOLD}Teardown:${RESET}
  uninstall     remove quadlets (models kept)

${BOLD}Endpoints (once running):${RESET}
  LiteLLM proxy  →  http://localhost:4000
  Open WebUI     →  http://localhost:3000
  Reasoning      →  http://localhost:8080
  Code           →  http://localhost:8081
  Fast / embed   →  http://localhost:8082

EOF
}

# ── Dependency installation ───────────────────────────────────────────────────

cmd_deps() {
    header "Installing system dependencies"
    [[ "$(id -u)" == "0" ]] && fail "Run as your regular user, not root"

    local packages=(
        podman podman-compose ramalama
        rocm rocm-hip rocm-runtime rocminfo
        amd-gpu-firmware curl python3 git
    )

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
        warn "rocminfo not found — install: sudo dnf install rocminfo"
    fi

    local accel
    accel=$(ramalama info 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('Accelerator','unknown'))" \
        2>/dev/null || echo "unknown")
    echo "  ramalama accelerator: $accel"
    [[ "$accel" == "hip" ]] || warn "Expected 'hip' — models may run on CPU"

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

    if ! grep -q 'HSA_OVERRIDE_GFX_VERSION' "$HOME/.bashrc" 2>/dev/null; then
        printf '\n# LLM Stack — AMD AI Max+ 395 ROCm\nexport HSA_OVERRIDE_GFX_VERSION=11.5.1\nexport LLAMA_HIP_UMA=1\n' \
            >> "$HOME/.bashrc"
        ok "Added ROCm env vars to ~/.bashrc"
    else
        ok "ROCm env vars already in ~/.bashrc"
    fi

    echo ""
    ok "Setup complete — next: ./llm-stack.sh pull-image"
}

# ── Image pulling (with fallback) ─────────────────────────────────────────────

cmd_pull_image() {
    header "Pulling RamaLama ROCm container image"

    local pulled=""
    for image in "${ROCM_IMAGES[@]}"; do
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
    for f in "$SCRIPT_DIR"/quadlets/ramalama-*.container; do
        sed -i "s|^Image=.*|Image=$pulled|" "$f"
        ok "Updated source: $(basename "$f")"
    done
    for f in "$QUADLET_DIR"/ramalama-*.container; do
        [[ -f "$f" ]] || continue
        sed -i "s|^Image=.*|Image=$pulled|" "$f"
        ok "Updated installed: $(basename "$f")"
    done
    systemctl --user daemon-reload
}

# ── Model pulling ─────────────────────────────────────────────────────────────

cmd_pull_models() {
    header "Pulling models via ramalama (~50 GB total)"

    log "Reasoning: QwQ-32B Q4_K_M (~19 GB)..."
    ramalama pull hf://Qwen/QwQ-32B-GGUF/qwq-32b-q4_k_m.gguf
    echo ""

    log "Code: Qwen2.5-Coder-32B Q4_K_M (~19 GB)..."
    ramalama pull hf://Qwen/Qwen2.5-Coder-32B-Instruct-GGUF/qwen2.5-coder-32b-instruct-q4_k_m.gguf
    echo ""

    # Qwen's own 14B repo splits the file; bartowski provides a single unsplit file
    log "Fast: Qwen2.5-14B Q4_K_M (~9 GB, via bartowski)..."
    ramalama pull hf://bartowski/Qwen2.5-14B-Instruct-GGUF/Qwen2.5-14B-Instruct-Q4_K_M.gguf
    echo ""

    log "Embed: nomic-embed-text (~300 MB)..."
    ramalama pull ollama://nomic-embed-text
    echo ""

    header "All models pulled"
    ramalama list
    echo ""
    ok "Next: ./llm-stack.sh install"
}

# ── Quadlet install / uninstall ───────────────────────────────────────────────

# Resolve the actual .gguf path from ramalama's store structure.
# ramalama stores models as:
#   ~/.local/share/ramalama/store/<transport>/<org>/<repo>/<file>/snapshots/<sha>/<file>
# This function finds the snapshot path for a given store subdirectory.
_resolve_model_path() {
    local store_subpath="$1"   # e.g. huggingface/Qwen/QwQ-32B-GGUF/qwq-32b-q4_k_m.gguf
    local filename="$2"        # e.g. qwq-32b-q4_k_m.gguf
    local store="$HOME/.local/share/ramalama/store"
    local snapdir="$store/$store_subpath/snapshots"

    if [[ ! -d "$snapdir" ]]; then
        echo ""
        return 1
    fi

    # Find the actual file under any snapshot sha directory
    local path
    path=$(find "$snapdir" -maxdepth 2 -name "$filename" 2>/dev/null | head -1)
    echo "$path"
}

cmd_install() {
    log "Resolving model paths from ramalama store..."

    # Map each quadlet to its store path and filename
    declare -A MODEL_STORE_PATH=(
        [ramalama-reasoning]="huggingface/Qwen/QwQ-32B-GGUF/qwq-32b-q4_k_m.gguf"
        [ramalama-code]="huggingface/Qwen/Qwen2.5-Coder-32B-Instruct-GGUF/qwen2.5-coder-32b-instruct-q4_k_m.gguf"
        [ramalama-fast]="huggingface/bartowski/Qwen2.5-14B-Instruct-GGUF/Qwen2.5-14B-Instruct-Q4_K_M.gguf"
    )
    declare -A MODEL_FILENAME=(
        [ramalama-reasoning]="qwq-32b-q4_k_m.gguf"
        [ramalama-code]="qwen2.5-coder-32b-instruct-q4_k_m.gguf"
        [ramalama-fast]="Qwen2.5-14B-Instruct-Q4_K_M.gguf"
    )

    local missing=()
    for unit in ramalama-reasoning ramalama-code ramalama-fast; do
        local resolved
        resolved=$(_resolve_model_path "${MODEL_STORE_PATH[$unit]}" "${MODEL_FILENAME[$unit]}")
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
    local gguf_files
    gguf_files=$(find "$HOME/.local/share/ramalama/store" -name "*.gguf" 2>/dev/null)
    if [[ -n "$gguf_files" ]]; then
        echo "$gguf_files" | xargs chcon -t container_ro_file_t -l s0
        ok "SELinux labels set on $(echo "$gguf_files" | wc -l) .gguf files"
    fi

    log "Installing quadlets to $QUADLET_DIR..."

    # Copy source quadlets then patch Mount= lines with resolved paths
    cp "$SCRIPT_DIR"/quadlets/*.container "$QUADLET_DIR"/
    cp "$SCRIPT_DIR"/quadlets/*.volume    "$QUADLET_DIR"/

    for unit in ramalama-reasoning ramalama-code ramalama-fast; do
        local resolved
        resolved=$(_resolve_model_path "${MODEL_STORE_PATH[$unit]}" "${MODEL_FILENAME[$unit]}")
        local quadlet="$QUADLET_DIR/$unit.container"
        sed -i "s|src=MODEL_PATH_PLACEHOLDER|src=$resolved|" "$quadlet"
    done

    systemctl --user daemon-reload

    # Verify generator is happy
    local errors
    errors=$(/usr/lib/systemd/user-generators/podman-user-generator -dryrun -user 2>&1 \
        | grep -iE "error|unsupported" || true)
    if [[ -n "$errors" ]]; then
        warn "Quadlet generator reported issues:"
        echo "$errors" | sed 's/^/    /'
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
    rm -f "$QUADLET_DIR"/litellm-db-data.volume "$QUADLET_DIR"/open-webui-data.volume
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
        warn "Diagnose: ./llm-stack.sh logs <reasoning|code|fast|proxy>"
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
        reasoning) journalctl --user -u ramalama-reasoning -f ;;
        code)      journalctl --user -u ramalama-code -f ;;
        fast)      journalctl --user -u ramalama-fast -f ;;
        proxy)     journalctl --user -u litellm -f ;;
        webui)     journalctl --user -u open-webui -f ;;
        *)         fail "Usage: ./llm-stack.sh logs <reasoning|code|fast|proxy|webui>" ;;
    esac
}

# ── Model swap ────────────────────────────────────────────────────────────────

cmd_swap() {
    local tier="${1:-}" model="${2:-}"
    [[ -n "$tier" && -n "$model" ]] || \
        fail "Usage: ./llm-stack.sh swap <reasoning|code> <hf://...>"

    local unit file
    case "$tier" in
        reasoning) unit="ramalama-reasoning"; file="ramalama-reasoning.container" ;;
        code)      unit="ramalama-code";      file="ramalama-code.container" ;;
        *) fail "Unknown tier '$tier' — use: reasoning or code" ;;
    esac

    log "Pulling $model..."
    ramalama pull "$model"

    warn "Update the Mount= path in quadlets/$file to match the new model path"
    warn "Then run: ./llm-stack.sh install && systemctl --user restart $unit"
}

# ── Smoke tests ───────────────────────────────────────────────────────────────

cmd_test() {
    local api="http://localhost:4000"
    local key="sk-llm-stack-local"
    local all_ok=true

    header "Smoke testing all tiers"

    for tier in reasoning code fast; do
        log "Testing $tier tier..."
        local resp
        if resp=$(curl -sf --max-time 90 "$api/chat/completions" \
            -H "Authorization: Bearer $key" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"$tier\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly one word: ready\"}],\"max_tokens\":5}" \
            2>/dev/null); then
            local content
            content=$(echo "$resp" | python3 -c \
                "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'].strip())" \
                2>/dev/null || echo "?")
            ok "$tier: $content"
        else
            warn "$tier: no response — check: ./llm-stack.sh logs $tier"
            all_ok=false
        fi
    done

    log "Testing embed tier..."
    if resp=$(curl -sf --max-time 30 "$api/embeddings" \
        -H "Authorization: Bearer $key" \
        -H "Content-Type: application/json" \
        -d '{"model":"embed","input":"local LLM stack","encoding_format":"float"}' 2>/dev/null); then
        local dims
        dims=$(echo "$resp" | python3 -c \
            "import sys,json; print(len(json.load(sys.stdin)['data'][0]['embedding']))" \
            2>/dev/null || echo "?")
        ok "embed: $dims dims"
    else
        warn "embed: no response"
        all_ok=false
    fi

    echo ""
    $all_ok && ok "All tiers healthy" || warn "Some tiers failed — check logs"
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
        pull-models)    cmd_pull_models ;;
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
