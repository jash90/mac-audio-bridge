# Mac Audio Bridge

A macOS menu bar app that captures system audio and streams it over Wi-Fi to an iOS app,
which plays it to Bluetooth headphones paired with the iPhone.

The Mac side is driven by a virtual output device: the HAL driver (`Driver/`) publishes
"iPhone (Mac Audio Bridge)" as a null output sink, the sender streams whatever plays to
it, and the Mac's volume keys control the iPhone loudness. See
[docs/virtual-device.md](docs/virtual-device.md).

## Generate and build

```bash
xcodegen generate
xcodebuild -project MacAudioBridge.xcodeproj -scheme Sender -destination 'platform=macOS' build
xcodebuild -project MacAudioBridge.xcodeproj -scheme Receiver -destination 'generic/platform=iOS' build
cd Packages/BridgeCore && swift test
```

Install the driver (sudo; builds the Driver scheme if needed):

```bash
./scripts/install-driver.sh
```
