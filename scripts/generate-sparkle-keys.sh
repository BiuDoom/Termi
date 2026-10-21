#!/bin/bash
# generate-sparkle-keys.sh — Generate EdDSA key pair for Sparkle auto-updates
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Sparkle's generate_keys lives inside the framework bundle (via SPM build artifacts)
# Adjust this path if Sparkle is resolved to a different location.
SPARKLE_BIN=$(find "$ROOT_DIR/.build" "$HOME/Library/Developer/Xcode/DerivedData" \
    -name "generate_keys" -type f 2>/dev/null | head -1)

if [ -z "$SPARKLE_BIN" ]; then
    echo "Error: Sparkle generate_keys tool not found."
    echo ""
    echo "You can generate keys manually:"
    echo "  1. Find generate_keys in Sparkle.framework/Versions/B/Resources/"
    echo "  2. Run: ./generate_keys"
    echo "  3. Add the public key to Info.plist as SUPublicEDKey"
    echo ""
    echo "Or install via Homebrew:"
    echo "  brew install --cask sparkle"
    echo "  /usr/local/Caskroom/sparkle/*/bin/generate_keys"
    exit 1
fi

echo "--- Generating Sparkle EdDSA Keys ---"
echo ""
echo "This will create/update the key pair in your Keychain."
echo "The PUBLIC key below should be added to Info.plist as SUPublicEDKey."
echo ""

"$SPARKLE_BIN"

echo ""
echo "--- Done ---"
echo "Add the public key to your Info.plist:"
echo "  <key>SUPublicEDKey</key>"
echo "  <string>YOUR_PUBLIC_KEY_HERE</string>"
