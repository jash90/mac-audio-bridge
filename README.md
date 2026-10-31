# Mac Audio Bridge

A macOS menu bar app that captures system audio and streams it over Wi-Fi to an iOS app,
which plays it to Bluetooth headphones paired with the iPhone.

## Generate and build

```bash
xcodegen generate
xcodebuild -project MacAudioBridge.xcodeproj -scheme Sender -destination 'platform=macOS' build
xcodebuild -project MacAudioBridge.xcodeproj -scheme Receiver -destination 'generic/platform=iOS' build
cd Packages/BridgeCore && swift test
```
