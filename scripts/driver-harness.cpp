// Loads a built MacAudioBridge.driver IN THIS PROCESS (no install, no
// coreaudiod) and talks to it through the AudioServerPlugIn interface, the
// same calls coreaudiod makes.
//
//   driver-harness dump <bundle> [UID]   property dump of every device, or of
//                                        the device with that UID and its
//                                        streams and controls
//   driver-harness io <bundle>           feeder -> ring -> mic round trip with
//                                        StartIO / WriteMix / ReadInput
//
// Built and run by scripts/check-driver.sh.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include <dlfcn.h>
#include <unistd.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

AudioServerPlugInDriverRef g_driver = nullptr;

// ------------------------------------------------------------ fake host

OSStatus HostPropertiesChanged(AudioServerPlugInHostRef, AudioObjectID, UInt32, const AudioObjectPropertyAddress*)
{
    return kAudioHardwareNoError;
}

OSStatus HostCopyFromStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef* outData)
{
    *outData = nullptr;
    return kAudioHardwareUnknownPropertyError;
}

OSStatus HostWriteToStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef)
{
    return kAudioHardwareNoError;
}

OSStatus HostDeleteFromStorage(AudioServerPlugInHostRef, CFStringRef)
{
    return kAudioHardwareNoError;
}

OSStatus HostRequestConfigurationChange(AudioServerPlugInHostRef, AudioObjectID, UInt64, void*)
{
    return kAudioHardwareNoError;
}

AudioServerPlugInHostInterface g_host = {
    HostPropertiesChanged,
    HostCopyFromStorage,
    HostWriteToStorage,
    HostDeleteFromStorage,
    HostRequestConfigurationChange,
};

bool Load(const char* bundlePath)
{
    const std::string exe = std::string(bundlePath) + "/Contents/MacOS/MacAudioBridge";
    void* lib = dlopen(exe.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        std::fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return false;
    }
    using Factory = void* (*)(CFAllocatorRef, CFUUIDRef);
    auto factory = reinterpret_cast<Factory>(dlsym(lib, "CreateMacAudioBridgeDriver"));
    if (!factory) {
        std::fprintf(stderr, "factory symbol not found\n");
        return false;
    }
    g_driver = static_cast<AudioServerPlugInDriverRef>(factory(kCFAllocatorDefault, kAudioServerPlugInTypeUUID));
    if (!g_driver) {
        std::fprintf(stderr, "factory returned null\n");
        return false;
    }
    if ((*g_driver)->Initialize(g_driver, &g_host) != kAudioHardwareNoError) {
        std::fprintf(stderr, "Initialize failed\n");
        return false;
    }
    return true;
}

// ------------------------------------------------------------ properties

enum class Kind { Raw, CFString, CFURL };

struct Selector
{
    AudioObjectPropertySelector selector;
    const char* name;
    Kind kind;
};

#define SEL(s, k) { s, #s, Kind::k }

