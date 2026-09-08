/// Bundle IDs of terminal emulators that C11 treats as dictation destinations
/// requiring confirmation (LLD §11.2).
///
/// Shared by the scanner and Dictation so the allowlist is not forked.
public enum TerminalBundleIDs {
    public static let allowlist: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
        "com.github.wez.wezterm",
    ]
}
