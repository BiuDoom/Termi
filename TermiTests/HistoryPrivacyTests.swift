import Testing
import Foundation
import GRDB
@testable import Termi

// History: deleting it deletes what it recorded (the saved session output of exactly the
// records that go, and nothing else), and a search asks every record, not the listed page.

// MARK: - Scratch database and transcripts folder

private struct HistScratch {
    let pool: DatabasePool
    let folder: URL
    /// Its own transcripts folder: the tests do not share the test profile's.
    let transcripts: URL
}

private func histMakeScratch() throws -> HistScratch {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-Tests-\(UUID().uuidString)", isDirectory: true)
    let transcripts = folder.appendingPathComponent("SessionLogs", isDirectory: true)
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: folder.appendingPathComponent("scratch.db").path)
    try Migrations.run(pool)
    return HistScratch(pool: pool, folder: folder, transcripts: transcripts)
}

/// Close before deleting: SQLite reports files that are unlinked while still open.
private func histDiscard(_ scratch: HistScratch) {
    try? scratch.pool.close()
    try? FileManager.default.removeItem(at: scratch.folder)
}

/// Inserts a record and returns its id.
private func histInsert(_ db: Database, label: String, hostname: String = "10.0.0.5", hostId: Int64? = nil,
                        status: String = "disconnected", error: String? = nil,
                        at connectedAt: String = "2026-10-05T12:00:00Z") throws -> Int64 {
    let log = ConnectionLog(id: nil, hostId: hostId, hostLabel: label, hostname: hostname, status: status,
                            errorMessage: error, durationMs: nil, connectedAt: connectedAt, disconnectedAt: nil)
    return try #require(try log.insertAndFetch(db).id)
}

private func histInsertHost(_ db: Database, label: String) throws -> Int64 {
    try db.execute(sql: "INSERT INTO hosts (label, hostname, port, username) VALUES (?, '10.0.0.9', 22, 'root')",
                   arguments: [label])
    return db.lastInsertedRowID
}

private func histWriteTranscript(_ id: Int64, in scratch: HistScratch) throws {
    try Data("output of \(id)\n".utf8).write(to: SessionTranscripts.url(for: id, in: scratch.transcripts))
}

/// The names in the transcripts folder, sorted.
private func histFiles(_ scratch: HistScratch) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: scratch.transcripts.path).sorted()
}

private func histRowIds(_ scratch: HistScratch) async throws -> [Int64] {
    try await scratch.pool.read { db in
        try Int64.fetchAll(db, sql: "SELECT id FROM connection_logs ORDER BY id")
    }
}

private func histNames(_ ids: [Int64]) -> [String] {
    ids.map { "\($0).log" }.sorted()
}

// MARK: - Deleting records removes exactly their transcripts

@Test func histDeletingOneRecordRemovesItsTranscriptAndNoOther() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    let ids = try await scratch.pool.write { db in
        try (0..<3).map { try histInsert(db, label: "web-\($0)") }
    }
    for id in ids { try histWriteTranscript(id, in: scratch) }

    let target = ids[1]
    let removed = try await ConnectionLogRepository.removing(from: scratch.pool, transcriptsIn: scratch.transcripts) { db in
        try ConnectionLogRepository.deleteRecord(db, id: target)
    }

    #expect(removed == [target])
    let rows = try await histRowIds(scratch)
    #expect(rows == [ids[0], ids[2]])
    let files = try histFiles(scratch)
    #expect(files == histNames([ids[0], ids[2]]))
}

@Test func histDeletingARecordThatIsNotThereRemovesNothing() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    let id = try await scratch.pool.write { db in try histInsert(db, label: "web") }
    try histWriteTranscript(id, in: scratch)
    // A transcript whose number is not a record of this database: not this deletion's to remove.
    let unknown: Int64 = id + 41
    try histWriteTranscript(unknown, in: scratch)

    let removed = try await ConnectionLogRepository.removing(from: scratch.pool, transcriptsIn: scratch.transcripts) { db in
        try ConnectionLogRepository.deleteRecord(db, id: unknown)
    }

    #expect(removed.isEmpty)
    let files = try histFiles(scratch)
    #expect(files == histNames([id, unknown]))
}

