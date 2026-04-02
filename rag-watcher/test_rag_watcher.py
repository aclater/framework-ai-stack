"""Tests for rag-watcher — covers text extraction, point ID determinism,
and state management."""

import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import patch, MagicMock

# Stub out heavy dependencies that aren't installed in the test environment.
# Use a dedicated dict so we can clean up without poisoning other test files.
_STUBS = {}
for _mod in [
    "google.oauth2.service_account",
    "googleapiclient.discovery",
    "googleapiclient.http",
    "langchain_text_splitters",
]:
    if _mod not in sys.modules:
        _STUBS[_mod] = MagicMock()
        sys.modules[_mod] = _STUBS[_mod]

# qdrant_client is a real package used by other test files — only stub if missing.
for _mod in ["qdrant_client", "qdrant_client.models"]:
    try:
        __import__(_mod)
    except ImportError:
        _STUBS[_mod] = MagicMock()
        sys.modules[_mod] = _STUBS[_mod]

spec = importlib.util.spec_from_file_location(
    "rag_watcher",
    Path(__file__).with_name("rag-watcher.py"),
)
rw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rw)


# ── Point ID determinism ────────────────────────────────────────────────────


class TestPointId:
    """Deterministic point IDs for idempotent Qdrant upsert."""

    def test_deterministic(self):
        a = rw._point_id("doc-abc", 0)
        b = rw._point_id("doc-abc", 0)
        assert a == b, "Same inputs must produce same ID"

    def test_different_chunks_differ(self):
        a = rw._point_id("doc-abc", 0)
        b = rw._point_id("doc-abc", 1)
        assert a != b, "Different chunk_ids must produce different IDs"

    def test_different_docs_differ(self):
        a = rw._point_id("doc-abc", 0)
        b = rw._point_id("doc-xyz", 0)
        assert a != b, "Different doc_ids must produce different IDs"

    def test_returns_int(self):
        result = rw._point_id("doc-abc", 0)
        assert isinstance(result, int)


# ── Text extraction ─────────────────────────────────────────────────────────


class TestExtractText:
    """Text extraction from various file types."""

    def test_plain_text(self, tmp_path):
        f = tmp_path / "test.txt"
        f.write_text("Hello world")
        assert rw.extract_text(f) == "Hello world"

    def test_markdown(self, tmp_path):
        f = tmp_path / "test.md"
        f.write_text("# Title\n\nBody text")
        result = rw.extract_text(f)
        assert "Title" in result
        assert "Body" in result

    def test_empty_file(self, tmp_path):
        f = tmp_path / "empty.txt"
        f.write_text("")
        assert rw.extract_text(f) == ""

    def test_unsupported_extension(self, tmp_path):
        f = tmp_path / "data.bin"
        f.write_bytes(b"\x00\x01\x02")
        result = rw.extract_text(f)
        assert result == "" or isinstance(result, str)


# ── State management ────────────────────────────────────────────────────────


class TestState:
    """State file load/save for Drive polling."""

    def test_load_missing_file(self, tmp_path):
        with patch.object(rw, "STATE_PATH", tmp_path / "missing.json"):
            state = rw.load_state()
            assert state == {}

    def test_save_and_load(self, tmp_path):
        state_file = tmp_path / "state.json"
        with patch.object(rw, "STATE_PATH", state_file):
            rw.save_state({"file1": "2026-01-01T00:00:00Z"})
            loaded = rw.load_state()
            assert loaded == {"file1": "2026-01-01T00:00:00Z"}

    def test_save_overwrites(self, tmp_path):
        state_file = tmp_path / "state.json"
        with patch.object(rw, "STATE_PATH", state_file):
            rw.save_state({"a": "1"})
            rw.save_state({"b": "2"})
            loaded = rw.load_state()
            assert "a" not in loaded
            assert loaded == {"b": "2"}
