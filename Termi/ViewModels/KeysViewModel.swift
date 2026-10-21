import SwiftUI
import GRDB
import os.log

/// ViewModel for SSH key management
@Observable
@MainActor
final class KeysViewModel {
    private let dataGeneration: UUID

    init(dataGeneration: UUID = DataSnapshot.current) {
        self.dataGeneration = dataGeneration
    }

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "KeysVM")
    private let keyRepo = SSHKeyRepository.shared
    private let identityRepo = IdentityRepository.shared
    private let keyGen = SSHKeyGenerator.shared
    private let secureStore = SecureStoreService.shared

    var keys: [SSHKey] = []
    /// For "used by": an identity that signs in with a key lends it to its hosts.
    private(set) var identities: [Identity] = []
    /// Keys whose passphrase is saved in the vault.
    private(set) var keysWithPassphrase: Set<Int64> = []
    var isLoading = false
    /// The first read has finished: until then the page shows nothing rather than "no keys".
    private(set) var hasLoaded = false
    var error: String?
    var searchText = ""

    /// The key that was just generated or imported: the page selects it, so that what the
    /// user made is what the detail shows.
    var addedKeyId: Int64?

    // Generation state
    var showingGenerate = false
    var showingImport = false
    var isGenerating = false

    // Delete confirmation
    var showingDeleteConfirm = false
    var keyToDelete: SSHKey?

    var filteredKeys: [SSHKey] {
        Self.filter(keys, by: searchText)
    }

    /// Name, type or fingerprint contains the query.
    nonisolated static func filter(_ keys: [SSHKey], by searchText: String) -> [SSHKey] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return keys }
        return keys.filter {
            $0.name.lowercased().contains(query)
                || $0.type.lowercased().contains(query)
                || ($0.fingerprint ?? "").lowercased().contains(query)
        }
    }

    func loadKeys() async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            let fetched = try await keyRepo.fetchAll()
            // Not worth failing the page for: without them "used by" lists only the direct hosts.
            identities = (try? await identityRepo.fetchAll()) ?? identities
            keysWithPassphrase = await Self.idsOfKeysWithSavedPassphrase()
            // The first fill just appears; rows added or removed later animate.
            if hasLoaded { withAnimation(DS.Motion.standard) { keys = fetched } } else { keys = fetched }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Only whether the vault holds an entry for a key ("sshkey_<id>", written when a
    /// passphrase is saved): no secret is decrypted to draw a chip.
    private static func idsOfKeysWithSavedPassphrase() async -> Set<Int64> {
        do {
            let reader = try await DatabaseManager.shared.reader
            let names = try await reader.read { db in
                try VaultEntry.select(Column("key"), as: String.self).fetchAll(db)
            }
            return keyIds(inVaultEntryNames: names)
        } catch {
            return []
        }
    }

    /// "sshkey_12" → 12; the vault's other entries (host passwords, …) are not keys.
    nonisolated static func keyIds(inVaultEntryNames names: [String]) -> Set<Int64> {
        let prefix = "sshkey_"
        return Set(names.filter { $0.hasPrefix(prefix) }.compactMap { Int64($0.dropFirst(prefix.count)) })
    }

    @discardableResult
    func generateKey(name: String, type: SSHKeyGenerator.KeyType, passphrase: String) async -> Bool {
        return await DataSnapshot.$expected.withValue(dataGeneration) { await generateCurrentKey(name: name, type: type, passphrase: passphrase) }
    }

    private func generateCurrentKey(name: String, type: SSHKeyGenerator.KeyType, passphrase: String) async -> Bool {
        isGenerating = true
        defer { isGenerating = false }

        do {
            try DataSnapshot.check(dataGeneration)
            try await secureStore.ensureUnlocked()
            let generated = try await keyGen.generateKey(type: type, comment: name, passphrase: passphrase)
            let encryptedPrivateKey = try await secureStore.encryptStoredValue(generated.privateKey)

            var key = SSHKey(
                name: name,
                type: generated.type,
                publicKey: generated.publicKey,
                privateKeyEncrypted: encryptedPrivateKey,
                fingerprint: generated.fingerprint,
                createdAt: ""
            )
            key = try await keyRepo.save(key)

            if !passphrase.isEmpty, let keyId = key.id {
                try await secureStore.setKeyPassphrase(passphrase, keyId: keyId)
            }

            await loadKeys()
            addedKeyId = key.id
            notifyDataChanged()
            logger.info("Generated key: \(name)")
            return true
        } catch {
            self.error = error.localizedDescription
            logger.error("Key generation failed: \(error)")
            return false
        }
    }

    @discardableResult
    func importKey(name: String, filePath: String) async -> Bool {
        return await DataSnapshot.$expected.withValue(dataGeneration) { await importCurrentKey(name: name, filePath: filePath) }
    }

    private func importCurrentKey(name: String, filePath: String) async -> Bool {
        do {
            try DataSnapshot.check(dataGeneration)
            try await secureStore.ensureUnlocked()
            let imported = try await keyGen.importKey(from: filePath)
            let encryptedPrivateKey = try await secureStore.encryptStoredValue(imported.privateKey)

            let key = SSHKey(
                name: name,
                type: imported.type,
                publicKey: imported.publicKey,
                privateKeyEncrypted: encryptedPrivateKey,
                fingerprint: imported.fingerprint,
                createdAt: ""
            )
            let saved = try await keyRepo.save(key)
            await loadKeys()
            addedKeyId = saved.id
            notifyDataChanged()
            logger.info("Imported key: \(name)")
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func importKeyFromText(name: String, privateKey: String, publicKey: String, passphrase: String) async -> Bool {
        return await DataSnapshot.$expected.withValue(dataGeneration) { await importCurrentKeyFromText(name: name, privateKey: privateKey, publicKey: publicKey, passphrase: passphrase) }
    }

    private func importCurrentKeyFromText(name: String, privateKey: String, publicKey: String, passphrase: String) async -> Bool {
        do {
            try DataSnapshot.check(dataGeneration)
            try await secureStore.ensureUnlocked()
            let imported = try await keyGen.importKeyFromText(
                privateKeyText: privateKey,
                publicKeyText: publicKey,
                passphrase: passphrase
            )
            let encryptedPrivateKey = try await secureStore.encryptStoredValue(imported.privateKey)

            var key = SSHKey(
                name: name,
                type: imported.type,
                publicKey: imported.publicKey,
                privateKeyEncrypted: encryptedPrivateKey,
                fingerprint: imported.fingerprint,
                createdAt: ""
            )
            key = try await keyRepo.save(key)

            if !passphrase.isEmpty, let keyId = key.id {
                try await secureStore.setKeyPassphrase(passphrase, keyId: keyId)
            }

            await loadKeys()
            addedKeyId = key.id
            notifyDataChanged()
            logger.info("Imported key from text: \(name)")
            return true
        } catch {
            self.error = error.localizedDescription
            logger.error("Key import from text failed: \(error)")
            return false
        }
    }

    func deleteKey(_ key: SSHKey) async {
        await DataSnapshot.$expected.withValue(dataGeneration) { await deleteCurrentKey(key) }
    }

    private func deleteCurrentKey(_ key: SSHKey) async {
        guard let id = key.id else { return }
        do {
            try DataSnapshot.check(dataGeneration)
            try await keyRepo.delete(id: id)
            try? await secureStore.deletePassword(forAccount: "sshkey_\(id)")
            await loadKeys()
            notifyDataChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func copyPublicKey(_ key: SSHKey) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKey, forType: .string)
    }

    /// The sidebar counts follow.
    private func notifyDataChanged() {
        NotificationCenter.default.post(name: .dsDataChanged, object: nil)
    }
}

// MARK: - Who signs in with what

/// Which hosts sign in with an identity or a key. The same rule as `SSHService`: a host's own
/// identity, else its group's — unless the host brings a key of its own; with an identity the
/// key is the identity's, otherwise the host's. (`SSHService` also skips the group's identity
/// for a host with a password saved under it; that is in the vault and not looked at here.)
enum VaultUsage {
    /// The group a host takes its identity from, if it does.
    static func inheritedGroup(of host: Host, groups: [HostGroup]) -> HostGroup? {
        guard host.authType != "agent", host.identityId == nil, host.privateKeyId == nil, let groupId = host.groupId,
              let group = groups.first(where: { $0.id == groupId }), group.identityId != nil else { return nil }
        return group
    }

    static func identityId(of host: Host, groups: [HostGroup]) -> Int64? {
        host.identityId ?? inheritedGroup(of: host, groups: groups)?.identityId
    }

    static func hosts(usingIdentity id: Int64, hosts: [Host], groups: [HostGroup]) -> [Host] {
        hosts.filter { identityId(of: $0, groups: groups) == id }
    }

    /// Groups whose default identity it is.
    static func groups(usingIdentity id: Int64, groups: [HostGroup]) -> [HostGroup] {
        groups.filter { $0.identityId == id }
    }

    /// Hosts that name the key themselves (and are not signed in by an identity).
    static func hosts(directlyUsingKey id: Int64, hosts: [Host], groups: [HostGroup]) -> [Host] {
        hosts.filter { identityId(of: $0, groups: groups) == nil && $0.privateKeyId == id }
    }

    static func identities(usingKey id: Int64, identities: [Identity]) -> [Identity] {
        identities.filter { $0.privateKeyId == id }
    }

    /// Every host the key signs in: directly, or through an identity.
    static func hosts(usingKey id: Int64, hosts: [Host], identities: [Identity], groups: [HostGroup]) -> [Host] {
        let lending = Set(self.identities(usingKey: id, identities: identities).compactMap(\.id))
        return hosts.filter { host in
            if let identity = identityId(of: host, groups: groups) { return lending.contains(identity) }
            return host.privateKeyId == id
        }
    }
}

// MARK: - Key strength

/// How long a key is and whether that is enough today, read from its public half.
enum KeyStrength: Equatable, Sendable {
    case strong, weak

    /// The key length in bits; nil when it cannot be told (never a guess).
    static func bits(type: String, publicKey: String) -> Int? {
        let fields = publicKey.split(separator: " ")
        let algorithm = fields.first.map(String.init) ?? ""
        switch type.lowercased() {
        case "ed25519":
            return 256
        case "ecdsa":
            // "ecdsa-sha2-nistp256", "sk-ecdsa-sha2-nistp256@openssh.com"
            guard let curve = algorithm.range(of: "nistp") else { return nil }
            return Int(algorithm[curve.upperBound...].prefix { $0.isNumber })
        case "rsa":
            // string "ssh-rsa", mpint e, mpint n
            return mpintBits(at: 2, in: fields)
        case "dsa":
            // string "ssh-dss", mpint p, …
            return mpintBits(at: 1, in: fields)
        default:
            return nil
        }
    }

    /// ED25519 / ECDSA / RSA from 3072 bits are strong; shorter RSA and DSA are weak; an RSA
    /// key of unknown length is not rated.
    static func rating(type: String, bits: Int?) -> KeyStrength? {
        switch type.lowercased() {
        case "ed25519", "ecdsa": return .strong
        case "dsa": return .weak
        case "rsa": return bits.map { $0 >= 3072 ? .strong : .weak }
        default: return nil
        }
    }

    /// "ED25519", "RSA 4096", "ECDSA 256".
    static func label(type: String, bits: Int?) -> String {
        let name = type.uppercased()
        guard let bits, type.lowercased() != "ed25519" else { return name }
        return "\(name) \(bits)"
    }

    /// Bit length of the `index`-th field of the key blob (SSH wire format: each field is a
    /// 4-byte big-endian length and that many bytes).
    private static func mpintBits(at index: Int, in fields: [Substring]) -> Int? {
        guard fields.count > 1, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        let bytes = [UInt8](blob)
        var offset = 0
        var current = 0
        while offset + 4 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard length >= 0, offset + length <= bytes.count else { return nil }
            if current == index {
                // An mpint is signed: a leading zero byte keeps a number with its top bit set positive.
                let value = bytes[offset..<offset + length].drop { $0 == 0 }
                guard let first = value.first else { return nil }
                return value.count * 8 - first.leadingZeroBitCount
            }
            offset += length
            current += 1
        }
        return nil
    }
}

// MARK: - Numbers with their unit

enum VaultText {
    /// The text with a zero-width space between its characters: a key or a fingerprint has no
    /// word boundaries worth keeping, so it should fill its lines instead of breaking after
    /// "ssh-" or a "/". For display only — what is copied is the original.
    static func breakable(_ text: String) -> String {
        text.map(String.init).joined(separator: "\u{200B}")
    }

    /// The letter on an identity's tile: the first of its user name.
    static func monogram(for username: String) -> String {
        DSIconTile.monogram(for: username, letters: 1)
    }

    /// "4 hosts" / "4 台" → the number and its unit, for a value set in two sizes. A text that
    /// does not start with the number comes back whole.
    static func split(_ counted: String) -> (value: String, unit: String?) {
        let digits = counted.prefix { $0.isNumber || $0 == "," || $0 == "." }
        guard !digits.isEmpty else { return (counted, nil) }
        let rest = counted[digits.endIndex...].trimmingCharacters(in: .whitespaces)
        return (String(digits), rest.isEmpty ? nil : rest)
    }
}
