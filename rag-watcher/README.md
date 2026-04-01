# Google Drive RAG Watcher

Polls a Google Drive folder for new or modified documents and automatically rebuilds a RamaLama RAG OCI image.

Supported file types: PDF, DOCX, PPTX, XLSX, HTML, Markdown. Google Docs/Sheets/Slides are exported automatically.

## Setup

### 1. Create a Google Cloud service account

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a project (or select an existing one)
3. Enable the **Google Drive API**: APIs & Services → Library → search "Google Drive API" → Enable
4. Create a service account: IAM & Admin → Service Accounts → Create Service Account
5. Give it a name (e.g. `ramalama-rag-reader`) — no roles needed
6. Click the service account → Keys → Add Key → Create new key → JSON
7. Save the downloaded JSON key file to `~/.config/ramalama/gdrive-sa.json`:

```bash
mkdir -p ~/.config/ramalama
mv ~/Downloads/your-project-*.json ~/.config/ramalama/gdrive-sa.json
chmod 600 ~/.config/ramalama/gdrive-sa.json
```

### 2. Share the Drive folder with the service account

1. Open the JSON key file and find the `client_email` field (e.g. `ramalama-rag-reader@your-project.iam.gserviceaccount.com`)
2. In Google Drive, right-click the folder you want to monitor → Share
3. Paste the service account email and grant **Viewer** access
4. Click Send (ignore the "not a Google account" warning)

### 3. Get the folder ID

Open the folder in Google Drive. The URL looks like:

```
https://drive.google.com/drive/folders/1aBcDeFgHiJkLmNoPqRsTuVwXyZ
```

The folder ID is the last segment: `1aBcDeFgHiJkLmNoPqRsTuVwXyZ`

### 4. Configure environment variables

Copy the example env file and edit it:

```bash
cp rag-watcher.env.example ~/.config/llm-stack/rag-watcher.env
# Edit GDRIVE_FOLDER_ID with your folder ID
```

Or add the variables to your existing `~/.config/llm-stack/env`:

```bash
GDRIVE_FOLDER_ID=1aBcDeFgHiJkLmNoPqRsTuVwXyZ
RAG_IMAGE=localhost/rag-data:latest
WATCH_INTERVAL_MINUTES=15
GOOGLE_APPLICATION_CREDENTIALS=~/.config/ramalama/gdrive-sa.json
```

### 5. Deploy the quadlet

```bash
cp quadlets/rag-watcher.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start rag-watcher
systemctl --user enable rag-watcher   # start on login
```

Check logs:

```bash
journalctl --user -u rag-watcher -f
```

## Using the RAG image with RamaLama

Once the watcher has built the RAG image, use it with any model:

```bash
ramalama run --rag localhost/rag-data:latest granite-moe
```

Or with the models already configured in the llm-stack:

```bash
ramalama run --rag localhost/rag-data:latest qwen2.5-coder
```

## Running standalone (without container)

```bash
cd rag-watcher
pip install -r requirements.txt
export GDRIVE_FOLDER_ID=your-folder-id
export GOOGLE_APPLICATION_CREDENTIALS=~/.config/ramalama/gdrive-sa.json
python rag-watcher.py
```

## State tracking

Ingested files are tracked in `~/.local/share/ramalama/rag-state.json`. Delete this file to force a full re-ingestion on the next poll cycle.
