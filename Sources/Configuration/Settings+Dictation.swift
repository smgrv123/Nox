import AideCore
import Foundation

extension Settings {

    /// Dictation cleanup register (LLD §2.5 `tone`). Defined once in `AideCore` and
    /// shared with `Dictation.TonePreset` — neither `Configuration` nor `Dictation`
    /// imports the other. Unknown JSON falls back to `.asIs` at `Tone` decode time.
    public typealias TonePreset = AideCore.TonePreset

    /// Dictation tone preset (LLD §2.5 `tone`). `defaultPreset` is
    /// `Settings.TonePreset`; the allowed set is `TonePreset.allCases` and is
    /// not persisted.
    public struct Tone: Equatable, Sendable, Codable {

        /// The user's default cleanup register. Voice prefixes override this per
        /// utterance only (P5a Phase 4).
        public var defaultPreset: TonePreset

        public init(defaultPreset: TonePreset = .asIs) {
            self.defaultPreset = defaultPreset
        }

        private enum CodingKeys: String, CodingKey {
            case defaultPreset = "default_preset"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decodeIfPresent(String.self, forKey: .defaultPreset) ?? TonePreset.asIs.rawValue
            self.defaultPreset = TonePreset(rawValue: raw) ?? .asIs
        }
    }

    /// Cleanup on/off (JSON key `dictation`). Named `DictationSettings` to avoid
    /// clashing with the `Dictation` module at App-layer import sites. Added by the
    /// locked P5a bypass (not in the original LLD §2.5 sample).
    public struct DictationSettings: Equatable, Sendable, Codable {

        /// When `false`, dictation inserts the (prefix-stripped) transcript and never
        /// calls the LLM. Default `true`.
        public var cleanupEnabled: Bool

        public init(cleanupEnabled: Bool = true) {
            self.cleanupEnabled = cleanupEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case cleanupEnabled = "cleanup_enabled"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.cleanupEnabled = try container.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? true
        }
    }

}
