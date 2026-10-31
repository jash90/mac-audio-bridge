# Task M0: bootstrap the mac-audio-bridge repository

You are working in `/Users/bartlomiejzimny/Projects/mac-audio-bridge` (a fresh git repo on `main`, no commits yet).
The product: a macOS menu bar app captures system audio and streams it over Wi-Fi to an iOS app, which plays it
to Bluetooth headphones paired with the iPhone. This task ONLY creates the empty, building skeleton. No audio code.

## Hard rules
- Touch files ONLY inside this repository directory. Do not modify anything outside it (no ~/ config, no other repos).
- All code identifiers, file names, comments and log messages in English.
- Do not delete or rewrite `scripts/agents/glm.sh` or `.claude/tasks/`.
- Do not add third-party dependencies.

## Create exactly this layout
```
project.yml                          # xcodegen spec
.gitignore                           # extend the existing one (keep `.agent-logs/`)
README.md                            # short: what it is, how to generate + build (5–15 lines)
Packages/BridgeCore/Package.swift    # swift-tools-version:6.0, platforms .macOS("14.2"), .iOS(.v17); library "BridgeCore"
Packages/BridgeCore/Sources/BridgeCore/AudioFormat.swift
Packages/BridgeCore/Tests/BridgeCoreTests/AudioFormatTests.swift
Apps/Sender-macOS/SenderApp.swift    # SwiftUI @main with MenuBarExtra("Mac Audio Bridge", systemImage: "hifispeaker") showing a Text and a Quit button
Apps/Sender-macOS/Info.plist         # LSUIElement = YES, NSAudioCaptureUsageDescription = "Mac Audio Bridge streams your Mac's audio to your iPhone."
Apps/Sender-macOS/Sender.entitlements # app sandbox OFF for now (empty dict is fine), hardened runtime handled by build settings
Apps/Receiver-iOS/ReceiverApp.swift  # SwiftUI @main with a single ContentView Text("Mac Audio Bridge")
Apps/Receiver-iOS/Info.plist         # NSLocalNetworkUsageDescription, NSBonjourServices = ["_macaudiobridge._tcp"], UIBackgroundModes = ["audio"], UILaunchScreen = {}
```

`AudioFormat.swift` content (public API, exactly this contract):
```swift
public enum AudioFormat {
    public static let sampleRate: Double = 48_000
    public static let channelCount: Int = 2
    public static let frameDurationMs: Int = 10
    public static var samplesPerFrame: Int { Int(sampleRate) * frameDurationMs / 1000 } // per channel = 480
}
```
Test: `samplesPerFrame == 480`, using Swift Testing (`import Testing`, `@Test`).

## project.yml requirements
- project name `MacAudioBridge`, `options.bundleIdPrefix: dev.jash90`, deploymentTarget macOS 14.2 / iOS 17.0.
- `settings.base`: `DEVELOPMENT_TEAM: H2X8YGN869`, `CODE_SIGN_STYLE: Automatic`, `SWIFT_VERSION: 6.0`.
- local package `BridgeCore` at `Packages/BridgeCore`.
- target `Sender` (application, macOS, sources `Apps/Sender-macOS`, bundle id `dev.jash90.MacAudioBridge.Sender`,
  product name `Mac Audio Bridge`, uses Info.plist + entitlements above, `ENABLE_HARDENED_RUNTIME: YES`, depends on BridgeCore).
- target `Receiver` (application, iOS, sources `Apps/Receiver-iOS`, bundle id `dev.jash90.MacAudioBridge.Receiver`,
  product name `Mac Audio Bridge`, `TARGETED_DEVICE_FAMILY: 1`, depends on BridgeCore).
- schemes `Sender` and `Receiver`.
- The generated `MacAudioBridge.xcodeproj` must be in `.gitignore` (it is regenerated with `xcodegen generate`).
  Also ignore `.build/`, `DerivedData/`, `build/`, `.DS_Store`, `*.xcuserstate`, `xcuserdata/`.

## Gates (all must pass; fix until they do)
1. `cd Packages/BridgeCore && swift test`
2. `xcodegen generate`
3. `xcodebuild -project MacAudioBridge.xcodeproj -scheme Sender -destination 'platform=macOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO -quiet`
4. `xcodebuild -project MacAudioBridge.xcodeproj -scheme Receiver -destination 'generic/platform=iOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO -quiet`

## Finish
- `git add -A && git commit -m "chore: bootstrap project skeleton"` on `main` (this is the initial commit).
- Do NOT create the GitHub repo and do NOT push (the supervisor does that).
- Final message: list of created files, and the last 5 lines of output of each gate. Nothing else.
