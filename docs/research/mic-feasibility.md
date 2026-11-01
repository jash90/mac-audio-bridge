# Feasibility: iPhone microphone → Mac virtual microphone (Meet / Teams)

Research only, 2026-11-01. macOS 27.0 SDK (`MacOSX27.0.sdk`), iOS 27.1 SDK (`iPhoneOS27.1.sdk`), Xcode 27,
libASPL as vendored in `ThirdParty/libASPL`. No repo code changed. The probes ran in a scratch dir outside the repo.

## Verdict

**Feasible.** Nothing found blocks it. The Mac side is a standard pattern: a HAL plug-in that exposes an input device.
This Mac already runs three of them (`Background Music`, `Microsoft Teams Audio`, and BlackHole-style loopbacks are
common). The iPhone side is a documented `AVAudioSession` configuration. The only hard limit is Bluetooth physics:
**you cannot use the AirPods mic and keep music-quality A2DP output, except on AirPods that support iOS 26
`bluetoothHighQualityRecording`, and Apple says that mode adds input latency and "is not recommended for real-time
communication".** The recommended default is therefore **iPhone built-in mic in, AirPods (A2DP) out**.

| # | Question | Verdict |
|---|----------|---------|
| 1 | Mac virtual mic in our libASPL driver | Yes. libASPL supports input streams (`OnReadClientInput`). Feed it through a second, hidden device in the same driver, with no IPC and no sandbox exceptions. |
| 2a | iPhone built-in mic while playing to AirPods | Yes, with `.playAndRecord` + `.allowBluetoothA2DP` and no HFP. Output stays A2DP/AAC. |
| 2b | AirPods mic | Yes, but HFP lowers output quality, unless the AirPods support high-quality recording (iOS 26), which adds latency. |
| 3 | Reverse transport | Yes. Use the existing iPhone→Mac UDP flow (it already carries keepalives every 20 ms). Apple's Opus encoder works at 10 ms frames (probed). |
| 4 | UX | Phone toggle and meter: easy. Mute from the Mac menu: easy. Lock-screen mute: Live Activity button. Starting the mic from the background: **not allowed** (it must be armed in the foreground). |
| 5 | Effort | About 4–5 agent-days for a working MVP and 7–9 for the polished version. **One driver reinstall** is needed (`sudo`, done by the user). |

---

## 1. Mac side: virtual microphone device

### How the output path works today (relevant baseline)

`Driver/Driver.cpp` is an **output-only null sink**: `AddStreamWithControlsAsync(Direction::Output)` and the default
`IORequestHandler` drops whatever is written. **No PCM leaves the driver.** The Sender app captures audio with a
**process tap bound to the device UID** plus a private aggregate (`Apps/Sender-macOS/Capture/DeviceAudioTap.swift:98-213`).
There is no shared memory or IPC between the driver and the app today. `Driver/Info.plist` has
`AudioServerPlugIn_MachServices = []` and no `AudioServerPlugIn_Network`.

The mic direction cannot reuse the tap trick. A tap reads audio and cannot inject it. So the driver must get PCM from the
Sender app somehow.

### Options for getting PCM into the driver

The plug-in host is sandboxed. Per `AudioServerPlugIn.h`, it "may only read files in its bundle … may not write to any
filesystem locations other than the system's cache and temporary directories". Mach services must be listed in
`AudioServerPlugIn_MachServices`. Network access requires `AudioServerPlugIn_Network = true`.

