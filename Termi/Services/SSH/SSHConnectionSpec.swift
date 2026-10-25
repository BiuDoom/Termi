import Foundation

// MARK: - Credentials

/// Credentials used to authenticate a single SSH hop.
///
/// Secrets only live in memory: private keys are written to 0600 files inside the
/// connection's private runtime directory, and passwords / passphrases are handed to
/// `ssh` through the askpass bridge — never through argv or environment variables.
struct SSHCredentials: Sendable, Equatable {
    struct PrivateKey: Sendable, Equatable {
        var keyId: Int64?
        var name: String
        var pem: String
        var passphrase: String?
    }

    /// Answer for password and keyboard-interactive password prompts. `nil` → ask the user.
    var password: String?
    /// Private key from the encrypted vault.
    var privateKey: PrivateKey?
    /// Let ssh use the user's ssh-agent and default `~/.ssh` identities, like the plain `ssh` command.
    var useSystemAgent: Bool

    init(password: String? = nil, privateKey: PrivateKey? = nil, useSystemAgent: Bool = false) {
        self.password = password
        self.privateKey = privateKey
        self.useSystemAgent = useSystemAgent
    }

    /// True when public-key authentication can succeed for this hop.
    var allowsPublicKey: Bool { privateKey != nil || useSystemAgent }
}

/// Non-secret login identity that a prompted password belongs to: only what SSH acts on.
/// "password", "keyboard-interactive" and "privateKey" without a key are the same to SSH (no
/// key, no agent, a password), so the raw authentication type is not part of it.
struct SSHPasswordContext: Sendable, Equatable {
    var hostname: String
    var port: Int
    var username: String
    var identityId: Int64?
    /// The system agent and the default ~/.ssh keys are offered (the host or its identity
    /// chose "agent").
    var usesSystemAgent: Bool
    /// The key from the vault that is offered (the identity's, or the host's own).
    var privateKeyId: Int64?

    /// The identity SSH signs in with for `host`: its own, else its group's — unless the host
    /// brings credentials of its own (the system agent, a key or a saved password).
    static func identityId(for host: Host, group: HostGroup?, hasSavedPassword: Bool) -> Int64? {
        if let own = host.identityId { return own }
        guard host.authType != "agent", host.privateKeyId == nil, !hasSavedPassword else { return nil }
        return group?.identityId
    }

    /// The account SSH signs in as: the identity's, else the host's, else the group's.
    static func username(host: Host, group: HostGroup?, identity: Identity?) -> String? {
        [identity?.username, host.username, group?.username]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// What SSH would use for `host` (see `SSHService.hop`), told without any secret. `identity`
    /// looks up an identity by id (the database, or the identities a form has loaded).
    static func resolve(host: Host, group: HostGroup?, hasSavedPassword: Bool,
                        identity lookup: (Int64) throws -> Identity?) rethrows -> SSHPasswordContext {
        let identity = try identityId(for: host, group: group, hasSavedPassword: hasSavedPassword).flatMap(lookup)
        return SSHPasswordContext(
            hostname: host.hostname,
            port: host.port,
            username: username(host: host, group: group, identity: identity) ?? "",
            identityId: identity?.id,
            usesSystemAgent: host.authType == "agent" || identity?.authType == "agent",
            privateKeyId: identity != nil ? identity?.privateKeyId : host.privateKeyId
        )
    }
}

// MARK: - Hop

/// One machine in a connection chain. Jump hosts come first, the destination last.
struct SSHHop: Sendable, Equatable {
    /// Unique alias used in the generated ssh_config and as `HostKeyAlias`.
    /// Using the alias in prompts ("user@alias's password:") tells us exactly which hop asks.
    var alias: String
    /// Human readable name used in prompts, e.g. "prod-db".
    var displayName: String
    /// Database id of the saved host a password answered in a prompt can be saved under
    /// (nil for ad-hoc connections and for hosts using their group's identity).
    var hostId: Int64?
    var hostname: String
    var port: Int
    var username: String
    var credentials: SSHCredentials
    /// Trusted host keys in OpenSSH format ("ssh-ed25519 AAAA...").
    var knownHostKeys: [String]
    var agentForwarding: Bool
    /// Effective, non-authentication options resolved for the real host via OpenSSH -G.
    var userOptions: [String: String] = [:]
    /// The agent, key files and certificates the user's ssh_config gives the real host
    /// (IdentityAgent / IdentityFile / CertificateFile, via -G). Applied only to a hop that
    /// offers the system agent — as plain `ssh` would — and never next to a key from the vault.
    var userAgentOptions = SSHUserAgentOptions()
    /// Original imported ssh_config Host alias, never the user-editable display name.
    var userConfigAlias: String? = nil
    var passwordContext: SSHPasswordContext? = nil

