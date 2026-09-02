import XCTest

@testable import DangerousCommandScanner

final class CorpusSafeCommandTests: XCTestCase {

    private let scanner = DangerousCommandScanner()

    // MARK: - Basic safe commands

    func testLs() {
        XCTAssertEqual(scanner.scan("ls"), .clean)
    }

    func testLsLa() {
        XCTAssertEqual(scanner.scan("ls -la ~/Projects"), .clean)
    }

    func testGitStatus() {
        XCTAssertEqual(scanner.scan("git status"), .clean)
    }

    func testGitDiff() {
        XCTAssertEqual(scanner.scan("git diff HEAD~1"), .clean)
    }

    func testGitLog() {
        XCTAssertEqual(scanner.scan("git log --oneline -20"), .clean)
    }

    func testGitCommit() {
        XCTAssertEqual(scanner.scan("git commit -m 'fix: update readme'"), .clean)
    }

    func testGitPull() {
        XCTAssertEqual(scanner.scan("git pull origin main"), .clean)
    }

    func testGitPushNormal() {
        XCTAssertEqual(scanner.scan("git push origin main"), .clean)
    }

    func testEchoSimple() {
        XCTAssertEqual(scanner.scan("echo hello world"), .clean)
    }

    func testCatFile() {
        XCTAssertEqual(scanner.scan("cat README.md"), .clean)
    }

    func testPwd() {
        XCTAssertEqual(scanner.scan("pwd"), .clean)
    }

    func testMkdir() {
        XCTAssertEqual(scanner.scan("mkdir -p build/output"), .clean)
    }

    func testCp() {
        XCTAssertEqual(scanner.scan("cp file.txt backup.txt"), .clean)
    }

    func testMvSingleFile() {
        XCTAssertEqual(scanner.scan("mv old.txt new.txt"), .clean)
    }

    func testTouch() {
        XCTAssertEqual(scanner.scan("touch newfile.txt"), .clean)
    }

    // MARK: - rm (safe variants)

    func testRmSingleFile() {
        XCTAssertEqual(scanner.scan("rm file.txt"), .clean)
    }

    func testRmBuildLog() {
        XCTAssertEqual(scanner.scan("rm build.log"), .clean)
    }

    // MARK: - grep / find (safe)

    func testGrepRecursive() {
        XCTAssertEqual(scanner.scan("grep -r pattern ."), .clean)
    }

    func testGrepWithFileName() {
        XCTAssertEqual(scanner.scan("grep -n 'TODO' src/*.swift"), .clean)
    }

    func testFindByName() {
        XCTAssertEqual(scanner.scan("find . -name '*.log'"), .clean)
    }

    func testFindByType() {
        XCTAssertEqual(scanner.scan("find /tmp -type f -name '*.txt'"), .clean)
    }

    // MARK: - Network commands (safe)

    func testCurlSimple() {
        XCTAssertEqual(scanner.scan("curl https://example.com"), .clean)
    }

    func testCurlOutput() {
        XCTAssertEqual(scanner.scan("curl -o file.zip https://example.com/file.zip"), .clean)
    }

    func testWgetFile() {
        XCTAssertEqual(scanner.scan("wget https://example.com/archive.tar.gz"), .clean)
    }

    // MARK: - Words containing keywords (false-positive check)

    func testSudokuIsSafe() {
        XCTAssertEqual(scanner.scan("echo 'sudoku is fun'"), .clean)
    }

    func testPseudocodeIsSafe() {
        XCTAssertEqual(scanner.scan("echo pseudocode"), .clean)
    }

    func testSurnameIsSafe() {
        XCTAssertEqual(scanner.scan("echo surname"), .clean)
    }

    func testFormatIsSafe() {
        XCTAssertEqual(scanner.scan("echo format"), .clean)
    }

    func testDiscussIsSafe() {
        XCTAssertEqual(scanner.scan("echo discuss"), .clean)
    }

    func testSudoInQuotedStringIsSafe() {
        XCTAssertEqual(scanner.scan("echo 'sudoku is fun'"), .clean)
    }

    func testRmInEchoStringIsSafe() {
        XCTAssertEqual(scanner.scan("echo 'please rm the old logs'"), .clean)
    }

    // MARK: - Build tools / package managers

    func testNpmInstall() {
        XCTAssertEqual(scanner.scan("npm install express"), .clean)
    }

    func testPipInstall() {
        XCTAssertEqual(scanner.scan("pip install requests"), .clean)
    }

    func testBrewInstall() {
        XCTAssertEqual(scanner.scan("brew install jq"), .clean)
    }

    func testMake() {
        XCTAssertEqual(scanner.scan("make -j8"), .clean)
    }

    func testSwiftBuild() {
        XCTAssertEqual(scanner.scan("swift build"), .clean)
    }

    func testSwiftTest() {
        XCTAssertEqual(scanner.scan("swift test"), .clean)
    }

    // MARK: - Miscellaneous safe

    func testDateCommand() {
        XCTAssertEqual(scanner.scan("date +%Y-%m-%d"), .clean)
    }

    func testWhoami() {
        XCTAssertEqual(scanner.scan("whoami"), .clean)
    }

    func testDfDashH() {
        XCTAssertEqual(scanner.scan("df -h"), .clean)
    }

    func testDuDashSh() {
        XCTAssertEqual(scanner.scan("du -sh ."), .clean)
    }

    func testHeadFile() {
        XCTAssertEqual(scanner.scan("head -20 main.swift"), .clean)
    }

    func testTailFile() {
        XCTAssertEqual(scanner.scan("tail -f /var/log/system.log"), .clean)
    }

    func testWcDashL() {
        XCTAssertEqual(scanner.scan("wc -l README.md"), .clean)
    }

    func testSortFile() {
        XCTAssertEqual(scanner.scan("sort names.txt"), .clean)
    }

    func testUniq() {
        XCTAssertEqual(scanner.scan("sort names.txt | uniq"), .clean)
    }

    func testSedInPlace() {
        XCTAssertEqual(scanner.scan("sed -i '' 's/foo/bar/g' file.txt"), .clean)
    }

    func testAwk() {
        XCTAssertEqual(scanner.scan("awk '{print $1}' data.csv"), .clean)
    }

    func testChainedSafeCommands() {
        XCTAssertEqual(scanner.scan("cd /tmp && ls -la && pwd"), .clean)
    }

    func testPipelineSafe() {
        XCTAssertEqual(scanner.scan("cat data.txt | grep pattern | wc -l"), .clean)
    }
}
