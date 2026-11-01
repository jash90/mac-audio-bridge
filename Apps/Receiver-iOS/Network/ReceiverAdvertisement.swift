import BridgeCore
import Combine
import Foundation
import UIKit

/// What the Mac sees of this receiver: the Bonjour name the listener is
/// registered under and whether the advertisement is up. Written by
/// `UDPReceiver` (hopping to the main actor), read by the Details and Settings tabs.
@MainActor
final class ReceiverAdvertisement: ObservableObject {
    enum Status: Equatable, Sendable {
        case starting
        /// Registered and listening.
        case advertising
        /// The listener is waiting on Local Network permission (prompt not
        /// answered yet, or denied in Settings).
        case localNetworkDenied
        case failed(String)
    }

    /// Main-actor update posted from the listener queue.
    enum Update: Sendable {
        case status(Status)
        case registeredName(String?)
        case port(UInt16?)
    }

    static let shared = ReceiverAdvertisement()

    @Published private(set) var status: Status = .starting
    /// Name actually registered (Bonjour may rename on a conflict).
    @Published private(set) var registeredName: String?
    @Published private(set) var port: UInt16?

    func apply(_ update: Update) {
        switch update {
        case .status(let status):
            if self.status != status { self.status = status }
        case .registeredName(let name):
            if registeredName != name { registeredName = name }
        case .port(let port):
            if self.port != port { self.port = port }
        }
    }
}

/// Stable, unique Bonjour name for this install: the device name plus a
/// random suffix generated once and persisted, e.g. "iPhone 7KQ2". iOS 16+
/// returns the generic "iPhone" from `UIDevice.current.name` without a
/// special entitlement, so the suffix is what tells two phones apart.
enum ReceiverIdentity {
    private static let suffixKey = "bonjourNameSuffix"

    /// Safe from any thread: reads `UIDevice` only on the main thread (it is
    /// main-actor API) and falls back to the generic name elsewhere.
    static func serviceName() -> String {
        let deviceName: String = Thread.isMainThread
            ? MainActor.assumeIsolated { UIDevice.current.name }
            : ReceiverService.fallbackDeviceName
        return ReceiverService.serviceName(deviceName: deviceName, suffix: persistedSuffix())
    }

    private static func persistedSuffix() -> String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: suffixKey), ReceiverService.isValidSuffix(stored) {
            return stored
        }
        let suffix = ReceiverService.makeSuffix()
        defaults.set(suffix, forKey: suffixKey)
        return suffix
    }
}
