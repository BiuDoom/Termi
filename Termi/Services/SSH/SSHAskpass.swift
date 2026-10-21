import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Wire protocol

/// One askpass question, sent by the askpass helper process to the app (one JSON line).
struct AskpassRequest: Codable, Sendable, Equatable {
    var token: String
    var prompt: String
    /// Value of SSH_ASKPASS_PROMPT ("confirm" for yes/no questions), if any.
    var hint: String?
}

/// The app's answer (one JSON line). `ok == false` makes the helper exit non-zero (= cancel / "no").
struct AskpassReply: Codable, Sendable, Equatable {
    var ok: Bool
    var value: String?

    static let cancel = AskpassReply(ok: false, value: nil)
    static func answer(_ value: String) -> AskpassReply { AskpassReply(ok: true, value: value) }
}

// MARK: - Client (runs inside the SSH_ASKPASS helper process)

/// When ssh needs a password it executes `$SSH_ASKPASS "<prompt>"` and reads the answer from
/// stdout. Termi points SSH_ASKPASS at its own executable; `main.swift` detects the marker
/// variable and runs `AskpassClient.run()` instead of starting the UI. The helper forwards the
/// prompt over a private Unix socket and prints whatever the app answers.
enum AskpassClient {
    static let modeVariable = "TERMI_ASKPASS"
    static let socketVariable = "TERMI_ASKPASS_SOCKET"
    static let tokenVariable = "TERMI_ASKPASS_TOKEN"

    static var isAskpassInvocation: Bool {
        ProcessInfo.processInfo.environment[modeVariable] == "1"
    }

    /// Returns the process exit status: 0 = answered, 1 = cancelled / failed.
    static func run(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        guard let socketPath = environment[socketVariable],
              let token = environment[tokenVariable] else {
            return 1
        }
        let prompt = arguments.dropFirst().joined(separator: " ")
        let request = AskpassRequest(token: token, prompt: prompt, hint: environment["SSH_ASKPASS_PROMPT"])
        guard let reply = exchange(request, socketPath: socketPath), reply.ok else {
            return 1
        }
        if let value = reply.value {
            FileHandle.standardOutput.write(Data((value + "\n").utf8))
        }
        return 0
    }

    static func exchange(_ request: AskpassRequest, socketPath: String) -> AskpassReply? {
        guard let payload = try? JSONEncoder().encode(request) else { return nil }
        let fd = socket(AF_UNIX, UnixSocket.streamType, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        UnixSocket.disableSigPipe(fd)
        guard UnixSocket.connect(fd, path: socketPath) else { return nil }
        guard UnixSocket.writeAll(fd, payload + Data([0x0A])) else { return nil }
        // The answer may take as long as the user needs to type a password — no timeout.
        guard let line = UnixSocket.readLine(fd, limit: 1 << 20) else { return nil }
        return try? JSONDecoder().decode(AskpassReply.self, from: line)
    }
}

// MARK: - Server (runs in the app)

/// Unix-socket server answering askpass requests. Each ssh process tree gets a random token
/// that selects the handler (i.e. the connection) responsible for its prompts.
final class AskpassServer: @unchecked Sendable {
    typealias Handler = @Sendable (AskpassRequest) async -> AskpassReply

    let socketPath: String
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.termi.Termi.askpass")

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }

        unlink(socketPath)
        let fd = socket(AF_UNIX, UnixSocket.streamType, 0)
        guard fd >= 0 else { throw SSHError.invalidConfiguration("askpass socket: \(String(cString: strerror(errno)))") }
        guard UnixSocket.bind(fd, path: socketPath) else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw SSHError.invalidConfiguration("askpass bind: \(message)")
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 32) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw SSHError.invalidConfiguration("askpass listen: \(message)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending(listenFD: fd)
        }
        source.setCancelHandler {
            close(fd)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        lock.lock()
        let source = self.source
        self.source = nil
        handlers.removeAll()
        lock.unlock()
        source?.cancel()
        unlink(socketPath)
    }

    func register(token: String, handler: @escaping Handler) {
        lock.lock()
        handlers[token] = handler
        lock.unlock()
    }

    func unregister(token: String) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    private func handler(for token: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[token]
    }

    private func acceptPending(listenFD: Int32) {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            // BSD sockets inherit O_NONBLOCK from the listening socket.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            UnixSocket.disableSigPipe(client)
            serve(client)
        }
    }

    private func serve(_ fd: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            UnixSocket.setReceiveTimeout(fd, seconds: 10)
            guard let self,
                  let line = UnixSocket.readLine(fd, limit: 1 << 16),
                  let request = try? JSONDecoder().decode(AskpassRequest.self, from: line),
                  let handler = self.handler(for: request.token) else {
                close(fd)
                return
            }
            Task.detached {
                let reply = await handler(request)
                let data = (try? JSONEncoder().encode(reply)) ?? Data(#"{"ok":false}"#.utf8)
                _ = UnixSocket.writeAll(fd, data + Data([0x0A]))
                close(fd)
            }
        }
    }
}

