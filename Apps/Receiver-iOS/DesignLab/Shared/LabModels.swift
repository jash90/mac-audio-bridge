import SwiftUI

// Mock data for the DesignLab redesign variants. Nothing here touches the
// real engine: every value is a static sample for one of three scenarios.

/// The scenario a variant is rendered in.
enum LabScenario: String, CaseIterable, Sendable {
    /// Streaming over home Wi‑Fi, good link.
    case wifi
    /// Streaming over a Tailscale relay on cellular, worse link.
    case cellular
    /// No Mac connected.
    case idle
}

/// Which tab a variant opens on. Every variant has the same four tabs in a
/// bottom tab bar: Now, Sources, Details, Settings.
enum LabScreen: String, Sendable {
    case home
    case sources
    case details
    case settings
}

/// How the audio reaches the phone.
enum LabPath: Sendable {
    case wifi
    case tailscaleDirect
    case tailscaleRelay
    case cellular

    var title: String {
        switch self {
        case .wifi: "Wi‑Fi"
        case .tailscaleDirect: "Tailscale direct"
        case .tailscaleRelay: "Tailscale relay"
        case .cellular: "Cellular"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .tailscaleDirect: "point.3.connected.trianglepath.dotted"
        case .tailscaleRelay: "arrow.triangle.branch"
        case .cellular: "antenna.radiowaves.left.and.right"
        }
    }
}

/// One simple latency control, explained in human terms.
enum LabLatency: String, CaseIterable, Identifiable, Sendable {
    case low
    case balanced
    case safe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .balanced: "Balanced"
        case .safe: "Safe"
        }
    }

    var symbol: String {
        switch self {
        case .low: "hare"
        case .balanced: "scalemass"
        case .safe: "tortoise"
        }
    }

    /// One sentence a non-engineer understands.
    var explanation: String {
        switch self {
        case .low: "Fastest. Lips stay in sync with video, but a weak signal can cause crackles."
        case .balanced: "A small delay that rarely drops out. Right for most music and video."
        case .safe: "Smoothest. Adds a little delay so weak Wi‑Fi or cellular never cuts out."
        }
    }

    var shortExplanation: String {
        switch self {
        case .low: "Best for video, needs strong Wi‑Fi"
        case .balanced: "Right for most things"
        case .safe: "Never cuts out, a bit more delay"
        }
    }
}

/// Output quality picker for the active Mac.
enum LabQuality: String, CaseIterable, Identifiable, Sendable {
    case opus128
    case opus192
    case pcm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opus128: "Opus 128"
        case .opus192: "Opus 192"
        case .pcm: "Lossless"
        }
    }

    var subtitle: String {
        switch self {
        case .opus128: "≈ 190 MB/h"
        case .opus192: "≈ 500 MB/h"
        case .pcm: "≈ 1.5 GB/h · Wi‑Fi only"
        }
    }
}

/// Overall link health, in plain words.
enum LabHealth: Sendable {
    case excellent
    case fair
    case none

    var title: String {
        switch self {
        case .excellent: "Excellent"
        case .fair: "Okay"
        case .none: "Not connected"
        }
    }

    var color: Color {
        switch self {
        case .excellent: .green
        case .fair: .orange
        case .none: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .excellent: "checkmark.seal.fill"
        case .fair: "exclamationmark.triangle.fill"
        case .none: "moon.zzz.fill"
        }
    }
}

struct LabMac: Identifiable, Sendable {
    enum Kind: Sendable { case laptop, mini, desktop }

    let id: String
    let name: String
    let kind: Kind
    let online: Bool
    let playing: Bool
    let active: Bool
    /// Second line of the row ("Output: Studio Display", "Offline — last used").
    let detail: String
    let path: LabPath?

    var symbol: String {
        switch kind {
        case .laptop: "laptopcomputer"
        case .mini: "macmini"
        case .desktop: "desktopcomputer"
        }
    }
}

struct LabNowPlaying: Sendable {
    let title: String
    let artist: String
    let app: String
    let appSymbol: String
    let isPlaying: Bool
    let elapsed: Double
    let duration: Double
}

/// Where the total delay comes from.
struct LabLatencyBreakdown: Sendable {
    let networkMs: Int
    let bufferMs: Int
    let outputMs: Int

    var totalMs: Int { networkMs + bufferMs + outputMs }
}

