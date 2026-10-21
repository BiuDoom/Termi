import Foundation
import CryptoKit
import GRDB
import os.log

/// App-managed encrypted credential storage backed by the local database.
actor SecureStoreService {
    static let shared = SecureStoreService()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "SecureStore")
    private let crypto = CryptoService.shared
    private var unlockedVaultKey: SymmetricKey?

    private enum VaultKey: String {
        case masterPasswordHash = "master_password_hash"
        case masterPasswordSalt = "master_password_salt"
    }

    // MARK: - Generic Secret Storage

    func setPassword(_ password: String, forAccount account: String) async throws {
        let key = try await requireUnlockedVaultKey()
        let encrypted = try crypto.encryptString(password, using: key)
        try await upsertVaultValue(encrypted, for: account)
        logger.debug("Stored encrypted secret for account: \(account)")
    }

    func getPassword(forAccount account: String) async throws -> String? {
        guard let encrypted = try await fetchVaultValue(for: account) else {
            return nil
        }

        let key = try await requireUnlockedVaultKey()
        return try crypto.decryptString(encrypted, using: key)
    }

    func deletePassword(forAccount account: String) async throws {
        let writer = try await DatabaseManager.shared.writer
        try await DataSnapshot.write(writer) { db in
            _ = try VaultEntry
                .filter(Column("key") == account)
                .deleteAll(db)
        }
    }

    func ensureUnlocked() async throws {
        _ = try await requireUnlockedVaultKey()
    }

    func encryptStoredValue(_ plaintext: String) async throws -> String {
        let key = try await requireUnlockedVaultKey()
        return try crypto.encryptString(plaintext, using: key)
    }

    func decryptStoredValue(_ ciphertext: String) async throws -> String {
        let key = try await requireUnlockedVaultKey()
        return try crypto.decryptString(ciphertext, using: key)
    }

    /// The key stored secrets are under right now; throws while the vault is locked. For the
    /// encrypted export / import, which takes every secret out of the vault or into it at once.
    /// (As bytes: SymmetricKey is not Sendable in the macOS 15 SDK.)
    func currentVaultKeyData() async throws -> Data {
        try await requireUnlockedVaultKey().withUnsafeBytes { Data($0) }
    }

    // MARK: - Host Password Helpers

    func setHostPassword(_ password: String, hostId: Int64, expectedContext: SSHPasswordContext? = nil) async throws {
        let key = try await requireUnlockedVaultKey()
        let encrypted = try crypto.encryptString(password, using: key)
        let writer = try await DatabaseManager.shared.writer
        try await DataSnapshot.write(writer) { db in
            if let expectedContext {
                guard let host = try Host.fetchOne(db, key: hostId),
                      try Self.passwordContext(for: host, in: db) == expectedContext else {
                    throw CancellationError()
                }
            }
            try Self.upsertVaultValue(encrypted, for: "host_\(hostId)", in: db)
        }
    }

    func getHostPassword(hostId: Int64) async throws -> String? {
        try await getPassword(forAccount: "host_\(hostId)")
    }

    func deleteHostPassword(hostId: Int64) async throws {
        let writer = try await DatabaseManager.shared.writer
        try await DataSnapshot.write(writer) { db in
            try Self.deleteHostPassword(hostId: hostId, in: db)
        }
    }

    /// Share the host update's transaction: a new login must never see the old login's secret.
    nonisolated static func deleteHostPassword(hostId: Int64, in db: Database) throws {
        _ = try VaultEntry.filter(Column("key") == "host_\(hostId)").deleteAll(db)
    }

    /// Resolve exactly the account/credential selection used by SSH, without decrypting secrets.
    /// Display labels, raw username on an explicit identity, group ids and jump choices are
    /// not login identities; changing them alone must not discard a useful saved password.
    nonisolated static func passwordContext(for host: Host, in db: Database) throws -> SSHPasswordContext {
        let group = try host.groupId.flatMap { try HostGroup.fetchOne(db, key: $0) }
        let hasSavedPassword = try host.id.map { try hasHostPassword(hostId: $0, in: db) } ?? false
        return try SSHPasswordContext.resolve(host: host, group: group, hasSavedPassword: hasSavedPassword) {
            try Identity.fetchOne(db, key: $0)
        }
    }

    /// Whether the vault holds a password saved for this host.
    nonisolated static func hasHostPassword(hostId: Int64, in db: Database) throws -> Bool {
        try VaultEntry.filter(Column("key") == "host_\(hostId)").fetchCount(db) > 0
    }

    /// Run `write` and forget the saved password of each of these hosts whose login it changes
    /// (another account, address, identity, key or agent), in the same transaction: a password
    /// typed for one account is never sent to another. The logins are compared as
    /// `passwordContext` resolves them, before and after `write`, all of them before any
    /// password is removed — as SSH sees them on the next connection.
    nonisolated static func dropHostPasswordsWhoseLoginChanges<T>(
        hostIds: [Int64], in db: Database, around write: () throws -> T
    ) throws -> T {
        var before: [Int64: SSHPasswordContext] = [:]
        for id in Set(hostIds) {
            guard try hasHostPassword(hostId: id, in: db), let host = try Host.fetchOne(db, key: id) else { continue }
            before[id] = try passwordContext(for: host, in: db)
        }
        let result = try write()
        var changed: [Int64] = []
        for (id, context) in before {
            guard let host = try Host.fetchOne(db, key: id) else {
                changed.append(id)
                continue
            }
            if try passwordContext(for: host, in: db) != context { changed.append(id) }
        }
        for id in changed { try deleteHostPassword(hostId: id, in: db) }
        return result
    }

    /// Store ciphertext under the vault key as the host's saved password, inside the caller's
    /// transaction (`HostRepository.save`).
    nonisolated static func setHostPassword(encrypted: String, hostId: Int64, in db: Database) throws {
        try upsertVaultValue(encrypted, for: "host_\(hostId)", in: db)
    }

    // MARK: - Master Password

    func configureMasterPassword(_ password: String) async throws {
        // Re-encrypt existing vault entries from the default key to the new master key
        let oldKey = try defaultVaultKey()
        let writer = try await DatabaseManager.shared.writer
        let newKey = try await configureMasterPassword(password, in: writer, replacing: oldKey)
        unlockedVaultKey = SymmetricKey(data: newKey)
        logger.info("Master password configured; vault entries re-encrypted")
    }

    /// Set the master password of `database`, whose secrets are under `oldKey` so far, and
    /// return the key they are under afterwards — as bytes: tests call this from outside the
    /// actor, and SymmetricKey is not Sendable in the macOS 15 SDK. The database and the key
    /// are parameters so that tests can pass scratch ones.
    func configureMasterPassword(
        _ password: String,
        in database: any DatabaseWriter,
        replacing oldKey: SymmetricKey
    ) async throws -> Data {
        let salt = crypto.generateSalt()
        let hash = try crypto.hashPassword(password, salt: salt)
        let newKey = try crypto.deriveKey(from: password, salt: salt, context: CryptoService.Context.vault)

        let rows = [
            CryptoConfig(key: VaultKey.masterPasswordHash.rawValue, value: hash),
            CryptoConfig(key: VaultKey.masterPasswordSalt.rawValue, value: salt.base64EncodedString())
        ]
        // The hash and the salt go into the transaction that re-encrypts: ciphertext under the
        // new key can never be opened again if its salt does not reach the disk.
        try await reEncryptVaultEntries(in: database, from: oldKey, to: newKey) { db in
            for row in rows {
                // Checked inside the transaction, where nothing can come in between: a second
                // master password would replace the salt the stored secrets depend on.
                guard try CryptoConfig.fetchOne(db, key: row.key) == nil else {
                    throw SecureStoreError.masterPasswordAlreadyConfigured
                }
                try row.insert(db)
            }
        }
        return newKey.withUnsafeBytes { Data($0) }
    }

    /// Re-encrypt everything stored under the vault key from one key to another: vault entries,
    /// SSH private keys and identity passwords. `configChange` — the master password's hash and
    /// salt being written or removed — runs in the same transaction. The database is a
    /// parameter so that tests can pass a scratch one.
    func reEncryptVaultEntries(
        in database: any DatabaseWriter,
        from oldKey: SymmetricKey,
        to newKey: SymmetricKey,
        alongside configChange: (@Sendable (Database) throws -> Void)? = nil
    ) async throws {
        let (entries, sshKeys, identities) = try await database.read { db -> ([VaultEntry], [SSHKey], [Identity]) in
            (try VaultEntry.fetchAll(db), try SSHKey.fetchAll(db), try Identity.fetchAll(db))
        }

        // A value the old key cannot open is skipped and keeps its ciphertext: it may already be
        // under the other key, and failing here would make it impossible to set or remove the
        // master password ever again.
        var reEncryptedEntries: [(key: String, value: String)] = []
        for entry in entries {
            do {
                let plaintext = try crypto.decryptString(entry.valueEncrypted, using: oldKey)
                let reEncrypted = try crypto.encryptString(plaintext, using: newKey)
                reEncryptedEntries.append((key: entry.key, value: reEncrypted))
            } catch {
                logger.warning("Could not re-encrypt vault entry '\(entry.key)': \(error)")
            }
        }

        var reEncryptedKeys: [(id: Int64, value: String)] = []
        for key in sshKeys {
            guard let id = key.id else { continue }
            do {
                let plaintext = try crypto.decryptString(key.privateKeyEncrypted, using: oldKey)
                let reEncrypted = try crypto.encryptString(plaintext, using: newKey)
                reEncryptedKeys.append((id: id, value: reEncrypted))
            } catch {
                logger.warning("Could not re-encrypt SSH private key \(id): \(error)")
            }
        }

        var reEncryptedIdentities: [(id: Int64, value: String)] = []
        for identity in identities {
            guard let id = identity.id, let encrypted = identity.passwordEncrypted, !encrypted.isEmpty else { continue }
            do {
                let plaintext = try crypto.decryptString(encrypted, using: oldKey)
                let reEncrypted = try crypto.encryptString(plaintext, using: newKey)
                reEncryptedIdentities.append((id: id, value: reEncrypted))
            } catch {
                logger.warning("Could not re-encrypt password of identity \(id): \(error)")
            }
        }

        guard configChange != nil || !reEncryptedEntries.isEmpty || !reEncryptedKeys.isEmpty
                || !reEncryptedIdentities.isEmpty else { return }

        let updates = reEncryptedEntries
        let keyUpdates = reEncryptedKeys
        let identityUpdates = reEncryptedIdentities
        let timestamp = TimestampFormatter.now()
        // One transaction: either every table moves to the new key, with `configChange`, or
        // nothing changes.
        try await database.write { db in
            for entry in updates {
                if var existing = try VaultEntry.filter(Column("key") == entry.key).fetchOne(db) {
                    existing.valueEncrypted = entry.value
                    existing.updatedAt = timestamp
                    try existing.update(db)
                }
            }
            for key in keyUpdates {
                try db.execute(
                    sql: "UPDATE ssh_keys SET private_key_encrypted = ? WHERE id = ?",
                    arguments: [key.value, key.id]
                )
            }
            for identity in identityUpdates {
                try db.execute(
                    sql: "UPDATE identities SET password_encrypted = ? WHERE id = ?",
                    arguments: [identity.value, identity.id]
                )
            }
            try configChange?(db)
        }
    }

    func unlock(masterPassword: String) async throws -> Bool {
        // Rate limiting — check if account is temporarily locked
        try await checkRateLimitLock()

        guard let hash = try await getMasterPasswordHash(),
              let saltBase64 = try await getMasterPasswordSalt(),
              let salt = Data(base64Encoded: saltBase64) else {
            throw SecureStoreError.masterPasswordNotConfigured
        }

        let isValid = try crypto.verifyPassword(masterPassword, salt: salt, hash: hash)
        guard isValid else {
            try await recordFailedAttempt()
            return false
        }

        // Success — reset rate limiter
        try await resetRateLimiter()

        unlockedVaultKey = try crypto.deriveKey(
            from: masterPassword,
            salt: salt,
            context: CryptoService.Context.vault
        )
        return true
    }

    // MARK: - Rate Limiting

    /// Maximum failed attempts before exponential lockout kicks in
    private static let maxAttemptsBeforeLock = 5

    private func checkRateLimitLock() async throws {
        let lockedUntilStr = try await fetchConfigValue(for: "locked_until") ?? "0"
        let lockedUntil = TimeInterval(lockedUntilStr) ?? 0

        if lockedUntil > Date().timeIntervalSince1970 {
            let remaining = Int(lockedUntil - Date().timeIntervalSince1970)
            throw SecureStoreError.rateLimited(secondsRemaining: remaining)
        }
    }

    private func recordFailedAttempt() async throws {
        let currentStr = try await fetchConfigValue(for: "failed_attempts") ?? "0"
        let current = Int(currentStr) ?? 0
        let newCount = current + 1

        try await upsertConfigValue("\(newCount)", for: "failed_attempts")

        // After threshold, apply exponential backoff: 2^(n-5) * 30 seconds
        // 5 fails → 30s, 6 → 60s, 7 → 120s, 8 → 240s, etc.
        if newCount >= Self.maxAttemptsBeforeLock {
            let exponent = newCount - Self.maxAttemptsBeforeLock
            let lockSeconds = min(30 * (1 << exponent), 3600) // cap at 1 hour
            let lockedUntil = Date().timeIntervalSince1970 + Double(lockSeconds)
            try await upsertConfigValue("\(lockedUntil)", for: "locked_until")
            logger.warning("Rate limit activated: \(lockSeconds)s lockout after \(newCount) failed attempts")
        }
    }

    private func resetRateLimiter() async throws {
        try await upsertConfigValue("0", for: "failed_attempts")
        try await upsertConfigValue("0", for: "locked_until")
    }

    /// Returns the number of seconds remaining in the lockout, or nil if not locked
    func rateLimitRemainingSeconds() async throws -> Int? {
        let lockedUntilStr = try await fetchConfigValue(for: "locked_until") ?? "0"
        let lockedUntil = TimeInterval(lockedUntilStr) ?? 0
        let remaining = lockedUntil - Date().timeIntervalSince1970
        return remaining > 0 ? Int(remaining) : nil
    }

    private func getMasterPasswordHash() async throws -> String? {
        try await fetchConfigValue(for: VaultKey.masterPasswordHash.rawValue)
    }

    private func getMasterPasswordSalt() async throws -> String? {
        try await fetchConfigValue(for: VaultKey.masterPasswordSalt.rawValue)
    }

    func hasMasterPassword() async throws -> Bool {
        (try await getMasterPasswordHash()) != nil
    }

    func lockVault() {
        unlockedVaultKey = nil
    }

    func deleteMasterPassword() async throws {
        // While locked there is no key to re-encrypt with: removing the salt now would leave
        // every stored secret undecryptable. (Read the key once — the vault can be locked
        // while this method is suspended.)
        let currentKey = unlockedVaultKey
        if currentKey == nil, try await hasMasterPassword() {
            throw SecureStoreError.vaultLocked
        }

        // Re-encrypt vault entries back to default key while removing master password
        let writer = try await DatabaseManager.shared.writer
        let fallbackKey = try defaultVaultKey()
        try await removeMasterPassword(in: writer, from: currentKey ?? fallbackKey, to: fallbackKey)
        unlockedVaultKey = fallbackKey
        logger.info("Master password removed; vault entries re-encrypted with default key")
    }

    /// Remove the master password of `database` and bring its secrets from `currentKey` back
    /// under `fallbackKey`. The database and the keys are parameters so that tests can pass
    /// scratch ones.
    func removeMasterPassword(
        in database: any DatabaseWriter,
        from currentKey: SymmetricKey,
        to fallbackKey: SymmetricKey
    ) async throws {
        let configKeys = [VaultKey.masterPasswordHash.rawValue, VaultKey.masterPasswordSalt.rawValue]
        // The same transaction as the re-encryption: with the secrets back under the default key
        // but the hash and the salt still there, the next unlock would derive a key that opens
        // none of them.
        try await reEncryptVaultEntries(in: database, from: currentKey, to: fallbackKey) { db in
            _ = try CryptoConfig
                .filter(configKeys.contains(Column("key")))
                .deleteAll(db)
        }
    }

    // MARK: - SSH Key Passphrase

    func setKeyPassphrase(_ passphrase: String, keyId: Int64) async throws {
        try await setPassword(passphrase, forAccount: "sshkey_\(keyId)")
    }

    func getKeyPassphrase(keyId: Int64) async throws -> String? {
        try await getPassword(forAccount: "sshkey_\(keyId)")
    }

    // MARK: - Storage Helpers

    private func requireUnlockedVaultKey() async throws -> SymmetricKey {
        if let unlockedVaultKey {
            return unlockedVaultKey
        }

        if try await hasMasterPassword() {
            throw SecureStoreError.vaultLocked
        }

        // No master password configured — auto-unlock with a default key.
        // This lets password storage work out of the box without setup.
        // Setting a master password later adds user-specific protection
        // (existing vault entries will need to be re-saved).
        let key = try defaultVaultKey()
        unlockedVaultKey = key
        logger.debug("Vault auto-unlocked with default key (no master password)")
        return key
    }

    // MARK: - Default Vault Key (file-backed random key, NO macOS Keychain)

    /// Retrieve or generate a random 256-bit key stored as a local file.
    /// Each device gets a unique key. The file is protected by POSIX
    /// permissions (0600 — owner read/write only).
    /// Throws on corruption or write failure — callers MUST handle the error.
    private func defaultVaultKey() throws -> SymmetricKey {
        if let existing = try readFileVaultKey() {
            return SymmetricKey(data: existing)
        }

        // First launch — generate a random key and persist it
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        do {
            try saveFileVaultKey(keyData)
        } catch {
            throw SecureStoreError.vaultKeyWriteFailed(underlying: error)
        }
        return key
    }

    /// Path: <profile folder>/.vault-key (~/Library/Application Support/Termi/.vault-key in
    /// the standard profile).
    private static func vaultKeyFileURL() throws -> URL {
        AppProfile.current.vaultKeyURL
    }

    /// Reads the vault key from disk.
    /// Returns `nil` only when the file does not exist (first launch).
    /// Throws on corruption or read failure — callers must NOT silently generate a new key.
    private func readFileVaultKey() throws -> Data? {
        let url = try Self.vaultKeyFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data = try Data(contentsOf: url)
        guard data.count == 32 else {
            logger.error("Vault key file corrupted: expected 32 bytes, got \(data.count)")
            throw SecureStoreError.vaultKeyCorrupted(path: url.path)
        }
        return data
    }

    /// Persists the vault key to disk. Throws on failure — the caller MUST handle this,
    /// because an unpersisted key means all encrypted data becomes unrecoverable after restart.
    private func saveFileVaultKey(_ keyData: Data) throws {
        let url = try Self.vaultKeyFileURL()
        let dir = url.deletingLastPathComponent()

        // Create directory with 0700 (owner-only access)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        // Write key file with 0600 (owner read/write only)
        try keyData.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        logger.info("Vault key saved to local file (permissions 0600)")
    }

    private func upsertVaultValue(_ encryptedValue: String, for key: String) async throws {
        let writer = try await DatabaseManager.shared.writer
        try await DataSnapshot.write(writer) { db in
            try Self.upsertVaultValue(encryptedValue, for: key, in: db)
        }
    }

    private nonisolated static func upsertVaultValue(_ encryptedValue: String, for key: String, in db: Database) throws {
        let timestamp = TimestampFormatter.now()
        if var entry = try VaultEntry.filter(Column("key") == key).fetchOne(db) {
            entry.valueEncrypted = encryptedValue
            entry.updatedAt = timestamp
            try entry.update(db)
        } else {
            try VaultEntry(id: nil, key: key, valueEncrypted: encryptedValue,
                           createdAt: timestamp, updatedAt: timestamp).insert(db)
        }
    }

    private func fetchVaultValue(for key: String) async throws -> String? {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try VaultEntry
                .filter(Column("key") == key)
                .fetchOne(db)?
                .valueEncrypted
        }
    }

    private func upsertConfigValue(_ value: String, for key: String) async throws {
        let writer = try await DatabaseManager.shared.writer
        try await DataSnapshot.write(writer) { db in
            if var config = try CryptoConfig.fetchOne(db, key: key) {
                config.value = value
                try config.update(db)
            } else {
                let config = CryptoConfig(key: key, value: value)
                try config.insert(db)
            }
        }
    }

    private func fetchConfigValue(for key: String) async throws -> String? {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try CryptoConfig.fetchOne(db, key: key)?.value
        }
    }

    // MARK: - Error

    enum SecureStoreError: Error, LocalizedError {
        case vaultLocked
        case masterPasswordNotConfigured
        case masterPasswordAlreadyConfigured
        case rateLimited(secondsRemaining: Int)
        case vaultKeyCorrupted(path: String)
        case vaultKeyWriteFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .vaultLocked:
                String(localized: "Termi is locked. Unlock it before using stored credentials.")
            case .masterPasswordNotConfigured:
                String(localized: "Set a master password before storing encrypted credentials.")
            case .masterPasswordAlreadyConfigured:
                String(localized: "A master password is already set. Remove it before setting a new one.")
            case .rateLimited(let seconds):
                String(localized: "Too many failed attempts. Try again in \(seconds) seconds.")
            case .vaultKeyCorrupted(let path):
                String(localized: "The vault key file at \(path) is damaged. Previously encrypted data cannot be decrypted. Restore from a backup.")
            case .vaultKeyWriteFailed(let error):
                String(localized: "The vault key could not be saved: \(error.localizedDescription). Data encrypted in this session may be lost on restart.")
            }
        }
    }
}
