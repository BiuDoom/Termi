import Testing
import CryptoKit
import Foundation
import GRDB
@testable import Termi

// The vault and everything that moves its contents — setting and removing the master password,
// encrypted export / import, backup / restore, key passphrases — against scratch databases in
// the temporary directory: neither the app database nor the vault key file is involved.

private let oldKeyData = Data(repeating: 0x11, count: 32)
private let newKeyData = Data(repeating: 0x22, count: 32)
private let foreignKeyData = Data(repeating: 0x33, count: 32)

/// A migrated database in a folder of its own; the caller discards it when done.
private func makeScratchDatabase() throws -> (pool: DatabasePool, folder: URL) {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: folder.appendingPathComponent("scratch.db").path)
    try Migrations.run(pool)
    return (pool, folder)
}

/// Close before deleting: SQLite reports files that are unlinked while still open.
private func discard(_ scratch: (pool: DatabasePool, folder: URL)) {
    try? scratch.pool.close()
    try? FileManager.default.removeItem(at: scratch.folder)
}

// Which case a thrown error is. The matching sits in functions of its own because Swift 6.0
// (Xcode 16.2) crashes while type-checking an enum pattern matched against `any Error` inside
// a closure handed to `#expect`.
private func isMasterPasswordAlreadyConfigured(_ error: any Error) -> Bool {
    if case SecureStoreService.SecureStoreError.masterPasswordAlreadyConfigured = error { return true }
    return false
}

private func isSecretsNotTransferable(_ error: any Error) -> Bool {
    if case SyncService.SyncError.secretsNotTransferable = error { return true }
    return false
}

private func isFileIsLiveDatabase(_ error: any Error) -> Bool {
    if case DatabaseManager.DatabaseError.fileIsLiveDatabase = error { return true }
    return false
}

private func isPassphraseNotSet(_ error: any Error) -> Bool {
    if case SSHKeyGenerator.KeyGenError.passphraseNotSet = error { return true }
    return false
}

private func encrypted(_ plaintext: String, under keyData: Data) throws -> String {
    try CryptoService.shared.encryptString(plaintext, using: SymmetricKey(data: keyData))
}

private func decrypted(_ ciphertext: String, under keyData: Data) throws -> String {
    try CryptoService.shared.decryptString(ciphertext, using: SymmetricKey(data: keyData))
}

// The vault table is empty here on purpose: keys and identities used to be skipped altogether,
// and an early return on "no vault entries" would skip them again.
@Test func reEncryptionCoversKeysAndIdentitiesWithEmptyVault() async throws {
    let scratch = try makeScratchDatabase()
    defer { discard(scratch) }

    let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"
    let keyCiphertext = try encrypted(pem, under: oldKeyData)
    let foreignCiphertext = try encrypted("other", under: foreignKeyData)
    let passwordCiphertext = try encrypted("s3cr3t", under: oldKeyData)
    let timestamp = TimestampFormatter.now()

    try await scratch.pool.write { db in
        try SSHKey(name: "prod", type: "ed25519", publicKey: "ssh-ed25519 AAAA prod",
                   privateKeyEncrypted: keyCiphertext, createdAt: timestamp).insert(db)
        try SSHKey(name: "foreign", type: "ed25519", publicKey: "ssh-ed25519 BBBB foreign",
                   privateKeyEncrypted: foreignCiphertext, createdAt: timestamp).insert(db)
        try Identity(name: "deploy", username: "deploy", authType: "password",
                     passwordEncrypted: passwordCiphertext, createdAt: timestamp).insert(db)
        try Identity(name: "agent", username: "ops", authType: "agent", createdAt: timestamp).insert(db)
    }

    try await SecureStoreService().reEncryptVaultEntries(
        in: scratch.pool,
        from: SymmetricKey(data: oldKeyData),
        to: SymmetricKey(data: newKeyData)
    )

    let (keys, identities) = try await scratch.pool.read { db -> ([SSHKey], [Identity]) in
        (try SSHKey.fetchAll(db), try Identity.fetchAll(db))
    }
    let prod = try #require(keys.first(where: { $0.name == "prod" }))
    let foreign = try #require(keys.first(where: { $0.name == "foreign" }))
    let deploy = try #require(identities.first(where: { $0.name == "deploy" }))
    let agent = try #require(identities.first(where: { $0.name == "agent" }))

    let prodPEM = try decrypted(prod.privateKeyEncrypted, under: newKeyData)
    #expect(prodPEM == pem)
    let deployCiphertext = try #require(deploy.passwordEncrypted)
    let deployPassword = try decrypted(deployCiphertext, under: newKeyData)
    #expect(deployPassword == "s3cr3t")
    // Not under the old key: kept byte for byte instead of failing the whole operation.
    #expect(foreign.privateKeyEncrypted == foreignCiphertext)
    #expect(agent.passwordEncrypted == nil)
}

