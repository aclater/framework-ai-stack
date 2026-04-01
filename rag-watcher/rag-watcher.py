#!/usr/bin/env python3
"""Google Drive RAG watcher — polls a Drive folder and rebuilds a RAG OCI image."""

import json
import logging
import os
import subprocess
import sys
import time
from pathlib import Path

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("rag-watcher")

SCOPES = ["https://www.googleapis.com/auth/drive.readonly"]

# Supported MIME types and their export conversions (native Google formats)
EXPORT_MAP = {
    "application/vnd.google-apps.document": (
        "application/pdf",
        ".pdf",
    ),
    "application/vnd.google-apps.spreadsheet": (
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ".xlsx",
    ),
    "application/vnd.google-apps.presentation": (
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ".pptx",
    ),
}

# Binary file extensions we download directly
DOWNLOAD_EXTENSIONS = {".pdf", ".docx", ".pptx", ".xlsx", ".html", ".md"}

STATE_PATH = Path(
    os.environ.get(
        "RAG_STATE_FILE",
        Path.home() / ".local" / "share" / "ramalama" / "rag-state.json",
    )
)


def load_state() -> dict:
    if STATE_PATH.exists():
        return json.loads(STATE_PATH.read_text())
    return {}


def save_state(state: dict) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, indent=2))


def get_drive_service():
    creds_file = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not creds_file:
        log.error("GOOGLE_APPLICATION_CREDENTIALS is not set")
        sys.exit(1)

    creds_path = Path(creds_file).expanduser()
    if not creds_path.exists():
        log.error("Service account key not found: %s", creds_path)
        sys.exit(1)

    creds = service_account.Credentials.from_service_account_file(
        str(creds_path), scopes=SCOPES
    )
    return build("drive", "v3", credentials=creds)


def list_files(service, folder_id: str) -> list[dict]:
    """List all supported files in the given Drive folder."""
    results = []
    page_token = None

    while True:
        resp = (
            service.files()
            .list(
                q=f"'{folder_id}' in parents and trashed = false",
                fields="nextPageToken, files(id, name, mimeType, modifiedTime)",
                pageSize=100,
                pageToken=page_token,
            )
            .execute()
        )
        results.extend(resp.get("files", []))
        page_token = resp.get("nextPageToken")
        if not page_token:
            break

    return results


def download_file(service, file_info: dict, staging_dir: Path) -> bool:
    """Download or export a single file to the staging directory."""
    file_id = file_info["id"]
    name = file_info["name"]
    mime = file_info["mimeType"]

    # Google native format — export
    if mime in EXPORT_MAP:
        export_mime, ext = EXPORT_MAP[mime]
        dest = staging_dir / f"{Path(name).stem}{ext}"
        log.info("Exporting %s → %s", name, dest.name)
        request = service.files().export_media(fileId=file_id, mimeType=export_mime)
    else:
        # Regular file — check extension
        ext = Path(name).suffix.lower()
        if ext not in DOWNLOAD_EXTENSIONS:
            log.debug("Skipping unsupported file: %s", name)
            return False
        dest = staging_dir / name
        log.info("Downloading %s", name)
        request = service.files().get_media(fileId=file_id)

    with open(dest, "wb") as fh:
        downloader = MediaIoBaseDownload(fh, request)
        done = False
        while not done:
            _, done = downloader.next_chunk()

    return True


def rebuild_rag(staging_dir: Path, rag_image: str) -> bool:
    """Run ramalama rag to rebuild the OCI image."""
    log.info("Rebuilding RAG image: %s", rag_image)
    try:
        subprocess.run(
            ["ramalama", "rag", str(staging_dir), rag_image],
            check=True,
        )
        log.info("RAG image rebuilt successfully")
        return True
    except subprocess.CalledProcessError as exc:
        log.error("ramalama rag failed (exit %d)", exc.returncode)
        return False
    except FileNotFoundError:
        log.error("ramalama not found on PATH")
        return False


def poll_once(service, folder_id: str, staging_dir: Path, rag_image: str) -> None:
    """Single poll iteration: check for changes, download, rebuild if needed."""
    state = load_state()
    files = list_files(service, folder_id)
    changed = []

    for f in files:
        fid = f["id"]
        modified = f["modifiedTime"]
        if state.get(fid) != modified:
            changed.append(f)

    if not changed:
        log.info("No new or modified files")
        return

    log.info("Detected %d new/modified file(s)", len(changed))

    downloaded = 0
    new_state = dict(state)

    for f in changed:
        if download_file(service, f, staging_dir):
            new_state[f["id"]] = f["modifiedTime"]
            downloaded += 1

    if downloaded == 0:
        log.info("No downloadable files among changes")
        save_state(new_state)
        return

    if rebuild_rag(staging_dir, rag_image):
        save_state(new_state)
    else:
        log.warning("State not updated due to RAG build failure — will retry next poll")


def main() -> None:
    folder_id = os.environ.get("GDRIVE_FOLDER_ID")
    if not folder_id:
        log.error("GDRIVE_FOLDER_ID is not set")
        sys.exit(1)

    rag_image = os.environ.get("RAG_IMAGE", "localhost/rag-data:latest")
    interval = int(os.environ.get("WATCH_INTERVAL_MINUTES", "15"))
    staging_dir = Path(os.environ.get("STAGING_DIR", "/tmp/ramalama-rag-staging"))

    staging_dir.mkdir(parents=True, exist_ok=True)

    log.info("Starting Drive RAG watcher")
    log.info("  Folder ID:  %s", folder_id)
    log.info("  RAG image:  %s", rag_image)
    log.info("  Interval:   %d min", interval)
    log.info("  Staging:    %s", staging_dir)

    service = get_drive_service()

    while True:
        try:
            poll_once(service, folder_id, staging_dir, rag_image)
        except Exception:
            log.exception("Poll cycle failed")
        time.sleep(interval * 60)


if __name__ == "__main__":
    main()
