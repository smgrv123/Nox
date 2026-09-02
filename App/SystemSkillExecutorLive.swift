import AppKit
import BuiltinSkills
import Foundation
import UserNotifications

/// Production `SystemSkillExecutor`: real AppKit / UserNotifications / HID / screencapture.
struct SystemSkillExecutorLive: SystemSkillExecutor {

    func openApplication(appName: String) async throws {
        if let running = await MainActor.run(body: { Self.runningApplication(named: appName) }) {
            await MainActor.run { running.activate() }
            return
        }
        guard let url = Self.applicationURL(named: appName) else {
            throw SystemSkillExecutorError.appNotFound(appName)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func quitApplication(appName: String) async throws {
        try await MainActor.run {
            guard let running = Self.runningApplication(named: appName) else {
                throw SystemSkillExecutorError.appNotRunning(appName)
            }
            guard running.terminate() else {
                throw SystemSkillExecutorError.quitFailed(appName)
            }
        }
    }

    func setTimer(durationSeconds: Int, label: String?) async throws {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else {
            throw SystemSkillExecutorError.notificationsDenied
        }
        let content = UNMutableNotificationContent()
        content.title = label ?? "Timer"
        content.body = label.map { "\($0) is done." } ?? "Timer finished."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(durationSeconds), repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: trigger)
        try await center.add(request)
    }

    func mediaControl(action: String) async throws {
        let key = try Self.mediaKey(for: action)
        try await MainActor.run {
            try Self.postMediaKey(key)
        }
    }

    func takeScreenshot(region: String?) async throws -> String {
        let path = try Self.screenshotPath()
        try await Task.detached {
            try Self.runScreencapture(region: region, path: path)
        }.value
        return path
    }

    // MARK: - Apps

    private static func runningApplication(named appName: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            namesMatch(appName, app.localizedName) || namesMatch(appName, app.bundleIdentifier)
        }
    }

    private static func applicationURL(named appName: String) -> URL? {
        if let bundleIDURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appName) {
            return bundleIDURL
        }
        let fileName = appName.hasSuffix(".app") ? appName : "\(appName).app"
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        for root in roots {
            let url = URL(fileURLWithPath: root).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func namesMatch(_ query: String, _ candidate: String?) -> Bool {
        guard let candidate else { return false }
        return candidate.compare(query, options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame
    }

    // MARK: - Media

    /// NX_KEYTYPE_* from IOKit `ev_keymap.h`.
    private static let playPauseKey: Int32 = 16
    private static let nextKey: Int32 = 17
    private static let previousKey: Int32 = 18
    private static let mediaKeyDownFlags: UInt = 0xA00
    private static let mediaKeyUpFlags: UInt = 0xB00
    private static let mediaKeyDownData1: Int = 0xA
    private static let mediaKeyUpData1: Int = 0xB
    private static let mediaKeySubtype: Int16 = 8

    private static func mediaKey(for action: String) throws -> Int32 {
        switch action {
        case "play", "pause", "toggle":
            return playPauseKey
        case "next":
            return nextKey
        case "previous":
            return previousKey
        default:
            throw SystemSkillExecutorError.unsupportedMediaAction(action)
        }
    }

    private static func postMediaKey(_ key: Int32) throws {
        try postMediaKey(key, down: true)
        try postMediaKey(key, down: false)
    }

    private static func postMediaKey(_ key: Int32, down: Bool) throws {
        let flags = NSEvent.ModifierFlags(rawValue: down ? mediaKeyDownFlags : mediaKeyUpFlags)
        let data1 = Int((Int(key) << 16) | ((down ? mediaKeyDownData1 : mediaKeyUpData1) << 8))
        guard
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: mediaKeySubtype,
                data1: data1,
                data2: -1)
        else {
            throw SystemSkillExecutorError.mediaKeyPostFailed
        }
        guard let cgEvent = event.cgEvent else {
            throw SystemSkillExecutorError.mediaKeyPostFailed
        }
        cgEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Screenshot

    private static func screenshotPath() throws -> String {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let directory = desktop ?? FileManager.default.temporaryDirectory
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("aide-screenshot-\(stamp).png").path
    }

    private static func runScreencapture(region: String?, path: String) throws {
        var arguments = ["-x"]
        switch region {
        case "window":
            arguments.append("-w")
        case "selection":
            arguments.append("-s")
        default:
            break
        }
        arguments.append(path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SystemSkillExecutorError.screenshotFailed
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw SystemSkillExecutorError.screenshotFailed
        }
    }
}

enum SystemSkillExecutorError: LocalizedError {
    case appNotFound(String)
    case appNotRunning(String)
    case quitFailed(String)
    case notificationsDenied
    case unsupportedMediaAction(String)
    case mediaKeyPostFailed
    case screenshotFailed

    var errorDescription: String? {
        switch self {
        case .appNotFound(let name):
            return "Couldn't find \(name)."
        case .appNotRunning(let name):
            return "\(name) isn't running."
        case .quitFailed(let name):
            return "Couldn't quit \(name)."
        case .notificationsDenied:
            return "Notifications aren't allowed, so the timer wasn't set."
        case .unsupportedMediaAction(let action):
            return "unsupported media action: \(action)"
        case .mediaKeyPostFailed:
            return "Couldn't post the media key."
        case .screenshotFailed:
            return "Couldn't capture a screenshot."
        }
    }
}