const Selector kSelectors[] = {
    SEL(kAudioObjectPropertyBaseClass, Raw),
    SEL(kAudioObjectPropertyClass, Raw),
    SEL(kAudioObjectPropertyOwner, Raw),
    SEL(kAudioObjectPropertyOwnedObjects, Raw),
    SEL(kAudioObjectPropertyName, CFString),
    SEL(kAudioObjectPropertyModelName, CFString),
    SEL(kAudioObjectPropertyManufacturer, CFString),
    SEL(kAudioObjectPropertyElementName, CFString),
    SEL(kAudioObjectPropertySerialNumber, CFString),
    SEL(kAudioObjectPropertyFirmwareVersion, CFString),
    SEL(kAudioObjectPropertyIdentify, Raw),
    SEL(kAudioObjectPropertyCustomPropertyInfoList, Raw),
    SEL(kAudioPlugInPropertyDeviceList, Raw),
    SEL(kAudioPlugInPropertyBoxList, Raw),
    SEL(kAudioPlugInPropertyClockDeviceList, Raw),
    SEL(kAudioPlugInPropertyResourceBundle, CFString),
    SEL(kAudioDevicePropertyConfigurationApplication, CFString),
    SEL(kAudioDevicePropertyDeviceUID, CFString),
    SEL(kAudioDevicePropertyModelUID, CFString),
    SEL(kAudioDevicePropertyTransportType, Raw),
    SEL(kAudioDevicePropertyRelatedDevices, Raw),
    SEL(kAudioDevicePropertyClockDomain, Raw),
    SEL(kAudioDevicePropertyDeviceIsAlive, Raw),
    SEL(kAudioDevicePropertyDeviceIsRunning, Raw),
    SEL(kAudioDevicePropertyDeviceCanBeDefaultDevice, Raw),
    SEL(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, Raw),
    SEL(kAudioDevicePropertyLatency, Raw),
    SEL(kAudioDevicePropertyStreams, Raw),
    SEL(kAudioObjectPropertyControlList, Raw),
    SEL(kAudioDevicePropertySafetyOffset, Raw),
    SEL(kAudioDevicePropertyNominalSampleRate, Raw),
    SEL(kAudioDevicePropertyAvailableNominalSampleRates, Raw),
    SEL(kAudioDevicePropertyIcon, CFURL),
    SEL(kAudioDevicePropertyIsHidden, Raw),
    SEL(kAudioDevicePropertyPreferredChannelsForStereo, Raw),
    SEL(kAudioDevicePropertyPreferredChannelLayout, Raw),
    SEL(kAudioDevicePropertyZeroTimeStampPeriod, Raw),
    SEL(kAudioDevicePropertyClockIsStable, Raw),
    SEL(kAudioDevicePropertyClockAlgorithm, Raw),
    SEL(kAudioStreamPropertyIsActive, Raw),
    SEL(kAudioStreamPropertyDirection, Raw),
    SEL(kAudioStreamPropertyTerminalType, Raw),
    SEL(kAudioStreamPropertyStartingChannel, Raw),
    SEL(kAudioStreamPropertyLatency, Raw),
    SEL(kAudioStreamPropertyVirtualFormat, Raw),
    SEL(kAudioStreamPropertyAvailableVirtualFormats, Raw),
    SEL(kAudioStreamPropertyPhysicalFormat, Raw),
    SEL(kAudioStreamPropertyAvailablePhysicalFormats, Raw),
    SEL(kAudioControlPropertyScope, Raw),
    SEL(kAudioControlPropertyElement, Raw),
    SEL(kAudioLevelControlPropertyScalarValue, Raw),
    SEL(kAudioLevelControlPropertyDecibelValue, Raw),
    SEL(kAudioLevelControlPropertyDecibelRange, Raw),
    SEL(kAudioBooleanControlPropertyValue, Raw),
};

const AudioObjectPropertyScope kScopes[] = {
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyScopeInput,
    kAudioObjectPropertyScopeOutput,
};

const char* ScopeName(AudioObjectPropertyScope scope)
{
    switch (scope) {
    case kAudioObjectPropertyScopeGlobal:
        return "glob";
    case kAudioObjectPropertyScopeInput:
        return "inpt";
    default:
        return "outp";
    }
}

std::string CFToString(CFTypeRef value)
{
    if (!value) {
        return "(null)";
    }
    CFStringRef str = nullptr;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        str = static_cast<CFStringRef>(CFRetain(value));
    } else if (CFGetTypeID(value) == CFURLGetTypeID()) {
        str = CFURLGetString(static_cast<CFURLRef>(value));
        CFRetain(str);
    } else {
        str = CFCopyDescription(value);
    }
    char buf[1024] = {};
    CFStringGetCString(str, buf, sizeof(buf), kCFStringEncodingUTF8);
    CFRelease(str);
    return std::string("\"") + buf + "\"";
}

bool GetProperty(AudioObjectID object, AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope, std::vector<UInt8>& out)
{
    const AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    if (!(*g_driver)->HasProperty(g_driver, object, getpid(), &address)) {
        return false;
    }
    UInt32 size = 0;
    if ((*g_driver)->GetPropertyDataSize(g_driver, object, getpid(), &address, 0, nullptr, &size) !=
        kAudioHardwareNoError) {
        return false;
    }
    out.assign(size, 0);
    UInt32 written = size;
    if ((*g_driver)->GetPropertyData(g_driver, object, getpid(), &address, 0, nullptr, size, &written,
            out.data()) != kAudioHardwareNoError) {
        return false;
    }
    out.resize(written);
    return true;
}

