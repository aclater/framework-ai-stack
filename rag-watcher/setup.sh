#!/usr/bin/env bash
# rag-watcher/setup.sh — set up the Google Drive RAG watcher
#
# Usage: ./rag-watcher/setup.sh
#
# Walks through: service account key, folder ID, env vars,
# quadlet install, pip deps, and service start.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
QUADLET_DIR="$HOME/.config/containers/systemd"
CONFIG_DIR="$HOME/.config/llm-stack"
SA_DIR="$HOME/.config/ramalama"
SA_KEY="$SA_DIR/gdrive-sa.json"
ENV_FILE="$CONFIG_DIR/env"

# ── Colours ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
    BOLD='\033[1m' RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

log()    { echo -e "  ${BOLD}→${RESET} $*"; }
ok()     { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()   { echo -e "  ${YELLOW}!${RESET} $*"; }
fail()   { echo -e "  ${RED}✗${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}━━━  $*  ━━━${RESET}\n"; }

prompt_value() {
    local varname="$1" prompt_text="$2" default="${3:-}"
    local input
    if [[ -n "$default" ]]; then
        read -rp "  $prompt_text [$default]: " input
        eval "$varname=\"${input:-$default}\""
    else
        while true; do
            read -rp "  $prompt_text: " input
            if [[ -n "$input" ]]; then
                eval "$varname=\"$input\""
                return
            fi
            echo -e "  ${RED}Required${RESET}"
        done
    fi
}

# ── Preflight ────────────────────────────────────────────────────────────────

header "Google Drive RAG Watcher — Setup"

[[ "$(id -u)" == "0" ]] && fail "Do not run as root — this stack is rootless"

log "Checking prerequisites..."
for cmd in podman systemctl ramalama; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd"
    else
        fail "$cmd not found — run './llm-stack.sh deps' first"
    fi
done

mkdir -p "$CONFIG_DIR" "$QUADLET_DIR" "$SA_DIR"

# ── Service account key ──────────────────────────────────────────────────────

header "Step 1: Google Cloud service account key"

if [[ -f "$SA_KEY" ]]; then
    ok "Service account key already exists: $SA_KEY"
    log "To replace it, delete the file and re-run this script."
else
    echo "  The RAG watcher needs a Google Cloud service account to read your"
    echo "  Drive folder. A service account is like a bot account — it gets its"
    echo "  own email address and a JSON key file instead of a password."
    echo ""
    echo "  If you don't have one yet, here's how to create it:"
    echo ""
    echo "    1. Go to https://console.cloud.google.com"
    echo "    2. Create a project (or pick an existing one)"
    echo "    3. In the sidebar: APIs & Services → Library"
    echo "       Search for 'Google Drive API' and click ${BOLD}Enable${RESET}"
    echo "    4. In the sidebar: IAM & Admin → Service Accounts"
    echo "       Click ${BOLD}Create Service Account${RESET}"
    echo "       Name it something like 'ramalama-rag-reader' — no roles needed"
    echo "    5. Click the service account you just created"
    echo "       Go to the ${BOLD}Keys${RESET} tab → Add Key → Create new key → ${BOLD}JSON${RESET}"
    echo "    6. A .json file will download — that's what we need below"
    echo ""
    prompt_value sa_key_path "Path to the downloaded JSON key file (e.g. ~/Downloads/my-project-abc123.json)"

    sa_key_path="${sa_key_path/#\~/$HOME}"

    if [[ ! -f "$sa_key_path" ]]; then
        fail "File not found: $sa_key_path"
    fi

    # Validate it looks like a service account key
    if ! python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'client_email' in d" \
        "$sa_key_path" 2>/dev/null; then
        fail "That doesn't look like a service account JSON key (missing client_email field)."
    fi

    cp "$sa_key_path" "$SA_KEY"
    chmod 600 "$SA_KEY"
    ok "Installed service account key to $SA_KEY"
fi

# Show the service account email for sharing
sa_email=$(python3 -c "import json; print(json.load(open('$SA_KEY'))['client_email'])" 2>/dev/null || echo "unknown")
echo ""
echo -e "  ${YELLOW}┌─ IMPORTANT ─────────────────────────────────────────────────────┐${RESET}"
echo -e "  ${YELLOW}│${RESET} Before continuing, share your Drive folder with this email:     ${YELLOW}│${RESET}"
echo -e "  ${YELLOW}│${RESET}                                                                 ${YELLOW}│${RESET}"
echo -e "  ${YELLOW}│${RESET}   ${BOLD}$sa_email${RESET}"
echo -e "  ${YELLOW}│${RESET}                                                                 ${YELLOW}│${RESET}"
echo -e "  ${YELLOW}│${RESET} In Google Drive: right-click folder → Share → paste the email   ${YELLOW}│${RESET}"
echo -e "  ${YELLOW}│${RESET} above → set role to ${BOLD}Viewer${RESET} → click Send.                        ${YELLOW}│${RESET}"
echo -e "  ${YELLOW}│${RESET} (Ignore the 'not a Google account' warning — it still works.)   ${YELLOW}│${RESET}"
echo -e "  ${YELLOW}└─────────────────────────────────────────────────────────────────┘${RESET}"
echo ""
read -rp "  Press Enter once you've shared the folder (or Ctrl-C to quit)..."

# ── Folder ID ────────────────────────────────────────────────────────────────

header "Step 2: Google Drive folder ID"

echo "  Now we need the ID of the Drive folder you want to monitor."
echo ""
echo "  To find it: open the folder in Google Drive and look at the URL."
echo "  It will look like this:"
echo ""
echo "    https://drive.google.com/drive/folders/${BOLD}1aBcDeFgHiJkLmNoPqRsTuVwXyZ${RESET}"
echo ""
echo "  The folder ID is the long string after /folders/ (highlighted above)."
echo "  You can paste the full URL or just the ID — we'll extract it either way."
echo ""

# Check if already configured
existing_folder_id=""
if [[ -f "$ENV_FILE" ]]; then
    existing_folder_id=$(grep -oP '^GDRIVE_FOLDER_ID=\K.+' "$ENV_FILE" 2>/dev/null || true)
fi

prompt_value folder_id "Drive folder URL or ID" "$existing_folder_id"

# Extract folder ID from full URL if the user pasted one
if [[ "$folder_id" == *"drive.google.com"* ]]; then
    folder_id=$(echo "$folder_id" | grep -oP 'folders/\K[A-Za-z0-9_-]+' || echo "$folder_id")
    log "Extracted folder ID: $folder_id"
fi

# ── RAG image name ───────────────────────────────────────────────────────────

header "Step 3: Configuration"

echo "  A couple of optional settings. The defaults are fine for most setups —"
echo "  just press Enter to accept them."
echo ""

existing_rag_image=""
if [[ -f "$ENV_FILE" ]]; then
    existing_rag_image=$(grep -oP '^RAG_IMAGE=\K.+' "$ENV_FILE" 2>/dev/null || true)
fi
echo "  The RAG image is the local OCI image where ingested documents are stored."
echo "  You'll reference it later with: ramalama run --rag <image> <model>"
prompt_value rag_image "RAG image name" "${existing_rag_image:-localhost/rag-data:latest}"
echo ""

existing_interval=""
if [[ -f "$ENV_FILE" ]]; then
    existing_interval=$(grep -oP '^WATCH_INTERVAL_MINUTES=\K.+' "$ENV_FILE" 2>/dev/null || true)
fi
echo "  How often should we check Drive for new or changed files?"
prompt_value interval "Poll interval in minutes" "${existing_interval:-15}"

# ── Write env vars ───────────────────────────────────────────────────────────

header "Step 4: Writing configuration"

# Remove any existing rag-watcher vars from env file, then append fresh ones
if [[ -f "$ENV_FILE" ]]; then
    # Strip old rag-watcher block
    sed -i '/^# ── RAG Watcher/,/^$/d' "$ENV_FILE"
    sed -i '/^GDRIVE_FOLDER_ID=/d; /^RAG_IMAGE=/d; /^WATCH_INTERVAL_MINUTES=/d' "$ENV_FILE"
fi

cat >> "$ENV_FILE" <<EOF

# ── RAG Watcher ─────────────────────────────────────────────────────────────
GDRIVE_FOLDER_ID=$folder_id
RAG_IMAGE=$rag_image
WATCH_INTERVAL_MINUTES=$interval
EOF

ok "Updated $ENV_FILE"

# ── Install quadlet ──────────────────────────────────────────────────────────

header "Step 5: Installing quadlet"

cp "$REPO_DIR/quadlets/rag-watcher.container" "$QUADLET_DIR/"
ok "Copied rag-watcher.container to $QUADLET_DIR"

systemctl --user daemon-reload
ok "Reloaded systemd"

# ── Verify connection ────────────────────────────────────────────────────────

header "Step 6: Verifying Drive access"

log "Testing connection to folder $folder_id..."

if python3 -c "
import sys
from google.oauth2 import service_account
from googleapiclient.discovery import build

creds = service_account.Credentials.from_service_account_file(
    '$SA_KEY',
    scopes=['https://www.googleapis.com/auth/drive.readonly'],
)
svc = build('drive', 'v3', credentials=creds)
resp = svc.files().list(
    q=\"'$folder_id' in parents and trashed = false\",
    fields='files(id, name)',
    pageSize=5,
).execute()
files = resp.get('files', [])
print(f'Found {len(files)} file(s) in folder')
for f in files[:5]:
    print(f'  - {f[\"name\"]}')
" 2>/dev/null; then
    ok "Drive access verified"
else
    warn "Could not list folder contents"
    echo ""
    echo "  This usually means one of:"
    echo ""
    echo "  • The folder hasn't been shared with the service account yet."
    echo "    → In Drive: right-click folder → Share → add $sa_email as Viewer"
    echo ""
    echo "  • The Google Drive API isn't enabled in your Cloud project."
    echo "    → Go to: https://console.cloud.google.com/apis/library"
    echo "      Search 'Google Drive API' and click Enable"
    echo ""
    echo "  • The folder ID is wrong."
    echo "    → Double-check the URL: https://drive.google.com/drive/folders/<ID>"
    echo ""
    echo "  • The Python Google API libraries aren't installed on this host."
    echo "    → Run: pip install -r $SCRIPT_DIR/requirements.txt"
    echo ""
    echo "  The quadlet is installed regardless — once you fix the issue, start"
    echo "  the service with: systemctl --user enable --now rag-watcher"
fi

# ── Start service ────────────────────────────────────────────────────────────

header "Step 7: Start service"

echo "  Ready to start the RAG watcher?"
read -rp "  Start now? [Y/n]: " start_now

if [[ "${start_now,,}" != "n" ]]; then
    systemctl --user enable rag-watcher
    systemctl --user start rag-watcher
    ok "rag-watcher started and enabled"
    echo ""
    log "Check logs: journalctl --user -u rag-watcher -f"
else
    echo ""
    log "Start later with:"
    echo "    systemctl --user enable --now rag-watcher"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

header "Setup complete"

echo "  Use the RAG image with any model:"
echo "    ramalama run --rag $rag_image <model>"
echo ""
echo "  Manage the watcher:"
echo "    systemctl --user status rag-watcher"
echo "    systemctl --user stop rag-watcher"
echo "    journalctl --user -u rag-watcher -f"
echo ""
