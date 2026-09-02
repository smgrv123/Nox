/// Context about *where* a command string originates (LLD §3.6, §4.3 Phase D).
///
/// Affects verdict escalation: e.g. `manifestID != nil` (Aide-generated automation)
/// promotes the §11.2 destructive subset from confirm → hard-block (H7).
public struct ScanContext: Equatable, Sendable {
    public enum Channel: String, Equatable, Hashable, Sendable {
        case generatedScript
        case preExecution
        case handEdit
        case dictatedOneOff
        case typedOneOff
    }

    public let channel: Channel
    public let destinationBundleID: String?
    public let manifestID: String?

    public init(
        channel: Channel = .preExecution,
        destinationBundleID: String? = nil,
        manifestID: String? = nil
    ) {
        self.channel = channel
        self.destinationBundleID = destinationBundleID
        self.manifestID = manifestID
    }
}
