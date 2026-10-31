// Mac Audio Bridge — OUTPUT-ONLY null virtual device (task M1.5b).
//
// The driver publishes "iPhone (Mac Audio Bridge)": a 48 kHz stereo Float32
// output stream with volume and mute controls, eligible as the default output
// device. Samples played to the device are mixed and DISCARDED — the device is
// a null sink. Capture happens in the sender app, which creates a process tap
// bound to this device's UID (see Apps/Sender-macOS/Capture/DeviceAudioTap.swift),
// so exactly the audio the user routes to "iPhone (Mac Audio Bridge)" is streamed.
//
// The user selects the device as the system output; the Mac speakers are simply
// not used then (nothing is played to them), like an AirPlay receiver.
//
// Built on libASPL (ThirdParty/libASPL, MIT license).

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <memory>

namespace {

constexpr UInt32 SampleRate = 48000;
constexpr UInt32 ChannelCount = 2;

// Stable UID that the sender targets with the device-bound process tap,
// the default-output comparison, and the volume/mute listeners.
constexpr const char* DeviceUID = "dev.jash90.MacAudioBridge.Device";

std::shared_ptr<aspl::Driver> CreateBridgeDriver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters params;
    params.Name = "iPhone (Mac Audio Bridge)";
    params.Manufacturer = "Mac Audio Bridge";
    params.DeviceUID = DeviceUID;
    params.SampleRate = SampleRate;
    params.ChannelCount = ChannelCount;

    // Presentation latency and read/write guard band, in frames. Keep small:
    // the iPhone link adds its own buffering downstream.
    params.Latency = 0;
    params.SafetyOffset = 0;

    // Clock: zero timestamps derived from the host clock, one period per
    // second (zero => defaults to SampleRate). This keeps GetZeroTimeStamp()
    // answering in real time, so the device reports running while any app
    // plays to it and the sender's aggregate can use it as the clock.
    params.ZeroTimeStampPeriod = SampleRate;

    // Eligible as default output (System Settings → Sound, the menu-bar volume
    // menu, and the keyboard volume keys then target this device's controls).
    params.CanBeDefault = true;
    params.CanBeDefaultForSystemSounds = true;

    auto device = std::make_shared<aspl::Device>(context, params);

    // Output stream + volume + mute controls on element main. The default
    // IORequestHandler discards what clients write — exactly what a null
    // sink wants; the sender reads the controls and applies the gain itself.
    device->AddStreamWithControlsAsync(aspl::Direction::Output);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* CreateMacAudioBridgeDriver(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    (void)allocator;

    // 443ABAB8-E7B3-491A-B985-BEB9187030DB (AudioServerPlugIn.h).
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    static std::shared_ptr<aspl::Driver> driver = CreateBridgeDriver();

    return driver->GetReference();
}
