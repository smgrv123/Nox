import XCTest

@testable import DangerousCommandScanner

final class ShellTokenizerBasicTests: XCTestCase {

    // MARK: - Plain words

    func testSingleWord() {
        XCTAssertEqual(ShellTokenizer.tokenize("ls"), [.word("ls")])
    }

    func testMultipleWords() {
        XCTAssertEqual(ShellTokenizer.tokenize("ls -la /tmp"), [.word("ls"), .word("-la"), .word("/tmp")])
    }

    func testLeadingAndTrailingWhitespace() {
        XCTAssertEqual(ShellTokenizer.tokenize("  echo hello  "), [.word("echo"), .word("hello")])
    }

    func testTabsAreWhitespace() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo\thello"), [.word("echo"), .word("hello")])
    }

    func testEmptyInput() {
        XCTAssertEqual(ShellTokenizer.tokenize(""), [])
    }

    func testWhitespaceOnlyInput() {
        XCTAssertEqual(ShellTokenizer.tokenize("   \t  "), [])
    }

    // MARK: - Single-quoted strings

    func testSingleQuotedString() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo 'hello world'"), [.word("echo"), .word("hello world")])
    }

    func testSingleQuotesPreserveBackslash() {
        XCTAssertEqual(ShellTokenizer.tokenize(#"echo 'no\nescape'"#), [.word("echo"), .word(#"no\nescape"#)])
    }

    func testSingleQuotesPreserveDollar() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo '$HOME'"), [.word("echo"), .word("$HOME")])
    }

    func testEmptySingleQuotes() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo ''"), [.word("echo"), .word("")])
    }

    func testUnterminatedSingleQuote() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo 'unterminated"), [.word("echo"), .opaque("'unterminated")])
    }

    // MARK: - Double-quoted strings

    func testDoubleQuotedString() {
        XCTAssertEqual(ShellTokenizer.tokenize(#"echo "hello world""#), [.word("echo"), .word("hello world")])
    }

    func testDoubleQuotesAllowEscapedBackslash() {
        XCTAssertEqual(ShellTokenizer.tokenize(#"echo "path\\here""#), [.word("echo"), .word(#"path\here"#)])
    }

    func testDoubleQuotesAllowEscapedDollar() {
        XCTAssertEqual(ShellTokenizer.tokenize(#"echo "\$HOME""#), [.word("echo"), .word("$HOME")])
    }

    func testDoubleQuotesAllowEscapedDoubleQuote() {
        XCTAssertEqual(ShellTokenizer.tokenize(#"echo "say \"hi\"""#), [.word("echo"), .word(#"say "hi""#)])
    }

    func testDoubleQuotesBackslashBeforeOrdinaryCharIsLiteral() {
        XCTAssertEqual(ShellTokenizer.tokenize(#"echo "\a""#), [.word("echo"), .word(#"\a"#)])
    }

    func testEmptyDoubleQuotes() {
        XCTAssertEqual(ShellTokenizer.tokenize(#"echo """#), [.word("echo"), .word("")])
    }

    func testUnterminatedDoubleQuote() {
        XCTAssertEqual(ShellTokenizer.tokenize(#"echo "unterminated"#), [.word("echo"), .opaque(#""unterminated"#)])
    }

    // MARK: - Backslash escapes outside quotes

    func testBackslashEscapeSpace() {
        XCTAssertEqual(ShellTokenizer.tokenize(#"echo hello\ world"#), [.word("echo"), .word("hello world")])
    }

    func testBackslashEscapeSpecialChar() {
        XCTAssertEqual(ShellTokenizer.tokenize(#"echo hello\;world"#), [.word("echo"), .word("hello;world")])
    }

    func testTrailingBackslashIsOpaque() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo \\"), [.word("echo"), .opaque("\\")])
    }

    // MARK: - Mixed quoting

    func testAdjacentQuotedSegments() {
        XCTAssertEqual(ShellTokenizer.tokenize(#"echo "hello "'world'"#), [.word("echo"), .word("hello world")])
    }

    func testQuotesConcatenatedWithUnquoted() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo hel'lo wo'rld"), [.word("echo"), .word("hello world")])
    }

    // MARK: - Null bytes (fail-closed)

    func testNullByteIsOpaque() {
        let tokens = ShellTokenizer.tokenize("echo \0 hello")
        XCTAssertEqual(tokens.count, 3)
        if case .opaque = tokens[1] {} else { XCTFail("null byte should produce an opaque token") }
    }

    // MARK: - Comments

    func testHashCommentIgnored() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo hi # this is a comment"), [.word("echo"), .word("hi")])
    }

    func testHashInMiddleOfWordIsNotComment() {
        XCTAssertEqual(ShellTokenizer.tokenize("echo foo#bar"), [.word("echo"), .word("foo#bar")])
    }

    // MARK: - Substitutions inside double quotes

    func testDollarParenInsideDoubleQuotes() {
        let tokens = ShellTokenizer.tokenize(#"echo "$(whoami)""#)
        XCTAssertEqual(
            tokens,
            [
                .word("echo"),
                .substitution(.dollarParen, [.word("whoami")]),
                .word(""),
            ])
    }

    func testBacktickInsideDoubleQuotes() {
        let tokens = ShellTokenizer.tokenize(#"echo "`date`""#)
        XCTAssertEqual(
            tokens,
            [
                .word("echo"),
                .substitution(.backtick, [.word("date")]),
                .word(""),
            ])
    }
}