    init(
        alias: String,
        displayName: String,
        hostId: Int64? = nil,
        hostname: String,
        port: Int = 22,
        username: String,
        credentials: SSHCredentials = SSHCredentials(),
        knownHostKeys: [String] = [],
        agentForwarding: Bool = false,
        userConfigAlias: String? = nil,
        passwordContext: SSHPasswordContext? = nil
    ) {
        self.alias = alias
        self.displayName = displayName
        self.hostId = hostId
        self.hostname = hostname
        self.port = port
        self.username = username
        self.credentials = credentials
        self.knownHostKeys = knownHostKeys
        self.agentForwarding = agentForwarding
        self.userConfigAlias = userConfigAlias
        self.passwordContext = passwordContext
    }

    /// "user@host" or "user@host:port" for display.
    var endpointDescription: String {
        let host = hostname.contains(":") ? "[\(hostname)]" : hostname
        return port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
    }
}

/// See `SSHHop.userAgentOptions`.
struct SSHUserAgentOptions: Sendable, Equatable {
    var identityAgent: String?
    var identityFiles: [String] = []
    var certificateFiles: [String] = []

    var isEmpty: Bool { identityAgent == nil && identityFiles.isEmpty && certificateFiles.isEmpty }
}

// MARK: - Connection Spec

/// Everything needed to open one multiplexed SSH connection (possibly through jump hosts).
struct SSHConnectionSpec: Sendable, Equatable {
    /// Jump hosts first, destination last. Never empty.
    var hops: [SSHHop]
    var connectTimeout: Int = 10
    var keepAliveInterval: Int = 15
    var keepAliveCountMax: Int = 3
    /// Optional ssh_config resolved for each real hostname (normally `~/.ssh/config`).
    var userConfigPath: String?

    static let maxHops = 8

    init(hops: [SSHHop], connectTimeout: Int = 10, keepAliveInterval: Int = 15,
         keepAliveCountMax: Int = 3, userConfigPath: String? = nil) {
        self.hops = hops
        self.connectTimeout = connectTimeout
        self.keepAliveInterval = keepAliveInterval
        self.keepAliveCountMax = keepAliveCountMax
        self.userConfigPath = userConfigPath
    }

    var target: SSHHop { hops[hops.count - 1] }

    /// Non-secret identity of this connection. Two specs with the same fingerprint can share
    /// one master connection; editing a host (address, user, key, jump chain…) changes it.
    var fingerprint: String {
        // One expression here is too much for the Swift 6.0 type checker (Xcode 16.2).
        // The text is the connection identity, so the pieces below stay in this order.
        var parts: [String] = []
        parts.reserveCapacity(hops.count + 2)
        for hop in hops {
            parts.append(Self.fingerprintComponent(for: hop))
        }
        let timeouts = "t\(connectTimeout)/\(keepAliveInterval)/\(keepAliveCountMax)"
        parts.append(timeouts)
        parts.append(userConfigPath ?? "-")
        return parts.joined(separator: ">")
    }