@Test func histClearingRemovesEveryRecordsTranscriptButNoFileItDoesNotOwn() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    let ids = try await scratch.pool.write { db in
        try (0..<5).map { try histInsert(db, label: "web-\($0)") }
    }
    // The fourth record never had output (a failed connection).
    for id in ids where id != ids[3] { try histWriteTranscript(id, in: scratch) }
    // A transcript no record of THIS database refers to: after a restore, the database kept
    // for rolling back still does. Clearing must not sweep it away.
    let foreign: Int64 = (ids.max() ?? 0) + 1000
    try histWriteTranscript(foreign, in: scratch)
    try Data("mine".utf8).write(to: scratch.transcripts.appendingPathComponent("notes.txt"))

    let removed = try await ConnectionLogRepository.removing(from: scratch.pool, transcriptsIn: scratch.transcripts) { db in
        try ConnectionLogRepository.deleteAllRecords(db)
    }

    #expect(removed.sorted() == ids)
    let rows = try await histRowIds(scratch)
    #expect(rows.isEmpty)
    let files = try histFiles(scratch)
    #expect(files == ["\(foreign).log", "notes.txt"])
}

@Test func histPruningOldRecordsRemovesOnlyTheirTranscripts() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    let cutoff = try #require(TimestampFormatter.date(from: "2026-07-07T00:00:00Z"))
    let (old, recent) = try await scratch.pool.write { db in
        let old = try [
            histInsert(db, label: "old-a", at: "2026-06-01T08:00:00Z"),
            histInsert(db, label: "old-b", at: "2026-07-06T23:59:59Z")
        ]
        let recent = try [
            histInsert(db, label: "new-a", at: "2026-07-07T00:00:00Z"),
            histInsert(db, label: "new-b", at: "2026-10-05T12:00:00Z")
        ]
        return (old, recent)
    }
    for id in old + recent { try histWriteTranscript(id, in: scratch) }

    let removed = try await ConnectionLogRepository.removing(from: scratch.pool, transcriptsIn: scratch.transcripts) { db in
        try ConnectionLogRepository.deleteRecords(db, startedBefore: cutoff)
    }

    #expect(removed.sorted() == old)
    let rows = try await histRowIds(scratch)
    #expect(rows == recent)
    let files = try histFiles(scratch)
    #expect(files == histNames(recent))
}

@Test func histDeletingAHostRemovesItsHistoryAndThatHistorysTranscriptsOnly() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    struct Seeded: Sendable {
        let doomedHost: Int64
        let doomed: [Int64]
        let kept: [Int64]
    }
    let seeded = try await scratch.pool.write { db -> Seeded in
        let doomedHost = try histInsertHost(db, label: "doomed")
        let otherHost = try histInsertHost(db, label: "other")
        let doomed = try [
            histInsert(db, label: "doomed", hostId: doomedHost),
            histInsert(db, label: "doomed", hostId: doomedHost, status: "failed", error: "Connection refused")
        ]
        let kept = try [
            histInsert(db, label: "other", hostId: otherHost),
            // An address typed once: the same name, but no saved host.
            histInsert(db, label: "doomed", hostId: nil)
        ]
        return Seeded(doomedHost: doomedHost, doomed: doomed, kept: kept)
    }
    for id in seeded.doomed + seeded.kept { try histWriteTranscript(id, in: scratch) }

    let removed = try await ConnectionLogRepository.removing(from: scratch.pool, transcriptsIn: scratch.transcripts) { db in
        try ConnectionLogRepository.deleteHost(db, id: seeded.doomedHost)
    }

    #expect(removed.sorted() == seeded.doomed)
    let rows = try await histRowIds(scratch)
    #expect(rows == seeded.kept)
    let hosts = try await scratch.pool.read { db in try String.fetchAll(db, sql: "SELECT label FROM hosts") }
    #expect(hosts == ["other"])
    let files = try histFiles(scratch)
    #expect(files == histNames(seeded.kept))
}

// MARK: - The database first; the files only when it succeeded

