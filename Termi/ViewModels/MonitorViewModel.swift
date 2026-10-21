import SwiftUI
import os.log

/// ViewModel for server monitoring
@Observable
@MainActor
final class MonitorViewModel {
    /// One reading of the selected host, as the trend chart draws it.
    struct Sample: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        /// 0…100
        let cpu: Double
        /// 0…100
        let memory: Double
        /// Bytes per second since the reading before; 0 for the first one.
        let rxRate: Double
        let txRate: Double
    }

    /// Seconds between two readings while auto refresh is on.
    static let refreshInterval: TimeInterval = 5
    /// Five minutes of readings at the refresh interval.
    static let historyLimit = 60

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "MonitorVM")
    private let monitorService = MonitorService()
    private let hostRepo = HostRepository.shared

    var hosts: [Host] = []
    var selectedHost: Host?
    var stats: MonitorService.ServerStats?
    var isLoading = false
    var isAutoRefresh = false
    var error: String?
    /// The readings of the selected host, oldest first.
    private(set) var history: [Sample] = []
    /// The last reading of every host that was read in this window (the host list shows its CPU).
    private(set) var lastStats: [Int64: MonitorService.ServerStats] = [:]

    /// When `stats` was read (the next reading's rates are measured against it).
    @ObservationIgnored private var statsDate: Date?
    /// The host a reading is being fetched from: auto refresh does not pile a second request
    /// onto a host that has not answered the first.
    @ObservationIgnored private var fetching: Host?

    // nonisolated(unsafe) allows cancellation from deinit without @MainActor
    @ObservationIgnored
    nonisolated(unsafe) private var refreshTask: Task<Void, Never>?

    deinit {
        refreshTask?.cancel()
    }

    func loadHosts() async {
        do {
            hosts = try await hostRepo.fetchAll()
        } catch {
            // The page left while its hosts were read (the read is cancelled with it): nothing
            // failed, and the model would keep showing the error when the page comes back.
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            return
        }
        refreshSelectedHost()
    }

    /// The model outlives the page: the selected host may have been edited or deleted on the
    /// Hosts page since it was picked. Readings come from where the saved host points now, not
    /// from the copy taken back then.
    func refreshSelectedHost() {
        guard let selected = selectedHost else { return }
        guard let current = hosts.first(where: { $0.connectionKey == selected.connectionKey }) else {
            stopAutoRefresh()
            selectedHost = nil
            stats = nil
            statsDate = nil
            history = []
            error = nil
            isLoading = false
            return
        }
        if current.isSameTarget(as: selected) {
            // Also when only the detected system changed: the readings are still this host's.
            selectedHost = current
        } else {
            // Another address, user or credentials: the reading is not this host's any more.
            error = nil
            selectHost(current)
        }
    }

    func fetchStats() async {
        guard let host = selectedHost, fetching?.isSameTarget(as: host) != true else { return }
        fetching = host
        defer {
            if fetching?.isSameTarget(as: host) == true { fetching = nil }
        }
        // The error stays while the next attempt runs: with auto-refresh on it would otherwise
        // trade places with the spinner every few seconds.
        isLoading = true

        do {
            let fetched = try await monitorService.fetchStats(host: host)
            // Another host was picked while this one answered: its numbers belong nowhere.
            guard isSelected(host) else { return }
            record(fetched, at: Date())
            if let id = host.id { lastStats[id] = fetched }
            error = nil
        } catch {
            guard isSelected(host) else { return }
            // The last reading stays on screen (the page dims it): numbers that vanish and come
            // back every few seconds are worse than numbers that are a moment old.
            self.error = error.localizedDescription
            // The user dismissed the password prompt: auto refresh would put it back on the
            // window every few seconds. Retry and the switch remain.
            if (error as? SSHError) == .cancelled { stopAutoRefresh() }
        }

        isLoading = false
    }

    /// Takes a reading: it becomes `stats` and the newest sample of the trend.
    func record(_ fetched: MonitorService.ServerStats, at date: Date) {
        var rxRate = 0.0
        var txRate = 0.0
        if let previous = stats, let previousDate = statsDate {
            let seconds = date.timeIntervalSince(previousDate)
            rxRate = Self.rate(previous: previous.networkRx, current: fetched.networkRx, seconds: seconds)
            txRate = Self.rate(previous: previous.networkTx, current: fetched.networkTx, seconds: seconds)
        }
        // After a pause (the page was left, auto refresh was off) the old samples are not the
        // "last five minutes" any more: the trend starts again.
        if let last = history.last, date.timeIntervalSince(last.date) > Self.refreshInterval * 6 {
            history = []
        }
        history.append(Sample(date: date, cpu: Self.clampedPercent(fetched.cpuUsage),
                              memory: Self.clampedPercent(fetched.memPercent), rxRate: rxRate, txRate: txRate))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        stats = fetched
        statsDate = date
    }

    /// Bytes per second between two readings of a counter. A counter that went backwards (it
    /// wrapped, or the host restarted) gives 0, not a negative rate.
    nonisolated static func rate(previous: Int64, current: Int64, seconds: TimeInterval) -> Double {
        guard seconds > 0, current >= previous else { return 0 }
        return Double(current - previous) / seconds
    }

    nonisolated static func clampedPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    /// False once another host was picked — or this one deleted, or saved with other settings —
    /// while it answered.
    private func isSelected(_ host: Host) -> Bool {
        selectedHost?.isSameTarget(as: host) == true
    }

    func startAutoRefresh(interval: TimeInterval = MonitorViewModel.refreshInterval) {
        // Cancel any existing refresh loop before starting a new one
        refreshTask?.cancel()
        isAutoRefresh = true
        refreshTask = Task { [weak self] in
            while !Task.isCancelled, self?.isAutoRefresh == true {
                await self?.fetchStats()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopAutoRefresh() {
        isAutoRefresh = false
        refreshTask?.cancel()
        refreshTask = nil
    }

    func selectHost(_ host: Host) {
        selectedHost = host
        stats = nil
        statsDate = nil
        history = []
        error = nil
        Task { await fetchStats() }
    }

    #if DEBUG
    /// `-debugMonitorHistory YES`: five minutes of made-up readings in front of the real ones,
    /// so that a screenshot shows the trend chart as it looks after five minutes.
    func debugSeedHistory(now: Date = Date()) {
        var state: UInt64 = 7
        func noise() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33 % 1000) / 1000 - 0.5
        }
        var cpu = 13.0
        history = (0..<(Self.historyLimit - 4)).map { index in
            cpu += noise() * 9 + (13 - cpu) * 0.25
            let spike: Double = [22: 9, 23: 36, 24: 52, 25: 40, 26: 18, 44: 14][index] ?? 0
            let date = now.addingTimeInterval(-Self.refreshInterval * Double(Self.historyLimit - 4 - index))
            return Sample(date: date, cpu: Self.clampedPercent(cpu + spike), memory: 38 + noise() * 1.4 + (index > 24 ? 2 : 0),
                          rxRate: max(0, 800_000 + noise() * 700_000 + spike * 30_000),
                          txRate: max(0, 60_000 + noise() * 50_000 + spike * 2_500))
        }
    }
    #endif
}

extension Host {
    /// True when `other` is this host connecting the same way. Unlike `isSameSave(as:)` it looks
    /// past the system that is read after a connection: the tools pages connect, the system is
    /// stored a moment later, and that must not count as "the host was edited".
    func isSameTarget(as other: Host) -> Bool {
        var copy = self
        copy.osId = other.osId
        copy.osName = other.osName
        copy.osArch = other.osArch
        copy.osDetectedAt = other.osDetectedAt
        return copy.isSameSave(as: other)
    }
}
