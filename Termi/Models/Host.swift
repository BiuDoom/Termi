import GRDB
import Foundation

struct Host: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "hosts"

    var id: Int64?
    var label: String
    var hostname: String
    var port: Int
    /// Empty = inherit from the group (or the host's identity).
    var username: String
    /// "password", "privateKey" or "agent" (system ssh-agent / default ~/.ssh keys).
    var authType: String
    var passwordEncrypted: String?
    var privateKeyId: Int64?
    var identityId: Int64?
    var groupId: Int64?
    var color: String?
    var sortOrder: Int
    var notes: String?
    var x11Forwarding: Bool
    var createdAt: String
    var updatedAt: String
    /// Connect through this host first (it may have its own jump host → chain).
    var jumpHostId: Int64? = nil
    var agentForwarding: Bool = false
    /// Snippet typed into the shell right after connecting.
    var startupSnippetId: Int64? = nil
    /// Terminal color theme id for this host (nil = app default).
    var terminalTheme: String? = nil
    var lastConnectedAt: String? = nil
    /// What the host runs, read from it after connecting (see `HostSystemProbe`): normalised id
    /// ("ubuntu"), the name it gives itself, its architecture, and when that was read. Written
    /// only by `HostRepository.setSystem`; a save of the host does not touch these columns.
    var osId: String? = nil
    var osName: String? = nil
    var osArch: String? = nil
    var osDetectedAt: String? = nil
    /// Original Host name from an ssh_config import, independent of the editable display label.
    var sshConfigAlias: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, hostname, port, username
        case authType = "auth_type"
        case passwordEncrypted = "password_encrypted"
        case privateKeyId = "private_key_id"
        case identityId = "identity_id"
        case groupId = "group_id"
        case color
        case sortOrder = "sort_order"
        case notes
        case x11Forwarding = "x11_forwarding"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case jumpHostId = "jump_host_id"
        case agentForwarding = "agent_forwarding"
        case startupSnippetId = "startup_snippet_id"
        case terminalTheme = "terminal_theme"
        case lastConnectedAt = "last_connected_at"
        case osId = "os_id"
        case osName = "os_name"
        case osArch = "os_arch"
        case osDetectedAt = "os_detected_at"
        case sshConfigAlias = "ssh_config_alias"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Host {
    /// Tolerant decoding: exports from older versions don't contain the newer columns.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        authType = try c.decodeIfPresent(String.self, forKey: .authType) ?? "password"
        passwordEncrypted = try c.decodeIfPresent(String.self, forKey: .passwordEncrypted)
        privateKeyId = try c.decodeIfPresent(Int64.self, forKey: .privateKeyId)
        identityId = try c.decodeIfPresent(Int64.self, forKey: .identityId)
        groupId = try c.decodeIfPresent(Int64.self, forKey: .groupId)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        x11Forwarding = try c.decodeIfPresent(Bool.self, forKey: .x11Forwarding) ?? false
        let now = TimestampFormatter.now()
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? now
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? now
        jumpHostId = try c.decodeIfPresent(Int64.self, forKey: .jumpHostId)
        agentForwarding = try c.decodeIfPresent(Bool.self, forKey: .agentForwarding) ?? false
        startupSnippetId = try c.decodeIfPresent(Int64.self, forKey: .startupSnippetId)
        terminalTheme = try c.decodeIfPresent(String.self, forKey: .terminalTheme)
        lastConnectedAt = try c.decodeIfPresent(String.self, forKey: .lastConnectedAt)
        osId = try c.decodeIfPresent(String.self, forKey: .osId)
        osName = try c.decodeIfPresent(String.self, forKey: .osName)
        osArch = try c.decodeIfPresent(String.self, forKey: .osArch)
        osDetectedAt = try c.decodeIfPresent(String.self, forKey: .osDetectedAt)
        sshConfigAlias = try c.decodeIfPresent(String.self, forKey: .sshConfigAlias)
    }

    static func defaultValue() -> Host {
        let timestamp = TimestampFormatter.now()
        return Host(
            label: "",
            hostname: "",
            port: 22,
            username: "root",
            authType: "password",
            sortOrder: 0,
            x11Forwarding: false,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    /// Key used to share one SSH master connection between all sessions of this host.
    var connectionKey: String {
        if let id { return "host-\(id)" }
        return "adhoc-\(username)@\(hostname):\(port)"
    }

    /// Whether `other` is this host with the same connection: only what changes the SSH
    /// connection is compared — not the name, colour or notes, not when it was last connected
    /// and not the system read from it.
    func connectsLike(_ other: Host) -> Bool {
        id == other.id && connectionKey == other.connectionKey
            && hostname == other.hostname && port == other.port && username == other.username
            && authType == other.authType && passwordEncrypted == other.passwordEncrypted
            && privateKeyId == other.privateKeyId && identityId == other.identityId
            && groupId == other.groupId && jumpHostId == other.jumpHostId
            && agentForwarding == other.agentForwarding && x11Forwarding == other.x11Forwarding
            && sshConfigAlias == other.sshConfigAlias
    }

    /// "user@host" (with port when not 22) — the user part may be inherited, so it can be empty.
    var addressDescription: String {
        let host = hostname.contains(":") ? "[\(hostname)]" : hostname
        let base = username.isEmpty ? host : "\(username)@\(host)"
        return port == 22 ? base : "\(base):\(port)"
    }
}