std::vector<AudioObjectID> GetIDs(AudioObjectID object, AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    std::vector<UInt8> raw;
    std::vector<AudioObjectID> ids;
    if (GetProperty(object, selector, scope, raw)) {
        ids.resize(raw.size() / sizeof(AudioObjectID));
        std::memcpy(ids.data(), raw.data(), ids.size() * sizeof(AudioObjectID));
    }
    return ids;
}

std::string GetString(AudioObjectID object, AudioObjectPropertySelector selector)
{
    std::vector<UInt8> raw;
    if (!GetProperty(object, selector, kAudioObjectPropertyScopeGlobal, raw) || raw.size() != sizeof(CFStringRef)) {
        return "";
    }
    CFStringRef str = nullptr;
    std::memcpy(&str, raw.data(), sizeof(str));
    char buf[512] = {};
    if (str) {
        CFStringGetCString(str, buf, sizeof(buf), kCFStringEncodingUTF8);
        CFRelease(str);
    }
    return buf;
}

void DumpObject(AudioObjectID object, const char* label)
{
    std::printf("[%s]\n", label);
    for (const auto scope : kScopes) {
        for (const auto& sel : kSelectors) {
            std::vector<UInt8> raw;
            if (!GetProperty(object, sel.selector, scope, raw)) {
                continue;
            }
            std::printf("  %s %-52s ", ScopeName(scope), sel.name);
            if (sel.kind != Kind::Raw && raw.size() == sizeof(CFTypeRef)) {
                CFTypeRef value = nullptr;
                std::memcpy(&value, raw.data(), sizeof(value));
                std::printf("%s\n", CFToString(value).c_str());
                if (value) {
                    CFRelease(value);
                }
                continue;
            }
            for (size_t i = 0; i < raw.size(); ++i) {
                std::printf("%02x%s", raw[i], (i % 4 == 3 && i + 1 < raw.size()) ? " " : "");
            }
            std::printf("\n");
        }
    }
}

void DumpDevice(AudioObjectID device)
{
    const std::string uid = GetString(device, kAudioDevicePropertyDeviceUID);
    char label[256];
    std::snprintf(label, sizeof(label), "device %u %s", unsigned(device), uid.c_str());
    DumpObject(device, label);
    for (const auto child : GetIDs(device, kAudioObjectPropertyOwnedObjects)) {
        std::snprintf(label, sizeof(label), "  object %u (owned by %s)", unsigned(child), uid.c_str());
        DumpObject(child, label);
    }
}

AudioObjectID FindDevice(const std::string& uid)
{
    for (const auto device : GetIDs(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList)) {
        if (GetString(device, kAudioDevicePropertyDeviceUID) == uid) {
            return device;
        }
    }
    return kAudioObjectUnknown;
}

int Dump(const char* uid)
{
    if (!uid) {
        DumpObject(kAudioObjectPlugInObject, "plugin");
    }
    for (const auto device : GetIDs(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList)) {
        if (uid && GetString(device, kAudioDevicePropertyDeviceUID) != uid) {
            continue;
        }
        DumpDevice(device);
    }
    return 0;
}

// ------------------------------------------------------------ io round trip

int g_failures = 0;

void Expect(bool ok, const char* what)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        ++g_failures;
    }
}

UInt32 GetUInt32(AudioObjectID object, AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    std::vector<UInt8> raw;
    UInt32 value = 0xFFFFFFFF;
    if (GetProperty(object, selector, scope, raw) && raw.size() == sizeof(UInt32)) {
        std::memcpy(&value, raw.data(), sizeof(value));
    }
    return value;
}

