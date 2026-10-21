import Foundation
import GRDB
import Testing
@testable import Termi

@Test func staleSnapshotIsRejectedOnDatabaseQueue() async throws {
    let database = try DatabaseQueue()
    try await database.write { db in try db.execute(sql: "CREATE TABLE marker (value TEXT)") }
    let staleGeneration = UUID()
    await #expect(throws: DataSnapshot.StaleSnapshot.self) {
        try await DataSnapshot.$expected.withValue(staleGeneration) {
            try await DataSnapshot.write(database) { db in
                try db.execute(sql: "INSERT INTO marker VALUES ('old operation')")
            }
        }
    }
    let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM marker") }
    #expect(count == 0)
}

@Test @MainActor func staleHostDraftCannotOverwriteImportedHost() async throws {
    var host = Host.defaultValue()
    host.hostname = "snapshot-new-\(UUID()).invalid"
    let saved = try await HostRepository.shared.save(host)
    let id = try #require(saved.id)
    var old = saved
    old.hostname = "snapshot-old.invalid"
    let draft = HostDraft(host: old, portForwards: [], tags: [], passwordChange: .set("unused-test-password"), dataGeneration: UUID())
    let result = await HostsViewModel.store(draft)
    #expect(result.failure != nil)
    let reloaded = try await HostRepository.shared.fetch(id: id)
    #expect(reloaded?.hostname == saved.hostname)
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: id)
}

@Test @MainActor func replacingDataInvalidatesBothWindowsAndTheirOldDeleteActions() async throws {
    var host = Host.defaultValue()
    host.hostname = "snapshot-window-\(UUID()).invalid"
    let saved = try await HostRepository.shared.save(host)
    let id = try #require(saved.id)
    let first = AppViewModel()
    let second = AppViewModel()
    let oldPage = first.hostsPage
    for model in [first, second] {
        model.hostsPage.hosts = [saved]
        model.hostsPage.editingHost = saved
        model.hostToEdit = saved
        model.showQuickConnect = true
        model.prepareForDataReplacement()
        #expect(model.hostsPage.hosts.isEmpty)
        #expect(model.hostsPage.editingHost == nil)
        #expect(model.hostToEdit == nil)
        #expect(!model.showQuickConnect)
        #expect(model.isReplacingData)
    }
    await oldPage.deleteHost(saved)
    let untouched = try await HostRepository.shared.fetch(id: id)
    #expect(untouched != nil)
    await first.finishDataReplacement()
    await second.finishDataReplacement()
    #expect(first.hostsPage !== oldPage)
    #expect(first.hostsPage.hosts.contains { $0.id == id })
    #expect(second.hostsPage.hosts.contains { $0.id == id })
    #expect(!first.isReplacingData)
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: id)
}

@Test @MainActor func staleForwardPageCannotSaveDeleteOrToggleImportedRule() async throws {
    var host = Host.defaultValue()
    host.hostname = "snapshot-forward-\(UUID()).invalid"
    let savedHost = try await HostRepository.shared.save(host)
    let hostId = try #require(savedHost.id)
    let original = try await PortForwardRepository.shared.save(PortForward(
        hostId: hostId, type: "local", localPort: 18090, remoteHost: "127.0.0.1",
        remotePort: 80, enabled: true, createdAt: ""))
    let id = try #require(original.id)
    let stale = PortForwardViewModel(dataGeneration: UUID())
    stale.portForwards = [original]
    var changed = original
    changed.localPort = 18091
    await stale.save(changed)
    await stale.toggleEnabled(id: id, enabled: false)
    await stale.delete(id: id)
    let remaining = try await PortForwardRepository.shared.fetchForHost(hostId)
    #expect(remaining.count == 1)
    #expect(remaining.first?.localPort == original.localPort)
    #expect(remaining.first?.enabled == true)
    #expect(stale.error != nil)
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
}

@Test @MainActor func staleHistoryPageCannotDeleteImportedHistory() async throws {
    var host = Host.defaultValue()
    host.hostname = "snapshot-history-\(UUID()).invalid"
    let log = try await ConnectionLogRepository.shared.log(host: host, status: "connected")
    let id = try #require(log.id)
    let page = ConnectionLogsViewModel(dataGeneration: UUID())
    await page.deleteLog(log)
    await page.clearAll()
    let records = try await ConnectionLogRepository.shared.page(matching: ConnectionLogQuery(text: host.hostname), limit: 20)
    #expect(records.records.contains { $0.id == id })
    #expect(page.error != nil)
    try await ConnectionLogRepository.shared.delete(id: id)
}
