import CommandDispatcher
import Foundation
import Personalization
import SkillManifest
import XCTest

@testable import BuiltinSkills

// MARK: - Clock

enum FrozenClock {
    /// 2024-06-15 12:00:00 UTC — summer, so America/New_York is EDT (UTC−4).
    static let date: Date = {
        var components = DateComponents()
        components.year = 2024
        components.month = 6
        components.day = 15
        components.hour = 12
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()
}

// MARK: - Mock system executor

final class MockSystemSkillExecutor: SystemSkillExecutor, @unchecked Sendable {
    private(set) var openCalls: [String] = []
    private(set) var quitCalls: [String] = []
    private(set) var timerCalls: [(durationSeconds: Int, label: String?)] = []
    private(set) var mediaCalls: [String] = []
    private(set) var screenshotCalls: [String?] = []
    var screenshotPath = "/tmp/aide-screenshot.png"

    func openApplication(appName: String) async throws {
        openCalls.append(appName)
    }

    func quitApplication(appName: String) async throws {
        quitCalls.append(appName)
    }

    func setTimer(durationSeconds: Int, label: String?) async throws {
        timerCalls.append((durationSeconds, label))
    }

    func mediaControl(action: String) async throws {
        mediaCalls.append(action)
    }

    func takeScreenshot(region: String?) async throws -> String {
        screenshotCalls.append(region)
        return screenshotPath
    }
}

final class RecordingSpy: DictionaryRecording, @unchecked Sendable {
    private(set) var records: [(mishearing: String, correctTerm: String)] = []

    func record(mishearing: String, correctTerm: String) async throws {
        records.append((mishearing, correctTerm))
    }
}

// MARK: - Router factory

func makeRouter(
    system: MockSystemSkillExecutor = MockSystemSkillExecutor(),
    dictionary: (any DictionaryRecording)? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
) -> BuiltinSkillRouter {
    BuiltinSkillRouter(system: system, dictionary: dictionary, now: now)
}

func frozenRouter(
    system: MockSystemSkillExecutor = MockSystemSkillExecutor()
) -> BuiltinSkillRouter {
    makeRouter(system: system, now: { FrozenClock.date })
}

func objectParams(_ fields: [String: JSONValue] = [:]) -> JSONValue {
    .object(fields)
}