OSStatus DoIO(AudioObjectID device, AudioObjectID stream, UInt32 client, UInt32 op,
    Float64 sampleTime, std::vector<float>& buffer)
{
    AudioServerPlugInIOCycleInfo cycle = {};
    cycle.mIOCycleCounter = 1;
    cycle.mNominalIOBufferFrameSize = UInt32(buffer.size());
    cycle.mInputTime.mSampleTime = sampleTime;
    cycle.mInputTime.mFlags = kAudioTimeStampSampleTimeValid;
    cycle.mOutputTime.mSampleTime = sampleTime;
    cycle.mOutputTime.mFlags = kAudioTimeStampSampleTimeValid;
    const UInt32 frames = UInt32(buffer.size());

    Boolean willDo = false, inPlace = false;
    (*g_driver)->WillDoIOOperation(g_driver, device, client, op, &willDo, &inPlace);
    if (!willDo) {
        return kAudioHardwareIllegalOperationError;
    }
    (*g_driver)->BeginIOOperation(g_driver, device, client, op, frames, &cycle);
    const OSStatus status =
        (*g_driver)->DoIOOperation(g_driver, device, stream, client, op, frames, &cycle, buffer.data(), nullptr);
    (*g_driver)->EndIOOperation(g_driver, device, client, op, frames, &cycle);
    return status;
}

