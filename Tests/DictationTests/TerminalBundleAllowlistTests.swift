import DangerousCommandScanner
import XCTest

@testable import Dictation

final class TerminalBundleAllowlistTests: XCTestCase {

    func testMatchesScannerAllowlist() {
        let expected: Set<String> = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty",
            "org.alacritty",
            "com.github.wez.wezterm",
        ]
        XCTAssertEqual(TerminalBundleAllowlist.ids, TerminalBundleIDs.allowlist)
        XCTAssertEqual(TerminalBundleAllowlist.ids, expected)
        for bundleID in expected {
            XCTAssertTrue(
                TerminalBundleAllowlist.contains(bundleID),
                "\(bundleID) must be on the dictation terminal allowlist")
        }
        XCTAssertFalse(TerminalBundleAllowlist.contains("com.apple.TextEdit"))
    }
}
