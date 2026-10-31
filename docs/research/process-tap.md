# Implementation brief: capturing ALL system audio output with Core Audio Process Taps (macOS 14.2+)

Researched 2026-10-31 on macOS 27.0.1 (build 26A434) against the macOS 27 SDK
(`MacOSX27.0.sdk`, Xcode 27). Sources: SDK headers (`CoreAudio/AudioHardwareTapping.h`,
`CoreAudio/CATapDescription.h`, `CoreAudio/AudioHardware.h`), `insidegui/AudioCap`
(`ProcessTap.swift`, `AudioProcessController.swift`, `CoreAudioUtils.swift`,
`AudioRecordingPermission.swift`), `makeusabrew/audiotee` (SPSC + AVAudioConverter pattern),
Apple docs + developer forums. Skeleton verified: `xcrun swiftc -typecheck
/private/tmp/mab-research/tap.swift` → exit 0 (see §6).

## 1. Exact call sequence (global tap, excluding our own process)

**Step 1 — translate own PID → process `AudioObjectID`.**

```swift
// AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
//                            mScope: kAudioObjectPropertyScopeGlobal,
//                            mElement: kAudioObjectPropertyElementMain)
var ownObject = AudioObjectID(kAudioObjectUnknown)
var qualifier = ProcessInfo.processInfo.processIdentifier   // pid_t
var size = UInt32(MemoryLayout<AudioObjectID>.size)
let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
    UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &ownObject)
```

Shortcut on macOS 26+ (we run 27): skip the translation and set
`description.bundleIDs = [Bundle.main.bundleIdentifier!]` — `bundleIDs` is
`API_AVAILABLE(macos(26.0))` in `CATapDescription.h`, verified in the local SDK.

**Step 2 — `CATapDescription` for "all processes, stereo mixdown, except us".**

```swift
// Raw Swift name on the macOS 27 SDK — the Objective-C initializers are
// NS_REFINED_FOR_SWIFT and NO Swift overlay refinement ships in the SDK,
// so the `__`-prefixed names are what compiles (typecheck-verified):
let description = CATapDescription(__stereoGlobalTapButExcludeProcesses: [ownObject as NSNumber])
description.name = "mac-audio-bridge-tap"
description.uuid = UUID()          // must be set BEFORE creating the aggregate (§5)
description.privateTap = true      // Swift name for setter setPrivate:
description.muteBehavior = .unmuted  // user keeps hearing playback
```

Other initializers (all `NS_REFINED_FOR_SWIFT` → `__` names, from `CATapDescription.h`):
`initStereoMixdownOfProcesses:`, `initMonoMixdownOfProcesses:`,
`initMonoGlobalTapButExcludeProcesses:`, `initWithProcesses:andDeviceUID:withStream:`,
`initExcludingProcesses:andDeviceUID:withStream:`. For "everything on the system" you want
the *global excluding* variant with one excluded PID (ours). Mono sources are duplicated
into both channels of the stereo mixdown.

**Step 3 — create the tap.**

```swift
// AudioHardwareTapping.h, API_AVAILABLE(macos(14.2)):
// AudioHardwareCreateProcessTap(CATapDescription* inDescription, AudioObjectID* outTapID) -> OSStatus
var tapID = AudioObjectID(kAudioObjectUnknown)
let status = AudioHardwareCreateProcessTap(description, &tapID)
```

First successful call triggers the TCC prompt (§2).

**Step 4 — read the tap format** (what the IOProc will deliver):

```swift
// kAudioTapPropertyFormat ('tfmt') on the tap object → AudioStreamBasicDescription
var asbd = AudioStreamBasicDescription()
var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioObjectGetPropertyData(tapID, &address, 0, nil, &fmtSize, &asbd) // address → kAudioTapPropertyFormat
```

**Step 5 — create a PRIVATE aggregate device containing the tap.** All dictionary keys
(`AudioHardware.h`, values are C-string keys):

```swift
let aggregate: [String: Any] = [
    kAudioAggregateDeviceNameKey:      "mac-audio-bridge-aggregate", // "name"
    kAudioAggregateDeviceUIDKey:       UUID().uuidString,            // "uid"
    kAudioAggregateDeviceIsPrivateKey: true,                         // "private" — REQUIRED, see §5
    kAudioAggregateDeviceIsStackedKey: false,                        // "stacked"
    kAudioAggregateDeviceTapAutoStartKey: true,                      // "tapautostart"
    kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],    // "subdevices" — empty: input-only
    kAudioAggregateDeviceTapListKey: [                              // "taps"
        [kAudioSubTapDriftCompensationKey: true,                    // "drift"
         kAudioSubTapUIDKey: description.uuid.uuidString]           // "uid" = CATapDescription UUID string
    ],
]
var aggregateID = AudioObjectID(kAudioObjectUnknown)
let status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
```