// MARK: - Prompt parsing

enum SSHPromptParser {
    /// Classify an askpass prompt produced by OpenSSH / ssh-add.
    static func kind(of prompt: String, hint: String? = nil) -> SSHPromptKind {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if hint?.lowercased() == "confirm" {
            return .confirmation
        }

        if text.contains("authenticity of host") || text.contains("continue connecting") {
            let alias = firstCapture(#"host '([^' ]+)"#, in: text)
            let keyType = firstCapture(#"([A-Za-z0-9-]+) key fingerprint is"#, in: text)
            // OpenSSH 10 writes "fingerprint is: SHA256:…", older versions have no colon.
            let fingerprint = firstCapture(#"fingerprint is:? ((?:SHA256|MD5):[A-Za-z0-9+/=:]+)"#, in: text)
            return .hostKey(alias: alias, keyType: keyType, fingerprint: fingerprint)
        }

        // ssh: "Enter passphrase for key '/path': "
        if let path = firstCapture(#"^Enter passphrase for key '(.+)':$"#, in: text) {
            return .passphrase(keyPath: path)
        }
        // ssh-add: "Enter passphrase for /path: " or "Enter passphrase for /path (will confirm each use): "
        if let path = firstCapture(#"^Enter passphrase for (.+?)(?: \(will confirm each use\))?:$"#, in: text) {
            return .passphrase(keyPath: path)
        }

        // "user@alias's password: " — the alias never contains '@'.
        if text.hasSuffix("'s password:"),
           let alias = firstCapture(#"@([^@\s]+)'s password:$"#, in: text) {
            return .password(alias: alias)
        }

        // keyboard-interactive (OpenSSH ≥ 8.5): "(user@alias) Password: "
        if let range = text.range(of: #"^\(([^()]*)@([^@()\s]+)\) "#, options: .regularExpression) {
            let header = String(text[range]).dropFirst().dropLast(2)
            let alias = header.split(separator: "@").last.map(String.init)
            let question = String(text[range.upperBound...])
            return .keyboardInteractive(alias: alias, prompt: question)
        }

        if text.lowercased().hasSuffix("password:") {
            return .password(alias: nil)
        }
        return .other
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}

// MARK: - POSIX socket helpers

enum UnixSocket {
    static var streamType: Int32 {
        #if canImport(Glibc)
        Int32(SOCK_STREAM.rawValue)
        #else
        SOCK_STREAM
        #endif
    }

    static func withAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                body(sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func bind(_ fd: Int32, path: String) -> Bool {
        withAddress(path: path) { address, length in
            #if canImport(Glibc)
            Glibc.bind(fd, address, length) == 0
            #else
            Darwin.bind(fd, address, length) == 0
            #endif
        } ?? false
    }

    static func connect(_ fd: Int32, path: String) -> Bool {
        withAddress(path: path) { address, length in
            #if canImport(Glibc)
            Glibc.connect(fd, address, length) == 0
            #else
            Darwin.connect(fd, address, length) == 0
            #endif
        } ?? false
    }

    static func disableSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func setReceiveTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var written = 0
            while written < buffer.count {
                #if canImport(Glibc)
                let n = send(fd, base.advanced(by: written), buffer.count - written, Int32(MSG_NOSIGNAL))
                #else
                let n = send(fd, base.advanced(by: written), buffer.count - written, 0)
                #endif
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                written += n
            }
            return true
        }
    }

    /// Read until "\n" (not included) or EOF. Returns nil on error or when `limit` is exceeded.
    static func readLine(_ fd: Int32, limit: Int) -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while result.count <= limit {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 {
                return result.isEmpty ? nil : result
            }
            if let newline = buffer[0..<n].firstIndex(of: 0x0A) {
                result.append(contentsOf: buffer[0..<newline])
                return result
            }
            result.append(contentsOf: buffer[0..<n])
        }
        return nil
    }
}
