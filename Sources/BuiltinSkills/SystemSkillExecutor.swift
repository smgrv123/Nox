/// Effectful OS actions used by built-in skills. The App layer injects a real
/// conformer (NSWorkspace, notifications, `screencapture`); tests inject a mock.
public protocol SystemSkillExecutor: Sendable {
    func openApplication(appName: String) async throws
    func quitApplication(appName: String) async throws
    func setTimer(durationSeconds: Int, label: String?) async throws
    func mediaControl(action: String) async throws
    func takeScreenshot(region: String?) async throws -> String
}
