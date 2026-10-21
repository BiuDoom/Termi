import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One authenticated OpenSSH ControlMaster connection.
///
/// Authentication (passwords, passphrases, 2FA codes, new host keys) happens exactly once, in
/// a background `ssh -M -N` process whose prompts are answered through the askpass bridge.
/// Terminal tabs, SFTP, port forwards and remote commands then run as multiplexed sessions
/// over the control socket — they open instantly and never ask for credentials again.
final class SSHMasterConnection: @unchecked Sendable {
    enum State: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case closed
    }

    /// Hooks into the app: UI prompts and persistence of answers the user chose to save.
    struct Callbacks: Sendable {
        var prompt: @Sendable (SSHPrompt) async -> SSHPromptResponse
        var savePassword: @Sendable (_ hostId: Int64, _ password: String) async -> Void
        var savePassphrase: @Sendable (_ keyId: Int64, _ passphrase: String) async -> Void
        var trustHostKey: @Sendable (_ hop: SSHHop, _ publicKey: String) async -> Void

        init(
            prompt: @escaping @Sendable (SSHPrompt) async -> SSHPromptResponse,
            savePassword: @escaping @Sendable (Int64, String) async -> Void = { _, _ in },
            savePassphrase: @escaping @Sendable (Int64, String) async -> Void = { _, _ in },
            trustHostKey: @escaping @Sendable (SSHHop, String) async -> Void = { _, _ in }
        ) {
            self.prompt = prompt
            self.savePassword = savePassword
            self.savePassphrase = savePassphrase
            self.trustHostKey = trustHostKey
        }
    }

    /// A process invocation that runs over this connection.
    struct Command: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    let spec: SSHConnectionSpec
    let runtime: SSHRuntime
    let directory: URL
    let configPath: String
    let controlPath: String
    let knownHostsPath: String
    var id: String { directory.lastPathComponent }
    var displayName: String { spec.target.displayName }

    private let callbacks: Callbacks
    private let token: String
    private let keyPaths: [String: String]
    private static let maxStderrBytes = 256 * 1024

    private let lock = NSLock()
    private var state: State = .idle
    private var process: Process?
    private var exitStatus: Int32?
    private var stderrData = Data()
    private var stderrClosed = false
    private var stderrConsumed = 0
    private var banner: String?
    private var closeHandlers: [UUID: @Sendable () -> Void] = [:]
    private var usedStoredSecrets = Set<String>()
    private var pendingPasswordSaves: [String: String] = [:]
    private var pendingPassphraseSaves: [String: String] = [:]
    private var promptTasks: [UUID: Task<SSHPromptResponse, Never>] = [:]
    private var cancelledByUser = false
    private var rejectedHostKeyAlias: String?
    /// known_hosts as ssh left it, read just before the connection directory is deleted.
    private var knownHostsAtExit: String?
    private var cleanedUp = false

    init(spec: SSHConnectionSpec, runtime: SSHRuntime, callbacks: Callbacks) throws {
        try spec.validate()
        self.spec = spec
        self.runtime = runtime
        self.callbacks = callbacks
        self.token = SSHRuntime.randomHex(bytes: 16)
        let directory = try runtime.makeConnectionDirectory()
        self.directory = directory
        self.configPath = directory.appendingPathComponent("config").path
        self.controlPath = directory.appendingPathComponent("s").path
        self.knownHostsPath = directory.appendingPathComponent("known_hosts").path
        var keyPaths: [String: String] = [:]
        for (index, hop) in spec.hops.enumerated() where hop.credentials.privateKey != nil {
            keyPaths[hop.alias] = directory.appendingPathComponent("k\(index)").path
        }
        self.keyPaths = keyPaths
    }

    deinit {
        // Dropping the object without close() (a cancelled connect that lost the entry, or the
        // last reference going away mid-flight) used to delete the control socket and leave ssh
        // running with nobody to answer its prompts. Signal it first. finish() still unregisters
        // the askpass token, which nobody else will.
        let running = lock.withLock { process }
        if let running {
            SSHRuntime.stop(running, grace: 1)
        }
        finish()
    }

    // MARK: - State

    var currentState: State {
        lock.withLock { state }
    }

    var isAlive: Bool {
        lock.withLock { state == .connected && exitStatus == nil }
    }

    /// Server banner and other messages printed while connecting (shown in the first terminal).
    func takeBanner() -> String? {
        lock.withLock {
            defer { banner = nil }
            return banner
        }
    }

    /// Register a handler called once when the connection closes after having been established.
    @discardableResult
    func onClose(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let alreadyClosed: Bool = lock.withLock {
            if state == .closed { return true }
            closeHandlers[id] = handler
            return false
        }
        if alreadyClosed { handler() }
        return id
    }

    func removeCloseHandler(_ id: UUID) {
        lock.withLock { closeHandlers[id] = nil }
    }

    // MARK: - Connect

    /// Launch the master and wait until authentication finished and the control socket is up.
    func connect() async throws {
        let canStart: Bool = lock.withLock {
            guard state == .idle else { return false }
            state = .connecting
            return true
        }
        guard canStart else { throw SSHError.invalidConfiguration("Connection already used") }

        runtime.askpass.register(token: token) { [weak self] request in
            guard let self else { return .cancel }
            return await self.answer(request)
        }

        do {
            try await writeFiles()
            try launch()
            try await waitUntilReady()
        } catch {
            let failure = await failure(from: error)
            // A host key the user explicitly trusted stays trusted when authentication then
            // fails or is cancelled (ssh's own known_hosts behaves the same way). In a task of
            // its own: this one may be the cancelled one, and the database refuses writes
            // from a cancelled task.
            await Task { await self.persistAcceptedHostKeys() }.value
            close()
            throw failure
        }

        lock.withLock {
            let text = Self.bannerText(String(decoding: stderrData, as: UTF8.self))
            banner = text.isEmpty ? nil : text
        }
        await persistAcceptedHostKeys()
        await applyPendingSaves()
        removeKeyFiles()
    }

    /// Terminate the master (all multiplexed sessions end with it).
    func close() {
        let (process, prompts, wasConnected, handlers): (Process?, [Task<SSHPromptResponse, Never>], Bool,
                                                         [@Sendable () -> Void]) = lock.withLock {
            // Without a running process nobody else will move us to .closed.
            if self.process == nil || exitStatus != nil { state = .closed }
            let prompts = Array(promptTasks.values)
            promptTasks.removeAll()
            let wasConnected = state == .connected
            var handlers: [@Sendable () -> Void] = []
            if wasConnected {
                // Report the close now rather than when the process exits: after an idle
                // close nothing keeps this object alive until then (processDidExit would
                // never run and the handlers would be lost).
                state = .closed
                handlers = Array(closeHandlers.values)
                closeHandlers.removeAll()
            }
            return (self.process, prompts, wasConnected, handlers)
        }
        prompts.forEach { $0.cancel() }
        guard let process, process.isRunning else {
            finish()
            handlers.forEach { $0() }
            return
        }
        if wasConnected {
            // Graceful shutdown through the control socket; signals are the fallback.
            let exit = Process()
            exit.executableURL = URL(fileURLWithPath: runtime.sshPath)
            exit.arguments = ["-F", configPath, "-O", "exit", spec.target.alias]
            exit.environment = runtime.environment(askpassToken: nil)
            exit.standardInput = FileHandle.nullDevice
            exit.standardOutput = FileHandle.nullDevice
            exit.standardError = FileHandle.nullDevice
            try? exit.run()
        }
        SSHRuntime.stop(process)
        handlers.forEach { $0() }
    }

    private func writeFiles() async throws {
        for hop in spec.hops {
            guard let key = hop.credentials.privateKey, let path = keyPaths[hop.alias] else { continue }
            var pem = key.pem.replacingOccurrences(of: "\r\n", with: "\n")
            if !pem.hasSuffix("\n") { pem += "\n" }
            try SSHRuntime.writePrivateFile(pem, to: URL(fileURLWithPath: path))
        }
        try SSHRuntime.writePrivateFile(SSHConfigRenderer.knownHosts(for: spec),
                                        to: URL(fileURLWithPath: knownHostsPath))

        var files = SSHConfigRenderer.Files(knownHostsPath: knownHostsPath, controlPath: controlPath,
                                            identityFiles: keyPaths)
        let target = spec.target
        if target.agentForwarding, target.credentials.privateKey != nil, !target.credentials.useSystemAgent,
           let keyPath = keyPaths[target.alias] {
            files.agentSocketPath = try await runtime.agentSocketPath()
            try await runtime.addToAgent(keyPath: keyPath, askpassToken: token)
        }
        try SSHRuntime.writePrivateFile(SSHConfigRenderer.render(spec, files: files),
                                        to: URL(fileURLWithPath: configPath))
    }

    private func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.sshPath)
        process.arguments = [
            "-F", configPath, "-M", "-N", "-T",
            "-o", "LogLevel=INFO",
            "-o", "ClearAllForwardings=yes",
            spec.target.alias,
        ]
        process.environment = runtime.environment(askpassToken: token)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] finished in
            self?.processDidExit(status: finished.terminationStatus)
        }
        lock.withLock { self.process = process }
        try process.run()

        let handle = errorPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty {
                    self.lock.withLock { self.stderrClosed = true }
                    return
                }
                self.lock.withLock {
                    self.stderrData.append(data)
                    let overflow = self.stderrData.count - Self.maxStderrBytes
                    if overflow > 0 {
                        self.stderrData.removeFirst(overflow)
                        self.stderrConsumed = max(0, self.stderrConsumed - overflow)
                    }
                }
            }
        }
    }

    private func waitUntilReady() async throws {
        while true {
            try Task.checkCancellation()
            let exited = lock.withLock { exitStatus != nil }
            if exited { throw SSHError.disconnected }
            if FileManager.default.fileExists(atPath: controlPath) {
                let ready: Bool = lock.withLock {
                    guard state == .connecting, exitStatus == nil else { return false }
                    state = .connected
                    return true
                }
                if ready { return }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func processDidExit(status: Int32) {
        // finish() deletes the directory before a failed connect() gets to read the host
        // keys the user accepted, so keep a copy (see persistAcceptedHostKeys).
        let knownHosts = try? String(contentsOfFile: knownHostsPath, encoding: .utf8)
        let handlers: [@Sendable () -> Void] = lock.withLock {
            exitStatus = status
            knownHostsAtExit = knownHosts
            let wasConnected = state == .connected
            state = .closed
            let handlers = wasConnected ? Array(closeHandlers.values) : []
            closeHandlers.removeAll()
            return handlers
        }
        finish()
        handlers.forEach { $0() }
    }

    private func finish() {
        runtime.askpass.unregister(token: token)
        cleanupFiles()
    }

    private func cleanupFiles() {
        let shouldClean: Bool = lock.withLock {
            guard !cleanedUp else { return false }
            cleanedUp = true
            return true
        }
        if shouldClean {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func removeKeyFiles() {
        for path in keyPaths.values {
            unlink(path)
        }
    }

    // MARK: - Failure classification

    private func failure(from error: Error) async -> SSHError {
        if error is CancellationError { return .cancelled }
        if let sshError = error as? SSHError, sshError != .disconnected { return sshError }

        // The process exited: give stderr a moment to drain before reading it.
        for _ in 0..<40 {
            if lock.withLock({ stderrClosed }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let (stderr, cancelled, rejectedAlias) = lock.withLock {
            (String(decoding: stderrData, as: UTF8.self), cancelledByUser, rejectedHostKeyAlias)
        }
        if cancelled { return .cancelled }
        return Self.classifyFailure(stderr: stderr, rejectedHostKeyAlias: rejectedAlias, spec: spec)
    }

    static func classifyFailure(stderr: String, rejectedHostKeyAlias: String?, spec: SSHConnectionSpec) -> SSHError {
        func hop(named name: String?) -> SSHHop? {
            guard let name else { return nil }
            return spec.hops.first { $0.alias == name } ?? spec.hops.first { $0.hostname == name }
        }
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)),
                  match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: stderr) else { return nil }
            return String(stderr[range])
        }

        if let alias = rejectedHostKeyAlias {
            return .hostKeyRejected(host: hop(named: alias)?.displayName ?? spec.target.displayName)
        }
        let lines = informationalOutput(stderr).split(whereSeparator: \.isNewline).map(String.init)
        let lastLine = lines.last ?? ""

        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
            || stderr.contains("Host key verification failed") {
            let offending = hop(named: capture(#"Host key for (\S+) has changed"#))
            let fingerprint = capture(#"(SHA256:[A-Za-z0-9+/=]+)"#) ?? ""
            return .hostKeyChanged(host: (offending ?? spec.target).displayName, detail: fingerprint)
        }
        if stderr.contains("Permission denied") || stderr.contains("Too many authentication failures")
            || stderr.contains("No more authentication methods") {
            let failedHop = hop(named: capture(#"@(\S+?): Permission denied"#))
            return .authenticationFailed(host: (failedHop ?? spec.target).displayName, detail: lastLine)
        }
        return .connectionFailed(host: spec.target.displayName, detail: humanize(lastLine))
    }

    /// stderr minus noise that users should not see.
    static func informationalOutput(_ stderr: String) -> String {
        stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty
                    && !line.hasPrefix("Warning: Permanently added")
                    && !line.hasPrefix("Authenticated to")
                    && !line.contains("ControlSocket")
                    && !line.hasPrefix("Transferred:")
            }
            .joined(separator: "\n")
    }

    /// ssh's notice after an answer the server did not accept.
    static let retryNotice = "Permission denied, please try again."

    /// What the first terminal shows above the shell: the server's banner, without ssh's
    /// notices about answers that were rejected on the way to the one that got in.
    static func bannerText(_ stderr: String) -> String {
        informationalOutput(stderr).split(whereSeparator: \.isNewline)
            .filter { $0 != retryNotice }
            .joined(separator: "\n")
    }

    private static func humanize(_ line: String) -> String {
        var text = line
        // "ssh: connect to host x port 22: Connection refused" → "Connection refused"
        if let range = text.range(of: #"^ssh: connect to host \S+ port \d+: "#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        if text.hasPrefix("ssh: ") { text.removeFirst(5) }
        // Aliases are internal; never show "termi-h0".
        if let range = text.range(of: #"termi-h\d+"#, options: .regularExpression) {
            text.replaceSubrange(range, with: "host")
        }
        return text
    }

    // MARK: - Prompts

    private enum SaveKind {
        case password, passphrase
    }

    private func hop(alias: String?) -> SSHHop? {
        guard let alias else { return spec.hops.count == 1 ? spec.target : nil }
        return spec.hops.first { $0.alias == alias } ?? spec.hops.first { $0.hostname == alias }
    }

    private func hop(keyPath: String) -> SSHHop? {
        // ssh truncates the path in its prompt to 100 characters.
        guard let alias = keyPaths.first(where: { $0.value == keyPath || $0.value.hasPrefix(keyPath) })?.key else {
            return nil
        }
        return hop(alias: alias)
    }

    /// Hand out a stored secret only once per hop and prompt type; a second prompt means it was wrong.
    private func takeStoredSecret(_ key: String) -> Bool {
        lock.withLock { usedStoredSecrets.insert(key).inserted }
    }

    private func takeRecentOutput() -> String? {
        lock.withLock {
            let pending = stderrData.count > stderrConsumed ? stderrData.suffix(from: stderrConsumed) : Data()
            stderrConsumed = stderrData.count
            let text = Self.informationalOutput(String(decoding: pending, as: UTF8.self))
            return text.isEmpty ? nil : text
        }
    }

    func answer(_ request: AskpassRequest) async -> AskpassReply {
        let kind = SSHPromptParser.kind(of: request.prompt, hint: request.hint)
        switch kind {
        case .password(let alias):
            let hop = hop(alias: alias)
            if let hop, let stored = hop.credentials.password, !stored.isEmpty,
               takeStoredSecret("password:\(hop.alias)") {
                return .answer(stored)
            }
            return await askUser(kind: kind, request: request, hop: hop, isSecret: true,
                                 save: hop?.hostId != nil ? .password : nil)

        case .keyboardInteractive(let alias, let question):
            let hop = hop(alias: alias)
            let asksPassword = question.lowercased().contains("password")
            if asksPassword, let hop, let stored = hop.credentials.password, !stored.isEmpty,
               takeStoredSecret("kbd:\(hop.alias)") {
                return .answer(stored)
            }
            return await askUser(kind: kind, request: request, hop: hop, isSecret: true,
                                 save: asksPassword && hop?.hostId != nil ? .password : nil)

        case .passphrase(let keyPath):
            let hop = hop(keyPath: keyPath)
            let key = hop?.credentials.privateKey
            if let hop, let stored = key?.passphrase, !stored.isEmpty,
               takeStoredSecret("passphrase:\(hop.alias):\(keyPath)") {
                return .answer(stored)
            }
            return await askUser(kind: kind, request: request, hop: hop, isSecret: true,
                                 save: key?.keyId != nil ? .passphrase : nil)

        case .hostKey(let alias, _, _):
            let hop = hop(alias: alias)
            let response = await presentPrompt(makePrompt(kind: kind, request: request, hop: hop,
                                                          isSecret: false, canSave: false))
            if response == .accept {
                return .answer("yes")
            }
            lock.withLock { rejectedHostKeyAlias = hop?.alias ?? alias ?? spec.target.alias }
            return .answer("no")

        case .confirmation:
            let response = await presentPrompt(makePrompt(kind: kind, request: request, hop: nil,
                                                          isSecret: false, canSave: false))
            return response == .accept ? .answer("yes") : .cancel

        case .other:
            return await askUser(kind: kind, request: request, hop: nil, isSecret: true, save: nil)
        }
    }

    private func makePrompt(kind: SSHPromptKind, request: AskpassRequest, hop: SSHHop?,
                            isSecret: Bool, canSave: Bool) -> SSHPrompt {
        SSHPrompt(
            kind: kind,
            hopDisplayName: hop?.displayName,
            hopEndpoint: hop?.endpointDescription,
            connectionName: spec.target.displayName,
            message: humanizePrompt(request.prompt),
            details: takeRecentOutput(),
            canSave: canSave,
            isSecret: isSecret
        )
    }

    /// Replace internal aliases in prompt text with the hop's real address.
    private func humanizePrompt(_ text: String) -> String {
        var result = text
        for hop in spec.hops {
            result = result.replacingOccurrences(of: hop.alias, with: hop.hostname)
        }
        for path in keyPaths.values {
            result = result.replacingOccurrences(of: path, with: "private key")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func askUser(kind: SSHPromptKind, request: AskpassRequest, hop: SSHHop?,
                         isSecret: Bool, save: SaveKind?) async -> AskpassReply {
        let prompt = makePrompt(kind: kind, request: request, hop: hop, isSecret: isSecret, canSave: save != nil)
        switch await presentPrompt(prompt) {
        case .text(let value, let shouldSave):
            if let save, let hop {
                // The latest answer decides: a rejected earlier one must not be saved instead.
                lock.withLock {
                    switch save {
                    case .password: pendingPasswordSaves[hop.alias] = shouldSave ? value : nil
                    case .passphrase: pendingPassphraseSaves[hop.alias] = shouldSave ? value : nil
                    }
                }
            }
            return .answer(value)
        case .accept:
            return .answer("yes")
        case .reject, .cancel:
            lock.withLock { cancelledByUser = true }
            // Abort right away instead of letting ssh cycle through its remaining attempts.
            if let process = lock.withLock({ self.process }) {
                SSHRuntime.stop(process)
            }
            return .cancel
        }
    }

    /// Show a prompt; cancelled automatically when the connection is closed.
    private func presentPrompt(_ prompt: SSHPrompt) async -> SSHPromptResponse {
        let id = UUID()
        let callbacks = self.callbacks
        let task = Task { await callbacks.prompt(prompt) }
        let isClosed: Bool = lock.withLock {
            if state == .closed { return true }
            promptTasks[id] = task
            return false
        }
        if isClosed { task.cancel() }
        let response = await task.value
        lock.withLock { promptTasks[id] = nil }
        return response
    }

    // MARK: - After connecting

    private func persistAcceptedHostKeys() async {
        // Once ssh has exited the file is gone; processDidExit kept its content.
        let saved = lock.withLock { knownHostsAtExit }
        guard let content = (try? String(contentsOfFile: knownHostsPath, encoding: .utf8)) ?? saved else { return }
        var known = Set<String>()
        for hop in spec.hops {
            for key in hop.knownHostKeys {
                let parts = key.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2 else { continue }
                known.insert("\(hop.alias) \(parts[0]) \(parts[1])")
            }
        }
        for entry in SSHConfigRenderer.parseKnownHosts(content)
        where !known.contains("\(entry.alias) \(entry.key)") {
            guard let hop = spec.hops.first(where: { $0.alias == entry.alias }) else { continue }
            await callbacks.trustHostKey(hop, entry.key)
        }
    }

    private func applyPendingSaves() async {
        let (passwords, passphrases) = lock.withLock {
            defer {
                pendingPasswordSaves.removeAll()
                pendingPassphraseSaves.removeAll()
            }
            return (pendingPasswordSaves, pendingPassphraseSaves)
        }
        for (alias, password) in passwords {
            if let hostId = hop(alias: alias)?.hostId {
                await callbacks.savePassword(hostId, password)
            }
        }
        for (alias, passphrase) in passphrases {
            if let keyId = hop(alias: alias)?.credentials.privateKey?.keyId {
                await callbacks.savePassphrase(keyId, passphrase)
            }
        }
    }

    // MARK: - Sessions over the master

    private var sessionEnvironment: [String: String] {
        runtime.environment(askpassToken: token)
    }

    /// Interactive shell (run inside a PTY). `-t` requests a remote terminal.
    func interactiveCommand(forwardX11: Bool = false, remoteCommand: String? = nil) -> Command {
        var arguments = ["-F", configPath, "-t", "-o", "ClearAllForwardings=yes"]
        if forwardX11 { arguments.append("-X") }
        arguments.append(spec.target.alias)
        if let remoteCommand { arguments.append(remoteCommand) }
        return Command(executable: runtime.sshPath, arguments: arguments, environment: sessionEnvironment)
    }

    /// Non-interactive remote command (stdin from /dev/null).
    func execCommand(_ remoteCommand: String) -> Command {
        Command(
            executable: runtime.sshPath,
            arguments: ["-F", configPath, "-T", "-n", "-o", "ClearAllForwardings=yes",
                        spec.target.alias, remoteCommand],
            environment: sessionEnvironment
        )
    }

    /// SFTP subsystem session; speak the SFTP protocol over stdin/stdout.
    func sftpCommand() -> Command {
        Command(
            executable: runtime.sshPath,
            arguments: ["-F", configPath, "-T", "-o", "ClearAllForwardings=yes", "-s", spec.target.alias, "sftp"],
            environment: sessionEnvironment
        )
    }

    /// Run a remote command and collect its output.
    func run(_ remoteCommand: String) async throws -> ProcessRunner.Result {
        guard isAlive else { throw SSHError.disconnected }
        let command = execCommand(remoteCommand)
        return try await ProcessRunner.run(command.executable, arguments: command.arguments,
                                           environment: command.environment)
    }

    /// Add a port forward to the live connection (`ssh -O forward`).
    func addForward(_ forward: SSHForward) async throws {
        try await control("forward", forward.arguments)
    }

    /// Remove a port forward previously added with `addForward`.
    func cancelForward(_ forward: SSHForward) async throws {
        try await control("cancel", forward.arguments)
    }

    private func control(_ operation: String, _ extra: [String]) async throws {
        guard isAlive else { throw SSHError.disconnected }
        let result = try await ProcessRunner.run(
            runtime.sshPath,
            arguments: ["-F", configPath, "-O", operation] + extra + [spec.target.alias],
            environment: sessionEnvironment
        )
        guard result.exitCode == 0 else {
            let message = Self.informationalOutput(result.stderr)
            throw SSHError.forwardFailed(message.isEmpty ? "exit code \(result.exitCode)" : Self.humanize(message))
        }
    }
}
