import XCTest

@testable import DangerousCommandScanner

final class RuleEngineHardBlockTests: XCTestCase {

    private let scanner = DangerousCommandScanner()

    // MARK: - H1: Privilege escalation

    func testSudoHardBlocks() {
        assertHardBlock("sudo rm -rf /", rule: .privilegeEscalation)
    }

    func testSuHardBlocks() {
        assertHardBlock("su - root", rule: .privilegeEscalation)
    }

    func testDoasHardBlocks() {
        assertHardBlock("doas reboot", rule: .privilegeEscalation)
    }

    func testPkexecHardBlocks() {
        assertHardBlock("pkexec visudo", rule: .privilegeEscalation)
    }

    func testSudoeditHardBlocks() {
        assertHardBlock("sudoedit /etc/hosts", rule: .privilegeEscalation)
    }

    func testSudoNestedInPipeHardBlocks() {
        assertHardBlock("echo hi | sudo tee /etc/hosts", rule: .privilegeEscalation)
    }

    func testSudoNestedInSubshellHardBlocks() {
        assertHardBlock("$(sudo whoami)", rule: .privilegeEscalation)
    }

    func testSudoNestedInShCHardBlocks() {
        assertHardBlock("sh -c 'sudo reboot'", rule: .privilegeEscalation)
    }

    func testSudoInAndChainHardBlocks() {
        assertHardBlock("echo ok && sudo halt", rule: .privilegeEscalation)
    }

    // MARK: - H2: SIP / security policy tampering

    func testCsrutilHardBlocks() {
        assertHardBlock("csrutil disable", rule: .sipSecurityPolicy)
    }

    func testSpctlHardBlocks() {
        assertHardBlock("spctl --master-disable", rule: .sipSecurityPolicy)
    }

    func testNvramWriteHardBlocks() {
        assertHardBlock("nvram boot-args=-v", rule: .sipSecurityPolicy)
    }

    func testNvramDeleteHardBlocks() {
        assertHardBlock("nvram -d boot-args", rule: .sipSecurityPolicy)
    }

    func testNvramReadIsClean() {
        XCTAssertEqual(scanner.scan("nvram -p"), .clean)
    }

    func testBputilHardBlocks() {
        assertHardBlock("bputil -nkc", rule: .sipSecurityPolicy)
    }

    // MARK: - H3: Credential exfiltration

    func testSecurityDumpKeychainHardBlocks() {
        assertHardBlock("security dump-keychain -d login.keychain", rule: .credentialExfiltration)
    }

    func testSecurityFindPasswordWithWFlagHardBlocks() {
        assertHardBlock(
            "security find-generic-password -w -s myservice",
            rule: .credentialExfiltration)
    }

    func testSecurityFindPasswordWithoutWIsClean() {
        XCTAssertEqual(
            scanner.scan("security find-generic-password -s myservice"),
            .clean)
    }

    // MARK: - H4: launchctl tampering

    func testLaunchctlLoadAideJobHardBlocks() {
        assertHardBlock(
            "launchctl load com.aide.agent",
            rule: .launchctlTampering)
    }

    func testLaunchctlUnloadSystemDaemonHardBlocks() {
        assertHardBlock(
            "launchctl unload /System/Library/LaunchDaemons/com.apple.ftp",
            rule: .launchctlTampering)
    }

    func testLaunchctlBootoutSystemHardBlocks() {
        assertHardBlock(
            "launchctl bootout system/com.apple.ftp",
            rule: .launchctlTampering)
    }

    // MARK: - H5: Disk destruction

    func testDdToDeviceHardBlocks() {
        assertHardBlock(
            "dd if=/dev/zero of=/dev/disk2 bs=1m",
            rule: .diskDestruction)
    }

    func testDiskutilEraseHardBlocks() {
        assertHardBlock("diskutil eraseDisk JHFS+ Untitled /dev/disk2", rule: .diskDestruction)
    }

    func testDiskutilReformatHardBlocks() {
        assertHardBlock("diskutil reformat /dev/disk2", rule: .diskDestruction)
    }

    func testDiskutilPartitionDiskHardBlocks() {
        assertHardBlock(
            "diskutil partitionDisk /dev/disk2 GPT JHFS+ Main 100%",
            rule: .diskDestruction)
    }

    func testMkfsHardBlocks() {
        assertHardBlock("mkfs.ext4 /dev/sda1", rule: .diskDestruction)
    }

    func testNewfsHardBlocks() {
        assertHardBlock("newfs_hfs /dev/disk2s1", rule: .diskDestruction)
    }

    func testAsrRestoreHardBlocks() {
        assertHardBlock(
            "asr restore --source image.dmg --target /dev/disk2",
            rule: .diskDestruction)
    }

    // MARK: - H6: Fork bomb

    func testForkBombHardBlocks() {
        assertHardBlock(":(){ :|:& };:", rule: .forkBomb)
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
            XCTFail("Expected .hardBlock for: \(command), got: \(verdict)", file: file, line: line)
            return
        }
        XCTAssertTrue(
            findings.contains(where: { $0.rule == rule }),
            "Expected rule \(rule) in findings for: \(command), got: \(findings.map(\.rule))",
            file: file,
            line: line)
    }
}
