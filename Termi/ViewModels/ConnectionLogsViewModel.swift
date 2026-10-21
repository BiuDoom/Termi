import SwiftUI
import os.log

/// The history page: what it lists (the newest records, or what a search matches among ALL
/// records) and what every record adds up to.
@Observable
@MainActor
final class ConnectionLogsViewModel {
    /// One consistent reading of the history for a query.
    typealias Loader = @Sendable (ConnectionLogQuery) async throws -> ConnectionLogPage

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "ConnLogsVM")
    private let repo = ConnectionLogRepository.shared
    private let load: Loader
    private let dataGeneration: UUID
    /// How long the typing has to pause before the database is asked.
    private let debounce: Duration

    /// The listed records: the newest ones, or the newest matches of `listedSearch`.
    var logs: [ConnectionLog] = []
    /// What is typed in the search field. `logs` follow it after `searchTextChanged()`.
    var searchText = ""
    /// The search `logs` answer — the typed text a moment ago; empty when they are the newest records.
    private(set) var listedSearch = ""
    /// How many records the search matches among all of them; nil without a search.
    private(set) var matchCount: Int?
    /// Counts the readings that were put on screen: the page looks after its selection then.
    private(set) var listVersion = 0
    var isLoading = false
    /// True once the first `loadLogs()` is over (the page draws nothing before that).
    private(set) var hasLoaded = false
    var error: String?
    var showingClearConfirm = false
    /// What ALL records add up to, counted in the database with the same reading as `logs`.
    private(set) var summary = HistorySummary([])

    /// The reading that was asked for last: an older one that is still running is dropped
    /// when it arrives.
    private var generation = 0
    private var pendingSearch: Task<Void, Never>?

    /// How many records the table lists (the newest ones, or the newest matches).
    static let listLimit = 200

    init(debounce: Duration = .milliseconds(250), load: Loader? = nil, dataGeneration: UUID = DataSnapshot.current) {
        self.debounce = debounce
        self.dataGeneration = dataGeneration
        let limit = Self.listLimit
        self.load = load ?? { query in
            try await ConnectionLogRepository.shared.page(matching: query, limit: limit)
        }
    }

    /// There is no history at all (not: a search matched nothing).
    var hasNoRecords: Bool {
        logs.isEmpty && summary.stats.total == 0
    }

    /// What the table leaves out, said in the line under it; nil when it lists everything
    /// there is (or everything that matches).
    var cut: HistoryCut? {
        HistoryCut(listed: logs.count, total: summary.stats.total, matches: matchCount)
    }

    /// The stored states whose word in the table contains the text: what is on screen can be
    /// searched, in the language it is shown in.
    nonisolated static func storedStatuses(showing text: String,
                                           shown: (String) -> String = shownStatus) -> [String] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return ["connected", "disconnected", "failed", "error"].filter { shown($0).lowercased().contains(needle) }
    }

    /// The status as the table shows it, so that a search matches what is on screen.
    nonisolated static func shownStatus(_ status: String) -> String {
        switch status.lowercased() {
        case "connected": String(localized: "Connected")
        case "disconnected": String(localized: "Disconnected")
        case "failed", "error": String(localized: "Failed")
        default: status
        }
    }

    /// The record that is selected after a reading: the one that was, while it is still
    /// listed; else the first.
    nonisolated static func selection(keeping current: ConnectionLog.ID?, in listed: [ConnectionLog]) -> ConnectionLog.ID? {
        if let current, listed.contains(where: { $0.id == current }) { return current }
        return listed.first.map(\.id)
    }

    /// The search field changed. Clearing it lists the newest records at once; text waits for
    /// a pause in the typing, and replaces a search that is still waiting or running.
    func searchTextChanged() {
        pendingSearch?.cancel()
        let delay = ConnectionLogQuery(text: searchText).isEmpty ? Duration.zero : debounce
        pendingSearch = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.loadLogs()
        }
    }

    /// Reads the list and the numbers for what is typed now, in one snapshot of the database,
    /// and puts both on screen together.
    func loadLogs() async {
        generation += 1
        let reading = generation
        let query = ConnectionLogQuery(text: searchText, statuses: Self.storedStatuses(showing: searchText))
        isLoading = true
        do {
            let page = try await load(query)
            // A newer reading was asked for meanwhile: its answer is the one to show.
            guard reading == generation else { return }
            logs = page.records
            matchCount = page.matches
            listedSearch = query.text
            summary = HistorySummary(page.totals)
            listVersion += 1
            error = nil
        } catch {
            guard reading == generation else { return }
            // A search the next keystroke cancelled is not a failure.
            if !(error is CancellationError) {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
        hasLoaded = true
    }

    func deleteLog(_ log: ConnectionLog) async {
        guard let id = log.id else { return }
        do {
            try await DataSnapshot.$expected.withValue(dataGeneration) {
                try await repo.delete(id: id)
            }
            await loadLogs()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearAll() async {
        do {
            try await DataSnapshot.$expected.withValue(dataGeneration) {
                try await repo.deleteAll()
            }
            await loadLogs()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// What the history table leaves out: it lists at most `ConnectionLogsViewModel.listLimit`
/// records, the cards above it count all of them.
enum HistoryCut: Equatable, Sendable {
    /// The newest `listed` of `total` records.
    case latest(listed: Int, total: Int)
    /// The newest `listed` of the `total` records a search matches.
    case matches(listed: Int, total: Int)

    /// Nil when nothing is left out.
    init?(listed: Int, total: Int, matches: Int?) {
        if let matches {
            guard matches > listed else { return nil }
            self = .matches(listed: listed, total: matches)
        } else {
            guard total > listed else { return nil }
            self = .latest(listed: listed, total: total)
        }
    }
}

// MARK: - What the page shows of a connection

extension ConnectionLog {
    /// How a connection went, as the table marks it.
    enum Outcome: Equatable, Sendable {
        case succeeded, failed, inProgress
    }

    /// Still open: connected, and neither an end nor a duration was recorded.
    var isInProgress: Bool {
        durationMs == nil && disconnectedAt == nil && status.lowercased() == "connected"
    }

    var outcome: Outcome {
        if dsDidFail { return .failed }
        return isInProgress ? .inProgress : .succeeded
    }

    /// The host's name, or its address when it has none.
    var displayName: String {
        hostLabel.isEmpty ? hostname : hostLabel
    }

    /// The address earns a second line only when the name is not the address itself
    /// (an ad-hoc host is named "user@host" or "user@host:port").
    var showsAddress: Bool {
        guard !hostLabel.isEmpty, hostLabel != hostname else { return false }
        let host = hostname.contains(":") ? "[\(hostname)]" : hostname
        let address = hostLabel.split(separator: "@").last.map(String.init) ?? hostLabel
        return !(address == host || address.hasPrefix(host + ":"))
    }

    /// The address as it is typed to reach the host again: with its port when that is not 22
    /// ("host:2222", "[::1]:2222"). A record keeps no port: it is the saved host's (`port`)
    /// while that host still has the record's address, else the one in an ad-hoc host's name
    /// ("user@host:2222").
    func addressToCopy(port savedPort: Int?) -> String {
        let bracketed = hostname.contains(":") ? "[\(hostname)]" : hostname
        var port = savedPort
        if port == nil, let target = hostLabel.split(separator: "@").last, target.hasPrefix(bracketed + ":") {
            port = Int(target.dropFirst(bracketed.count + 1))
        }
        guard let port, port != 22 else { return hostname }
        return "\(bracketed):\(port)"
    }

    /// The same, for the saved host the record belongs to: its port counts only while it still
    /// has the record's address (a host edited to another address and port was never reached at
    /// "old address:new port").
    func addressToCopy(savedHost: Host?) -> String {
        addressToCopy(port: savedHost?.hostname == hostname ? savedHost?.port : nil)
    }

    /// The first line of the error (the table has one line for it).
    var errorSummary: String? {
        guard let line = errorMessage?.split(whereSeparator: \.isNewline).first else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension DSLogStats {
    /// Numbers that were counted elsewhere (in the database, over every record).
    init(total: Int, failed: Int, averageDurationMs: Int?) {
        self.total = total
        self.failed = failed
        self.averageDurationMs = averageDurationMs
    }
}

/// What the connection history adds up to: the band above the table.
struct HistorySummary: Equatable {
    /// The host that was connected to most often.
    struct Top: Equatable {
        let name: String
        let hostId: Int64?
        let count: Int
        /// Its share of all connections, 0…100.
        let share: Double
    }

    let stats: DSLogStats
    /// Connections that started today.
    let today: Int
    let longestDurationMs: Int?
    let top: Top?
    /// The last 30 days, oldest first.
    let days: [DSActivityChart.Day]
    /// The recorded durations in seconds, oldest first (the trend under the average).
    let durations: [Double]

    /// The connections of the last 30 days, when that is not all of them ("Last 30 Days · 104
    /// times" next to a total of 412); nil when the total already is that number.
    var recentCountIfPartial: Int? {
        let recent = days.reduce(0) { $0 + $1.total }
        return recent == stats.total ? nil : recent
    }

    /// Whether the 30-day chart has a second colour to explain.
    var hasRecentFailures: Bool {
        days.contains { $0.failed > 0 }
    }

    /// From the database's own count of every record.
    init(_ totals: ConnectionLogTotals) {
        stats = DSLogStats(total: totals.total, failed: totals.failed, averageDurationMs: totals.averageDurationMs)
        days = totals.days.map { DSActivityChart.Day(date: $0.date, succeeded: $0.succeeded, failed: $0.failed) }
        today = days.last?.total ?? 0
        longestDurationMs = totals.longestDurationMs
        durations = totals.recentDurationsMs.map { Double($0) / 1000 }
        top = totals.top.map {
            Top(name: $0.name, hostId: $0.hostId, count: $0.count,
                share: totals.total > 0 ? Double($0.count * 100) / Double(totals.total) : 0)
        }
    }

    /// From a list of records that is known to be all of them.
    init(_ logs: [ConnectionLog], now: Date = Date(), calendar: Calendar = .current) {
        stats = DSLogStats(logs)
        days = DSActivityChart.days(from: logs, count: 30, now: now, calendar: calendar)
        today = days.last?.total ?? 0
        let recorded = logs.filter { ($0.durationMs ?? 0) > 0 }.sorted { $0.connectedAt < $1.connectedAt }
        longestDurationMs = recorded.compactMap(\.durationMs).max()
        durations = recorded.suffix(30).compactMap { $0.durationMs.map { Double($0) / 1000 } }

        // A saved host is counted by its id (it may have been renamed), an ad-hoc one by its name.
        var counts: [String: (name: String, hostId: Int64?, count: Int, latest: String)] = [:]
        for log in logs {
            let key = log.hostId.map { "#\($0)" } ?? log.displayName
            var entry = counts[key] ?? (name: log.displayName, hostId: log.hostId, count: 0, latest: "")
            entry.count += 1
            // The name the host had at its latest connection.
            if log.connectedAt >= entry.latest {
                entry.latest = log.connectedAt
                entry.name = log.displayName
            }
            counts[key] = entry
        }
        // Ties go to the one connected to last, so the answer does not depend on dictionary order.
        let best = counts.values.max { lhs, rhs in
            lhs.count != rhs.count ? lhs.count < rhs.count : lhs.latest < rhs.latest
        }
        top = best.map {
            Top(name: $0.name, hostId: $0.hostId, count: $0.count, share: Double($0.count * 100) / Double(logs.count))
        }
    }
}

/// How the history page writes times and durations. Pure, for the tests.
enum HistoryFormat {
    /// How wide the number cards are beside the 30-day chart: 140 pt each and the gaps between
    /// them — three cards (no average duration) leave their fourth's room to the chart.
    static func bandWidth(cards: Int) -> CGFloat {
        CGFloat(cards) * 140 + CGFloat(max(cards - 1, 0)) * 10
    }

    /// A duration as one number and its unit, for a number card: under a minute in seconds,
    /// under an hour in minutes, then in hours with one decimal. Nil without a duration.
    static func durationParts(ms: Int?) -> (value: String, unit: Unit)? {
        guard let ms, ms > 0 else { return nil }
        let seconds = max(ms / 1000, 1)
        if seconds < 60 { return ("\(seconds)", .seconds) }
        if seconds < 3600 { return ("\(Int((Double(seconds) / 60).rounded()))", .minutes) }
        return (String(format: "%.1f", locale: .current, Double(seconds) / 3600), .hours)
    }

    /// A duration as its two largest units, each a number and its unit ("4" min, "12" sec), for
    /// the selected session: hours and minutes from an hour on, a single piece when the second
    /// would be zero. Empty without a duration.
    static func durationPieces(ms: Int?) -> [(value: String, unit: Unit)] {
        guard let ms, ms > 0 else { return [] }
        let seconds = max(ms / 1000, 1)
        let all: [(Int, Unit)] = [(seconds / 3600, .hours), (seconds % 3600 / 60, .minutes), (seconds % 60, .seconds)]
        let leading = all.drop { $0.0 == 0 }.prefix(2)
        return leading.enumerated().compactMap { index, piece in
            index > 0 && piece.0 == 0 ? nil : ("\(piece.0)", piece.1)
        }
    }

    enum Unit: Equatable, Sendable {
        case seconds, minutes, hours

        var title: String {
            switch self {
            case .seconds: String(localized: "sec")
            case .minutes: String(localized: "min")
            case .hours: String(localized: "hr")
            }
        }
    }

    /// When a connection started, absolute (finding one takes the time to the second):
    /// "Today 21:57:32" for today, otherwise the day and the time to the minute, with the year
    /// when it is not this one.
    static func time(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            return String(localized: "Today \(time)")
        }
        let base = Date.FormatStyle.dateTime.month().day().hour().minute()
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? base : base.year())
    }

    /// The last `count` lines of a transcript; empty lines at its end do not count, and the
    /// result does not start with one.
    static func tail(of text: String, lines count: Int) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        while let last = lines.last, last.allSatisfy(\.isWhitespace) {
            lines.removeLast()
        }
        // Nor do empty lines at the start of what is left: the block would open on a blank.
        return lines.suffix(count).drop { $0.allSatisfy(\.isWhitespace) }.joined(separator: "\n")
    }

    /// The end of a saved session: its last `limit` bytes. The panel shows forty lines of it
    /// for every record the selection passes over, and a transcript can be many megabytes.
    static func readEnd(ofFileAt path: String, limit: Int = 256 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        let data = (try? handle.readToEnd()) ?? Data()
        return end(of: data, isCut: start > 0)
    }

    /// The text of the last bytes of a file. Cut out of a longer one, they start in the middle
    /// of a line (maybe of a character): that line is dropped.
    static func end(of data: Data, isCut: Bool) -> String {
        var bytes = data[...]
        if isCut, let newline = bytes.firstIndex(of: 0x0A) {
            bytes = bytes[bytes.index(after: newline)...]
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