@Test func reEncryptionMovesVaultEntriesTogetherWithKeys() async throws {
    let scratch = try makeScratchDatabase()
    defer { discard(scratch) }

    let hostCiphertext = try encrypted("host-password", under: oldKeyData)
    let keyCiphertext = try encrypted("PEM", under: oldKeyData)
    let timestamp = TimestampFormatter.now()

    try await scratch.pool.write { db in
        try VaultEntry(id: nil, key: "host_1", valueEncrypted: hostCiphertext,
                       createdAt: timestamp, updatedAt: timestamp).insert(db)
        try SSHKey(name: "prod", type: "ed25519", publicKey: "ssh-ed25519 AAAA prod",
                   privateKeyEncrypted: keyCiphertext, createdAt: timestamp).insert(db)
    }

    let store = SecureStoreService()
    try await store.reEncryptVaultEntries(
        in: scratch.pool,
        from: SymmetricKey(data: oldKeyData),
        to: SymmetricKey(data: newKeyData)
    )
    // And back, as removing the master password does.
    try await store.reEncryptVaultEntries(
        in: scratch.pool,
        from: SymmetricKey(data: newKeyData),
        to: SymmetricKey(data: oldKeyData)
    )

    let (entries, keys) = try await scratch.pool.read { db -> ([VaultEntry], [SSHKey]) in
        (try VaultEntry.fetchAll(db), try SSHKey.fetchAll(db))
    }
    let entry = try #require(entries.first)
    let key = try #require(keys.first)

    let hostPassword = try decrypted(entry.valueEncrypted, under: oldKeyData)
    #expect(hostPassword == "host-password")
    let keyPEM = try decrypted(key.privateKeyEncrypted, under: oldKeyData)
    #expect(keyPEM == "PEM")
    // Re-encrypted twice, not left alone: AES-GCM uses a fresh nonce every time.
    #expect(entry.valueEncrypted != hostCiphertext)
    #expect(key.privateKeyEncrypted != keyCiphertext)
}

// MARK: - Master password: one transaction

private func cryptoConfig(of pool: DatabasePool) async throws -> [String: String] {
    try await pool.read { db in
        Dictionary(uniqueKeysWithValues: try CryptoConfig.fetchAll(db).map { ($0.key, $0.value) })
    }
}

/// One vault entry and one SSH key under `keyData`; returns their ciphertexts.
private func insertOneEntryAndKey(into pool: DatabasePool, under keyData: Data) async throws -> (entry: String, key: String) {
    let entryCiphertext = try encrypted("host-password", under: keyData)
    let keyCiphertext = try encrypted("PEM", under: keyData)
    let timestamp = TimestampFormatter.now()
    try await pool.write { db in
        try VaultEntry(id: nil, key: "host_1", valueEncrypted: entryCiphertext,
                       createdAt: timestamp, updatedAt: timestamp).insert(db)
        try SSHKey(name: "prod", type: "ed25519", publicKey: "ssh-ed25519 AAAA prod",
                   privateKeyEncrypted: keyCiphertext, createdAt: timestamp).insert(db)
    }
    return (entryCiphertext, keyCiphertext)
}

private func storedCiphertexts(of pool: DatabasePool) async throws -> (entry: String, key: String) {
    let (entries, keys) = try await pool.read { db -> ([VaultEntry], [SSHKey]) in
        (try VaultEntry.fetchAll(db), try SSHKey.fetchAll(db))
    }
    let entry = try #require(entries.first)
    let key = try #require(keys.first)
    return (entry.valueEncrypted, key.privateKeyEncrypted)
}

@Test func masterPasswordIsStoredWithTheReEncryption() async throws {
    let scratch = try makeScratchDatabase()
    defer { discard(scratch) }
    _ = try await insertOneEntryAndKey(into: scratch.pool, under: oldKeyData)

    let store = SecureStoreService()
    let masterKeyData = try await store.configureMasterPassword(
        "correct horse", in: scratch.pool, replacing: SymmetricKey(data: oldKeyData))

    // What the lock screen does: the key comes from the password and the stored salt.
    let config = try await cryptoConfig(of: scratch.pool)
    let hash = try #require(config["master_password_hash"])
    let saltText = try #require(config["master_password_salt"])
    let salt = try #require(Data(base64Encoded: saltText))
    let isValid = try CryptoService.shared.verifyPassword("correct horse", salt: salt, hash: hash)
    #expect(isValid)
    let derived = try CryptoService.shared.deriveKey(from: "correct horse", salt: salt,
                                                     context: CryptoService.Context.vault)
    let stored = try await storedCiphertexts(of: scratch.pool)
    let password = try CryptoService.shared.decryptString(stored.entry, using: derived)
    #expect(password == "host-password")
    let pem = try decrypted(stored.key, under: masterKeyData)
    #expect(pem == "PEM")

    // A second master password is refused: it would replace the salt everything depends on.
    await #expect {
        _ = try await store.configureMasterPassword(
            "another one", in: scratch.pool, replacing: SymmetricKey(data: masterKeyData))
    } throws: { error in
        isMasterPasswordAlreadyConfigured(error)
    }
    let configAfter = try await cryptoConfig(of: scratch.pool)
    #expect(configAfter == config)
    let storedAfter = try await storedCiphertexts(of: scratch.pool)
    #expect(storedAfter.entry == stored.entry)
    #expect(storedAfter.key == stored.key)
}

