import Foundation

/// The injectable seam around `ModelVerification.verify(fileAt:descriptor:)` (docs/05-lld.md
/// §2.7). `ModelVerification` itself is already a pure static function — this protocol exists
/// purely so `ModelProvisioner` can be unit-tested with a canned verdict, without touching a
/// real file on disk for every skip/ready/mismatch scenario.
public protocol ModelVerifying: Sendable {
    func verify(fileAt url: URL, descriptor: ModelDescriptor) -> ModelVerification
}

/// The real conformer: a thin pass-through to `ModelVerification.verify(fileAt:descriptor:)`.
/// Always reads `FileManager.default` — matching `ModelVerification`'s own default and
/// avoiding storing a `FileManager` instance (not `Sendable`-annotated on this SDK).
public struct LiveModelVerifier: ModelVerifying, Sendable {
    public init() {}

    public func verify(fileAt url: URL, descriptor: ModelDescriptor) -> ModelVerification {
        ModelVerification.verify(fileAt: url, descriptor: descriptor)
    }
}
