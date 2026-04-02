#!/usr/bin/env python3
"""Google Drive RAG watcher — polls a Drive folder and rebuilds a RAG OCI image."""

import json
import logging
import os
import shutil
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


def get_available_ram_mb() -> int:
    """Get available system RAM in MB from /proc/meminfo."""
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) // 1024
    return 0


# ramalama rag peak memory is roughly this multiple of raw file size on disk
_RAM_MULTIPLIER = int(os.environ.get("RAG_RAM_MULTIPLIER", "20"))
# fraction of available RAM we're willing to use — conservative to leave
# headroom for desktop apps (Chrome, Signal), model serving, and system stability
_RAM_BUDGET_FRACTION = float(os.environ.get("RAG_RAM_BUDGET_FRACTION", "0.20"))
# absolute maximum budget cap — prevents excessive memory usage even with
# large available RAM, prioritizing desktop stability over RAG throughput
# 128GB system: 64GB CPU RAM = 65536 MB, 20% = ~13GB, cap at 12GB for safety
_RAM_BUDGET_CAP_MB = int(os.environ.get("RAG_RAM_BUDGET_CAP_MB", "12288"))
# minimum RAM that must remain free before we start a batch — ensures desktop
# remains responsive and prevents OOM kills of user applications
# 128GB system: keep 16GB free for desktop + model serving + system overhead
_RAM_MIN_FREE_MB = int(os.environ.get("RAG_RAM_MIN_FREE_MB", "16384"))


def _get_ram_budget_mb() -> float:
    """Compute the RAM budget for a single batch, re-checked each time."""
    available_mb = get_available_ram_mb()
    if available_mb < _RAM_MIN_FREE_MB:
        return 0.0
    usable_mb = available_mb - _RAM_MIN_FREE_MB
    budget = usable_mb * _RAM_BUDGET_FRACTION
    return min(budget, _RAM_BUDGET_CAP_MB)


def _plan_batches(files: list[Path], budget_mb: float) -> list[list[Path]]:
    """Split files into batches whose estimated peak RAM fits within budget_mb."""
    sorted_files = sorted(files, key=lambda f: f.stat().st_size)
    batches: list[list[Path]] = []
    batch: list[Path] = []
    batch_mb = 0.0

    for f in sorted_files:
        size_mb = f.stat().st_size / (1024 * 1024)
        estimated = size_mb * _RAM_MULTIPLIER
        if batch and batch_mb + estimated > budget_mb:
            batches.append(batch)
            batch = [f]
            batch_mb = estimated
        else:
            batch.append(f)
            batch_mb += estimated

    if batch:
        batches.append(batch)
    return batches


def _run_ramalama_rag(paths: list[Path], rag_image: str) -> bool:
    """Run ramalama rag on one or more file paths. Returns True on success."""
    cmd = ["ramalama", "rag"] + [str(p) for p in paths] + [rag_image]
    try:
        subprocess.run(cmd, check=True)
        return True
    except subprocess.CalledProcessError as exc:
        log.error("ramalama rag failed (exit %d)", exc.returncode)
        return False
    except FileNotFoundError:
        log.error("ramalama not found on PATH")
        return False


def rebuild_rag(staging_dir: Path, rag_image: str) -> bool:
    """Run ramalama rag to rebuild the OCI image, batching documents if needed."""
    all_files = [f for f in staging_dir.iterdir() if f.is_file()]
    if not all_files:
        log.warning("No files in staging directory")
        return True

    budget_mb = _get_ram_budget_mb()
    total_size_mb = sum(f.stat().st_size for f in all_files) / (1024 * 1024)
    estimated_peak_mb = total_size_mb * _RAM_MULTIPLIER

    log.info(
        "RAM check: %.0f MB available, %.0f MB budget (%.0f%% of usable, "
        "cap %d MB, %d MB reserved), %.1f MB docs on disk, ~%.0f MB estimated peak",
        get_available_ram_mb(), budget_mb, _RAM_BUDGET_FRACTION * 100,
        _RAM_BUDGET_CAP_MB, _RAM_MIN_FREE_MB,
        total_size_mb, estimated_peak_mb,
    )

    if budget_mb <= 0:
        log.error(
            "Available RAM (%d MB) below minimum free threshold (%d MB) — "
            "skipping RAG build this cycle",
            get_available_ram_mb(), _RAM_MIN_FREE_MB,
        )
        return False

    if estimated_peak_mb <= budget_mb:
        log.info("All %d files fit in RAM budget — processing at once", len(all_files))
        return _run_ramalama_rag(all_files, rag_image)

    # Batch: pass each batch of files directly to ramalama (no accumulation —
    # ramalama rag appends to the OCI image on each invocation)
    batches = _plan_batches(all_files, budget_mb)
    log.info(
        "Batching %d files into %d batches to stay within %.0f MB budget",
        len(all_files), len(batches), budget_mb,
    )

    for i, batch in enumerate(batches, 1):
        # Re-check RAM before each batch — a prior batch or other process may
        # have changed available memory
        current_budget = _get_ram_budget_mb()
        if current_budget <= 0:
            log.error(
                "Available RAM dropped below minimum free threshold before "
                "batch %d/%d — aborting (processed %d/%d batches)",
                i, len(batches), i - 1, len(batches),
            )
            return False

        batch_size_mb = sum(f.stat().st_size for f in batch) / (1024 * 1024)
        log.info(
            "Batch %d/%d: %d file(s) (%.1f MB on disk), "
            "%.0f MB RAM available, %.0f MB budget",
            i, len(batches), len(batch), batch_size_mb,
            get_available_ram_mb(), current_budget,
        )
        if not _run_ramalama_rag(batch, rag_image):
            return False

    log.info("RAG image rebuilt successfully (%d batches)", len(batches))
    return True


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