@Test func histAFailedDatabaseStepRemovesNoTranscript() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    let ids = try await scratch.pool.write { db -> [Int64] in
        let ids = try (0..<3).map { try histInsert(db, label: "web-\($0)") }
        // The database refuses to delete history.
        try db.execute(sql: """
            CREATE TRIGGER hist_refuse BEFORE DELETE ON connection_logs
            BEGIN SELECT RAISE(ABORT, 'history is read-only'); END
            """)
        return ids
    }
    for id in ids { try histWriteTranscript(id, in: scratch) }

    await #expect(throws: (any Error).self) {
        try await ConnectionLogRepository.removing(from: scratch.pool, transcriptsIn: scratch.transcripts) { db in
            try ConnectionLogRepository.deleteAllRecords(db)
        }
    }
    await #expect(throws: (any Error).self) {
        try await ConnectionLogRepository.removing(from: scratch.pool, transcriptsIn: scratch.transcripts) { db in
            try ConnectionLogRepository.deleteRecord(db, id: ids[0])
        }
    }

    let rows = try await histRowIds(scratch)
    #expect(rows == ids)
    let files = try histFiles(scratch)
    #expect(files == histNames(ids))
}

@Test func histATransactionThatFailsAfterDeletingRollsBackAndRemovesNoTranscript() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    let ids = try await scratch.pool.write { db in
        try (0..<2).map { try histInsert(db, label: "web-\($0)") }
    }
    for id in ids { try histWriteTranscript(id, in: scratch) }

    struct LaterStepFailed: Error {}
    await #expect(throws: LaterStepFailed.self) {
        try await ConnectionLogRepository.removing(from: scratch.pool, transcriptsIn: scratch.transcripts) { db in
            _ = try ConnectionLogRepository.deleteAllRecords(db)
            throw LaterStepFailed()
        }
    }

    let rows = try await histRowIds(scratch)
    #expect(rows == ids)
    let files = try histFiles(scratch)
    #expect(files == histNames(ids))
}

@Test func histATranscriptThatCannotBeRemovedIsReportedNotFatal() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    let ids = try await scratch.pool.write { db in
        try (0..<2).map { try histInsert(db, label: "web-\($0)") }
    }
    for id in ids { try histWriteTranscript(id, in: scratch) }
    // Nothing can be unlinked from a folder that is not writable.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratch.transcripts.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.transcripts.path)
    }

    // The records go all the same: the deletion does not throw.
    let removed = try await ConnectionLogRepository.removing(from: scratch.pool, transcriptsIn: scratch.transcripts) { db in
        try ConnectionLogRepository.deleteAllRecords(db)
    }
    #expect(removed.sorted() == ids)
    let rows = try await histRowIds(scratch)
    #expect(rows.isEmpty)

    // And the file side says which ones stayed.
    let kept = SessionTranscripts.remove(ids: ids, in: scratch.transcripts)
    #expect(kept == ids)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.transcripts.path)
    let none = SessionTranscripts.remove(ids: ids, in: scratch.transcripts)
    #expect(none.isEmpty)
    let files = try histFiles(scratch)
    #expect(files.isEmpty)
}

@Test func histTranscriptsAreNamedByTheRecordsId() {
    let folder = URL(fileURLWithPath: "/opt/termi-qa/SessionLogs", isDirectory: true)
    let path: String = SessionTranscripts.url(for: 7, in: folder).path
    #expect(path == "/opt/termi-qa/SessionLogs/7.log")
    // Removing from a folder that does not exist is not a failure: nothing is there to stay.
    // A folder of this test's own, never a fixed path: on a Mac where that path happens to
    // exist the test would delete somebody's transcripts.
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-Tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("SessionLogs", isDirectory: true)
    let kept = SessionTranscripts.remove(ids: [1, 2], in: missing)
    #expect(kept.isEmpty)
}

// MARK: - A record's number is never one a transcript on disk already has

@Test func histTranscriptNumbersAreReadFromFileNamesOnly() {
    let seven = SessionTranscripts.recordId(ofFileNamed: "7.log")
    #expect(seven == 7)
    for name in ["7.log.part", "7.txt", ".log", "-7.log", "7a.log", "notes.log", "７.log", "7"] {
        let id = SessionTranscripts.recordId(ofFileNamed: name)
        #expect(id == nil, "\(name) is not a transcript")
    }
}

