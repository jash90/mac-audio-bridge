# Task M1a: research Core Audio Process Taps (read-only research, no code changes in the repo)

Goal: produce a precise implementation brief for capturing ALL system audio output on macOS 14.2+ (we run macOS 27)
with Core Audio Process Taps, so another engineer can implement it without guessing.

## Hard rules
- Do NOT modify any file in the repository. The only file you write is the output file below.
- Do not clone into the repo. If you clone a reference repo, clone it into `/private/tmp/mab-research/` only.
- Write in English.

## Sources (use all that work)
1. Reference implementation: GitHub `insidegui/AudioCap` (read `ProcessTap.swift` and related files; via `gh api` /
   raw.githubusercontent.com or a shallow clone into /private/tmp/mab-research/).
2. Apple docs: `CATapDescription`, `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`,
   `kAudioAggregateDeviceTapListKey`, `AudioDeviceCreateIOProcIDWithBlock`. Use `npx ctx7@latest library "Core Audio" "process tap"`
   then `npx ctx7@latest docs <id> "..."` if available; otherwise web.
3. The local SDK headers: `xcrun --show-sdk-path` then grep `AudioHardwareTapping.h`, `CATapDescription.h`
   under `System/Library/Frameworks/CoreAudio.framework/Headers` — these are the ground truth for macOS 27 signatures.

## Output: `/Users/bartlomiejzimny/Projects/mac-audio-bridge/.agent-logs/research-process-tap.md`
Max ~200 lines. Sections:
1. **Exact call sequence** to tap all system output (global tap, excluding our own process), with the real Swift
   signatures from the SDK headers: create CATapDescription (which initializer for "all processes, stereo mixdown",
   how to exclude own PID / how to translate PID → AudioObjectID), create tap, read tap format
   (`kAudioTapPropertyFormat`), create a private aggregate device containing the tap (all dictionary keys needed),
   create IOProc, start, and teardown order.
2. **Permissions / TCC**: which Info.plist key (`NSAudioCaptureUsageDescription`), whether an entitlement is needed,
   how the prompt is triggered, how to detect denial, behaviour for unsigned/ad-hoc builds.
3. **Format handling**: what format the IOProc delivers (Float32 interleaved/non-interleaved, sample rate = output
   device rate which may be 44.1k or 48k) and how to convert to 48 kHz stereo Float32 interleaved
   (recommend AVAudioConverter usage pattern outside the realtime thread or a lock-free ring buffer design).
4. **Realtime-thread rules**: what must not happen in the IOProc block; recommended handoff (SPSC ring buffer).
5. **Pitfalls** found in AudioCap issues/commits and in the headers (e.g. muting behaviour `CATapMuteBehavior`,
   default output device changes, aggregate device must be private, tap UUID).
6. **Minimal Swift skeleton** (~60–100 lines) of a `SystemAudioTap` class with `start(onBuffer:)` / `stop()`
   that compiles against the macOS 27 SDK — verify it by writing it to `/private/tmp/mab-research/tap.swift` and running
   `xcrun swiftc -typecheck /private/tmp/mab-research/tap.swift` (fix until it typechecks; say so in the doc).

Final message: the path of the output file and one line saying whether the skeleton typechecked.
