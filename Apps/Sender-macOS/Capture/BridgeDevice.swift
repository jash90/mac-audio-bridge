import BridgeCore
import CoreAudio
import Foundation

/// Stable UID of the virtual output device published by the HAL driver
/// (Driver/Driver.cpp, installed as MacAudioBridge.driver). The sender binds
/// its process tap, default-output comparison, and volume/mute reads to it.
enum BridgeDevice {
    static let uid = "dev.jash90.MacAudioBridge.Device"

    /// Resolves the device's current AudioObjectID from its UID. The ID is
    /// NOT stable: coreaudiod assigns a fresh one on every restart (driver
    /// install/uninstall), so callers re-resolve instead of caching.
    static func deviceID(uid: String = BridgeDevice.uid) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let uidString = uid as CFString
        let status = withUnsafePointer(to: uidString) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID)
        }
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    /// The system's current default output device.
    static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    /// Makes the given device the default output (the "Use iPhone as output"
    /// button). Returns false when the HAL rejects the change.
    static func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = deviceID
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, size, &value) == noErr
    }

    /// Human-readable device name, for the "Switch back to …" button.
    static func deviceName(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return name as String
    }

    /// The device's output volume scalar on element main (0...1). The driver
    /// attaches its volume control to element main, so this is what the
    /// keyboard volume keys and the menu-bar slider change.
    static func volumeScalar(_ deviceID: AudioObjectID) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr
        else { return nil }
        return volume
    }

    /// The device's mute state (output scope, element main).
    static func isMuted(_ deviceID: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr
        else { return nil }
        return muted != 0
    }

    /// Sets the device's output volume scalar (0...1) — the phone's volume
    /// slider. The volume listener then feeds the stream gain.
    @discardableResult
    static func setVolumeScalar(_ deviceID: AudioObjectID, _ volume: Float) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value = Float32(min(max(volume, 0), 1))
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    /// Sets the device's mute state — the phone's mute button.
    @discardableResult
    static func setMuted(_ deviceID: AudioObjectID, _ muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// The device's persistent UID.
    static func deviceUID(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return uid as String
    }

    /// UID, name and built-in-ness of a device, for the output switch model.
    static func outputDeviceInfo(_ deviceID: AudioObjectID) -> OutputDeviceInfo? {
        guard let uid = deviceUID(deviceID) else { return nil }
        return OutputDeviceInfo(
            uid: uid, name: deviceName(deviceID) ?? uid, isBuiltIn: isBuiltIn(deviceID))
    }

    /// Every device with at least one output stream (candidates to restore).
    static func outputDevices() -> [(id: AudioObjectID, info: OutputDeviceInfo)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutputStreams(id), let info = outputDeviceInfo(id) else { return nil }
            return (id, info)
        }
    }

    private static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func isBuiltIn(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr
        else { return false }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }

    /// Whether any process currently runs IO on the device — tells "selected
    /// but silent" apart from "an app is actually playing to it".
    static func isRunningSomewhere(uid: String = BridgeDevice.uid) -> Bool {
        guard let deviceID = deviceID(uid: uid) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }
}

/// Owns the CoreAudio property listeners that drive automatic start/stop and
/// volume tracking. The listener blocks are built in a `nonisolated` factory:
/// a closure literal written in a main-actor context would inherit main-actor
/// isolation, and Swift 6's dynamic executor check traps when CoreAudio
/// invokes it on the listener queue. Each block only calls the `@Sendable`
/// event callback (which hops to the main actor itself); nothing else is
/// captured. Registration methods are called from the main actor only.
final class DeviceEventObserver {
    private struct Registration {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.device-events")
    private var registrations: [Registration] = []

    /// Listens for one property on one object. `onEvent` runs on the listener
    /// queue — it must not touch UI state directly.
    func add(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        onEvent: @escaping @Sendable () -> Void
    ) -> Bool {
        let address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        let block = Self.makeListenerBlock(onEvent)
        var propertyAddress = address
        let status = AudioObjectAddPropertyListenerBlock(objectID, &propertyAddress, queue, block)
        guard status == noErr else { return false }
        registrations.append(Registration(objectID: objectID, address: address, block: block))
        return true
    }

    /// Removes every registration — device IDs are reassigned by coreaudiod
    /// restarts, so stale listeners are dropped and re-added against the fresh
    /// ID by the controller.
    func removeAllRegistrations() {
        registrations.removeAll { registration in
            var address = registration.address
            _ = AudioObjectRemovePropertyListenerBlock(
                registration.objectID, &address, queue, registration.block)
            return true
        }
    }

    /// Nonisolated factory: the block carries no actor isolation, so the HAL
    /// may invoke it on any queue/queueless context without tripping Swift 6's
    /// executor check.
    nonisolated private static func makeListenerBlock(
        _ onEvent: @escaping @Sendable () -> Void
    ) -> AudioObjectPropertyListenerBlock {
        { _, _ in onEvent() }
    }
}