struct LabLink: Sendable {
    let health: LabHealth
    /// Plain-language headline ("Streaming smoothly over Wi‑Fi").
    let headline: String
    /// Plain-language explanation of what it means for the listener.
    let explanation: String
    let path: LabPath
    let pathDetail: String
    let codec: String
    let bitrateKbps: Int
    let targetMs: Int
    let breakdown: LabLatencyBreakdown
    let lossPercent: Double
    let recovered: Int
    let concealed: Int
    let late: Int
    let rebuffers: Int
    let underruns: Int
    let jitterMs: Double
    let delayP50Ms: Double
    let delayP95Ms: Double
    let delayP99Ms: Double
    let dataUsedMB: Double
    let mbPerHour: Int
    let sessionMinutes: Int
    let route: String
    let engineRestarts: Int
    let malformed: Int
    let foreignDropped: Int
    let redundantReceived: Int
    /// Last 40 samples of the delay p95, ms (sparklines and charts).
    let delayHistory: [Double]
    /// Last 40 samples of loss %, per second.
    let lossHistory: [Double]
    /// Overall score 0…1 for gauges.
    let score: Double
}

enum LabMicState: Sendable {
    case off
    case armed
    case live
}

struct LabMic: Sendable {
    let state: LabMicState
    let source: String
    let level: Double
}

/// Everything one scenario shows.
struct LabSnapshot: Sendable {
    let scenario: LabScenario
    let macs: [LabMac]
    let nowPlaying: LabNowPlaying?
    let link: LabLink?
    let mic: LabMic
    let volume: Double
    let quality: LabQuality
    let latency: LabLatency

    var activeMac: LabMac? { macs.first { $0.active } }
}

/// Interactive state for one variant, seeded from a scenario so the mockups
/// can be clicked through (latency, volume, mute, mic) without the engine.
@MainActor
final class LabStore: ObservableObject {
    let snapshot: LabSnapshot
    @Published var latency: LabLatency
    @Published var volume: Double
    @Published var muted = false
    @Published var quality: LabQuality
    @Published var micEnabled: Bool
    @Published var micMuted = false
    @Published var isPlaying: Bool

    init(scenario: LabScenario) {
        let snapshot = LabSnapshot.sample(scenario)
        self.snapshot = snapshot
        latency = snapshot.latency
        volume = snapshot.volume
        quality = snapshot.quality
        micEnabled = snapshot.mic.state != .off
        isPlaying = snapshot.nowPlaying?.isPlaying ?? false
    }

    var link: LabLink? { snapshot.link }
    var activeMac: LabMac? { snapshot.activeMac }
    var nowPlaying: LabNowPlaying? { snapshot.nowPlaying }
    var isConnected: Bool { snapshot.link != nil }

    /// Target ms the latency control would give on the current path.
    func targetMs(for mode: LabLatency) -> Int {
        let cellular = snapshot.scenario == .cellular
        switch mode {
        case .low: return cellular ? 100 : 30
        case .balanced: return cellular ? 120 : 60
        case .safe: return cellular ? 150 : 120
        }
    }
}

extension LabSnapshot {
    static func sample(_ scenario: LabScenario) -> LabSnapshot {
        switch scenario {
        case .wifi: wifi
        case .cellular: cellular
        case .idle: idle
        }
    }

    private static let wifi = LabSnapshot(
        scenario: .wifi,
        macs: [
            LabMac(
                id: "mbp", name: "MacBook Pro", kind: .laptop, online: true, playing: true,
                active: true, detail: "Playing on this iPhone · Opus 192", path: .wifi),
            LabMac(
                id: "mini", name: "Studio Mac mini", kind: .mini, online: true, playing: false,
                active: false, detail: "Output: Studio Display speakers", path: .wifi),
            LabMac(
                id: "imac", name: "iMac (Office)", kind: .desktop, online: false, playing: false,
                active: false, detail: "Offline", path: nil),
        ],
        nowPlaying: LabNowPlaying(
            title: "Midnight City", artist: "M83", app: "Spotify",
            appSymbol: "music.note", isPlaying: true, elapsed: 97, duration: 243),
        link: LabLink(
            health: .excellent,
            headline: "Streaming smoothly",
            explanation: "Strong home Wi‑Fi. Nothing lost that you could hear.",
            path: .wifi, pathDetail: "Home Wi‑Fi · same network",
            codec: "Opus", bitrateKbps: 192, targetMs: 60,
            breakdown: LabLatencyBreakdown(networkMs: 6, bufferMs: 58, outputMs: 146),
            lossPercent: 0.1, recovered: 12, concealed: 0, late: 3, rebuffers: 0, underruns: 0,
            jitterMs: 2.4, delayP50Ms: 4.1, delayP95Ms: 7.8, delayP99Ms: 12.5,
            dataUsedMB: 412, mbPerHour: 498, sessionMinutes: 50,
            route: "AirPods Pro", engineRestarts: 0, malformed: 0, foreignDropped: 0,
            redundantReceived: 61_204,
            delayHistory: [
                7, 6, 8, 7, 7, 9, 6, 7, 8, 7, 6, 7, 11, 8, 7, 7, 6, 8, 7, 7,
                6, 7, 8, 9, 7, 6, 7, 7, 8, 7, 6, 7, 7, 8, 6, 7, 7, 8, 7, 7,
            ],
            lossHistory: [
                0, 0, 0, 0, 0.2, 0, 0, 0, 0, 0, 0, 0, 0.4, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0.2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            ],
            score: 0.94),
        mic: LabMic(state: .live, source: "iPhone microphone", level: 0.62),
        volume: 0.72, quality: .opus192, latency: .balanced)

