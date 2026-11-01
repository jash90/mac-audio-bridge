// Mac Audio Bridge — one clock shared by the feeder and mic devices (task M12a).
//
// libASPL anchors each device's zero timestamps at that device's own StartIO,
// so two devices would disagree on what sample time t means. The mic and its
// hidden feeder instead both answer GetZeroTimeStamp from this clock: one
// anchor host time taken once, when the driver is created, and the same
// period. Sample time t is then the same instant on both devices — the ring
// (MicRing.hpp) is indexed by it — and the two can never drift apart, since
// they are literally the same function of mach_absolute_time().
//
// The zero timestamp is a pure, stateless function of the current host time:
// the start of the period containing `now`. No mutable state, so it is safe to
// call from any IO thread concurrently, and monotonic because `now` is.
//
// Pure C++17, no CoreAudio — unit-tested in Driver/Tests outside coreaudiod.

#pragma once

#include <cstdint>

namespace mab {

struct ZeroTimestamp
{
    double sampleTime = 0;
    std::uint64_t hostTime = 0;
};

// Host clock ticks per audio frame. mach ticks convert to nanoseconds as
// ticks * numer / denom, so the tick rate is 1e9 * denom / numer per second.
inline double HostTicksPerFrame(std::uint32_t timebaseNumer,
    std::uint32_t timebaseDenom,
    double sampleRate) noexcept
{
    const double ticksPerSecond = 1e9 * double(timebaseDenom) / double(timebaseNumer);
    return ticksPerSecond / sampleRate;
}

// Zero timestamp at host time `now`: the most recent period boundary at or
// before `now`, counted from `anchorHostTime`. Before the anchor it returns
// the anchor itself (sample time 0).
inline ZeroTimestamp ZeroTimestampAt(std::uint64_t now,
    std::uint64_t anchorHostTime,
    double hostTicksPerFrame,
    std::uint32_t framesPerPeriod) noexcept
{
    ZeroTimestamp result;
    result.hostTime = anchorHostTime;

    if (now <= anchorHostTime || framesPerPeriod == 0 || hostTicksPerFrame <= 0) {
        return result;
    }

    const double ticksPerPeriod = hostTicksPerFrame * double(framesPerPeriod);
    std::uint64_t period = std::uint64_t(double(now - anchorHostTime) / ticksPerPeriod);

    auto periodHostTime = [&](std::uint64_t p) {
        return anchorHostTime + std::uint64_t(double(p) * ticksPerPeriod);
    };

    // Floating-point rounding can put the boundary one tick on the wrong side
    // of `now`; nudge so that periodHostTime(period) <= now < periodHostTime(period + 1).
    while (period > 0 && periodHostTime(period) > now) {
        --period;
    }
    while (periodHostTime(period + 1) <= now) {
        ++period;
    }

    result.sampleTime = double(period) * double(framesPerPeriod);
    result.hostTime = periodHostTime(period);
    return result;
}

class SharedClock
{
public:
    SharedClock(std::uint64_t anchorHostTime, double hostTicksPerFrame, std::uint32_t framesPerPeriod) noexcept
        : anchorHostTime_(anchorHostTime)
        , hostTicksPerFrame_(hostTicksPerFrame)
        , framesPerPeriod_(framesPerPeriod)
    {
    }

    ZeroTimestamp At(std::uint64_t now) const noexcept
    {
        return ZeroTimestampAt(now, anchorHostTime_, hostTicksPerFrame_, framesPerPeriod_);
    }

    std::uint32_t FramesPerPeriod() const noexcept
    {
        return framesPerPeriod_;
    }

private:
    // Immutable after construction: read concurrently without synchronization.
    const std::uint64_t anchorHostTime_;
    const double hostTicksPerFrame_;
    const std::uint32_t framesPerPeriod_;
};

} // namespace mab
