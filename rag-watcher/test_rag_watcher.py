"""Tests for rag-watcher batching and RAM budget logic."""

import importlib
import sys
from pathlib import Path
from unittest import mock

import pytest

# Import without needing google API deps
sys.modules.setdefault("google.oauth2", mock.MagicMock())
sys.modules.setdefault("google.oauth2.service_account", mock.MagicMock())
sys.modules.setdefault("googleapiclient", mock.MagicMock())
sys.modules.setdefault("googleapiclient.discovery", mock.MagicMock())
sys.modules.setdefault("googleapiclient.http", mock.MagicMock())

spec = importlib.util.spec_from_file_location(
    "rag_watcher",
    Path(__file__).with_name("rag-watcher.py"),
)
rw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rw)


# ---------------------------------------------------------------------------
# _plan_batches
# ---------------------------------------------------------------------------

def _make_files(tmp_path, sizes_mb):
    """Create dummy files of given sizes (in MB). Returns list of Paths."""
    files = []
    for i, size_mb in enumerate(sizes_mb):
        p = tmp_path / f"doc_{i}.pdf"
        p.write_bytes(b"\x00" * int(size_mb * 1024 * 1024))
        files.append(p)
    return files


def test_plan_batches_single_batch(tmp_path):
    files = _make_files(tmp_path, [1, 1, 1])
    # Budget of 100 MB, multiplier 20 -> each 1 MB file = 20 MB estimated
    # Total = 60 MB, fits in 100 MB
    batches = rw._plan_batches(files, 100)
    assert len(batches) == 1
    assert len(batches[0]) == 3


def test_plan_batches_splits_when_needed(tmp_path):
    files = _make_files(tmp_path, [1, 1, 1, 1])
    # Budget 50 MB, multiplier 20 -> each 1 MB = 20 MB, so 2 per batch
    batches = rw._plan_batches(files, 50)
    assert len(batches) == 2
    assert all(len(b) == 2 for b in batches)


def test_plan_batches_large_file_gets_own_batch(tmp_path):
    files = _make_files(tmp_path, [0.5, 0.5, 5])
    # Budget 30 MB, multiplier 20 -> 0.5 MB = 10 MB est, 5 MB = 100 MB est
    # First two fit together (20 MB), big one alone
    batches = rw._plan_batches(files, 30)
    assert len(batches) == 2
    assert len(batches[0]) == 2  # two small files
    assert len(batches[1]) == 1  # the big file alone


def test_plan_batches_empty(tmp_path):
    batches = rw._plan_batches([], 100)
    assert batches == []


# ---------------------------------------------------------------------------
# _get_ram_budget_mb
# ---------------------------------------------------------------------------

def test_ram_budget_respects_min_free():
    with mock.patch.object(rw, "get_available_ram_mb", return_value=3000), \
         mock.patch.object(rw, "_RAM_MIN_FREE_MB", 4096):
        assert rw._get_ram_budget_mb() == 0.0


def test_ram_budget_respects_cap():
    with mock.patch.object(rw, "get_available_ram_mb", return_value=60000), \
         mock.patch.object(rw, "_RAM_MIN_FREE_MB", 4096), \
         mock.patch.object(rw, "_RAM_BUDGET_FRACTION", 0.3), \
         mock.patch.object(rw, "_RAM_BUDGET_CAP_MB", 8192):
        budget = rw._get_ram_budget_mb()
        # (60000 - 4096) * 0.3 = 16771, but capped at 8192
        assert budget == 8192


def test_ram_budget_normal():
    with mock.patch.object(rw, "get_available_ram_mb", return_value=20000), \
         mock.patch.object(rw, "_RAM_MIN_FREE_MB", 4096), \
         mock.patch.object(rw, "_RAM_BUDGET_FRACTION", 0.3), \
         mock.patch.object(rw, "_RAM_BUDGET_CAP_MB", 8192):
        budget = rw._get_ram_budget_mb()
        assert budget == pytest.approx((20000 - 4096) * 0.3)


# ---------------------------------------------------------------------------
# rebuild_rag — integration with mocked ramalama
# ---------------------------------------------------------------------------

