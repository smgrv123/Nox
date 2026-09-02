import Foundation

/// Byte range of the first occurrence of `snippet` in `raw`'s UTF-8 view.
internal func utf8Range(of snippet: String, in raw: String) throws -> Range<Int> {
    let haystack = Array(raw.utf8)
    let needle = Array(snippet.utf8)
    guard let start = haystack.firstRange(of: needle)?.lowerBound else {
        struct SnippetNotFound: Error {}
        throw SnippetNotFound()
    }
    return start..<(start + needle.count)
}
