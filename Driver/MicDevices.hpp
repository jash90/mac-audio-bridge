// Mac Audio Bridge — virtual iPhone microphone (task M12a, phase 1).
//
// Two more devices next to the unchanged output device:
//
// - "iPhone Mic (Mac Audio Bridge)" (UID dev.jash90.MacAudioBridge.Mic): a
//   visible input-only device, 48 kHz mono Float32, with input volume and mute
//   controls. Meet, Teams, QuickTime and Voice Memos list it like any mic.
// - "Mac Audio Bridge Mic Feed" (UID dev.jash90.MacAudioBridge.MicFeed): a
//   HIDDEN output-only device, 48 kHz mono Float32. It is not in the device
//   lists and cannot be a default device; the Sender app finds it by UID
//   (kAudioHardwarePropertyTranslateUIDToDevice) and plays the iPhone's mic
//   audio into it.
//
// What the feeder's mixed output gets (WriteMix) goes into one in-process ring
// (MicRing.hpp); the mic's ReadInput reads it back. Both devices answer
// GetZeroTimeStamp from one SharedClock, so a sample time means the same
// instant on both. When nothing feeds the ring the mic reads silence.
//
// The mic reads the ring MicReadDelayFrames behind the requested time and
// reports that as its latency: it gives the feeder's IO cycle a fixed margin
// to finish writing a frame before any mic client reads it, instead of racing
// it at a zero offset.
//
// kAudioDevicePropertyDeviceIsRunningSomewhere is computed by the HAL from
// StartIO/StopIO across all processes (as for the output device today), so it
// reports whether any app has the mic open — nothing to implement here.

#pragma once

#include "MicRing.hpp"
#include "SharedClock.hpp"

#include <aspl/Device.hpp>
#include <aspl/IORequestHandler.hpp>
#include <aspl/Plugin.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>

#include <cmath>
#include <cstring>
#include <memory>

