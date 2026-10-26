import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Process-wide SSH plumbing shared by all connections:
/// - a private 0700 runtime directory (control sockets, generated configs, temporary keys)
/// - the askpass bridge server
/// - an app-private `ssh-agent`, started on demand to forward vault keys
///
/// The directory name embeds the app's PID so leftovers from a crashed run can be
/// recognised and their orphaned master connections shut down on the next launch.
final class SSHRuntime: @unchecked Sendable {
    static let directoryPrefix = "bmt-"

    let sshPath: String
    let sshAddPath: String
    let sshAgentPath: String
    /// Executable that ssh runs as SSH_ASKPASS (the app binary itself in production).
    let askpassExecutable: String
    let directory: URL
    let askpass: AskpassServer

    private let lock = NSLock()
    private var started = false
    private var agentProcess: Process?
    private var agentSocket: String?

    init(
        askpassExecutable: String,
        sshPath: String = "/usr/bin/ssh",
        sshAddPath: String = "/usr/bin/ssh-add",
        sshAgentPath: String = "/usr/bin/ssh-agent",
        parentDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.askpassExecutable = askpassExecutable
        self.sshPath = sshPath
        self.sshAddPath = sshAddPath
        self.sshAgentPath = sshAgentPath
        let name = "\(Self.directoryPrefix)\(getpid())"
        self.directory = parentDirectory.appendingPathComponent(name, isDirectory: true)
        self.askpass = AskpassServer(socketPath: directory.appendingPathComponent("a").path)
    }

    /// Create the runtime directory and start the askpass server. Safe to call repeatedly.
    func start() throws {
        try lock.withLock {
            guard !started else { return }
            try Self.makePrivateDirectory(directory)
            try askpass.start()
            started = true
        }
    }

