/// POSIX-ish shell lexer (LLD §4.3 Phase A).
///
/// Scans character-by-character producing a `[ShellToken]` stream. Honors single
/// quotes (literal), double quotes (with `$`, backtick, `\` handling), backslash
/// escapes, `$'...'` ANSI-C quoting, and shell operators. Recursively tokenizes
/// `$(...)` and backtick command substitutions. Never expands variables or globs.
/// Unknown/odd bytes produce `.opaque` tokens (fail-closed).
public enum ShellTokenizer: Sendable {

    public static func tokenize(_ input: String) -> [ShellToken] {
        var scanner = ShellScanner(input)
        return scanner.scanTokens()
    }
}