int Io()
{
    const AudioObjectID mic = FindDevice("dev.jash90.MacAudioBridge.Mic");
    const AudioObjectID feed = FindDevice("dev.jash90.MacAudioBridge.MicFeed");
    const AudioObjectID output = FindDevice("dev.jash90.MacAudioBridge.Device");
    Expect(output != kAudioObjectUnknown, "output device present");
    Expect(mic != kAudioObjectUnknown, "mic device present");
    Expect(feed != kAudioObjectUnknown, "feeder device present");
    if (g_failures) {
        return 1;
    }

    Expect(GetUInt32(feed, kAudioDevicePropertyIsHidden) == 1, "feeder is hidden");
    Expect(GetUInt32(mic, kAudioDevicePropertyIsHidden) == 0, "mic is visible");
    Expect(GetUInt32(output, kAudioDevicePropertyIsHidden) == 0, "output is visible");
    Expect(GetUInt32(feed, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0,
        "feeder cannot be default output");
    Expect(GetUInt32(mic, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1,
        "mic can be default input");

    const auto micIn = GetIDs(mic, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
    const auto micOut = GetIDs(mic, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    const auto feedOut = GetIDs(feed, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    const auto feedIn = GetIDs(feed, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
    Expect(micIn.size() == 1 && micOut.empty(), "mic: one input stream, no output");
    Expect(feedOut.size() == 1 && feedIn.empty(), "feeder: one output stream, no input");
    if (g_failures) {
        return 1;
    }

    std::vector<UInt8> raw;
    AudioStreamBasicDescription asbd = {};
    if (GetProperty(micIn[0], kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, raw) &&
        raw.size() == sizeof(asbd)) {
        std::memcpy(&asbd, raw.data(), sizeof(asbd));
    }
    Expect(asbd.mSampleRate == 48000 && asbd.mChannelsPerFrame == 1 && asbd.mBitsPerChannel == 32 &&
            (asbd.mFormatFlags & kAudioFormatFlagIsFloat),
        "mic format: 48 kHz mono Float32");
    const UInt32 micLatency = GetUInt32(mic, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput);
    std::printf("     mic latency %u frames\n", unsigned(micLatency));
    Expect(GetUInt32(mic, kAudioDevicePropertyClockDomain) == GetUInt32(feed, kAudioDevicePropertyClockDomain) &&
            GetUInt32(mic, kAudioDevicePropertyClockDomain) != 0,
        "mic and feeder share a nonzero clock domain");

    const AudioServerPlugInClientInfo micClient = {101, getpid(), true, nullptr};
    const AudioServerPlugInClientInfo feedClient = {102, getpid(), true, nullptr};
    Expect((*g_driver)->AddDeviceClient(g_driver, mic, &micClient) == kAudioHardwareNoError, "mic AddClient");
    Expect((*g_driver)->AddDeviceClient(g_driver, feed, &feedClient) == kAudioHardwareNoError, "feeder AddClient");

    // Start the feeder first, the mic 50 ms later: libASPL's per-device anchor
    // would give them different timelines; the shared clock must not.
    Expect((*g_driver)->StartIO(g_driver, feed, feedClient.mClientID) == kAudioHardwareNoError, "feeder StartIO");
    usleep(50'000);
    Expect((*g_driver)->StartIO(g_driver, mic, micClient.mClientID) == kAudioHardwareNoError, "mic StartIO");
    Expect(GetUInt32(mic, kAudioDevicePropertyDeviceIsRunning) == 1, "mic reports running");

    bool sameClock = false;
    Float64 zeroSample = 0;
    for (int attempt = 0; attempt < 3 && !sameClock; ++attempt) {
        Float64 sampleA = 0, sampleB = 0;
        UInt64 hostA = 0, hostB = 0, seedA = 0, seedB = 0;
        (*g_driver)->GetZeroTimeStamp(g_driver, feed, feedClient.mClientID, &sampleA, &hostA, &seedA);
        (*g_driver)->GetZeroTimeStamp(g_driver, mic, micClient.mClientID, &sampleB, &hostB, &seedB);
        sameClock = (sampleA == sampleB && hostA == hostB && seedA == seedB);
        zeroSample = sampleB;
    }
    Expect(sameClock, "feeder and mic return the same zero timestamp");

    // Feed 512 frames of 1 kHz at output time T; read them back at T plus the
    // mic's read delay (the ReadInput time the HAL would use).
    const Float64 T = zeroSample + 96'000;
    std::vector<float> tone(512);
    for (size_t i = 0; i < tone.size(); ++i) {
        tone[i] = 0.5f * float(std::sin(2 * M_PI * 1000.0 * double(i) / 48000.0));
    }
    std::vector<float> fed = tone;
    Expect(DoIO(feed, feedOut[0], feedClient.mClientID, kAudioServerPlugInIOOperationWriteMix, T, fed) ==
            kAudioHardwareNoError,
        "feeder WriteMix");

    std::vector<float> got(512, 9.0f);
    Expect(DoIO(mic, micIn[0], micClient.mClientID, kAudioServerPlugInIOOperationReadInput, T + micLatency, got) ==
            kAudioHardwareNoError,
        "mic ReadInput");
    Expect(got == tone, "mic delivers exactly what the feeder wrote");

    std::vector<float> later(512, 9.0f);
    DoIO(mic, micIn[0], micClient.mClientID, kAudioServerPlugInIOOperationReadInput, T + micLatency + 512, later);
    bool silent = true;
    for (float v : later) {
        silent = silent && v == 0.0f;
    }
    Expect(silent, "underrun (nothing fed yet) reads silence");

    std::vector<float> stale(512, 9.0f);
    DoIO(mic, micIn[0], micClient.mClientID, kAudioServerPlugInIOOperationReadInput, T + micLatency + 8192, stale);
    silent = true;
    for (float v : stale) {
        silent = silent && v == 0.0f;
    }
    Expect(silent, "one ring lap later reads silence, not stale audio");

    Expect((*g_driver)->StopIO(g_driver, mic, micClient.mClientID) == kAudioHardwareNoError, "mic StopIO");
    Expect((*g_driver)->StopIO(g_driver, feed, feedClient.mClientID) == kAudioHardwareNoError, "feeder StopIO");
    Expect(GetUInt32(mic, kAudioDevicePropertyDeviceIsRunning) == 0, "mic reports stopped");
    (*g_driver)->RemoveDeviceClient(g_driver, mic, &micClient);
    (*g_driver)->RemoveDeviceClient(g_driver, feed, &feedClient);

    std::printf("%d failures\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s dump <bundle> [UID] | io <bundle>\n", argv[0]);
        return 2;
    }
    if (!Load(argv[2])) {
        return 1;
    }
    if (std::strcmp(argv[1], "dump") == 0) {
        return Dump(argc > 3 ? argv[3] : nullptr);
    }
    if (std::strcmp(argv[1], "io") == 0) {
        return Io();
    }
    return 2;
}