    private static let cellular = LabSnapshot(
        scenario: .cellular,
        macs: [
            LabMac(
                id: "mbp", name: "MacBook Pro", kind: .laptop, online: true, playing: true,
                active: true, detail: "Playing on this iPhone · Opus 128 (cellular)",
                path: .tailscaleRelay),
            LabMac(
                id: "mini", name: "Studio Mac mini", kind: .mini, online: true, playing: false,
                active: false, detail: "Via Tailscale · idle", path: .tailscaleDirect),
            LabMac(
                id: "imac", name: "iMac (Office)", kind: .desktop, online: false, playing: false,
                active: false, detail: "Offline", path: nil),
        ],
        nowPlaying: LabNowPlaying(
            title: "The Daily", artist: "The New York Times", app: "Podcasts",
            appSymbol: "antenna.radiowaves.left.and.right", isPlaying: true,
            elapsed: 812, duration: 1_740),
        link: LabLink(
            health: .fair,
            headline: "Playing, with extra delay",
            explanation: "Away from home on 5G through a Tailscale relay. A bigger buffer keeps it from cutting out.",
            path: .tailscaleRelay, pathDetail: "5G → Tailscale relay (Frankfurt)",
            codec: "Opus", bitrateKbps: 128, targetMs: 150,
            breakdown: LabLatencyBreakdown(networkMs: 74, bufferMs: 152, outputMs: 24),
            lossPercent: 2.1, recovered: 184, concealed: 23, late: 41, rebuffers: 1, underruns: 2,
            jitterMs: 38, delayP50Ms: 71, delayP95Ms: 132, delayP99Ms: 210,
            dataUsedMB: 64, mbPerHour: 188, sessionMinutes: 20,
            route: "iPhone speaker", engineRestarts: 1, malformed: 0, foreignDropped: 0,
            redundantReceived: 21_870,
            delayHistory: [
                96, 110, 140, 122, 98, 105, 180, 210, 150, 118, 102, 99, 134, 128, 160, 112, 97, 104,
                118, 145, 190, 170, 126, 108, 100, 117, 133, 121, 99, 140, 155, 124, 109, 101, 98,
                143, 168, 129, 112, 132,
            ],
            lossHistory: [
                1, 2, 4, 2, 0.5, 1, 6, 8, 3, 1, 1, 0.5, 2, 2, 4, 1, 0, 1, 2, 3,
                7, 5, 2, 1, 1, 2, 2, 1, 0.5, 3, 4, 2, 1, 1, 0.5, 3, 5, 2, 1, 2,
            ],
            score: 0.58),
        mic: LabMic(state: .off, source: "iPhone microphone", level: 0),
        volume: 0.55, quality: .opus128, latency: .safe)

    private static let idle = LabSnapshot(
        scenario: .idle,
        macs: [
            LabMac(
                id: "mbp", name: "MacBook Pro", kind: .laptop, online: true, playing: false,
                active: false, detail: "Ready · Output: MacBook Pro speakers", path: .wifi),
            LabMac(
                id: "mini", name: "Studio Mac mini", kind: .mini, online: true, playing: true,
                active: false, detail: "Streaming to Bart's iPad", path: .wifi),
            LabMac(
                id: "imac", name: "iMac (Office)", kind: .desktop, online: false, playing: false,
                active: false, detail: "Offline — last used", path: nil),
        ],
        nowPlaying: nil, link: nil,
        mic: LabMic(state: .off, source: "iPhone microphone", level: 0),
        volume: 0.72, quality: .opus192, latency: .balanced)
}

// MARK: - Formatting

enum LabFormat {
    static func time(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func megabytes(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.1f GB", value / 1000) : "\(Int(value)) MB"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f %%", value)
    }
}
