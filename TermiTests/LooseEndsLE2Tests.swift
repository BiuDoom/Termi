import Testing
import Foundation
import GRDB
@testable import Termi

// Loose ends of the click acceptance, hosts / vault / data pages: numbers of the history page
// counted from every record, the address a record copies, a Docker failure without a reason,
// what a gauge card says to assistive technologies, the selection after a host is added.

private func le2MakePool() throws -> (pool: DatabasePool, folder: URL) {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: folder.appendingPathComponent("scratch.db").path)
    try Migrations.run(pool)
    return (pool, folder)
}

/// Close before deleting: SQLite reports files that are unlinked while still open.
private func le2Discard(_ scratch: (pool: DatabasePool, folder: URL)) {
    try? scratch.pool.close()
    try? FileManager.default.removeItem(at: scratch.folder)
}

private func le2Record(_ label: String, hostname: String = "10.0.0.5", status: String = "disconnected",
                       durationMs: Int? = nil, at connectedAt: String) -> ConnectionLog {
    ConnectionLog(id: nil, hostId: nil, hostLabel: label, hostname: hostname, status: status,
                  errorMessage: nil, durationMs: durationMs, connectedAt: connectedAt, disconnectedAt: nil)
}

private func le2UTC() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
}

@Test func le2HistoryNumbersCountEveryRecordNotTheListedPage() async throws {
    let scratch = try le2MakePool()
    defer { le2Discard(scratch) }
    let calendar = le2UTC()
    let now = try #require(TimestampFormatter.date(from: "2026-10-05T12:00:00Z"))

    // 540 records: 300 today (every 10th failed), 200 yesterday, 40 long ago.
    try await scratch.pool.write { db in
        for index in 0..<300 {
            let stamp = String(format: "2026-10-05T%02d:%02d:%02dZ", index / 60, index % 60, 0)
            let log = le2Record(index % 3 == 0 ? "db" : "web", status: index % 10 == 0 ? "failed" : "disconnected",
                                durationMs: index % 10 == 0 ? nil : 2000, at: stamp)
            try log.insert(db)
        }
        for index in 0..<200 {
            let stamp = String(format: "2026-10-04T%02d:%02d:%02dZ", 10 + index / 60, index % 60, 0)
            let log = le2Record("web", durationMs: 4000, at: stamp)
            try log.insert(db)
        }
        for index in 0..<40 {
            let stamp = String(format: "2026-07-01T08:%02d:00Z", index)
            let log = le2Record("old", status: "error", at: stamp)
            try log.insert(db)
        }
    }

    let totals = try await scratch.pool.read { db in
        try ConnectionLogRepository.totals(db, now: now, calendar: calendar)
    }
    #expect(totals.total == 540)
    #expect(totals.failed == 70)
    // 270 sessions of 2 s and 200 of 4 s.
    #expect(totals.averageDurationMs == 2851)
    #expect(totals.longestDurationMs == 4000)
    #expect(totals.days.count == 30)
    #expect(totals.days.last?.succeeded == 270)
    #expect(totals.days.last?.failed == 30)
    let yesterday = totals.days[28]
    #expect(yesterday.succeeded == 200)
    #expect(yesterday.failed == 0)
    #expect(totals.top?.name == "web")
    #expect(totals.top?.count == 400)
    #expect(totals.recentDurationsMs.count == 30)
    #expect(totals.recentDurationsMs.last == 2000)

    let summary = HistorySummary(totals)
    #expect(summary.stats.total == 540)
    #expect(summary.stats.totalText == "540")
    #expect(summary.today == 300)
    #expect(summary.stats.failed == 70)
    #expect(summary.recentCountIfPartial == 500)
    #expect(summary.hasRecentFailures)
    let share = try #require(summary.top?.share)
    let shareIsRight: Bool = abs(share - 74.07) < 0.01
    #expect(shareIsRight)

    // The same numbers as the in-memory count over every record.
    let all = try await scratch.pool.read { db in try ConnectionLog.fetchAll(db) }
    let counted = HistorySummary(all, now: now, calendar: calendar)
    #expect(counted.stats == summary.stats)
    #expect(counted.days == summary.days)
    #expect(counted.today == summary.today)
    #expect(counted.longestDurationMs == summary.longestDurationMs)
    #expect(counted.top?.name == summary.top?.name)
    #expect(counted.top?.count == summary.top?.count)
}

@Test func le2HistoryNumbersOfAnEmptyDatabase() async throws {
    let scratch = try le2MakePool()
    defer { le2Discard(scratch) }
    let totals = try await scratch.pool.read { db in try ConnectionLogRepository.totals(db) }
    #expect(totals.total == 0)
    #expect(totals.averageDurationMs == nil)
    #expect(totals.top == nil)
    let summary = HistorySummary(totals)
    #expect(summary.stats.totalText == "—")
    #expect(summary.top == nil)
    #expect(summary.today == 0)
}

@Test func le2MostConnectedCountsASavedHostByItsIdAndNamesItAsItWasLast() async throws {
    let scratch = try le2MakePool()
    defer { le2Discard(scratch) }
    try await scratch.pool.write { db in
        try db.execute(sql: """
            INSERT INTO hosts (label, hostname, port, username) VALUES ('renamed', '10.0.0.9', 22, 'root')
            """)
        let hostId = db.lastInsertedRowID
        for (index, label) in ["first-name", "first-name", "renamed"].enumerated() {
            let log = ConnectionLog(id: nil, hostId: hostId, hostLabel: label, hostname: "10.0.0.9", status: "disconnected",
                                    errorMessage: nil, durationMs: nil, connectedAt: "2026-10-0\(index + 1)T09:00:00Z",
                                    disconnectedAt: nil)
            try log.insert(db)
        }
        for index in 0..<2 {
            let log = le2Record("adhoc", at: "2026-10-0\(index + 1)T10:00:00Z")
            try log.insert(db)
        }
    }
    let totals = try await scratch.pool.read { db in try ConnectionLogRepository.totals(db) }
    #expect(totals.top?.count == 3)
    #expect(totals.top?.name == "renamed")
    #expect(totals.top?.hostId != nil)
}

