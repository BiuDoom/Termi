import GRDB
import Foundation
import os.log

/// Repository for Host CRUD operations
actor HostRepository {
    static let shared = HostRepository()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "HostRepo")

    // MARK: - Read

    func fetchAll() async throws -> [Host] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try Host.order(Column("sort_order").asc, Column("label").asc).fetchAll(db)
        }
    }

    func fetchGrouped() async throws -> [(group: HostGroup?, hosts: [Host])] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            let groups = try HostGroup.order(Column("sort_order").asc).fetchAll(db)
            let allHosts = try Host.order(Column("sort_order").asc, Column("label").asc).fetchAll(db)

            var result: [(group: HostGroup?, hosts: [Host])] = []

            // Ungrouped hosts first
            let ungrouped = allHosts.filter { $0.groupId == nil }
            if !ungrouped.isEmpty {
                result.append((group: nil, hosts: ungrouped))
            }

            // Grouped hosts
            for group in groups {
                let hosts = allHosts.filter { $0.groupId == group.id }
                if !hosts.isEmpty {
                    result.append((group: group, hosts: hosts))
                }
            }

            return result
        }
    }

    func fetch(id: Int64) async throws -> Host? {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try Host.fetchOne(db, key: id)
        }
    }

    func search(_ query: String) async throws -> [Host] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            // Escape LIKE wildcards in user input to prevent injection.
            // "%" and "_" are LIKE metacharacters; "\" is the escape character.
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            return try Host
                .filter(
                    Column("label").like(pattern, escape: "\\") ||
                    Column("hostname").like(pattern, escape: "\\") ||
                    Column("username").like(pattern, escape: "\\") ||
                    Column("notes").like(pattern, escape: "\\")
                )
                .order(Column("label").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Write

    /// What a save does with the host's saved password (the vault's `host_<id>`), in the same
    /// transaction as the row.
    enum SavedPassword: Sendable {
        /// Keep it while it still belongs to the login the host signs in with. A save that
        /// changes that login (address, port, account, identity, key or agent) forgets it — and
        /// is refused when forgetting it would make the host sign in with its group's identity:
        /// that is another account, which nobody chose (`HostRepositoryError`).
        case keep
        /// Store this ciphertext (under the vault key) as the new saved password.
        case replace(encrypted: String)
        /// Forget it: the host signs in as it would without one (asked, or the identity's).
        case forget
    }

    @discardableResult
    func save(_ host: Host, password: SavedPassword = .keep) async throws -> Host {
        let writer = try await DatabaseManager.shared.writer
        return try await DataSnapshot.write(writer) { db in
            try Self.save(host, password: password, db)
        }
    }

    static func save(_ host: Host, password: SavedPassword = .keep, _ db: Database) throws -> Host {
        var h = host
        let now = TimestampFormatter.now()
        h.updatedAt = now
        guard let id = h.id else {
            // New record: use insertAndFetch so GRDB backfills the generated id
            h.createdAt = now
            let inserted = try h.insertAndFetch(db)
            if case .replace(let encrypted) = password, let newId = inserted.id {
                try SecureStoreService.setHostPassword(encrypted: encrypted, hostId: newId, in: db)
            }
            return inserted
        }
        // Existing record: update in place. The detected system is not the form's to write —
        // the copy being saved may have been read before the probe stored it — unless the
        // address changed: then it describes another machine.
        let stored = try Host.fetchOne(db, key: id)
        if let stored, try SecureStoreService.hasHostPassword(hostId: id, in: db) {
            let oldContext = try SecureStoreService.passwordContext(for: stored, in: db)
            let newContext = try SecureStoreService.passwordContext(for: h, in: db)
            if oldContext != newContext {
                if case .keep = password, let group = try groupIdentityTakingOver(h, db) {
                    throw HostRepositoryError.savedPasswordWouldSwitchToGroupIdentity(group: group.name)
                }
                try SecureStoreService.deleteHostPassword(hostId: id, in: db)
            }
        }
        try h.update(db, columns: editableColumns)
        switch password {
        case .keep: break
        case .replace(let encrypted): try SecureStoreService.setHostPassword(encrypted: encrypted, hostId: id, in: db)
        case .forget: try SecureStoreService.deleteHostPassword(hostId: id, in: db)
        }
        if let stored {
            if stored.hostname != h.hostname || stored.port != h.port {
                try writeSystem(nil, detectedAt: nil, id: id, db)
            }
        }
        return try Host.fetchOne(db, key: id) ?? h
    }

    /// The group whose identity `host` would sign in with once it has no saved password — nil
    /// when it would not (it has an identity, a key or the agent of its own, or the group has
    /// no identity).
    static func groupIdentityTakingOver(_ host: Host, _ db: Database) throws -> HostGroup? {
        guard host.identityId == nil, let groupId = host.groupId,
              let group = try HostGroup.fetchOne(db, key: groupId),
              SSHPasswordContext.identityId(for: host, group: group, hasSavedPassword: false) != nil else {
            return nil
        }
        return group
    }

    /// Everything a save of the host writes: all columns but the detected system.
    private static let editableColumns: [String] = Host.CodingKeys.allCases
        .map(\.rawValue)
        .filter { !Host.systemColumns.contains($0) }

    /// Store what the host runs (nil forgets it). Only these columns are written, so an edit
    /// of the host saved at the same moment is not overwritten. With `address`, only while the
    /// host still has it: what was read from one machine is not stored on a host that was
    /// pointed at another in the meantime. Returns whether a row was written.
    @discardableResult
    func setSystem(_ system: HostSystem?, id: Int64, at address: (hostname: String, port: Int)? = nil) async throws -> Bool {
        let writer = try await DatabaseManager.shared.writer
        return try await DataSnapshot.write(writer) { db in
            try Self.writeSystem(system, detectedAt: system == nil ? nil : TimestampFormatter.now(), id: id,
                                 at: address, db)
        }
    }

    @discardableResult
    static func writeSystem(_ system: HostSystem?, detectedAt: String?, id: Int64,
                            at address: (hostname: String, port: Int)? = nil, _ db: Database) throws -> Bool {
        if let address {
            try db.execute(
                sql: """
                    UPDATE hosts SET os_id = ?, os_name = ?, os_arch = ?, os_detected_at = ?
                    WHERE id = ? AND hostname = ? AND port = ?
                    """,
                arguments: [system?.id, system?.name, system?.arch, detectedAt, id, address.hostname, address.port])
        } else {
            try db.execute(
                sql: "UPDATE hosts SET os_id = ?, os_name = ?, os_arch = ?, os_detected_at = ? WHERE id = ?",
                arguments: [system?.id, system?.name, system?.arch, detectedAt, id])
        }
        return db.changesCount > 0
    }

    // Deleting a host is `ConnectionLogRepository.deleteHostWithHistory(hostId:)`: its history rows
    // go with it (ON DELETE CASCADE), and with them the session output they recorded.

    func updateSortOrder(ids: [Int64]) async throws {
        let writer = try await DatabaseManager.shared.writer
        try await DataSnapshot.write(writer) { db in
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE hosts SET sort_order = ? WHERE id = ?",
                    arguments: [index, id]
                )
            }
        }
    }

    /// Record a successful connection (drives "recently connected" sorting).
    func markConnected(id: Int64) async throws {
        let writer = try await DatabaseManager.shared.writer
        try await DataSnapshot.write(writer) { db in
            try db.execute(sql: "UPDATE hosts SET last_connected_at = ? WHERE id = ?",
                           arguments: [TimestampFormatter.now(), id])
        }
    }

    func duplicate(id: Int64) async throws -> Host? {
        guard var host = try await fetch(id: id) else { return nil }
        host.id = nil
        host.label = String(localized: "\(host.label) (Copy)")
        host.lastConnectedAt = nil
        // The copy is usually pointed at another machine: it is read again when it connects.
        host.osId = nil
        host.osName = nil
        host.osArch = nil
        host.osDetectedAt = nil
        return try await save(host)
    }
}

enum HostRepositoryError: Error, LocalizedError, Equatable {
    /// The edit changes the login the saved password was typed for, and without it the host
    /// would sign in with the identity of its group (named).
    case savedPasswordWouldSwitchToGroupIdentity(group: String)

    var errorDescription: String? {
        switch self {
        case .savedPasswordWouldSwitchToGroupIdentity(let group):
            String(localized: "After this change the saved password no longer applies, and this host would sign in with the identity of the group “\(group)”. Enter the password again, or choose to forget the saved password.")
        }
    }
}
