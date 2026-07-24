import XCTest

@testable import Persistence

/// Atomic whole-file write (docs/05-lld.md §2.7 "Atomicity (MUST)").
///
/// A reader must never observe a partial file and an interrupted write must never
/// corrupt an existing one. True mid-write interruption isn't unit-testable without
/// killing the process, so these assert the observable proxies the temp-then-rename
/// design guarantees: exact content, all-or-nothing replacement (short over long
/// leaves no stale tail), no leftover temp siblings, and fail-closed on a bad path.
final class AtomicFileWriterTests: XCTestCase {

    private var directory: URL!
    private let fileManager = FileManager.default
    private let sut = AtomicFileWriter()

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory
            .appending(path: "aide-atomic-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: directory)
    }

    private func target(_ name: String = "settings.json") -> URL {
        directory.appending(path: name)
    }

    func testWritePersistsExactContent() throws {
        let url = target()
        let payload = Data(#"{"schema_version":1}"#.utf8)
        try sut.write(payload, to: url)
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testOverwriteFullyReplacesLongerContentWithShorter() throws {
        // The canonical no-corruption regression: an in-place truncating writer
        // that crashed mid-flush would leave a tail of the old, longer bytes.
        let url = target()
        try sut.write(Data(String(repeating: "A", count: 4096).utf8), to: url)
        let shorter = Data("B".utf8)
        try sut.write(shorter, to: url)
        XCTAssertEqual(try Data(contentsOf: url), shorter)
    }

    func testWriteLeavesNoTempResidue() throws {
        try sut.write(Data("x".utf8), to: target())
        let survivors = try fileManager.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(survivors, ["settings.json"], "a temp sibling was left behind: \(survivors)")
    }

    func testFailedWriteToMissingDirectoryCreatesNothing() {
        // Fail-closed: writing under a directory that does not exist must throw and
        // leave no partial file or temp behind.
        let missing = directory.appending(path: "does-not-exist", directoryHint: .isDirectory)
        let url = missing.appending(path: "settings.json")
        XCTAssertThrowsError(try sut.write(Data("data".utf8), to: url))
        XCTAssertFalse(fileManager.fileExists(atPath: missing.path))
    }

    func testFailedOverwriteLeavesExistingFileIntact() throws {
        // Point the second write at a URL whose parent is a *file*, not a directory,
        // so the temp write fails — the previously written file must be untouched.
        let keep = target("keep.json")
        let original = Data("original".utf8)
        try sut.write(original, to: keep)

        let blockedParent = target("keep.json")  // a file, so this can't be a directory
        let doomed = blockedParent.appending(path: "child.json")
        XCTAssertThrowsError(try sut.write(Data("new".utf8), to: doomed))
        XCTAssertEqual(try Data(contentsOf: keep), original)
    }
}
