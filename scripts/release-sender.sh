#!/bin/bash
# Builds a signed, notarized and stapled Mac sender release:
# build/MacAudioBridge-Sender-<version>.dmg with "Mac Audio Bridge.app",
# an /Applications link, the HAL driver, "Install Driver.command" and
# INSTALL.txt (English, for the person installing it).
#
# Usage: ./scripts/release-sender.sh 0.7.0
#
# Signing: Developer ID Application, hardened runtime, secure timestamp,
# no get-task-allow. The app gets no extra entitlements: it is not
# sandboxed (network needs nothing), Core Audio process taps are gated by
# the System Audio Recording permission (NSAudioCaptureUsageDescription),
# not by com.apple.security.device.audio-input, and the app never opens a
# microphone: "Talk through iPhone" plays the iPhone's mic audio into the
# driver's "Mac Audio Bridge Mic Feed" output, which the driver loops back to
# its "iPhone Mic" input for call apps.
#
# Notarization uses the notarytool keychain profile in $NOTARY_PROFILE
# (default "vpn-time"). Override the identity with $SIGN_IDENTITY (SHA-1).
# Never uses sudo and never touches an installed copy of the app.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: $0 <version>, e.g. 0.5.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-C8A59E318C4B9B36C72A6FCA04D0BFBAB7D87F4A}"
NOTARY_PROFILE="${NOTARY_PROFILE:-vpn-time}"
TEAM_ID="H2X8YGN869"

DERIVED="build/dd-release"
WORK="build/release"
STAGE="$WORK/stage"
VOLNAME="Mac Audio Bridge $VERSION"
DMG="build/MacAudioBridge-Sender-$VERSION.dmg"
ENTITLEMENTS="Apps/Sender-macOS/Sender.entitlements"

log() { printf '\n==> %s\n' "$*"; }

# Fails if the built version does not match the requested one.
check_version() {
    local plist="$1/Contents/Info.plist" got
    got=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
    if [ "$got" != "$VERSION" ]; then
        echo "$1 is version $got, expected $VERSION (MARKETING_VERSION in project.yml)" >&2
        exit 1
    fi
}

# notarize <path-to-zip-or-dmg>: submits, waits, prints the log on failure.
notarize() {
    local file="$1" out id status
    out=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json)
    id=$(plutil -extract id raw - <<<"$out")
    status=$(plutil -extract status raw - <<<"$out")
    echo "    $(basename "$file"): id $id, status $status"
    echo "$(basename "$file") $id $status" >>"$WORK/notary-ids.txt"
    if [ "$status" != "Accepted" ]; then
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        exit 1
    fi
}

if command -v xcodegen >/dev/null; then
    xcodegen generate >/dev/null
fi

rm -rf "$WORK" "$DMG"
mkdir -p "$STAGE"
: >"$WORK/notary-ids.txt"
# Clean once here: a per-scheme "clean" would delete the other scheme's product.
rm -rf "$DERIVED/Build/Products"

for scheme in Sender Driver; do
    log "Building $scheme (Release, Developer ID)..."
    if ! xcodebuild -project MacAudioBridge.xcodeproj -scheme "$scheme" \
        -configuration Release -derivedDataPath "$DERIVED" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        DEVELOPMENT_TEAM="$TEAM_ID" PROVISIONING_PROFILE_SPECIFIER= \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES \
        OTHER_CODE_SIGN_FLAGS="--timestamp" \
        build >"$WORK/build-$scheme.log" 2>&1; then
        grep -E "error:" "$WORK/build-$scheme.log" | head -20 >&2
        echo "Build failed, see $WORK/build-$scheme.log" >&2
        exit 1
    fi
done

PRODUCTS="$DERIVED/Build/Products/Release"
APP="$STAGE/Mac Audio Bridge.app"
DRIVER="$STAGE/MacAudioBridge.driver"
ditto "$PRODUCTS/Mac Audio Bridge.app" "$APP"
ditto "$PRODUCTS/MacAudioBridge.driver" "$DRIVER"
check_version "$APP"
check_version "$DRIVER"

# Re-sign explicitly so the shipped signature never depends on Xcode
# defaults: hardened runtime, timestamp, exactly the entitlements file.
log "Signing app and driver..."
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DRIVER"
# Nested code first: the app's seal covers the embedded adapter framework.
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" "$APP"
for bundle in "$APP" "$DRIVER"; do
    codesign --verify --deep --strict "$bundle"
    if codesign -d --entitlements - --xml "$bundle" 2>/dev/null | grep -q get-task-allow; then
        echo "$bundle still has get-task-allow" >&2
        exit 1
    fi
