# Virtual output device — "iPhone (Mac Audio Bridge)"

The user-facing model: the iPhone shows up as a regular output device. Select it in
System Settings → Sound (or the menu-bar volume menu) and everything the Mac plays is
streamed to the iPhone; select another device and the stream stops. The Mac speakers
are not used while our device is the output — it is a null sink, like an AirPlay
receiver.

## How it works

Three pieces cooperate:

1. **HAL driver** (`Driver/Driver.cpp`, built on vendored libASPL in
   `ThirdParty/libASPL/`, MIT). An AudioServerPlugIn that publishes a virtual output
   device: name `iPhone (Mac Audio Bridge)`, UID `dev.jash90.MacAudioBridge.Device`,
   48 kHz stereo Float32, one output stream with volume + mute controls (so the
   keyboard volume keys and the menu-bar slider work), eligible as default output.
   The driver **discards** the samples its clients write (null sink) — it exists to
   be selected, to expose the volume control, and to provide a stable 48 kHz clock.
   Its host-clock-derived zero timestamps (`ZeroTimeStampPeriod`) keep IO running in
   real time, so the device reports running while an app plays to it.

2. **Device-bound process tap** (`Apps/Sender-macOS/Capture/DeviceAudioTap.swift`).
   A `CATapDescription` created with the excluding initializer
   (`__excludingProcesses:andDeviceUID:withStream:`, only our own process excluded,
   stream 0) captures the audio of **every process playing to our device** — and
   nothing else. The excluding form is the unambiguous "everything on this device
   except us" variant (header doc: "Mix all process audio streams destined for the
   selected device stream except the given processes"); excluding our own process
   also rules out any feedback from the aggregate's own IO. The tap feeds a private
   aggregate device whose **main (clock) sub-device is the virtual device**, with
   `tapautostart` so IO waits for the first audio. From there the M2.5/M2.6
   pipeline is unchanged: SPSC ring → 5 ms frames encoded in the menu's quality
   (Opus 192 / 128 kbit/s CBR, or PCM16) → UDP (≤ 1200 B datagrams; Opus datagrams
   carry the previous 4 frames, PCM16 frames are repeated 15 ms later; see
   `AudioRedundancy`). The iPhone decodes per frame, following each frame's codec.

3. **Auto start/stop + volume** (`Apps/Sender-macOS/SenderController.swift`). The
   sender listens for `kAudioHardwarePropertyDefaultOutputDevice` (system) and
   `kAudioDevicePropertyDeviceIsRunningSomewhere` / `VolumeScalar` / `Mute` (our
   device) and streams **only while our device is the default output AND a receiver
   is known** (a discovered Bonjour receiver or a manual address — see
   [discovery.md](discovery.md)); switching the output away stops the stream and releases the
   tap. The device's volume/mute is read from the driver's control and applied as a
   gain in the frame converter before packetizing (mute → zeros) — that is how the
   Mac volume keys set the iPhone loudness. The device's `AudioObjectID` is not
   stable across coreaudiod restarts, so it is re-resolved from the UID on every
   evaluation and the listeners re-bind when it changes.

The same Audio Capture TCC permission applies as with the old global tap
(`NSAudioCaptureUsageDescription` is already in the sender's Info.plist); no new
prompt appears after the first grant.

## Install / uninstall

You cannot write to `/Library` from the build session — run these yourself:

```bash
./scripts/install-driver.sh    # builds if needed, sudo cp into /Library/Audio/Plug-Ins/HAL/, sudo killall coreaudiod
./scripts/uninstall-driver.sh  # sudo rm of the bundle, sudo killall coreaudiod
```

`sudo launchctl kickstart -k system/com.apple.audio.coreaudiod` is blocked by SIP on
the dev machine, so the scripts reload coreaudiod with `sudo killall coreaudiod`
instead — the daemon restarts on its own within a second or two.

## Verifying it loaded

```bash
system_profiler SPAudioDataType | grep -A3 "Mac Audio Bridge"
```

should list `iPhone (Mac Audio Bridge)`. The sender's menu then stops showing the
"Driver not installed" line.

Runtime logs:

```bash
log stream --predicate 'process == "coreaudiod"' --level debug
log stream --predicate 'sender == "MacAudioBridge"'
```

## Troubleshooting

- **Device missing right after install** — wait a few seconds after `killall
  coreaudiod` and re-open System Settings → Sound (the list refreshes lazily).
- **Still missing** — check `system_profiler SPAudioDataType | grep -A3 "Mac Audio Bridge"`;
  if empty, check `log show --last 2m --predicate 'process == "coreaudiod"'` for load
  errors (unsigned/mismatched bundle, wrong factory UUID). Re-run the install script
  (it fully replaces the bundle — no stale leftovers).
- **Device listed, but the sender says "Driver not installed"** — the sender
  re-resolves the device by UID every second; if it stays missing, coreaudiod was
  restarted under a different device enumeration — restarting the sender app
  re-subscribes. (Should not normally happen.)
- **No audio on the iPhone while "Streaming to …" shows** — check that something is
  actually playing on the Mac (`DeviceIsRunningSomewhere` drives the tap), that the
  device volume is not 0/muted (the menu shows it), and that the Audio Capture
  permission was granted for the sender.
- **Uninstall leaves the device selected** — macOS falls back to another output
  automatically after the driver disappears and coreaudiod reloads.
