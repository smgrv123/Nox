import XCTest

@testable import DangerousCommandScanner

final class PathRestrictionTests: XCTestCase {

    // MARK: - Lexical path resolution

    func testTildeExpandsToHome() {
        let resolved = PathRestriction.resolveLexically("~/Documents")
        let home = PathRestriction.homeDirectory
        XCTAssertEqual(resolved, "\(home)/Documents")
    }

    func testBareTildeExpandsToHome() {
        let resolved = PathRestriction.resolveLexically("~")
        XCTAssertEqual(resolved, PathRestriction.homeDirectory)
    }

    func testDotDotResolved() {
        let resolved = PathRestriction.resolveLexically("/usr/local/../bin")
        XCTAssertEqual(resolved, "/usr/bin")
    }

    func testDotResolved() {
        let resolved = PathRestriction.resolveLexically("/usr/./bin")
        XCTAssertEqual(resolved, "/usr/bin")
    }

    func testMultipleDotDotsResolved() {
        let resolved = PathRestriction.resolveLexically("/a/b/c/../../d")
        XCTAssertEqual(resolved, "/a/d")
    }

    func testDotDotAtRootStaysAtRoot() {
        let resolved = PathRestriction.resolveLexically("/../../../etc")
        XCTAssertEqual(resolved, "/etc")
    }

    func testAbsolutePathPassedThrough() {
        let resolved = PathRestriction.resolveLexically("/usr/local/bin")
        XCTAssertEqual(resolved, "/usr/local/bin")
    }

    func testNoFilesystemAccess() {
        let resolved = PathRestriction.resolveLexically("~/nonexistent/../real")
        let home = PathRestriction.homeDirectory
        XCTAssertEqual(resolved, "\(home)/real")
    }

    // MARK: - Path classification

    func testPathOutsideHome() {
        let result = PathRestriction.classify("/usr/local/bin")
        XCTAssertEqual(result, .outsideHome)
    }

    func testEtcIsOutsideHome() {
        let result = PathRestriction.classify("/etc/hosts")
        XCTAssertEqual(result, .outsideHome)
    }

    func testRootIsOutsideHome() {
        let result = PathRestriction.classify("/")
        XCTAssertEqual(result, .outsideHome)
    }

    func testSshDirIsSystemCritical() {
        let home = PathRestriction.homeDirectory
        let result = PathRestriction.classify("\(home)/.ssh/id_rsa")
        XCTAssertEqual(result, .systemCritical)
    }

    func testGnupgDirIsSystemCritical() {
        let home = PathRestriction.homeDirectory
        let result = PathRestriction.classify("\(home)/.gnupg/pubring.kbx")
        XCTAssertEqual(result, .systemCritical)
    }

    func testLaunchAgentsIsSystemCritical() {
        let home = PathRestriction.homeDirectory
        let result = PathRestriction.classify(
            "\(home)/Library/LaunchAgents/com.evil.plist")
        XCTAssertEqual(result, .systemCritical)
    }

    func testPreferencesIsSystemCritical() {
        let home = PathRestriction.homeDirectory
        let result = PathRestriction.classify(
            "\(home)/Library/Preferences/com.apple.foo.plist")
        XCTAssertEqual(result, .systemCritical)
    }

    func testKeychainsIsSystemCritical() {
        let home = PathRestriction.homeDirectory
        let result = PathRestriction.classify(
            "\(home)/Library/Keychains/login.keychain-db")
        XCTAssertEqual(result, .systemCritical)
    }

    func testNormalHomePathIsAllowed() {
        let home = PathRestriction.homeDirectory
        let result = PathRestriction.classify("\(home)/Downloads/junk")
        XCTAssertEqual(result, .allowed)
    }

    func testHomeDesktopIsAllowed() {
        let home = PathRestriction.homeDirectory
        let result = PathRestriction.classify("\(home)/Desktop/file.txt")
        XCTAssertEqual(result, .allowed)
    }

    // MARK: - Glob detection

