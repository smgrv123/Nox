import Foundation
import LLMRuntime

/// Failures from locating or measuring the `skill_id` value (docs/05-lld.md §4.2).
/// Fail-closed: never crash, never invent a high-confidence mean.
public enum RoutingConfidenceError: Error, Equatable, Sendable {
    /// `raw` has no `"skill_id":` key followed by a value and a comma.
    case skillIDValueNotFound
    /// No `TokenLogprob` overlapped the `skill_id` value literal. Fail-closed:
    /// there is no honest measurement, so we refuse to invent a mean (a `0`
    /// mean would look like maximum confidence).
    case noIdSelectingTokens
}

/// Derives ``RoutingConfidence`` from a ``RouterCompletion`` by measuring logprobs
/// only at the tokens that select `skill_id` (LLD §4.2).
public enum RoutingConfidenceDeriver {

    /// Locate the `skill_id` value literal in `completion.raw`, collect overlapping
    /// ``TokenLogprob``s, and return their count / sum / mean.
    public static func derive(from completion: RouterCompletion) throws -> RoutingConfidence {
        let valueRange = try skillIDValueByteRange(in: completion.raw)
        let selecting = completion.tokenLogprobs.filter { $0.byteRange.overlaps(valueRange) }
        guard !selecting.isEmpty else {
            throw RoutingConfidenceError.noIdSelectingTokens
        }
        let sum = selecting.reduce(Float(0)) { $0 + $1.logprob }
        let mean = sum / Float(selecting.count)
        return RoutingConfidence(
            idSelectingTokenCount: selecting.count,
            logprobSum: sum,
            logprobMean: mean)
    }

    /// UTF-8 byte range of the `skill_id` **value literal** — `"open_application"`
    /// or `null` — after `"skill_id":` (optional JSON whitespace) and before the
    /// following `,`.
    static func skillIDValueByteRange(in raw: String) throws -> Range<Int> {
        let bytes = Array(raw.utf8)
        let marker = Array(#""skill_id":"#.utf8)
        guard let markerRange = bytes.firstRange(of: marker) else {
            throw RoutingConfidenceError.skillIDValueNotFound
        }
        let valueStart = skipJSONWhitespace(in: bytes, from: markerRange.upperBound)
        guard let comma = bytes[valueStart...].firstIndex(of: UInt8(ascii: ",")) else {
            throw RoutingConfidenceError.skillIDValueNotFound
        }
        let valueEnd = trimTrailingJSONWhitespace(in: bytes, from: valueStart, upTo: comma)
        guard valueStart < valueEnd else {
            throw RoutingConfidenceError.skillIDValueNotFound
        }
        return valueStart..<valueEnd
    }

    private static func skipJSONWhitespace(in bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count && isJSONWhitespace(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func trimTrailingJSONWhitespace(
        in bytes: [UInt8], from start: Int, upTo end: Int
    ) -> Int {
        var index = end
        while index > start && isJSONWhitespace(bytes[index - 1]) {
            index -= 1
        }
        return index
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
