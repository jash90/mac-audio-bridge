#!/bin/bash
# Unit tests for the driver's realtime helpers (Driver/MicRing.hpp,
# Driver/SharedClock.hpp). Runs on the host, outside coreaudiod; the tests
# are not part of the driver bundle.
#
# Usage: ./scripts/test-driver.sh
#
# Builds twice: optimized with -Werror, then under ThreadSanitizer (the
# concurrent producer/consumer stress test must be race-free).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/driver-tests"
mkdir -p "$OUT"
SRC="Driver/Tests/DriverTests.cpp"
FLAGS=(-std=c++17 -Wall -Wextra -Werror -pedantic)

echo "==> Driver tests (optimized)"
clang++ "${FLAGS[@]}" -O2 "$SRC" -o "$OUT/driver-tests"
"$OUT/driver-tests"

echo "==> Driver tests (ThreadSanitizer)"
clang++ "${FLAGS[@]}" -O1 -g -fsanitize=thread "$SRC" -o "$OUT/driver-tests-tsan"
TSAN_OPTIONS="halt_on_error=1" "$OUT/driver-tests-tsan"
