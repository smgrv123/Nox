import XCTest

@testable import AppLifecycle

/// Single-instance decision (User Story 36). The effectful `NSRunningApplication`
/// lookup is not exercised here — only the pure verdict, with the running-app
/// snapshot injected for determinism (per specs/P1 §"Testing Decisions").
final class SingleInstanceGuardTests: XCTestCase {

    private let sut = SingleInstanceGuard()
    private let ownBundleID = "com.aide.Aide"
    private let ownPID: Int32 = 1000

    private func decide(_ running: [RunningInstance]) -> Bool {
        sut.isDuplicate(
            ownBundleIdentifier: ownBundleID,
            ownProcessIdentifier: ownPID,
            runningInstances: running)
    }

    // MARK: - Not a duplicate

    func testNoRunningAppsIsNotDuplicate() {
        XCTAssertFalse(decide([]))
    }

    func testOnlySelfInSnapshotIsNotDuplicate() {
        // Our own process shows up in the running-apps snapshot; matching bundle id
        // but the *same* PID must not count as a second instance.
        XCTAssertFalse(decide([RunningInstance(bundleIdentifier: ownBundleID, processIdentifier: ownPID)]))
    }

    func testOtherAppsWithDifferentBundleIDsAreNotDuplicates() {
        let others = [
            RunningInstance(bundleIdentifier: "com.apple.finder", processIdentifier: 42),
            RunningInstance(bundleIdentifier: "com.google.Chrome", processIdentifier: 77),
            RunningInstance(bundleIdentifier: ownBundleID, processIdentifier: ownPID),
        ]
        XCTAssertFalse(decide(others))
    }

    func testProcessWithoutBundleIdentifierIsIgnored() {
        XCTAssertFalse(decide([RunningInstance(bundleIdentifier: nil, processIdentifier: 5)]))
    }

    // MARK: - Duplicate

    func testAnotherInstanceWithSameBundleIDDifferentPIDIsDuplicate() {
        let running = [
            RunningInstance(bundleIdentifier: ownBundleID, processIdentifier: ownPID),
            RunningInstance(bundleIdentifier: ownBundleID, processIdentifier: 2000),
        ]
        XCTAssertTrue(decide(running))
    }

    func testExistingInstanceSeenBeforeSelfAppearsIsDuplicate() {
        // The newcomer may enumerate before its own process is listed: an original
        // instance alone in the snapshot must still be detected.
        XCTAssertTrue(decide([RunningInstance(bundleIdentifier: ownBundleID, processIdentifier: 2000)]))
    }

    func testDuplicateDetectedAmongUnrelatedApps() {
        let running = [
            RunningInstance(bundleIdentifier: "com.apple.finder", processIdentifier: 42),
            RunningInstance(bundleIdentifier: ownBundleID, processIdentifier: 2000),
            RunningInstance(bundleIdentifier: "com.google.Chrome", processIdentifier: 77),
        ]
        XCTAssertTrue(decide(running))
    }
}
