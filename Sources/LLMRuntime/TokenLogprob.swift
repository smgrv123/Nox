import Foundation

/// One generated token's log-probability, aligned to the byte offsets of the completion
/// text it belongs to (docs/05-lld.md §3.3, the `[ASSUMPTION]` note right after it, and
/// §4.2's "measure at the id-selecting tokens" rule — P4's job, not P2b's, but this is the
/// data shape that measurement reads). `byteRange` is a **UTF-8 byte** range into the
/// completion string, not a character/grapheme range: a token boundary is not guaranteed
/// to fall on a `Character` boundary (multi-byte UTF-8 sequences can split across
/// tokens), so bytes are the only representation that is always exact.
public struct TokenLogprob: Equatable, Sendable {
    public let token: String
    public let logprob: Float
    public let byteRange: Range<Int>

    public init(token: String, logprob: Float, byteRange: Range<Int>) {
        self.token = token
        self.logprob = logprob
        self.byteRange = byteRange
    }
}
