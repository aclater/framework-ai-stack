#!/bin/bash
# Deploy and run one-shot RAG ingestion on lennon.home.arpa
# Embeds locally on lennon (32 cores, 125GB RAM), pushes to harrison's Qdrant + Postgres
set -euo pipefail

REMOTE="lennon.home.arpa"
REMOTE_DIR="/tmp/rag-ingest"
HARRISON="192.168.1.122"
SA_KEY="$HOME/.config/ramalama/gdrive-sa.json"

echo "=== Deploying to $REMOTE ==="

# Create remote directory and copy files
ssh "$REMOTE" "mkdir -p $REMOTE_DIR"
scp ingest-remote.py "$REMOTE:$REMOTE_DIR/"

# Copy SA key if it exists
if [[ -f "$SA_KEY" ]]; then
    ssh "$REMOTE" "mkdir -p ~/.config/ramalama"
    scp "$SA_KEY" "$REMOTE:~/.config/ramalama/gdrive-sa.json"
    echo "Copied SA key"
fi

echo "=== Installing dependencies ==="
ssh "$REMOTE" "cd $REMOTE_DIR && \
    python3 -m venv --system-site-packages venv && \
    source venv/bin/activate && \
    pip install -q \
        sentence-transformers \
        qdrant-client \
        psycopg2-binary \
        langchain-text-splitters \
        google-api-python-client \
        google-auth-httplib2 \
        google-auth-oauthlib \
        pypdf \
        python-docx \
        python-pptx \
        openpyxl \
        requests"

echo "=== Running ingestion ==="
ssh "$REMOTE" "cd $REMOTE_DIR && \
    source venv/bin/activate && \
    HARRISON_HOST=$HARRISON \
    GDRIVE_FOLDER_ID=${GDRIVE_FOLDER_ID:-1_ad-SbUR5LxT954YhRJg5Pbeaz8v8ddu} \
    REPO_SOURCES='${REPO_SOURCES:-}' \
    WEB_SOURCES='${WEB_SOURCES:-}' \
    EMBED_THREADS=32 \
    python3 ingest-remote.py"
