#!/bin/bash
# Installs the MacAudioBridge HAL driver — the virtual output device
# "iPhone (Mac Audio Bridge)" that the sender streams from.
#
# Usage: ./scripts/install-driver.sh
#
# Builds the Driver scheme (Debug) if the bundle is not built yet, replaces any
# previously installed driver, and reloads coreaudiod. The sudo prompts are for
# the copy into /Library/Audio/Plug-Ins/HAL/ and the coreaudiod reload.
# (`sudo launchctl kickstart -k system/com.apple.audio.coreaudiod` is blocked by
# SIP on this machine, so the reload uses `sudo killall coreaudiod`.)
set -euo pipefail
cd "$(dirname "$0")/.."

DRIVER="build/dd/Build/Products/Debug/MacAudioBridge.driver"

if [ ! -d "$DRIVER" ]; then
    echo "==> Driver bundle not found, building (Driver scheme, Debug)..."
    xcodebuild -project MacAudioBridge.xcodeproj -scheme Driver -configuration Debug -derivedDataPath build/dd -allowProvisioningUpdates build
fi

echo "==> Replacing /Library/Audio/Plug-Ins/HAL/MacAudioBridge.driver (sudo)..."
sudo rm -rf /Library/Audio/Plug-Ins/HAL/MacAudioBridge.driver
sudo cp -R "$DRIVER" /Library/Audio/Plug-Ins/HAL/

echo "==> Reloading coreaudiod (sudo killall; it restarts on its own)..."
sudo killall coreaudiod

echo ""
echo "Installed. Check that it loaded:"
echo "  system_profiler SPAudioDataType | grep -A3 \"Mac Audio Bridge\""
echo "Then pick \"iPhone (Mac Audio Bridge)\" as the output device in"
echo "System Settings -> Sound (or the menu-bar volume menu) — it can take a"
echo "few seconds to appear after the reload. The sender app shows"
echo "\"Streaming to <ip>\" once it is selected and an iPhone address is set."
