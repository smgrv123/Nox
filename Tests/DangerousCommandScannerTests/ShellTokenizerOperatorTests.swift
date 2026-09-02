import XCTest

@testable import DangerousCommandScanner

final class ShellTokenizerOperatorTests: XCTestCase {

    // MARK: - Operators

    func testPipeOperator() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("ls | grep foo"),
            [.word("ls"), .operator(.pipe), .word("grep"), .word("foo")]
        )
    }

    func testDoublePipeOperator() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("false || echo fallback"),
            [.word("false"), .operator(.or), .word("echo"), .word("fallback")]
        )
    }

    func testDoubleAmpersandOperator() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("true && echo yes"),
            [.word("true"), .operator(.and), .word("echo"), .word("yes")]
        )
    }

    func testAmpersandBackground() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("sleep 10 &"),
            [.word("sleep"), .word("10"), .operator(.background)]
        )
    }

    func testSemicolon() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("cd /tmp; ls"),
            [.word("cd"), .word("/tmp"), .operator(.semi), .word("ls")]
        )
    }

    func testParentheses() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("(echo hi)"),
            [.operator(.leftParen), .word("echo"), .word("hi"), .operator(.rightParen)]
        )
    }

    func testBraces() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("{ echo hi; }"),
            [.operator(.leftBrace), .word("echo"), .word("hi"), .operator(.semi), .operator(.rightBrace)]
        )
    }

    func testRedirectOut() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("echo hi > out.txt"),
            [.word("echo"), .word("hi"), .operator(.redirectOut), .word("out.txt")]
        )
    }

    func testRedirectAppend() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("echo hi >> out.txt"),
            [.word("echo"), .word("hi"), .operator(.redirectAppend), .word("out.txt")]
        )
    }

    func testRedirectIn() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("sort < input.txt"),
            [.word("sort"), .operator(.redirectIn), .word("input.txt")]
        )
    }

    func testNewlineSeparatesCommands() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("echo hi\necho bye"),
            [.word("echo"), .word("hi"), .operator(.newline), .word("echo"), .word("bye")]
        )
    }

    // MARK: - Command substitutions

    func testDollarParenSubstitution() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("echo $(whoami)"),
            [.word("echo"), .substitution(.dollarParen, [.word("whoami")])]
        )
    }

    func testNestedDollarParenSubstitution() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("echo $(echo $(whoami))"),
            [
                .word("echo"),
                .substitution(.dollarParen, [.word("echo"), .substitution(.dollarParen, [.word("whoami")])]),
            ]
        )
    }

    func testBacktickSubstitution() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("echo `whoami`"),
            [.word("echo"), .substitution(.backtick, [.word("whoami")])]
        )
    }

    func testUnterminatedBacktickIsOpaque() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo `whoami"), [.word("echo"), .opaque("`whoami")])
    }

    func testUnterminatedDollarParenIsOpaque() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo $(whoami"), [.word("echo"), .opaque("$(whoami")])
    }

    func testDollarParenInsideSingleQuotesIsLiteral() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo '$(rm -rf /)'"), [.word("echo"), .word("$(rm -rf /)")])
    }

    // MARK: - ANSI-C quoting

    func testAnsiCQuotingNewline() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo $'hello\\nworld'"), [.word("echo"), .word("hello\nworld")])
    }

    func testAnsiCQuotingTab() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo $'col1\\tcol2'"), [.word("echo"), .word("col1\tcol2")])
    }

    func testAnsiCQuotingBackslash() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo $'back\\\\slash'"), [.word("echo"), .word("back\\slash")])
    }

    func testAnsiCQuotingSingleQuote() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo $'it\\'s'"), [.word("echo"), .word("it's")])
    }

    func testAnsiCQuotingHex() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo $'\\x41'"), [.word("echo"), .word("A")])
    }

    func testAnsiCQuotingOctal() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo $'\\101'"), [.word("echo"), .word("A")])
    }

    func testAnsiCQuotingUnicodeShort() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo $'\\u0041'"), [.word("echo"), .word("A")])
    }

    func testAnsiCQuotingUnterminatedIsOpaque() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo $'unterminated"), [.word("echo"), .opaque("$'unterminated")])
    }

    // MARK: - Complex pipelines

    func testComplexPipeline() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("cat file.txt | grep 'pattern' | wc -l"),
            [
                .word("cat"), .word("file.txt"), .operator(.pipe), .word("grep"), .word("pattern"), .operator(.pipe),
                .word("wc"), .word("-l"),
            ]
        )
    }

    func testAndOrChain() {
        XCTAssertEqual(
            ShellTokenizer.tokenize("mkdir /tmp/foo && cd /tmp/foo || echo fail"),
            [
                .word("mkdir"), .word("/tmp/foo"), .operator(.and), .word("cd"), .word("/tmp/foo"), .operator(.or),
                .word("echo"), .word("fail"),
            ]
        )
    }
}
