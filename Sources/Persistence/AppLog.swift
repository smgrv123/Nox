import Foundation

/// The plain-text, human-readable application log at `logs/app.log`
/// (User Story 35; docs/05-lld.md §2.6 / §9). Every failure the app surfaces is
/// also recorded here as a timestamped line. Strictly local — no telemetry, no
/// network, nothing leaves the machine (docs/03-architecture.md §10.1).
///
/// Lines are `<ISO-8601 timestamp> [LEVEL] <message>` and appended in order. The
/// clock is injected so tests are deterministic; a lock keeps interleaved writes
/// from other threads whole. Logging is not a hot path, so a simple synchronous
/// append is fine.
public final class AppLog: @unchecked Sendable {

    /// Severity, rendered verbatim between brackets. Mirrors the `os.Logger`
    /// levels the app shell already uses.
    public enum Level: String, Sendable {
        case info = "INFO"
        case notice = "NOTICE"
        case warning = "WARNING"
        case error = "ERROR"
    }

    private let fileURL: URL
    private let now: () -> Date
    private let lock = NSLock()

    public init(fileURL: URL, now: @escaping () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    /// Append one timestamped line. Failures to write are swallowed: the log is the
    /// last-resort sink, and its own I/O error has nowhere else to go.
    public func log(_ message: String, level: Level = .info) {
        let line = "\(Timestamp.string(from: now())) [\(level.rawValue)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // No file yet — the first line creates it.
            try? data.write(to: fileURL)
        }
    }
}
