import AideCore

/// Thin `VoiceSessionDriver` that muxes Command Mode and Dictation onto one seam.
///
/// `VoiceSessionCoordinator` stays unchanged: it sees one driver. `begin(mode:)`
/// picks the active inner driver; `end()` / `cancel()` / `approve()` / `reject()`
/// forward to it. `onUpdate` is copied onto both inners — only the active one
/// fires (each has its own generation guard).
final class MuxVoiceSessionDriver: VoiceSessionDriver {

    var onUpdate: ((VoiceSessionUpdate) -> Void)? {
        didSet {
            command.onUpdate = onUpdate
            dictation.onUpdate = onUpdate
        }
    }

    private let command: any VoiceSessionDriver
    private let dictation: any VoiceSessionDriver
    private var active: (any VoiceSessionDriver)?

    init(command: any VoiceSessionDriver, dictation: any VoiceSessionDriver) {
        self.command = command
        self.dictation = dictation
    }

    func begin(mode: VoiceSessionMode) {
        let driver: any VoiceSessionDriver =
            switch mode {
            case .command: command
            case .dictation: dictation
            }
        active = driver
        driver.begin(mode: mode)
    }

    func end() {
        active?.end()
    }

    func cancel() {
        active?.cancel()
    }

    func approve() {
        active?.approve()
    }

    func reject() {
        active?.reject()
    }
}
