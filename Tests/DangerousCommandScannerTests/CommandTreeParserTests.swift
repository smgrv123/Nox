import XCTest

@testable import DangerousCommandScanner

final class CommandTreeParserTests: XCTestCase {

    private func parse(_ input: String) -> CommandTreeParser.ParseResult {
        CommandTreeParser.parse(ShellTokenizer.tokenize(input))
    }

    // MARK: - Simple commands

    func testEmptyInputProducesNoNodes() {
        let result = parse("")
        XCTAssertTrue(result.nodes.isEmpty)
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testSingleCommand() {
        let result = parse("ls")
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes[0].argv, ["ls"])
        XCTAssertEqual(result.nodes[0].path, [])
        XCTAssertTrue(result.nodes[0].children.isEmpty)
    }

    func testCommandWithArguments() {
        let result = parse("ls -la /tmp")
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes[0].argv, ["ls", "-la", "/tmp"])
    }

    // MARK: - Pipeline operator splitting

    func testPipeSplitsIntoNodes() {
        let result = parse("ls | grep foo")
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(result.nodes[0].argv, ["ls"])
        XCTAssertEqual(result.nodes[1].argv, ["grep", "foo"])
        XCTAssertEqual(result.nodes[1].path, ["pipe"])
    }

    func testAndOperatorSplitsNodes() {
        let result = parse("cd /tmp && ls")
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(result.nodes[0].argv, ["cd", "/tmp"])
        XCTAssertEqual(result.nodes[1].argv, ["ls"])
    }

    func testOrOperatorSplitsNodes() {
        let result = parse("make || echo failed")
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(result.nodes[0].argv, ["make"])
        XCTAssertEqual(result.nodes[1].argv, ["echo", "failed"])
    }

    func testSemicolonSplitsNodes() {
        let result = parse("echo a; echo b")
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(result.nodes[0].argv, ["echo", "a"])
        XCTAssertEqual(result.nodes[1].argv, ["echo", "b"])
    }

    func testNewlineSplitsNodes() {
        let result = parse("echo a\necho b")
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(result.nodes[0].argv, ["echo", "a"])
        XCTAssertEqual(result.nodes[1].argv, ["echo", "b"])
    }

    func testMultipleOperatorsSplit() {
        let result = parse("echo a | grep a && echo ok; echo done")
        XCTAssertEqual(result.nodes.count, 4)
        XCTAssertEqual(result.nodes[0].argv, ["echo", "a"])
        XCTAssertEqual(result.nodes[1].argv, ["grep", "a"])
        XCTAssertEqual(result.nodes[2].argv, ["echo", "ok"])
        XCTAssertEqual(result.nodes[3].argv, ["echo", "done"])
    }

    // MARK: - Command substitutions

    func testDollarParenSubstitutionProducesChild() {
        let result = parse("echo $(rm -rf /)")
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes[0].argv, ["echo"])
        XCTAssertEqual(result.nodes[0].children.count, 1)
        XCTAssertEqual(result.nodes[0].children[0].argv, ["rm", "-rf", "/"])
        XCTAssertEqual(result.nodes[0].children[0].path, ["$()"])
    }

    func testBacktickSubstitutionProducesChild() {
        let result = parse("echo `rm -rf /`")
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes[0].argv, ["echo"])
        XCTAssertEqual(result.nodes[0].children.count, 1)
        XCTAssertEqual(result.nodes[0].children[0].argv, ["rm", "-rf", "/"])
        XCTAssertEqual(result.nodes[0].children[0].path, ["`...`"])
    }

    // MARK: - Path tracking

    func testNestedSubstitutionPathAccumulates() {
        let result = parse("echo $(sh -c 'rm -rf /')")
        let substChild = result.nodes[0].children[0]
        XCTAssertEqual(substChild.argv, ["sh", "-c", "rm -rf /"])
        XCTAssertEqual(substChild.path, ["$()"])
        XCTAssertEqual(substChild.children[0].argv, ["rm", "-rf", "/"])
        XCTAssertEqual(substChild.children[0].path, ["$()", "sh -c"])
    }

    // MARK: - Redirections excluded from argv

    func testOutputRedirectExcludedFromArgv() {
        let result = parse("echo hello > out.txt")
        XCTAssertEqual(result.nodes[0].argv, ["echo", "hello"])
    }

    func testInputRedirectExcludedFromArgv() {
        let result = parse("sort < input.txt")
        XCTAssertEqual(result.nodes[0].argv, ["sort"])
    }

    func testAppendRedirectExcludedFromArgv() {
        let result = parse("echo hello >> log.txt")
        XCTAssertEqual(result.nodes[0].argv, ["echo", "hello"])
    }

    // MARK: - Flattening

    func testAllNodesFlattensEntireTree() {
        let result = parse("echo $(rm -rf /); ls")
        let all = result.allNodes
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].argv, ["echo"])
        XCTAssertEqual(all[1].argv, ["rm", "-rf", "/"])
        XCTAssertEqual(all[2].argv, ["ls"])
    }

    func testFlattenedIncludesDeeplyNestedChildren() {
        let result = parse("nohup sh -c 'rm -rf /'")
        let all = result.allNodes
        XCTAssertTrue(all.contains(where: { $0.argv == ["rm", "-rf", "/"] }))
    }
}
