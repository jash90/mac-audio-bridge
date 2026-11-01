// Loopback check for the INSTALLED virtual microphone (task M12a).
//
// Plays a 1 kHz tone into the hidden feeder device "Mac Audio Bridge Mic Feed"
// and records 3 s from "iPhone Mic (Mac Audio Bridge)", then prints the
// detected frequency, level, dropouts and latency.
//
// Usage: swift scripts/mic-loopback-check.swift
//
// Needs the new driver installed (scripts/install-driver.sh) and microphone
// permission for the terminal app (macOS asks on the first run; without it
// the mic records silence).

import AVFoundation
import CoreAudio
import Foundation

let feedUID = "dev.jash90.MacAudioBridge.MicFeed"
let micUID = "dev.jash90.MacAudioBridge.Mic"
let sampleRate = 48_000.0
let toneHz = 1_000.0
let toneAmplitude: Float = 0.5
let silenceLead = 0.5 // s of silence before the tone starts
let recordSeconds = 3.0
// The tone's onset is the first sample above this. Other apps may feed the
// mic at the same time (the Sender plays the phone's microphone into the feed
// device whenever an app opens "iPhone Mic"), so a near-zero threshold would
// fire on their background signal instead of the tone.
let onsetThreshold: Float = 0.1

func deviceID(forUID uid: String) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &device)
    }
    return status == noErr && device != kAudioObjectUnknown ? device : nil
}

func uint32Property(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func hostTicksToMs(_ ticks: Int64) -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e6
}

// Shared between the two IO procs and the main thread. Fixed-size storage;
// the procs only write into preallocated memory.
final class LoopbackState: @unchecked Sendable {
    let capacity = Int(sampleRate * (recordSeconds + 1))
    let samples: UnsafeMutablePointer<Float>
    var recorded = 0
    var firstInputSampleTime = -1.0
    var expectedNextInputTime = -1.0
    var inputTimeGaps = 0

    var feedStartSampleTime = -1.0
    var toneOnsetSampleTime = -1.0 // feeder sample time of the first tone frame
    var toneOnsetHostTime: UInt64 = 0 // when the feeder callback wrote it
    var micOnsetSampleTime = -1.0 // mic sample time of the first non-silent frame
    var micOnsetHostTime: UInt64 = 0

    init() {
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
    }
}

let state = LoopbackState()

guard let feed = deviceID(forUID: feedUID), let mic = deviceID(forUID: micUID) else {
    print("The new driver is not installed: devices \(micUID) / \(feedUID) not found.")
    print("Install it with ./scripts/install-driver.sh, then run this again.")
    exit(2)
}

let semaphore = DispatchSemaphore(value: 0)
var micAllowed = false
AVCaptureDevice.requestAccess(for: .audio) { granted in
    micAllowed = granted
    semaphore.signal()
}
semaphore.wait()
if !micAllowed {
    print("Microphone access denied for this terminal: the mic would record silence.")
    print("Allow it in System Settings → Privacy & Security → Microphone and run again.")
    exit(3)
}

let micLatency = uint32Property(mic, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput) ?? 0
let micSafety = uint32Property(mic, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput) ?? 0
let feedSafety = uint32Property(feed, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput) ?? 0
let micBuffer = uint32Property(mic, kAudioDevicePropertyBufferFrameSize) ?? 0
let feedBuffer = uint32Property(feed, kAudioDevicePropertyBufferFrameSize) ?? 0
print("mic id \(mic) (latency \(micLatency), safety \(micSafety), buffer \(micBuffer) frames)")
print("feed id \(feed) (safety \(feedSafety), buffer \(feedBuffer) frames)")

var feedProc: AudioDeviceIOProcID?
var micProc: AudioDeviceIOProcID?

// Feeder: silence for `silenceLead`, then the tone. Phase follows sample time.
var status = AudioDeviceCreateIOProcIDWithBlock(&feedProc, feed, nil) { _, _, _, outData, outTime in
    let buffers = UnsafeMutableAudioBufferListPointer(outData)
    let t0 = outTime.pointee.mSampleTime
    if state.feedStartSampleTime < 0 { state.feedStartSampleTime = t0 }
    let onset = state.feedStartSampleTime + silenceLead * sampleRate
    for buffer in buffers {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let channels = Int(buffer.mNumberChannels)
        let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        for frame in 0..<frames {
            let t = t0 + Double(frame)
            var value: Float = 0
            if t >= onset {
                if state.toneOnsetSampleTime < 0 {
                    state.toneOnsetSampleTime = t
                    state.toneOnsetHostTime = mach_absolute_time()
                }
                value = toneAmplitude * Float(sin(2 * Double.pi * toneHz * (t - onset) / sampleRate))
            }
            for channel in 0..<channels { data[frame * channels + channel] = value }
        }
    }
}
guard status == noErr else { print("feeder IOProc failed: \(status)"); exit(1) }

