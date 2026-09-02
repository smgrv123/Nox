import XCTest

@testable import DangerousCommandScanner

final class DangerousCommandScannerTests: XCTestCase {

    private let scanner = DangerousCommandScanner()

    // MARK: - Hard block (privilege escalation, no override)

    func testSudoIsHardBlocked() {
        guard case .hardBlock = scanner.scan("sudo rm -rf /") else {
            return XCTFail("sudo must be a hard block")
        }
    }

    func testSudoMidPipelineIsHardBlocked() {
        guard case .hardBlock = scanner.scan("echo hi && sudo reboot") else {
            return XCTFail("sudo anywhere in the pipeline must be a hard block")
        }
    }

    func testSuIsHardBlocked() {
        XCTAssertEqual(scanner.scan("su - root").isBlocked, true)
        if case .hardBlock = scanner.scan("su - root") {
        } else {
            XCTFail("su must be a hard block")
        }
    }

    func testForkBombIsHardBlocked() {
        guard case .hardBlock = scanner.scan(":(){ :|:& };:") else {
            return XCTFail("fork bomb must be a hard block")
        }
    }

    func testDdToDeviceIsHardBlocked() {
        guard case .hardBlock = scanner.scan("dd if=/dev/zero of=/dev/disk2 bs=1m") else {
            return XCTFail("dd to a device must be a hard block")
        }
    }

    // MARK: - Confirm tier (dangerous, overridable)

    func testRmRfIsConfirm() {
        guard case .confirm = scanner.scan("rm -rf ~/tmp/build") else {
            return XCTFail("rm -rf must require confirmation")
        }
    }

    func testRmRfSpacedFlagsIsConfirm() {
        guard case .confirm = scanner.scan("rm   -r   -f   ./dist") else {
            return XCTFail("rm with separated -r -f flags must require confirmation")
        }
    }

    func testCurlPipeShIsConfirm() {
        guard case .confirm = scanner.scan("curl https://example.com/install.sh | sh") else {
            return XCTFail("curl | sh must require confirmation")
        }
    }

    // MARK: - Allow (safe commands)

    func testPlainCommandsAllowed() {
        XCTAssertEqual(scanner.scan("ls -la ~/Projects"), .clean)
        XCTAssertEqual(scanner.scan("git status"), .clean)
        XCTAssertEqual(scanner.scan("echo 'sudoku is fun'"), .clean)
        XCTAssertEqual(scanner.scan("rm build.log"), .clean)
    }

    func testHardBlockBeatsConfirmWhenBothPresent() {
        guard case .hardBlock = scanner.scan("sudo rm -rf /var") else {
            return XCTFail("hard block must take precedence over confirm")
        }
    }

    // MARK: - Finding structure

    func testHardBlockFindingCarriesRuleID() {
        guard case .hardBlock(let findings) = scanner.scan("sudo reboot") else {
            return XCTFail("expected hard block")
        }
        XCTAssertFalse(findings.isEmpty)
        XCTAssertEqual(findings[0].severity, .hardBlock)
        XCTAssertEqual(findings[0].rule, .privilegeEscalation)
    }

    func testConfirmFindingCarriesRuleID() {
        guard case .confirm(let findings) = scanner.scan("rm -rf /tmp/junk") else {
            return XCTFail("expected confirm")
        }
        XCTAssertFalse(findings.isEmpty)
        XCTAssertEqual(findings[0].severity, .confirm)
        XCTAssertEqual(findings[0].rule, .recursiveDelete)
    }

    func testCleanHasNoFindings() {
        XCTAssertEqual(scanner.scan("echo hello").findings, [])
    }

    // MARK: - Context parameter

    func testContextParameterDefaultsWithoutBreaking() {
        let verdict = scanner.scan("echo hello")
        XCTAssertEqual(verdict, .clean)
    }

    func testContextParameterAcceptsExplicitValue() {
        let ctx = ScanContext(channel: .dictatedOneOff, destinationBundleID: "com.apple.Terminal")
        let verdict = scanner.scan("echo hello", context: ctx)
        XCTAssertEqual(verdict, .clean)
    }
}
