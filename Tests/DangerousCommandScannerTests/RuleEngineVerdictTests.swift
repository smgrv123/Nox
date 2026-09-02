import XCTest

@testable import DangerousCommandScanner

final class RuleEngineVerdictTests: XCTestCase {

    private let scanner = DangerousCommandScanner()

    // MARK: - Verdict combiner

    func testHardBlockBeatsConfirm() {
        guard case .hardBlock = scanner.scan("sudo rm -rf /var") else {
            return XCTFail("hardBlock must take precedence over confirm")
        }
    }

    func testConfirmBeatsClean() {
        guard case .confirm = scanner.scan("rm -rf ./dist") else {
            return XCTFail("confirm must take precedence over clean")
        }
    }

    func testMultipleFindingsCollected() {
        let verdict = scanner.scan("sudo rm -rf /")
        guard case .hardBlock(let findings) = verdict else {
            return XCTFail("expected hardBlock")
        }
        XCTAssertTrue(findings.count >= 1, "Should have at least one finding")
    }

    // MARK: - H7: Aide automation escalation

    func testManifestIDEscalatesConfirmToHardBlock() {
        let ctx = ScanContext(channel: .generatedScript, manifestID: "manifest-123")
        let verdict = scanner.scan("rm -rf /tmp/build", context: ctx)
        guard case .hardBlock(let findings) = verdict else {
            return XCTFail("manifestID should escalate C1 confirm to hardBlock")
        }
        XCTAssertTrue(
            findings.contains(where: { $0.rule == .aideAutomationEscalation }),
            "Should contain H7 escalation finding")
    }

    func testManifestIDEscalatesGitDestructiveToHardBlock() {
        let ctx = ScanContext(channel: .generatedScript, manifestID: "manifest-456")
        let verdict = scanner.scan("git push --force", context: ctx)
        guard case .hardBlock(let findings) = verdict else {
            return XCTFail("manifestID should escalate C9 to hardBlock")
        }
        XCTAssertTrue(
            findings.contains(where: { $0.rule == .aideAutomationEscalation }),
            "Should contain H7 escalation finding")
    }

    func testManifestIDDoesNotEscalateClean() {
        let ctx = ScanContext(channel: .generatedScript, manifestID: "manifest-789")
        XCTAssertEqual(scanner.scan("ls -la", context: ctx), .clean)
    }

    func testManifestIDDoesNotEscalateC11() {
        let ctx = ScanContext(
            channel: .dictatedOneOff,
            destinationBundleID: "com.apple.Terminal",
            manifestID: "manifest-xyz")
        let verdict = scanner.scan("echo hello", context: ctx)
        guard case .confirm(let findings) = verdict else {
            return XCTFail("C11 should remain confirm even with manifestID")
        }
        XCTAssertTrue(findings.contains(where: { $0.rule == .dictationIntoTerminal }))
    }

    func testManifestIDDoesNotEscalateC12() {
        var deep = "echo hi"
        for _ in 0..<10 {
            deep = "echo $(\(deep))"
        }
        let ctx = ScanContext(channel: .generatedScript, manifestID: "manifest-deep")
        let verdict = scanner.scan(deep, context: ctx)
        XCTAssertTrue(verdict.isBlocked, "Should still be blocked")
    }

    // MARK: - C11: Dictation into terminal

    func testDictationIntoTerminalConfirms() {
        let ctx = ScanContext(
            channel: .dictatedOneOff,
            destinationBundleID: "com.apple.Terminal")
        let verdict = scanner.scan("echo hello world", context: ctx)
        guard case .confirm(let findings) = verdict else {
            return XCTFail("Dictation into terminal should confirm")
        }
        XCTAssertTrue(findings.contains(where: { $0.rule == .dictationIntoTerminal }))
    }

    func testDictationIntoItermConfirms() {
        let ctx = ScanContext(
            channel: .dictatedOneOff,
            destinationBundleID: "com.googlecode.iterm2")
        let verdict = scanner.scan("ls", context: ctx)
        guard case .confirm(let findings) = verdict else {
            return XCTFail("Dictation into iTerm should confirm")
        }
        XCTAssertTrue(findings.contains(where: { $0.rule == .dictationIntoTerminal }))
    }

    func testDictationIntoWarpConfirms() {
        let ctx = ScanContext(
            channel: .dictatedOneOff,
            destinationBundleID: "dev.warp.Warp-Stable")
        guard case .confirm = scanner.scan("pwd", context: ctx) else {
            return XCTFail("Dictation into Warp should confirm")
        }
    }

    func testDictationIntoNonTerminalIsClean() {
        let ctx = ScanContext(
            channel: .dictatedOneOff,
            destinationBundleID: "com.apple.TextEdit")
        XCTAssertEqual(scanner.scan("echo hello", context: ctx), .clean)
    }

    func testNonDictationChannelDoesNotTriggerC11() {
        let ctx = ScanContext(
            channel: .preExecution,
            destinationBundleID: "com.apple.Terminal")
        XCTAssertEqual(scanner.scan("echo hello", context: ctx), .clean)
    }

    // MARK: - Safe commands

    func testLsIsClean() {
        XCTAssertEqual(scanner.scan("ls -la ~/Projects"), .clean)
    }

    func testGitStatusIsClean() {
        XCTAssertEqual(scanner.scan("git status"), .clean)
    }

    func testEchoSudokuIsClean() {
        XCTAssertEqual(scanner.scan("echo 'sudoku'"), .clean)
    }

    func testRmSingleFileIsClean() {
        XCTAssertEqual(scanner.scan("rm file.txt"), .clean)
    }

    func testCatFileIsClean() {
        XCTAssertEqual(scanner.scan("cat README.md"), .clean)
    }

    func testMkdirIsClean() {
        XCTAssertEqual(scanner.scan("mkdir -p /tmp/build"), .clean)
    }

    func testGitCommitIsClean() {
        XCTAssertEqual(scanner.scan("git commit -m 'fix: typo'"), .clean)
    }

    func testPipeSafeCommandsIsClean() {
        XCTAssertEqual(scanner.scan("cat file.txt | grep foo | wc -l"), .clean)
    }
}
