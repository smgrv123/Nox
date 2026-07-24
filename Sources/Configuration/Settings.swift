import Foundation

/// Aide's user preferences — the in-memory shape of `settings.json`
/// (docs/05-lld.md §2.5). This is a pure value type: `AppCoordinator` owns one on
/// the main actor, the menubar reads it, and `SettingsStore` (de)serialises it.
///
/// **Phase 3 scope.** LLD §2.5 defines the full document (hotkeys, model tier, tone,
/// BYOK, wake word, indicators, privacy, text-insertion). Phase 3 ships only the
/// **schema envelope** + the **indicators** block — enough to prove the
/// load/save/migrate round-trip with one real, user-visible setting (the audio cue).
/// Later phases add their own blocks and bump `currentSchemaVersion`; the
/// forward-migration chain (`SettingsMigration`) is exactly how those additions slot
/// in without breaking existing files.
///
/// **Secrets are never modelled here** (docs/03-architecture.md §10.1, D1). A future
/// BYOK key lives in the macOS Keychain, referenced from the file by a `keychain://`
/// URI — this struct deliberately holds no secret material.
///
/// Decoding is **tolerant**: an absent field falls back to its default rather than
/// throwing, so a file written by an older build (missing a field a newer build
/// added within the same schema version) still loads. Renames / restructures across
/// schema versions are handled by the migration chain, not here.
public struct Settings: Equatable, Sendable, Codable {

    /// The schema version this build reads and writes. Bumped by a later phase when
    /// it adds or renames a field; that phase also appends the matching
    /// `SettingsMigration` step. Matches the `schema_version: 1` baseline in §2.5.
    public static let currentSchemaVersion = 1

    /// The document's schema version. Always normalised to `currentSchemaVersion`
    /// in memory (migration runs on load), so an in-memory value never lags the file.
    public var schemaVersion: Int

    /// Overlay / menubar indicator options (§2.5 `indicators`). Surfaced by the P1
    /// overlay-options Settings pane in Phase 9; Phase 3 reaches one field of it
    /// (the audio cue) through a temporary menubar toggle.
    public var indicators: Indicators

    public init(indicators: Indicators = Indicators()) {
        self.schemaVersion = Settings.currentSchemaVersion
        self.indicators = indicators
    }

    /// The safe defaults used for a missing or unreadable file (User Story 38: a
    /// failure surfaces a working default state, never a crash).
    public static let defaults = Settings()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case indicators
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The file's version is already normalised by the migration chain before we
        // decode, so the model is always the current version — read it, don't trust it.
        self.schemaVersion = Settings.currentSchemaVersion
        self.indicators = try container.decodeIfPresent(Indicators.self, forKey: .indicators) ?? Indicators()
    }
    // `encode(to:)` is synthesised from `CodingKeys` — writes `schema_version` + `indicators`.
}

extension Settings {

    /// Overlay / menubar indicator preferences (§2.5 `indicators`).
    public struct Indicators: Equatable, Sendable, Codable {

        /// Show the Local/Cloud indicator component (rendered LOCAL by default in P1;
        /// its live state is driven by P6). §2.5 `show_local_cloud_indicator`.
        public var showLocalCloudIndicator: Bool

        /// Play an audio cue when listening starts (User Story 8). This is Phase 3's
        /// demonstrator setting — the one flipped by the temporary menubar toggle to
        /// prove persistence across relaunch. §2.5 `audio_cue_on_listen`.
        public var audioCueOnListen: Bool

        /// Play an audio cue when processing starts (User Story 8, optional).
        /// §2.5 `audio_cue_on_processing`.
        public var audioCueOnProcessing: Bool

        /// Where the Overlay floats on screen. §2.5 `overlay_position`.
        public var overlayPosition: OverlayPosition

        public init(
            showLocalCloudIndicator: Bool = true,
            audioCueOnListen: Bool = true,
            audioCueOnProcessing: Bool = false,
            overlayPosition: OverlayPosition = .bottomCenter
        ) {
            self.showLocalCloudIndicator = showLocalCloudIndicator
            self.audioCueOnListen = audioCueOnListen
            self.audioCueOnProcessing = audioCueOnProcessing
            self.overlayPosition = overlayPosition
        }

        private enum CodingKeys: String, CodingKey {
            case showLocalCloudIndicator = "show_local_cloud_indicator"
            case audioCueOnListen = "audio_cue_on_listen"
            case audioCueOnProcessing = "audio_cue_on_processing"
            case overlayPosition = "overlay_position"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A single source of default truth: any absent field falls back here.
            let fallback = Indicators()
            self.showLocalCloudIndicator =
                try container.decodeIfPresent(Bool.self, forKey: .showLocalCloudIndicator)
                ?? fallback.showLocalCloudIndicator
            self.audioCueOnListen =
                try container.decodeIfPresent(Bool.self, forKey: .audioCueOnListen) ?? fallback.audioCueOnListen
            self.audioCueOnProcessing =
                try container.decodeIfPresent(Bool.self, forKey: .audioCueOnProcessing)
                ?? fallback.audioCueOnProcessing
            self.overlayPosition =
                try container.decodeIfPresent(OverlayPosition.self, forKey: .overlayPosition)
                ?? fallback.overlayPosition
        }
    }

    /// Overlay screen anchor. The raw values match the on-disk JSON (§2.5). Phase 9's
    /// overlay-options pane surfaces the choice; Phase 3 only needs it to exist so the
    /// block round-trips. Additional anchors are a later, additive change.
    public enum OverlayPosition: String, Equatable, Sendable, Codable, CaseIterable {
        case topCenter = "top_center"
        case bottomCenter = "bottom_center"
    }
}
