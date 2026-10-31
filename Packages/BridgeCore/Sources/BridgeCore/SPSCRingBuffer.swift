import Synchronization

/// Single-producer single-consumer ring buffer of Float samples.
/// Capacity fixed at init (rounded up to a power of two).
/// write/read never allocate, never lock. Producer and consumer may be on different threads.
///
/// Memory ordering: the producer publishes written samples with a releasing store to
/// `writeIndex`; the consumer loads it with acquire ordering before reading. The consumer
/// publishes reclaimed slots with a releasing store to `readIndex`; the producer loads it
/// with acquire ordering before overwriting. Both indices are monotonic 64-bit counters —
/// at 96,000 samples/s they would not overflow for millions of years.
///
/// Diagnostics: lock-free monotonic counters track write() calls, samples stored and
/// samples dropped to overflow (relaxed ordering — they are readouts, not synchronization).
/// `capturedSampleCount = storedSampleCount + droppedSampleCount` is everything the
/// producer handed to `write`, i.e. everything the capture side produced.
public final class SPSCRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacityValue: Int
    private let indexMask: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let writeCalls = Atomic<Int>(0)
    private let storedSamples = Atomic<Int>(0)
    private let droppedSamples = Atomic<Int>(0)

    /// Creates a ring buffer that holds `capacity` samples (rounded up to a power of two).
    public init(capacity: Int) {
        precondition(capacity > 0, "SPSCRingBuffer capacity must be positive")
        var roundedCapacity = 1
        while roundedCapacity < capacity {
            roundedCapacity <<= 1
        }
        self.capacityValue = roundedCapacity
        self.indexMask = roundedCapacity - 1
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: roundedCapacity)
        self.storage.initialize(repeating: 0, count: roundedCapacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Number of samples the buffer holds (power of two).
    public var capacity: Int { capacityValue }

    /// Cumulative producer `write()` calls (≈ capture IOProc callbacks).
    public var writeCallCount: Int {
        writeCalls.load(ordering: .relaxed)
    }

    /// Cumulative samples successfully stored.
    public var storedSampleCount: Int {
        storedSamples.load(ordering: .relaxed)
    }

    /// Cumulative samples dropped because the ring was full when written.
    public var droppedSampleCount: Int {
        droppedSamples.load(ordering: .relaxed)
    }

    /// Samples currently available to read (consumer's view).
    public var availableToRead: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed)
    }

    /// Samples currently available to write (producer's view).
    public var availableToWrite: Int {
        capacityValue - (writeIndex.load(ordering: .relaxed) - readIndex.load(ordering: .acquiring))
    }

    /// Producer only. Writes at most `count` samples from `src` and returns the number
    /// written. Excess samples are dropped — the producer never blocks and never
    /// overwrites samples the consumer has not read yet.
    @discardableResult
    public func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        let cursor = writeIndex.load(ordering: .relaxed)
        let reader = readIndex.load(ordering: .acquiring)
        let free = capacityValue - (cursor - reader)
        let toWrite = min(count, free)
        writeCalls.wrappingAdd(1, ordering: .relaxed)
        storedSamples.wrappingAdd(toWrite, ordering: .relaxed)
        if toWrite < count {
            droppedSamples.wrappingAdd(count - toWrite, ordering: .relaxed)
        }
        guard toWrite > 0 else { return 0 }
        let start = cursor & indexMask
        let head = min(toWrite, capacityValue - start)
        for i in 0..<head {
            storage[start + i] = src[i]
        }
        if toWrite > head {
            let tail = toWrite - head
            for i in 0..<tail {
                storage[i] = src[head + i]
            }
        }
        writeIndex.store(cursor + toWrite, ordering: .releasing)
        return toWrite
    }

    /// Consumer only. Reads at most `count` samples into `dst` and returns the number read.
    @discardableResult
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let cursor = readIndex.load(ordering: .relaxed)
        let writer = writeIndex.load(ordering: .acquiring)
        let toRead = min(count, writer - cursor)
        guard toRead > 0 else { return 0 }
        let start = cursor & indexMask
        let head = min(toRead, capacityValue - start)
        for i in 0..<head {
            dst[i] = storage[start + i]
        }
        if toRead > head {
            let tail = toRead - head
            for i in 0..<tail {
                dst[head + i] = storage[i]
            }
        }
        readIndex.store(cursor + toRead, ordering: .releasing)
        return toRead
    }

    /// Consumer only. Drops all buffered samples.
    public func reset() {
        let writer = writeIndex.load(ordering: .acquiring)
        readIndex.store(writer, ordering: .releasing)
    }
}
