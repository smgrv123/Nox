import Foundation

/// Shared append-or-create primitive for the Persistence module's log types
/// (`AppLog`, `HistoryLog`; docs/05-lld.md §2.6). Opens `fileURL` for writing and
/// seeks to the end to append; if the file doesn't exist yet, this is the first
/// write and creates it directly.
///
/// Always throws on I/O failure rather than swallowing it — callers that treat
/// their log as a best-effort, last-resort sink (`AppLog`) wrap the call in
/// `try?`; callers that need to propagate failures (`HistoryLog`) let it throw.
enum FileAppender {

    /// Append `data` to `fileURL`, creating the file first if it doesn't exist.
    static func append(_ data: Data, to fileURL: URL) throws {
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL)
        }
    }
}
