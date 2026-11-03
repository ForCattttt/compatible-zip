#!/usr/bin/env python3
"""Prepare portable app and Finder service resources. Build-time only."""
from pathlib import Path
import plistlib
import shutil
import struct

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
APP = BUILD / "兼容压缩.app"
# ICNS supports PNG payloads; package the generated icon sizes directly.
icon_entries = [
    (b"icp4", "icon_16x16.png"), (b"icp5", "icon_32x32.png"),
    (b"icp6", "icon_32x32@2x.png"), (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"), (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"), (b"ic11", "icon_16x16@2x.png"),
    (b"ic12", "icon_32x32@2x.png"), (b"ic13", "icon_128x128@2x.png"),
    (b"ic14", "icon_256x256@2x.png"),
]
chunks = []
for code, name in icon_entries:
    png = (BUILD / "AppIcon.iconset" / name).read_bytes()
    chunks.append(struct.pack(">4sI", code, len(png) + 8) + png)
payload = b"".join(chunks)
(APP / "Contents/Resources/AppIcon.icns").write_bytes(
    struct.pack(">4sI", b"icns", len(payload) + 8) + payload
)
info = {
    "CFBundleName": "兼容压缩",
    "CFBundleDisplayName": "兼容压缩",
    "CFBundleIdentifier": "io.github.ForCattttt.compatiblezip",
    "CFBundleExecutable": "CompatZip",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.1.1",
    "CFBundleVersion": "3",
    "LSMinimumSystemVersion": "13.0",
    "NSHighResolutionCapable": True,
    "CFBundleIconFile": "AppIcon",
    "NSPrincipalClass": "NSApplication",
    "CFBundleDocumentTypes": [{
        "CFBundleTypeName": "文件或文件夹",
        "CFBundleTypeRole": "Viewer",
        "LSHandlerRank": "Alternate",
        "LSItemContentTypes": ["public.item"],
    }],
}
(APP / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
service = BUILD / "兼容压缩（发微信）.workflow"
shutil.copytree(ROOT / "resources" / service.name, service, dirs_exist_ok=True)
service_info = service / "Contents/Info.plist"
data = plistlib.loads(service_info.read_bytes())
data["CFBundleIdentifier"] = "io.github.ForCattttt.compatiblezip.service"
service_info.write_bytes(plistlib.dumps(data))
