"""Verify the Windows export layout and collisions on either build host."""
from pathlib import Path
import shutil
import subprocess

import pytest


def test_export_normalizes_only_verified_nested_segments(tmp_path):
    node = shutil.which("node")
    if not node:
        pytest.skip("Node is required for source builds.")
    module = Path(__file__).resolve().parents[1] / "web/export-segments.mjs"
    run = [node, "--input-type=module", "-e",
           "const {normalizeExportSegments} = await import(process.argv[1]); "
           "console.log(normalizeExportSegments('out', 'compiled'));", module.as_uri()]
    out = tmp_path / "out/interviews/review"
    out.mkdir(parents=True)
    (out / "__next._tree.txt").write_text("tree")
    source = tmp_path / "compiled/interviews/review.segments/interviews/review/__PAGE__.segment.rsc"
    source.parent.mkdir(parents=True)
    payload = b"0:fixture\r\n\xc3\xa9\n"
    source.write_bytes(payload)
    legacy = out / "__next.interviews/review/__PAGE__.txt"
    legacy.parent.mkdir(parents=True)
    legacy.write_bytes(payload)
    extra = legacy.with_name("operator.txt")
    extra.write_bytes(b"ordinary static file")
    target = out / "__next.interviews.review.__PAGE__.txt"

    target.write_bytes(b"occupied")
    conflict = subprocess.run(run, cwd=tmp_path, capture_output=True)
    assert conflict.returncode and b"Conflicting exported segment" in conflict.stderr
    assert target.read_bytes() == b"occupied" and legacy.read_bytes() == payload
    target.unlink()
    legacy.write_bytes(b"wrong segment")
    mismatch = subprocess.run(run, cwd=tmp_path, capture_output=True)
    assert mismatch.returncode and b"Unverified exported segment" in mismatch.stderr
    assert not target.exists() and legacy.read_bytes() == b"wrong segment"

    legacy.write_bytes(payload)
    assert subprocess.check_output(run, cwd=tmp_path).strip() == b"1"
    assert target.read_bytes() == payload and not legacy.exists()
    assert not (out / "__next.interviews.review.operator.txt").exists()
    assert extra.read_bytes() == b"ordinary static file"
    assert subprocess.check_output(run, cwd=tmp_path).strip() == b"0"