| Option | How | Verdict |
|---|---|---|
| **A. Hidden feeder device (recommended)** | The driver publishes two devices. **"iPhone Mic (Mac Audio Bridge)"** is a visible device with one input stream. **"Mac Audio Bridge Mic Feed"** is an output-only device with `SetIsHidden(true)`. The Sender app opens the hidden device by UID (`kAudioHardwarePropertyTranslateUIDToDevice`) and plays the received mic PCM to it with an ordinary IOProc. The driver copies `OnWriteMixedOutput` of the feeder into an in-process ring buffer, and the mic device's `OnReadClientInput` reads from it. | **Best.** No IPC, no sandbox keys, no shared memory. This is exactly BlackHole's design: `kDevice2_IsHidden = true` by default, and the two devices share one global `gRingBuffer` indexed by `mSampleTime % kRing_Buffer_Frame_Size`. |
| B. XPC / Mach service | Add the Sender's (or a LaunchAgent's) Mach service to `AudioServerPlugIn_MachServices` and send shared-memory or XPC buffers. | Works (Background Music's `BGMXPCHelper` pattern), but it needs a launchd-registered helper, extra lifecycle code, and realtime-safe IPC. Overkill. |
| C. Driver receives UDP itself | `AudioServerPlugIn_Network = true`; the driver binds a localhost (or even iPhone-facing) socket. | Rejected. Jitter buffering and Opus decoding inside coreaudiod is a crash and maintenance risk, and the driver would need Bonjour and pairing logic. |
| D. Duplex loopback (plain BlackHole) | One visible device with input and output. The app plays to its output, and Meet reads its input. | Works, but the device then also shows in **output** lists and can be picked as the system output by mistake. Option A hides the feed side. |
| E. Add an input stream to the existing "iPhone (Mac Audio Bridge)" | One duplex "headset" device. | Possible, but it would still need a feed path (A or B). It also changes the device the process tap and aggregate are built on (channel layout, IsRunningSomewhere semantics), so there is regression risk to working code. Keep the output device untouched. |

**libASPL probe (vendored copy):**
- Input streams: `aspl::Direction::Input` is handled in `src/Device.cpp:539-546` (counts input streams and publishes them
  in input scope). `kAudioServerPlugInIOOperationReadInput` → `IORequestHandler::OnReadClientInput(client, stream,
  zeroTimestamp, timestamp, bytes, bytesCount)` is in `src/Device.cpp:1358,1495`, and the hook is in
  `include/aspl/IORequestHandler.hpp:60`. The default fills zeros.
- Feed side: `OnWriteMixedOutput(stream, zeroTimestamp, timestamp, bytes, bytesCount)` is in `IORequestHandler.hpp:191`.
- Hidden device: `Device::SetIsHidden()` / `GetIsHidden()` back `kAudioDevicePropertyIsHidden`
  (`include/aspl/Device.hpp:505-513`). The SDK confirms that hidden devices are "not included in … kAudioHardwarePropertyDevices
  nor can it be the default device" and are found by UID (`AudioHardwareBase.h:716-720`).
- Input volume and mute: `AddStreamWithControlsAsync(Direction::Input)` gives macOS Sound settings an input slider and a
  mute for free.

### Clocking and drift

- **Between the two driver devices**, libASPL anchors each device's clock at its own `StartIO`
  (`anchorHostTime_ = mach_absolute_time()`, `src/Device.cpp:1124`). The feeder and the mic would therefore have
  different sample-time origins. Fix this by overriding the virtual `GetZeroTimeStampImpl` (`src/Device.cpp:1261`) in a
  small `Device` subclass that uses **one driver-global anchor**. Sample time *T* then means the same instant on both
  devices, and the ring buffer can be indexed BlackHole-style by `T % ringFrames`. The HAL writes output for time *T*
  before *T* and reads input for *T* after *T*, so a zero offset is causal. Add a few ms of `Latency`/`SafetyOffset`
  margin anyway.
- **iPhone mic clock vs. Mac host clock**: these are two crystals, so expect about 10–50 ppm of drift
  (≈ 0.5–2.5 samples/s, tens of ms per hour). Absorb it in the **Sender app**: reuse `BridgeCore.JitterBuffer` (adaptive
  40–80 ms target) and the drift resampler planned for M5. An MVP can drop or duplicate one frame when the buffer leaves
  its band.
- Format: 48 kHz, **mono** Float32 input stream. WebRTC downmixes anyway. If some app mishandles mono, duplicate the
  channel to stereo.

### Auto start only when someone listens

Listen to `kAudioDevicePropertyDeviceIsRunningSomewhere` (`'gone'`, `AudioHardware.h:918`) **on the visible mic
device**. The Sender already does this for the output device (`Apps/Sender-macOS/Capture/BridgeDevice.swift:111`).
- 0→1 (Meet or Teams opened the mic): start the feeder IOProc and send `mic-start` to the iPhone.
- 1→0: send `mic-stop` after a grace period of about 2 s (apps reopen the device on device-picker changes).
- Note that Meet in Chrome keeps the mic open while muted in the Meet UI (it shows "you're muted, are you talking?").
  Expect the device to stay running for the whole call. Muting is a separate concern (§4).
- The Sender app needs **no microphone TCC permission**. It only plays to the hidden output. Chrome, Safari, and Teams need their
  usual mic permission, which they already have.

### How Meet and Teams find the device

- Chrome, Safari, and Teams enumerate CoreAudio devices that are **not hidden** and have input streams. Live probe on this Mac
  (`kAudioHardwarePropertyDevices`): `Background Music` (virt, 1 input stream), `Microsoft Teams Audio` (virt,
  1 input stream), and `iPhone (Mac Audio Bridge)` (virt, 0 input streams) are all listed. Virtual (`'virt'`) transport
  is not filtered.
- Hot-plug: the device exists as soon as coreaudiod loads the driver, so it is always listed and can be picked before a
  call. Chrome reacts to `kAudioHardwarePropertyDevices` changes with a `devicechange` event. Meet: Settings → Audio →
  Microphone. Teams: Settings → Devices → Microphone, or "System default" if we optionally set
  `kAudioHardwarePropertyDefaultInputDevice`. That should be a user opt-in, and the previous default must be restored.
- Name it distinctly from Apple's Continuity "iPhone Microphone", e.g. **"iPhone Mic (Mac Audio Bridge)"**.
- When the iPhone is not connected, deliver silence, not an error. Apps handle a silent mic well and a vanishing device badly.

## 2. iPhone: capture while playing Mac audio

Today `Apps/Receiver-iOS/Audio/AudioOutput.swift:87` uses `setCategory(.playback, mode: .default, options: [])`, 5 ms IO
buffer, `AVAudioSourceNode`, and `UIBackgroundModes = audio`. **`NSMicrophoneUsageDescription` is missing** from
`Apps/Receiver-iOS/Info.plist` and must be added.

### (a) Built-in mic + AirPods output (recommended default)

`setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])`. Do **not** add `.allowBluetoothHFP`, and do
not use `.voiceChat`/`.videoChat`, which imply HFP.
- SDK `AVAudioSessionTypes.h` (AllowBluetoothA2DP): with PlayAndRecord it allows "a paired Bluetooth A2DP device to
  appear as an available route for output, **while recording through the category-appropriate input**", which is the built-in mic.
- When both HFP and A2DP are allowed and one device supports both, "the HFP ports will be given a higher priority". That
  is why HFP must stay off for this mode.
- Output quality is unchanged (A2DP/AAC). The AirPods A2DP latency is unchanged.
- Without AirPods, PlayAndRecord defaults to the **receiver** (earpiece). Add `.defaultToSpeaker` only for a "speaker" mode.
- Switching category `.playback` → `.playAndRecord` at runtime triggers a route or configuration change
  (`AVAudioEngineConfigurationChange`). `PlaybackController` already rebuilds the engine on that event (M6), so expect a
  short glitch at toggle time.

### (b) AirPods microphone

- `.allowBluetoothHFP` (renamed from the deprecated `.allowBluetooth`, same value `0x4`): the route becomes **HFP for input
  and output**. The Mac audio you hear drops to wideband-speech quality (16 kHz mono class). That is fine for a call and bad for
  music.
- **iOS 26: `AVAudioSessionCategoryOptionBluetoothHighQualityRecording` (`1 << 19`, Swift
  `.bluetoothHighQualityRecording`)**. This is the real, verified name. From the SDK header: it "will enable
  **full-bandwidth audio in both input & output directions**, if the Bluetooth route supports it (e.g. certain AirPods
  models)". It is "currently compatible only with mode `.default`". Support shows as
  `route.inputs[…].bluetoothMicrophoneExtension.highQualityRecording.isSupported` / `.isEnabled`
  (`AVAudioSessionRoute.h:130-148`, `AVAudioSessionCapability`). Combined with `.allowBluetoothHFP`, HFP is the
  fallback. **Caveat in the header: "This option may increase input latency when enabled and is therefore not
  recommended for real-time communication usage."** Apple also suggests `setPrefersNoInterruptionsFromSystemAlerts`.
  In practice it is H2-chip AirPods only (AirPods Pro 2/3, AirPods 4). It needs a device test to measure the added latency.
- iOS 26.2 also adds `.farFieldInput` (requires HFP). It is not useful here.

**Trade-off in one line:** the iPhone mic keeps the AirPods at full A2DP quality. The AirPods mic forces HFP (speech-grade
audio both ways) unless your AirPods support iOS 26 high-quality recording, which keeps full bandwidth but adds input latency.

### Echo cancellation

- `AVAudioInputNode.setVoiceProcessingEnabled(true)` (`AVAudioIONode.h:141-164`) enables VPIO on **both** IO nodes. The engine
  must be stopped to toggle it, and the input-node output format must equal the output-node input format. Because our
  playback runs in the **same engine**, VPIO has the correct far-end reference and would cancel the Mac audio picked up by
  the mic.
- Downsides: VPIO changes and ducks playback (`voiceProcessingOtherAudioDuckingConfiguration`), forces a voice-tuned
  mono path, and is designed around HFP/receiver/speaker. Behavior with A2DP output must be tested.
- **Recommendation:** VPIO **off** with AirPods in the ears (acoustic echo is negligible, and Chrome's WebRTC AEC on the
  Mac handles the residual). Turn VPIO **on** automatically in "phone speaker" mode. Optionally use
  `voiceProcessingInputMuted` + `setMutedSpeechActivityEventListener` (iOS 17) for a "you're muted" hint.

### Background, lock screen, permissions

- **Starting** recording from the background is not allowed. Audio background mode alone is not enough: input must begin in
  the foreground ([forum 751866](https://developer.apple.com/forums/thread/751866),
  [forum 120038](https://developer.apple.com/forums/thread/120038?page=3)). Once input is running, it continues in the
  background and on the lock screen under `UIBackgroundModes = audio`.
- `AudioRecordingIntent` (AppIntents, iOS 18) exists (`AppIntents.swiftinterface:306`). Apple requires a Live Activity for
  the whole recording ("if you don't start a Live Activity, the audio recording stops"). Forum reports say it **cannot
  cold-start** a recording from the background ("Target is not foreground"). It can only manage a session already
  started in the foreground ([AudioRecordingIntent docs](https://developer.apple.com/documentation/appintents/audiorecordingintent),
  [forum 815725](https://developer.apple.com/forums/thread/815725)).
- **Design consequence:** the user **arms** the mic in the foreground (the "Mic" toggle). After that, the input node runs
  continuously, and the Mac's `mic-start`/`mic-stop` only gate *sending*. The orange mic indicator stays on while armed, which is
  honest and expected.
- Permission: `AVAudioApplication.requestRecordPermission` + `NSMicrophoneUsageDescription`.
- `.overrideMutedMicrophoneInterruption` is irrelevant on iPhone (it is for the iPad folio). Handle `interruption` (phone calls,
  Siri) as today.

## 3. Transport

- **Channel:** the iPhone already holds an accepted `NWConnection` per sender and sends **16-byte keepalives every 20 ms**
  back on it (`Apps/Receiver-iOS/Network/UDPReceiver.swift:8-45`). Send mic packets on the same flow. This works through
  NAT/Tailscale with no new port, discovery, or firewall change, because it is a reply to the Mac's flow. The `serviceClass`
  is already `interactiveVoice`.
- **Framing:** reuse `AudioPacket` (20-byte `MABA` header). Use the reserved byte 7 as a **stream id** (0 = Mac→iPhone
  playback, 1 = iPhone mic), or bump `version`. Keepalives stay distinguishable by size and magic. Add tiny control messages
  `mic-start`, `mic-stop`, `mic-mute` (Mac→iPhone) and `mic-state` (iPhone→Mac).
- **Codec:**
  - MVP: `pcm16` mono 48 kHz at 10 ms = 960 B payload, 100 pps ≈ **0.79 Mbit/s**. That is trivial on the LAN and acceptable over
    Tailscale on a good link. It needs zero codec work.
  - Then `opus` (enum value already reserved in `AudioPacket.swift`). **Probe: Apple's AudioToolbox Opus encoder via
    `AVAudioConverter` works on macOS 27 at 10 ms frames (480) and 20 ms frames (960). At `bitRate = 32000` it produces
    ≈40 B/packet (10 ms) ≈ 32 kbit/s.** It should be the same AudioToolbox codec on iOS, but encoding must be verified on device.
    Apple's converter exposes no in-band FEC/DTX knobs. For loss resilience, either piggyback the previous frame
    (redundancy, +40 B) or vendor libopus (`OPUS_SET_INBAND_FEC`, `OPUS_SET_PACKET_LOSS_PERC`). Settings: 32–48 kbit/s,
    10 ms, `VOIP` application.
- **Mac jitter buffer:** a second `BridgeCore.JitterBuffer` instance in the Sender (adaptive 40–80 ms; the M2.6 loss and outage
  logic applies). The feeder IOProc pulls from it at the driver clock, which is a natural pull model, plus the drift
  correction from §1.
- **Latency budget (mouth → Meet), estimate:**

  | Stage | ms |
  |---|---|
  | iPhone IO buffer (5 ms) + 10 ms frame | 15 |
  | encode/packetize | 1 |
  | Wi-Fi one-way (typ.; user's p99 spikes are 100–300 ms) | 5–20 |
  | Mac jitter buffer target | 40–80 |
  | feeder → ring → mic device HAL cycles | 10–20 |
  | **added vs. built-in Mac mic** | **≈ 70–135** |

  ITU-T G.114 suggests ≤150 ms one-way mouth-to-ear for good interactivity and ≤400 ms as acceptable. Meet/Teams network paths
  are typically 100–250 ms, so the mic path adds a noticeable but usable amount. Round-trip conversational delay grows by the
  mic path plus the existing playback path (bridge buffer + AirPods A2DP ~150–200 ms). Expect slightly more "talking over each
  other" than with the Mac's own mic and headphones.
- **Tailscale:** works, because the traffic rides the same flow. Use Opus there: DERP-relayed paths add 20–100 ms and lose more packets.

## 4. UX

- **iPhone:** "Mic" toggle (arms input in the foreground) with three states: *Off*, *Armed, Mac not listening*, *Live*. Add an
  input level meter (RMS from the tap, at UI rate), a mute button, and a source picker (iPhone mic / AirPods mic, with an HFP
  quality warning or an HQ badge when `highQualityRecording.isSupported`).
- **Lock screen:** a Live Activity while armed, with a Mute/Unmute button (`LiveActivityIntent`/`AudioRecordingIntent` that
  only gates sending). That works because the session is already running.
- **AirPods stem press:** iOS 17 `AVAudioApplication` exposes `inputMuted` and `inputMuteStateChangeNotification` for
  record sessions. `setInputMuteStateChangeHandler` is **macOS-only** (`AVAudioApplication.h:104`). Whether the AirPods
  press-to-mute gesture reaches a non-CallKit app using the *built-in* mic is unverified (it is likely tied to the AirPods mic
  route), so it needs a device test. Treat it as a bonus.
- **Mac menu:** a mic indicator (live / muted / iPhone not sending / no app listening), a level meter, and a **Mute** item with
  a global hotkey. Mac-side mute zeroes the feeder: it is instant and does not depend on the phone. Optionally add "Use as
  default input while connected".
- **Push-to-talk:** a hold-to-talk button in the app or Live Activity, plus a Mac hotkey (hold = unmute). Apple's `PushToTalk`
  framework is for server-based walkie-talkie apps and is overkill here.
- **Pitfall to document:** AirPods are paired with the Mac too. macOS automatic switching may grab them when the call
  starts on the Mac. Set "Connect to This Mac: When Last Connected" on the Mac (Bluetooth → AirPods options).

## 5. Milestones, effort, risks

| Milestone | Content | Effort (agent) | Driver reinstall |
|---|---|---|---|
| MIC-1 driver | Shared-clock `Device` subclass, visible mono input device + hidden feeder device, in-process SPSC ring, input volume/mute controls, unit test of ring indexing | 1–1.5 d | **Yes**: user runs `scripts/install-driver.sh` + `sudo killall coreaudiod` once (this kills running audio for a few seconds) |
| MIC-2 Mac sender | Receive stream 1 on the existing flow, jitter buffer, feeder IOProc, IsRunningSomewhere → `mic-start`/`stop`, menu indicator and mute | 1–1.5 d | no |
| MIC-3 iPhone | Usage string, permission, `.playAndRecord`+A2DP switch with engine rebuild, input tap → 48 kHz mono, PCM16 packets, toggle and meter | 1.5–2 d | no |
| MIC-4 polish | Opus (Apple encoder; libopus if FEC is needed), drift resampler (shared with M5), Live Activity mute, AirPods mic and HQ option, VPIO for speaker mode, soak test with a real Meet/Teams call | 2–3 d | no |

MVP (MIC-1…3, PCM16, built-in mic): **≈4–5 agent-days**. Everything: **≈7–9**.

**What could block it entirely:** nothing found for the recommended design. The hard "no" is AirPods mic plus music-quality
output on AirPods without HQ-recording support. That is a Bluetooth HFP limit with no workaround.

**Top risks**
1. **iOS session behavior:** the mic cannot start from the background (so it must be armed in the foreground, with a permanent
   orange dot). The category switch glitches playback. A wrong option (HFP) silently drops the AirPods to call quality. VPIO
   with A2DP output is untested.
2. **Network and clock quality on the mic path:** the user's Wi-Fi stalls (100–300 ms, 2.4 GHz + Bluetooth coexistence,
   and the phone is now *also* using Bluetooth for AirPods) cause audible mic dropouts for the remote party. Drift without a
   resampler causes periodic clicks. Recommend 5 GHz (already in the handoff).
3. **Driver change in coreaudiod:** realtime C++ in the plug-in (ring buffer, shared clock override). A bug crashes or
   hangs coreaudiod for every app, and each iteration needs a `sudo` reinstall by the user. Mitigate with a ring and clock
   unit test outside coreaudiod and an `os_log` counter for under/overruns.

Smaller: AirPods auto-switching to the Mac at call start; Meet/Teams auto-picking a different default mic; echo if
the phone speaker is used without VPIO.

## 6. Alternative worth a 5-minute user test first: Continuity Camera mic

macOS Ventura+ offers the iPhone microphone to apps as part of Continuity Camera (iPhone XR+, same Apple Account, Wi-Fi + BT;
the mic is selected in each app's settings, and users report it often does not appear in System Settings → Sound)
([Apple 102546](https://support.apple.com/102546), [community 254539054](https://discussions.apple.com/thread/254539054)).
It takes over the iPhone (the Continuity screen) and will very likely stop our Receiver's playback to the AirPods, so it does not
meet "Mac audio on AirPods + talk via phone". It costs nothing to try, though.

## 7. Probes run (scratch dir, not in the repo)

- `opus.swift`: `AVAudioConverter` LPCM 48 kHz mono → `kAudioFormatOpus`, 480 and 960 frames/packet, `bitRate = 32000`.
  Result: both OK, ≈40.3 B (10 ms) / ≈78.6 B (20 ms) per packet ≈ 32 kbit/s. Applicable bit rates start at 6 kbit/s.
- `devs.swift`: enumerated `kAudioHardwarePropertyDevices` with transport type and input-stream count (results in §1).
- SDK header greps cited inline (AVFAudio `AVAudioSessionTypes.h`, `AVAudioSessionRoute.h`, `AVAudioApplication.h`,
  `AVAudioIONode.h`; CoreAudio `AudioHardware.h`, `AudioHardwareBase.h`, `AudioServerPlugIn.h`; AppIntents swiftinterface).

## Sources

- SDK headers: `iPhoneOS27.1.sdk` AVFAudio (`AVAudioSessionTypes.h` lines ~500–640, `AVAudioSessionRoute.h` 130–148,
  `AVAudioIONode.h` 141–267, `AVAudioApplication.h` 40–104), `MacOSX27.0.sdk` CoreAudio (`AudioHardware.h` 918/1015,
  `AudioHardwareBase.h` 716–720, `AudioServerPlugIn.h` 30–57), AppIntents `AudioRecordingIntent`.
- libASPL (vendored): `include/aspl/IORequestHandler.hpp:60,191`, `include/aspl/Device.hpp:505-513`,
  `src/Device.cpp:539-546,1124,1261-1295,1358,1495`.
- BlackHole: [BlackHole.c](https://github.com/ExistentialAudio/BlackHole/blob/master/BlackHole/BlackHole.c). Two devices
  (`kObjectID_Device2`, `kDevice2_IsHidden = true`) share one `gRingBuffer`. Index `mSampleTime % kRing_Buffer_Frame_Size`.
  ReadInput/WriteMix are `memcpy` from/to the ring. Zero timestamp from `mach_absolute_time()` and `gDevice_HostTicksPerFrame`.
- Apple: [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent),
  [LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent),
  [Continuity Camera](https://support.apple.com/102546).
- Forums: [751866](https://developer.apple.com/forums/thread/751866) (no background recording start),
  [120038](https://developer.apple.com/forums/thread/120038?page=3), [815725](https://developer.apple.com/forums/thread/815725)
  (AudioRecordingIntent cannot cold-start).
- Repo: `Driver/Driver.cpp`, `Driver/Info.plist`, `Apps/Sender-macOS/Capture/{DeviceAudioTap,BridgeDevice}.swift`,
  `Apps/Receiver-iOS/Audio/AudioOutput.swift`, `Apps/Receiver-iOS/Network/UDPReceiver.swift`, `Apps/Receiver-iOS/Info.plist`,
  `Packages/BridgeCore/Sources/BridgeCore/{AudioPacket,JitterBuffer}.swift`.
