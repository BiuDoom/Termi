#!/bin/bash
# create-dmg.sh — Create a distributable DMG from the built .app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/Termi.app"

# Extract version from Xcode project
VERSION=$(grep MARKETING_VERSION "$ROOT_DIR/Termi.xcodeproj/project.pbxproj" \
    | head -1 | sed 's/.*= *\(.*\);/\1/' | tr -d ' ')
DMG_NAME="Termi-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
STAGING_DIR="$BUILD_DIR/dmg-staging"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH not found. Run 'make build' first."
    exit 1
fi

echo "--- Creating DMG: $DMG_NAME ---"

# Clean previous artifacts
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"

# Copy app and create Applications symlink
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Create read-write DMG from staging directory
hdiutil create \
    -srcfolder "$STAGING_DIR" \
    -volname "Termi" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$BUILD_DIR/Termi-rw.dmg"

# Convert to compressed read-only DMG
hdiutil convert \
    "$BUILD_DIR/Termi-rw.dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH"

# Cleanup
rm -rf "$STAGING_DIR" "$BUILD_DIR/Termi-rw.dmg"

echo "--- DMG created: $DMG_PATH ---"
echo "    Size: $(du -h "$DMG_PATH" | cut -f1)"
