import Persistence
import XCTest

@testable import ModelProvisioning

/// The `.download-state.json` codec + store (docs/05-lld.md §2.7). The codec round-trips
/// the (offset, expected sha256) bookkeeping; the store persists it through
/// `Persistence.AtomicFileWriter`, so every mutation is a `*.tmp` + `rename(2)` (the §2.7
/// "Atomicity (MUST)") — reusing the audited writer rather than reinventing one.
final class DownloadStateTests: XCTestCase {

    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory
            .appending(path: "aide-dlstate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: directory)
    }

    private var stateURL: URL { directory.appending(path: ".download-state.json") }

    // MARK: - Codec round-trip

    func testCodecRoundTrips() throws {
        let state = DownloadState(
            offset: 1_234_567,
            expectedSHA256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002")
        let decoded = try DownloadStateCodec.decode(DownloadStateCodec.encode(state))
        XCTAssertEqual(decoded, state)
    }

    func testJSONUsesTheDocumentedSnakeCaseKeys() throws {
        let data = try DownloadStateCodec.encode(DownloadState(offset: 42, expectedSHA256: "beef"))
        let object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        XCTAssertEqual(Set(object.keys), ["offset", "expected_sha256"])
    }

    // MARK: - Atomic store (reuses Persistence.AtomicFileWriter)

    func testStoreSavesThenLoadsThroughTheAtomicWriter() throws {
        let store = DownloadStateStore(writer: AtomicFileWriter())
        let state = DownloadState(offset: 999, expectedSHA256: "cafe")

        try store.save(state, to: stateURL)

        XCTAssertEqual(try store.load(from: stateURL), state)
        // The atomic contract: the temp sibling is renamed into place, never left behind.
        let survivors = try fileManager.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(survivors, [".download-state.json"], "a temp sibling leaked: \(survivors)")
    }

    func testLoadReturnsNilWhenNoStateFileExists() throws {
        let store = DownloadStateStore(writer: AtomicFileWriter())
        XCTAssertNil(try store.load(from: stateURL))  // first run / after a restart wipe
    }
}
