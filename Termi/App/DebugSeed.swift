#if DEBUG
import Foundation
import os.log

/// `-debugSeedHosts <path to a JSON file>`: creates or updates the hosts the file describes, so
/// that a test profile gets its hosts from a file instead of from somebody typing them — and
/// never into the owner's real profile: the seed runs only in an isolated or tests profile.
///
/// ```json
/// { "hosts": [
///   { "label": "test-key", "address": "127.0.0.1", "port": 2222, "user": "tester",
///     "auth": { "type": "key", "keyFile": "/…/id_plain", "passphraseFile": "/…/passphrase",
///               "keyName": "test-env plain" },
///     "jump": "test-jump", "hostKeyFile": "/…/ssh_host_ed25519_key.pub",
///     "startupSnippet": { "name": "where am I", "command": "hostname" } } ] }
/// ```
/// `auth.type` is "agent", "password" (`passwordFile` optional: without it nothing is saved and
/// the app asks) or "key". `hostKeyFile` is the server's public host key: the host is then a
/// known host from the start, pinned to that key instead of trusted on first sight. Paths are
/// absolute, or relative to the folder of the JSON file.
/// Hosts are keyed by label, keys and snippets by name: seeding twice changes nothing.
/// `TestEnvironment/test-env.sh up` writes such a file (see docs/TESTING.md).
enum DebugSeed {
    static let argument = "debugSeedHosts"

    private static let logger = Logger(subsystem: "dev.termi.Termi", category: "DebugSeed")

    // MARK: - Whether to seed (pure)

    enum Decision: Equatable, Sendable {
        case notRequested
        case seed(path: String)
        case refused(String)
    }

    /// The seed writes hosts, keys and passwords: only where the profile is a separate one.
    static func decision(kind: AppProfile.Kind, argument value: String?) -> Decision {
        guard let value, !value.isEmpty else { return .notRequested }
        switch kind {
        case .isolated, .tests:
            return .seed(path: value)
        case .standard:
            return .refused("-\(argument) is refused in the standard profile: test hosts never go into real data. "
                + "Start the app with \(AppProfile.overrideVariable)=<absolute folder>.")
        }
    }

    // MARK: - The file (pure)

    struct Plan: Equatable, Sendable {
        var hosts: [HostEntry]
    }

    struct HostEntry: Equatable, Sendable {
        var label: String
        var address: String
        var port: Int
        var user: String
        var auth: Auth
        /// Label of the host to connect through.
        var jump: String?
        var startupSnippet: SnippetEntry?
        /// The server's public host key ("ssh-ed25519 AAAA…"), trusted for this address.
        var hostKeyFile: String?
    }

    enum Auth: Equatable, Sendable {
        case agent
        /// Without a file nothing is saved: the app asks when it connects.
        case password(file: String?)
        case key(name: String, file: String, passphraseFile: String?)
    }

    struct SnippetEntry: Equatable, Sendable {
        var name: String
        var command: String
    }

    enum SeedError: Error, Equatable, Sendable, CustomStringConvertible {
        case unreadable(String)
        case malformed(String)
        case emptyField(host: String, field: String)
        case duplicateLabel(String)
        case invalidPort(host: String, port: Int)
        case unknownAuth(host: String, type: String)
        case unknownJump(host: String, jump: String)
        case jumpLoop(host: String)

        var description: String {
            switch self {
            case .unreadable(let path): "the file cannot be read: \(path)"
            case .malformed(let reason): "the file is not a hosts description: \(reason)"
            case .emptyField(let host, let field): "host \"\(host)\": \"\(field)\" is empty or missing"
            case .duplicateLabel(let label): "the label \"\(label)\" is used twice"
            case .invalidPort(let host, let port): "host \"\(host)\": \(port) is not a port"
            case .unknownAuth(let host, let type): "host \"\(host)\": unknown auth type \"\(type)\" (agent, password, key)"
            case .unknownJump(let host, let jump): "host \"\(host)\": the jump host \"\(jump)\" is not in the file"
            case .jumpLoop(let host): "host \"\(host)\": its jump hosts lead back to itself"
            }
        }
    }

