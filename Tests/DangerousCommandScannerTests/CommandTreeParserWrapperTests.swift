import XCTest

@testable import DangerousCommandScanner

final class CommandTreeParserWrapperTests: XCTestCase {

    private func parse(_ input: String) -> CommandTreeParser.ParseResult {
        CommandTreeParser.parse(ShellTokenizer.tokenize(input))
    }

    // MARK: - sh / bash / zsh -c

    func testShCParsesArgument() {
        let result = parse("sh -c 'rm -rf *'")
        XCTAssertEqual(result.nodes[0].argv, ["sh", "-c", "rm -rf *"])
        XCTAssertEqual(result.nodes[0].children.count, 1)
        XCTAssertEqual(result.nodes[0].children[0].argv, ["rm", "-rf", "*"])
        XCTAssertEqual(result.nodes[0].children[0].path, ["sh -c"])
    }

    func testBashCParsesArgument() {
        let result = parse("bash -c 'rm -rf *'")
        XCTAssertEqual(result.nodes[0].children.count, 1)
        XCTAssertEqual(result.nodes[0].children[0].argv, ["rm", "-rf", "*"])
        XCTAssertEqual(result.nodes[0].children[0].path, ["bash -c"])
    }

    func testZshCParsesArgument() {
        let result = parse("zsh -c 'rm -rf *'")
        XCTAssertEqual(result.nodes[0].children.count, 1)
        XCTAssertEqual(result.nodes[0].children[0].argv, ["rm", "-rf", "*"])
        XCTAssertEqual(result.nodes[0].children[0].path, ["zsh -c"])
    }

    // MARK: - eval

    func testEvalParsesArgument() {
        let result = parse("eval 'rm -rf *'")
        XCTAssertEqual(result.nodes[0].children.count, 1)
        XCTAssertEqual(result.nodes[0].children[0].argv, ["rm", "-rf", "*"])
        XCTAssertEqual(result.nodes[0].children[0].path, ["eval"])
    }

    // MARK: - xargs

    func testXargsParsesWrappedCommand() {
        let result = parse("find . -name '*.tmp' | xargs rm -rf")
        let xargsNode = result.nodes[1]
        XCTAssertEqual(xargsNode.argv, ["xargs", "rm", "-rf"])
        XCTAssertEqual(xargsNode.children.count, 1)
        XCTAssertEqual(xargsNode.children[0].argv, ["rm", "-rf"])
        XCTAssertEqual(xargsNode.children[0].path, ["pipe", "xargs"])
    }

    // MARK: - find -exec

    func testFindExecParsesWrappedCommand() {
        let result = parse("find . -exec rm -rf {} \\;")
        let node = result.nodes[0]
        XCTAssertEqual(node.argv[0], "find")
        XCTAssertEqual(node.children.count, 1)
        XCTAssertEqual(node.children[0].argv, ["rm", "-rf"])
        XCTAssertEqual(node.children[0].path, ["find -exec"])
    }

    func testFindExecWithUnescapedSemicolon() {
        let result = parse("find . -exec rm -rf {} ;")
        let findNodes = result.nodes.filter { $0.argv.first == "find" }
        XCTAssertEqual(findNodes.count, 1)
        XCTAssertEqual(findNodes[0].children.count, 1)
        XCTAssertEqual(findNodes[0].children[0].argv, ["rm", "-rf"])
    }

    // MARK: - env

    func testEnvParsesWrappedCommand() {
        let result = parse("env PATH=/usr/bin rm -rf /")
        let node = result.nodes[0]
        XCTAssertEqual(node.children.count, 1)
        XCTAssertEqual(node.children[0].argv, ["rm", "-rf", "/"])
        XCTAssertEqual(node.children[0].path, ["env"])
    }

    func testEnvWithMultipleVarsParsesCommand() {
        let result = parse("env A=1 B=2 rm -rf /")
        XCTAssertEqual(result.nodes[0].children[0].argv, ["rm", "-rf", "/"])
    }

    // MARK: - nohup / nice / time

    func testNohupParsesWrappedCommand() {
        let result = parse("nohup rm -rf /")
        XCTAssertEqual(result.nodes[0].children.count, 1)
        XCTAssertEqual(result.nodes[0].children[0].argv, ["rm", "-rf", "/"])
        XCTAssertEqual(result.nodes[0].children[0].path, ["nohup"])
    }

    func testNiceParsesWrappedCommand() {
        let result = parse("nice rm -rf /")
        XCTAssertEqual(result.nodes[0].children.count, 1)
        XCTAssertEqual(result.nodes[0].children[0].argv, ["rm", "-rf", "/"])
        XCTAssertEqual(result.nodes[0].children[0].path, ["nice"])
    }

    func testTimeParsesWrappedCommand() {
        let result = parse("time rm -rf /")
        XCTAssertEqual(result.nodes[0].children.count, 1)
        XCTAssertEqual(result.nodes[0].children[0].argv, ["rm", "-rf", "/"])
        XCTAssertEqual(result.nodes[0].children[0].path, ["time"])
    }

    // MARK: - ssh

    func testSshParsesRemoteCommand() {
        let result = parse("ssh host 'rm -rf /'")
        XCTAssertEqual(result.nodes[0].children.count, 1)
        XCTAssertEqual(result.nodes[0].children[0].argv, ["rm", "-rf", "/"])
        XCTAssertEqual(result.nodes[0].children[0].path, ["ssh"])
    }

    func testSshWithOptionsParsesRemoteCommand() {
        let result = parse("ssh -p 22 host 'rm -rf /'")
        XCTAssertEqual(result.nodes[0].children.count, 1)
        XCTAssertEqual(result.nodes[0].children[0].argv, ["rm", "-rf", "/"])
    }

    // MARK: - base64 decode | shell

    func testBase64DecodePipeShProducesFinding() {
        let result = parse("base64 -d | sh")
        XCTAssertFalse(result.findings.isEmpty)
        XCTAssertEqual(result.findings[0].rule, .obfuscatedExecution)
        XCTAssertEqual(result.findings[0].severity, .confirm)
    }

    func testBase64LongFlagPipeBashProducesFinding() {
        let result = parse("base64 --decode | bash")
        XCTAssertFalse(result.findings.isEmpty)
        XCTAssertEqual(result.findings[0].rule, .obfuscatedExecution)
    }

    func testBase64CapitalDPipeZshProducesFinding() {
        let result = parse("base64 -D | zsh")
        XCTAssertFalse(result.findings.isEmpty)
        XCTAssertEqual(result.findings[0].rule, .obfuscatedExecution)
    }

    // MARK: - Depth limit

    func testDepthLimitExceededProducesFinding() {
        let tokens = buildDeeplyNested(depth: 9)
        let result = CommandTreeParser.parse(tokens)
        let depthFindings = result.findings.filter { $0.rule == .unparseable }
        XCTAssertFalse(depthFindings.isEmpty, "Exceeding depth 8 must produce a finding")
    }

    func testAtExactMaxDepthStillParses() {
        let tokens = buildDeeplyNested(depth: 8)
        let result = CommandTreeParser.parse(tokens)
        let depthFindings = result.findings.filter { $0.rule == .unparseable }
        XCTAssertTrue(depthFindings.isEmpty, "Depth 8 is the limit — must not trigger")
    }

    // MARK: - Helpers

    private func buildDeeplyNested(depth: Int) -> [ShellToken] {
        if depth <= 0 { return [.word("echo"), .word("hello")] }
        return [.substitution(.dollarParen, buildDeeplyNested(depth: depth - 1))]
    }
}
