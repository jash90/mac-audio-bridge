#!/bin/bash
# Re-creates this directory's sources from ungive/mediaremote-adapter.
#
# Pinned: tag v0.7.7, commit e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6
# (BSD 3-Clause, see LICENSE). Tested on macOS 27.0.1.
# Copied unmodified: LICENSE, bin/mediaremote-adapter.pl, include/*.h,
# src/{adapter,private,utility,test}/*. The framework target in project.yml
# builds src/ except src/test/*.m (the optional test client; test.m only
# needs its header). Not copied: CMake files, scripts/, README badges.
set -euo pipefail

TAG=v0.7.7
COMMIT=e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6
URL="https://github.com/ungive/mediaremote-adapter.git"

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git -c advice.detachedHead=false clone -q --branch "$TAG" --depth 1 "$URL" "$work/src"
actual="$(git -C "$work/src" rev-parse HEAD)"
if [ "$actual" != "$COMMIT" ]; then
    echo "Tag $TAG is $actual, expected $COMMIT" >&2
    exit 1
fi

rm -rf "$here/bin" "$here/include" "$here/src"
mkdir -p "$here/bin" "$here/include" "$here/src"
cp "$work/src/LICENSE" "$here/LICENSE"
cp "$work/src/bin/mediaremote-adapter.pl" "$here/bin/"
cp "$work/src/include/"*.h "$here/include/"
for dir in adapter private utility test; do
    cp -R "$work/src/src/$dir" "$here/src/$dir"
done
echo "Vendored mediaremote-adapter $TAG ($COMMIT)"