// The hash and the salt used to be written after the re-encryption had been committed: a failure
// in between left every secret under a key nothing could derive again.
@Test func reEncryptionIsUndoneWhenTheConfigChangeFails() async throws {
    struct ConfigChangeFailed: Error {}

    let scratch = try makeScratchDatabase()
    defer { discard(scratch) }
    let before = try await insertOneEntryAndKey(into: scratch.pool, under: oldKeyData)

    await #expect(throws: ConfigChangeFailed.self) {
        try await SecureStoreService().reEncryptVaultEntries(
            in: scratch.pool,
            from: SymmetricKey(data: oldKeyData),
            to: SymmetricKey(data: newKeyData)
        ) { _ in
            throw ConfigChangeFailed()
        }
    }

    let after = try await storedCiphertexts(of: scratch.pool)
    #expect(after.entry == before.entry)
    #expect(after.key == before.key)
}

@Test func masterPasswordIsRemovedWithTheReEncryption() async throws {
    let scratch = try makeScratchDatabase()
    defer { discard(scratch) }
    _ = try await insertOneEntryAndKey(into: scratch.pool, under: oldKeyData)

    let store = SecureStoreService()
    let masterKeyData = try await store.configureMasterPassword(
        "correct horse", in: scratch.pool, replacing: SymmetricKey(data: oldKeyData))
    try await store.removeMasterPassword(
        in: scratch.pool, from: SymmetricKey(data: masterKeyData), to: SymmetricKey(data: oldKeyData))

    let config = try await cryptoConfig(of: scratch.pool)
    #expect(config["master_password_hash"] == nil)
    #expect(config["master_password_salt"] == nil)
    // The rest of the table (rate limiting) is not the master password's.
    #expect(config["failed_attempts"] == "0")
    let stored = try await storedCiphertexts(of: scratch.pool)
    let password = try decrypted(stored.entry, under: oldKeyData)
    #expect(password == "host-password")
    let pem = try decrypted(stored.key, under: oldKeyData)
    #expect(pem == "PEM")
}

// MARK: - Encrypted export → import

private let samplePEM = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"

/// One row in every exported table, with references in both directions (the group points at an
/// identity and a jump host, the host at the group), and every kind of secret under `keyData`.
private func insertSampleData(into pool: DatabasePool, secretsUnder keyData: Data) async throws {
    let pemCiphertext = try encrypted(samplePEM, under: keyData)
    let identityCiphertext = try encrypted("identity-password", under: keyData)
    let hostCiphertext = try encrypted("host-password", under: keyData)
    let passphraseCiphertext = try encrypted("key-passphrase", under: keyData)
    let now = TimestampFormatter.now()

    try await pool.write { db in
        try SSHKey(id: 1, name: "prod", type: "ed25519", publicKey: "ssh-ed25519 AAAA prod",
                   privateKeyEncrypted: pemCiphertext, createdAt: now).insert(db)
        try Identity(id: 1, name: "deploy", username: "deploy", authType: "password",
                     passwordEncrypted: identityCiphertext, privateKeyId: 1, createdAt: now).insert(db)
        try Snippet(id: 1, name: "uptime", command: "uptime", sortOrder: 0, createdAt: now).insert(db)

        var bastion = Host.defaultValue()
        bastion.id = 1
        bastion.label = "bastion"
        bastion.hostname = "bastion.example"
        try bastion.insert(db)

        try HostGroup(id: 1, name: "production", sortOrder: 0, createdAt: now,
                      username: "deploy", identityId: 1, jumpHostId: 1).insert(db)

        var web = Host.defaultValue()
        web.id = 2
        web.label = "web"
        web.hostname = "web.example"
        web.authType = "privateKey"
        web.privateKeyId = 1
        web.identityId = 1
        web.groupId = 1
        web.jumpHostId = 1
        web.startupSnippetId = 1
        try web.insert(db)

        try Termi.Tag(id: 1, name: "frontend", color: "#6366f1", createdAt: now).insert(db)
        try HostTag(hostId: 2, tagId: 1).insert(db)
        try KnownHost(id: nil, hostname: "web.example", port: 22, keyType: "ssh-ed25519",
                      publicKey: "AAAA", fingerprint: "SHA256:abc", addedAt: now).insert(db)
        try PortForward(id: nil, hostId: 2, type: "local", localPort: 8080,
                        remoteHost: "127.0.0.1", remotePort: 80, enabled: true, createdAt: now).insert(db)
        try ConnectionLog(id: nil, hostId: 2, hostLabel: "web", hostname: "web.example",
                          status: "connected", connectedAt: now).insert(db)
        try AppSetting(key: "terminal_font_size", value: "15").insert(db)
        try VaultEntry(id: nil, key: "host_2", valueEncrypted: hostCiphertext,
                       createdAt: now, updatedAt: now).insert(db)
        try VaultEntry(id: nil, key: "sshkey_1", valueEncrypted: passphraseCiphertext,
                       createdAt: now, updatedAt: now).insert(db)
    }
}

