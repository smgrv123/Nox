import XCTest

@testable import ModelProvisioning

/// `ModelsDirectory` resolves the user-discoverable models path and the reveal-in-Finder
/// affordance (docs/05-lld.md §2.7; User Story 16). Exercised against an **injected** temp
/// root — never the real `~/Library` — exactly like `StorageLayout`'s suite.
final class ModelsDirectoryTests: XCTestCase {

    private var container: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        container = fileManager.temporaryDirectory
            .appending(path: "aide-models-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: container)
    }

    private var sut: ModelsDirectory { ModelsDirectory(containerRoot: container) }

    private let descriptor = ModelDescriptor(
        repo: "ggerganov/whisper.cpp",
        pinnedRevision: "rev",
        filename: "ggml-base.en.bin",
        expectedSHA256: "deadbeef",
        byteSize: 10,
        onDiskRelativePath: "ggml-base.en.bin")

    func testModelsDirectoryIsAModelsSlotUnderTheInjectedRoot() {
        XCTAssertEqual(sut.url.lastPathComponent, "models")
        XCTAssertEqual(sut.url.deletingLastPathComponent(), container)
        XCTAssertTrue(sut.url.path.hasPrefix(container.path))
    }

    func testBlobURLResolvesTheDescriptorsOnDiskPath() {
        let blob = sut.blobURL(for: descriptor)
        XCTAssertEqual(blob.lastPathComponent, "ggml-base.en.bin")
        XCTAssertEqual(blob.deletingLastPathComponent(), sut.url)
    }

    func testDownloadStateURLIsTheHiddenBookkeepingFile() {
        XCTAssertEqual(sut.downloadStateURL.lastPathComponent, ".download-state.json")
        XCTAssertEqual(sut.downloadStateURL.deletingLastPathComponent(), sut.url)
    }

    func testRevealInFinderURLIsTheModelsDirectory() {
        XCTAssertEqual(sut.revealInFinderURL, sut.url)
    }

    func testCreateMaterialisesTheDirectory() throws {
        try sut.create(using: fileManager)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: sut.url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