@Test func histANewRecordIsNumberedAboveEveryTranscriptOnDisk() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    // A restored backup: its last record is 10, but sessions 11 and 100 were recorded after
    // that backup was made, and their transcripts are kept for rolling back.
    try await scratch.pool.write { db in
        try db.execute(sql: """
            INSERT INTO connection_logs (id, host_label, hostname, status, connected_at)
            VALUES (10, 'restored', 'r.example', 'disconnected', '2026-09-01T10:00:00Z')
            """)
    }
    try histWriteTranscript(11, in: scratch)
    try histWriteTranscript(100, in: scratch)
    let highest = SessionTranscripts.highestId(in: scratch.transcripts)
    #expect(highest == 100)

    let fresh = try await scratch.pool.write { db in
        try ConnectionLogRepository.reserveIds(db, through: highest)
        return try histInsert(db, label: "after the restore")
    }
    // Without the reservation this would be 11: the output of another session.
    #expect(fresh == 101)

    // Nothing on disk, or a counter that is already ahead: the counter is left alone.
    let next = try await scratch.pool.write { db in
        try ConnectionLogRepository.reserveIds(db, through: nil)
        try ConnectionLogRepository.reserveIds(db, through: 50)
        return try histInsert(db, label: "the next one")
    }
    #expect(next == 102)
}

@Test func histTheFirstRecordOfAnEmptyHistoryIsNumberedAboveLeftoverTranscripts() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    // A database that never had a history record (its counter does not exist yet) beside
    // transcripts of a database that was replaced.
    try histWriteTranscript(42, in: scratch)
    let first = try await scratch.pool.write { db in
        try ConnectionLogRepository.reserveIds(db, through: SessionTranscripts.highestId(in: scratch.transcripts))
        return try histInsert(db, label: "first")
    }
    #expect(first == 43)
}

// MARK: - Search asks every record

@Test func histSearchFindsRecordsOlderThanTheListedPage() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    try await scratch.pool.write { db in
        // Five old sessions, then 260 newer ones: the listed page (200) holds none of the old.
        for index in 0..<5 {
            _ = try histInsert(db, label: "archive-db", at: String(format: "2026-08-01T08:%02d:00Z", index))
        }
        for index in 0..<260 {
            let stamp = String(format: "2026-10-05T%02d:%02d:00Z", index / 60, index % 60)
            _ = try histInsert(db, label: "web", at: stamp)
        }
    }

    let (latest, archive, web) = try await scratch.pool.read { db in
        (try ConnectionLogRepository.page(db, limit: 200),
         try ConnectionLogRepository.page(db, matching: ConnectionLogQuery(text: "archive"), limit: 200),
         try ConnectionLogRepository.page(db, matching: ConnectionLogQuery(text: "WEB"), limit: 200))
    }

    // Without a search: the newest 200, none of them old, and the numbers of all 265.
    #expect(latest.records.count == 200)
    #expect(latest.matches == nil)
    #expect(latest.totals.total == 265)
    let listedOld = latest.records.filter { $0.hostLabel == "archive-db" }
    #expect(listedOld.isEmpty)

    // The search reaches them, newest first, and still counts every record in the cards.
    #expect(archive.matches == 5)
    let archiveTimes: [String] = archive.records.map(\.connectedAt)
    let newestFirst: [String] = [
        "2026-08-01T08:04:00Z", "2026-08-01T08:03:00Z", "2026-08-01T08:02:00Z",
        "2026-08-01T08:01:00Z", "2026-08-01T08:00:00Z"
    ]
    #expect(archiveTimes == newestFirst)
    #expect(archive.totals.total == 265)

    // More matches than the list holds: the newest 200 of them, and how many there are.
    #expect(web.matches == 260)
    #expect(web.records.count == 200)
    let newestWeb: String? = web.records.first?.connectedAt
    let oldestListedWeb: String? = web.records.last?.connectedAt
    #expect(newestWeb == "2026-10-05T04:19:00Z")
    #expect(oldestListedWeb == "2026-10-05T01:00:00Z")
}

