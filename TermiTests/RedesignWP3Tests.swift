import Foundation
import Testing
@testable import Termi

/// Pure logic behind the vault pages: who signs in with what, how strong a key is, how known
/// hosts fall into machines.
@Suite("Vault pages")
struct RedesignWP3Tests {
    private func host(_ id: Int64, key: Int64? = nil, identity: Int64? = nil, group: Int64? = nil,
                      hostname: String = "10.0.0.1", port: Int = 22, lastConnectedAt: String? = nil) -> Termi.Host {
        var host = Termi.Host.defaultValue()
        host.id = id
        host.label = "h\(id)"
        host.hostname = hostname
        host.port = port
        host.privateKeyId = key
        host.identityId = identity
        host.groupId = group
        host.lastConnectedAt = lastConnectedAt
        return host
    }

    private func identity(_ id: Int64, key: Int64? = nil) -> Identity {
        Identity(id: id, name: "i\(id)", username: "root", authType: key == nil ? "password" : "privateKey",
                 passwordEncrypted: nil, privateKeyId: key, createdAt: "2026-10-03T05:00:00Z")
    }

    private func group(_ id: Int64, identity: Int64?) -> HostGroup {
        HostGroup(id: id, name: "g\(id)", sortOrder: 0, createdAt: "2026-10-03T05:00:00Z", identityId: identity)
    }

    private func known(_ id: Int64, _ hostname: String, _ port: Int, fingerprint: String, addedAt: String) -> KnownHost {
        KnownHost(id: id, hostname: hostname, port: port, keyType: "ssh-ed25519", publicKey: "ssh-ed25519 AAAA",
                  fingerprint: fingerprint, addedAt: addedAt)
    }

    // MARK: Who signs in with what

    @Test("A host takes its group's identity only when it brings neither an identity nor a key")
    func inheritedIdentity() {
        let groups = [group(1, identity: 7), group(2, identity: nil)]
        #expect(VaultUsage.identityId(of: host(1, group: 1), groups: groups) == 7)
        #expect(VaultUsage.identityId(of: host(2, key: 3, group: 1), groups: groups) == nil)
        #expect(VaultUsage.identityId(of: host(3, identity: 9, group: 1), groups: groups) == 9)
        #expect(VaultUsage.identityId(of: host(4, group: 2), groups: groups) == nil)
        #expect(VaultUsage.inheritedGroup(of: host(1, group: 1), groups: groups)?.id == 1)
        #expect(VaultUsage.inheritedGroup(of: host(3, identity: 9, group: 1), groups: groups) == nil)
    }

    @Test("An explicit system-agent host does not use its group's identity or key")
    func agentDoesNotInheritGroupIdentity() {
        let groups = [group(1, identity: 7)]
        let identities = [identity(7, key: 5)]
        var explicitAgent = host(1, group: 1)
        explicitAgent.authType = "agent"
        #expect(VaultUsage.inheritedGroup(of: explicitAgent, groups: groups) == nil)
        #expect(VaultUsage.identityId(of: explicitAgent, groups: groups) == nil)
        #expect(VaultUsage.hosts(usingIdentity: 7, hosts: [explicitAgent], groups: groups).isEmpty)
        #expect(VaultUsage.hosts(usingKey: 5, hosts: [explicitAgent], identities: identities, groups: groups).isEmpty)
    }

