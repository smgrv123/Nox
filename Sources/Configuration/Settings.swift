import Foundation

/// Aide's user preferences — the in-memory shape of `settings.json`
/// (docs/05-lld.md §2.5). This is a pure value type: `AppCoordinator` owns one on
/// the main actor, the menubar reads it, and `SettingsStore` (de)serialises it.
///
/// **Scope so far.** LLD §2.5 defines the full document (hotkeys, model tier, tone,
/// BYOK, wake word, indicators, privacy, text-insertion). Phase 3 shipped the
/// **schema envelope** + the **indicators** block; Phase 5 adds the **hotkeys** block
/// (the two push-to-talk bindings), bumping the schema to v2. Later phases add their
/// own blocks and bump `currentSchemaVersion`; the forward-migration chain
/// (`SettingsMigration`) is exactly how those additions slot in without breaking
/// existing files.
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

    /// The schema version this build reads and writes. Bumped whenever a phase adds
    /// or renames a field; that phase also appends the matching `SettingsMigration`
    /// step. **v2** (Phase 5) added the `hotkeys` block on top of the v1 `indicators`
    /// baseline (§2.5).
    public static let currentSchemaVersion = 2

    /// The document's schema version. Always normalised to `currentSchemaVersion`
    /// in memory (migration runs on load), so an in-memory value never lags the file.
    public var schemaVersion: Int

    /// The two global push-to-talk bindings — command mode and dictation mode
    /// (§2.5 `hotkeys`). Read by `HotkeyManager`/the `Hotkeys` binder to decide which
    /// semantic hotkey a raw key event is. Rebindable via the Phase-9 hotkeys pane.
    public var hotkeys: Hotkeys

    /// Overlay / menubar indicator options (§2.5 `indicators`). Surfaced by the P1
    /// overlay-options Settings pane in Phase 9; Phase 3 reaches one field of it
    /// (the audio cue) through a temporary menubar toggle.
    public var indicators: Indicators

    public init(hotkeys: Hotkeys = Hotkeys(), indicators: Indicators = Indicators()) {
        self.schemaVersion = Settings.currentSchemaVersion
        self.hotkeys = hotkeys
        self.indicators = indicators
    }

    /// The safe defaults used for a missing or unreadable file (User Story 38: a
    /// failure surfaces a working default state, never a crash).
    public static let defaults = Settings()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case hotkeys
        case indicators
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The file's version is already normalised by the migration chain before we
        // decode, so the model is always the current version — read it, don't trust it.
        self.schemaVersion = Settings.currentSchemaVersion
        self.hotkeys = try container.decodeIfPresent(Hotkeys.self, forKey: .hotkeys) ?? Hotkeys()
        self.indicators = try container.decodeIfPresent(Indicators.self, forKey: .indicators) ?? Indicators()
    }
    // `encode(to:)` is synthesised from `CodingKeys` — writes `schema_version` + `hotkeys` + `indicators`.
}

extension Settings {

    /// The two global push-to-talk bindings (§2.5 `hotkeys`). Defaults are ⌥Space for
    /// command mode and ⌃Space for dictation mode — both `push_to_talk` — matching the
    /// spec (User Story 13). Each is independently rebindable (User Story 14).
    public struct Hotkeys: Equatable, Sendable, Codable {

        /// Command-mode trigger. Default ⌥Space (key_code 49 + `option`).
        public var commandMode: HotkeyBinding

        /// Dictation-mode trigger. Default ⌃Space (key_code 49 + `control`).
        public var dictationMode: HotkeyBinding

        public init(
            commandMode: HotkeyBinding = HotkeyBinding(keyCode: HotkeyBinding.spaceKeyCode, modifiers: [.option]),
            dictationMode: HotkeyBinding = HotkeyBinding(keyCode: HotkeyBinding.spaceKeyCode, modifiers: [.control])
        ) {
            self.commandMode = commandMode
            self.dictationMode = dictationMode
        }

        private enum CodingKeys: String, CodingKey {
            case commandMode = "command_mode"
            case dictationMode = "dictation_mode"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = Hotkeys()
            self.commandMode =
                try container.decodeIfPresent(HotkeyBinding.self, forKey: .commandMode) ?? fallback.commandMode
            self.dictationMode =
                try container.decodeIfPresent(HotkeyBinding.self, forKey: .dictationMode) ?? fallback.dictationMode
        }
    }

    /// A single hotkey binding: a base key plus zero or more modifiers, held to talk
    /// (§2.5 — `{ key_code, modifiers[], mode }`). `keyCode` is a hardware virtual
    /// key code (49 = Space); `modifiers` are the chord's required modifier keys.
    public struct HotkeyBinding: Equatable, Sendable, Codable {

        /// Hardware virtual key code of the Space bar — the base key of both spec
        /// defaults (⌥Space command mode, ⌃Space dictation mode) and the fallback used
        /// when decoding a binding whose `key_code` is missing.
        public static let spaceKeyCode = 49

        /// Hardware virtual key code of the base key (e.g. 49 = Space). Matches the
        /// value the event tap reports for `keyboardEventKeycode`.
        public var keyCode: Int

        /// Modifier keys that must be held together with `keyCode` (order-insensitive).
        public var modifiers: [HotkeyModifier]

        /// The trigger style. v1 supports only `push_to_talk` (hold-to-talk).
        public var mode: HotkeyMode

        public init(keyCode: Int, modifiers: [HotkeyModifier], mode: HotkeyMode = .pushToTalk) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.mode = mode
        }

        private enum CodingKeys: String, CodingKey {
            case keyCode = "key_code"
            case modifiers
            case mode
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A binding with no key_code is meaningless; fall back to Space so a
            // partial/hand-edited file still yields a usable (if generic) binding
            // rather than throwing.
            self.keyCode = try container.decodeIfPresent(Int.self, forKey: .keyCode) ?? HotkeyBinding.spaceKeyCode
            self.modifiers = try container.decodeIfPresent([HotkeyModifier].self, forKey: .modifiers) ?? []
            self.mode = try container.decodeIfPresent(HotkeyMode.self, forKey: .mode) ?? .pushToTalk
        }
    }

    /// A chord modifier key. Raw values match the on-disk JSON (§2.5 `modifiers[]`);
    /// the `Hotkeys` binder maps each to its `CGEventFlags` bit when matching events.
    public enum HotkeyModifier: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case command
        case control
        case option
        case shift
    }

    /// How a hotkey triggers. v1 ships only push-to-talk (hold to talk, release to
    /// stop); the enum exists so future modes (e.g. toggle) are an additive change.
    public enum HotkeyMode: String, Equatable, Sendable, Codable, CaseIterable {
        case pushToTalk = "push_to_talk"
    }

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
