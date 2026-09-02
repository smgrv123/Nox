import XCTest

@testable import DangerousCommandScanner

final class CorpusObfuscationTests: XCTestCase {

    private let scanner = DangerousCommandScanner()

    // MARK: - Backslash-escape normalization (tokenizer)

    func testBackslashEscapedRmIsCaught() {
        let verdict = scanner.scan(#"r\m -rf /"#)
        XCTAssertTrue(
            verdict.isBlocked,
            #"r\m -rf / should be caught via backslash normalization"#)
    }

    func testBackslashEscapedSudoIsCaught() {
        let verdict = scanner.scan(#"s\udo reboot"#)
        XCTAssertTrue(
            verdict.isBlocked,
            #"s\udo reboot should be caught via backslash normalization"#)
    }

    // MARK: - ANSI-C hex decode ($'\x..')

    func testAnsiCHexSudoReboot() {
        let verdict = scanner.scan("$'\\x73\\x75\\x64\\x6f' reboot")
        XCTAssertTrue(
            verdict.isBlocked,
            "$'\\x73\\x75\\x64\\x6f' (sudo) reboot should be hard-blocked")
        if case .hardBlock(let findings) = verdict {
            XCTAssertTrue(findings.contains { $0.rule == .privilegeEscalation })
        }
    }

    func testAnsiCHexRm() {
        let verdict = scanner.scan("$'\\x72\\x6d' -rf /")
        XCTAssertTrue(
            verdict.isBlocked,
            "$'\\x72\\x6d' (rm) -rf / should be caught")
    }

    func testAnsiCOctalSudo() {
        let verdict = scanner.scan("$'\\163\\165\\144\\157' reboot")
        XCTAssertTrue(
            verdict.isBlocked,
            "Octal-encoded sudo should be caught")
    }

    // MARK: - base64 obfuscation

    func testEchoBase64DecodePipeSh() {
        let verdict = scanner.scan("echo cm0gLXJmIC8= | base64 -d | sh")
        XCTAssertTrue(
            verdict.isBlocked,
            "base64-encoded rm -rf / piped to sh should be caught")
    }

    func testBase64DecodePipeBash() {
        let verdict = scanner.scan("base64 --decode | bash")
        XCTAssertTrue(
            verdict.isBlocked,
            "base64 --decode | bash should be flagged as obfuscation")
    }

    func testBase64CapitalDPipeZsh() {
        let verdict = scanner.scan("base64 -D | zsh")
        XCTAssertTrue(verdict.isBlocked)
    }

    // MARK: - openssl obfuscation

    func testOpensslEncDecodePipeSh() {
        let verdict = scanner.scan("openssl enc -d -aes-256-cbc -in payload | sh")
        XCTAssertTrue(
            verdict.isBlocked,
            "openssl enc -d piped to sh should be flagged as obfuscation")
        if case .confirm(let findings) = verdict {
            XCTAssertTrue(findings.contains { $0.rule == .obfuscatedExecution })
        }
    }

    func testOpensslEncDecryptPipeBash() {
        let verdict = scanner.scan("openssl enc --decrypt -in secret | bash")
        XCTAssertTrue(
            verdict.isBlocked,
            "openssl enc --decrypt piped to bash should be flagged")
    }

    // MARK: - xxd obfuscation

    func testXxdReversePipeSh() {
        let verdict = scanner.scan("xxd -r payload.hex | sh")
        XCTAssertTrue(
            verdict.isBlocked,
            "xxd -r piped to sh should be flagged as obfuscation")
        if case .confirm(let findings) = verdict {
            XCTAssertTrue(findings.contains { $0.rule == .obfuscatedExecution })
        }
    }

    func testXxdReversePipeBash() {
        let verdict = scanner.scan("xxd -r -p | bash")
        XCTAssertTrue(verdict.isBlocked)
    }

    // MARK: - printf hex obfuscation

    func testPrintfHexPipeSh() {
        let verdict = scanner.scan(#"printf '\x73\x75\x64\x6f' | sh"#)
        XCTAssertTrue(
            verdict.isBlocked,
            "printf with hex escapes piped to sh should be flagged")
        if case .confirm(let findings) = verdict {
            XCTAssertTrue(findings.contains { $0.rule == .obfuscatedExecution })
        }
    }

    func testPrintfHexPipeBash() {
        let verdict = scanner.scan(#"printf '\x72\x6d\x20\x2d\x72\x66' | bash"#)
        XCTAssertTrue(verdict.isBlocked)
    }

    // MARK: - eval recursion

    func testEvalRmRfIsCaught() {
        let verdict = scanner.scan(#"eval "rm -rf /""#)
        XCTAssertTrue(
            verdict.isBlocked,
            "eval wrapping rm -rf should be caught")
    }

    func testEvalSudoReboot() {
        let verdict = scanner.scan(#"eval "sudo reboot""#)
        XCTAssertTrue(verdict.isBlocked)
    }

    // MARK: - sh -c / bash -c recursion

    func testShCRmRf() {
        let verdict = scanner.scan("sh -c 'rm -rf /'")
        XCTAssertTrue(verdict.isBlocked)
    }

    func testBashCRmRf() {
        let verdict = scanner.scan("bash -c 'rm -rf /'")
        XCTAssertTrue(verdict.isBlocked)
    }

    // MARK: - Multi-layer nesting

    func testBashCWithLiteralSudoReboot() {
        let verdict = scanner.scan("bash -c 'sudo reboot'")
        XCTAssertTrue(
            verdict.isBlocked,
            "bash -c 'sudo reboot' should be caught via wrapper recursion")
    }

    func testEvalShCRmRf() {
        let verdict = scanner.scan("eval \"sh -c 'rm -rf /'\"")
        XCTAssertTrue(verdict.isBlocked)
    }

    // MARK: - Character concatenation via quotes

    func testQuoteConcatRm() {
        let verdict = scanner.scan("'r'm -rf /")
        XCTAssertTrue(
            verdict.isBlocked,
            "'r'm -rf / (quote concatenation) should be caught")
    }

    func testDoubleQuoteConcatSudo() {
        let verdict = scanner.scan(#""su""do" reboot"#)
        XCTAssertTrue(
            verdict.isBlocked,
            "Double-quote concatenation of sudo should be caught")
    }
}