    private struct RawPlan: Decodable {
        let hosts: [RawHost]
    }

    private struct RawHost: Decodable {
        let label: String
        let address: String
        let port: Int?
        let user: String?
        let auth: RawAuth
        let jump: String?
        let startupSnippet: RawSnippet?
        let hostKeyFile: String?
    }

    private struct RawAuth: Decodable {
        let type: String
        let passwordFile: String?
        let keyFile: String?
        let passphraseFile: String?
        let keyName: String?
    }

    private struct RawSnippet: Decodable {
        let name: String
        let command: String
    }

    /// Reads a hosts description. Everything that would make the seed stop half-way is found
    /// here, before anything is written. Reads no file but `data`.
    static func parse(_ data: Data, relativeTo base: URL) throws -> Plan {
        let raw: RawPlan
        do {
            raw = try JSONDecoder().decode(RawPlan.self, from: data)
        } catch let error as DecodingError {
            throw SeedError.malformed(describe(error))
        } catch {
            throw SeedError.malformed(error.localizedDescription)
        }

        func path(_ value: String) -> String {
            value.hasPrefix("/") ? value : base.appendingPathComponent(value).standardizedFileURL.path
        }

        var hosts: [HostEntry] = []
        var labels = Set<String>()
        for item in raw.hosts {
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { throw SeedError.emptyField(host: item.address, field: "label") }
            guard labels.insert(label).inserted else { throw SeedError.duplicateLabel(label) }
            let address = item.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { throw SeedError.emptyField(host: label, field: "address") }
            let port = item.port ?? 22
            guard (1...65535).contains(port) else { throw SeedError.invalidPort(host: label, port: port) }

            let auth: Auth
            switch item.auth.type {
            case "agent":
                auth = .agent
            case "password":
                auth = .password(file: item.auth.passwordFile.map(path))
            case "key":
                guard let keyFile = item.auth.keyFile, !keyFile.isEmpty else {
                    throw SeedError.emptyField(host: label, field: "auth.keyFile")
                }
                let name = item.auth.keyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                auth = .key(name: name.isEmpty ? label : name, file: path(keyFile),
                            passphraseFile: item.auth.passphraseFile.map(path))
            default:
                throw SeedError.unknownAuth(host: label, type: item.auth.type)
            }

            var snippet: SnippetEntry?
            if let rawSnippet = item.startupSnippet {
                let name = rawSnippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw SeedError.emptyField(host: label, field: "startupSnippet.name") }
                guard !rawSnippet.command.isEmpty else {
                    throw SeedError.emptyField(host: label, field: "startupSnippet.command")
                }
                snippet = SnippetEntry(name: name, command: rawSnippet.command)
            }

            let jump = item.jump?.trimmingCharacters(in: .whitespacesAndNewlines)
            hosts.append(HostEntry(label: label, address: address, port: port, user: item.user ?? "",
                                   auth: auth, jump: (jump ?? "").isEmpty ? nil : jump,
                                   startupSnippet: snippet,
                                   hostKeyFile: (item.hostKeyFile ?? "").isEmpty ? nil : item.hostKeyFile.map(path)))
        }

