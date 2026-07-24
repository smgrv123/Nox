import Foundation

/// Failures raised by the persistence layer that aren't already a Foundation error.
public enum PersistenceError: Error, Equatable {
    /// `rename(2)` of the temp file over its destination failed with this `errno`.
    case renameFailed(code: Int32)
}

/// Atomic whole-file write for the documents docs/05-lld.md §2.7 marks **MUST**
/// atomic — `settings.json`, `dictionary.json`, a manifest, `.download-state.json`.
///
/// The write fully materialises a hidden `*.tmp` sibling in the *same* directory
/// (so the rename stays on one volume) and then `rename(2)`s it over the target.
/// Because materialise and rename are distinct steps and the rename is atomic on
/// APFS, a reader never sees a half-written file and an interrupted write leaves any
/// existing file untouched. Append-style logs (`app.log`, history JSONL) are a
/// different concern and don't use this — they append whole lines instead.
public struct AtomicFileWriter: Sendable {

    public init() {}

    public func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try data.write(to: temp)
        } catch {
            // Nothing was renamed into place, so the destination is still whatever
            // it was before; just clear the partial temp.
            try? FileManager.default.removeItem(at: temp)
            throw error
        }

        do {
            try Self.rename(from: temp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Atomic overwrite via POSIX `rename`, which replaces the destination in a
    /// single step whether or not it already exists.
    private static func rename(from source: URL, to destination: URL) throws {
        let succeeded = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return false }
                return Foundation.rename(sourcePath, destinationPath) == 0
            }
        }
        guard succeeded else {
            throw PersistenceError.renameFailed(code: errno)
        }
    }
}
