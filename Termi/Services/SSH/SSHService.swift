import CryptoKit
import Foundation
import os.log

/// App-level entry point for SSH.
///
/// Turns saved hosts into connection specs — group defaults, identities, vault secrets,
/// jump-host chains and trusted host keys — and hands out shared master connections from
/// `SSHConnectionManager`. Prompts go to `AuthPromptPresenter`; answers the user chose to
/// save go to the encrypted vault; newly trusted host keys go to Known Hosts.
actor SSHService {
    static let shared = SSHService()

    nonisolated let runtime: SSHRuntime
    nonisolated let manager: SSHConnectionManager

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "SSHService")
    private let hostRepo = HostRepository.shared
    private let groupRepo = GroupRepository.shared
    private let keyRepo = SSHKeyRepository.shared
    private let identityRepo = IdentityRepository.shared
    private let knownHostRepo = KnownHostRepository.shared
    private let secureStore = SecureStoreService.shared

    init() {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        runtime = SSHRuntime(askpassExecutable: executable)
        manager = SSHConnectionManager(runtime: runtime)
    }

    // MARK: - Connections

    /// Open (or reuse) the shared master connection for `host`.
    /// - Parameter password: one-off password (Quick Connect / prompt), not stored.
    func connect(to host: Host, password: String? = nil) async throws -> SSHConnectionManager.Lease {
        let generation = DataSnapshot.expected ?? DataSnapshot.current
        return try await DataSnapshot.$expected.withValue(generation) {
            try DataSnapshot.check(generation)
            let spec = try await connectionSpec(for: host, passwordOverride: password)
            try DataSnapshot.check(generation)
            let lease = try await manager.acquire(key: host.connectionKey, spec: spec, callbacks: Self.callbacks(for: spec))
            do { try DataSnapshot.check(generation) }
            catch { lease.release(); throw error }
            if let id = host.id {
                try? await hostRepo.markConnected(id: id)
                try DataSnapshot.check(generation)
                // Saved hosts only: probe the connection just opened in the background.
                HostSystemProbe.shared.hostConnected(id: id, hostname: host.hostname, port: host.port, master: lease.master)
            }
            return lease
        }
    }

    /// Run a non-interactive command on `host`, connecting first if needed.
    func run(_ command: String, on host: Host) async throws -> ProcessRunner.Result {
        let lease = try await connect(to: host)
        defer { lease.release() }
        return try await lease.master.run(command)
    }

    /// Close the host's connection — every terminal, SFTP session and tunnel on it ends.
    func disconnect(_ host: Host) async {
        await manager.disconnect(key: host.connectionKey)
    }

    func connectedHostKeys() async -> Set<String> {
        await manager.connectedKeys()
    }

    /// Close all connections (app quit / vault lock).
    func shutdown() async {
        await manager.shutdown()
        runtime.shutdown()
    }

    /// Hooks from the SSH engine into the app.
    nonisolated static var callbacks: SSHMasterConnection.Callbacks { callbacks(for: nil) }

    nonisolated static func callbacks(for spec: SSHConnectionSpec?) -> SSHMasterConnection.Callbacks {
        let contexts = Dictionary((spec?.hops ?? []).compactMap { hop -> (Int64, SSHPasswordContext)? in
            guard let id = hop.hostId, let context = hop.passwordContext else { return nil }
            return (id, context)
        }, uniquingKeysWith: { first, _ in first })
        let generation = DataSnapshot.expected ?? DataSnapshot.current
        return SSHMasterConnection.Callbacks(
            prompt: { prompt in
                guard (try? DataSnapshot.check(generation)) != nil else { return .cancel }
                return await AuthPromptPresenter.shared.present(prompt)
            },
            savePassword: { hostId, password in
                try? await DataSnapshot.$expected.withValue(generation) {
                    try DataSnapshot.check(generation)
                    try await SecureStoreService.shared.setHostPassword(password, hostId: hostId,
                                                                        expectedContext: contexts[hostId])
                }
            },
            savePassphrase: { keyId, passphrase in
                try? await DataSnapshot.$expected.withValue(generation) {
                    try DataSnapshot.check(generation)
                    try await SecureStoreService.shared.setKeyPassphrase(passphrase, keyId: keyId)
                }
            },
            trustHostKey: { hop, publicKey in
                _ = try? await DataSnapshot.$expected.withValue(generation) {
                    try DataSnapshot.check(generation)
                    let fingerprint = (try? SSHService.fingerprint(forOpenSSHPublicKey: publicKey)) ?? ""
                    return try await KnownHostRepository.shared.trust(
                        hostname: hop.hostname, port: hop.port, publicKey: publicKey, fingerprint: fingerprint)
                }
            }
        )
    }

    // MARK: - Resolving hosts into connection specs

    /// Build the full connection description for `host`, including its jump-host chain.
    func connectionSpec(for host: Host, passwordOverride: String? = nil) async throws -> SSHConnectionSpec {
        var chain: [Host] = [host]
        var visited = Set<Int64>()
        if let id = host.id { visited.insert(id) }
        var current = host
        while let jumpId = try await jumpHostId(for: current) {
            guard !visited.contains(jumpId) else {
                throw SSHError.invalidConfiguration(
                    String(localized: "The jump hosts of \(host.label) form a loop."))
            }
            guard let jump = try await hostRepo.fetch(id: jumpId) else { break }
            visited.insert(jumpId)
            chain.insert(jump, at: 0)
            guard chain.count <= SSHConnectionSpec.maxHops else {
                throw SSHError.invalidConfiguration(String(localized: "Too many jump hosts for \(host.label)."))
            }
            current = jump
        }

        var hops: [SSHHop] = []
        for (index, member) in chain.enumerated() {
            let isTarget = index == chain.count - 1
            hops.append(try await hop(for: member, alias: "termi-h\(index)",
                                      passwordOverride: isTarget ? passwordOverride : nil,
                                      isTarget: isTarget))
        }

        let settings = await Self.loadConnectionSettings()
        let spec = SSHConnectionSpec(
            hops: hops,
            connectTimeout: settings.timeout,
            keepAliveInterval: settings.keepAliveInterval,
            keepAliveCountMax: 3,
            userConfigPath: settings.userConfigPath
        )
        return try await SSHConfigRenderer.resolvingUserOptions(in: spec)
    }

    private func jumpHostId(for host: Host) async throws -> Int64? {
        if let id = host.jumpHostId { return id }
        guard let groupId = host.groupId, let group = try await groupRepo.fetch(id: groupId),
              let jumpId = group.jumpHostId, jumpId != host.id else {
            return nil
        }
        return jumpId
    }

    func hop(for host: Host, alias: String, passwordOverride: String?, isTarget: Bool) async throws -> SSHHop {
        let group: HostGroup? = if let groupId = host.groupId { try await groupRepo.fetch(id: groupId) } else { nil }

        let savedPassword: String? = if let id = host.id {
            try? await secureStore.getHostPassword(hostId: id)
        } else { nil }

        // Identity: the host's own, else the group's — unless the host brings its own credentials.
        // The same rule decides which login a saved password belongs to (`SSHPasswordContext`).
        var identity: Identity?
        if let identityId = SSHPasswordContext.identityId(for: host, group: group,
                                                          hasSavedPassword: savedPassword?.isEmpty == false) {
            identity = try await identityRepo.fetch(id: identityId)
        }

        guard let username = SSHPasswordContext.username(host: host, group: group, identity: identity) else {
            throw SSHServiceError.missingUsername(host: host.label.isEmpty ? host.hostname : host.label)
        }

        var credentials = SSHCredentials()
        let keyId = identity != nil ? identity?.privateKeyId : host.privateKeyId
        if let keyId {
            guard let key = try await keyRepo.fetch(id: keyId) else {
                throw SSHServiceError.privateKeyNotFound(host: host.label)
            }
            // A key the vault can no longer decrypt (its vault key was replaced, e.g. the data
            // was moved to another Mac) says so, with what to do: the raw error read
            // "CryptoKit.CryptoKitError error 3" on the failure card.
            let pem: String
            do {
                pem = try await secureStore.decryptStoredValue(key.privateKeyEncrypted)
            } catch {
                throw Self.unreadableSecret(error, as: .privateKeyUnreadable(key: key.name))
            }
            let passphrase: String? = try? await secureStore.getKeyPassphrase(keyId: keyId)
            credentials.privateKey = .init(keyId: keyId, name: key.name, pem: pem, passphrase: passphrase)
        }

        if let passwordOverride, !passwordOverride.isEmpty {
            credentials.password = passwordOverride
        } else if let savedPassword, !savedPassword.isEmpty {
            // "Save to vault" in this host's prompt is a host-only override. It must also
            // win for an explicit identity, without changing that shared identity for others.
            credentials.password = savedPassword
        } else if let encrypted = identity?.passwordEncrypted, !encrypted.isEmpty {
            do {
                credentials.password = try await secureStore.decryptStoredValue(encrypted)
            } catch {
                throw Self.unreadableSecret(error, as: .identityPasswordUnreadable(identity: identity?.name ?? ""))
            }
        }
        credentials.useSystemAgent = host.authType == "agent" || identity?.authType == "agent"

        let knownKeys = (try? await knownHostRepo.fetchAll(hostname: host.hostname, port: host.port))?
            .map(\.publicKey) ?? []

        // A password saved under the host would switch off the group's identity on the next
        // connection (see above), so prompts don't offer saving while it is inherited.
        let inheritsIdentity = host.identityId == nil && identity != nil

        return SSHHop(
            alias: alias,
            displayName: host.label.isEmpty ? host.hostname : host.label,
            hostId: inheritsIdentity ? nil : host.id,
            hostname: host.hostname,
            port: host.port,
            username: username,
            credentials: credentials,
            knownHostKeys: knownKeys,
            agentForwarding: isTarget && host.agentForwarding,
            userConfigAlias: host.sshConfigAlias,
            passwordContext: SSHPasswordContext(hostname: host.hostname, port: host.port, username: username,
                identityId: identity?.id, usesSystemAgent: credentials.useSystemAgent, privateKeyId: keyId)
        )
    }

    struct ConnectionSettings: Sendable {
        var timeout = 10
        var keepAliveInterval = 15
        var userConfigPath: String?
    }

    static func loadConnectionSettings() async -> ConnectionSettings {
        var settings = ConnectionSettings()
        var useUserConfig = true
        if let reader = try? await DatabaseManager.shared.reader,
           let values = try? await reader.read({ db in try AppSetting.fetchAll(db) }) {
            let dict = Dictionary(values.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
            if let timeout = dict["connection_timeout"].flatMap(Int.init), timeout > 0 { settings.timeout = timeout }
            if let interval = dict["keepalive_interval"].flatMap(Int.init), interval > 0 { settings.keepAliveInterval = interval }
            useUserConfig = dict["ssh_use_user_config"] != "false"
        }
        if useUserConfig {
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh/config").path
            if FileManager.default.isReadableFile(atPath: path) {
                settings.userConfigPath = path
            }
        }
        return settings
    }

    // MARK: - Utilities

    /// Remove temporary files left behind by a crashed previous run. (Remote files downloaded
    /// for editing in SFTP are not deleted here: see `RemoteEditFolder.sweepStale`.)
    nonisolated static func cleanupResidualTempFiles() {
        let tmpDir = FileManager.default.temporaryDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) {
            // Files from the pre-ControlMaster implementation.
            for url in contents where url.lastPathComponent.hasPrefix("termi-ssh-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        SSHRuntime.cleanupStaleDirectories()
    }

    /// OpenSSH-style "SHA256:…" fingerprint of an "ssh-ed25519 AAAA…" public key.
    nonisolated static func fingerprint(forOpenSSHPublicKey publicKey: String) throws -> String {
        let parts = publicKey.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let keyData = Data(base64Encoded: String(parts[1])) else {
            throw SSHServiceError.invalidHostKey
        }
        let digest = SHA256.hash(data: keyData)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// What a failed read of a stored secret is to the user: a secret that does not decrypt
    /// (wrong vault key, damaged value) becomes `replacement`, which says what to do about it.
    /// Everything else — a locked vault, a key file that cannot be read while the screen is
    /// locked (which is retried) — stays what it is. Decided by the error's type, never its text.
    nonisolated static func unreadableSecret(_ error: Error, as replacement: SSHServiceError) -> Error {
        if error is CryptoKitError || error is CryptoService.CryptoError { return replacement }
        return error
    }

    enum SSHServiceError: Error, LocalizedError, Sendable, Equatable {
        case invalidHostKey
        case privateKeyNotFound(host: String)
        case missingUsername(host: String)
        /// The stored private key does not decrypt with the vault's current key.
        case privateKeyUnreadable(key: String)
        /// The identity's stored password does not decrypt with the vault's current key.
        case identityPasswordUnreadable(identity: String)

        var errorDescription: String? {
            switch self {
            case .invalidHostKey:
                String(localized: "Invalid SSH host key")
            case .privateKeyNotFound(let host):
                String(localized: "The private key configured for \(host) no longer exists.")
            case .missingUsername(let host):
                String(localized: "No username is set for \(host). Set one on the host, its identity or its group.")
            case .privateKeyUnreadable(let key):
                String(localized: "The saved private key “\(key)” cannot be decrypted on this Mac. Import the key again in Keychain.")
            case .identityPasswordUnreadable(let identity):
                String(localized: "The saved password of the identity “\(identity)” cannot be decrypted on this Mac. Enter it again under Identities.")
            }
        }
    }
}
