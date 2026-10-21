import GRDB
import Foundation
import os.log

/// Repository for ConnectionLog CRUD operations
actor ConnectionLogRepository {
    static let shared = ConnectionLogRepository()

    private static let logger = Logger(subsystem: "dev.termi.Termi", category: "ConnLogRepo")

    func fetchAll(limit: Int = 200) async throws -> [ConnectionLog] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try ConnectionLog
                .order(Column("connected_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func fetchForHost(_ hostId: Int64) async throws -> [ConnectionLog] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try ConnectionLog
                .filter(Column("host_id") == hostId)
                .order(Column("connected_at").desc)
                .fetchAll(db)
        }
    }

    /// What the history page shows, read in ONE snapshot of the database: the records it lists
    /// and what all records add up to. Two separate reads could list a record the numbers do
    /// not count yet (a session that started in between).
    func page(matching query: ConnectionLogQuery = ConnectionLogQuery(), limit: Int = 200,
              now: Date = Date(), calendar: Calendar = .current) async throws -> ConnectionLogPage {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try Self.page(db, matching: query, limit: limit, now: now, calendar: calendar)
        }
    }

    /// The page itself, on any database (the tests run it on a scratch one). Call it inside
    /// one read: that is what makes the list and the numbers agree.
    static func page(_ db: Database, matching query: ConnectionLogQuery = ConnectionLogQuery(), limit: Int = 200,
                     now: Date = Date(), calendar: Calendar = .current) throws -> ConnectionLogPage {
        let totals = try totals(db, now: now, calendar: calendar)
        guard !query.isEmpty else {
            let latest = try ConnectionLog
                .order(Column("connected_at").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
            return ConnectionLogPage(records: latest, matches: nil, totals: totals)
        }

        // Every record is asked, not the listed ones: the cards count every record, and a
        // search that only knew the newest page said "no results" for an older session.
        db.add(function: fold)
        // The typed text means its characters: "100%" is not "100 and anything", "a_b" is
        // not "a, any character, b". instr() and not LIKE with escaped wildcards: it has no
        // wildcards to escape, and SQLite refuses a LIKE pattern over 50 000 bytes ("LIKE or
        // GLOB pattern too complex") — a long paste into the search field was a red error.
        var arguments = [query.text.lowercased()]
        // "?1": the one text, looked for in every column.
        var condition = ["host_label", "hostname", "status", "COALESCE(error_message, '')"]
            .map { "instr(\(fold.name)(\($0)), ?1) > 0" }
            .joined(separator: " OR ")
        // The states whose word on screen contains the text (the table does not show them as
        // they are stored: "error" reads "Failed", and in another language none reads as stored).
        if !query.statuses.isEmpty {
            let marks = Array(repeating: "?", count: query.statuses.count).joined(separator: ", ")
            condition += " OR lower(status) IN (\(marks))"
            arguments.append(contentsOf: query.statuses.map { $0.lowercased() })
        }

        let matches = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM connection_logs WHERE \(condition)",
                                       arguments: StatementArguments(arguments)) ?? 0
        let records = try ConnectionLog.fetchAll(db, sql: """
            SELECT * FROM connection_logs WHERE \(condition)
            ORDER BY connected_at DESC, id DESC
            LIMIT \(max(limit, 0))
            """, arguments: StatementArguments(arguments))
        return ConnectionLogPage(records: records, matches: matches, totals: totals)
    }

    /// Lower case as Swift knows it. SQLite's own lower() folds ASCII only: a host
    /// named "Сервер" or "Büro" would not be found by "сервер" or "büro".
    private static let fold = DatabaseFunction("termi_fold", argumentCount: 1, pure: true) { values in
        String.fromDatabaseValue(values[0])?.lowercased()
    }

    /// What ALL records add up to. The page lists the newest `fetchAll(limit:)` of them only,
    /// so its numbers cannot be counted from that list.
    func totals(now: Date = Date(), calendar: Calendar = .current) async throws -> ConnectionLogTotals {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try Self.totals(db, now: now, calendar: calendar)
        }
    }

    /// The aggregation itself, on any database (the tests run it on a scratch one).
    static func totals(_ db: Database, days dayCount: Int = 30, now: Date = Date(),
                       calendar: Calendar = .current) throws -> ConnectionLogTotals {
        let failed = "lower(status) IN ('failed', 'error')"
        let overall = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS total,
                   COALESCE(SUM(CASE WHEN \(failed) THEN 1 ELSE 0 END), 0) AS failed,
                   COALESCE(SUM(CASE WHEN duration_ms > 0 THEN 1 ELSE 0 END), 0) AS timed,
                   COALESCE(SUM(CASE WHEN duration_ms > 0 THEN duration_ms ELSE 0 END), 0) AS duration_sum,
                   MAX(CASE WHEN duration_ms > 0 THEN duration_ms END) AS duration_max
            FROM connection_logs
            """)
        let total: Int = overall?["total"] ?? 0
        let failedCount: Int = overall?["failed"] ?? 0
        let timed: Int = overall?["timed"] ?? 0
        let durationSum: Int64 = overall?["duration_sum"] ?? 0
        let longest: Int? = overall?["duration_max"]

        // A saved host is counted by its id (it may have been renamed), an ad-hoc one by its
        // name. With a single max() SQLite takes the other columns from that row: the name is
        // the one the host had at its latest connection. Ties go to the one connected to last.
        let name = "CASE WHEN host_label = '' THEN hostname ELSE host_label END"
        let topRow = try Row.fetchOne(db, sql: """
            SELECT host_id, \(name) AS name, COUNT(*) AS n, MAX(connected_at) AS latest
            FROM connection_logs
            GROUP BY COALESCE('#' || host_id, \(name))
            ORDER BY n DESC, latest DESC
            LIMIT 1
            """)
        let top = topRow.map { row -> ConnectionLogTotals.Top in
            ConnectionLogTotals.Top(name: row["name"], hostId: row["host_id"], count: row["n"])
        }

        // One count per local day: the bounds are that day's first moment and the next day's,
        // written the way `connected_at` is (ISO 8601 in UTC, which sorts as text).
        let today = calendar.startOfDay(for: now)
        var days: [ConnectionLogTotals.Day] = []
        for offset in (0..<dayCount).reversed() {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, COALESCE(SUM(CASE WHEN \(failed) THEN 1 ELSE 0 END), 0) AS failed
                FROM connection_logs
                WHERE connected_at >= ? AND connected_at < ?
                """, arguments: [TimestampFormatter.string(from: start), TimestampFormatter.string(from: end)])
            let count: Int = row?["n"] ?? 0
            let dayFailed: Int = row?["failed"] ?? 0
            days.append(ConnectionLogTotals.Day(date: start, succeeded: count - dayFailed, failed: dayFailed))
        }

        let recent = try Int.fetchAll(db, sql: """
            SELECT duration_ms FROM connection_logs
            WHERE duration_ms > 0
            ORDER BY connected_at DESC
            LIMIT 30
            """)

        return ConnectionLogTotals(
            total: total,
            failed: failedCount,
            averageDurationMs: timed > 0 ? Int(durationSum / Int64(timed)) : nil,
            longestDurationMs: longest,
            top: top,
            days: days,
            recentDurationsMs: recent.reversed()
        )
    }

    @discardableResult
    /// Makes the next history record's id larger than `highest` (the highest number a transcript
    /// on disk carries). The table counts on from its own highest id ever, which a restored or
    /// imported database may have behind what `SessionLogs` still holds.
    static func reserveIds(_ db: Database, through highest: Int64?) throws {
        guard let highest, highest > 0 else { return }
        // The counter's row exists only once the table has had a row.
        try db.execute(sql: """
            INSERT INTO sqlite_sequence (name, seq)
            SELECT 'connection_logs', ? WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'connection_logs')
            """, arguments: [highest])
        try db.execute(sql: "UPDATE sqlite_sequence SET seq = MAX(seq, ?) WHERE name = 'connection_logs'",
                       arguments: [highest])
    }

    func log(host: Host, status: String, error: String? = nil) async throws -> ConnectionLog {
        let writer = try await DatabaseManager.shared.writer
        // Read before the transaction: a new record never takes the number of a transcript
        // that is on disk (see `SessionTranscripts.highestId`).
        let highestTranscript = SessionTranscripts.highestId()
        return try await DataSnapshot.write(writer) { db in
            try Self.reserveIds(db, through: highestTranscript)
            let entry = ConnectionLog(
                hostId: host.id,
                hostLabel: host.label,
                hostname: host.hostname,
                status: status,
                errorMessage: error,
                connectedAt: TimestampFormatter.now()
            )
            return try entry.insertAndFetch(db)
        }
    }

    func updateDisconnected(id: Int64, durationMs: Int) async throws {
        let writer = try await DatabaseManager.shared.writer
        try await DataSnapshot.write(writer) { db in
            try db.execute(
                sql: """
                    UPDATE connection_logs
                    SET disconnected_at = ?, duration_ms = ?, status = 'disconnected'
                    WHERE id = ?
                """,
                arguments: [TimestampFormatter.now(), durationMs, id]
            )
        }
    }

    // MARK: - Deleting records, and what they recorded
    //
    // A record's terminal output is saved in a file named by its id (`SessionTranscripts`).
    // Every way records go removes exactly their transcripts: someone who clears the history
    // means the output too, and a file no record leads to can no longer be reached from the app.

    /// The whole history and every saved session output of it.
    func deleteAll() async throws {
        let ids = try await Self.removing(from: try await DatabaseManager.shared.writer) { db in
            try Self.deleteAllRecords(db)
        }
        Self.logger.info("Cleared the connection history: \(ids.count) record(s)")
    }

    /// One record and its saved session output.
    func delete(id: Int64) async throws {
        try await Self.removing(from: try await DatabaseManager.shared.writer) { db in
            try Self.deleteRecord(db, id: id)
        }
    }

    /// A saved host, and with it — the database cascades them — its history records, whose
    /// saved session output goes too. This is here and not in the host repository because the
    /// ids of those records have to be read in the transaction that deletes the host.
    func deleteHostWithHistory(hostId: Int64) async throws {
        let ids = try await Self.removing(from: try await DatabaseManager.shared.writer) { db in
            try Self.deleteHost(db, id: hostId)
        }
        Self.logger.info("Deleted host \(hostId) and its \(ids.count) history record(s)")
    }

    /// The step every deletion goes through. The database first, in one transaction that also
    /// reads the ids of the records it deletes (afterwards nobody knows them); the files only
    /// once that is committed. When the database step fails nothing has been removed; a file
    /// that cannot be removed afterwards is logged by `SessionTranscripts`, and the records
    /// stay deleted.
    @discardableResult
    static func removing(from writer: any DatabaseWriter,
                         transcriptsIn directory: URL = SessionTranscripts.directory,
                         _ deletion: @escaping @Sendable (Database) throws -> [Int64]) async throws -> [Int64] {
        let ids = try await DataSnapshot.write(writer) { db in try deletion(db) }
        SessionTranscripts.remove(ids: ids, in: directory)
        return ids
    }

    /// Each of these deletes inside the caller's transaction and returns the ids of the
    /// history records that went, read BEFORE the rows are deleted.

    static func deleteRecord(_ db: Database, id: Int64) throws -> [Int64] {
        let ids = try Int64.fetchAll(db, sql: "SELECT id FROM connection_logs WHERE id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM connection_logs WHERE id = ?", arguments: [id])
        return ids
    }

    static func deleteAllRecords(_ db: Database) throws -> [Int64] {
        let ids = try Int64.fetchAll(db, sql: "SELECT id FROM connection_logs")
        try db.execute(sql: "DELETE FROM connection_logs")
        return ids
    }

    static func deleteRecords(_ db: Database, startedBefore cutoff: Date) throws -> [Int64] {
        let stamp = TimestampFormatter.string(from: cutoff)
        let ids = try Int64.fetchAll(db, sql: "SELECT id FROM connection_logs WHERE connected_at < ?", arguments: [stamp])
        try db.execute(sql: "DELETE FROM connection_logs WHERE connected_at < ?", arguments: [stamp])
        return ids
    }

    /// The host's own row; its records (and rules, and tags) go by ON DELETE CASCADE. Records
    /// of an address that was only typed once have no host and stay.
    static func deleteHost(_ db: Database, id: Int64) throws -> [Int64] {
        let ids = try Int64.fetchAll(db, sql: "SELECT id FROM connection_logs WHERE host_id = ?", arguments: [id])
        try Host.deleteOne(db, key: id)
        return ids
    }

    /// Rows a previous run left "connected" (it quit or crashed with the session open). No
    /// session of this run is older than its launch, so they are over; when is unknown, so the
    /// duration stays empty.
    @discardableResult
    func closeUnfinished(startedBefore cutoff: Date) async throws -> Int {
        let writer = try await DatabaseManager.shared.writer
        let cutoffStr = TimestampFormatter.string(from: cutoff)
        return try await DataSnapshot.write(writer) { db in
            try db.execute(sql: """
                UPDATE connection_logs SET status = 'disconnected'
                WHERE status = 'connected' AND connected_at < ?
            """, arguments: [cutoffStr])
            return db.changesCount
        }
    }

    /// Deletes the records older than the given number of days, with their saved session
    /// output. Call once at app launch.
    @discardableResult
    func deleteOlderThan(days: Int) async throws -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let ids = try await Self.removing(from: try await DatabaseManager.shared.writer) { db in
            try Self.deleteRecords(db, startedBefore: cutoff)
        }
        if !ids.isEmpty {
            Self.logger.info("Pruned \(ids.count) connection log(s) older than \(days) days")
        }
        return ids.count
    }
}

