import AideCore
import Darwin
import Foundation
import LLMRuntime
import ModelProvisioning
import os

/// The real `SidecarProcessSource` conformer (plan Phase 2) — owns the actual
/// `llama-server` `Process`: binds `127.0.0.1:0`, reads the OS-assigned port back,
/// launches the pinned binary, and answers `checkHealth`/`terminate` against it.
///
/// Absorbed from Phase 1's `LlamaServerSidecarSpike` (now retired): the spawn/
/// port-reservation/health-check/kill mechanics are unchanged, just reshaped behind
/// the `SidecarProcessSource` seam so `SidecarLifecycleController` (LLMRuntime) can
/// drive this through the full LLD §5.1 state machine instead of the one-shot spike.
///
/// **Never a fixed port, never `0.0.0.0`** (locked decision, docs/03-architecture.md /
/// docs/04-hld.md §4.1): every `launch(model:)` call binds a **fresh** `:0` port — this
/// is what lets a post-crash relaunch never collide with a lingering socket.
actor LlamaServerProcessSource: SidecarProcessSource {

    private let logger = Logger(subsystem: Build.bundleIdentifier, category: "SidecarProcessSource")

    private var process: Process?
    private var logHandle: FileHandle?

    /// The directory containing `llama-server` + its sibling dylibs — the bundled
    /// `Contents/Resources/llama-server/` resource in a real app, or a dev override
    /// (see `AppCoordinator+Sidecar.swift`).
    private let binaryDirectory: URL
    private let logFileURL: URL
    /// Resolves a `ModelDescriptor`'s `onDiskRelativePath` to an absolute file URL.
    /// Real provisioning (Phase 5) isn't wired up yet — Phase 2's manual verification
    /// hook points this at wherever a manually-placed dev GGUF lives
    /// (docs/native-deps.md § llama-server (LLM Sidecar) § "Dev-only smoke-test model").
    private let modelsDirectory: ModelsDirectory

    init(binaryDirectory: URL, logFileURL: URL, modelsDirectory: ModelsDirectory) {
        self.binaryDirectory = binaryDirectory
        self.logFileURL = logFileURL
        self.modelsDirectory = modelsDirectory
    }

    // MARK: - SidecarProcessSource

    /// Bind `127.0.0.1:0`, launch the bundled `llama-server` on the OS-assigned port
    /// with `model`'s resolved blob, and return that port. Readiness is the caller's
    /// job (`checkHealth`, polled by `SidecarLifecycleController`) — a spawned process
    /// is not yet an accepting server.
    func launch(model: ModelDescriptor) async throws -> Int {
        let executableURL = binaryDirectory.appending(path: "llama-server")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LlamaServerProcessSourceError.binaryNotFound(executableURL)
        }
        let modelURL = modelsDirectory.blobURL(for: model)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LlamaServerProcessSourceError.modelNotFound(modelURL)
        }

        let port = try Self.reserveLoopbackPort()

        let child = Process()
        child.executableURL = executableURL
        child.arguments = [
            "--host", "127.0.0.1",
            "--port", String(port),
            "-m", modelURL.path,
            "-c", "2048",
            "--no-webui",
        ]

        let handle = try Self.openLogHandle(at: logFileURL)
        child.standardOutput = handle
        child.standardError = handle

        do {
            try child.run()
        } catch {
            try? handle.close()
            throw LlamaServerProcessSourceError.processLaunchFailed(error)
        }

        process = child
        logHandle = handle
        logger.notice(
            "Spawned llama-server pid \(Int(child.processIdentifier), privacy: .public) on 127.0.0.1:\(Int(port), privacy: .public)"
        )
        return Int(port)
    }

    /// `GET /health`, short per-call timeout. `false` covers both "responded
    /// unhealthy" and "connection refused" — indistinguishable to the caller, and
    /// both correctly mean "not ready" (docs/05-lld.md §5.1).
    func checkHealth(port: Int) async -> Bool {
        var request = URLRequest(url: healthURL(port: port))
        request.timeoutInterval = 1.0
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Kill the child cleanly — SIGTERM, then SIGKILL if it hasn't exited shortly
    /// after (no orphaned process left running). Safe to call more than once, and
    /// safe to call even if `launch` never ran.
    func terminate() async {
        defer { closeLogHandle() }
        guard let child = process, child.isRunning else {
            process = nil
            return
        }
        child.terminate()

        let deadline = Date().addingTimeInterval(2)
        while child.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
        }
        process = nil
        logger.notice("llama-server sidecar terminated.")
    }

    // MARK: - Helpers

    private func closeLogHandle() {
        try? logHandle?.close()
        logHandle = nil
    }

    private func healthURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/health")!
    }

    /// Bind a TCP socket to `127.0.0.1:0`, read back the OS-assigned port, then close
    /// it immediately so `llama-server` can bind that same port itself. There is a
    /// narrow, unavoidable TOCTOU window between the close and the child's own bind
    /// (another process could grab the port first) — acceptable here, same as Phase
    /// 1's spike; harden further (retry-on-bind-failure) if it proves flaky in practice.
    private static func reserveLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LlamaServerProcessSourceError.portReservationFailed }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw LlamaServerProcessSourceError.portReservationFailed }

        var boundAddr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &boundAddr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard getResult == 0 else { throw LlamaServerProcessSourceError.portReservationFailed }
        return UInt16(bigEndian: boundAddr.sin_port)
    }

    /// Open (create, or append to) `logs/sidecar.log` for the child's stdout/stderr —
    /// the app's log-directory convention (`StorageLayout.sidecarLogFile`).
    private static func openLogHandle(at fileURL: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        return handle
    }
}

/// Why a `launch(model:)` call failed (plan Phase 2). Kept narrow and typed, same
/// posture as Phase 1's `LlamaServerSidecarSpikeError`.
enum LlamaServerProcessSourceError: Error, CustomStringConvertible {
    case binaryNotFound(URL)
    case modelNotFound(URL)
    case portReservationFailed
    case processLaunchFailed(Error)

    var description: String {
        switch self {
        case .binaryNotFound(let url): return "llama-server binary not found at \(url.path)"
        case .modelNotFound(let url): return "Qwen GGUF model not found at \(url.path)"
        case .portReservationFailed: return "failed to reserve a dynamic loopback port"
        case .processLaunchFailed(let error): return "failed to launch llama-server: \(error)"
        }
    }
}