    /// Stop the askpass server and agent and delete the runtime directory.
    /// Master connections must be closed first (see `SSHConnectionManager.shutdown`).
    func shutdown() {
        let agent: Process? = lock.withLock {
            let agent = agentProcess
            agentProcess = nil
            agentSocket = nil
            started = false
            return agent
        }

        if let agent { Self.stop(agent) }
        askpass.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    /// A fresh private directory for one master connection.
    func makeConnectionDirectory() throws -> URL {
        try start()
        let url = directory.appendingPathComponent("c" + Self.randomHex(bytes: 3), isDirectory: true)
        try Self.makePrivateDirectory(url)
        return url
    }

    /// Minimal environment for ssh subprocesses. Parent-process secrets (API tokens etc.)
    /// are not passed on. With a token, prompts are routed through the askpass bridge.
    func environment(askpassToken: String?) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "PATH": parent["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": parent["HOME"] ?? NSHomeDirectory(),
            "USER": parent["USER"] ?? NSUserName(),
            "LOGNAME": parent["LOGNAME"] ?? parent["USER"] ?? NSUserName(),
            "LANG": parent["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_US.UTF-8",
            "TERM": "xterm-256color",
        ]
        if let tmp = parent["TMPDIR"] { environment["TMPDIR"] = tmp }
        if let authSocket = parent["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = authSocket }
        if let display = parent["DISPLAY"] { environment["DISPLAY"] = display }
        if let token = askpassToken {
            environment["SSH_ASKPASS"] = askpassExecutable
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment[AskpassClient.modeVariable] = "1"
            environment[AskpassClient.socketVariable] = askpass.socketPath
            environment[AskpassClient.tokenVariable] = token
        }
        return environment
    }

    // MARK: - App-private ssh-agent

    /// Socket of the app's own ssh-agent, starting it if needed.
    func agentSocketPath() async throws -> String {
        if let socket = currentAgentSocket() { return socket }
        try start()

        let socket = directory.appendingPathComponent("g").path
        unlink(socket)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshAgentPath)
        process.arguments = ["-D", "-a", socket]
        process.environment = environment(askpassToken: nil)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) {
            guard process.isRunning else { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard process.isRunning, FileManager.default.fileExists(atPath: socket) else {
            Self.stop(process)
            throw SSHError.invalidConfiguration("ssh-agent failed to start")
        }

        let winner: String = lock.withLock {
            if let existing = agentSocket {
                return existing
            }
            agentProcess = process
            agentSocket = socket
            return socket
        }
        if winner != socket {
            // Lost a race with another caller — keep the first agent.
            Self.stop(process)
        }
        return winner
    }

    private func currentAgentSocket() -> String? {
        lock.withLock {
            guard let process = agentProcess, process.isRunning else { return nil }
            return agentSocket
        }
    }

    /// Add a key file to the app-private agent. Passphrase prompts go through askpass.
    func addToAgent(keyPath: String, askpassToken: String) async throws {
        let socket = try await agentSocketPath()
        var env = environment(askpassToken: askpassToken)
        env["SSH_AUTH_SOCK"] = socket
        let result = try await ProcessRunner.run(sshAddPath, arguments: ["-q", keyPath], environment: env)
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHError.invalidConfiguration(message.isEmpty ? "ssh-add failed" : message)
        }
    }

    // MARK: - Process helpers

    /// SIGTERM the process group now, and SIGKILL it if anything is still there after `grace`.
    ///
    /// Foundation starts `Process` in its own group. Signalling only the leader leaves a
    /// ProxyJump `ssh`, a ProxyCommand, or a grandchild running after the leader exits, and a
    /// child can inherit a blocked SIGTERM from the thread that spawned it. The group's id is
    /// taken only while this process is still running, so a later `stop` of an exited process
    /// (a master released long after `ssh` quit) cannot hit a pid that has been reused. A group
    /// id stays reserved until its last member is gone, so the follow-up SIGKILL reaches this
    /// group or fails with `ESRCH`. The application's own group is never signalled.
    static func stop(_ process: Process, grace: TimeInterval = 3) {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        // `getpgid` fails if the leader exits in this window; members can still be in the group.
        // The running check above is what keeps a long-dead pid from matching some other group.
        let ownsGroup = pid != getpgrp() && (getpgid(pid) == pid || kill(-pid, 0) == 0)
        if ownsGroup {
            kill(-pid, SIGTERM)
        } else {
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if ownsGroup {
                kill(-pid, SIGKILL)
            } else if process.isRunning, kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - Leftovers from previous runs

    /// Shut down master connections orphaned by a crashed previous run and delete their files.
    ///
    /// `ssh -O exit` against a wedged control socket can sit forever. `exitTimeout` bounds that
    /// wait; the process is then signalled so a crashed run cannot pin a thread or leave an ssh.
    static func cleanupStaleDirectories(in parent: URL = FileManager.default.temporaryDirectory,
                                        sshPath: String = "/usr/bin/ssh",
                                        exitTimeout: TimeInterval = 2) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(directoryPrefix) {
            guard let pid = Int32(entry.lastPathComponent.dropFirst(directoryPrefix.count)),
                  pid != getpid(), !isProcessAlive(pid) else { continue }
            let connections = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
            for connection in connections {
                let control = connection.appendingPathComponent("s").path
                guard fm.fileExists(atPath: control) else { continue }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: sshPath)
                process.arguments = ["-F", "/dev/null", "-S", control, "-O", "exit", "termi-orphan"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil {
                    if !waitUntilExit(process, timeout: exitTimeout) {
                        stop(process, grace: 0.2)
                        _ = waitUntilExit(process, timeout: 1)
                    }
                }
            }
            try? fm.removeItem(at: entry)
        }
    }

    /// True once `process` has exited. Returns false if it is still running when `timeout` elapses.
    static func waitUntilExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: min(0.05, max(0.001, deadline.timeIntervalSinceNow)))
        }
        return !process.isRunning
    }

    static func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - File helpers

    static func makePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SSHError.invalidConfiguration("\(url.path) is not a directory")
            }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw SSHError.invalidConfiguration("Cannot secure \(url.path)")
        }
    }

    enum PrivateFileError: Error, Equatable {
        /// `O_EXCL` lost: something else created the path first. Callers that must not replace
        /// an existing secret (the vault key) re-read it instead of writing a second one.
        case alreadyExists
        case io(String)
    }

    /// Create a new file and write `data` with `permissions` from the first byte.
    ///
    /// Foundation's atomic write creates the file as 0666 masked by umask (0644) and only then
    /// chmod's it. `fchmod` on this fd sets `permissions` before any byte is written, so umask
    /// cannot widen it. `O_NOFOLLOW` refuses a symlink planted at the path. `O_EXCL` leaves an
    /// existing file untouched.
    static func createPrivateFile(_ data: Data, at url: URL, permissions: mode_t = 0o600, sync: Bool = false) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, permissions)
        guard fd >= 0 else {
            if errno == EEXIST { throw PrivateFileError.alreadyExists }
            throw PrivateFileError.io("Cannot create \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        guard fchmod(fd, permissions) == 0 else {
            unlink(url.path)
            throw PrivateFileError.io("Cannot secure \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        let wrote: Bool = data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var written = 0
            while written < buffer.count {
                let n = write(fd, base.advanced(by: written), buffer.count - written)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                written += n
            }
            return true
        }
        guard wrote else {
            unlink(url.path)
            throw PrivateFileError.io("Cannot write \(url.lastPathComponent)")
        }
        if sync, fsync(fd) != 0 {
            unlink(url.path)
            throw PrivateFileError.io("Cannot store \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    /// Replace `url` with `data` at `permissions`. The temporary file is created in the same
    /// directory (so `rename` is atomic) and is never group- or world-readable, including the
    /// moment it takes the destination's name.
    static func replacePrivateFile(_ data: Data, at url: URL, permissions: mode_t = 0o600) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        do {
            try createPrivateFile(data, at: temporary, permissions: permissions)
            guard rename(temporary.path, url.path) == 0 else {
                throw PrivateFileError.io("Cannot replace \(url.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    /// Create a new file with the given permissions atomically (O_CREAT|O_EXCL — no TOCTOU window).
    static func writePrivateFile(_ contents: String, to url: URL, permissions: mode_t = 0o600) throws {
        do {
            try createPrivateFile(Data(contents.utf8), at: url, permissions: permissions)
        } catch PrivateFileError.alreadyExists {
            throw SSHError.invalidConfiguration("Cannot create \(url.lastPathComponent): \(String(cString: strerror(EEXIST)))")
        } catch PrivateFileError.io(let message) {
            throw SSHError.invalidConfiguration(message)
        }
    }

    static func randomHex(bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
