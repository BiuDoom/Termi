import Foundation
import Testing
@testable import Termi

@Test @MainActor func staleSnippetPageCannotChangeOrDeleteImportedSnippet() async throws {
    let repo = SnippetRepository.shared
    let saved = try await repo.save(Snippet(name: "snapshot-\(UUID())", command: "new command", sortOrder: 0, createdAt: ""))
    let id = try #require(saved.id)
    let page = SnippetsViewModel(dataGeneration: UUID())
    var changed = saved
    changed.command = "old command"
    await page.save(changed)
    await page.deleteSnippet(saved)
    let stored = try await repo.fetch(id: id)
    #expect(stored?.command == saved.command)
    #expect(page.error != nil)
    // A queued repository callback carries the original task-local value across actor hops.
    await #expect(throws: DataSnapshot.StaleSnapshot.self) {
        try await DataSnapshot.$expected.withValue(UUID()) { try await repo.save(changed) }
    }
    try await repo.delete(id: id)
}

@Test @MainActor func staleIdentityPageCannotChangeOrDeleteImportedIdentity() async throws {
    let repo = IdentityRepository.shared
    let saved = try await repo.save(Identity(name: "snapshot-\(UUID())", username: "new-user", authType: "agent", createdAt: ""))
    let id = try #require(saved.id)
    let page = IdentitiesViewModel(dataGeneration: UUID())
    var changed = saved
    changed.username = "old-user"
    #expect(await page.save(changed) == false)
    await page.deleteIdentity(saved)
    let stored = try await repo.fetch(id: id)
    #expect(stored?.username == saved.username)
    #expect(page.error != nil)
    await #expect(throws: DataSnapshot.StaleSnapshot.self) {
        try await DataSnapshot.$expected.withValue(UUID()) { try await repo.save(changed) }
    }
    try await repo.delete(id: id)
}

@Test @MainActor func staleKeyPageCannotDeleteOrImportIntoReplacedVault() async throws {
    let repo = SSHKeyRepository.shared
    let saved = try await repo.save(SSHKey(name: "snapshot-\(UUID())", type: "ed25519", publicKey: "fixture",
                                           privateKeyEncrypted: "fixture", createdAt: ""))
    let id = try #require(saved.id)
    let page = KeysViewModel(dataGeneration: UUID())
    await page.deleteKey(saved)
    let stored = try await repo.fetch(id: id)
    #expect(stored?.publicKey == saved.publicKey)
    #expect(page.error != nil)
    // The stale guard also precedes key generation, file access and vault unlock prompts.
    #expect(await page.generateKey(name: "stale", type: .ed25519, passphrase: "") == false)
    #expect(await page.importKey(name: "stale", filePath: "/does-not-exist") == false)
    #expect(await page.importKeyFromText(name: "stale", privateKey: "", publicKey: "", passphrase: "") == false)
    #expect(page.error == DataSnapshot.StaleSnapshot().localizedDescription)
    await #expect(throws: DataSnapshot.StaleSnapshot.self) {
        try await DataSnapshot.$expected.withValue(UUID()) { try await repo.save(saved) }
    }
    try await repo.delete(id: id)
}

@Test @MainActor func staleKnownHostBatchCannotRemoveImportedTrustRecords() async throws {
    let repo = KnownHostRepository.shared
    let hostname = "snapshot-\(UUID()).invalid"
    let first = try await repo.trust(hostname: hostname, port: 22, publicKey: "ssh-ed25519 fixture", fingerprint: "first")
    let second = try await repo.trust(hostname: hostname, port: 22, publicKey: "ssh-rsa fixture", fingerprint: "second")
    let firstId = try #require(first.id)
    let secondId = try #require(second.id)
    let page = KnownHostsViewModel(dataGeneration: UUID())
    await page.deleteHost(first)
    await page.deleteHosts([first, second])
    let stored = try await repo.fetchAll(hostname: hostname, port: 22)
    #expect(Set(stored.compactMap(\.id)) == Set([firstId, secondId]))
    #expect(page.error != nil)
    await #expect(throws: DataSnapshot.StaleSnapshot.self) {
        try await DataSnapshot.$expected.withValue(UUID()) { try await repo.delete(id: secondId) }
    }
    try await repo.delete(id: firstId)
    try await repo.delete(id: secondId)
}