// Mic: record the first channel into the preallocated buffer.
status = AudioDeviceCreateIOProcIDWithBlock(&micProc, mic, nil) { _, inData, inTime, _, _ in
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    guard let buffer = buffers.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
    let channels = Int(buffer.mNumberChannels)
    let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    let t0 = inTime.pointee.mSampleTime
    if state.firstInputSampleTime < 0 { state.firstInputSampleTime = t0 }
    if state.expectedNextInputTime >= 0, t0 != state.expectedNextInputTime { state.inputTimeGaps += 1 }
    state.expectedNextInputTime = t0 + Double(frames)
    for frame in 0..<frames where state.recorded < state.capacity {
        let value = data[frame * channels]
        if state.micOnsetSampleTime < 0, abs(value) > onsetThreshold {
            state.micOnsetSampleTime = t0 + Double(frame)
            state.micOnsetHostTime = mach_absolute_time()
        }
        state.samples[state.recorded] = value
        state.recorded += 1
    }
}
guard status == noErr else { print("mic IOProc failed: \(status)"); exit(1) }

guard AudioDeviceStart(feed, feedProc) == noErr else { print("feeder start failed"); exit(1) }
guard AudioDeviceStart(mic, micProc) == noErr else { print("mic start failed"); exit(1) }
let running = uint32Property(mic, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0
print("mic IsRunningSomewhere while recording: \(running)")

Thread.sleep(forTimeInterval: recordSeconds + 0.1)

AudioDeviceStop(mic, micProc)
AudioDeviceStop(feed, feedProc)
AudioDeviceDestroyIOProcID(mic, micProc!)
AudioDeviceDestroyIOProcID(feed, feedProc!)
Thread.sleep(forTimeInterval: 0.3)
let runningAfter = uint32Property(mic, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0
print("mic IsRunningSomewhere after stop: \(runningAfter)")

// ---------------------------------------------------------------- analysis

let count = min(state.recorded, Int(sampleRate * recordSeconds))
let samples = UnsafeBufferPointer(start: state.samples, count: count)
print("recorded \(count) frames (\(String(format: "%.2f", Double(count) / sampleRate)) s)")

guard state.micOnsetSampleTime >= 0, state.toneOnsetSampleTime >= 0 else {
    print("RESULT: FAIL — the mic recorded only silence (tone never arrived).")
    exit(1)
}

let onsetIndex = Int(state.micOnsetSampleTime - state.firstInputSampleTime)
// Skip 10 ms after the onset; analyse the rest of the recording.
let start = min(count, onsetIndex + 480)
let tone = Array(samples[start..<count])
guard tone.count > 4_800 else {
    print("RESULT: FAIL — less than 0.1 s of tone recorded.")
    exit(1)
}

var crossings = 0
for i in 1..<tone.count where (tone[i - 1] < 0) != (tone[i] < 0) { crossings += 1 }
let frequency = Double(crossings) / 2 / (Double(tone.count) / sampleRate)

let rms = sqrt(tone.reduce(0) { $0 + Double($1) * Double($1) } / Double(tone.count))
let peak = tone.reduce(0) { max($0, abs($1)) }
let expectedRms = Double(toneAmplitude) / sqrt(2)

// Dropout: a run of >= 8 frames of (near) silence inside the tone. A 1 kHz
// sine at 48 kHz is never near zero for more than one frame.
var dropouts = 0
var silentRun = 0
for value in tone {
    if abs(value) < 1e-4 {
        silentRun += 1
        if silentRun == 8 { dropouts += 1 }
    } else {
        silentRun = 0
    }
}

// Anything before the tone (up to one cycle before the onset, which is the
// tone rising towards the threshold) is another feeder client (e.g. the Sender playing
// the phone's mic) — it is mixed into the tone too and skews the level.
let background = samples[0..<max(0, min(onsetIndex - 48, count))].reduce(Float(0)) { max($0, abs($1)) }
let sampleOffset = state.micOnsetSampleTime - state.toneOnsetSampleTime
let wallLatency = hostTicksToMs(Int64(state.micOnsetHostTime) - Int64(state.toneOnsetHostTime))

print(String(format: "frequency  %.1f Hz (expected %.0f)", frequency, toneHz))
print(String(format: "level      RMS %.1f dBFS, peak %.3f (expected RMS %.1f dBFS at full mic volume)",
             20 * log10(max(rms, 1e-9)), peak, 20 * log10(expectedRms)))
print("dropouts   \(dropouts) (silent runs >= 8 frames), input timestamp gaps \(state.inputTimeGaps)")
print(String(format: "latency    ring offset %.0f frames = %.1f ms (expected %u = mic latency), callback-to-callback %.1f ms",
             sampleOffset, sampleOffset / sampleRate * 1000, micLatency, wallLatency))

if background > 1e-4 {
    print(String(format: "background peak %.4f before the tone: another app feeds the mic (is the iPhone sending its mic?) — level and frequency include it", background))
}
let latencyOK = abs(sampleOffset - Double(micLatency)) <= 2
let ok = abs(frequency - toneHz) < 5 && dropouts == 0 && rms > 0.01 && latencyOK
print(ok ? "RESULT: PASS" : "RESULT: FAIL")
exit(ok ? 0 : 1)