    @Test("A key's hosts: those that name it, and those of the identities that use it")
    func keyUsers() {
        let groups = [group(1, identity: 7)]
        let identities = [identity(7, key: 5), identity(8)]
        let hosts = [
            host(1, key: 5),                 // names the key
            host(2, key: 5, identity: 8),    // the identity wins: its key (none) counts
            host(3, identity: 7),            // through the identity
            host(4, group: 1),               // through the group's identity
            host(5, key: 6)                  // another key
        ]
        #expect(VaultUsage.hosts(directlyUsingKey: 5, hosts: hosts, groups: groups).compactMap(\.id) == [1])
        #expect(VaultUsage.hosts(usingKey: 5, hosts: hosts, identities: identities, groups: groups)
            .compactMap(\.id) == [1, 3, 4])
        #expect(VaultUsage.identities(usingKey: 5, identities: identities).compactMap(\.id) == [7])
        #expect(VaultUsage.hosts(usingIdentity: 7, hosts: hosts, groups: groups).compactMap(\.id) == [3, 4])
        #expect(VaultUsage.groups(usingIdentity: 7, groups: groups).compactMap(\.id) == [1])
        #expect(VaultUsage.hosts(usingKey: 99, hosts: hosts, identities: identities, groups: groups).isEmpty)
    }

    // MARK: Key strength

    /// An "ssh-rsa" public key whose modulus has `bits` bits.
    private func rsaPublicKey(bits: Int) -> String {
        func field(_ bytes: [UInt8]) -> [UInt8] {
            let count = UInt32(bytes.count)
            return [UInt8(count >> 24), UInt8((count >> 16) & 0xff), UInt8((count >> 8) & 0xff), UInt8(count & 0xff)] + bytes
        }
        // Top bit set, so the mpint carries a leading zero byte.
        let modulus = [UInt8(0), UInt8(0x80)] + [UInt8](repeating: 0x01, count: bits / 8 - 1)
        let blob = field(Array("ssh-rsa".utf8)) + field([0x01, 0x00, 0x01]) + field(modulus)
        return "ssh-rsa \(Data(blob).base64EncodedString()) test"
    }

    @Test("Key length is read from the type or the public key, never guessed")
    func keyBits() {
        #expect(KeyStrength.bits(type: "ed25519", publicKey: "ssh-ed25519 AAAA x") == 256)
        #expect(KeyStrength.bits(type: "ecdsa", publicKey: "ecdsa-sha2-nistp384 AAAA x") == 384)
        #expect(KeyStrength.bits(type: "ecdsa", publicKey: "sk-ecdsa-sha2-nistp256@openssh.com AAAA") == 256)
        #expect(KeyStrength.bits(type: "rsa", publicKey: rsaPublicKey(bits: 2048)) == 2048)
        #expect(KeyStrength.bits(type: "rsa", publicKey: rsaPublicKey(bits: 4096)) == 4096)
        #expect(KeyStrength.bits(type: "rsa", publicKey: "ssh-rsa not-base64!") == nil)
        #expect(KeyStrength.bits(type: "rsa", publicKey: "") == nil)
        #expect(KeyStrength.bits(type: "unknown", publicKey: "whatever") == nil)
    }

    @Test("Rating and label")
    func keyRating() {
        #expect(KeyStrength.rating(type: "ed25519", bits: 256) == .strong)
        #expect(KeyStrength.rating(type: "ecdsa", bits: 256) == .strong)
        #expect(KeyStrength.rating(type: "rsa", bits: 4096) == .strong)
        #expect(KeyStrength.rating(type: "rsa", bits: 3072) == .strong)
        #expect(KeyStrength.rating(type: "rsa", bits: 2048) == .weak)
        #expect(KeyStrength.rating(type: "rsa", bits: nil) == nil)
        #expect(KeyStrength.rating(type: "dsa", bits: 1024) == .weak)
        #expect(KeyStrength.rating(type: "unknown", bits: nil) == nil)
        #expect(KeyStrength.label(type: "ed25519", bits: 256) == "ED25519")
        #expect(KeyStrength.label(type: "rsa", bits: 2048) == "RSA 2048")
        #expect(KeyStrength.label(type: "rsa", bits: nil) == "RSA")
        #expect(KeyStrength.label(type: "ecdsa", bits: 256) == "ECDSA 256")
    }

    // MARK: Text

    @Test("A counted text splits into its number and its unit")
    func countedText() {
        #expect(VaultText.split("4 hosts").value == "4")
        #expect(VaultText.split("4 hosts").unit == "hosts")
        #expect(VaultText.split("256 位").unit == "位")
        #expect(VaultText.split("1,024 bits").value == "1,024")
        #expect(VaultText.split("12").unit == nil)
        #expect(VaultText.split("none").value == "none")
        #expect(VaultText.split("none").unit == nil)
        #expect(VaultText.monogram(for: "root") == "R")
        #expect(VaultText.monogram(for: "  ") == "?")
    }

    @Test("Keys are found by name, type or fingerprint")
    func keyFilter() {
        let keys = [
            SSHKey(id: 1, name: "deploy", type: "ed25519", publicKey: "", privateKeyEncrypted: "",
                   passphraseEncrypted: nil, fingerprint: "SHA256:abcDEF", createdAt: ""),
            SSHKey(id: 2, name: "legacy", type: "rsa", publicKey: "", privateKeyEncrypted: "",
                   passphraseEncrypted: nil, fingerprint: nil, createdAt: "")
        ]
        #expect(KeysViewModel.filter(keys, by: "").count == 2)
        #expect(KeysViewModel.filter(keys, by: " DEP ").compactMap(\.id) == [1])
        #expect(KeysViewModel.filter(keys, by: "rsa").compactMap(\.id) == [2])
        #expect(KeysViewModel.filter(keys, by: "abcdef").compactMap(\.id) == [1])
        #expect(KeysViewModel.filter(keys, by: "nothing").isEmpty)
    }

    @Test("Keys with a saved passphrase are told by the names of the vault entries, nothing is decrypted")
    func keysWithSavedPassphrase() {
        let names = ["sshkey_12", "host_3", "sshkey_7", "sshkey_", "sshkey_x", "identity_sshkey_9"]
        #expect(KeysViewModel.keyIds(inVaultEntryNames: names) == [7, 12])
        #expect(KeysViewModel.keyIds(inVaultEntryNames: []).isEmpty)
    }

    // MARK: Known hosts

    @Test("Known hosts group by host key, oldest machine and oldest address first")
    func knownHostGroups() {
        let entries = [
            known(3, "b", 22, fingerprint: "SHA256:two", addedAt: "2026-10-03T11:00:00Z"),
            known(2, "a", 2222, fingerprint: "SHA256:two", addedAt: "2026-10-03T06:00:00Z"),
            known(1, "c", 22, fingerprint: "SHA256:one", addedAt: "2026-10-03T05:00:00Z"),
            known(4, "d", 22, fingerprint: "SHA256:two", addedAt: "2026-10-03T11:00:00Z")
        ]
        let groups = KnownHostsViewModel.groups(of: entries)
        #expect(groups.map(\.fingerprint) == ["SHA256:one", "SHA256:two"])
        #expect(groups[1].entries.compactMap(\.id) == [2, 3, 4])
        #expect(KnownHostsViewModel.groups(of: []).isEmpty)
    }

    @Test("An entry without a saved host at its address and port is an orphan")
    func knownHostOrphans() {
        let saved = [host(1, hostname: "Example.com", port: 22), host(2, hostname: "example.com", port: 22),
                     host(3, hostname: "10.0.0.9", port: 2222)]
        let entries = [
            known(1, "example.com", 22, fingerprint: "SHA256:a", addedAt: ""),
            known(2, "example.com", 2222, fingerprint: "SHA256:a", addedAt: ""),
            known(3, "10.0.0.9", 2222, fingerprint: "SHA256:b", addedAt: ""),
            known(4, "localhost", 22, fingerprint: "SHA256:b", addedAt: "")
        ]
        #expect(KnownHostsViewModel.savedHosts(for: entries[0], in: saved).compactMap(\.id) == [1, 2])
        #expect(KnownHostsViewModel.orphans(entries, hosts: saved).compactMap(\.id) == [2, 4])
        // No saved hosts at all: everything is an orphan — the page only offers the removal
        // once the hosts were read.
        #expect(KnownHostsViewModel.orphans(entries, hosts: []).count == 4)
    }

    @Test("Short forms of a key type and a fingerprint")
    func knownHostText() {
        #expect(KnownHostsViewModel.shortKeyType("ssh-ed25519") == "ED25519")
        #expect(KnownHostsViewModel.shortKeyType("ecdsa-sha2-nistp256") == "ECDSA")
        #expect(KnownHostsViewModel.shortKeyType("ssh-rsa") == "RSA")
        #expect(KnownHostsViewModel.shortFingerprint("SHA256:p7/ishVgKY45MXiNPUn8IJ") == "p7/ishVgKY45…")
        #expect(KnownHostsViewModel.shortFingerprint("SHA256:short") == "short")
        #expect(KnownHostsViewModel.shortFingerprint("plain", length: 3) == "pla…")
    }

    // MARK: Identities

    @Test("Last use and active days of an identity's hosts")
    func identityUse() throws {
        let hosts = [host(1, lastConnectedAt: "2026-10-03T05:00:00Z"), host(2, lastConnectedAt: "2026-10-04T05:00:00Z"),
                     host(3)]
        #expect(IdentitiesViewModel.lastUsed(among: hosts)?.host.id == 2)
        #expect(IdentitiesViewModel.lastUsed(among: [host(3)]) == nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(TimestampFormatter.date(from: "2026-10-05T12:00:00Z"))
        let logs = [
            ConnectionLog(id: 1, hostId: 1, hostLabel: "h1", hostname: "x", status: "connected", errorMessage: nil,
                          durationMs: nil, connectedAt: "2026-10-05T08:00:00Z", disconnectedAt: nil),
            ConnectionLog(id: 2, hostId: 9, hostLabel: "h9", hostname: "x", status: "connected", errorMessage: nil,
                          durationMs: nil, connectedAt: "2026-10-04T08:00:00Z", disconnectedAt: nil)
        ]
        let days = IdentitiesViewModel.activeDays(of: [hosts[0]], in: logs, count: 3, now: now, calendar: calendar)
        #expect(days == [false, false, true])
    }
}
