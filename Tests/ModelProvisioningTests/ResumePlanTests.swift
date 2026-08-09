import XCTest

@testable import ModelProvisioning

/// `ResumePlan` is the pure resumable-download math (docs/05-lld.md §2.7; User Story 13):
/// from the recorded `.download-state.json` + the partial file's actual size, decide the
/// next byte-range to request, or `restart` (inconsistent/oversized/mismatched state), or
/// `complete` (already whole → no download). All synthetic, small sizes — no real blob.
final class ResumePlanTests: XCTestCase {

    private let sha = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"

    private func descriptor(byteSize: Int64) -> ModelDescriptor {
        ModelDescriptor(
            repo: "r",
            pinnedRevision: "rev",
            filename: "m.bin",
            expectedSHA256: sha,
            byteSize: byteSize,
            onDiskRelativePath: "m.bin")
    }

    // MARK: - resume: correct next byte-range

    func testFreshDownloadRequestsTheWholeFile() {
        let plan = ResumePlan.compute(
            descriptor: descriptor(byteSize: 1000),
            state: nil,
            partialFileSize: 0)

        guard case .resume(let range) = plan else { return XCTFail("expected resume, got \(plan)") }
        XCTAssertEqual(range.offset, 0)
        XCTAssertEqual(range.totalSize, 1000)
        XCTAssertEqual(range.count, 1000)
        XCTAssertEqual(range.httpRangeHeaderValue, "bytes=0-999")
    }

    func testResumesFromTheRecordedOffset() {
        let plan = ResumePlan.compute(
            descriptor: descriptor(byteSize: 1000),
            state: DownloadState(offset: 400, expectedSHA256: sha),
            partialFileSize: 400)

        guard case .resume(let range) = plan else { return XCTFail("expected resume, got \(plan)") }
        XCTAssertEqual(range.offset, 400)
        XCTAssertEqual(range.count, 600)
        XCTAssertEqual(range.httpRangeHeaderValue, "bytes=400-999")
    }

    // MARK: - complete: no download requested

    func testCompleteWhenPartialAlreadyWholeWithMatchingState() {
        let plan = ResumePlan.compute(
            descriptor: descriptor(byteSize: 1000),
            state: DownloadState(offset: 1000, expectedSHA256: sha),
            partialFileSize: 1000)
        XCTAssertEqual(plan, .complete)
    }

    func testCompleteWhenFullFilePresentWithNoState() {
        // Skip-if-present-and-verified (User Story 17): a whole-sized file with no
        // bookkeeping is complete; integrity is confirmed separately by ModelVerification.
        let plan = ResumePlan.compute(
            descriptor: descriptor(byteSize: 1000),
            state: nil,
            partialFileSize: 1000)
        XCTAssertEqual(plan, .complete)
    }

    // MARK: - restart: inconsistent / oversized / mismatched state

    func testRestartWhenStatePinsADifferentModel() {
        let plan = ResumePlan.compute(
            descriptor: descriptor(byteSize: 1000),
            state: DownloadState(offset: 400, expectedSHA256: "cafe"),  // wrong pin
            partialFileSize: 400)
        XCTAssertEqual(plan, .restart)
    }

    func testRestartWhenRecordedOffsetExceedsTheWholeFile() {
        let plan = ResumePlan.compute(
            descriptor: descriptor(byteSize: 1000),
            state: DownloadState(offset: 2000, expectedSHA256: sha),  // oversized
            partialFileSize: 2000)
        XCTAssertEqual(plan, .restart)
    }

    func testRestartWhenOffsetDisagreesWithBytesOnDisk() {
        let plan = ResumePlan.compute(
            descriptor: descriptor(byteSize: 1000),
            state: DownloadState(offset: 400, expectedSHA256: sha),
            partialFileSize: 300)  // file shorter than the recorded offset
        XCTAssertEqual(plan, .restart)
    }

    func testRestartWhenPartialFileHasNoBookkeeping() {
        // A partial-sized file with no state we can trust ⇒ start over (safe direction).
        let plan = ResumePlan.compute(
            descriptor: descriptor(byteSize: 1000),
            state: nil,
            partialFileSize: 300)
        XCTAssertEqual(plan, .restart)
    }
}
