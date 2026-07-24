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

    func testForkBombIsConfirm() {
        guard case .confirm = scanner.scan(":(){ :|:& };:") else {
            return XCTFail("fork bomb must require confirmation")
        }
    }

    func testDdToDeviceIsConfirm() {
        guard case .confirm = scanner.scan("dd if=/dev/zero of=/dev/disk2 bs=1m") else {
            return XCTFail("dd to a device must require confirmation")
        }
    }

    // MARK: - Allow (safe commands)

    func testPlainCommandsAllowed() {
        XCTAssertEqual(scanner.scan("ls -la ~/Projects"), .allow)
        XCTAssertEqual(scanner.scan("git status"), .allow)
        XCTAssertEqual(scanner.scan("echo 'sudoku is fun'"), .allow)  // must not match 'sudo' inside 'sudoku'
        XCTAssertEqual(scanner.scan("rm build.log"), .allow)  // non-recursive rm is not flagged here
    }

    func testHardBlockBeatsConfirmWhenBothPresent() {
        // sudo (hard) co-occurs with rm -rf (confirm) — hard block must win.
        guard case .hardBlock = scanner.scan("sudo rm -rf /var") else {
            return XCTFail("hard block must take precedence over confirm")
        }
    }
}
