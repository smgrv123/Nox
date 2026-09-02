import XCTest

@testable import DangerousCommandScanner

final class CorpusHardBlockTests: XCTestCase {

    private let scanner = DangerousCommandScanner()

    // MARK: - H1: Privilege escalation — multiple spellings

    func testSudoReboot() {
        assertHardBlock("sudo reboot", rule: .privilegeEscalation)
    }

    func testSudoShutdown() {
        assertHardBlock("sudo shutdown -h now", rule: .privilegeEscalation)
    }

    func testSuDashRoot() {
        assertHardBlock("su - root", rule: .privilegeEscalation)
    }

    func testDoasHalt() {
        assertHardBlock("doas halt", rule: .privilegeEscalation)
    }

    func testPkexecReboot() {
        assertHardBlock("pkexec reboot", rule: .privilegeEscalation)
    }

    func testSudoInMiddleOfPipeline() {
        assertHardBlock("cat /etc/hosts | sudo tee /etc/resolv.conf", rule: .privilegeEscalation)
    }

    func testSudoAfterAndChain() {
        assertHardBlock("echo ok && sudo rm -rf /var", rule: .privilegeEscalation)
    }

    func testSudoInSubshell() {
        assertHardBlock("$(sudo whoami)", rule: .privilegeEscalation)
    }

    func testSudoInsideShC() {
        assertHardBlock("sh -c 'sudo reboot'", rule: .privilegeEscalation)
    }

    func testSudoInsideEval() {
        assertHardBlock("eval 'sudo halt'", rule: .privilegeEscalation)
    }

    func testSudoInsideBashC() {
        assertHardBlock("bash -c 'sudo rm -rf /'", rule: .privilegeEscalation)
    }

    // MARK: - H2: SIP / security policy

    func testCsrutilDisable() {
        assertHardBlock("csrutil disable", rule: .sipSecurityPolicy)
    }

    func testSpctlDisable() {
        assertHardBlock("spctl --master-disable", rule: .sipSecurityPolicy)
    }

    func testNvramSet() {
        assertHardBlock("nvram boot-args=-v", rule: .sipSecurityPolicy)
    }

    func testBputilDisable() {
        assertHardBlock("bputil -nkc", rule: .sipSecurityPolicy)
    }

    // MARK: - H3: Credential exfiltration

    func testSecurityDumpKeychain() {
        assertHardBlock("security dump-keychain -d login.keychain", rule: .credentialExfiltration)
    }

    func testSecurityFindPasswordDashW() {
        assertHardBlock("security find-generic-password -w -s foo", rule: .credentialExfiltration)
    }

    // MARK: - H4: launchctl tampering

    func testLaunchctlBootoutAide() {
        assertHardBlock("launchctl bootout gui/501 com.aide.agent", rule: .launchctlTampering)
    }

    func testLaunchctlLoadSystemDaemon() {
        assertHardBlock(
            "launchctl load /System/Library/LaunchDaemons/com.apple.ftp",
            rule: .launchctlTampering)
    }

    // MARK: - H5: Disk destruction

    func testDdToDevice() {
        assertHardBlock("dd if=/dev/zero of=/dev/disk2 bs=1m", rule: .diskDestruction)
    }

    func testDiskutilErase() {
        assertHardBlock("diskutil erase /dev/disk2", rule: .diskDestruction)
    }

    func testMkfsExt4() {
        assertHardBlock("mkfs.ext4 /dev/sda1", rule: .diskDestruction)
    }

    func testNewfsHfs() {
        assertHardBlock("newfs_hfs /dev/disk2s1", rule: .diskDestruction)
    }

    func testAsrRestore() {
        assertHardBlock("asr restore --source img.dmg --target /dev/disk2", rule: .diskDestruction)
    }

    // MARK: - H6: Fork bomb

    func testClassicForkBomb() {
        assertHardBlock(":(){ :|:& };:", rule: .forkBomb)
    }

    // MARK: - Multi-layer nesting depth

    func testSshSudoReboot() {
        assertHardBlock("ssh host 'sudo reboot'", rule: .privilegeEscalation)
    }

    func testEnvSudoRm() {
        assertHardBlock("env sudo rm -rf /", rule: .privilegeEscalation)
    }

    func testTimeSudoReboot() {
        assertHardBlock("time sudo reboot", rule: .privilegeEscalation)
    }

    func testBashCWithNestedEvalCatchesSudo() {
        assertHardBlock("bash -c 'sudo reboot'", rule: .privilegeEscalation)
    }

    // MARK: - Helpers

    private func assertHardBlock(
        _ command: String,
        rule: RuleID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let verdict = scanner.scan(command)
        guard case .hardBlock(let findings) = verdict else {
            XCTFail(
                "Expected .hardBlock for: \(command), got: \(verdict)",
                file: file, line: line)
            return
        }
        XCTAssertTrue(
            findings.contains(where: { $0.rule == rule }),
            "Expected rule \(rule) in findings for: \(command)",
            file: file, line: line)
    }
}
