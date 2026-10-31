import Foundation

/// One second of receiver telemetry, appended as a single JSON line to
/// `Documents/stats.jsonl` (reachable through the Files app).
struct StatsLine: Codable, Sendable {
    /// Wall-clock unix timestamp of the sample.
    var timestamp: Double
    var received: Int
    var played: Int
    var lost: Int
    var late: Int
    var duplicates: Int
    var overflowDropped: Int
    var underruns: Int
    var rebuffers: Int
    var bufferingPops: Int
    var depthFrames: Int
    var targetFrames: Int
    /// RFC 3550 interarrival jitter estimate.
    var jitterMs: Double
    /// Relative-delay distribution (fastest-path-anchored), in ms.
    var delayP50Ms: Double
    var delayP95Ms: Double
    var delayP99Ms: Double
    var delayMaxMs: Double
    /// Largest gap between consecutive packets in this second, in ms — the
    /// Wi-Fi power-save burst signature.
    var maxInterArrivalGapMs: Double
    /// Output-side latency (audio session output latency + IO buffer), ms.
    var outputMs: Double
    /// Current audio route name (e.g. the headphones).
    var route: String
    /// Active latency mode: low / balanced / safe.
    var latencyMode: String
    /// Datagrams dropped as malformed since launch.
    var malformed: Int
    /// Frames skipped by the jitter buffer's latency trim since launch.
    var trimmed: Int
    /// Whether the audio engine's IO is running at the sample time.
    var engineRunning: Bool
    /// Render callbacks per second (0 = nothing pulls the jitter buffer).
    var renderCallsPerSec: Int
    /// Successful engine restarts since launch (all causes, watchdog included).
    var engineRestarts: Int
    /// Hardware sample rate the session runs at (48000 = no resampling).
    var sessionSampleRate: Double
    /// IO buffer duration the session granted, ms.
    var ioBufferMs: Double
    /// Audio route changes and interruptions since launch.
    var routeChanges: Int
    var interruptions: Int
    /// Redundant copies received, and frames played from one because the
    /// primary never arrived (M2.8).
    var redundantReceived: Int
    var recovered: Int
    /// Playout slots spent waiting with an empty buffer, and waiting for a
    /// missing frame / growing the cushion (5 ms each).
    var underrunFrames: Int
    var waitFrames: Int
    /// Reader concealment: synthesized slots, concealment events, the ones
    /// that faded all the way to silence, resumes (fade-ins) and crossfaded
    /// splices (trim / overflow).
    var concealedFrames: Int
    var concealments: Int
    var fadeOuts: Int
    var fadeIns: Int
    var crossfades: Int
    /// Playout frame length in ms (5 since M2.8; depth/target are in frames).
    var frameMs: Int
    /// Codec being played: "opus" / "pcm16" ("" before the first frame).
    var codec: String
    /// Its payload bitrate in kbit/s (Opus CBR: from the frame size).
    var codecKbps: Int
    /// Frames that failed to decode (concealed instead), and slots produced
    /// by Opus packet-loss concealment, since launch.
    var decodeErrors: Int
    var opusPlcFrames: Int
    /// Name of the active Mac ("" = none).
    var source: String
    /// Datagrams from non-active Macs dropped since launch.
    var foreignDropped: Int
}

/// Appends one JSON line per second to `Documents/stats.jsonl` on a utility
/// queue — never the render or network path. The file is capped at 2 MB;
/// past the cap the oldest half of the lines is dropped. Encoding happens on
/// the caller; only the resulting `Data` crosses to the queue.
final class StatsJSONLWriter: @unchecked Sendable {
    private let fileURL: URL
    private let maxBytes: Int
    private let encoder: JSONEncoder
    /// All file access is confined to this queue.
    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.stats", qos: .utility)

    init(filename: String = "stats.jsonl", maxBytes: Int = 2 * 1024 * 1024) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent(filename)
        self.maxBytes = maxBytes
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    func append(_ line: StatsLine) {
        guard let data = try? encoder.encode(line) else { return }
        queue.async { [weak self] in
            self?.write(data)
        }
    }

    // MARK: - Queue-confined implementation

    private func write(_ data: Data) {
        var line = data
        line.append(0x0A)
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // No file yet (or it vanished): create it with this line.
            try? line.write(to: fileURL, options: .atomic)
        }
        trimIfNeeded()
    }

    /// Keeps the file bounded: past `maxBytes`, drop the oldest half of the
    /// lines and rewrite atomically.
    private func trimIfNeeded() {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? Int,
            size > maxBytes
        else { return }
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let keptLines = max(lines.count / 2, 1)
        lines.removeFirst(lines.count - keptLines)
        try? lines.joined(separator: "\n").appending("\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
