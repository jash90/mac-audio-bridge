import Foundation

/// Appends JSON lines to a file on a utility queue and keeps the file
/// bounded: past `maxBytes` the oldest half of the lines is dropped.
///
/// The caller encodes the line; only the resulting `Data` (Sendable)
/// crosses to the queue, so nothing encoded from a realtime or network
/// path is touched here. The parent directory is created on demand.
public final class RollingJSONLWriter: @unchecked Sendable {
    private let fileURL: URL
    private let maxBytes: Int
    /// All file access is confined to this queue.
    private let queue = DispatchQueue(label: "dev.jash90.MacAudioBridge.jsonl-writer", qos: .utility)

    public init(fileURL: URL, maxBytes: Int = 2 * 1024 * 1024) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
    }

    /// Appends one pre-encoded JSON line (a trailing newline is added).
    public func append(_ data: Data) {
        queue.async { [weak self] in
            self?.write(data)
        }
    }

    // MARK: - Queue-confined implementation

    private func write(_ data: Data) {
        var line = data
        line.append(0x0A)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
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
