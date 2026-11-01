#!/usr/bin/env bash
# Regenerates the AppIcon asset catalogs for both apps from scripts/icons/render-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

swift scripts/icons/render-icon.swift ios "$tmp/ios.png"
swift scripts/icons/render-icon.swift macos "$tmp/macos.png"

ios_set="Apps/Receiver-iOS/Assets.xcassets/AppIcon.appiconset"
mac_set="Apps/Sender-macOS/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ios_set" "$mac_set"
for catalog in Apps/Receiver-iOS/Assets.xcassets Apps/Sender-macOS/Assets.xcassets; do
  printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > "$catalog/Contents.json"
done

cp "$tmp/ios.png" "$ios_set/icon-1024.png"
cat > "$ios_set/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

images=""
for pt in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((pt * scale))
    name="icon-${pt}@${scale}x.png"
    sips -z "$px" "$px" "$tmp/macos.png" --out "$mac_set/$name" >/dev/null
    images+="    { \"filename\" : \"$name\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${pt}x${pt}\" },"$'\n'
  done
done
printf '{\n  "images" : [\n%s  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' "${images%,$'\n'}"$'\n' > "$mac_set/Contents.json"
echo "App icons generated."
