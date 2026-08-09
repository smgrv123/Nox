import Foundation

/// Orchestrates "get this descriptor onto disk and ready to load" (docs/05-lld.md §2.7;
/// specs/P2a Phase 5; User Stories 12, 13, 15, 17, 19): skip-if-already-verified, else
/// download → verify → ready, with every non-ready outcome mapped to a human-readable
/// `Failure` — never a crash or silent no-op. Shared by P2a (Whisper) and P2b (the LLM
/// GGUF), so it carries no STT/LLM specifics.
///
/// Both collaborators — `ModelDownloading` (the network) and `ModelVerifying` (the
/// integrity check) — are injected protocols, so the decision logic here (skip vs.
/// download, how a failure is classified) is unit-testable with fakes: no network, no
/// real disk I/O, no multi-GB model. The App layer supplies the real `ModelDownloader`
/// (a separate effectful module) and `LiveModelVerifier`.
public struct ModelProvisioner: Sendable {

    /// A snapshot of provisioning progress, suitable for driving onboarding UI directly
    /// (each case is a distinct, honestly-labelled phase — User Story 15).
    public enum State: Equatable, Sendable {
        case checking
        case downloading(bytesWritten: Int64, totalBytes: Int64)
        case verifying
        case ready(URL)
        case failed(Failure)
    }

    /// Why provisioning did not end in `.ready` — the "speech model not ready" family
    /// (User Story 19), classified so the App layer can render an actionable message.
    public enum Failure: Equatable, Sendable {
        /// The downloader threw (network/transport failure). Carries a description for
        /// the human-readable error, not a typed `Error` (which isn't `Equatable`).
        case downloadFailed(String)
        /// The transfer completed but the bytes don't match the pin — corrupt or
        /// tampered. Never treated as usable (mirrors `ModelVerification`'s posture).
        case verificationFailed(ModelVerification.Mismatch)
        /// The downloader finished without producing a file at all.
        case notReady
    }

    private let downloader: any ModelDownloading
    private let verifier: any ModelVerifying
    private let modelsDirectory: ModelsDirectory

    public init(
        downloader: any ModelDownloading,
        verifier: any ModelVerifying,
        modelsDirectory: ModelsDirectory
    ) {
        self.downloader = downloader
        self.verifier = verifier
        self.modelsDirectory = modelsDirectory
    }

    /// Provision `descriptor`, reporting every phase through `onState` (called at least
    /// once with `.checking`, and exactly once more with the terminal `.ready`/`.failed`).
    /// Returns the terminal state as a convenience for a caller that doesn't need the
    /// intermediate progress (e.g. a test asserting only the outcome).
    @discardableResult
    public func provision(
        descriptor: ModelDescriptor,
        onState: @Sendable @escaping (State) -> Void = { _ in }
    ) async -> State {
        let blobURL = modelsDirectory.blobURL(for: descriptor)

        onState(.checking)
        if verifier.verify(fileAt: blobURL, descriptor: descriptor) == .verified {
            return report(.ready(blobURL), to: onState)
        }

        onState(.downloading(bytesWritten: 0, totalBytes: descriptor.byteSize))
        let reportProgress: @Sendable (Int64, Int64) -> Void = { written, total in
            onState(.downloading(bytesWritten: written, totalBytes: total))
        }
        let verification: ModelVerification
        do {
            verification = try await downloader.download(
                descriptor: descriptor, into: modelsDirectory, onProgress: reportProgress)
        } catch {
            return report(.failed(.downloadFailed(String(describing: error))), to: onState)
        }

        onState(.verifying)
        switch verification {
        case .verified:
            return report(.ready(blobURL), to: onState)
        case .mismatch(let mismatch):
            return report(.failed(.verificationFailed(mismatch)), to: onState)
        case .absent:
            return report(.failed(.notReady), to: onState)
        }
    }

    private func report(_ state: State, to onState: (State) -> Void) -> State {
        onState(state)
        return state
    }
}