/// Data of its own in the database that receives an import: all of it is replaced.
private func insertStaleData(into pool: DatabasePool, secretsUnder keyData: Data) async throws {
    let ciphertext = try encrypted("stale-password", under: keyData)
    let now = TimestampFormatter.now()
    try await pool.write { db in
        var stale = Host.defaultValue()
        stale.label = "stale"
        stale.hostname = "stale.example"
        try stale.insert(db)
        try VaultEntry(id: nil, key: "host_99", valueEncrypted: ciphertext,
                       createdAt: now, updatedAt: now).insert(db)
    }
}

/// The database holds exactly what `insertSampleData` wrote, with its secrets readable under
/// `keyData`.
private func expectSampleData(in pool: DatabasePool, secretsUnder keyData: Data) async throws {
    let (hosts, groups, keys, identities, entries) = try await pool.read {
        db -> ([Termi.Host], [HostGroup], [SSHKey], [Identity], [VaultEntry]) in
        (try Host.order(Column("id").asc).fetchAll(db), try HostGroup.fetchAll(db), try SSHKey.fetchAll(db),
         try Identity.fetchAll(db), try VaultEntry.order(Column("key").asc).fetchAll(db))
    }
    let rowCounts = try await pool.read { db in
        try ["host_tags", "known_hosts", "port_forwards", "connection_logs", "snippets", "tags", "settings"].map {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? 0
        }
    }

    #expect(hosts.map(\.label) == ["bastion", "web"])
    let web = try #require(hosts.last)
    #expect(web.groupId == 1)
    #expect(web.privateKeyId == 1)
    #expect(web.identityId == 1)
    #expect(web.jumpHostId == 1)
    #expect(web.startupSnippetId == 1)
    #expect(groups.count == 1)
    let group = try #require(groups.first)
    #expect(group.identityId == 1)
    #expect(group.jumpHostId == 1)
    #expect(rowCounts == [1, 1, 1, 1, 1, 1, 1])

    #expect(keys.count == 1)
    let sshKey = try #require(keys.first)
    let pem = try decrypted(sshKey.privateKeyEncrypted, under: keyData)
    #expect(pem == samplePEM)
    #expect(identities.count == 1)
    let identityCiphertext = try #require(identities.first?.passwordEncrypted)
    let identityPassword = try decrypted(identityCiphertext, under: keyData)
    #expect(identityPassword == "identity-password")
    #expect(entries.map(\.key) == ["host_2", "sshkey_1"])
    let hostEntry = try #require(entries.first)
    let passphraseEntry = try #require(entries.last)
    let hostPassword = try decrypted(hostEntry.valueEncrypted, under: keyData)
    #expect(hostPassword == "host-password")
    let passphrase = try decrypted(passphraseEntry.valueEncrypted, under: keyData)
    #expect(passphrase == "key-passphrase")
}

// Without a master password the vault key is a random file of this Mac: the secrets of an export
// have to arrive under the key of the Mac that imports it.
@Test func encryptedExportImportsIntoAnotherVault() async throws {
    let source = try makeScratchDatabase()
    defer { discard(source) }
    let target = try makeScratchDatabase()
    defer { discard(target) }
    try await insertSampleData(into: source.pool, secretsUnder: oldKeyData)
    try await insertStaleData(into: target.pool, secretsUnder: newKeyData)
    let configBefore = try await cryptoConfig(of: target.pool)

    let sync = SyncService()
    let file = source.folder.appendingPathComponent("termi-sync.json")
    let unreadable = try await sync.exportSync(of: source.pool, vaultKey: SymmetricKey(data: oldKeyData),
                                               password: "export-password", to: file)
    #expect(unreadable == 0)
    // Only the export password protects the secrets on their way: none of them is readable in the file.
    let fileText = try String(contentsOf: file, encoding: .utf8)
    #expect(!fileText.contains("host-password"))
    #expect(!fileText.contains("OPENSSH PRIVATE KEY"))

    await #expect(throws: SyncService.SyncError.self) {
        _ = try await sync.importSync(from: file, password: "not the password")
    }
    let snapshot = try await sync.importSync(from: file, password: "export-password")
    try await sync.applySyncData(snapshot, to: target.pool, vaultKey: SymmetricKey(data: newKeyData))

    try await expectSampleData(in: target.pool, secretsUnder: newKeyData)
    let configAfter = try await cryptoConfig(of: target.pool)
    #expect(configAfter == configBefore)
}

