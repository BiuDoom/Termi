#!/bin/bash
# build-release.sh — Archive and export Termi with ad-hoc signing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Termi.xcarchive"
EXPORT_PATH="$BUILD_DIR"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"

mkdir -p "$BUILD_DIR"

echo "--- Archiving Termi ---"
xcodebuild archive \
    -project "$ROOT_DIR/Termi.xcodeproj" \
    -scheme Termi \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -quiet \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

echo "--- Exporting .app ---"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH" \
    -quiet

# Ad-hoc re-sign to satisfy Gatekeeper for local use
if [ -d "$BUILD_DIR/Termi.app" ]; then
    codesign --force --deep --sign - "$BUILD_DIR/Termi.app" 2>/dev/null || true
    echo "--- Ad-hoc signed: $BUILD_DIR/Termi.app ---"
fi

echo "--- Build complete ---"