@Test func histSearchLooksAtNameAddressErrorAndState() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    try await scratch.pool.write { db in
        _ = try histInsert(db, label: "alpha", hostname: "10.1.1.1")
        _ = try histInsert(db, label: "beta", hostname: "db.example.org")
        _ = try histInsert(db, label: "gamma", hostname: "10.2.2.2", status: "failed", error: "Permission denied (publickey)")
        _ = try histInsert(db, label: "delta", hostname: "10.3.3.3", status: "error", error: nil)
    }
    func labels(_ query: ConnectionLogQuery) async throws -> [String] {
        try await scratch.pool.read { db in
            try ConnectionLogRepository.page(db, matching: query).records.map(\.hostLabel).sorted()
        }
    }

    let byName = try await labels(ConnectionLogQuery(text: "ALPHA"))
    #expect(byName == ["alpha"])
    let byAddress = try await labels(ConnectionLogQuery(text: "example.org"))
    #expect(byAddress == ["beta"])
    let byError = try await labels(ConnectionLogQuery(text: "publickey"))
    #expect(byError == ["gamma"])
    // The state as it is stored…
    let byStoredState = try await labels(ConnectionLogQuery(text: "failed"))
    #expect(byStoredState == ["gamma"])
    // …and as the table words it: "error" is shown as "Failed" too.
    let english = ConnectionLogsViewModel.storedStatuses(showing: "fail") { status in
        ["connected": "Connected", "disconnected": "Disconnected", "failed": "Failed", "error": "Failed"][status] ?? status
    }
    #expect(english == ["failed", "error"])
    let byShownState = try await labels(ConnectionLogQuery(text: "fail", statuses: english))
    #expect(byShownState == ["delta", "gamma"])
    // White space around the text is not part of it; nothing typed is not a search.
    let padded = try await labels(ConnectionLogQuery(text: "  alpha \n"))
    #expect(padded == ["alpha"])
    let blank = ConnectionLogQuery(text: "   ", statuses: ["failed"])
    #expect(blank == ConnectionLogQuery())
    #expect(blank.isEmpty)
}

@Test func histSearchFindsAStateByItsWordInTheInterfaceLanguage() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    try await scratch.pool.write { db in
        _ = try histInsert(db, label: "ok-1", status: "disconnected")
        _ = try histInsert(db, label: "bad-1", status: "failed", error: "Connection refused")
        _ = try histInsert(db, label: "bad-2", status: "error")
        _ = try histInsert(db, label: "live-1", status: "connected")
    }
    let chinese: (String) -> String = { status in
        ["connected": "已连接", "disconnected": "已断开", "failed": "失败", "error": "失败"][status] ?? status
    }

    // Nothing in the database contains "失败": the word is only on screen.
    let failedWords = ConnectionLogsViewModel.storedStatuses(showing: "失败", shown: chinese)
    #expect(failedWords == ["failed", "error"])
    let connectedWords = ConnectionLogsViewModel.storedStatuses(showing: " 已连 ", shown: chinese)
    #expect(connectedWords == ["connected"])
    let noWords = ConnectionLogsViewModel.storedStatuses(showing: "web", shown: chinese)
    #expect(noWords.isEmpty)
    let nothingTyped = ConnectionLogsViewModel.storedStatuses(showing: "  ", shown: chinese)
    #expect(nothingTyped.isEmpty)

    let page = try await scratch.pool.read { db in
        try ConnectionLogRepository.page(db, matching: ConnectionLogQuery(text: "失败", statuses: failedWords))
    }
    #expect(page.matches == 2)
    let failedLabels: [String] = page.records.map(\.hostLabel).sorted()
    #expect(failedLabels == ["bad-1", "bad-2"])
    let withoutWords = try await scratch.pool.read { db in
        try ConnectionLogRepository.page(db, matching: ConnectionLogQuery(text: "失败"))
    }
    #expect(withoutWords.matches == 0)
    #expect(withoutWords.records.isEmpty)
}

