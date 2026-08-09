import CryptoKit
import XCTest

@testable import ModelProvisioning

/// `ModelVerification` decides whether a provisioned blob matches its pinned
/// `ModelDescriptor` (docs/05-lld.md §2.7; User Story 14). It carries the
/// Dangerous-Command Scanner's posture: a false `verified` on a corrupt/mismatched
/// file is a **defect**, never a tolerated edge — so the tampered-byte case asserts
/// `!= .verified` **directly**.
final class ModelVerificationTests: XCTestCase {

    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory
            .appending(path: "aide-verify-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: directory)
    }

    /// Real SHA-256 hex of `data`, computed independently of the SUT so the test is a
    /// genuine oracle rather than a tautology against the module's own hasher.
    private func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func write(_ data: Data, named name: String = "model.bin") throws -> URL {
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func descriptor(sha: String, byteSize: Int64) -> ModelDescriptor {
        ModelDescriptor(
            repo: "ggerganov/whisper.cpp",
            pinnedRevision: "rev",
            filename: "model.bin",
            expectedSHA256: sha,
            byteSize: byteSize,
            onDiskRelativePath: "model.bin")
    }

    // MARK: - verified / mismatch / absent over fixture bytes

    func testVerifiedWhenFileMatchesDescriptor() throws {
        let bytes = Data("aide speech model fixture payload".utf8)
        let url = try write(bytes)
        let sut = descriptor(sha: sha256Hex(of: bytes), byteSize: Int64(bytes.count))

        XCTAssertEqual(ModelVerification.verify(fileAt: url, descriptor: sut), .verified)
    }

    func testTamperedByteIsNeverVerified() throws {
        // Same length, one flipped byte ⇒ a different hash. This is the scanner-serious
        // invariant: verification MUST NOT return `.verified` for a mismatched file.
        var bytes = Data("aide speech model fixture payload".utf8)
        let sut = descriptor(sha: sha256Hex(of: bytes), byteSize: Int64(bytes.count))
        bytes[0] ^= 0xFF  // flip one bit-pattern; length unchanged
        let url = try write(bytes)

        let result = ModelVerification.verify(fileAt: url, descriptor: sut)

        XCTAssertNotEqual(result, .verified, "a tampered file was reported verified — a defect")
        guard case .mismatch(.hash) = result else {
            return XCTFail("expected a hash mismatch, got \(result)")
        }
    }

    func testTruncatedFileIsASizeMismatch() throws {
        let bytes = Data("aide speech model fixture payload".utf8)
        let sut = descriptor(sha: sha256Hex(of: bytes), byteSize: Int64(bytes.count))
        let url = try write(bytes.prefix(4))  // shorter than the descriptor claims

        let result = ModelVerification.verify(fileAt: url, descriptor: sut)

        XCTAssertNotEqual(result, .verified)
        guard case .mismatch(.size) = result else {
            return XCTFail("expected a size mismatch, got \(result)")
        }
    }

    func testAbsentWhenFileMissing() {
        let missing = directory.appending(path: "not-downloaded.bin")
        let sut = descriptor(sha: "deadbeef", byteSize: 10)
        XCTAssertEqual(ModelVerification.verify(fileAt: missing, descriptor: sut), .absent)
    }

    // MARK: - The streamed-hash path (what the resumable downloader will use)

    func testStreamedHashVerifiesRealBaseEnDescriptor() {
        // Uses the already-pinned base.en values from docs/native-deps.md as a real
        // descriptor — proving the type carries production pins — without a multi-GB file.
        let sut = ModelDescriptor.baseEnFixture
        XCTAssertEqual(
            ModelVerification.verify(
                streamedSHA256: sut.expectedSHA256,
                byteCount: sut.byteSize,
                descriptor: sut),
            .verified)
    }

    func testStreamedHashRejectsAWrongDigest() {
        let sut = ModelDescriptor.baseEnFixture
        let result = ModelVerification.verify(
            streamedSHA256: String(sut.expectedSHA256.reversed()),  // valid hex, wrong value
            byteCount: sut.byteSize,
            descriptor: sut)

        XCTAssertNotEqual(result, .verified)
        guard case .mismatch(.hash) = result else {
            return XCTFail("expected a hash mismatch, got \(result)")
        }
    }

    // MARK: - An unpinned (placeholder) descriptor must never verify anything

    func testUnpinnedDescriptorNeverVerifies() throws {
        // Production descriptors carry placeholder SHA/size until P5 pins them. A blob
        // must NEVER be reported verified against an unpinned descriptor — the safe
        // (re-provision) direction. Even a 0-byte file against a 0-byte placeholder fails.
        let empty = try write(Data(), named: "empty.bin")
        let placeholder = descriptor(sha: "", byteSize: 0)
        XCTAssertNotEqual(ModelVerification.verify(fileAt: empty, descriptor: placeholder), .verified)
    }
}