done

log "Notarizing app and driver..."
for bundle in "$APP" "$DRIVER"; do
    zip="$WORK/$(basename "$bundle").zip"
    ditto -c -k --keepParent "$bundle" "$zip"
    notarize "$zip"
done

log "Stapling..."
xcrun stapler staple -q "$APP"
if xcrun stapler staple -q "$DRIVER" 2>/dev/null; then
    DRIVER_STAPLED=yes
else
    DRIVER_STAPLED="no (stapler does not support this bundle type; the online ticket is used)"
fi
echo "    driver stapled: $DRIVER_STAPLED"

log "Staging DMG contents..."
ln -s /Applications "$STAGE/Applications"

cat >"$STAGE/Install Driver.command" <<'EOF'
#!/bin/bash
# Installs the Mac Audio Bridge audio driver from this disk image.
set -euo pipefail
cd "$(dirname "$0")"
HAL="/Library/Audio/Plug-Ins/HAL"
echo "Installing the Mac Audio Bridge audio driver."
echo "Enter this Mac's administrator password (it is not shown as you type)."
echo "Sound on this Mac drops for a few seconds while the driver reloads."
echo ""
sudo rm -rf "$HAL/MacAudioBridge.driver"
sudo ditto MacAudioBridge.driver "$HAL/MacAudioBridge.driver"
sudo xattr -dr com.apple.quarantine "$HAL/MacAudioBridge.driver" 2>/dev/null || true
# coreaudiod restarts on its own and loads the new driver.
sudo killall coreaudiod
echo ""
echo "Done. In a few seconds System Settings > Sound shows the output"
echo "\"iPhone (Mac Audio Bridge)\" and the input \"iPhone Mic (Mac Audio Bridge)\"."
echo "You can close this window."
read -r -p "Press Enter to finish..." _ || true
EOF
chmod +x "$STAGE/Install Driver.command"
codesign --force --timestamp --sign "$SIGN_IDENTITY" \
    --identifier dev.jash90.MacAudioBridge.InstallDriver "$STAGE/Install Driver.command"

cat >"$STAGE/INSTALL.txt" <<EOF
Mac Audio Bridge $VERSION - installing on a Mac
===============================================

1. Open this disk image (done, if you are reading this).

2. Double-click "Install Driver.command".
   Terminal opens and asks for the administrator password.
   If macOS blocks the file: right-click it, choose Open and confirm.
   Updating from an older version? Install the driver again: this
   release adds the "iPhone Mic (Mac Audio Bridge)" input. Sound on
   the Mac drops for a few seconds while the driver reloads.

3. Drag "Mac Audio Bridge.app" onto the Applications folder.
   If an older version is there, choose Replace (quit the old app
   from the menu bar first).

4. Open the app from Applications (its icon appears in the menu bar).
   Answer Allow when macOS asks:
   - Local Network: the iPhone finds this Mac and controls it.
   - System Audio Recording: asked the first time audio is sent.
   Missed one? System Settings > Privacy & Security.

5. On the iPhone open Mac Audio Bridge and pick this Mac under Sources.

Talking in calls through the iPhone microphone:
   - On the iPhone turn on "Talk through iPhone".
   - In Meet, Teams or another call app choose the microphone
     "iPhone Mic (Mac Audio Bridge)".

Every Mac and the iPhone app must run the same version ($VERSION).
EOF

log "Creating $DMG..."
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -ov \
    -format UDZO -fs HFS+ "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

log "Notarizing DMG..."
notarize "$DMG"
xcrun stapler staple -q "$DMG"

log "Verifying..."
codesign --verify --deep --strict -vv "$APP" 2>&1 | tail -2
codesign --verify --deep --strict -vv "$DRIVER" 2>&1 | tail -2
codesign --verify --strict -vv "$DMG" 2>&1 | tail -2
spctl -a -vvv -t exec "$APP" 2>&1
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1
xcrun stapler validate "$APP" | tail -1
xcrun stapler validate "$DMG" | tail -1

echo ""
echo "Notarization: $(tr '\n' ';' <"$WORK/notary-ids.txt")"
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