@Test func histSearchTextMeansItsCharactersNotWildcards() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    try await scratch.pool.write { db in
        for label in ["cpu 100%", "cpu 1000", "a_b", "axb", #"back\slash"#, "plain", "it's"] {
            _ = try histInsert(db, label: label)
        }
    }
    func labels(_ text: String) async throws -> [String] {
        try await scratch.pool.read { db in
            try ConnectionLogRepository.page(db, matching: ConnectionLogQuery(text: text)).records.map(\.hostLabel).sorted()
        }
    }

    let percent = try await labels("100%")
    #expect(percent == ["cpu 100%"])
    let onlyPercent = try await labels("%")
    #expect(onlyPercent == ["cpu 100%"])
    let underscore = try await labels("a_b")
    #expect(underscore == ["a_b"])
    let onlyUnderscore = try await labels("_")
    #expect(onlyUnderscore == ["a_b"])
    let backslash = try await labels(#"\"#)
    #expect(backslash == [#"back\slash"#])
    let escapedLooking = try await labels(#"\%"#)
    #expect(escapedLooking.isEmpty)
    // A quote is text, not SQL.
    let quote = try await labels("it's")
    #expect(quote == ["it's"])
    let injection = try await labels("' OR 1=1 --")
    #expect(injection.isEmpty)
}

/// SQLite refuses a LIKE pattern over 50 000 bytes; a long paste must be a search like any other.
@Test func histSearchTakesAVeryLongTextAndAnEmoji() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    let longError = String(repeating: "timeout ", count: 10_000)
    try await scratch.pool.write { db in
        _ = try histInsert(db, label: "web 🚀", status: "failed", error: longError)
        _ = try histInsert(db, label: "plain")
    }
    func labels(_ text: String) async throws -> [String] {
        try await scratch.pool.read { db in
            try ConnectionLogRepository.page(db, matching: ConnectionLogQuery(text: text)).records.map(\.hostLabel)
        }
    }

    // 80 000 characters that are in a record, and as many that are in none.
    let found = try await labels(longError)
    #expect(found == ["web 🚀"])
    let missing = try await labels(String(repeating: "%_", count: 40_000))
    #expect(missing.isEmpty)
    let emoji = try await labels("🚀")
    #expect(emoji == ["web 🚀"])
}

@Test func histSearchIgnoresCaseBeyondASCII() async throws {
    let scratch = try histMakeScratch()
    defer { histDiscard(scratch) }
    try await scratch.pool.write { db in
        _ = try histInsert(db, label: "Сервер-1")
        _ = try histInsert(db, label: "Büro NAS")
        _ = try histInsert(db, label: "plain")
    }
    let (cyrillic, umlaut) = try await scratch.pool.read { db in
        (try ConnectionLogRepository.page(db, matching: ConnectionLogQuery(text: "сервер")),
         try ConnectionLogRepository.page(db, matching: ConnectionLogQuery(text: "BÜRO")))
    }
    let cyrillicLabels: [String] = cyrillic.records.map(\.hostLabel)
    let umlautLabels: [String] = umlaut.records.map(\.hostLabel)
    #expect(cyrillicLabels == ["Сервер-1"])
    #expect(umlautLabels == ["Büro NAS"])
}

// MARK: - The line under the table, and the selection

@Test func histTheLineUnderTheTableSaysWhatIsLeftOutInBothModes() {
    // Everything is listed: nothing to say.
    #expect(HistoryCut(listed: 12, total: 12, matches: nil) == nil)
    #expect(HistoryCut(listed: 7, total: 575, matches: 7) == nil)
    #expect(HistoryCut(listed: 0, total: 575, matches: 0) == nil)
    // The newest 200 of all records / of the matches.
    #expect(HistoryCut(listed: 200, total: 575, matches: nil) == .latest(listed: 200, total: 575))
    #expect(HistoryCut(listed: 200, total: 575, matches: 392) == .matches(listed: 200, total: 392))
}