@Test func le2CopiedAddressCarriesAPortThatIsNot22() {
    let saved = le2Record("web", hostname: "10.0.0.5", at: "2026-10-05T09:00:00Z")
    #expect(saved.addressToCopy(port: 22) == "10.0.0.5")
    #expect(saved.addressToCopy(port: 2222) == "10.0.0.5:2222")
    // The saved host is gone and the name says nothing about a port.
    #expect(saved.addressToCopy(port: nil) == "10.0.0.5")

    let adhoc = le2Record("root@127.0.0.1:2223", hostname: "127.0.0.1", at: "2026-10-05T09:00:00Z")
    #expect(adhoc.addressToCopy(port: nil) == "127.0.0.1:2223")
    let plain = le2Record("root@127.0.0.1", hostname: "127.0.0.1", at: "2026-10-05T09:00:00Z")
    #expect(plain.addressToCopy(port: nil) == "127.0.0.1")

    let v6 = le2Record("root@[::1]:2223", hostname: "::1", at: "2026-10-05T09:00:00Z")
    #expect(v6.addressToCopy(port: nil) == "[::1]:2223")
    #expect(v6.addressToCopy(port: 22) == "::1")
}

@Test func le2CopiedAddressIgnoresThePortOfAHostThatMovedToAnotherAddress() {
    let record = le2Record("web", hostname: "10.0.0.5", at: "2026-10-05T09:00:00Z")
    var host = Termi.Host.defaultValue()
    host.hostname = "10.0.0.5"
    host.port = 2222
    #expect(record.addressToCopy(savedHost: host) == "10.0.0.5:2222")
    // The host was edited to another address and port: the record was never at "10.0.0.5:2200".
    host.hostname = "10.0.0.9"
    host.port = 2200
    #expect(record.addressToCopy(savedHost: host) == "10.0.0.5")
    #expect(record.addressToCopy(savedHost: nil) == "10.0.0.5")
}

@Test func le2DockerFailureWithoutAReasonHasNoDanglingColon() {
    let silent = DockerViewModel.message(for: DockerService.DockerError.commandFailed("  \n"))
    #expect(!silent.hasSuffix(":"))
    #expect(!silent.hasSuffix("："))
    #expect(!silent.trimmingCharacters(in: .whitespaces).hasSuffix(":"))
    #expect(silent == String(localized: "The Docker command failed and the host gave no reason."))

    let told = DockerViewModel.message(for: DockerService.DockerError.commandFailed("No such container: x"))
    #expect(told.contains("No such container: x"))
    let other = DockerViewModel.message(for: DockerService.DockerError.invalidContainerId("a b"))
    #expect(other.contains("a b"))
}

@Test func le2GaugeCardReadsItsPercentageAndItsSubLine() {
    #expect(MonitorFormat.gaugeReading(percent: 23.4, detail: "9 processes", level: nil) == "23%, 9 processes")
    #expect(MonitorFormat.gaugeReading(percent: 91, detail: "7.2 / 8 GB", level: "Critical") == "91%, 7.2 / 8 GB, Critical")
    // No sub-line (the host did not say): the percentage alone, never a dash.
    #expect(MonitorFormat.gaugeReading(percent: 5, detail: "—", level: nil) == "5%")
    #expect(MonitorFormat.gaugeReading(percent: nil, detail: "—", level: nil) == String(localized: "No data"))
}

private func le2Host(_ id: Int64, _ label: String) -> Termi.Host {
    var host = Termi.Host.defaultValue()
    host.id = id
    host.label = label
    host.hostname = "10.0.0.\(id)"
    return host
}

@MainActor
@Test func le2AHostThatWasJustAddedBecomesTheSelection() {
    let model = HostsViewModel()
    model.hosts = [le2Host(1, "a"), le2Host(2, "b")]
    model.pick(1)
    let asked = model.revealCount

    // The list was read again with the new host in it.
    model.hosts = [le2Host(1, "a"), le2Host(2, "b"), le2Host(3, "click-new")]
    #expect(model.selectedHostId == 1)
    model.reveal(3)
    #expect(model.selectedHostId == 3)
    // Selected by the page, not picked by hand: ⌫ outside the list does not ask about it.
    #expect(model.pickedHostId == nil)
    let target = HostsViewModel.deleteTarget(selected: model.selectedHostId, picked: model.pickedHostId, listHasFocus: false)
    #expect(target == nil)
    #expect(model.revealedHostId == 3)
    let askedOnce: Bool = model.revealCount == asked + 1
    #expect(askedOnce)

    // A host the list does not have is not selected (the save failed before its row).
    model.reveal(99)
    #expect(model.selectedHostId == 3)
}

@Test func le2ADockerCommandRunWithMergedOutputSaysWhyItFailed() {
    // "docker logs … 2>&1": the reason is on stdout, stderr is empty.
    let merged = DockerService.failureReason(stdout: "Error response from daemon: No such container: web\n", stderr: "")
    #expect(merged == "Error response from daemon: No such container: web")
    // Anything else: stderr is the reason, stdout is the command's output.
    let split = DockerService.failureReason(stdout: "partial output", stderr: " permission denied \n")
    #expect(split == "permission denied")
    // Nothing at all stays empty: the page then says that the host gave no reason.
    let silent = DockerService.failureReason(stdout: " \n", stderr: "")
    #expect(silent.isEmpty)
}