    func testStarIsGlob() {
        XCTAssertTrue(PathRestriction.containsGlob("*"))
    }

    func testDoubleStarIsGlob() {
        XCTAssertTrue(PathRestriction.containsGlob("**"))
    }

    func testQuestionMarkIsGlob() {
        XCTAssertTrue(PathRestriction.containsGlob("file?.txt"))
    }

    func testPathWithEmbeddedStarIsGlob() {
        XCTAssertTrue(PathRestriction.containsGlob("/tmp/*.log"))
    }

    func testNormalPathIsNotGlob() {
        XCTAssertFalse(PathRestriction.containsGlob("/tmp/foo.log"))
    }
}

// MARK: - Integration via scanner

final class PathRestrictionScannerTests: XCTestCase {

    private let scanner = DangerousCommandScanner()

    // MARK: - rm outside $HOME → C7

    func testRmOutsideHomeConfirmsC7() {
        assertConfirm("rm -rf /usr/local/bin", rule: .outsideHome)
    }

    func testRmEtcConfirmsC7() {
        assertConfirm("rm /etc/passwd", rule: .outsideHome)
    }

    // MARK: - rm in system-critical zone → C7

    func testRmSshKeyConfirmsC7() {
        assertConfirm("rm -rf ~/.ssh/id_rsa", rule: .outsideHome)
    }

    func testRmGnupgConfirmsC7() {
        assertConfirm("rm ~/.gnupg/pubring.kbx", rule: .outsideHome)
    }

    func testRmLaunchAgentConfirmsC7() {
        assertConfirm(
            "rm ~/Library/LaunchAgents/com.evil.plist",
            rule: .outsideHome)
    }

    // MARK: - rm inside $HOME normal path → no C7

    func testRmDownloadsNoC7() {
        let verdict = scanner.scan("rm -rf ~/Downloads/junk")
        let c7Findings = verdict.findings.filter { $0.rule == .outsideHome }
        XCTAssertTrue(
            c7Findings.isEmpty,
            "rm -rf ~/Downloads/junk should NOT trigger C7, got: \(c7Findings)")
    }

    // MARK: - Write redirect outside $HOME → C7

    func testWriteRedirectToEtcHostsConfirmsC7() {
        assertConfirm("echo data > /etc/hosts", rule: .outsideHome)
    }

    func testAppendRedirectOutsideHomeConfirmsC7() {
        assertConfirm("echo data >> /var/log/syslog", rule: .outsideHome)
    }

    // MARK: - mv / cp outside $HOME → C7

    func testMvToOutsideHomeConfirmsC7() {
        assertConfirm("mv file.txt /usr/local/bin/file", rule: .outsideHome)
    }

    func testCpToOutsideHomeConfirmsC7() {
        assertConfirm("cp file.txt /opt/configs/file", rule: .outsideHome)
    }

    // MARK: - dd with path outside $HOME → C7

    func testDdOfOutsideHomeConfirmsC7() {
        assertConfirm(
            "dd if=input.img of=/opt/backup.img bs=4k",
            rule: .outsideHome)
    }

    // MARK: - Glob fail-closed → C7

    func testRmStarConfirmsC7() {
        assertConfirm("rm -rf *", rule: .outsideHome)
    }

    func testRmDoubleStarConfirmsC7() {
        assertConfirm("rm **", rule: .outsideHome)
    }

    func testRmQuestionMarkGlobConfirmsC7() {
        assertConfirm("rm file?.txt", rule: .outsideHome)
    }

    // MARK: - Helpers

    private func assertConfirm(
        _ command: String,
        rule: RuleID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let verdict = scanner.scan(command)
        guard verdict.isBlocked else {
            XCTFail(
                "Expected blocked verdict for: \(command), got: \(verdict)",
                file: file, line: line)
            return
        }
        XCTAssertTrue(
            verdict.findings.contains(where: { $0.rule == rule }),
            "Expected rule \(rule) in findings for: \(command), got: \(verdict.findings.map(\.rule))",
            file: file,
            line: line)
    }
}
