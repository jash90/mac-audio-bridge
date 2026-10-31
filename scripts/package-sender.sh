#!/bin/bash
# Packages the Mac sender for another Mac: builds a signed Release
# "Mac Audio Bridge.app" and the HAL driver, and produces
# build/MacAudioBridge-Sender.zip with the app, the driver bundle,
# install-driver.sh and INSTALL.txt.
#
# Usage: ./scripts/package-sender.sh
#
# Never uses sudo; installing the driver on the target Mac does (see
# INSTALL.txt). Signing uses the project's team (Automatic signing).
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="build/dd-package"
STAGE="build/package/MacAudioBridge-Sender"
ZIP="build/MacAudioBridge-Sender.zip"

if command -v xcodegen >/dev/null; then
    xcodegen generate >/dev/null
fi

for scheme in Sender Driver; do
    echo "==> Building $scheme (Release)..."
    xcodebuild -project MacAudioBridge.xcodeproj -scheme "$scheme" \
        -configuration Release -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD" || true
done

PRODUCTS="$DERIVED/Build/Products/Release"
APP="$PRODUCTS/Mac Audio Bridge.app"
DRIVER="$PRODUCTS/MacAudioBridge.driver"
for bundle in "$APP" "$DRIVER"; do
    if [ ! -d "$bundle" ]; then
        echo "Missing $bundle — build failed" >&2
        exit 1
    fi
    codesign --verify --deep --strict "$bundle"
done

echo "==> Staging $STAGE..."
rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Mac Audio Bridge.app"
ditto "$DRIVER" "$STAGE/MacAudioBridge.driver"
cp scripts/install-driver.sh "$STAGE/install-driver.sh"
chmod +x "$STAGE/install-driver.sh"

cat > "$STAGE/INSTALL.txt" <<'EOF'
Mac Audio Bridge - sender for another Mac
=========================================

Run each line in Terminal (one short command per line).

1. Go to the unzipped folder:
   cd ~/Downloads/MacAudioBridge-Sender

2. Clear the download quarantine:
   xattr -dr com.apple.quarantine .

3. Install the audio driver (asks for your password):
   ./install-driver.sh

4. Install the app:
   mkdir -p ~/Applications
   cp -R "Mac Audio Bridge.app" ~/Applications/

5. Open it (it lives in the menu bar):
   open ~/Applications/"Mac Audio Bridge.app"

6. Answer the prompts with Allow:
   - Local Network: the iPhone finds and controls this Mac.
   - System Audio Recording: shown the first time audio streams.
   Missed one? System Settings > Privacy & Security.

7. On the iPhone, open Mac Audio Bridge and tap this Mac
   under Sources. Or pick "iPhone (Mac Audio Bridge)" as
   the output on this Mac: the iPhone switches to it.
EOF

echo "==> Zipping..."
ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$ZIP"
echo ""
echo "Created $ZIP ($(du -h "$ZIP" | cut -f1))"
