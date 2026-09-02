/// Wrapper-command detection: recognises `sh -c`, `eval`, `xargs`, `find -exec`,
/// `env`, `nohup`, `nice`, `time`, and `ssh`, then recurses into the wrapped
/// command string or argv.
extension CommandTreeParser {

    static func detectWrappers(
        argv: [String],
        path: [String],
        depth: Int,
        findings: inout [Finding]
    ) -> [CommandNode] {
        guard let cmd = argv.first else { return [] }
        switch cmd {
        case "sh", "bash", "zsh":
            return handleShellC(argv: argv, path: path, depth: depth, findings: &findings)
        case "eval":
            return handleEval(argv: argv, path: path, depth: depth, findings: &findings)
        case "xargs":
            return handleXargs(argv: argv, path: path, depth: depth, findings: &findings)
        case "find":
            return handleFind(argv: argv, path: path, depth: depth, findings: &findings)
        case "env":
            return handleEnv(argv: argv, path: path, depth: depth, findings: &findings)
        case "nohup", "nice", "time":
            return handleSimplePrefix(
                name: cmd, argv: argv, path: path, depth: depth, findings: &findings)
        case "ssh":
            return handleSsh(argv: argv, path: path, depth: depth, findings: &findings)
        default:
            return []
        }
    }

    // MARK: - sh / bash / zsh -c

    private static func handleShellC(
        argv: [String], path: [String], depth: Int, findings: inout [Finding]
    ) -> [CommandNode] {
        guard let cIdx = argv.firstIndex(of: "-c"),
            cIdx + 1 < argv.count
        else { return [] }
        let shell = argv[0]
        let innerPath = path + ["\(shell) -c"]
        return parseString(
            argv[cIdx + 1], path: innerPath, depth: depth + 1, findings: &findings)
    }

    // MARK: - eval

    private static func handleEval(
        argv: [String], path: [String], depth: Int, findings: inout [Finding]
    ) -> [CommandNode] {
        guard argv.count >= 2 else { return [] }
        let argument = argv.dropFirst().joined(separator: " ")
        return parseString(
            argument, path: path + ["eval"], depth: depth + 1, findings: &findings)
    }

    // MARK: - xargs

    private static let xargsOptionsWithArg: Set<String> = [
        "-I", "-n", "-P", "-L", "-s", "-E", "-d",
    ]

    private static func handleXargs(
        argv: [String], path: [String], depth: Int, findings: inout [Finding]
    ) -> [CommandNode] {
        var idx = 1
        while idx < argv.count {
            if xargsOptionsWithArg.contains(argv[idx]), idx + 1 < argv.count {
                idx += 2
            } else if argv[idx].hasPrefix("-") {
                idx += 1
            } else {
                break
            }
        }
        guard idx < argv.count else { return [] }
        return parseArgvAsCommand(
            Array(argv[idx...]), path: path + ["xargs"],
            depth: depth + 1, findings: &findings
        )
    }

    // MARK: - find -exec / -execdir

    private static func handleFind(
        argv: [String], path: [String], depth: Int, findings: inout [Finding]
    ) -> [CommandNode] {
        guard let execIdx = argv.firstIndex(where: { $0 == "-exec" || $0 == "-execdir" })
        else { return [] }
        let afterExec = Array(argv[(execIdx + 1)...])
        let terminatorIdx = afterExec.firstIndex(where: { $0 == ";" || $0 == "+" })
        let commandArgv =
            terminatorIdx.map { Array(afterExec[..<$0]) } ?? afterExec
        guard !commandArgv.isEmpty else { return [] }
        return parseArgvAsCommand(
            commandArgv, path: path + ["find -exec"],
            depth: depth + 1, findings: &findings
        )
    }

    // MARK: - env

    private static func handleEnv(
        argv: [String], path: [String], depth: Int, findings: inout [Finding]
    ) -> [CommandNode] {
        var idx = 1
        while idx < argv.count {
            let arg = argv[idx]
            if arg.contains("=") && !arg.hasPrefix("-") {
                idx += 1
            } else if arg == "-i" || arg == "--ignore-environment" {
                idx += 1
            } else if arg == "-u" && idx + 1 < argv.count {
                idx += 2
            } else if arg.hasPrefix("--unset=") {
                idx += 1
            } else {
                break
            }
        }
        guard idx < argv.count else { return [] }
        return parseArgvAsCommand(
            Array(argv[idx...]), path: path + ["env"],
            depth: depth + 1, findings: &findings
        )
    }

    // MARK: - nohup / nice / time

    private static func handleSimplePrefix(
        name: String, argv: [String], path: [String], depth: Int,
        findings: inout [Finding]
    ) -> [CommandNode] {
        var idx = 1
        idx += skipPrefixOptions(name: name, argv: argv, startAt: idx)
        guard idx < argv.count else { return [] }
        return parseArgvAsCommand(
            Array(argv[idx...]), path: path + [name],
            depth: depth + 1, findings: &findings
        )
    }

    // MARK: - ssh

    private static let sshOptionsWithArg: Set<String> = [
        "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J",
        "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
    ]

    private static func handleSsh(
        argv: [String], path: [String], depth: Int, findings: inout [Finding]
    ) -> [CommandNode] {
        var idx = 1
        while idx < argv.count && argv[idx].hasPrefix("-") {
            if sshOptionsWithArg.contains(argv[idx]) && idx + 1 < argv.count {
                idx += 2
            } else {
                idx += 1
            }
        }
        guard idx < argv.count else { return [] }
        idx += 1  // skip the hostname
        guard idx < argv.count else { return [] }
        let remoteCommand = argv[idx...].joined(separator: " ")
        return parseString(
            remoteCommand, path: path + ["ssh"],
            depth: depth + 1, findings: &findings
        )
    }

    private static func skipPrefixOptions(name: String, argv: [String], startAt idx: Int) -> Int {
        guard idx < argv.count else { return 0 }
        if name == "nice" && argv[idx] == "-n" && idx + 1 < argv.count { return 2 }
        if name == "nice" && argv[idx].hasPrefix("--adjustment") { return 1 }
        if name == "time" && argv[idx] == "-p" { return 1 }
        return 0
    }
}
