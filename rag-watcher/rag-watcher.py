#!/usr/bin/env python3
"""Google Drive RAG watcher — polls a Drive folder and ingests documents into Qdrant."""

import json
import logging
import os
import sys
import time
import uuid
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
DOWNLOAD_EXTENSIONS = {".pdf", ".docx", ".pptx", ".xlsx", ".html", ".md", ".txt"}

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


# ── Text extraction ──────────────────────────────────────────────────────────

def extract_text(file_path: Path) -> str:
    """Extract text from a file based on its extension."""
    ext = file_path.suffix.lower()

    if ext == ".md" or ext == ".txt" or ext == ".html":
        return file_path.read_text(errors="replace")

    if ext == ".pdf":
        try:
            import pypdf
            reader = pypdf.PdfReader(str(file_path))
            return "\n\n".join(page.extract_text() or "" for page in reader.pages)
        except Exception:
            log.warning("Failed to extract text from PDF: %s", file_path.name)
            return ""

    if ext == ".docx":
        try:
            import docx
            doc = docx.Document(str(file_path))
            return "\n\n".join(p.text for p in doc.paragraphs if p.text.strip())
        except Exception:
            log.warning("Failed to extract text from DOCX: %s", file_path.name)
            return ""

    if ext == ".pptx":
        try:
            from pptx import Presentation
            prs = Presentation(str(file_path))
            texts = []
            for slide in prs.slides:
                for shape in slide.shapes:
                    if shape.has_text_frame:
                        texts.append(shape.text_frame.text)
            return "\n\n".join(texts)
        except Exception:
            log.warning("Failed to extract text from PPTX: %s", file_path.name)
            return ""

    if ext == ".xlsx":
        try:
            import openpyxl
            wb = openpyxl.load_workbook(str(file_path), read_only=True, data_only=True)
            texts = []
            for ws in wb.worksheets:
                for row in ws.iter_rows(values_only=True):
                    vals = [str(c) for c in row if c is not None]
                    if vals:
                        texts.append(" | ".join(vals))
            return "\n".join(texts)
        except Exception:
            log.warning("Failed to extract text from XLSX: %s", file_path.name)
            return ""

    return ""


def chunk_text(text: str, chunk_size: int = 1024, overlap: int = 128) -> list[str]:
    """Split text into overlapping chunks."""
    if len(text) <= chunk_size:
        return [text] if text.strip() else []

    chunks = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        start = end - overlap

    return chunks


# ── Qdrant ingestion ─────────────────────────────────────────────────────────

def get_qdrant_client():
    from qdrant_client import QdrantClient
    url = os.environ.get("QDRANT_URL", "http://127.0.0.1:6333")
    return QdrantClient(url=url, timeout=30)


def get_embedder():
    from sentence_transformers import SentenceTransformer
    model_name = os.environ.get("EMBED_MODEL", "sentence-transformers/all-mpnet-base-v2")
    log.info("Loading embedding model: %s", model_name)
    return SentenceTransformer(model_name)


def ensure_collection(qdrant, collection_name: str, vector_size: int):
    from qdrant_client.models import Distance, VectorParams
    collections = [c.name for c in qdrant.get_collections().collections]
    if collection_name not in collections:
        qdrant.create_collection(
            collection_name=collection_name,
            vectors_config=VectorParams(size=vector_size, distance=Distance.COSINE),
        )
        log.info("Created Qdrant collection: %s", collection_name)


def ingest_files(staging_dir: Path) -> bool:
    """Extract text from staged files, embed, and upsert into Qdrant."""
    from qdrant_client.models import PointStruct

    all_files = [f for f in staging_dir.iterdir() if f.is_file()]
    if not all_files:
        log.warning("No files in staging directory")
        return True

    collection_name = os.environ.get("QDRANT_COLLECTION", "documents")
    chunk_size = int(os.environ.get("CHUNK_SIZE", "1024"))
    chunk_overlap = int(os.environ.get("CHUNK_OVERLAP", "128"))

    # Extract and chunk all documents
    all_chunks = []
    for f in all_files:
        text = extract_text(f)
        if not text:
            log.warning("No text extracted from %s — skipping", f.name)
            continue
        chunks = chunk_text(text, chunk_size, chunk_overlap)
        for chunk in chunks:
            all_chunks.append({"text": chunk, "source": f.name})
        log.info("Extracted %d chunks from %s", len(chunks), f.name)

    if not all_chunks:
        log.warning("No text chunks to ingest")
        return True

    log.info("Embedding %d chunks total...", len(all_chunks))
    embedder = get_embedder()
    texts = [c["text"] for c in all_chunks]
    vectors = embedder.encode(texts, show_progress_bar=True).tolist()

    qdrant = get_qdrant_client()
    ensure_collection(qdrant, collection_name, len(vectors[0]))

    # Delete existing points and re-ingest (full rebuild on each poll)
    qdrant.delete_collection(collection_name)
    ensure_collection(qdrant, collection_name, len(vectors[0]))

    points = [
        PointStruct(
            id=str(uuid.uuid4()),
            vector=vec,
            payload=chunk,
        )
        for vec, chunk in zip(vectors, all_chunks)
    ]

    # Upsert in batches of 100
    batch_size = 100
    for i in range(0, len(points), batch_size):
        batch = points[i : i + batch_size]
        qdrant.upsert(collection_name=collection_name, points=batch)

    log.info("Ingested %d chunks into Qdrant collection '%s'", len(points), collection_name)
    return True


# ── Poll loop ────────────────────────────────────────────────────────────────

def poll_once(service, folder_id: str, staging_dir: Path) -> None:
    """Single poll iteration: check for changes, download, ingest into Qdrant."""
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

    if ingest_files(staging_dir):
        save_state(new_state)
        log.info("Qdrant updated — new documents available for RAG immediately")
    else:
        log.warning("State not updated due to ingestion failure — will retry next poll")


def main() -> None:
    folder_id = os.environ.get("GDRIVE_FOLDER_ID")
    if not folder_id:
        log.error("GDRIVE_FOLDER_ID is not set")
        sys.exit(1)

    interval = int(os.environ.get("WATCH_INTERVAL_MINUTES", "15"))
    staging_dir = Path(os.environ.get("STAGING_DIR", "/tmp/rag-staging"))

    staging_dir.mkdir(parents=True, exist_ok=True)

    log.info("Starting Drive RAG watcher")
    log.info("  Folder ID:  %s", folder_id)
    log.info("  Qdrant:     %s", os.environ.get("QDRANT_URL", "http://127.0.0.1:6333"))
    log.info("  Collection: %s", os.environ.get("QDRANT_COLLECTION", "documents"))
    log.info("  Interval:   %d min", interval)
    log.info("  Staging:    %s", staging_dir)

    service = get_drive_service()

    while True:
        try:
            poll_once(service, folder_id, staging_dir)
        except Exception:
            log.exception("Poll cycle failed")
        time.sleep(interval * 60)


if __name__ == "__main__":
    main()
