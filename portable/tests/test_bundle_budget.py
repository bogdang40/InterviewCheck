"""Tests for M9 bundle budget: zero Three.js/Framer Motion, trimmed fonts, split lazy chunks, and <600 KiB JS."""
from __future__ import annotations

from html.parser import HTMLParser
import os
from pathlib import Path
import pytest

OUT_DIR = Path(__file__).resolve().parents[1] / "web" / "out"
STATIC_DIR = OUT_DIR / "_next" / "static"
MAX_ROUTE_ESM_BYTES = 600 * 1024  # 614,400 bytes (600 KiB)
FORBIDDEN_CHUNKS_TOKENS = ("WebGLRenderer", "framer-motion", "MotionConfig", "OrthographicCamera")


class _ScriptSrcParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.esm_srcs: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "script":
            return
        attr_map = {k.lower(): v for k, v in attrs}
        src = attr_map.get("src")
        if not src or "nomodule" in attr_map:
            return
        self.esm_srcs.append(src)


def _require_out_dir() -> Path:
    if not OUT_DIR.is_dir():
        if os.getenv("INTERVIEWCHECK_REQUIRE_WEB_OUT") == "1":
            pytest.fail(f"Expected built static bundle at {OUT_DIR}")
        pytest.skip("portable/web/out not built")
    return OUT_DIR


def _route_esm_files(html_path: Path) -> list[Path]:
    parser = _ScriptSrcParser()
    parser.feed(html_path.read_text(encoding="utf-8"))
    files: list[Path] = []
    for src in parser.esm_srcs:
        resolved = OUT_DIR / src.lstrip("/")
        assert resolved.is_file(), f"Missing script {src} referenced by {html_path.relative_to(OUT_DIR)}"
        files.append(resolved)
    return files


def test_chunks_exclude_three_and_framer_motion():
    _require_out_dir()
    chunks = sorted((STATIC_DIR / "chunks").rglob("*.js"))
    assert chunks, "Expected JS chunks in portable/web/out/_next/static/chunks"
    for chunk in chunks:
        text = chunk.read_text(encoding="utf-8", errors="ignore")
        for token in FORBIDDEN_CHUNKS_TOKENS:
            assert token not in text, f"Forbidden dependency token {token!r} found in {chunk.name}"


def test_media_drops_cyrillic_and_vietnamese_fonts():
    _require_out_dir()
    media_dir = STATIC_DIR / "media"
    files = sorted(p for p in media_dir.iterdir() if p.is_file())
    names = [p.name for p in files]
    assert len(files) == 6, f"Expected exactly 6 Latin/Latin-ext font files, got {len(files)}: {names}"
    for name in names:
        lower = name.lower()
        assert "cyrillic" not in lower, f"Unexpected Cyrillic font asset: {name}"
        assert "vietnamese" not in lower, f"Unexpected Vietnamese font asset: {name}"
        assert "latin" in lower, f"Unexpected non-Latin font asset: {name}"


def test_interviews_route_excludes_overview_only_modules():
    _require_out_dir()
    index_js = "".join(p.read_text(encoding="utf-8", errors="ignore") for p in _route_esm_files(OUT_DIR / "index.html"))
    interviews_js = "".join(
        p.read_text(encoding="utf-8", errors="ignore") for p in _route_esm_files(OUT_DIR / "interviews/index.html")
    )
    overview_markers = ("signal-field", "workspace-metrics", "Choose a role template")
    for marker in overview_markers:
        assert marker in index_js, f"Expected overview marker {marker!r} on /"
        assert marker not in interviews_js, f"Overview-only marker {marker!r} leaked into /interviews/"


def test_lazy_components_split_from_initial_route_scripts():
    _require_out_dir()
    all_chunks = {p: p.read_text(encoding="utf-8", errors="ignore") for p in sorted((STATIC_DIR / "chunks").rglob("*.js"))}
    admin_initial = "".join(
        p.read_text(encoding="utf-8", errors="ignore") for p in _route_esm_files(OUT_DIR / "admin/index.html")
    )
    review_initial = "".join(
        p.read_text(encoding="utf-8", errors="ignore") for p in _route_esm_files(OUT_DIR / "interviews/review/index.html")
    )

    for label, marker, initial_bundle in (
        ("ModelFormModal", "Save and connect", admin_initial),
        ("AccountsTab", "Update password", admin_initial),
        ("AuditLogTab", "Filter and export administrative audit events", admin_initial),
        ("TranscriptBatchImport", "Select a WebVTT transcript encoded as UTF-8.", review_initial),
        ("LocalRecordingPlayback", "LocalRecordingPlayback", review_initial),
    ):
        assert any(marker in text for text in all_chunks.values()), f"Lazy chunk for {label} missing from build output"
        assert marker not in initial_bundle, f"Lazy module {label} ({marker!r}) should not be in initial route scripts"


def test_route_initial_esm_js_under_600_kib():
    _require_out_dir()
    html_files = sorted(OUT_DIR.rglob("*.html"))
    assert html_files, "Expected exported HTML pages in portable/web/out"
    for html_path in html_files:
        esm_files = _route_esm_files(html_path)
        assert esm_files, f"No active ESM scripts found in {html_path.relative_to(OUT_DIR)}"
        total_bytes = sum(p.stat().st_size for p in esm_files)
        assert total_bytes < MAX_ROUTE_ESM_BYTES, (
            f"{html_path.relative_to(OUT_DIR)} initial ESM JS {total_bytes} B >= {MAX_ROUTE_ESM_BYTES} B"
        )