    /// One hop inside `fingerprint`, split out so Swift 6.0 can type-check it.
    private static func fingerprintComponent(for hop: SSHHop) -> String {
        let key: String
        if let privateKey = hop.credentials.privateKey {
            if let keyId = privateKey.keyId {
                key = "k\(keyId)"
            } else {
                key = "k\(privateKey.name)"
            }
        } else {
            key = "-"
        }
        let agent = hop.credentials.useSystemAgent ? "a" : "-"
        let forwarding = hop.agentForwarding ? "f" : "-"
        let alias = hop.userConfigAlias ?? "-"
        let options = hop.userOptions
        var optionParts: [String] = []
        for name in options.keys.sorted() {
            optionParts.append(name + "=" + options[name]!)
        }
        let identityAgent = hop.userAgentOptions.identityAgent ?? "-"
        let identityFiles = hop.userAgentOptions.identityFiles.joined(separator: ";")
        let certificateFiles = hop.userAgentOptions.certificateFiles.joined(separator: ";")
        let fields = [
            hop.hostname, String(hop.port), hop.username, key,
            agent, forwarding, alias, optionParts.joined(separator: ";"),
            "ia=" + identityAgent, "if=" + identityFiles, "cf=" + certificateFiles
        ]
        return fields.joined(separator: "|")
    }

    /// Reject values that could break out of the generated ssh_config or be parsed as options.
    func validate() throws {
        guard !hops.isEmpty else { throw SSHError.invalidConfiguration(String(localized: "No host specified")) }
        guard hops.count <= Self.maxHops else {
            throw SSHError.invalidConfiguration(String(localized: "Too many jump hosts (at most \(Self.maxHops - 1))"))
        }
        var aliases = Set<String>()
        for hop in hops {
            guard hop.alias.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil,
                  aliases.insert(hop.alias).inserted else {
                throw SSHError.invalidConfiguration("Invalid host alias \(hop.alias)")
            }
            if let alias = hop.userConfigAlias, !Self.isSafeValue(alias) {
                throw SSHError.invalidConfiguration(String(localized: "Invalid ssh_config alias for \(hop.displayName)"))
            }
            guard Self.isSafeValue(hop.hostname) else {
                throw SSHError.invalidConfiguration(String(localized: "Invalid address for \(hop.displayName)"))
            }
            guard Self.isSafeValue(hop.username) else {
                throw SSHError.invalidConfiguration(String(localized: "Invalid username for \(hop.displayName)"))
            }
            guard (1...65535).contains(hop.port) else {
                throw SSHError.invalidConfiguration(String(localized: "Invalid port for \(hop.displayName)"))
            }
        }
    }

    /// Hostnames / usernames end up in ssh_config values: no whitespace, quotes, control
    /// characters or leading dash.
    static func isSafeValue(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-") else { return false }
        return !value.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
                || scalar == "\"" || scalar == "'" || scalar == "\\" || scalar == "#"
        }
    }
}

// MARK: - Port forwarding

/// A forwarding rule applied to a live master connection with `ssh -O forward`.
struct SSHForward: Sendable, Hashable {
    enum Kind: String, Sendable {
        case local, remote, dynamic
    }

    var kind: Kind
    var bindPort: Int
    var destinationHost: String
    var destinationPort: Int

    init(kind: Kind, bindPort: Int, destinationHost: String = "127.0.0.1", destinationPort: Int = 0) {
        self.kind = kind
        self.bindPort = bindPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
    }

    /// Command line flag + value, e.g. ["-L", "8080:127.0.0.1:80"].
    var arguments: [String] {
        let destination = destinationHost.contains(":") ? "[\(destinationHost)]" : destinationHost
        switch kind {
        case .local: return ["-L", "\(bindPort):\(destination):\(destinationPort)"]
        case .remote: return ["-R", "\(bindPort):\(destination):\(destinationPort)"]
        case .dynamic: return ["-D", "\(bindPort)"]
        }
    }

