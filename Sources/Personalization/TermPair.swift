import Foundation

/// A single STT mishearing and the canonical spelling it should become.
public struct TermPair: Equatable, Sendable {
    public var mishearing: String
    public var correctTerm: String

    public init(mishearing: String, correctTerm: String) {
        self.mishearing = mishearing
        self.correctTerm = correctTerm
    }
}