// With a master password on both sides: the import must leave the hash and the salt of the
// receiving vault alone (it used to delete them), and its secrets must open with the key that
// the receiving vault derives from them.
@Test func encryptedImportKeepsTheMasterPasswordOfTheReceivingVault() async throws {
    let source = try makeScratchDatabase()
    defer { discard(source) }
    let target = try makeScratchDatabase()
    defer { discard(target) }
    let store = SecureStoreService()

    try await insertSampleData(into: source.pool, secretsUnder: oldKeyData)
    let sourceKeyData = try await store.configureMasterPassword(
        "source master", in: source.pool, replacing: SymmetricKey(data: oldKeyData))
    try await insertStaleData(into: target.pool, secretsUnder: newKeyData)
    let targetKeyData = try await store.configureMasterPassword(
        "target master", in: target.pool, replacing: SymmetricKey(data: newKeyData))
    let configBefore = try await cryptoConfig(of: target.pool)

    let sync = SyncService()
    let file = source.folder.appendingPathComponent("termi-sync.json")
    let unreadable = try await sync.exportSync(of: source.pool, vaultKey: SymmetricKey(data: sourceKeyData),
                                               password: "export-password", to: file)
    #expect(unreadable == 0)
    let snapshot = try await sync.importSync(from: file, password: "export-password")
    try await sync.applySyncData(snapshot, to: target.pool, vaultKey: SymmetricKey(data: targetKeyData))

    let configAfter = try await cryptoConfig(of: target.pool)
    #expect(configAfter == configBefore)
    let hash = try #require(configAfter["master_password_hash"])
    let saltText = try #require(configAfter["master_password_salt"])
    let salt = try #require(Data(base64Encoded: saltText))
    let isValid = try CryptoService.shared.verifyPassword("target master", salt: salt, hash: hash)
    #expect(isValid)
    // As after the next unlock: the key comes from the master password and the stored salt.
    let derived = try CryptoService.shared.deriveKey(from: "target master", salt: salt,
                                                     context: CryptoService.Context.vault)
    try await expectSampleData(in: target.pool, secretsUnder: derived.withUnsafeBytes { Data($0) })
}

// Exports of the previous format carry the ciphertext of the vault that made them.
@Test func oldFormatExportIsRefusedWhereItsSecretsCannotBeRead() async throws {
    let target = try makeScratchDatabase()
    defer { discard(target) }
    try await insertStaleData(into: target.pool, secretsUnder: newKeyData)
    let now = TimestampFormatter.now()

    func oldFormatSnapshot(secretsUnder keyData: Data) throws -> SyncService.SyncData {
        SyncService.SyncData(
            hosts: [], groups: [], snippets: [],
            sshKeys: [SSHKey(id: 1, name: "prod", type: "ed25519", publicKey: "ssh-ed25519 AAAA prod",
                             privateKeyEncrypted: try encrypted("PEM", under: keyData), createdAt: now)],
            identities: [], knownHosts: [], portForwards: [], tags: [], hostTags: [], settings: [],
            vaultEntries: [VaultEntry(id: nil, key: "host_1", valueEncrypted: try encrypted("host-password", under: keyData),
                                      createdAt: now, updatedAt: now)],
            cryptoConfig: [], connectionLogs: [], exportedAt: now, secretsArePlaintext: false
        )
    }

    let sync = SyncService()
    let foreign = try oldFormatSnapshot(secretsUnder: foreignKeyData)
    await #expect {
        try await sync.applySyncData(foreign, to: target.pool, vaultKey: SymmetricKey(data: newKeyData))
    } throws: { error in
        isSecretsNotTransferable(error)
    }
    // Refused before anything was replaced.
    let keysBefore = try await target.pool.read { db in try VaultEntry.fetchAll(db).map(\.key) }
    #expect(keysBefore == ["host_99"])

    // Made by this vault: its ciphertext is still good here.
    let own = try oldFormatSnapshot(secretsUnder: newKeyData)
    try await sync.applySyncData(own, to: target.pool, vaultKey: SymmetricKey(data: newKeyData))
    let entries = try await target.pool.read { db in try VaultEntry.fetchAll(db) }
    #expect(entries.map(\.key) == ["host_1"])
    let entry = try #require(entries.first)
    let password = try decrypted(entry.valueEncrypted, under: newKeyData)
    #expect(password == "host-password")
}

// MARK: - Backup / restore

private func hostLabels(inDatabaseAt path: String) throws -> [String] {
    let queue = try DatabaseQueue(path: path)
    defer { try? queue.close() }
    return try queue.read { db in try String.fetchAll(db, sql: "SELECT label FROM hosts ORDER BY label") }
}

private func insertHost(labelled label: String, into pool: DatabasePool) async throws {
    try await pool.write { db in
        var host = Host.defaultValue()
        host.label = label
        host.hostname = "\(label).example"
        try host.insert(db)
    }
}

// The pool is in WAL mode: copying the main file alone used to leave out everything that had
// not been checkpointed yet.
@Test func backupIsOneCompleteFile() async throws {
    let scratch = try makeScratchDatabase()
    defer { discard(scratch) }
    try await insertHost(labelled: "first", into: scratch.pool)

    let backup = scratch.folder.appendingPathComponent("backup.db")
    try await DatabaseManager.backup(scratch.pool, to: backup)
    #expect(!FileManager.default.fileExists(atPath: backup.path + "-wal"))
    let labels = try hostLabels(inDatabaseAt: backup.path)
    #expect(labels == ["first"])

    // Over a file that is already there (the save panel has asked): replaced by the new backup.
    try await insertHost(labelled: "second", into: scratch.pool)
    try await DatabaseManager.backup(scratch.pool, to: backup)
    let labelsAfter = try hostLabels(inDatabaseAt: backup.path)
    #expect(labelsAfter == ["first", "second"])
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.folder.path)
        .filter { $0.hasPrefix(".backup.db") }
    #expect(leftovers.isEmpty)
}

