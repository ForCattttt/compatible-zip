#!/bin/bash
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$TASK_ROOT/build"
APP="$BUILD_DIR/兼容压缩.app"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BUILD_DIR/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
    /usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library \
        -target "$ARCH-apple-macosx13.0" -sdk "$SDK_PATH" \
        -module-cache-path "$BUILD_DIR/module-cache" \
        -debug-prefix-map "$TASK_ROOT=." \
        "$TASK_ROOT/src/CompatZip.swift" "$TASK_ROOT/src/ZipMetadata.swift" \
        -o "$BUILD_DIR/CompatZip-$ARCH"
done
/usr/bin/lipo -create "$BUILD_DIR/CompatZip-arm64" "$BUILD_DIR/CompatZip-x86_64" \
    -output "$APP/Contents/MacOS/CompatZip"
/usr/bin/xcrun swiftc -O -module-cache-path "$BUILD_DIR/module-cache" \
    "$TASK_ROOT/tools/MakeIcon.swift" -o "$BUILD_DIR/MakeIcon"
"$BUILD_DIR/MakeIcon" "$BUILD_DIR/AppIcon.iconset"
python3 "$TASK_ROOT/scripts/prepare_bundle.py"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
