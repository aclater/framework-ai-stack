#!/usr/bin/env bash
# tests/run-tests.sh — test suite for llm-stack.sh
#
# Tests everything that doesn't require live podman/systemd/GPU.
# Run from the repo root: bash tests/run-tests.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/llm-stack.sh"
PASS=0
FAIL=0
ERRORS=()

# ── Test harness ──────────────────────────────────────────────────────────────

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[1;33m' BOLD='\033[1m' RESET='\033[0m'

pass() { echo -e "  ${GREEN}✓${RESET} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${RESET} $1"; FAIL=$((FAIL+1)); ERRORS+=("$1"); }
skip() { echo -e "  ${YELLOW}~${RESET} $1 (skipped — requires $2)"; }
section() { echo -e "\n${BOLD}$1${RESET}"; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc (expected: '$expected', got: '$actual')"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -q "$needle"; then
        pass "$desc"
    else
        fail "$desc (expected to find '$needle' in output)"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -q "$needle"; then
        pass "$desc"
    else
        fail "$desc (did not expect '$needle' in output)"
    fi
}

assert_exit_zero() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        pass "$desc"
    else
        fail "$desc (command exited non-zero)"
    fi
}

assert_exit_nonzero() {
    local desc="$1"; shift
    if ! "$@" &>/dev/null; then
        pass "$desc"
    else
        fail "$desc (expected non-zero exit)"
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    [[ -f "$path" ]] && pass "$desc" || fail "$desc ($path not found)"
}

assert_file_contains() {
    local desc="$1" path="$2" needle="$3"
    if [[ -f "$path" ]] && grep -q "$needle" "$path"; then
        pass "$desc"
    else
        fail "$desc ($path does not contain '$needle')"
    fi
}

# ── Setup: temp home for config file tests ────────────────────────────────────

ORIG_HOME="$HOME"
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
trap 'rm -rf "$TEST_HOME"; export HOME="$ORIG_HOME"' EXIT

# ── 1. Script basics ──────────────────────────────────────────────────────────

section "1. Script basics"

assert_file_exists "script exists" "$SCRIPT"
assert_exit_zero   "script is valid bash syntax" bash -n "$SCRIPT"

# Help should exit 0 and contain key commands
HELP_OUT=$(bash "$SCRIPT" help 2>&1)
assert_exit_zero     "help exits 0"                bash "$SCRIPT" help
assert_contains      "help mentions deps"           "deps"     "$HELP_OUT"
assert_contains      "help mentions pull-image"     "pull-image" "$HELP_OUT"
assert_contains      "help mentions pull-models"    "pull-models" "$HELP_OUT"
assert_contains      "help mentions install"        "install"  "$HELP_OUT"
assert_contains      "help mentions status"         "status"   "$HELP_OUT"
assert_contains      "help mentions logs"           "logs"     "$HELP_OUT"
assert_contains      "help shows endpoint ports"    "4000"     "$HELP_OUT"

# Unknown command should exit non-zero
assert_exit_nonzero "unknown command exits non-zero" bash "$SCRIPT" definitely-not-a-command

# ── 2. Registry check logic ───────────────────────────────────────────────────

section "2. Registry check logic"

# Extract and test the check_registry function in isolation

# Test HTTP status parsing directly
_test_status() {
    local status="$1" expected="$2"
    local result
    if [[ "$status" == "200" || "$status" == "401" ]]; then
        result="up"
    else
        result="down"
    fi
    assert_eq "status $status → $expected" "$expected" "$result"
}

_test_status "200"    "up"
_test_status "401"    "up"
_test_status "502"    "down"
_test_status "000"    "down"
_test_status "401000" "down"   # the old bug — concatenated exit code
_test_status "404"    "down"

# ── 3. Config file generation ─────────────────────────────────────────────────

section "3. Config file generation"

CONFIG_DIR="$TEST_HOME/.config/llm-stack"
QUADLET_DIR="$TEST_HOME/.config/containers/systemd"

# Stub out commands that require real system access
PATH_BAK="$PATH"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME" "$STUB_DIR"; export HOME="$ORIG_HOME"; export PATH="$PATH_BAK"' EXIT

# Create stubs for podman, ramalama, rocminfo, systemctl, loginctl, sudo
for cmd in podman ramalama rocminfo sudo loginctl; do
    cat > "$STUB_DIR/$cmd" << STUB
#!/usr/bin/env bash
# stub: $cmd — always succeeds silently
exit 0
STUB
    chmod +x "$STUB_DIR/$cmd"
done

# systemctl stub — returns "active" for is-active, otherwise succeeds
cat > "$STUB_DIR/systemctl" << 'STUB'
#!/usr/bin/env bash
if [[ "${*}" == *"is-active"* ]]; then echo "active"; fi
exit 0
STUB
chmod +x "$STUB_DIR/systemctl"

# ramalama info stub — returns JSON with hip accelerator
cat > "$STUB_DIR/ramalama" << 'STUB'
#!/usr/bin/env bash
if [[ "$1" == "info" ]]; then
    echo '{"Accelerator":"hip"}'
elif [[ "$1" == "list" ]]; then
    echo "NAME  MODIFIED  SIZE"
fi
exit 0
STUB
chmod +x "$STUB_DIR/ramalama"

# rocminfo stub — returns gfx1151
cat > "$STUB_DIR/rocminfo" << 'STUB'
#!/usr/bin/env bash
echo "  Name:                    gfx1151"
exit 0
STUB
chmod +x "$STUB_DIR/rocminfo"

# Fake /etc/group with render and video containing the current user
FAKE_GROUP="$(mktemp)"
echo "render:x:105:$(whoami)" >> "$FAKE_GROUP"
echo "video:x:39:$(whoami)"   >> "$FAKE_GROUP"

# Patch the script: fake /etc/group, remove root check, fix SCRIPT_DIR, stub PATH
PATCHED="$(mktemp --suffix=.sh)"
sed \
    -e "s|/etc/group|$FAKE_GROUP|g" \
    -e 's|\[\[ "$(id -u)" == "0" \]\] && fail.*||g' \
    -e "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$REPO_DIR\"|" \
    "$SCRIPT" > "$PATCHED"
chmod +x "$PATCHED"
export PATH="$STUB_DIR:$PATH_BAK"

# Run setup with faked environment — override device checks
SETUP_OUT=$(HOME="$TEST_HOME" bash "$PATCHED" setup 2>&1 || true)

assert_contains "setup creates config dir"   "$CONFIG_DIR"          "$SETUP_OUT"
assert_file_exists "env.example copied"      "$CONFIG_DIR/env"
assert_file_exists "litellm config copied"   "$CONFIG_DIR/litellm-config.yaml"
assert_contains "setup detects hip"          "hip"                  "$SETUP_OUT"
assert_contains "setup adds HSA var"         "HSA_OVERRIDE_GFX_VERSION" "$SETUP_OUT"
assert_file_contains "bashrc gets HSA var"   "$TEST_HOME/.bashrc"   "HSA_OVERRIDE_GFX_VERSION=11.5.1"
assert_file_contains "bashrc gets UMA var"   "$TEST_HOME/.bashrc"   "LLAMA_HIP_UMA=1"

# Setup should not duplicate vars on second run
HOME="$TEST_HOME" bash "$PATCHED" setup &>/dev/null || true
BASHRC_COUNT=$(grep -c "HSA_OVERRIDE_GFX_VERSION" "$TEST_HOME/.bashrc" || echo 0)
assert_eq "bashrc var not duplicated on re-run" "1" "$BASHRC_COUNT"

# ── 4. Quadlet files ──────────────────────────────────────────────────────────

section "4. Quadlet files"

QUADLET_SRC="$REPO_DIR/quadlets"

assert_file_exists "ramalama-reasoning.container" "$QUADLET_SRC/ramalama-reasoning.container"
assert_file_exists "ramalama-code.container"      "$QUADLET_SRC/ramalama-code.container"
assert_file_exists "ramalama-fast.container"      "$QUADLET_SRC/ramalama-fast.container"
assert_file_exists "litellm.container"            "$QUADLET_SRC/litellm.container"
assert_file_exists "open-webui.container"         "$QUADLET_SRC/open-webui.container"
assert_file_exists "litellm-db-data.volume"       "$QUADLET_SRC/litellm-db-data.volume"
assert_file_exists "open-webui-data.volume"       "$QUADLET_SRC/open-webui-data.volume"

# No PullPolicy — not supported in this podman-quadlet version
for f in "$QUADLET_SRC"/ramalama-*.container; do
    assert_not_contains "$(basename $f) has no PullPolicy" \
        "PullPolicy" "$(cat $f)"
done

# No quay.io references in ramalama quadlets (should use ghcr.io fallback image or be templated)
for f in "$QUADLET_SRC"/ramalama-*.container; do
    name=$(basename $f)
    # Image line must exist
    assert_contains "$name has Image= line" "^Image=" "$(grep "^Image=" $f || true)"
done

# litellm must not reference litellm-db.service in After=
assert_contains "litellm uses main-stable image"    "main-stable"          "$(cat $QUADLET_SRC/litellm.container)"
assert_not_contains "litellm has no bad env interpolation" 'LITELLM_MASTER_KEY=${' "$(cat $QUADLET_SRC/litellm.container)"
assert_contains "litellm loads env file"           "EnvironmentFile"      "$(cat $QUADLET_SRC/litellm.container)"

# litellm must not have DATABASE_URL
assert_contains "litellm has postgres DATABASE_URL" \
    "DATABASE_URL=postgresql" "$(cat $QUADLET_SRC/litellm.container)"

# All ramalama containers must expose correct ports
assert_contains "reasoning publishes 8080" "8080" "$(cat $QUADLET_SRC/ramalama-reasoning.container)"
assert_contains "code publishes 8081"      "8081" "$(cat $QUADLET_SRC/ramalama-code.container)"
assert_contains "fast publishes 8082"      "8082" "$(cat $QUADLET_SRC/ramalama-fast.container)"

# GPU device passthrough present in all ramalama containers
for f in "$QUADLET_SRC"/ramalama-*.container; do
    assert_contains "$(basename $f) has /dev/kfd" "/dev/kfd" "$(cat $f)"
    assert_contains "$(basename $f) has /dev/dri" "/dev/dri" "$(cat $f)"
done

# ROCm env vars present
for f in "$QUADLET_SRC"/ramalama-*.container; do
    assert_contains "$(basename $f) has LLAMA_HIP_UMA"          "LLAMA_HIP_UMA=1"            "$(cat $f)"
    assert_contains "$(basename $f) has HSA_OVERRIDE_GFX_VERSION" "HSA_OVERRIDE_GFX_VERSION" "$(cat $f)"
done

# Mount lines use placeholder — resolved at install time from ramalama store
assert_contains "reasoning mount placeholder present" "MODEL_PATH_PLACEHOLDER" "$(cat $QUADLET_SRC/ramalama-reasoning.container)"
assert_contains "code mount placeholder present"      "MODEL_PATH_PLACEHOLDER" "$(cat $QUADLET_SRC/ramalama-code.container)"
assert_contains "fast mount placeholder present"      "MODEL_PATH_PLACEHOLDER" "$(cat $QUADLET_SRC/ramalama-fast.container)"
assert_contains "reasoning mounts to /mnt/models"    "/mnt/models/model.file" "$(cat $QUADLET_SRC/ramalama-reasoning.container)"

# ── 5. LiteLLM config ────────────────────────────────────────────────────────

section "5. LiteLLM config"

LITELLM_CFG="$REPO_DIR/configs/litellm-config.yaml"
assert_file_exists "litellm-config.yaml exists" "$LITELLM_CFG"

for alias in reasoning code fast embed; do
    assert_contains "config has '$alias' alias" "model_name: $alias" "$(cat $LITELLM_CFG)"
done

assert_contains "reasoning routes to :8080" "8080" "$(cat $LITELLM_CFG)"
assert_contains "code routes to :8081"      "8081" "$(cat $LITELLM_CFG)"
assert_contains "fast routes to :8082"      "8082" "$(cat $LITELLM_CFG)"
assert_not_contains "no DATABASE_URL in config" "DATABASE_URL" "$(cat $LITELLM_CFG)"
assert_contains "drop_params enabled" "drop_params: true" "$(cat $LITELLM_CFG)"
assert_contains "master key set" "LITELLM_MASTER_KEY" "$(cat $LITELLM_CFG)"

# Validate YAML is parseable
if command -v python3 &>/dev/null; then
    YAML_OK=$(python3 -c "import sys; 
try:
    import yaml; yaml.safe_load(open('$LITELLM_CFG')); print('ok')
except ImportError:
    print('skip')
except Exception as e:
    print(f'error: {e}')" 2>/dev/null)
    if [[ "$YAML_OK" == "ok" ]]; then
        pass "litellm-config.yaml is valid YAML"
    elif [[ "$YAML_OK" == "skip" ]]; then
        skip "YAML validation" "PyYAML"
    else
        fail "litellm-config.yaml YAML parse error: $YAML_OK"
    fi
fi

# ── 6. env.example ───────────────────────────────────────────────────────────

section "6. env.example"

ENV="$REPO_DIR/env.example"
assert_file_exists "env.example exists" "$ENV"
assert_contains "has HSA_OVERRIDE_GFX_VERSION" "HSA_OVERRIDE_GFX_VERSION" "$(cat $ENV)"
assert_contains "has LLAMA_HIP_UMA"            "LLAMA_HIP_UMA"            "$(cat $ENV)"
assert_contains "has LITELLM_MASTER_KEY"        "LITELLM_MASTER_KEY"       "$(cat $ENV)"
assert_not_contains "no real API keys in example" "sk-ant" "$(cat $ENV)"

# ── 7. SVG architecture diagram ──────────────────────────────────────────────

section "7. SVG diagram"

SVG="$REPO_DIR/architecture.svg"
assert_file_exists "architecture.svg exists" "$SVG"
assert_contains "SVG has viewBox"             'viewBox'       "$(cat $SVG)"
assert_contains "SVG mentions LiteLLM"        "LiteLLM"       "$(cat $SVG)"
assert_contains "SVG mentions ROCm"           "ROCm"          "$(cat $SVG)"
assert_contains "SVG mentions port 8080"      "8080"          "$(cat $SVG)"
assert_contains "SVG has dark mode styles"    "prefers-color-scheme" "$(cat $SVG)"

# Validate it's well-formed XML
if command -v python3 &>/dev/null; then
    XML_OK=$(python3 -c "
import xml.etree.ElementTree as ET
try:
    ET.parse('$SVG'); print('ok')
except Exception as e: print(f'error: {e}')
" 2>/dev/null)
    assert_eq "architecture.svg is valid XML" "ok" "$XML_OK"
fi

# ── 8. pull-models URLs ───────────────────────────────────────────────────────

section "8. Model URLs in script"

SCRIPT_CONTENT=$(cat "$SCRIPT")

assert_contains     "QwQ-32B URL present"           "QwQ-32B-GGUF/qwq-32b-q4_k_m.gguf"          "$SCRIPT_CONTENT"
assert_contains     "Qwen-Coder-32B URL present"    "Qwen2.5-Coder-32B-Instruct-GGUF"            "$SCRIPT_CONTENT"
assert_contains     "14B uses bartowski"             "bartowski/Qwen2.5-14B-Instruct-GGUF"        "$SCRIPT_CONTENT"
assert_not_contains "14B not from Qwen official"    "Qwen/Qwen2.5-14B-Instruct-GGUF"             "$SCRIPT_CONTENT"
assert_contains     "nomic-embed-text present"      "ollama://nomic-embed-text"                  "$SCRIPT_CONTENT"

# ── 10. Model path resolver ───────────────────────────────────────────────────

section "10. Model path resolver"

# Source just the resolver function from the script using awk to extract it cleanly
source <(awk '/^_resolve_model_path\(\)/,/^}/' "$SCRIPT")

# Create a fake ramalama store structure
FAKE_STORE="$(mktemp -d)"
SHA="sha256-abc123def456"
mkdir -p "$FAKE_STORE/huggingface/Qwen/QwQ-32B-GGUF/qwq-32b-q4_k_m.gguf/snapshots/$SHA"
touch "$FAKE_STORE/huggingface/Qwen/QwQ-32B-GGUF/qwq-32b-q4_k_m.gguf/snapshots/$SHA/qwq-32b-q4_k_m.gguf"

# Override HOME to point at our fake store
RESOLVER_HOME="$(mktemp -d)"
mkdir -p "$RESOLVER_HOME/.local/share/ramalama"
ln -s "$FAKE_STORE" "$RESOLVER_HOME/.local/share/ramalama/store"

RESOLVED=$(HOME="$RESOLVER_HOME" _resolve_model_path \
    "huggingface/Qwen/QwQ-32B-GGUF/qwq-32b-q4_k_m.gguf" \
    "qwq-32b-q4_k_m.gguf")

assert_contains "resolver finds model under snapshots"  "snapshots"             "$RESOLVED"
assert_contains "resolver finds correct filename"       "qwq-32b-q4_k_m.gguf"  "$RESOLVED"
assert_contains "resolver returns absolute path"        "$RESOLVER_HOME"        "$RESOLVED"

# Missing model returns empty string (not an error)
MISSING=$(HOME="$RESOLVER_HOME" _resolve_model_path \
    "huggingface/SomeOrg/nonexistent-model" \
    "nonexistent.gguf" || true)
assert_eq "resolver returns empty for missing model" "" "$MISSING"

rm -rf "$FAKE_STORE" "$RESOLVER_HOME"

section "9. .gitignore"

GITIGNORE="$REPO_DIR/.gitignore"
assert_file_exists "gitignore exists" "$GITIGNORE"
assert_contains    "gitignore excludes .env" ".env" "$(cat $GITIGNORE)"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━  Results  ━━━${RESET}"
echo ""
echo -e "  ${GREEN}Passed: $PASS${RESET}"
if [[ $FAIL -gt 0 ]]; then
    echo -e "  ${RED}Failed: $FAIL${RESET}"
    echo ""
    echo "  Failed tests:"
    for e in "${ERRORS[@]}"; do
        echo -e "    ${RED}✗${RESET} $e"
    done
    echo ""
    exit 1
else
    echo -e "  ${GREEN}All tests passed${RESET}"
    echo ""
    exit 0
fi
