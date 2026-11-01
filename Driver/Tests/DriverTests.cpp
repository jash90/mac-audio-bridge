// Host-side unit tests for the driver's realtime helpers (task M12a):
// the sample-time ring (MicRing.hpp) and the shared clock (SharedClock.hpp).
// Built and run by scripts/test-driver.sh (also under ThreadSanitizer);
// excluded from the driver bundle in project.yml.

#include "../MicRing.hpp"
#include "../SharedClock.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <functional>
#include <random>
#include <string>
#include <thread>
#include <vector>

namespace {

int g_failures = 0;
int g_checks = 0;

#define CHECK(cond)                                                             \
    do {                                                                        \
        ++g_checks;                                                             \
        if (!(cond)) {                                                          \
            ++g_failures;                                                       \
            std::fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                       \
    } while (0)

struct TestCase
{
    const char* name;
    std::function<void()> body;
};

std::vector<TestCase>& Registry()
{
    static std::vector<TestCase> tests;
    return tests;
}

struct Register
{
    Register(const char* name, std::function<void()> body)
    {
        Registry().push_back({name, std::move(body)});
    }
};

#define TEST(name)                                  \
    void name();                                    \
    const Register name##_registration(#name, name); \
    void name()

// Deterministic, never-zero signal: a frame's value identifies its time.
float Signal(std::int64_t t)
{
    return 1.0f + float(((t % 4096) + 4096) % 4096) / 4096.0f;
}

std::vector<float> SignalBlock(std::int64_t time, std::uint32_t count)
{
    std::vector<float> block(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        block[i] = Signal(time + std::int64_t(i));
    }
    return block;
}

using SmallRing = mab::SampleTimeRing<64>;

// ---------------------------------------------------------------- ring

TEST(RingEmptyReadsSilence)
{
    SmallRing ring;
    std::vector<float> out(16, 7.0f);
    CHECK(ring.Read(0, out.data(), 16) == 0);
    for (float v : out) {
        CHECK(v == 0.0f);
    }
    CHECK(ring.Read(-100, out.data(), 16) == 0);
    CHECK(ring.Read(1'000'000, out.data(), 16) == 0);
}

TEST(RingRoundTrip)
{
    SmallRing ring;
    auto in = SignalBlock(10, 20);
    ring.Write(10, in.data(), 20);

    std::vector<float> out(20);
    CHECK(ring.Read(10, out.data(), 20) == 20);
    CHECK(out == in);
}

TEST(RingWrapsAroundTheEnd)
{
    SmallRing ring;
    // Continuous writes across several laps; slot index wraps at 64.
    for (std::int64_t t = 0; t < 64 * 5; t += 24) {
        auto in = SignalBlock(t, 24);
        ring.Write(t, in.data(), 24);
    }
    // Last written end = 336. A read straddling the wrap point (slot 63 -> 0).
    const std::int64_t end = 336;
    std::vector<float> out(40);
    CHECK(ring.Read(end - 40, out.data(), 40) == 40);
    CHECK(out == SignalBlock(end - 40, 40));
}

TEST(RingUnderrunIsSilenceNotStale)
{
    SmallRing ring;
    auto in = SignalBlock(0, 32);
    ring.Write(0, in.data(), 32);

    // Request [24, 40): 24..31 written, 32..39 not yet -> zeros.
    std::vector<float> out(16, 9.0f);
    CHECK(ring.Read(24, out.data(), 16) == 8);
    for (int i = 0; i < 8; ++i) {
        CHECK(out[i] == Signal(24 + i));
    }
    for (int i = 8; i < 16; ++i) {
        CHECK(out[i] == 0.0f);
    }

    // A full lap later the same slots would hold time 0..31 — must not leak.
    CHECK(ring.Read(64, out.data(), 16) == 0);
    for (float v : out) {
        CHECK(v == 0.0f);
    }
}

TEST(RingOverrunDropsOldest)
{
    SmallRing ring;
    // Writer runs 100 frames ahead of time 0: 0..35 are overwritten.
    for (std::int64_t t = 0; t < 100; t += 10) {
        auto in = SignalBlock(t, 10);
        ring.Write(t, in.data(), 10);
    }
    std::vector<float> out(64);
    // Valid window is [36, 100).
    CHECK(ring.Read(0, out.data(), 64) == 28);
    for (int i = 0; i < 36; ++i) {
        CHECK(out[i] == 0.0f);
    }
    for (int i = 36; i < 64; ++i) {
        CHECK(out[i] == Signal(i));
    }
    CHECK(ring.Read(36, out.data(), 64) == 64);
    CHECK(out == SignalBlock(36, 64));
}

TEST(RingGapAfterFeederPauseReadsSilence)
{
    SmallRing ring;
    auto first = SignalBlock(0, 64);
    ring.Write(0, first.data(), 64);

    // Feeder pauses, resumes at 80: 64..79 were never written. Their slots
    // (16 frames) still hold times 0..15 and must read as silence.
    auto second = SignalBlock(80, 8);
    ring.Write(80, second.data(), 8);

    std::vector<float> out(24, 5.0f);
    CHECK(ring.Read(64, out.data(), 24) == 24); // gap is zero-filled, then 8 real
    for (int i = 0; i < 16; ++i) {
        CHECK(out[i] == 0.0f);
    }
    for (int i = 16; i < 24; ++i) {
        CHECK(out[i] == Signal(64 + i));
    }
}

TEST(RingLongGapLeavesNoStaleFrames)
{
    SmallRing ring;
    auto first = SignalBlock(0, 64);
    ring.Write(0, first.data(), 64);

    // Resume far in the future: every slot not rewritten must read as silence.
    auto second = SignalBlock(10'000, 4);
    ring.Write(10'000, second.data(), 4);

    std::vector<float> out(64, 5.0f);
    ring.Read(10'004 - 64, out.data(), 64);
    for (int i = 0; i < 60; ++i) {
        CHECK(out[i] == 0.0f);
    }
    for (int i = 60; i < 64; ++i) {
        CHECK(out[i] == Signal(10'000 - 60 + i));
    }
}

TEST(RingOversizedWriteKeepsNewest)
{
    SmallRing ring;
    auto in = SignalBlock(0, 200);
    ring.Write(0, in.data(), 200);

    std::vector<float> out(64);
    CHECK(ring.Read(136, out.data(), 64) == 64);
    CHECK(out == SignalBlock(136, 64));
    CHECK(ring.Read(100, out.data(), 36) == 0);
}

TEST(RingZeroCountIsNoOp)
{
    SmallRing ring;
    float dummy = 1.0f;
    ring.Write(5, &dummy, 0);
    std::vector<float> out(4, 3.0f);
    CHECK(ring.Read(0, out.data(), 4) == 0);
    CHECK(ring.Read(0, out.data(), 0) == 0);
}

TEST(RingMultipleReadersSeeSameFrames)
{
    SmallRing ring;
    auto in = SignalBlock(500, 32);
    ring.Write(500, in.data(), 32);
    std::vector<float> a(32), b(32);
    CHECK(ring.Read(500, a.data(), 32) == 32);
    CHECK(ring.Read(500, b.data(), 32) == 32);
    CHECK(a == b);
    CHECK(a == in);
}

// One producer writing a time-coded signal, one reader racing it. Every frame
// the reader reports must be either exact audio for its time or silence —
// never a torn or stale value — and frames well inside the window must be
// delivered.
TEST(RingConcurrentStress)
{
    using Ring = mab::SampleTimeRing<1024>;
    Ring ring;

    constexpr std::int64_t TotalFrames = 3'000'000;
    std::atomic<std::int64_t> published { 0 };
    std::atomic<bool> done { false };

    std::thread writer([&] {
        std::mt19937 rng(1);
        std::uniform_int_distribution<int> blockSize(1, 300);
        std::int64_t t = 0;
        std::vector<float> block(300);
        while (t < TotalFrames) {
            const auto n = std::uint32_t(blockSize(rng));
            for (std::uint32_t i = 0; i < n; ++i) {
                block[i] = Signal(t + std::int64_t(i));
            }
            ring.Write(t, block.data(), n);
            t += n;
            published.store(t, std::memory_order_release);
        }
        done.store(true, std::memory_order_release);
    });

    std::int64_t wrong = 0;
    std::int64_t delivered = 0;
    std::int64_t safeMissing = 0;
    std::int64_t reads = 0;

    std::thread reader([&] {
        std::mt19937 rng(2);
        std::uniform_int_distribution<int> lag(-200, 1400);
        std::uniform_int_distribution<int> size(1, 512);
        std::vector<float> out(512);
        while (!done.load(std::memory_order_acquire)) {
            const std::int64_t head = published.load(std::memory_order_acquire);
            const auto n = std::uint32_t(size(rng));
            const std::int64_t start = head - lag(rng);
            const std::uint32_t valid = ring.Read(start, out.data(), n);
            ++reads;
            std::uint32_t nonZero = 0;
            for (std::uint32_t i = 0; i < n; ++i) {
                const std::int64_t t = start + std::int64_t(i);
                if (out[i] != 0.0f) {
                    ++nonZero;
                    if (out[i] != Signal(t)) {
                        ++wrong;
                    }
                }
            }
            // Signal() is never zero, so valid frames == non-zero frames.
            if (nonZero != valid) {
                ++wrong;
            }
            delivered += valid;

            // Frames already published before the read and far from the
            // writer's reach (it can only move forward) must be there:
            // [head - 600, head) when the writer cannot have lapped them yet.
            if (start >= head - 600 && start + std::int64_t(n) <= head && head > 2000) {
                if (valid != n) {
                    // The writer may have lapped them meanwhile (it can be one
                    // 300-frame block past `published`); only count a miss if
                    // it advanced < 100 frames, so limit - 1024 < head - 600.
                    if (published.load(std::memory_order_acquire) - head < 100) {
                        ++safeMissing;
                    }
                }
            }
        }
    });

    writer.join();
    reader.join();

    std::printf("    stress: %lld reads, %lld frames delivered, %lld wrong, %lld missing\n",
        (long long)reads, (long long)delivered, (long long)wrong, (long long)safeMissing);
    CHECK(wrong == 0);
    CHECK(safeMissing == 0);
    CHECK(reads > 0);
}

// ---------------------------------------------------------------- clock

TEST(ClockTicksPerFrame)
{
    // Apple silicon: numer/denom = 125/3 -> 24 MHz -> 500 ticks per 48 kHz frame.
    CHECK(std::fabs(mab::HostTicksPerFrame(125, 3, 48000) - 500.0) < 1e-9);
    // Intel: 1/1 -> 1 GHz.
    CHECK(std::fabs(mab::HostTicksPerFrame(1, 1, 48000) - 1e9 / 48000) < 1e-6);
}

TEST(ClockBeforeAndAtAnchor)
{
    const auto before = mab::ZeroTimestampAt(900, 1000, 500, 48000);
    CHECK(before.sampleTime == 0);
    CHECK(before.hostTime == 1000);

    const auto at = mab::ZeroTimestampAt(1000, 1000, 500, 48000);
    CHECK(at.sampleTime == 0);
    CHECK(at.hostTime == 1000);
}

TEST(ClockPeriodBoundaries)
{
    // 500 ticks/frame * 48000 frames = 24'000'000 ticks per period.
    const std::uint64_t anchor = 5'000;
    const auto mid = mab::ZeroTimestampAt(anchor + 12'000'000, anchor, 500, 48000);
    CHECK(mid.sampleTime == 0);
    CHECK(mid.hostTime == anchor);

    const auto justBefore = mab::ZeroTimestampAt(anchor + 23'999'999, anchor, 500, 48000);
    CHECK(justBefore.sampleTime == 0);

    const auto boundary = mab::ZeroTimestampAt(anchor + 24'000'000, anchor, 500, 48000);
    CHECK(boundary.sampleTime == 48000);
    CHECK(boundary.hostTime == anchor + 24'000'000);

    const auto third = mab::ZeroTimestampAt(anchor + 3 * 24'000'000 + 7, anchor, 500, 48000);
    CHECK(third.sampleTime == 3 * 48000);
    CHECK(third.hostTime == anchor + 3 * 24'000'000);
}

TEST(ClockInvariantsWithFractionalTicks)
{
    // Intel timebase: 20833.33 ticks per frame, non-integer period length.
    const double tpf = mab::HostTicksPerFrame(1, 1, 48000);
    const std::uint64_t anchor = 123'456'789;
    std::mt19937_64 rng(3);
    std::uniform_int_distribution<std::uint64_t> offset(0, 400ull * 24 * 3600 * 1'000'000'000ull);

    mab::ZeroTimestamp previous;
    std::uint64_t previousNow = 0;
    std::vector<std::uint64_t> nows;
    for (int i = 0; i < 20000; ++i) {
        nows.push_back(anchor + offset(rng));
    }
    std::sort(nows.begin(), nows.end());

    int violations = 0;
    for (std::uint64_t now : nows) {
        const auto ts = mab::ZeroTimestampAt(now, anchor, tpf, 48000);
        const double period = ts.sampleTime / 48000;
        const std::uint64_t next =
            anchor + std::uint64_t((period + 1) * tpf * 48000);
        if (!(ts.hostTime <= now && now < next)) {
            ++violations;
        }
        if (std::floor(period) != period) {
            ++violations;
        }
        if (previousNow != 0 &&
            (ts.sampleTime < previous.sampleTime || ts.hostTime < previous.hostTime)) {
            ++violations; // must be monotonic
        }
        previous = ts;
        previousNow = now;
    }
    CHECK(violations == 0);
}

TEST(ClockSharedByTwoDevicesAgrees)
{
    // The feeder and the mic hold the same SharedClock: identical answers at
    // any instant, so sample time t is the same moment on both.
    const mab::SharedClock clock(777, 500, 48000);
    for (std::uint64_t now = 0; now < 200'000'000; now += 9'999'991) {
        const auto a = clock.At(now);
        const auto b = clock.At(now);
        CHECK(a.sampleTime == b.sampleTime);
        CHECK(a.hostTime == b.hostTime);
    }
    CHECK(clock.FramesPerPeriod() == 48000);
}

TEST(ClockSampleTimeMatchesHostTime)
{
    // The sample time / host time pair must describe the same instant:
    // hostTime - anchor == sampleTime * ticksPerFrame (to within a tick).
    const std::uint64_t anchor = 42;
    for (std::uint64_t k = 1; k < 1000; k += 37) {
        const std::uint64_t now = anchor + k * 24'000'000 + 3;
        const auto ts = mab::ZeroTimestampAt(now, anchor, 500, 48000);
        const double expectedHost = double(anchor) + ts.sampleTime * 500;
        CHECK(std::fabs(double(ts.hostTime) - expectedHost) <= 1.0);
    }
}

} // namespace

int main()
{
    for (const auto& test : Registry()) {
        const int failuresBefore = g_failures;
        test.body();
        std::printf("%s %s\n", g_failures == failuresBefore ? "PASS" : "FAIL", test.name);
    }
    std::printf("%zu tests, %d checks, %d failures\n", Registry().size(), g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
