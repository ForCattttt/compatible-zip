#!/usr/bin/env python3
"""Package an already built universal app with executable permissions preserved."""
from pathlib import Path
import hashlib
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
DIST.mkdir(exist_ok=True)
archive = DIST / "CompatibleZip-1.1.1-macOS-universal.zip"
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
    for name in ("兼容压缩.app", "兼容压缩（发微信）.workflow"):
        folder = ROOT / "build" / name
        if not folder.is_dir():
            raise SystemExit("Run bash scripts/build.sh first")
        for path in sorted(folder.rglob("*")):
            if path.is_file() and path.name != ".DS_Store":
                z.write(path, path.relative_to(folder.parent).as_posix())
    z.write(ROOT / "使用说明.txt", "使用说明.txt")
    z.write(ROOT / "LICENSE", "LICENSE")
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    executable = z.getinfo("兼容压缩.app/Contents/MacOS/CompatZip")
    assert (executable.external_attr >> 16) & stat.S_IXUSR
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(DIST / "SHA256SUMS.txt").write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
print(archive)
print(digest)