@Test func restoreRejectsWhatIsNotABackup() async throws {
    let scratch = try makeScratchDatabase()
    defer { discard(scratch) }
    try await insertHost(labelled: "current", into: scratch.pool)
    let livePath = scratch.folder.appendingPathComponent("scratch.db").path

    let junk = scratch.folder.appendingPathComponent("junk.db")
    try Data("not a database".utf8).write(to: junk)
    #expect(throws: DatabaseManager.DatabaseError.self) {
        _ = try DatabaseManager.stageBackup(from: junk, forDatabaseAt: livePath)
    }

    // An SQLite database, but not this app's.
    let other = scratch.folder.appendingPathComponent("other.db")
    let queue = try DatabaseQueue(path: other.path)
    try await queue.write { db in try db.execute(sql: "CREATE TABLE notes (body TEXT)") }
    try queue.close()
    #expect(throws: DatabaseManager.DatabaseError.self) {
        _ = try DatabaseManager.stageBackup(from: other, forDatabaseAt: livePath)
    }

    // The database in use itself: "restoring" it used to delete it first.
    #expect {
        _ = try DatabaseManager.stageBackup(from: URL(fileURLWithPath: livePath), forDatabaseAt: livePath)
    } throws: { error in
        isFileIsLiveDatabase(error)
    }

    // Nothing was brought in, and the database in use is as it was.
    let staged = try FileManager.default.contentsOfDirectory(atPath: scratch.folder.path)
        .filter { $0.contains(".restore-") }
    #expect(staged.isEmpty)
    let labels = try await scratch.pool.read { db in try String.fetchAll(db, sql: "SELECT label FROM hosts") }
    #expect(labels == ["current"])
}

@Test func restoreKeepsThePreviousDatabase() async throws {
    struct ReopenFailed: Error {}

    let live = try makeScratchDatabase()
    defer { discard(live) }
    let saved = try makeScratchDatabase()
    defer { discard(saved) }
    try await insertHost(labelled: "current", into: live.pool)
    try await insertHost(labelled: "from-backup", into: saved.pool)
    let backup = saved.folder.appendingPathComponent("backup.db")
    try await DatabaseManager.backup(saved.pool, to: backup)

    let livePath = live.folder.appendingPathComponent("scratch.db").path
    let keptPath = live.folder.appendingPathComponent("scratch.before-restore.db").path
    // As DatabaseManager.replaceDatabase does before it swaps the files.
    try live.pool.close()

    // The restored database does not open: the previous one is back, under its own name only.
    let rejected = try DatabaseManager.stageBackup(from: backup, forDatabaseAt: livePath)
    #expect(throws: ReopenFailed.self) {
        try DatabaseManager.swapDatabaseFile(at: livePath, with: rejected, keptAs: keptPath) {
            throw ReopenFailed()
        }
    }
    let labelsAfterFailure = try hostLabels(inDatabaseAt: livePath)
    #expect(labelsAfterFailure == ["current"])
    #expect(!FileManager.default.fileExists(atPath: keptPath))

    // It opens (as DatabaseManager.initialize does: a WAL pool, then the migrations): the backup
    // is in place and the previous database is kept next to it.
    let staged = try DatabaseManager.stageBackup(from: backup, forDatabaseAt: livePath)
    try DatabaseManager.swapDatabaseFile(at: livePath, with: staged, keptAs: keptPath) {
        let reopened = try DatabasePool(path: livePath)
        try Migrations.run(reopened)
        try reopened.close()
    }
    let restored = try hostLabels(inDatabaseAt: livePath)
    #expect(restored == ["from-backup"])
    let kept = try hostLabels(inDatabaseAt: keptPath)
    #expect(kept == ["current"])
    // The backup file itself is not consumed, and no staged copy is left.
    let source = try hostLabels(inDatabaseAt: backup.path)
    #expect(source == ["from-backup"])
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: live.folder.path)
        .filter { $0.contains(".restore-") }
    #expect(leftovers.isEmpty)
}

// MARK: - Key passphrase

private func publicKeyBody(_ publicKey: String) -> String {
    publicKey.split(separator: " ").prefix(2).joined(separator: " ")
}

// The passphrase used to be an argument of ssh-keygen (-N / -P), which every local user can
// read with ps. Here ssh-keygen is started through a script that writes down its arguments and
// its environment.
@Test func keyPassphraseIsNotGivenToSSHKeygenInItsArguments() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let record = folder.appendingPathComponent("invocations.txt")
    let wrapper = folder.appendingPathComponent("ssh-keygen")
    let script = """
        #!/bin/sh
        {
          printf 'ARGV:'
          for argument in "$@"; do printf ' [%s]' "$argument"; done
          printf '\\n'
          /usr/bin/env
        } >> '\(record.path)'
        exec /usr/bin/ssh-keygen "$@"

        """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)

    let generator = SSHKeyGenerator(keygenPath: wrapper.path)
    let passphrase = "open sesame \(UUID().uuidString)"
    let generated = try await generator.generateKey(type: .ed25519, comment: "test", passphrase: passphrase)
    #expect(generated.publicKey.hasPrefix("ssh-ed25519 "))
    #expect(generated.fingerprint.hasPrefix("SHA256:"))

    // The key is protected, and by this passphrase.
    let opened = try await generator.importKeyFromText(privateKeyText: generated.privateKey, passphrase: passphrase)
    #expect(publicKeyBody(opened.publicKey) == publicKeyBody(generated.publicKey))
    let notOpened = try await generator.importKeyFromText(privateKeyText: generated.privateKey,
                                                         passphrase: "not " + passphrase)
    #expect(notOpened.publicKey.isEmpty)

    let recorded = try String(contentsOf: record, encoding: .utf8)
    #expect(recorded.contains("ARGV: [-t] [ed25519]"))
    #expect(recorded.contains("ARGV: [-y]"))
    #expect(!recorded.contains(passphrase))
}

