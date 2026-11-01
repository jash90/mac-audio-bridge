// Live check of "Talk through iPhone" (task M12b): records from
// "iPhone Mic (Mac Audio Bridge)" for a few seconds, like a call would, and
// prints the level per second. Opening the device is what makes the Sender
// ask the phone for its mic (micStart), so with the phone's mic armed the
// level shows room noise / your voice; without it, silence.
//
// Usage: swift scripts/mic-record-check.swift [seconds]   (default 5)
//
// Needs the driver with the mic devices installed and microphone permission
// for the terminal app (macOS asks on the first run).

import CoreAudio
import Foundation

let micUID = "dev.jash90.MacAudioBridge.Mic"
let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 5

func deviceID(forUID uid: String) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
    }
    return status == noErr && device != kAudioObjectUnknown ? device : nil
}

guard let mic = deviceID(forUID: micUID) else {
    print("iPhone Mic (Mac Audio Bridge) not found — install the driver first (scripts/install-driver.sh)")
    exit(1)
}

final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private var sumSquares = 0.0
    private var peak: Float = 0
    private var count = 0

    func add(_ samples: UnsafePointer<Float>, _ n: Int) {
        var sum = 0.0
        var top: Float = 0
        for i in 0..<n {
            sum += Double(samples[i] * samples[i])
            top = max(top, abs(samples[i]))
        }
        lock.lock()
        sumSquares += sum
        peak = max(peak, top)
        count += n
        lock.unlock()
    }

    func take() -> (rmsDB: Double, peakDB: Double, samples: Int) {
        lock.lock()
        defer {
            sumSquares = 0
            peak = 0
            count = 0
            lock.unlock()
        }
        let rms = count > 0 ? (sumSquares / Double(count)).squareRoot() : 0
        func db(_ value: Double) -> Double { value > 0 ? 20 * log10(value) : -.infinity }
        return (db(rms), db(Double(peak)), count)
    }
}

let meter = Meter()
let ioQueue = DispatchQueue(label: "mic-record-check")
var procID: AudioDeviceIOProcID?
let ioBlock: AudioDeviceIOBlock = { _, inputData, _, _, _ in
    for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData)) {
        guard let data = buffer.mData else { continue }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        meter.add(data.assumingMemoryBound(to: Float.self), frames * channels)
        break
    }
}
guard AudioDeviceCreateIOProcIDWithBlock(&procID, mic, ioQueue, ioBlock) == noErr, let procID,
    AudioDeviceStart(mic, procID) == noErr
else {
    print("Could not start recording from iPhone Mic")
    exit(1)
}
print("Recording \(Int(seconds)) s from iPhone Mic…")
var loudest = -Double.infinity
for second in 1...max(Int(seconds), 1) {
    Thread.sleep(forTimeInterval: 1)
    let (rms, peak, samples) = meter.take()
    loudest = max(loudest, rms)
    print(String(format: "  %d s: RMS %6.1f dBFS, peak %6.1f dBFS (%d samples)", second, rms, peak, samples))
}
AudioDeviceStop(mic, procID)
AudioDeviceDestroyIOProcID(mic, procID)
print(loudest > -80 ? "OK: the iPhone mic delivers audio" : "Silence: is “Talk through iPhone” on and the Mac streaming to it?")
