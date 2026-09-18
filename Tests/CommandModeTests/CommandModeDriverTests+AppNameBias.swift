import AideCore
import XCTest

@testable import CommandMode

/// Regression coverage for `CommandModeDriver.appNameBiasPhrases`: it must hand back
/// installed-app display names unsplit. The prior implementation derived this list by
/// joining names with `", "` and then re-splitting on that same separator, which
/// silently mangled any display name that itself contains `", "`.
@MainActor
extension CommandModeDriverTests {

    func testAppNameBiasPhrasesReturnsNamesUnsplit() async {
        let commaContainingName = "Foo, Bar"
        let appCatalog = FakeInstalledApplicationCatalog(apps: [
            InstalledApplication(
                displayName: commaContainingName,
                bundleURL: URL(fileURLWithPath: "/Applications/Foo, Bar.app")),
            InstalledApplication(
                displayName: "Ghostty", bundleURL: URL(fileURLWithPath: "/Applications/Ghostty.app")),
        ])

        let phrases = await CommandModeDriver.appNameBiasPhrases(appCatalog)

        XCTAssertTrue(
            phrases.contains(commaContainingName),
            "expected the comma-containing display name to survive intact, got \(phrases)")
        XCTAssertTrue(phrases.contains("Ghostty"))
        XCTAssertEqual(phrases.count, 2, "a join/split round-trip would have produced 3 entries here")
    }
}