`tapautostart` requires the `private` key per the header doc: "the composition must also
include the private key". With `tapautostart`, `AudioDeviceStart` waits until a tapped
process starts producing audio instead of running dry forever. An empty sub-device list
(audiotee pattern) makes the aggregate input-only: no output passthrough to manage, and
processes keep playing normally because `muteBehavior == .unmuted`. (AudioCap instead pins
the current default output device as sub-device + `kAudioAggregateDeviceMainSubDeviceKey`;
that couples you to that device — §5.)

**Step 6 — IOProc, then start.**

```swift
// AudioDeviceCreateIOProcIDWithBlock(AudioDeviceIOProcID* outIOProcID, AudioObjectID inDevice,
//                                    dispatch_queue_t? inDispatchQueue, AudioDeviceIOBlock inIOBlock)
var ioProcID: AudioDeviceIOProcID?
let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
    now, inputData, inputTime, outputData, outputTime in   // params imported NON-optional
    // inputData: UnsafePointer<AudioBufferList> — valid only during the call
}
AudioDeviceStart(aggregateID, ioProcID)
```

**Teardown order (reverse of creation; aggregate references the tap by UID, so destroy it
first):** `AudioDeviceStop(aggregateID, ioProcID)` → `AudioDeviceDestroyIOProcID` →
`AudioHardwareDestroyAggregateDevice(aggregateID)` → `AudioHardwareDestroyProcessTap(tapID)`.

## 2. Permissions / TCC

- TCC service: **`kTCCServiceAudioCapture`** (System Settings → Privacy & Security).
- **Info.plist**: `NSAudioCaptureUsageDescription` (Audio Capture usage description).
  Since macOS 15.4 the TCC dialog is the **microphone** dialog, so also set
  `NSMicrophoneUsageDescription`; a Catalyst app without the keys **crashes**
  (`attempted to access privacy-sensitive data without a usage description`).
- **Entitlement**: none needed to create taps in development. For App Store / notarized
  distribution Apple introduced (macOS 26 era) a gated **audio-capture entitlement**
  (`com.apple.developer.audio.capture`, requested via a developer form; apps already
  approved for Audio Input / Drivers are auto-eligible). Verify this at submission time —
  it does not affect local dev.
- **Prompt trigger**: the first `AudioHardwareCreateProcessTap`. You can pre-flight with
  public API: `AVCaptureDevice.authorizationStatus(for: .audio)` /
  `AVCaptureDevice.requestAccess(for: .audio)`. AudioCap instead calls the private TCC SPI
  (`dlopen /System/Library/PrivateFrameworks/TCC.framework`, `TCCAccessPreflight` /
  `TCCAccessRequest` with `"kTCCServiceAudioCapture"`; preflight 0 = authorized, 1 =
  denied) — works, but it is private API; do not ship it to the App Store.
- **Denial behaviour**: tap creation can succeed but IO delivers silence; public
  `authorizationStatus == .denied` is the reliable check. Reset for testing:
  `tccutil reset AudioCapture <bundle-id>` (or `tccutil reset Microphone ...`).
- **CLI tools**: the prompt is attributed to the hosting terminal app (iTerm sometimes
  never surfaces it; grant ahead of time in System Settings). Unsigned/ad-hoc binaries:
  community reports (SoundPaste thread, 2025 blog posts) of Core Audio delivering
  **zero-filled buffers** to unsigned/unauthorized builds; sign dev builds with a real
  identity, and expect ad-hoc rebuilds to change identity (re-prompt / re-grant).

## 3. Format handling

- The IOProc delivers the **tap format** read in step 4: Linear PCM
  `kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked` (Float32), **2 channels**
  (stereo mixdown), **sample rate = the current default output device's rate** (44.1 kHz
  or 48 kHz, changes with the device). Interleavedness is **not guaranteed** — check
  `asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved` and branch (the skeleton handles
  both: 2 `AudioBuffer`s = non-interleaved, 1 = interleaved). In practice: non-interleaved
  lists deliver one `AudioBuffer` per channel (`mBytesPerFrame` = bytes/frame/channel);
  interleaved delivers one buffer with `mBytesPerFrame` = bytes/frame × 2.
- Target format: **48 kHz, 2ch, Float32 interleaved**
  (`AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2,
  interleaved: true)`).
- **Convert off the realtime thread** with `AVAudioConverter(from:to:)` + the pull pattern
  `convert(to:error:withInputFrom:)`: the input closure reads the SPSC ring and returns an
  `AVAudioPCMBuffer` in the *converter's input format*; on empty ring set
  `outStatus.pointee = .endOfStream` and return `nil` (converter reports `.inputRanDry`,
  just reschedule). **Do not call `converter.reset()` between chunks** — the resampler
  keeps internal state for continuity (audiotee learned this the hard way; dropping it
  causes discontinuity clicks). Size the output buffer with
  `ceil(frames * outRate/inRate)` + headroom. Allocate/clone buffers on the consumer
  queue, never in the IOProc.

## 4. Realtime-thread rules (IOProc block)

