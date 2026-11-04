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
            // A crash can leave this pid's directory behind. Reuse that real directory;
            // a symlink at the same path is not a directory and must not be followed.
            try Self.makePrivateDirectory(directory, reuseExisting: true)
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

    /// What a signal for a pid is still known to hit.
    enum StopScope: Equatable {
        /// The process leads its own group, or that leader has exited while other members
        /// still hold the group id.
        case processGroup
        /// This pid only. It is not the leader of a group this call may signal.
        case process
    }

    /// SIGTERM the process group now, and SIGKILL it if anything is still there after `grace`.
    ///
    /// Foundation starts `Process` in its own group. Signalling only the leader leaves a
    /// ProxyJump `ssh`, a ProxyCommand, or a grandchild running after the leader exits, and a
    /// child can inherit a blocked SIGTERM from the thread that spawned it.
    ///
    /// The scope is decided again before the SIGKILL. A process-group id can be reused as soon
    /// as its last member has exited, so the decision from the SIGTERM is not safe to replay
    /// a few seconds later: `kill(-pid, SIGKILL)` would then reach whatever new group had taken
    /// the id. A live pid is ours only while this `Process` is still running and leads the
    /// group. If that pid is already gone and the group still exists, the remaining members are
    /// the ones we spawned — the id stays reserved until they exit. The application's own group
    /// is never signalled, and neither is pid 1 (`kill(-1, …)` would signal every process).
    static func stop(_ process: Process, grace: TimeInterval = 3) {
        let pid = process.processIdentifier
        switch stopScope(of: pid, leaderStillRunning: process.isRunning) {
        case .processGroup:
            kill(-pid, SIGTERM)
        case .process:
            process.terminate()
        case nil:
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            switch stopScope(of: pid, leaderStillRunning: process.isRunning) {
            case .processGroup:
                kill(-pid, SIGKILL)
            case .process:
                kill(pid, SIGKILL)
            case nil:
                break
            }
        }
    }

    /// Where a signal for `pid` still cannot be a recycled process-group id.
    /// `leaderStillRunning` is `isRunning` of the `Process` this app spawned.
    static func stopScope(of pid: Int32, leaderStillRunning: Bool) -> StopScope? {
        guard pid > 1, pid != getpgrp() else { return nil }
        if leaderStillRunning, getpgid(pid) == pid {
            return .processGroup
        }
        // The leader's pid is free only after the whole group is gone. Re-check it after
        // the group probe: a pid reused in between belongs to a new leader and must not
        // be signalled.
        if !isProcessAlive(pid), kill(-pid, 0) == 0, !isProcessAlive(pid) {
            return .processGroup
        }
        if leaderStillRunning, isProcessAlive(pid) {
            return .process
        }
        return nil
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

    /// Create `url` as a directory only this user can list or add to.
    ///
    /// `FileManager.createDirectory` asks `mkdir` for 0777 and applies the requested mode
    /// afterwards, so the directory exists as 0755 (or 0777, when the umask is 0) before
    /// `chmod`. In a shared temporary directory another account can add a name in that gap —
    /// a symlink where a private key or the askpass socket is about to be written.
    /// `mkdir(0700)` is masked by umask and so is never wider than 0700. `fchmod` on the
    /// directory fd then sets 0700 exactly, in case the mask cleared the execute bit.
    ///
    /// `fileExists` and `chmod` follow a symlink. A link planted at `url` used to be treated
    /// as the directory and its target chmod'd to 0700, after which key files were written
    /// through the link. `mkdir` fails when the name exists, and the fd is opened with
    /// `O_NOFOLLOW`, so the target is left untouched.
    ///
    /// A directory this call created must still be empty once it is 0700: a name that appeared
    /// in the gap is refused and the directory is removed. An existing directory is reused
    /// only when `reuseExisting` is set (the runtime directory, whose name is the pid and which
    /// a crashed run may have left behind). It still has to be a real directory this user owns.
    static func makePrivateDirectory(_ url: URL, reuseExisting: Bool = false) throws {
        if mkdir(url.path, 0o700) == 0 {
            do {
                try secureOwnerOnlyDirectory(at: url, requireEmpty: true)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return
        }
        let createError = errno
        if createError == EEXIST, reuseExisting {
            try secureOwnerOnlyDirectory(at: url, requireEmpty: false)
            return
        }
        let reason = String(cString: strerror(createError))
        throw SSHError.invalidConfiguration("Cannot create \(url.lastPathComponent): \(reason)")
    }

    /// `mode` 0700 on the directory fd, which is the directory itself and not a symlink.
    /// When `requireEmpty` is set, a name already inside it is an error: the caller has not
    /// written anything yet, so the name belongs to someone else.
    static func secureOwnerOnlyDirectory(at url: URL, requireEmpty: Bool) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw SSHError.invalidConfiguration(
                "Cannot secure \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        // Owned by this user before the mode changes. As root, fchmod would succeed on
        // somebody else's directory; that directory is not this runtime.
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw SSHError.invalidConfiguration(
                "Cannot secure \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw SSHError.invalidConfiguration("Cannot secure \(url.lastPathComponent)")
        }
        guard fchmod(fd, 0o700) == 0 else {
            throw SSHError.invalidConfiguration(
                "Cannot secure \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        var secured = stat()
        guard fstat(fd, &secured) == 0 else {
            throw SSHError.invalidConfiguration(
                "Cannot secure \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        let mode = UInt32(secured.st_mode) & 0o777
        guard mode == 0o700 else {
            throw SSHError.invalidConfiguration("Cannot secure \(url.lastPathComponent)")
        }
        // The path still names this directory. A symlink put in its place has a different
        // identity, and lstat does not follow it into looking like the directory.
        var linked = stat()
        guard lstat(url.path, &linked) == 0, linked.st_dev == secured.st_dev, linked.st_ino == secured.st_ino else {
            throw SSHError.invalidConfiguration("Cannot secure \(url.lastPathComponent)")
        }
        if requireEmpty {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            } catch {
                throw SSHError.invalidConfiguration("Cannot secure \(url.lastPathComponent)")
            }
            guard names.isEmpty else {
                throw SSHError.invalidConfiguration("Cannot secure \(url.lastPathComponent)")
            }
            // Listed the directory this fd holds, not a name put in its place afterwards.
            var listed = stat()
            guard lstat(url.path, &listed) == 0, listed.st_dev == secured.st_dev, listed.st_ino == secured.st_ino else {
                throw SSHError.invalidConfiguration("Cannot secure \(url.lastPathComponent)")
            }
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