        let jumps = Dictionary(uniqueKeysWithValues: hosts.map { ($0.label, $0.jump) })
        for host in hosts {
            guard let jump = host.jump else { continue }
            guard labels.contains(jump) else { throw SeedError.unknownJump(host: host.label, jump: jump) }
            // A chain is at most as long as the list; one step more is a loop.
            var next: String? = jump
            var steps = 0
            while let current = next {
                steps += 1
                guard current != host.label, steps <= hosts.count else { throw SeedError.jumpLoop(host: host.label) }
                next = jumps[current] ?? nil
            }
        }
        return Plan(hosts: hosts)
    }

    private static func describe(_ error: DecodingError) -> String {
        func location(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return path.isEmpty ? "the top level" : path
        }
        switch error {
        case .keyNotFound(let key, let context): return "\"\(key.stringValue)\" is missing at \(location(context))"
        case .typeMismatch(_, let context): return "wrong kind of value at \(location(context))"
        case .valueNotFound(_, let context): return "no value at \(location(context))"
        case .dataCorrupted(let context): return "not valid JSON (\(context.debugDescription))"
        @unknown default: return "not readable"
        }
    }

    /// The content of a secret's file. One trailing line break is the editor's, not the
    /// secret's; anything else, spaces included, is kept.
    static func secret(fromFileContents contents: String) -> String {
        var value = contents
        // "\r\n" is one Character to Swift: it does not end in "\n".
        if value.hasSuffix("\r\n") || value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    // MARK: - This run

    /// The one call from `WindowRootView.applyDebugLaunchArguments`. What happened is logged, on
    /// standard error and — when a seed ran — in `debug-seed.log` in the profile folder, because
    /// nobody sees the standard error of an app started with `open`.
    ///
    /// Once per run, although every window calls it as it opens: a second window (⌘N) must not
    /// seed again — that would take back what the tester changed on a seeded host meanwhile —
    /// and two windows opening together must not both create the same host.
    @MainActor static func applyIfRequested() async {
        if let seeding {
            await seeding.value
            return
        }
        let task = Task { await seedIfRequested() }
        seeding = task
        await task.value
    }

    @MainActor private static var seeding: Task<Void, Never>?

    private static func seedIfRequested() async {
        let profile = AppProfile.current
        switch decision(kind: profile.kind, argument: AppProfile.arguments.string(forKey: argument)) {
        case .notRequested:
            return
        case .refused(let reason):
            logger.error("\(reason, privacy: .public)")
            FileHandle.standardError.write(Data((reason + "\n").utf8))
        case .seed(let path):
            var lines = ["seed: \(path)", "profile: \(profile.directory.path)"]
            do {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard let data = FileManager.default.contents(atPath: url.path) else {
                    throw SeedError.unreadable(url.path)
                }
                let plan = try parse(data, relativeTo: url.deletingLastPathComponent())
                lines += try await apply(plan)
                lines.append("done: \(plan.hosts.count) hosts")
            } catch {
                lines.append("FAILED: \((error as? SeedError)?.description ?? error.localizedDescription)")
            }
            let report = lines.joined(separator: "\n") + "\n"
            logger.notice("\(report, privacy: .public)")
            FileHandle.standardError.write(Data(report.utf8))
            try? report.write(to: profile.directory.appendingPathComponent("debug-seed.log"),
                              atomically: true, encoding: .utf8)
            // Pages that are already on screen read their hosts again.
            await MainActor.run {
                NotificationCenter.default.post(name: .dsDataChanged, object: nil)
            }
        }
    }

    /// Writes the plan through the same repositories and vault the forms use. Returns one line
    /// per record (never a secret). Stops at the first failure: what was written stays, and the
    /// next seed completes it.
    static func apply(_ plan: Plan) async throws -> [String] {
        // A locked vault (a profile with a master password) cannot take secrets: say so first.
        try await SecureStoreService.shared.ensureUnlocked()
        var lines: [String] = []
        var keyIds: [String: Int64] = [:]
        var hostIds: [String: Int64] = [:]

        for entry in plan.hosts {
            let existing = try await HostRepository.shared.fetchAll().first { $0.label == entry.label }
            var host = existing ?? Host.defaultValue()
            host.label = entry.label
            host.hostname = entry.address
            host.port = entry.port
            host.username = entry.user
            // The password lives in the vault, never in this column (as the host form saves).
            host.passwordEncrypted = nil
            host.privateKeyId = nil
            // An identity outranks the host's own user, key and password when connecting: one
            // left from an earlier edit would silently replace what the seed describes.
            host.identityId = nil

            var passwordFile: String?
            switch entry.auth {
            case .agent:
                host.authType = "agent"
            case .password(let file):
                host.authType = "password"
                passwordFile = file
            case .key(let name, let file, let passphraseFile):
                host.authType = "privateKey"
                if let id = keyIds[name] {
                    host.privateKeyId = id
                } else {
                    let id = try await storeKey(name: name, file: file, passphraseFile: passphraseFile)
                    keyIds[name] = id
                    host.privateKeyId = id
                    lines.append("key \"\(name)\" from \(file)")
                }
            }

            if let snippet = entry.startupSnippet {
                host.startupSnippetId = try await storeSnippet(snippet)
            } else {
                host.startupSnippetId = nil
            }

            let saved = try await HostRepository.shared.save(host)
            guard let id = saved.id else { continue }
            hostIds[entry.label] = id

            if let passwordFile {
                let password = try readSecret(passwordFile)
                try await SecureStoreService.shared.setHostPassword(password, hostId: id)
            } else {
                // What the file does not give is not there: the seed decides the whole host.
                try await SecureStoreService.shared.deleteHostPassword(hostId: id)
            }
            if let hostKeyFile = entry.hostKeyFile {
                try await trustHostKey(file: hostKeyFile, hostname: entry.address, port: entry.port)
            }
            lines.append("\(existing == nil ? "created" : "updated") host \"\(entry.label)\" \(saved.addressDescription)")
        }

        // Jump hosts by label, once every host has an id (a host may be listed before its jump).
        for entry in plan.hosts {
            guard let id = hostIds[entry.label], var host = try await HostRepository.shared.fetch(id: id) else { continue }
            let jumpId = entry.jump.flatMap { hostIds[$0] }
            guard host.jumpHostId != jumpId else { continue }
            host.jumpHostId = jumpId
            try await HostRepository.shared.save(host)
        }
        return lines
    }

    private static func readSecret(_ path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
            throw SeedError.unreadable(path)
        }
        return secret(fromFileContents: text)
    }

    /// As "Import key" in the key vault does: the private key encrypted with the vault key, its
    /// passphrase a vault entry.
    private static func storeKey(name: String, file: String, passphraseFile: String?) async throws -> Int64 {
        guard FileManager.default.isReadableFile(atPath: file) else { throw SeedError.unreadable(file) }
        let imported = try await SSHKeyGenerator.shared.importKey(from: file)
        let encrypted = try await SecureStoreService.shared.encryptStoredValue(imported.privateKey)
        var key = try await SSHKeyRepository.shared.fetchAll().first { $0.name == name }
            ?? SSHKey(name: name, type: "", publicKey: "", privateKeyEncrypted: "", fingerprint: nil, createdAt: "")
        key.type = imported.type
        key.publicKey = imported.publicKey
        key.privateKeyEncrypted = encrypted
        key.fingerprint = imported.fingerprint
        let saved = try await SSHKeyRepository.shared.save(key)
        guard let id = saved.id else { throw SeedError.unreadable(file) }
        if let passphraseFile {
            let passphrase = try readSecret(passphraseFile)
            try await SecureStoreService.shared.setKeyPassphrase(passphrase, keyId: id)
        } else {
            try await SecureStoreService.shared.deletePassword(forAccount: "sshkey_\(id)")
        }
        return id
    }

    /// As answering "Trust" to the host key prompt, with a key that is known beforehand.
    private static func trustHostKey(file: String, hostname: String, port: Int) async throws {
        guard let data = FileManager.default.contents(atPath: file), let text = String(data: data, encoding: .utf8) else {
            throw SeedError.unreadable(file)
        }
        // "type base64 comment": the comment is not part of the key.
        let publicKey = text.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
        let fingerprint = try SSHService.fingerprint(forOpenSSHPublicKey: publicKey)
        try await KnownHostRepository.shared.trust(hostname: hostname, port: port, publicKey: publicKey,
                                                   fingerprint: fingerprint)
    }

    private static func storeSnippet(_ entry: SnippetEntry) async throws -> Int64? {
        var snippet = try await SnippetRepository.shared.fetchAll().first { $0.name == entry.name }
            ?? Snippet(name: entry.name, command: entry.command, sortOrder: 0, createdAt: "")
        snippet.command = entry.command
        return try await SnippetRepository.shared.save(snippet).id
    }
}
#endif
