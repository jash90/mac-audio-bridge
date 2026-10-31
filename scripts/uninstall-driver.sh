#!/bin/bash
# Removes the MacAudioBridge HAL driver and reloads coreaudiod.
#
# Usage: ./scripts/uninstall-driver.sh
set -euo pipefail

echo "==> Removing /Library/Audio/Plug-Ins/HAL/MacAudioBridge.driver (sudo)..."
sudo rm -rf /Library/Audio/Plug-Ins/HAL/MacAudioBridge.driver

echo "==> Reloading coreaudiod (sudo killall; it restarts on its own)..."
sudo killall coreaudiod

echo ""
echo "Uninstalled. Verify it is gone:"
echo "  system_profiler SPAudioDataType | grep -A3 \"Mac Audio Bridge\""
echo "(no output means it is gone). If it was the selected output, macOS falls"
echo "back to another device automatically."
