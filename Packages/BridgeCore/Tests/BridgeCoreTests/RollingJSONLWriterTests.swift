import Foundation
import Testing
@testable import BridgeCore

struct RollingJSONLWriterTests {
    private enum WaitForError: Error {
        case timeout
    }

    private func makeTempFileURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollingJSONLWriterTests-\(UUID().uuidString)")
        return directory.appendingPathComponent("nested/stats.jsonl")
    }

    /// The writer is async on its own utility queue; poll the file until the
    /// condition holds (or fail after `timeout`).
    @discardableResult
    private func waitUntil(
        _ url: URL,
        timeout: TimeInterval = 5,
        _ condition: (String) -> Bool
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8), condition(contents) {
                return contents
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw WaitForError.timeout
    }

    @Test("Creates the directory and appends one JSON line per call")
    func appendsLinesAndCreatesDirectory() throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let writer = RollingJSONLWriter(fileURL: url, maxBytes: 1024 * 1024)

        writer.append(Data("{\"n\":1}".utf8))
        writer.append(Data("{\"n\":2}".utf8))
        let contents = try waitUntil(url) { $0.split(separator: "\n").count == 2 }

        let lines = contents.split(separator: "\n")
        #expect(lines[0] == "{\"n\":1}")
        #expect(lines[1] == "{\"n\":2}")
    }

    @Test("Past the byte cap the oldest half of the lines is dropped")
    func trimsOldestHalfPastCap() throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        // Each line is 13 bytes ("line-000001\n"); the cap fits ~10 lines.
        let writer = RollingJSONLWriter(fileURL: url, maxBytes: 130)

        for index in 0..<100 {
            writer.append(Data(String(format: "line-%06d", index).utf8))
        }
        // Every append is followed by its trim on the same serial queue, so
        // once the last line has landed the final trim has run too.
        let contents = try waitUntil(url) {
            $0.hasSuffix("line-000099\n")
                && $0.split(separator: "\n", omittingEmptySubsequences: true).count < 100
        }

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // Trimmed to roughly the cap, keeping the newest lines: the first
        // survivor is exactly as old as the dropped count says.
        #expect(lines.count > 0)
        #expect(lines.count < 100)
        #expect(lines.first == String(format: "line-%06d", 100 - lines.count))
        #expect(lines.last == "line-000099")
        #expect(contents.utf8.count <= 130 + 64)
    }
}
