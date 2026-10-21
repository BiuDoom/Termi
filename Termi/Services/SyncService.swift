import CryptoKit
import Foundation
import GRDB
import os.log

/// Sync engine — encrypted JSON envelope to local directory for backup & transfer
actor SyncService {
    static let shared = SyncService()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "Sync")
    private let crypto = CryptoService.shared
    private let fm = FileManager.default

    /// Encrypted envelope format
    struct SyncEnvelope: Codable {
        let version: Int
        let timestamp: String
        let salt: String
        let payload: String
    }

    /// Full synced snapshot. Missing keys default to empty arrays so older exports still import.
    struct SyncData: Codable {
        let hosts: [Host]
        let groups: [HostGroup]
        let snippets: [Snippet]
        var sshKeys: [SSHKey]
        var identities: [Identity]
        let knownHosts: [KnownHost]
        let portForwards: [PortForward]
        let tags: [Tag]
        let hostTags: [HostTag]
        let settings: [AppSetting]
        var vaultEntries: [VaultEntry]
        let cryptoConfig: [CryptoConfig]
        let connectionLogs: [ConnectionLog]
        let exportedAt: String
        /// True (format 3): vault values, SSH private keys and identity passwords are plaintext
        /// in this snapshot, protected by the envelope alone. False (format 2): they are still
        /// ciphertext of the vault that exported them.
        let secretsArePlaintext: Bool

        enum CodingKeys: String, CodingKey {
            case hosts
            case groups
            case snippets
            case sshKeys = "ssh_keys"
            case identities
            case knownHosts = "known_hosts"
            case portForwards = "port_forwards"
            case tags
            case hostTags = "host_tags"
            case settings
            case vaultEntries = "vault_entries"
            case cryptoConfig = "crypto_config"
            case connectionLogs = "connection_logs"
            case exportedAt = "exported_at"
            case secretsArePlaintext = "secrets_plaintext"
        }

        init(
            hosts: [Host],
            groups: [HostGroup],
            snippets: [Snippet],
            sshKeys: [SSHKey],
            identities: [Identity],
            knownHosts: [KnownHost],
            portForwards: [PortForward],
            tags: [Tag],
            hostTags: [HostTag],
            settings: [AppSetting],
            vaultEntries: [VaultEntry],
            cryptoConfig: [CryptoConfig],
            connectionLogs: [ConnectionLog],
            exportedAt: String,
            secretsArePlaintext: Bool
        ) {
            self.hosts = hosts
            self.groups = groups
            self.snippets = snippets
            self.sshKeys = sshKeys
            self.identities = identities
            self.knownHosts = knownHosts
            self.portForwards = portForwards
            self.tags = tags
            self.hostTags = hostTags
            self.settings = settings
            self.vaultEntries = vaultEntries
            self.cryptoConfig = cryptoConfig
            self.connectionLogs = connectionLogs
            self.exportedAt = exportedAt
            self.secretsArePlaintext = secretsArePlaintext
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hosts = try container.decodeIfPresent([Host].self, forKey: .hosts) ?? []
            groups = try container.decodeIfPresent([HostGroup].self, forKey: .groups) ?? []
            snippets = try container.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
            sshKeys = try container.decodeIfPresent([SSHKey].self, forKey: .sshKeys) ?? []
            identities = try container.decodeIfPresent([Identity].self, forKey: .identities) ?? []
            knownHosts = try container.decodeIfPresent([KnownHost].self, forKey: .knownHosts) ?? []
            portForwards = try container.decodeIfPresent([PortForward].self, forKey: .portForwards) ?? []
            tags = try container.decodeIfPresent([Tag].self, forKey: .tags) ?? []
            hostTags = try container.decodeIfPresent([HostTag].self, forKey: .hostTags) ?? []
            settings = try container.decodeIfPresent([AppSetting].self, forKey: .settings) ?? []
            vaultEntries = try container.decodeIfPresent([VaultEntry].self, forKey: .vaultEntries) ?? []
            cryptoConfig = try container.decodeIfPresent([CryptoConfig].self, forKey: .cryptoConfig) ?? []
            connectionLogs = try container.decodeIfPresent([ConnectionLog].self, forKey: .connectionLogs) ?? []
            exportedAt = try container.decodeIfPresent(String.self, forKey: .exportedAt) ?? ""
            secretsArePlaintext = try container.decodeIfPresent(Bool.self, forKey: .secretsArePlaintext) ?? false
        }
    }

    func syncDirectoryURL() -> URL? {
        let local = AppProfile.current.syncDirectory
        try? fm.createDirectory(at: local, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        return local
    }

    struct ExportResult: Sendable {
        let url: URL
        /// Stored secrets the vault key could not open; they are not in the export.
        let unreadableSecrets: Int
    }

    func exportSync(password: String) async throws -> ExportResult {
        guard let syncDir = syncDirectoryURL() else {
            throw SyncError.noSyncDirectory
        }
        let fileURL = syncDir.appendingPathComponent("termi-sync.json")

        let vaultKey = SymmetricKey(data: try await SecureStoreService.shared.currentVaultKeyData())
        let reader = try await DatabaseManager.shared.reader
        let unreadable = try await exportSync(of: reader, vaultKey: vaultKey, password: password, to: fileURL)

        logger.info("Exported sync file: \(fileURL.path)")
        return ExportResult(url: fileURL, unreadableSecrets: unreadable)
    }

    /// Write an encrypted export of `database` to `fileURL`; returns how many stored secrets
    /// `vaultKey` could not open (they are left out). The database and the vault key are
    /// parameters so that tests can pass scratch ones.
    func exportSync(
        of database: any DatabaseReader,
        vaultKey: SymmetricKey,
        password: String,
        to fileURL: URL
    ) async throws -> Int {
        var syncData = try await database.read { db in
            SyncData(
                hosts: try Host.order(Column("sort_order").asc, Column("label").asc).fetchAll(db),
                groups: try HostGroup.order(Column("sort_order").asc, Column("name").asc).fetchAll(db),
                snippets: try Snippet.order(Column("sort_order").asc, Column("name").asc).fetchAll(db),
                sshKeys: try SSHKey.order(Column("name").asc).fetchAll(db),
                identities: try Identity.order(Column("name").asc).fetchAll(db),
                knownHosts: try KnownHost.order(Column("hostname").asc, Column("port").asc, Column("key_type").asc).fetchAll(db),
                portForwards: try PortForward.order(Column("host_id").asc, Column("local_port").asc).fetchAll(db),
                tags: try Tag.order(Column("name").asc).fetchAll(db),
                hostTags: try HostTag.order(Column("host_id").asc, Column("tag_id").asc).fetchAll(db),
                settings: try AppSetting.order(Column("key").asc).fetchAll(db),
                vaultEntries: try VaultEntry.order(Column("key").asc).fetchAll(db),
                // Strip master password hash/salt and rate-limit state from export —
                // hash+salt could be used for offline brute-force attacks
                cryptoConfig: try CryptoConfig
                    .filter(
                        Column("key") != "master_password_hash"
                            && Column("key") != "master_password_salt"
                            && Column("key") != "failed_attempts"
                            && Column("key") != "locked_until"
                    )
                    .order(Column("key").asc)
                    .fetchAll(db),
                connectionLogs: try ConnectionLog.order(Column("connected_at").desc).fetchAll(db),
                exportedAt: TimestampFormatter.now(),
                secretsArePlaintext: true
            )
        }

        // Secrets leave the vault here and travel as plaintext inside the envelope, which the
        // export password encrypts: ciphertext under this Mac's vault key (its key file, or its
        // master password) could not be opened anywhere else. What the vault key cannot open
        // here cannot be transferred.
        var unreadable = 0
        var readableEntries: [VaultEntry] = []
        for var entry in syncData.vaultEntries {
            guard let plaintext = try? crypto.decryptString(entry.valueEncrypted, using: vaultKey) else {
                unreadable += 1
                continue
            }
            entry.valueEncrypted = plaintext
            readableEntries.append(entry)
        }
        syncData.vaultEntries = readableEntries
        for index in syncData.sshKeys.indices {
            // The row stays even without its private key: hosts and identities refer to it.
            let pem = try? crypto.decryptString(syncData.sshKeys[index].privateKeyEncrypted, using: vaultKey)
            if pem == nil { unreadable += 1 }
            syncData.sshKeys[index].privateKeyEncrypted = pem ?? ""
        }
        for index in syncData.identities.indices {
            guard let encrypted = syncData.identities[index].passwordEncrypted, !encrypted.isEmpty else { continue }
            let identityPassword = try? crypto.decryptString(encrypted, using: vaultKey)
            if identityPassword == nil { unreadable += 1 }
            syncData.identities[index].passwordEncrypted = identityPassword
        }
        if unreadable > 0 {
            logger.warning("Export leaves out \(unreadable) stored secrets the vault key cannot open")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(syncData)

        let salt = crypto.generateSalt()
        let key = try crypto.deriveKey(from: password, salt: salt)
        let encrypted = try crypto.encrypt(jsonData, using: key)

        let envelope = SyncEnvelope(
            version: 3,
            timestamp: TimestampFormatter.now(),
            salt: salt.base64EncodedString(),
            payload: encrypted.base64EncodedString()
        )

        let envelopeData = try JSONEncoder().encode(envelope)
        // The export password is all that protects the secrets in this file. Create it 0600
        // rather than writing a world-readable temporary and chmod'ing afterwards.
        try SSHRuntime.replacePrivateFile(envelopeData, at: fileURL)
        return unreadable
    }

    func importSync(from url: URL, password: String) async throws -> SyncData {
        let envelopeData = try Data(contentsOf: url)
        guard let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: envelopeData),
              let salt = Data(base64Encoded: envelope.salt),
              let encrypted = Data(base64Encoded: envelope.payload) else {
            throw SyncError.invalidFormat
        }

        let key = try crypto.deriveKey(from: password, salt: salt)
        guard let decrypted = try? crypto.decrypt(encrypted, using: key) else {
            throw SyncError.decryptionFailed
        }
        let syncData = try JSONDecoder().decode(SyncData.self, from: decrypted)

        logger.info(
            "Imported sync snapshot: \(syncData.hosts.count) hosts, \(syncData.sshKeys.count) keys, \(syncData.identities.count) identities"
        )
        return syncData
    }

    /// Replace current synced data with the imported snapshot while preserving primary keys and references.
    /// Returns where a copy of the database as it was before was kept.
    @discardableResult
    func applySyncData(_ data: SyncData) async throws -> URL {
        let database = DatabaseManager.shared
        let vaultKey = SymmetricKey(data: try await SecureStoreService.shared.currentVaultKeyData())

        // Every table is about to be replaced: keep a copy of the database as it is now.
        let kept = try await database.backupBeside(tag: "before-import")
        logger.info("Database before the import kept at \(kept.path)")

        try await DataReplacementCoordinator.shared.begin()
        do {
            try await applySyncData(data, to: try await database.writer, vaultKey: vaultKey)
        } catch {
            await DataReplacementCoordinator.shared.finish()
            throw error
        }
        await DataReplacementCoordinator.shared.finish()
        logger.info("Applied sync snapshot successfully")
        return kept
    }

    /// The database and the vault key the imported secrets are stored under are parameters so
    /// that tests can pass scratch ones.
    func applySyncData(_ data: SyncData, to database: any DatabaseWriter, vaultKey: SymmetricKey,
                       transcriptsIn transcripts: URL = SessionTranscripts.directory) async throws {
        // Secrets are brought under this vault's key before anything is deleted: one that cannot
        // be stored stops the import while the current data is still there.
        var snapshot = data
        if data.secretsArePlaintext {
            for index in snapshot.vaultEntries.indices {
                snapshot.vaultEntries[index].valueEncrypted =
                    try crypto.encryptString(snapshot.vaultEntries[index].valueEncrypted, using: vaultKey)
            }
            for index in snapshot.sshKeys.indices {
                snapshot.sshKeys[index].privateKeyEncrypted =
                    try crypto.encryptString(snapshot.sshKeys[index].privateKeyEncrypted, using: vaultKey)
            }
            for index in snapshot.identities.indices {
                guard let password = snapshot.identities[index].passwordEncrypted, !password.isEmpty else {
                    snapshot.identities[index].passwordEncrypted = nil
                    continue
                }
                snapshot.identities[index].passwordEncrypted = try crypto.encryptString(password, using: vaultKey)
            }
        } else {
            // Format 2 exported the vault's ciphertext as it was. It is only usable where this
            // vault's key opens all of it (the same Mac, the same master password).
            let ciphertexts = data.vaultEntries.map(\.valueEncrypted)
                + data.sshKeys.map(\.privateKeyEncrypted)
                + data.identities.compactMap(\.passwordEncrypted).filter { !$0.isEmpty }
            for ciphertext in ciphertexts {
                guard (try? crypto.decryptString(ciphertext, using: vaultKey)) != nil else {
                    throw SyncError.secretsNotTransferable
                }
            }
        }

        let imported = snapshot
        let highestTranscript = SessionTranscripts.highestId(in: transcripts)
        // `write` is one transaction: either the whole snapshot replaces the data or nothing does.
        try await database.write { db in
            // The snapshot is consistent as a whole, not row by row (groups, hosts, identities
            // and snippets refer to each other): check foreign keys at commit.
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            try Self.deleteCurrentSnapshot(from: db)
            // The transcripts of the history that was just replaced stay on disk for rolling
            // back: imported records are numbered above every one of them.
            try ConnectionLogRepository.reserveIds(db, through: highestTranscript)
            try Self.insertSnapshot(imported, into: db)
        }
    }

    // crypto_config is not part of a snapshot and stays as it is: it holds this Mac's master
    // password hash and salt, which the secrets stored above depend on.
    private static func deleteCurrentSnapshot(from db: Database) throws {
        try db.execute(sql: "DELETE FROM host_tags")
        try db.execute(sql: "DELETE FROM port_forwards")
        try db.execute(sql: "DELETE FROM connection_logs")
        try db.execute(sql: "DELETE FROM known_hosts")
        try db.execute(sql: "DELETE FROM hosts")
        try db.execute(sql: "DELETE FROM identities")
        try db.execute(sql: "DELETE FROM ssh_keys")
        try db.execute(sql: "DELETE FROM tags")
        try db.execute(sql: "DELETE FROM groups")
        try db.execute(sql: "DELETE FROM snippets")
        try db.execute(sql: "DELETE FROM settings")
        try db.execute(sql: "DELETE FROM vault")
    }

    private static func insertSnapshot(_ data: SyncData, into db: Database) throws {
        for group in data.groups {
            try group.insert(db)
        }
        for tag in data.tags {
            try tag.insert(db)
        }
        for setting in data.settings {
            try setting.insert(db)
        }
        for entry in data.vaultEntries {
            try entry.insert(db)
        }
        for key in data.sshKeys {
            try key.insert(db)
        }
        for identity in data.identities {
            try identity.insert(db)
        }
        for host in data.hosts {
            try host.insert(db)
        }
        for hostTag in data.hostTags {
            try hostTag.insert(db)
        }
        for knownHost in data.knownHosts {
            try knownHost.insert(db)
        }
        for snippet in data.snippets {
            try snippet.insert(db)
        }
        for portForward in data.portForwards {
            try portForward.insert(db)
        }
        // A history row's id names its transcript on the Mac that recorded it
        // (SessionLogs/<id>.log). Imported rows get fresh ids — above every id this database
        // has used and above every transcript on disk (the caller reserved those) — so that
        // none of them points at a transcript of this Mac that belongs to another session.
        // Oldest first: ids keep following time.
        for var log in data.connectionLogs.sorted(by: { $0.connectedAt < $1.connectedAt }) {
            log.id = nil
            try log.insert(db)
        }
    }

    enum SyncError: Error, LocalizedError {
        case noSyncDirectory
        case invalidFormat
        case decryptionFailed
        case secretsNotTransferable

        var errorDescription: String? {
            switch self {
            case .noSyncDirectory:
                String(localized: "Sync directory not available")
            case .invalidFormat:
                String(localized: "Invalid export file format")
            case .decryptionFailed:
                String(localized: "Wrong password or damaged file")
            case .secretsNotTransferable:
                String(localized: "This export was made by an older version of Termi: its saved passwords and private keys can only be read on the Mac that created it. Export again with this version.")
            }
        }
    }
}
