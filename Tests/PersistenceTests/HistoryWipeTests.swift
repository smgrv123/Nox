import XCTest

@testable import Persistence

/// Wipe-scope correctness (User Story 34; docs/05-lld.md §2.6 "Retention & wipe").
///
/// This is the safety-relevant test for the one-click "Wipe all history": a wipe
/// MUST clear transcripts + command history + script execution logs and **nothing
/// else** — settings, scripts, dictionary, the skill registry, grammar, launchd
/// snapshots, models, and non-history logs (`app.log`, `sidecar.log`, and
/// `calibration.jsonl` unless separately chosen) must survive untouched. A wipe
/// that deletes too much is a data-loss bug; per the P1 rule we never weaken this.
///
/// Two layers are exercised: the pure `isInScope` policy predicate (no I/O — the
/// testable heart) and the full `perform` against an **injected** temp tree so we
/// never touch the user's real `~/Library/Application Support/Aide/`.
final class HistoryWipeTests: XCTestCase {

    private var root: URL!
    private let fileManager = FileManager.default

    private var layout: StorageLayout { StorageLayout(root: root) }
    private var wipe: HistoryWipe { HistoryWipe(layout: layout) }

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appending(path: "aide-wipe-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    // MARK: - Pure policy predicate (no I/O)

    func testInScopePathsAreHistoryCommandsAndScriptExecLogs() {
        // §2.6: history/, logs/exec/, and loose logs/*.out|.err are cleared.
        let inScope = [
            layout.historyFile(for: Date(timeIntervalSince1970: 1_753_347_124)),
            layout.historyDirectory.appending(path: "commands-2026-07-21.jsonl"),
            layout.execLogsDirectory.appending(path: "prod_sanity_check-2026-07-21.jsonl"),
            layout.execLogsDirectory.appending(path: "prod_sanity_check-2026-07-21T09-00-00.out"),
            layout.execLogsDirectory.appending(path: "prod_sanity_check-2026-07-21T09-00-00.err"),
            layout.logsDirectory.appending(path: "stray.out"),
            layout.logsDirectory.appending(path: "stray.err"),
        ]
        for url in inScope {
            XCTAssertTrue(wipe.isInScope(url), "\(url.lastPathComponent) should be wiped")
        }
    }

    func testPreservedPathsAreSettingsScriptsDictionaryAndNonHistoryLogs() {
        // §2.6: a default wipe never touches settings/scripts/dictionary, and spares
        // the non-history logs (app.log, sidecar.log) and calibration.jsonl.
        let preserved = [
            layout.settingsFile,
            layout.dictionaryFile,
            layout.scriptsDirectory.appending(path: "prod_sanity_check.sh"),
            layout.registryDirectory.appending(path: "open_application.json"),
            layout.grammarDirectory.appending(path: "router.gbnf"),
            layout.launchdDirectory.appending(path: "com.aide.automation.plist"),
            layout.modelsDirectory.appending(path: "qwen3-8b-q4_k_m.gguf"),
            layout.appLogFile,
            layout.sidecarLogFile,
            layout.calibrationLogFile,
        ]
        for url in preserved {
            XCTAssertFalse(wipe.isInScope(url), "\(url.lastPathComponent) must be preserved")
        }
    }

    func testCalibrationLogIsSparedByDefaultButInScopeWhenChosen() {
        // §2.6: calibration.jsonl is a distinct file so a wipe can *optionally* spare it.
        XCTAssertFalse(wipe.isInScope(layout.calibrationLogFile))
        XCTAssertTrue(
            wipe.isInScope(layout.calibrationLogFile, options: .init(includeCalibrationLog: true)))
    }

    // MARK: - Full wipe against an injected temp tree

    func testWipeRemovesInScopeFilesAndPreservesEverythingElse() throws {
        try layout.createTree()

        // Populate every relevant slot with a marker file.
        let inScope = [
            layout.historyFile(for: Date(timeIntervalSince1970: 1_753_347_124)),
            layout.execLogsDirectory.appending(path: "run-2026-07-21.jsonl"),
            layout.execLogsDirectory.appending(path: "run-2026-07-21T09-00-00.out"),
            layout.execLogsDirectory.appending(path: "run-2026-07-21T09-00-00.err"),
            layout.logsDirectory.appending(path: "stray.out"),
        ]
        let preserved = [
            layout.settingsFile,
            layout.dictionaryFile,
            layout.scriptsDirectory.appending(path: "prod_sanity_check.sh"),
            layout.registryDirectory.appending(path: "open_application.json"),
            layout.grammarDirectory.appending(path: "router.gbnf"),
            layout.launchdDirectory.appending(path: "com.aide.automation.plist"),
            layout.modelsDirectory.appending(path: "model.gguf"),
            layout.appLogFile,
            layout.sidecarLogFile,
            layout.calibrationLogFile,
        ]
        for url in inScope + preserved {
            try Data("x".utf8).write(to: url)
        }

        let removed = try wipe.perform()

        for url in inScope {
            XCTAssertFalse(
                fileManager.fileExists(atPath: url.path), "\(url.lastPathComponent) should be gone")
        }
        for url in preserved {
            XCTAssertTrue(
                fileManager.fileExists(atPath: url.path), "\(url.lastPathComponent) must survive")
        }
        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), Set(inScope.map(\.lastPathComponent)))

        // The slot directories themselves persist (emptied, not deleted).
        for slot in [layout.historyDirectory, layout.execLogsDirectory, layout.logsDirectory] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(fileManager.fileExists(atPath: slot.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testWipeSparesCalibrationByDefaultButRemovesWhenChosen() throws {
        try layout.createTree()
        try Data("cal".utf8).write(to: layout.calibrationLogFile)

        _ = try wipe.perform()
        XCTAssertTrue(
            fileManager.fileExists(atPath: layout.calibrationLogFile.path),
            "default wipe must spare calibration.jsonl")

        _ = try wipe.perform(options: .init(includeCalibrationLog: true))
        XCTAssertFalse(
            fileManager.fileExists(atPath: layout.calibrationLogFile.path),
            "an opted-in wipe removes calibration.jsonl")
    }

    func testWipeIsIdempotentAndTolerantOfAMissingTree() throws {
        // No createTree(): the slots don't exist yet. A wipe must not throw and must
        // report nothing removed — a failure here would be a silent-failure regression.
        XCTAssertEqual(try wipe.perform(), [])

        try layout.createTree()
        try Data("h".utf8).write(to: layout.historyFile(for: Date()))
        XCTAssertEqual(try wipe.perform().count, 1)
        XCTAssertEqual(try wipe.perform(), [], "a second wipe over an empty tree removes nothing")
    }

    func testPlannedRemovalsMatchesWhatPerformDeletesAndDoesNotMutate() throws {
        try layout.createTree()
        let historyFile = layout.historyFile(for: Date(timeIntervalSince1970: 1_753_347_124))
        try Data("h".utf8).write(to: historyFile)
        try Data("e".utf8).write(to: layout.execLogsDirectory.appending(path: "run.jsonl"))

        let planned = wipe.plannedRemovals()
        // Planning is read-only: the files are still there afterwards.
        XCTAssertTrue(fileManager.fileExists(atPath: historyFile.path))

        let removed = try wipe.perform()
        XCTAssertEqual(Set(planned.map(\.path)), Set(removed.map(\.path)))
    }
}