/// What the history page asks for: nothing (the newest records), or a search.
struct ConnectionLogQuery: Sendable, Equatable {
    /// The typed text, without the white space around it. Empty: no search.
    let text: String
    /// The stored states whose word on screen contains the text, in the language of the
    /// interface (the database does not know that "failed" reads "失败").
    let statuses: [String]

    init(text: String = "", statuses: [String] = []) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.statuses = self.text.isEmpty ? [] : statuses
    }

    var isEmpty: Bool { text.isEmpty }
}

/// One consistent reading of the history: the listed records and the numbers of all of them.
struct ConnectionLogPage: Sendable {
    /// Newest first, at most the limit that was asked for.
    let records: [ConnectionLog]
    /// How many records a search matches in all (`records` may be fewer); nil without a search.
    let matches: Int?
    let totals: ConnectionLogTotals
}

/// What every recorded connection adds up to, counted in the database.
struct ConnectionLogTotals: Sendable, Equatable {
    struct Day: Sendable, Equatable {
        /// The day's first moment in the calendar the totals were asked with.
        let date: Date
        let succeeded: Int
        let failed: Int
    }

    /// The host that was connected to most often.
    struct Top: Sendable, Equatable {
        let name: String
        let hostId: Int64?
        let count: Int
    }

    let total: Int
    let failed: Int
    /// Mean of the durations that were recorded (> 0); nil when none was.
    let averageDurationMs: Int?
    let longestDurationMs: Int?
    let top: Top?
    /// The last days up to today, oldest first, empty days included.
    let days: [Day]
    /// The latest recorded durations, oldest first.
    let recentDurationsMs: [Int]
}