@Test func histTheSelectedRecordStaysWhileItIsStillListed() {
    let listed = [41, 40, 12].map { id in
        ConnectionLog(id: Int64(id), hostId: nil, hostLabel: "web", hostname: "10.0.0.5", status: "disconnected",
                      errorMessage: nil, durationMs: nil, connectedAt: "2026-10-05T12:00:00Z", disconnectedAt: nil)
    }
    let still: ConnectionLog.ID = 12
    let gone: ConnectionLog.ID = 99
    #expect(ConnectionLogsViewModel.selection(keeping: still, in: listed) == still)
    // Not listed any more: the first of what is.
    let first: ConnectionLog.ID = 41
    #expect(ConnectionLogsViewModel.selection(keeping: gone, in: listed) == first)
    #expect(ConnectionLogsViewModel.selection(keeping: nil, in: listed) == first)
    #expect(ConnectionLogsViewModel.selection(keeping: still, in: []) == nil)
}

// MARK: - The view model: one reading at a time on screen

/// Holds a reading back until the test lets it through.
private actor HistGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func pass() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

private func histPage(_ labels: [String], matches: Int?, total: Int) -> ConnectionLogPage {
    let records = labels.enumerated().map { index, label in
        ConnectionLog(id: Int64(index + 1), hostId: nil, hostLabel: label, hostname: "10.0.0.5", status: "disconnected",
                      errorMessage: nil, durationMs: nil, connectedAt: "2026-10-05T12:00:00Z", disconnectedAt: nil)
    }
    let totals = ConnectionLogTotals(total: total, failed: 0, averageDurationMs: nil, longestDurationMs: nil,
                                     top: nil, days: [], recentDurationsMs: [])
    return ConnectionLogPage(records: records, matches: matches, totals: totals)
}

@Test @MainActor func histANewerSearchReplacesAnOlderOneThatIsStillRunning() async throws {
    let gate = HistGate()
    let viewModel = ConnectionLogsViewModel(debounce: .zero) { query in
        if query.text == "slow" {
            await gate.pass()
            return histPage(["slow-result"], matches: 1, total: 9)
        }
        return histPage(["fast-result"], matches: 1, total: 9)
    }

    viewModel.searchText = "slow"
    let older = Task { @MainActor in await viewModel.loadLogs() }
    // The older reading is under way (held at the gate) when the next one is asked for.
    var arrived = 0
    for _ in 0..<2000 where arrived == 0 {
        try await Task.sleep(for: .milliseconds(1))
        arrived = await gate.arrivals
    }
    try #require(arrived == 1)

    viewModel.searchText = "fast"
    await viewModel.loadLogs()
    let afterFast: [String] = viewModel.logs.map(\.hostLabel)
    #expect(afterFast == ["fast-result"])
    #expect(viewModel.listedSearch == "fast")
    let versionAfterFast = viewModel.listVersion

    // The older answer arrives last and is dropped.
    await gate.open()
    await older.value
    let afterOlder: [String] = viewModel.logs.map(\.hostLabel)
    #expect(afterOlder == ["fast-result"])
    #expect(viewModel.listedSearch == "fast")
    #expect(viewModel.listVersion == versionAfterFast)
    #expect(viewModel.error == nil)
}

@Test @MainActor func histTheListAndTheNumbersComeFromOneReading() async {
    let viewModel = ConnectionLogsViewModel(debounce: .zero) { query in
        query.isEmpty
            ? histPage((0..<200).map { "web-\($0)" }, matches: nil, total: 575)
            : histPage((0..<200).map { "agent-\($0)" }, matches: 392, total: 575)
    }

    await viewModel.loadLogs()
    #expect(viewModel.hasLoaded)
    #expect(viewModel.logs.count == 200)
    #expect(viewModel.summary.stats.total == 575)
    #expect(viewModel.matchCount == nil)
    #expect(viewModel.cut == .latest(listed: 200, total: 575))
    #expect(!viewModel.hasNoRecords)

    viewModel.searchText = " agent "
    await viewModel.loadLogs()
    #expect(viewModel.listedSearch == "agent")
    #expect(viewModel.matchCount == 392)
    // The cards keep counting everything.
    #expect(viewModel.summary.stats.total == 575)
    #expect(viewModel.cut == .matches(listed: 200, total: 392))
}

