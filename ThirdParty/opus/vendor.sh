#!/bin/bash
# Re-creates Sources/COpus from the official libopus release tarball.
#
# Pinned: libopus 1.5.2, sha256 below (https://downloads.xiph.org/releases/opus/).
# Copied unmodified: COPYING, AUTHORS, include/*.h, celt/*.{c,h}, silk/*.{c,h},
# silk/float/*.{c,h}, src/*.{c,h}. Pruned (not needed, see Package.swift):
#   - celt/arm, celt/x86, celt/mips, silk/arm, silk/x86, silk/fixed: SIMD and
#     fixed-point variants (we build the portable float path);
#   - silk/float/inner_product_FLP_avx2.c: x86 AVX2 only;
#   - dnn/: Deep PLC / DRED / OSCE, opt-in via ENABLE_* defines we never set;
#   - demos and tools with a main(): celt/opus_custom_demo.c, src/opus_demo.c,
#     src/opus_compare.c, src/repacketizer_demo.c;
#   - the multistream / projection (ambisonics) layers: src/opus_multistream*.c,
#     src/opus_projection*.c, src/mapping_matrix.{c,h} (we use plain stereo).
set -euo pipefail

VERSION=1.5.2
SHA256=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
URL="https://downloads.xiph.org/releases/opus/opus-${VERSION}.tar.gz"

here="$(cd "$(dirname "$0")" && pwd)"
dest="$here/Sources/COpus"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -sSfL -o "$work/opus.tar.gz" "$URL"
echo "$SHA256  $work/opus.tar.gz" | shasum -a 256 -c -
tar -xzf "$work/opus.tar.gz" -C "$work"
src="$work/opus-${VERSION}"

rm -rf "$dest"
mkdir -p "$dest/celt" "$dest/silk/float" "$dest/src" "$dest/include"
cp "$src/COPYING" "$src/AUTHORS" "$dest/"
cp "$src"/include/*.h "$dest/include/"
cp "$src"/celt/*.c "$src"/celt/*.h "$dest/celt/"
cp "$src"/silk/*.c "$src"/silk/*.h "$dest/silk/"
cp "$src"/silk/float/*.c "$src"/silk/float/*.h "$dest/silk/float/"
cp "$src"/src/*.c "$src"/src/*.h "$dest/src/"

rm -f "$dest/celt/opus_custom_demo.c" \
    "$dest/silk/float/inner_product_FLP_avx2.c" \
    "$dest/src/opus_demo.c" "$dest/src/opus_compare.c" "$dest/src/repacketizer_demo.c" \
    "$dest"/src/opus_multistream*.c "$dest"/src/opus_projection*.c \
    "$dest/src/mapping_matrix.c" "$dest/src/mapping_matrix.h"

echo "libopus ${VERSION} vendored into ${dest}"
