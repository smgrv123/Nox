import Foundation

/// Lexical path restriction checks (LLD §11.3 — C7).
///
/// All resolution is purely lexical (expand `~`, resolve `.`/`..`).
/// No filesystem I/O, no symlink following.
///
/// NOTE: Manifest `file_write_paths` checking is deferred to Phase 6.
enum PathRestriction {

    enum Classification: Equatable {
        case outsideHome
        case systemCritical
        case allowed
    }

    static let homeDirectory: String = {
        NSHomeDirectory()
    }()

    static let systemCriticalPaths: [String] = [
        "Library/LaunchAgents", "Library/Preferences", "Library/Keychains",
        ".ssh", ".gnupg",
    ]

    // MARK: - Lexical resolution

    static func resolveLexically(_ path: String) -> String {
        let expanded = expandTilde(path)
        return resolveComponents(expanded)
    }

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let rest = path.dropFirst()
        if rest.isEmpty { return homeDirectory }
        if rest.hasPrefix("/") {
            return homeDirectory + rest
        }
        return path
    }

    private static func resolveComponents(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        var stack: [Substring] = []
        for part in parts {
            switch part {
            case ".":
                continue
            case "..":
                _ = stack.popLast()
            default:
                stack.append(part)
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    // MARK: - Classification

    static func classify(_ resolvedPath: String) -> Classification {
        guard resolvedPath.hasPrefix("/") else { return .allowed }
        let homePrefixSlash = homeDirectory + "/"
        let isInsideHome =
            resolvedPath == homeDirectory
            || resolvedPath.hasPrefix(homePrefixSlash)
        guard isInsideHome else { return .outsideHome }

        let relative = String(resolvedPath.dropFirst(homePrefixSlash.count))
        for critical in systemCriticalPaths {
            let isCritical =
                relative == critical || relative.hasPrefix(critical + "/")
            if isCritical { return .systemCritical }
        }
        return .allowed
    }

    // MARK: - Glob detection

    static func containsGlob(_ path: String) -> Bool {
        path.contains("*") || path.contains("?")
    }

    // MARK: - Check a target path, returning a Finding if flagged

    static func checkTarget(
        _ rawPath: String, node: CommandNode
    ) -> Finding? {
        if containsGlob(rawPath) { return globFinding(rawPath, node: node) }
        let resolved = resolveLexically(rawPath)
        let result = classify(resolved)
        switch result {
        case .outsideHome:
            return outsideHomeFinding(rawPath, node: node)
        case .systemCritical:
            return systemCriticalFinding(rawPath, node: node)
        case .allowed:
            return nil
        }
    }

    private static func outsideHomeFinding(
        _ rawPath: String, node: CommandNode
    ) -> Finding {
        Finding(
            rule: .outsideHome,
            severity: .confirm,
            matchedText: rawPath,
            explanation:
                "Target path is outside $HOME — could modify system files.",
            path: node.path)
    }

    private static func systemCriticalFinding(
        _ rawPath: String, node: CommandNode
    ) -> Finding {
        Finding(
            rule: .outsideHome,
            severity: .confirm,
            matchedText: rawPath,
            explanation:
                "Target path is in a system-critical zone inside $HOME.",
            path: node.path)
    }

    private static func globFinding(
        _ rawPath: String, node: CommandNode
    ) -> Finding {
        Finding(
            rule: .outsideHome,
            severity: .confirm,
            matchedText: rawPath,
            explanation:
                "Glob/wildcard in path — could expand outside declared scope (fail-closed).",
            path: node.path)
    }
}
