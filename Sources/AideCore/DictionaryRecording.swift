import Foundation

/// Seam for recording an explicit mishearing → correct-term pair (P5b Phase 2).
/// The live conformer is ``DictionaryStore``; skills never talk to the filesystem.
public protocol DictionaryRecording: Sendable {
    func record(mishearing: String, correctTerm: String) async throws
}