namespace mab {

constexpr const char* MicDeviceUID = "dev.jash90.MacAudioBridge.Mic";
constexpr const char* MicFeedDeviceUID = "dev.jash90.MacAudioBridge.MicFeed";

constexpr UInt32 MicSampleRate = 48000;
constexpr UInt32 MicChannelCount = 1;

// 8192 frames = 170.7 ms at 48 kHz: holds the feeder's lead plus the mic
// client's lag with room for large IO buffers. Power of two for the index.
constexpr std::size_t MicRingFrames = 8192;

// 240 frames = 5 ms.
constexpr UInt32 MicReadDelayFrames = 240;

// Same nonzero clock domain on both devices: tells the HAL (and aggregates)
// that they run off one clock and need no drift correction between them.
constexpr UInt32 MicClockDomain = 0x4D414243; // 'MABC'

using MicRing = SampleTimeRing<MicRingFrames>;

// A device whose zero timestamps come from the driver-wide SharedClock instead
// of libASPL's per-device anchor (taken at each StartIO).
class SharedClockDevice : public aspl::Device
{
public:
    SharedClockDevice(std::shared_ptr<const aspl::Context> context,
        const aspl::DeviceParameters& params,
        std::shared_ptr<const SharedClock> clock)
        : aspl::Device(std::move(context), params)
        , clock_(std::move(clock))
    {
    }

protected:
    // Realtime thread: pure arithmetic on immutable state.
    OSStatus GetZeroTimeStampImpl(UInt32 clientID,
        Float64* outSampleTime,
        UInt64* outHostTime,
        UInt64* outSeed) override
    {
        (void)clientID;
        const ZeroTimestamp ts = clock_->At(mach_absolute_time());
        *outSampleTime = ts.sampleTime;
        *outHostTime = ts.hostTime;
        // The timeline never restarts or jumps, so the seed never changes.
        *outSeed = 1;
        return kAudioHardwareNoError;
    }

private:
    const std::shared_ptr<const SharedClock> clock_;
};

inline std::int64_t SampleTimeToFrame(Float64 sampleTime) noexcept
{
    return std::int64_t(std::floor(sampleTime));
}

// Feeder device: the mixed output (Float32 mono, the stream's physical
// format) goes into the ring at its output sample time.
class MicFeedWriter : public aspl::IORequestHandler
{
public:
    explicit MicFeedWriter(std::shared_ptr<MicRing> ring)
        : ring_(std::move(ring))
    {
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        (void)stream;
        (void)zeroTimestamp;
        ring_->Write(SampleTimeToFrame(timestamp),
            static_cast<const float*>(bytes),
            bytesCount / UInt32(sizeof(float) * MicChannelCount));
    }

private:
    const std::shared_ptr<MicRing> ring_;
};

// Mic device: each client's input buffer is read from the ring at its input
// sample time (minus the fixed read delay). Silence where nothing was fed.
class MicInputReader : public aspl::IORequestHandler
{
public:
    explicit MicInputReader(std::shared_ptr<const MicRing> ring)
        : ring_(std::move(ring))
    {
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override
    {
        (void)client;
        (void)stream;
        (void)zeroTimestamp;
        ring_->Read(SampleTimeToFrame(timestamp) - std::int64_t(MicReadDelayFrames),
            static_cast<float*>(bytes),
            bytesCount / UInt32(sizeof(float) * MicChannelCount));
    }

private:
    const std::shared_ptr<const MicRing> ring_;
};

inline aspl::StreamParameters MicStreamParameters(aspl::Direction direction)
{
    aspl::StreamParameters params;
    params.Direction = direction;
    params.StartingChannel = 1;
    params.Format.mSampleRate = MicSampleRate;
    params.Format.mFormatID = kAudioFormatLinearPCM;
    params.Format.mFormatFlags =
        kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    params.Format.mBitsPerChannel = 32;
    params.Format.mChannelsPerFrame = MicChannelCount;
    params.Format.mBytesPerFrame = UInt32(sizeof(float)) * MicChannelCount;
    params.Format.mFramesPerPacket = 1;
    params.Format.mBytesPerPacket = params.Format.mBytesPerFrame;
    return params;
}

inline aspl::DeviceParameters MicDeviceParametersBase()
{
    aspl::DeviceParameters params;
    params.Manufacturer = "Mac Audio Bridge";
    params.SampleRate = MicSampleRate;
    params.ChannelCount = MicChannelCount;
    params.SafetyOffset = 0;
    params.ZeroTimeStampPeriod = MicSampleRate;
    params.ClockDomain = MicClockDomain;
    params.CanBeDefaultForSystemSounds = false;
    return params;
}

// Creates the mic and feeder devices and adds them to `plugin`.
inline void AddMicDevices(const std::shared_ptr<aspl::Context>& context,
    const std::shared_ptr<aspl::Plugin>& plugin)
{
    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);

    auto clock = std::make_shared<const SharedClock>(mach_absolute_time(),
        HostTicksPerFrame(timebase.numer, timebase.denom, MicSampleRate),
        MicSampleRate);

    auto ring = std::make_shared<MicRing>();

    // Visible microphone. Can be the default input (opt-in by the user).
    aspl::DeviceParameters micParams = MicDeviceParametersBase();
    micParams.Name = "iPhone Mic (Mac Audio Bridge)";
    micParams.DeviceUID = MicDeviceUID;
    micParams.Latency = MicReadDelayFrames;
    micParams.CanBeDefault = true;

    auto mic = std::make_shared<SharedClockDevice>(context, micParams, clock);
    mic->AddStreamWithControlsAsync(MicStreamParameters(aspl::Direction::Input));
    mic->SetIOHandler(std::make_shared<MicInputReader>(ring));

    // Hidden feeder: never listed, never a default device.
    aspl::DeviceParameters feedParams = MicDeviceParametersBase();
    feedParams.Name = "Mac Audio Bridge Mic Feed";
    feedParams.DeviceUID = MicFeedDeviceUID;
    feedParams.Latency = 0;
    feedParams.CanBeDefault = false;

    auto feed = std::make_shared<SharedClockDevice>(context, feedParams, clock);
    feed->AddStreamAsync(MicStreamParameters(aspl::Direction::Output));
    feed->SetIsHidden(true);
    feed->SetIOHandler(std::make_shared<MicFeedWriter>(ring));

    plugin->AddDevice(mic);
    plugin->AddDevice(feed);
}

} // namespace mab