@Test func keyWithoutPassphraseIsStillGenerated() async throws {
    let generator = SSHKeyGenerator()
    let generated = try await generator.generateKey(type: .ed25519, comment: "plain")
    #expect(generated.publicKey.hasPrefix("ssh-ed25519 "))
    let opened = try await generator.importKeyFromText(privateKeyText: generated.privateKey)
    #expect(publicKeyBody(opened.publicKey) == publicKeyBody(generated.publicKey))
}

// When the askpass helper cannot answer, ssh-keygen carries on with an empty passphrase and
// reports success.
@Test func keyIsNotLeftUnprotectedWhenThePassphraseCannotBeDelivered() async throws {
    let generator = SSHKeyGenerator(askpassExecutable: "/usr/bin/false")
    await #expect {
        _ = try await generator.generateKey(type: .ed25519, comment: "test", passphrase: "open sesame")
    } throws: { error in
        isPassphraseNotSet(error)
    }
    // One line of text is all an askpass helper can hand over.
    await #expect(throws: SSHKeyGenerator.KeyGenError.self) {
        _ = try await SSHKeyGenerator().generateKey(type: .ed25519, comment: "test", passphrase: "two\nlines")
    }
}

// Import took any text for a key: a failed `ssh-keygen -y` also means "protected key, passphrase
// not given", so text that is no key at all was stored as a key of type "unknown".
@Test func onlyTextWithAPrivateKeyHeaderIsAPrivateKey() async throws {
    #expect(SSHKeyGenerator.isPrivateKeyText("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"))
    #expect(SSHKeyGenerator.isPrivateKeyText("  -----BEGIN RSA PRIVATE KEY-----\r\nAAAA\r\n-----END RSA PRIVATE KEY-----\r\n"))
    #expect(SSHKeyGenerator.isPrivateKeyText("-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA"))
    #expect(!SSHKeyGenerator.isPrivateKeyText("not a key"))
    #expect(!SSHKeyGenerator.isPrivateKeyText("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH1C comment"))
    #expect(!SSHKeyGenerator.isPrivateKeyText("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"))
    #expect(!SSHKeyGenerator.isPrivateKeyText(""))

    let generator = SSHKeyGenerator()
    let refused = await importFails(generator, text: "not a key")
    #expect(refused)
}

private func importFails(_ generator: SSHKeyGenerator, text: String) async -> Bool {
    do {
        _ = try await generator.importKeyFromText(privateKeyText: text)
        return false
    } catch {
        return true
    }
}

// A history row's id names its transcript on the Mac that recorded it (SessionLogs/<id>.log). An
// imported row must not arrive under an id this Mac has used: it would show another session's output.
@Test func importedHistoryNeverTakesAnIdThisMacHasUsed() async throws {
    let source = try makeScratchDatabase()
    defer { discard(source) }
    let target = try makeScratchDatabase()
    defer { discard(target) }
    try await insertSampleData(into: source.pool, secretsUnder: oldKeyData)
    try await insertStaleData(into: target.pool, secretsUnder: newKeyData)
    // The other Mac recorded sessions 901 and 902 (the later one first); this Mac has used ids up to 950 —
    // 901 and 902 among them, for sessions of its own.
    try await source.pool.write { db in
        try db.execute(sql: """
            INSERT INTO connection_logs (id, host_label, hostname, status, connected_at) VALUES
            (901, 'import-later', 'b.example', 'disconnected', '2026-09-02T10:00:00Z'),
            (902, 'import-earlier', 'a.example', 'disconnected', '2026-09-01T10:00:00Z')
            """)
    }
    try await target.pool.write { db in
        try db.execute(sql: """
            INSERT INTO connection_logs (id, host_label, hostname, status, connected_at)
            VALUES (950, 'local', 'local.example', 'disconnected', '2026-08-01T10:00:00Z')
            """)
    }

    let sync = SyncService()
    let file = source.folder.appendingPathComponent("termi-sync.json")
    _ = try await sync.exportSync(of: source.pool, vaultKey: SymmetricKey(data: oldKeyData),
                                  password: "export-password", to: file)
    let snapshot = try await sync.importSync(from: file, password: "export-password")
    // A transcript of this Mac numbered above its database's counter: this Mac once restored an
    // older backup, and the newer sessions' output is kept for rolling back.
    let transcripts = target.folder.appendingPathComponent("SessionLogs", isDirectory: true)
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    try Data("a newer local session\n".utf8).write(to: SessionTranscripts.url(for: 2000, in: transcripts))
    try await sync.applySyncData(snapshot, to: target.pool, vaultKey: SymmetricKey(data: newKeyData),
                                 transcriptsIn: transcripts)

    let labels = try await target.pool.read { db in
        try String.fetchAll(db, sql: "SELECT host_label FROM connection_logs WHERE host_label LIKE 'import-%' ORDER BY id")
    }
    // Fresh ids in the order of time, whatever order and ids the file had.
    #expect(labels == ["import-earlier", "import-later"])
    let ids = try await target.pool.read { db in
        try Int64.fetchAll(db, sql: "SELECT id FROM connection_logs WHERE host_label LIKE 'import-%' ORDER BY id")
    }
    let allAboveEveryUsedId: Bool = ids.allSatisfy { $0 > 950 }
    #expect(allAboveEveryUsedId)
    // …and above the transcript that is on disk: record 2000's output is not theirs.
    let allAboveEveryTranscript: Bool = ids.allSatisfy { $0 > 2000 }
    #expect(allAboveEveryTranscript)
    let localRows = try await target.pool.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM connection_logs WHERE host_label = 'local'") ?? -1
    }
    // The import replaces this Mac's history (its transcripts stay for a roll back).
    #expect(localRows == 0)
}

