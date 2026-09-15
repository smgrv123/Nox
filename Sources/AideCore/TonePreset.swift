import Foundation

/// Dictation cleanup register (LLD §2.5 `tone`, LLD §4.6). Shared by `Configuration`
/// (persisted as `Settings.TonePreset`) and `Dictation` (used as `Dictation.TonePreset`,
/// which adds the `instruction` computed property for the cleanup prompt) so neither
/// module needs to duplicate or hand-map this enum at the App boundary.
///
/// The raw values are the on-disk JSON wire format — do not change them.
public enum TonePreset: String, Equatable, Sendable, Codable, CaseIterable {
    case asIs = "as_is"
    case professional
    case casual
    case concise
}