    var displayDescription: String {
        switch kind {
        case .local: "localhost:\(bindPort) → \(destinationHost):\(destinationPort)"
        case .remote: "remote:\(bindPort) → \(destinationHost):\(destinationPort)"
        case .dynamic: "SOCKS localhost:\(bindPort)"
        }
    }
}

// MARK: - Prompts

/// What ssh is asking for, parsed from the askpass prompt text.
enum SSHPromptKind: Sendable, Equatable {
    /// "user@alias's password:"
    case password(alias: String?)
    /// "Enter passphrase for key '/path':" (ssh) or "Enter passphrase for /path:" (ssh-add)
    case passphrase(keyPath: String)
    /// First connection to a host: "The authenticity of host … can't be established."
    case hostKey(alias: String?, keyType: String?, fingerprint: String?)
    /// keyboard-interactive prompt, "(user@alias) Verification code:"
    case keyboardInteractive(alias: String?, prompt: String)
    /// Yes/no confirmation (SSH_ASKPASS_PROMPT=confirm).
    case confirmation
    case other
}

/// A prompt shown to the user, already mapped to the hop that asked.
struct SSHPrompt: Sendable, Equatable {
    var kind: SSHPromptKind
    /// Hop the prompt belongs to (nil if it could not be determined).
    var hopDisplayName: String?
    var hopEndpoint: String?
    /// Name of the connection (destination host) the prompt is for.
    var connectionName: String
    /// Raw prompt text from ssh.
    var message: String
    /// Recent informational output from ssh (banners, keyboard-interactive instructions).
    var details: String?
    /// Whether the answer can be saved to the vault (password / passphrase of a saved host or key).
    var canSave: Bool
    /// Whether the expected answer is a secret (masked input).
    var isSecret: Bool
}

enum SSHPromptResponse: Sendable, Equatable {
    case text(String, save: Bool)
    case accept
    case reject
    case cancel
}

// MARK: - Errors

enum SSHError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case cancelled
    case authenticationFailed(host: String, detail: String)
    case hostKeyChanged(host: String, detail: String)
    case hostKeyRejected(host: String)
    case connectionFailed(host: String, detail: String)
    case disconnected
    case commandFailed(String)
    case forwardFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .cancelled:
            return String(localized: "Connection cancelled")
        case .authenticationFailed(let host, let detail):
            return String(localized: "Authentication failed for \(host). \(detail)")
        case .hostKeyChanged(let host, _):
            return String(localized: "The host key of \(host) has changed. This could mean the server was reinstalled — or that someone is intercepting the connection. Remove the old key under Known Hosts only if you trust this change.")
        case .hostKeyRejected(let host):
            return String(localized: "The host key of \(host) was not trusted.")
        case .connectionFailed(let host, let detail):
            return detail.isEmpty
                ? String(localized: "Could not connect to \(host).")
                : String(localized: "Could not connect to \(host): \(Self.localizedReason(detail))")
        case .disconnected:
            return String(localized: "The connection was closed.")
        case .commandFailed(let message):
            return message
        case .forwardFailed(let message):
            return String(localized: "Port forwarding failed: \(message)")
        }
    }

    /// The few transport reasons ssh reports, in the interface language. The error itself keeps
    /// ssh's text (it is matched on and logged); anything else is a diagnostic and stays verbatim.
    private static func localizedReason(_ detail: String) -> String {
        if detail.hasPrefix("Could not resolve hostname") {
            return String(localized: "The host name could not be resolved")
        }
        switch detail {
        case "Connection refused": return String(localized: "Connection refused")
        case "Operation timed out", "Connection timed out": return String(localized: "Operation timed out")
        case "No route to host": return String(localized: "No route to host")
        case "Network is unreachable": return String(localized: "Network is unreachable")
        default: return detail
        }
    }
}
