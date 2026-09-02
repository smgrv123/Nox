import Foundation

/// Provenance of a manifest's script: who or what generated it.
public enum GeneratedBy: String, Codable, Sendable, Hashable {
    case builtin
    case localLlm = "local_llm"
    case cloudLlm = "cloud_llm"
    case manual
}