// MARK: - Secret files are owner-only from the first byte

private func posixMode(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let raw: Int
    if let number = attributes[.posixPermissions] as? NSNumber {
        raw = number.intValue
    } else if let mode = attributes[.posixPermissions] as? Int {
        raw = mode
    } else {
        throw CocoaError(.fileReadUnknown)
    }
    return raw & 0o777
}

private func isPrivateFileAlreadyExists(_ error: any Error) -> Bool {
    if case SSHRuntime.PrivateFileError.alreadyExists = error { return true }
    return false
}

private func isVaultKeyCorrupted(_ error: any Error) -> Bool {
    if case SecureStoreService.SecureStoreError.vaultKeyCorrupted = error { return true }
    return false
}

@Test func privateFileIsCreatedAtTheRequestedModeAndNotReplaced() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    // 0666 is what an atomic Data.write asks for; umask would turn that into 0644 without fchmod.
    let created = folder.appendingPathComponent("created")
    try SSHRuntime.createPrivateFile(Data("one".utf8), at: created, permissions: 0o666)
    #expect(try posixMode(created.path) == 0o666)
    #expect(try Data(contentsOf: created) == Data("one".utf8))

    let rejected = Result { try SSHRuntime.createPrivateFile(Data("two".utf8), at: created) }
    if case .failure(let error) = rejected {
        #expect(isPrivateFileAlreadyExists(error))
    } else {
        Issue.record("a second create replaced the file")
    }
    #expect(try Data(contentsOf: created) == Data("one".utf8))

    let target = folder.appendingPathComponent("target")
    try Data("keep".utf8).write(to: target)
    let link = folder.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let followed = Result { try SSHRuntime.createPrivateFile(Data("nope".utf8), at: link) }
    if case .success = followed { Issue.record("wrote through a symlink") }
    #expect(try Data(contentsOf: target) == Data("keep".utf8))

    let replaced = folder.appendingPathComponent("replaced")
    try Data("old".utf8).write(to: replaced)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: replaced.path)
    try SSHRuntime.replacePrivateFile(Data("new".utf8), at: replaced)
    #expect(try Data(contentsOf: replaced) == Data("new".utf8))
    #expect(try posixMode(replaced.path) == 0o600)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .filter { $0.hasPrefix(".replaced.") }
    #expect(leftovers.isEmpty)
}

@Test func vaultKeyFileIsOwnerOnlyAndNeverOverwritten() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)

    let url = folder.appendingPathComponent(".vault-key")
    let key = Data(repeating: 0xAB, count: 32)
    try SecureStoreService.persistNewVaultKey(key, to: url)
    #expect(try Data(contentsOf: url) == key)
    #expect(try posixMode(url.path) == 0o600)
    #expect(try posixMode(folder.path) == 0o700)
    let unpublished = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .filter { $0.hasPrefix(".vault-key.") }
    #expect(unpublished.isEmpty)

    let rejected = Result { try SecureStoreService.persistNewVaultKey(Data(repeating: 0xCD, count: 32), to: url) }
    if case .failure(let error) = rejected {
        #expect(isPrivateFileAlreadyExists(error))
    } else {
        Issue.record("a second launch overwrote the vault key")
    }
    #expect(try Data(contentsOf: url) == key)

    let short = Result { try SecureStoreService.persistNewVaultKey(Data(repeating: 1, count: 16), to: url) }
    if case .failure(let error) = short {
        #expect(isVaultKeyCorrupted(error))
    } else {
        Issue.record("stored a key that is not 32 bytes")
    }
}

@Test func databaseFilesAreRestrictedToTheOwner() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let database = folder.appendingPathComponent("termi.db")
    try Data("sqlite".utf8).write(to: database)
    try Data("wal".utf8).write(to: folder.appendingPathComponent("termi.db-wal"))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: database.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                          ofItemAtPath: folder.appendingPathComponent("termi.db-wal").path)
    DatabaseManager.restrictDatabaseFiles(at: database.path)
    #expect(try posixMode(database.path) == 0o600)
    #expect(try posixMode(folder.appendingPathComponent("termi.db-wal").path) == 0o600)
}
