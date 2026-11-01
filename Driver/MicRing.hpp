// Mac Audio Bridge — lock-free ring between the hidden feeder device and the
// virtual microphone (task M12a).
//
// The ring is indexed by device SAMPLE TIME, BlackHole style: frame t lives in
// slot t % Capacity. The feeder and the mic share one clock (SharedClock.hpp),
// so sample time t means the same instant on both devices and no read/write
// cursor has to be negotiated between them.
//
// Semantics:
// - One producer (the feeder's WriteMix IO thread), any number of readers
//   (one ReadInput per mic client, all on the mic's IO thread or threads).
// - A frame is valid only if it was written for exactly the time asked for.
//   Reading a time not written yet (underrun), or written so long ago that its
//   slot has been reused (overrun: the writer is more than Capacity frames
//   ahead), yields SILENCE — never stale audio from an older lap of the ring.
// - Writing past the previous end with a gap zero-fills the gap, so stale
//   frames from before a feeder pause can never be read back.
// - Overrun drops the oldest frames by construction (their slots are reused).
//
// Realtime safety: fixed-size storage, no allocation, no locks, no logging,
// no system calls. Only relaxed/acquire/release atomics; on arm64 and x86_64
// a relaxed std::atomic<float> load/store is a plain load/store.
//
// Concurrency: a seqlock-style protocol. Before touching any slot, the writer
// publishes `limit_` (the end of the range it is about to write), then a
// release fence, then the samples, then `end_` with release. A reader loads
// `end_` (acquire), copies the samples, issues an acquire fence and loads
// `limit_`. Frames at times >= end_ were not complete when the copy started;
// frames at times < limit_ - Capacity may have been overwritten during the
// copy. Both are replaced by silence. (Boehm, "Can seqlocks get along with
// programming language memory models?", 2012.)
//
// Not protected: a writer REWRITING times it already wrote (going back in
// time). The shared clock never makes the HAL do that; if it did, a reader
// could see a mix of the old and new version of those same frames.
//
// Pure C++17, no CoreAudio — unit-tested in Driver/Tests outside coreaudiod.

#pragma once

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace mab {

template <std::size_t CapacityFrames>
class SampleTimeRing
{
    static_assert(CapacityFrames > 0 && (CapacityFrames & (CapacityFrames - 1)) == 0,
        "capacity must be a power of two");
    static_assert(std::atomic<float>::is_always_lock_free, "atomic<float> must be lock-free");
    static_assert(std::atomic<std::int64_t>::is_always_lock_free, "atomic<int64_t> must be lock-free");

public:
    static constexpr std::int64_t Capacity = std::int64_t(CapacityFrames);

    SampleTimeRing()
    {
        for (auto& sample : samples_) {
            sample.store(0.0f, std::memory_order_relaxed);
        }
    }

    SampleTimeRing(const SampleTimeRing&) = delete;
    SampleTimeRing& operator=(const SampleTimeRing&) = delete;

    // Producer only. Writes `count` mono frames for sample times
    // [time, time + count).
    void Write(std::int64_t time, const float* frames, std::uint32_t count) noexcept
    {
        if (count == 0) {
            return;
        }

        // Only the newest Capacity frames of an oversized write can survive.
        if (std::int64_t(count) > Capacity) {
            const std::int64_t skip = std::int64_t(count) - Capacity;
            frames += skip;
            time += skip;
            count = std::uint32_t(Capacity);
        }

        const std::int64_t writeEnd = time + std::int64_t(count);
        const std::int64_t oldEnd = end_.load(std::memory_order_relaxed);
        const std::int64_t newEnd = std::max(oldEnd, writeEnd);

        // Gap after the previous write: zero the part of it that is still
        // inside the window [newEnd - Capacity, newEnd), so it reads as silence.
        const std::int64_t zeroFrom =
            time > oldEnd ? std::max(oldEnd, writeEnd - Capacity) : time;

        // Announce the range about to be overwritten before touching a slot.
        limit_.store(newEnd, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_release);

        for (std::int64_t t = zeroFrom; t < time; ++t) {
            Slot(t).store(0.0f, std::memory_order_relaxed);
        }
        for (std::uint32_t i = 0; i < count; ++i) {
            Slot(time + std::int64_t(i)).store(frames[i], std::memory_order_relaxed);
        }

        end_.store(newEnd, std::memory_order_release);
    }

    // Any reader. Fills `count` mono frames for sample times [time, time + count);
    // frames that are not valid (see the header comment) are set to 0.
    // Returns how many frames carried written audio.
    std::uint32_t Read(std::int64_t time, float* out, std::uint32_t count) const noexcept
    {
        const std::int64_t end = end_.load(std::memory_order_acquire);

        for (std::uint32_t i = 0; i < count; ++i) {
            out[i] = Slot(time + std::int64_t(i)).load(std::memory_order_relaxed);
        }

        std::atomic_thread_fence(std::memory_order_acquire);
        const std::int64_t limit = limit_.load(std::memory_order_relaxed);

        // Valid times: [limit - Capacity, end), intersected with the request.
        const std::int64_t requestEnd = time + std::int64_t(count);
        const std::int64_t validBegin = std::clamp(limit - Capacity, time, requestEnd);
        const std::int64_t validEnd = std::clamp(end, validBegin, requestEnd);

        for (std::int64_t t = time; t < validBegin; ++t) {
            out[t - time] = 0.0f;
        }
        for (std::int64_t t = validEnd; t < requestEnd; ++t) {
            out[t - time] = 0.0f;
        }

        return std::uint32_t(validEnd - validBegin);
    }

private:
    static constexpr std::uint64_t Mask = std::uint64_t(CapacityFrames - 1);

    std::atomic<float>& Slot(std::int64_t time) noexcept
    {
        return samples_[std::size_t(std::uint64_t(time) & Mask)];
    }

    const std::atomic<float>& Slot(std::int64_t time) const noexcept
    {
        return samples_[std::size_t(std::uint64_t(time) & Mask)];
    }

    // End (exclusive) of the frames fully written, as a sample time.
    // Starts at 0: nothing has been written, every read is silence.
    alignas(64) std::atomic<std::int64_t> end_ { 0 };
    // End (exclusive) of the frames the writer has started writing.
    alignas(64) std::atomic<std::int64_t> limit_ { 0 };
    alignas(64) std::atomic<float> samples_[CapacityFrames];
};

} // namespace mab