@Test @MainActor func histASearchThatMatchesNothingIsNotAnEmptyHistoryAndAFailureKeepsTheList() async {
    struct ReadFailed: Error {}
    let viewModel = ConnectionLogsViewModel(debounce: .zero) { query in
        switch query.text {
        case "": return histPage(["web"], matches: nil, total: 1)
        case "nothing": return histPage([], matches: 0, total: 1)
        case "cancelled": throw CancellationError()
        default: throw ReadFailed()
        }
    }

    await viewModel.loadLogs()
    viewModel.searchText = "nothing"
    await viewModel.loadLogs()
    #expect(viewModel.logs.isEmpty)
    #expect(viewModel.matchCount == 0)
    #expect(viewModel.cut == nil)
    // There IS history: the page shows "no results", not "no connection logs".
    #expect(!viewModel.hasNoRecords)

    // A failed reading says so and leaves what was on screen.
    viewModel.searchText = ""
    await viewModel.loadLogs()
    viewModel.searchText = "broken"
    await viewModel.loadLogs()
    #expect(viewModel.error != nil)
    let stillListed: [String] = viewModel.logs.map(\.hostLabel)
    #expect(stillListed == ["web"])
    #expect(viewModel.listedSearch.isEmpty)

    // A search the next keystroke cancelled is not a failure.
    viewModel.error = nil
    viewModel.searchText = "cancelled"
    await viewModel.loadLogs()
    #expect(viewModel.error == nil)
    #expect(!viewModel.isLoading)
}

@Test @MainActor func histTypingAsksOnceThePauseIsOverAndOnlyForTheLastText() async throws {
    let asked = HistAsked()
    let viewModel = ConnectionLogsViewModel(debounce: .milliseconds(60)) { query in
        await asked.add(query.text)
        return histPage([query.text], matches: query.isEmpty ? nil : 1, total: 3)
    }

    for text in ["a", "ar", "arc"] {
        viewModel.searchText = text
        viewModel.searchTextChanged()
    }
    var texts: [String] = []
    for _ in 0..<2000 where texts.isEmpty {
        try await Task.sleep(for: .milliseconds(5))
        texts = await asked.texts
    }
    // Give a wrongly surviving earlier search the time to show up.
    try await Task.sleep(for: .milliseconds(150))
    texts = await asked.texts
    #expect(texts == ["arc"])
    #expect(viewModel.listedSearch == "arc")
}

private actor HistAsked {
    private(set) var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
}

// MARK: - A transcript file is private from the moment it exists, and never replaces another

private func histMode(_ path: String) throws -> Int {
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

@Test func sessionTranscriptIsCreatedOwnerOnlyAndDoesNotReplace() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-Tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let logs = folder.appendingPathComponent("SessionLogs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    // What `mkdir` leaves behind under a typical umask, before any chmod.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logs.path)

    let created = try SessionTranscripts.createExclusive(for: 4, in: logs)
    let url = try #require(created)
    let directoryMode = try histMode(logs.path)
    let fileMode = try histMode(url.path)
    #expect(directoryMode == 0o700)
    #expect(fileMode == 0o600)
    let bytes = try Data(contentsOf: url)
    #expect(bytes.isEmpty)

    // A file already there is another session's output. It is not truncated.
    let kept = SessionTranscripts.url(for: 9, in: logs)
    try Data("kept".utf8).write(to: kept)
    let replaced = try SessionTranscripts.createExclusive(for: 9, in: logs)
    #expect(replaced == nil)
    let keptText = try String(contentsOf: kept, encoding: .utf8)
    #expect(keptText == "kept")

    // A symlink where the transcript would be is not followed, and not written through.
    let outside = folder.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outside)
    let link = logs.appendingPathComponent("8.log")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let throughLink = try? SessionTranscripts.createExclusive(for: 8, in: logs)
    #expect(throughLink == nil)
    let outsideText = try String(contentsOf: outside, encoding: .utf8)
    #expect(outsideText == "outside")

    // A symlink in place of the directory is not chmod'd, and gets no transcript.
    let real = folder.appendingPathComponent("real-logs", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
    let linkDir = folder.appendingPathComponent("link-logs")
    try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: real)
    let throughDirectory = try? SessionTranscripts.createExclusive(for: 1, in: linkDir)
    #expect(throughDirectory == nil)
    let realMode = try histMode(real.path)
    #expect(realMode == 0o755)
    #expect(!FileManager.default.fileExists(atPath: real.appendingPathComponent("1.log").path))
}
