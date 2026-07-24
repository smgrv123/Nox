import XCTest

@testable import Persistence

/// Storage-tree layout + idempotent creation (User Story 33; docs/05-lld.md §2.7).
///
/// The layout is pure path computation and its tree creation is exercised against a
/// throwaway temp directory — never the real `~/Library/Application Support/Aide/`
/// (per specs/P1 §"Testing Decisions": the root URL is injected for determinism).
final class StorageLayoutTests: XCTestCase {

    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appending(path: "aide-layout-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private var sut: StorageLayout { StorageLayout(root: root) }

    // MARK: - Path computation (pure)

    func testEveryDirectorySlotIsUnderRoot() {
        for directory in sut.directories {
            XCTAssertTrue(
                directory.path.hasPrefix(root.path),
                "\(directory.lastPathComponent) escaped the storage root")
        }
    }

    func testDirectorySlotsMatchTheLLDTree() {
        // docs/05-lld.md §2.7: the root is created first, then these slots.
        XCTAssertEqual(sut.directories.first, root)
        let slots = Set(sut.directories.dropFirst().map(\.lastPathComponent))
        XCTAssertEqual(
            slots,
            ["registry", "scripts", "grammar", "history", "logs", "exec", "launchd", "models"])
    }

    func testSettingsAndDictionaryAreFileSlotsNotDirectories() {
        // §2.7 places settings.json / dictionary.json as files at the root; those
        // documents are owned by later phases, so the tree must not pre-create them.
        XCTAssertEqual(sut.settingsFile.lastPathComponent, "settings.json")
        XCTAssertEqual(sut.dictionaryFile.lastPathComponent, "dictionary.json")
        XCTAssertFalse(sut.directories.contains(sut.settingsFile))
        XCTAssertFalse(sut.directories.contains(sut.dictionaryFile))
    }

    func testNamedLogFilesResolveUnderLogs() {
        XCTAssertEqual(sut.appLogFile.lastPathComponent, "app.log")
        XCTAssertEqual(sut.appLogFile.deletingLastPathComponent().lastPathComponent, "logs")
        XCTAssertEqual(sut.calibrationLogFile.lastPathComponent, "calibration.jsonl")
        XCTAssertEqual(sut.execLogsDirectory.lastPathComponent, "exec")
    }

    func testHistoryFileIsDatePartitioned() {
        // §2.6: history/commands-YYYY-MM-DD.jsonl, dated in UTC.
        let date = Date(timeIntervalSince1970: 1_753_347_124)  // 2025-07-24T09:12:04Z
        let file = sut.historyFile(for: date)
        XCTAssertEqual(file.lastPathComponent, "commands-2025-07-24.jsonl")
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "history")
    }

    // MARK: - Tree creation (I/O against a temp root)

    func testCreateTreeMaterialisesEverySlot() throws {
        try sut.createTree(using: fileManager)
        for directory in sut.directories {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                "missing slot: \(directory.lastPathComponent)")
            XCTAssertTrue(isDirectory.boolValue, "\(directory.lastPathComponent) is not a directory")
        }
    }

    func testCreateTreeIsIdempotentAndPreservesExistingData() throws {
        try sut.createTree(using: fileManager)

        // Drop a file into an existing slot; a second createTree must not disturb it.
        let marker = sut.registryDirectory.appending(path: "keep.json")
        try Data("{}".utf8).write(to: marker)

        XCTAssertNoThrow(try sut.createTree(using: fileManager))
        XCTAssertTrue(fileManager.fileExists(atPath: marker.path))
    }
}