def test_rebuild_single_batch_all_fit(tmp_path):
    files = _make_files(tmp_path, [0.1, 0.1])
    with mock.patch.object(rw, "get_available_ram_mb", return_value=30000), \
         mock.patch.object(rw, "_RAM_MIN_FREE_MB", 4096), \
         mock.patch.object(rw, "_RAM_BUDGET_FRACTION", 0.3), \
         mock.patch.object(rw, "_RAM_BUDGET_CAP_MB", 8192), \
         mock.patch.object(rw, "_run_ramalama_rag", return_value=True) as run_mock:
        result = rw.rebuild_rag(tmp_path, "localhost/test:latest")
        assert result is True
        assert run_mock.call_count == 1
        # Should pass files directly, not a directory
        paths_arg = run_mock.call_args[0][0]
        assert all(isinstance(p, Path) for p in paths_arg)


def test_rebuild_batches_when_tight(tmp_path):
    # 4 files at 1 MB each; multiplier=20 -> 20 MB estimated each
    files = _make_files(tmp_path, [1, 1, 1, 1])
    with mock.patch.object(rw, "get_available_ram_mb", return_value=10000), \
         mock.patch.object(rw, "_RAM_MIN_FREE_MB", 4096), \
         mock.patch.object(rw, "_RAM_BUDGET_FRACTION", 0.5), \
         mock.patch.object(rw, "_RAM_BUDGET_CAP_MB", 8192), \
         mock.patch.object(rw, "_run_ramalama_rag", return_value=True) as run_mock:
        # budget = (10000-4096)*0.5 = 2952 MB -> each file est 20 MB -> ~147 per batch
        # but that's huge... let's force a smaller budget
        pass

    # More realistic: budget that forces splits
    with mock.patch.object(rw, "get_available_ram_mb", return_value=8200), \
         mock.patch.object(rw, "_RAM_MIN_FREE_MB", 4096), \
         mock.patch.object(rw, "_RAM_BUDGET_FRACTION", 1.0), \
         mock.patch.object(rw, "_RAM_BUDGET_CAP_MB", 30), \
         mock.patch.object(rw, "_run_ramalama_rag", return_value=True) as run_mock:
        # budget = min((8200-4096)*1.0, 30) = 30 MB
        # each 1MB file * 20 = 20 MB est -> 1 per batch (second won't fit)
        result = rw.rebuild_rag(tmp_path, "localhost/test:latest")
        assert result is True
        assert run_mock.call_count == 4  # one per file


def test_rebuild_aborts_when_ram_drops(tmp_path):
    files = _make_files(tmp_path, [1, 1, 1])
    call_count = 0

    def fake_available():
        nonlocal call_count
        call_count += 1
        # Calls 1-3: initial check + _get_ram_budget_mb in rebuild_rag + batch 1 re-check
        if call_count <= 3:
            return 10000
        return 2000  # below _RAM_MIN_FREE_MB

    with mock.patch.object(rw, "get_available_ram_mb", side_effect=fake_available), \
         mock.patch.object(rw, "_RAM_MIN_FREE_MB", 4096), \
         mock.patch.object(rw, "_RAM_BUDGET_FRACTION", 1.0), \
         mock.patch.object(rw, "_RAM_BUDGET_CAP_MB", 25), \
         mock.patch.object(rw, "_run_ramalama_rag", return_value=True) as run_mock:
        result = rw.rebuild_rag(tmp_path, "localhost/test:latest")
        assert result is False
        # Should have run batch 1 then aborted before batch 2
        assert run_mock.call_count == 1


def test_rebuild_skips_when_no_ram(tmp_path):
    _make_files(tmp_path, [1])
    with mock.patch.object(rw, "get_available_ram_mb", return_value=2000), \
         mock.patch.object(rw, "_RAM_MIN_FREE_MB", 4096), \
         mock.patch.object(rw, "_run_ramalama_rag") as run_mock:
        result = rw.rebuild_rag(tmp_path, "localhost/test:latest")
        assert result is False
        run_mock.assert_not_called()
