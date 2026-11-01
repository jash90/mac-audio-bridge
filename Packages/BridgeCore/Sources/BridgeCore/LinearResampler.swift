import Foundation

/// Converts a mono stream from the input hardware rate to 48 kHz by linear
/// interpolation — the phone's capture path, for the rare route whose input
/// is not at 48 kHz (the session asks for 48 kHz, and with it this is a
/// plain copy). Linear interpolation is enough for a voice stream that is
/// band-limited by the codec anyway.
///
/// Realtime: no allocation, no locks; state is one fractional position and
/// the previous input sample. Not thread-safe: one (render) thread.
public struct LinearResampler: Sendable {
    public private(set) var inputRate: Double
    public let outputRate: Double
    /// Input samples advanced per output sample.
    private var step: Double
    /// Position of the next output sample, relative to `previous` (0 =
    /// exactly `previous`, 1 = the first new input sample).
    private var position: Double = 1
    private var previous: Float = 0

    public init(inputRate: Double, outputRate: Double = MicFormat.sampleRate) {
        self.inputRate = inputRate
        self.outputRate = outputRate
        step = inputRate / outputRate
    }

    public var isPassthrough: Bool { inputRate == outputRate }

    /// Most output samples `inputCount` input samples can produce.
    public func maxOutput(forInput inputCount: Int) -> Int {
        Int((Double(inputCount) / step).rounded(.up)) + 2
    }

    public mutating func reset(inputRate newRate: Double? = nil) {
        if let newRate {
            inputRate = newRate
            step = newRate / outputRate
        }
        position = 1
        previous = 0
    }

    /// Converts `inputCount` samples; returns the output samples written
    /// (at most `outputCapacity`, which should be `maxOutput(forInput:)`).
    public mutating func process(
        _ input: UnsafePointer<Float>, inputCount: Int,
        into output: UnsafeMutablePointer<Float>, outputCapacity: Int
    ) -> Int {
        guard inputCount > 0 else { return 0 }
        if isPassthrough {
            let n = min(inputCount, outputCapacity)
            output.update(from: input, count: n)
            previous = input[inputCount - 1]
            return n
        }
        var written = 0
        // `position` counts from `previous` (index −1 of this block).
        while written < outputCapacity {
            let index = Int(position)  // 0 = previous, k = input[k − 1]
            guard index < inputCount else { break }
            let fraction = Float(position - Double(index))
            let a = index == 0 ? previous : input[index - 1]
            let b = input[index]
            output[written] = a + fraction * (b - a)
            written += 1
            position += step
        }
        position -= Double(inputCount)
        previous = input[inputCount - 1]
        return written
    }
}