The block runs on a Core Audio IO thread (synchronously dispatched on the queue you pass,
or directly if you pass `NULL`). It must **not**: allocate (malloc, `[Any]`, `Data`,
`AVAudioPCMBuffer`, `String`), take locks (`NSLock`, `os_unfair_lock`, `DispatchQueue.sync`
to another queue), call into ObjC runtime, use `os_log` heavy formatting, or block on I/O
(`AVAudioFile.write`, network). Violations cause priority inversions and dropped/garbled
audio (the whole point of `AudioDeviceCreateIOProcIDWithBlock`'s queue parameter is
synchronous dispatch at IO priority). **Handoff**: producer (IOProc) does a single memcpy
into a preallocated SPSC ring buffer with monotonic head/tail cursors (relaxed atomics are
sufficient: single producer, single consumer, capacity ≫ max chunk); a consumer queue
drains ~every 50–100 ms, runs the `AVAudioConverter`, and hands 48 kHz interleaved buffers
to the rest of the app. On overrun drop the oldest samples (or reject new) — never block
the producer. AudioCap's recorder writes `AVAudioFile` directly inside the block — fine for
a demo, do not copy it into a bridge.

## 5. Pitfalls (headers + AudioCap/audiotee history)

- **`kAudioSubTapUIDKey` must be the `CATapDescription.uuid.uuidString`**, and the UUID
  must be assigned before `AudioHardwareCreateAggregateDevice` — the tap list is validated
  at aggregate creation. (AudioCap sets `tapDescription.uuid = UUID()` then passes
  `tapDescription.uuid.uuidString`.)
- **The aggregate must be private** (`kAudioAggregateDeviceIsPrivateKey: true`): the header
  says `tapautostart` requires it; a non-private aggregate publishes a new device
  system-wide and is not cleaned up across launches.
- **`kAudioAggregateDeviceTapAutoStartKey`**: without it, `AudioDeviceStart` on an idle
  system (nothing playing) can stall/deliver nothing until audio starts; with it, start
  waits for the first tapped audio.
- **`CATapMuteBehavior`** (default `.unmuted`): `.mutedWhenTapped` mutes the tapped
  processes while another client reads the tap — pick `.unmuted` for a bridge so the user
  keeps hearing audio. `.muted` silences them always.
- **Default output device changes**: a *global* mixdown tap follows processes regardless of
  output device, but the **tap sample rate tracks the output device** — re-read
  `kAudioTapPropertyFormat` (listen `kAudioHardwarePropertyDefaultOutputDevice` /
  `DefaultSystemOutputDevice` notifications) and rebuild the `AVAudioConverter` when it
  changes. If you use AudioCap's sub-device style (output device as `subdevices[0]`), the
  aggregate is pinned to that device UID — rebuild the whole tap on device change.
- **Per-process taps go stale**: processes exit/restart; global-excluding taps don't care.
  On macOS 26+, `processRestoreEnabled` re-adds processes by bundle ID when they restart
  (only relevant for include-list taps).
- **Teardown order matters** (§1): IOProc → aggregate → tap; and do it on a single owner
  (`AudioHardwareDestroyProcessTap` on an aggregate-referenced tap fails).
- **Don't set `deviceUID`/`stream`** unless deliberately tapping one device's stream;
  `nil`/absent = follow the system default (what a bridge wants).
- **Swift imports**: `AudioBufferList.mBuffers` is NOT an array in Swift (1-element C
  array) — index via `withUnsafePointer(to: list.pointee.mBuffers)` + `UnsafeBufferPointer`
  of `mNumberBuffers` elements; `AudioDeviceIOBlock` params are non-optional;
  `CATapDescription` initializers/`processes` are `__`-prefixed (§1).

## 6. Minimal Swift skeleton — TYPECHECKED ✅

File: `/private/tmp/mab-research/tap.swift` (250 lines: `StereoRingBuffer` + `SystemAudioTap`).
Verified: `xcrun swiftc -typecheck /private/tmp/mab-research/tap.swift` → **exit 0** on the
macOS 27 SDK (zero warnings/errors; `import Synchronization` atomics for the ring cursors).
API surface: `init(onBuffer:)` (called off-thread with 48 kHz stereo Float32 interleaved
`AVAudioPCMBuffer`s), `start() throws` (the 7 steps of §1), `stop()` (teardown §1).
Notable typecheck findings baked into the file: raw `__` init names, non-optional IOBlock
params, `mBuffers` tuple access, `AudioDeviceIOProcID` is `OpaquePointer?`.

## Pointers

- AudioCap: `/private/tmp/mab-research/AudioCap/AudioCap/ProcessTap/{ProcessTap,AudioProcessController,CoreAudioUtils,AudioRecordingPermission}.swift`
- audiotee: `/private/tmp/mab-research/AudioTee/Sources/AudioTeeCore/Core/{AudioTapManager,AudioRecorder,AudioFormatConverter}.swift`
- Apple docs: developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:),
  `.../catsapdescription` (CATapDescription), `.../nsaudiocaptureusagedescription`
