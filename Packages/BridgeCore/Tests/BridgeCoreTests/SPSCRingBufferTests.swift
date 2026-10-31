import Foundation
import Testing
@testable import BridgeCore

struct SPSCRingBufferTests {
    // MARK: - Helpers

    private func write(_ values: [Float], to ring: SPSCRingBuffer) -> Int {
        values.withUnsafeBufferPointer { buffer in
            ring.write(buffer.baseAddress!, count: values.count)
        }
    }

    private func read(_ count: Int, from ring: SPSCRingBuffer) -> [Float] {
        var output = [Float](repeating: .nan, count: count)
        let read = output.withUnsafeMutableBufferPointer { buffer in
            ring.read(into: buffer.baseAddress!, count: count)
        }
        return Array(output[0..<read])
    }

    // MARK: - Capacity

    @Test
    func capacityRoundsUpToPowerOfTwo() {
        #expect(SPSCRingBuffer(capacity: 1).capacity == 1)
        #expect(SPSCRingBuffer(capacity: 3).capacity == 4)
        #expect(SPSCRingBuffer(capacity: 1_000).capacity == 1_024)
        #expect(SPSCRingBuffer(capacity: 96_000).capacity == 131_072)
    }

    // MARK: - Basic write/read

    @Test
    func writeThenReadPreservesOrder() {
        let ring = SPSCRingBuffer(capacity: 8)
        let input: [Float] = (0..<8).map(Float.init)
        #expect(write(input, to: ring) == 8)
        #expect(read(8, from: ring) == input)
    }

    @Test
    func readFromEmptyBufferReturnsZero() {
        let ring = SPSCRingBuffer(capacity: 8)
        #expect(read(4, from: ring).isEmpty)
        #expect(ring.availableToRead == 0)
        #expect(ring.availableToWrite == 8)
    }

    @Test
    func readReturnsOnlyWhatIsAvailable() {
        let ring = SPSCRingBuffer(capacity: 8)
        _ = write([1, 2, 3], to: ring)
        #expect(read(8, from: ring) == [1, 2, 3])
    }

    // MARK: - Wrap-around

    @Test
    func wrapAroundPreservesOrder() {
        let ring = SPSCRingBuffer(capacity: 4)
        // Advance cursors so subsequent writes straddle the end of the storage.
        _ = write([1, 2, 3], to: ring)
        #expect(read(3, from: ring) == [1, 2, 3])
        // Slots 3..0 — the write itself wraps.
        #expect(write([4, 5, 6, 7], to: ring) == 4)
        #expect(read(4, from: ring) == [4, 5, 6, 7])
        // Cursor now at 7: slot 3, then wrapping to slots 0 and 1.
        #expect(write([8, 9], to: ring) == 2)
        #expect(read(2, from: ring) == [8, 9])
    }

    // MARK: - Full / partial writes

    @Test
    func fullBufferRejectsFurtherWrites() {
        let ring = SPSCRingBuffer(capacity: 4)
        #expect(write([1, 2, 3, 4], to: ring) == 4)
        #expect(ring.availableToWrite == 0)
        #expect(write([5], to: ring) == 0)
        #expect(read(4, from: ring) == [1, 2, 3, 4])
    }

    @Test
    func partialWriteReturnsSpaceAvailable() {
        let ring = SPSCRingBuffer(capacity: 4)
        #expect(write([1, 2, 3], to: ring) == 3)
        // Only one slot free: the excess samples are dropped.
        #expect(write([4, 5, 6], to: ring) == 1)
        #expect(ring.availableToWrite == 0)
        #expect(read(4, from: ring) == [1, 2, 3, 4])
    }

    // MARK: - Drop counters

    @Test
    func overflowedWritesCountDroppedSamples() {
        let ring = SPSCRingBuffer(capacity: 4)
        #expect(write([1, 2, 3], to: ring) == 3)
        // One slot free: two of the three offered samples are dropped.
        #expect(write([4, 5, 6], to: ring) == 1)

        #expect(ring.writeCallCount == 2)
        #expect(ring.storedSampleCount == 4)
        #expect(ring.droppedSampleCount == 2)
        // Captured = stored + dropped is everything the producer offered.
        #expect(ring.storedSampleCount + ring.droppedSampleCount == 6)
    }

    @Test("A write into a full ring counts the whole chunk as dropped")
    func fullWriteCountsWholeChunkDropped() {
        let ring = SPSCRingBuffer(capacity: 8)
        let input: [Float] = (0..<8).map(Float.init)
        #expect(write(input, to: ring) == 8)
        // Ring full: everything is dropped, stored stays put.
        #expect(write([9, 10, 11, 12], to: ring) == 0)

        #expect(ring.writeCallCount == 2)
        #expect(ring.storedSampleCount == 8)
        #expect(ring.droppedSampleCount == 4)
    }

    @Test("A consumer keeping pace keeps the drop counter at zero")
    func steadyStreamingDropsNothing() {
        let ring = SPSCRingBuffer(capacity: 8)
        for batch in 0..<10 {
            let input: [Float] = (0..<4).map { Float(batch * 4 + $0) }
            #expect(write(input, to: ring) == 4)
            #expect(read(4, from: ring) == input)
        }
        #expect(ring.writeCallCount == 10)
        #expect(ring.storedSampleCount == 40)
        #expect(ring.droppedSampleCount == 0)
    }

    // MARK: - Reset

    @Test
    func resetDropsBufferedSamples() {
        let ring = SPSCRingBuffer(capacity: 8)
        _ = write([1, 2, 3], to: ring)
        ring.reset()
        #expect(ring.availableToRead == 0)
        #expect(ring.availableToWrite == 8)
        #expect(read(3, from: ring).isEmpty)
        #expect(write([7, 8], to: ring) == 2)
        #expect(read(2, from: ring) == [7, 8])
    }

    // MARK: - Concurrency

    @Test
    func concurrentProducerConsumerPreservesOrder() {
        let ring = SPSCRingBuffer(capacity: 1_024)
        let totalSamples = 2_000_000
        let maxChunk = 2_000

        let group = DispatchGroup()
        DispatchQueue(label: "test.spsc-producer").async(group: group) {
            var nextSample = 0
            while nextSample < totalSamples {
                let chunk = min(Int.random(in: 1...maxChunk), totalSamples - nextSample)
                var block = [Float](repeating: 0, count: chunk)
                for i in 0..<chunk {
                    block[i] = Float(nextSample + i)
                }
                var written = 0
                while written < chunk {
                    written += block.withUnsafeBufferPointer { buffer in
                        ring.write(buffer.baseAddress! + written, count: chunk - written)
                    }
                }
                nextSample += chunk
            }
        }

        // Runs concurrently with the producer on its own queue and returns the first
        // mismatching sample index (nil when every sample arrived in order).
        let firstMismatch: Int? = DispatchQueue(label: "test.spsc-consumer").sync {
            var expected = 0
            var buffer = [Float](repeating: .nan, count: maxChunk)
            while expected < totalSamples {
                let count = min(Int.random(in: 1...maxChunk), totalSamples - expected)
                let read = buffer.withUnsafeMutableBufferPointer {
                    ring.read(into: $0.baseAddress!, count: count)
                }
                guard read > 0 else { continue }
                for i in 0..<read {
                    if buffer[i] != Float(expected + i) {
                        return expected + i
                    }
                }
                expected += read
            }
            return nil
        }

        group.wait()
        #expect(firstMismatch == nil)
        #expect(ring.availableToRead == 0)
    }
}
