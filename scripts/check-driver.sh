#!/bin/bash
# Checks a BUILT driver bundle without installing it: loads it in-process
# (scripts/driver-harness.cpp) and
#   1. runs a feeder -> ring -> mic round trip through the plug-in interface;
#   2. with --baseline <old bundle>, diffs the property dump of the output
#      device "iPhone (Mac Audio Bridge)" against the old build — it must be
#      byte-for-byte the same.
#
# Usage: ./scripts/check-driver.sh [bundle] [--baseline <old bundle>]
# Default bundle: build/dd/Build/Products/Release/MacAudioBridge.driver
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE="build/dd/Build/Products/Release/MacAudioBridge.driver"
BASELINE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --baseline) BASELINE="$2"; shift 2 ;;
        *) BUNDLE="$1"; shift ;;
    esac
done

OUT="build/driver-tests"
mkdir -p "$OUT"
clang++ -std=c++17 -Wall -Wextra -Werror -O1 scripts/driver-harness.cpp \
    -framework CoreFoundation -framework CoreAudio -o "$OUT/driver-harness"

echo "==> IO round trip ($BUNDLE)"
"$OUT/driver-harness" io "$BUNDLE"

if [ -n "$BASELINE" ]; then
    UID_OUT="dev.jash90.MacAudioBridge.Device"
    echo "==> Output device property dump vs baseline ($BASELINE)"
    "$OUT/driver-harness" dump "$BASELINE" "$UID_OUT" > "$OUT/output-device.baseline.txt"
    "$OUT/driver-harness" dump "$BUNDLE" "$UID_OUT" > "$OUT/output-device.new.txt"
    if diff -u "$OUT/output-device.baseline.txt" "$OUT/output-device.new.txt"; then
        echo "identical: $(wc -l < "$OUT/output-device.new.txt" | tr -d ' ') property lines"
    else
        echo "OUTPUT DEVICE CHANGED"
        exit 1
    fi
fi
