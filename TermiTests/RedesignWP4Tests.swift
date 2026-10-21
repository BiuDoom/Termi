import Testing
import Foundation
@testable import Termi

// The logic behind the data pages (monitoring, Docker, history): samples and rates, how numbers
// are written, what a list of containers or of connections adds up to.

// MARK: - Monitoring

private func reading(cpu: Double = 10, memory: Double = 40, rx: Int64 = 0, tx: Int64 = 0) -> MonitorService.ServerStats {
    var stats = MonitorService.ServerStats()
    stats.cpuUsage = cpu
    stats.memPercent = memory
    stats.networkRx = rx
    stats.networkTx = tx
    return stats
}

private func savedHost(id: Int64) -> Termi.Host {
    var host = Host.defaultValue()
    host.id = id
    host.label = "staging"
    host.hostname = "10.0.0.5"
    return host
}

@Test func networkRateIsBytesPerSecondAndNeverNegative() {
    #expect(MonitorViewModel.rate(previous: 1000, current: 6000, seconds: 5) == 1000)
    // The counter wrapped or the host restarted.
    #expect(MonitorViewModel.rate(previous: 6000, current: 1000, seconds: 5) == 0)
    #expect(MonitorViewModel.rate(previous: 1000, current: 6000, seconds: 0) == 0)
}

@Test @MainActor func aReadingBecomesASampleWithItsRates() {
    let viewModel = MonitorViewModel()
    let start = Date(timeIntervalSince1970: 1_000_000)
    viewModel.record(reading(cpu: 12, memory: 41, rx: 10_000, tx: 500), at: start)
    viewModel.record(reading(cpu: 140, memory: -3, rx: 20_000, tx: 400), at: start.addingTimeInterval(5))

    #expect(viewModel.history.count == 2)
    // The first reading has nothing to be measured against.
    #expect(viewModel.history[0].rxRate == 0)
    #expect(viewModel.history[1].rxRate == 2000)
    #expect(viewModel.history[1].txRate == 0)
    // Out-of-range percentages do not leave the chart's scale.
    #expect(viewModel.history[1].cpu == 100)
    #expect(viewModel.history[1].memory == 0)
    #expect(viewModel.stats?.networkRx == 20_000)
}

@Test @MainActor func theTrendKeepsFiveMinutesAndStartsAgainAfterAPause() {
    let viewModel = MonitorViewModel()
    let start = Date(timeIntervalSince1970: 1_000_000)
    for index in 0..<(MonitorViewModel.historyLimit + 10) {
        viewModel.record(reading(cpu: Double(index)), at: start.addingTimeInterval(Double(index) * 5))
    }
    #expect(viewModel.history.count == MonitorViewModel.historyLimit)
    #expect(viewModel.history.first?.cpu == 10)

    // Ten minutes later: the old samples are not "the last five minutes".
    viewModel.record(reading(cpu: 1), at: start.addingTimeInterval(Double(MonitorViewModel.historyLimit + 10) * 5 + 600))
    #expect(viewModel.history.count == 1)
}

@Test @MainActor func aDetectedSystemDoesNotCountAsAnEditedHost() {
    let viewModel = MonitorViewModel()
    let picked = savedHost(id: 7)
    viewModel.selectedHost = picked
    viewModel.record(reading(), at: Date())

    // The system is stored a moment after the page connected.
    var current = picked
    current.osId = "ubuntu"
    current.osName = "Ubuntu 24.04.1 LTS"
    current.osArch = "aarch64"
    current.osDetectedAt = "2026-10-05T01:00:00Z"
    viewModel.hosts = [current]
    viewModel.refreshSelectedHost()

    #expect(viewModel.selectedHost == current)
    #expect(viewModel.stats != nil)
    #expect(viewModel.history.count == 1)
    #expect(current.isSameTarget(as: picked))

    var moved = current
    moved.hostname = "10.0.0.9"
    #expect(!moved.isSameTarget(as: picked))
}

@Test @MainActor func dockerKeepsItsContainersWhenOnlyTheSystemWasDetected() {
    let viewModel = DockerViewModel()
    let picked = savedHost(id: 7)
    viewModel.selectedHost = picked
    viewModel.containers = [DockerService.Container(id: "4f1c2a9be0d3", name: "web", image: "nginx",
                                                    status: "Up 2 hours", ports: "", created: "")]
    var current = picked
    current.osId = "debian"
    viewModel.hosts = [current]
    viewModel.refreshSelectedHost()

    #expect(viewModel.selectedHost == current)
    #expect(viewModel.containers.count == 1)
}

@Test func monitoringWritesAmountsWithTheUnitOnce() {
    let gib: Int64 = 1024 * 1024 * 1024
    let decimal = String(format: "%.1f", locale: .current, 3.5)
    #expect(MonitorFormat.pair(used: gib * 7 / 2, total: gib * 8) == "\(decimal) / \(String(format: "%.1f", locale: .current, 8.0)) GB")
    #expect(MonitorFormat.pair(used: gib * 49, total: gib * 78) == "49 / 78 GB")
    // 28 GB of 1.4 TB would read "0.0": each amount gets its own unit.
    #expect(MonitorFormat.pair(used: gib * 28, total: gib * 1434).hasPrefix("28 GB / "))
    #expect(MonitorFormat.pair(used: 0, total: 0) == "—")
    #expect(MonitorFormat.bytes(gib * 29) == "29 GB")
    #expect(MonitorFormat.percent(11.6) == "12%")
    #expect(MonitorFormat.percent(250) == "100%")
}

@Test func monitoringWritesRatesAsNumberAndUnit() {
    #expect(MonitorFormat.rate(316).value == "316")
    #expect(MonitorFormat.rate(316).unit == "B/s")
    #expect(MonitorFormat.rate(86_016).value == "84")
    #expect(MonitorFormat.rate(86_016).unit == "KB/s")
    #expect(MonitorFormat.rate(1_310_720).unit == "MB/s")
    #expect(MonitorFormat.rate(-5).value == "0")
    #expect(MonitorFormat.rate(.nan).value == "0")
}

@Test func uptimeIsReadFromWhatTheHostPrinted() {
    #expect(MonitorFormat.uptimeSeconds(" 22:01:39 up 41 days,  3:12,  1 user,  load average: 0.42, 0.31, 0.18")
            == 3_553_920)
    #expect(MonitorFormat.uptimeSeconds(" 10:00:00 up 5 min,  2 users,  load average: 0.00, 0.00, 0.00") == 300)
    #expect(MonitorFormat.uptimeSeconds(" 10:00:00 up 1 day, 2 min,  0 users,  load average: 0.00") == 86_520)
    #expect(MonitorFormat.uptimeSeconds("10:00  up 3:04, 2 users, load averages: 1.20 1.10 1.00") == 11_040)
    #expect(MonitorFormat.uptimeSeconds("no such thing") == nil)
    // What cannot be read is shown as it came.
    #expect(MonitorFormat.uptimeText("no such thing") == "no such thing")
    #expect(MonitoringView.uptimeSummary(" 22:01:39 up 41 days,  3:12,  1 user,  load average: 0.42") == "41 days, 3:12")
}

@Test func thePeakIsNamedOnlyWhenItStandsOut() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    func samples(_ cpu: [Double]) -> [MonitorViewModel.Sample] {
        cpu.enumerated().map { index, value in
            MonitorViewModel.Sample(date: start.addingTimeInterval(Double(index) * 5), cpu: value, memory: 40,
                                    rxRate: 0, txRate: 0)
        }
    }
    #expect(MonitorFormat.peak(of: samples([10, 64, 12]))?.cpu == 64)
    // The newest reading is the peak: the legend already says it.
    #expect(MonitorFormat.peak(of: samples([10, 12, 64])) == nil)
    // Flat.
    #expect(MonitorFormat.peak(of: samples([10, 12, 11])) == nil)
    #expect(MonitorFormat.peak(of: samples([10, 64])) == nil)

    // The time axis is at least a minute wide.
    let domain = MonitorFormat.timeDomain(of: samples([1, 2, 3]))
    #expect(domain.upperBound.timeIntervalSince(domain.lowerBound) == 60)
    let long = MonitorFormat.timeDomain(of: samples(Array(repeating: 1, count: 60)))
    #expect(long.upperBound.timeIntervalSince(long.lowerBound) == 295)
}

@Test func toolsPagesListHostsByGroup() {
    var first = savedHost(id: 1)
    first.groupId = 20
    var second = savedHost(id: 2)
    second.groupId = 10
    var orphan = savedHost(id: 3)
    orphan.groupId = 99
    let loose = savedHost(id: 4)
    let groups = [
        HostGroup(id: 10, name: "prod", sortOrder: 0, createdAt: ""),
        HostGroup(id: 20, name: "staging", sortOrder: 1, createdAt: ""),
        HostGroup(id: 30, name: "empty", sortOrder: 2, createdAt: "")
    ]

    let sections = ToolsHostSections.make(hosts: [first, second, orphan, loose], groups: groups)
    #expect(sections.map { $0.group?.name } == ["prod", "staging", nil])
    #expect(sections.map { $0.hosts.compactMap(\.id) } == [[2], [1], [3, 4]])

    // No groups in use: one unnamed section.
    let flat = ToolsHostSections.make(hosts: [loose], groups: groups)
    #expect(flat.count == 1)
    #expect(flat.first?.group == nil)
    #expect(ToolsHostSections.make(hosts: [], groups: groups).isEmpty)
}

// MARK: - Docker

private func container(_ name: String, image: String = "nginx", status: String, ports: String = "") -> DockerService.Container {
    DockerService.Container(id: name, name: name, image: image, status: status, ports: ports, created: "")
}

@Test func publishedPortsBecomeShortLabels() {
    #expect(DockerService.Container.portLabels(from: "0.0.0.0:80->80/tcp, :::80->80/tcp, [::]:80->80/tcp") == ["80→80"])
    #expect(DockerService.Container.portLabels(from: "127.0.0.1:8080->8080/tcp") == ["127.0.0.1:8080→8080"])
    #expect(DockerService.Container.portLabels(from: "6379/tcp, 53/udp") == ["6379", "53/udp"])
    #expect(DockerService.Container.portLabels(from: "").isEmpty)
    #expect(DockerService.Container.portLabels(from: " , ").isEmpty)
}

@Test func containersAddUpToRunningStoppedAndImages() {
    let summary = DockerSummary([
        container("nginx", status: "Up 3 days"),
        container("api", image: "acme/api", status: "Up 3 days (Paused)"),
        container("migrate", image: "acme/api", status: "Exited (0) 3 days ago"),
        container("fresh", image: "redis", status: "Created")
    ])
    #expect(summary.running == ["nginx", "api"])
    #expect(summary.stopped == ["migrate", "fresh"])
    #expect(summary.total == 4)
    #expect(summary.images == 3)

    #expect(container("api", status: "Up 3 days (Paused)").phase == .transitional)
    #expect(container("api", status: "Restarting (1) 5 seconds ago").phase == .transitional)
    #expect(container("api", status: "Exited (0) 3 days ago").phase == .stopped)
    #expect(container("api", status: "Up 2 hours").phase == .running)

    #expect(DockerSummary.names(["a", "b", "c", "d", "e"]) == "a · b · c +2")
    #expect(DockerSummary.names(["a"]) == "a")
    #expect(DockerSummary.names([]) == nil)
}

// MARK: - History

private func record(_ label: String, hostId: Int64? = nil, status: String = "disconnected", error: String? = nil,
                    durationMs: Int? = nil, at connectedAt: String, ended: String? = nil) -> ConnectionLog {
    ConnectionLog(id: nil, hostId: hostId, hostLabel: label, hostname: "10.0.0.5", status: status,
                  errorMessage: error, durationMs: durationMs, connectedAt: connectedAt, disconnectedAt: ended)
}

@Test func aRecordIsMarkedByHowItWent() {
    #expect(record("web", status: "failed", at: "2026-10-04T10:00:00Z").outcome == .failed)
    #expect(record("web", status: "connected", at: "2026-10-04T10:00:00Z").outcome == .inProgress)
    // Connected, and its end was recorded: over.
    #expect(record("web", status: "connected", durationMs: 4000, at: "2026-10-04T10:00:00Z").outcome == .succeeded)
    #expect(record("web", status: "connected", at: "2026-10-04T10:00:00Z", ended: "2026-10-04T10:05:00Z").outcome == .succeeded)
    #expect(record("web", at: "2026-10-04T10:00:00Z").outcome == .succeeded)

    #expect(record("web", error: "Permission denied (publickey)\nsecond line", at: "").errorSummary
            == "Permission denied (publickey)")
    #expect(record("web", error: "  \n", at: "").errorSummary == nil)
    #expect(record("", at: "").displayName == "10.0.0.5")
}

@Test func theHistoryAddsUp() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(TimestampFormatter.date(from: "2026-10-04T22:00:00Z"))
    let logs = [
        record("web-01", hostId: 1, durationMs: 60_000, at: "2026-10-04T09:00:00Z"),
        record("web", hostId: 1, durationMs: 240_000, at: "2026-10-03T09:00:00Z"),
        record("bastion", hostId: 2, durationMs: nil, at: "2026-10-04T10:00:00Z"),
        record("root@198.51.100.7", status: "failed", error: "timed out", at: "2026-10-04T11:00:00Z"),
        record("old", hostId: 3, at: "2026-07-01T11:00:00Z")
    ]
    let summary = HistorySummary(logs, now: now, calendar: calendar)

    #expect(summary.stats.total == 5)
    #expect(summary.stats.failed == 1)
    #expect(summary.today == 3)
    #expect(summary.days.count == 30)
    #expect(summary.days.reduce(0) { $0 + $1.total } == 4)
    #expect(summary.longestDurationMs == 240_000)
    // Oldest first, in seconds; records without a duration are left out.
    #expect(summary.durations == [240, 60])
    // Counted by host id, named as at its latest connection.
    #expect(summary.top?.name == "web-01")
    #expect(summary.top?.hostId == 1)
    #expect(summary.top?.count == 2)
    #expect(summary.top?.share == 40)

    let empty = HistorySummary([], now: now, calendar: calendar)
    #expect(empty.top == nil)
    #expect(empty.today == 0)
    #expect(empty.longestDurationMs == nil)
}

@Test func aTieForTheMostConnectedHostGoesToTheLatest() throws {
    let now = try #require(TimestampFormatter.date(from: "2026-10-04T22:00:00Z"))
    let logs = [
        record("a", hostId: 1, at: "2026-10-04T09:00:00Z"),
        record("b", hostId: 2, at: "2026-10-04T10:00:00Z")
    ]
    #expect(HistorySummary(logs, now: now).top?.name == "b")
    #expect(HistorySummary(logs.reversed(), now: now).top?.name == "b")
}

@Test func durationsForANumberCardAreOneNumberAndItsUnit() {
    #expect(HistoryFormat.durationParts(ms: nil) == nil)
    #expect(HistoryFormat.durationParts(ms: 0) == nil)
    #expect(HistoryFormat.durationParts(ms: 400)?.value == "1")
    #expect(HistoryFormat.durationParts(ms: 43_000)?.value == "43")
    #expect(HistoryFormat.durationParts(ms: 43_000)?.unit == .seconds)
    #expect(HistoryFormat.durationParts(ms: 252_000)?.value == "4")
    #expect(HistoryFormat.durationParts(ms: 252_000)?.unit == .minutes)
    #expect(HistoryFormat.durationParts(ms: 7_200_000)?.unit == .hours)
    #expect(HistoryFormat.durationPieces(ms: nil).isEmpty)
    #expect(HistoryFormat.durationPieces(ms: 252_000).map(\.value) == ["4", "12"])
    #expect(HistoryFormat.durationPieces(ms: 252_000).map(\.unit) == [.minutes, .seconds])
    #expect(HistoryFormat.durationPieces(ms: 43_900).map(\.value) == ["43"])
    #expect(HistoryFormat.durationPieces(ms: 120_000).map(\.value) == ["2"])
    #expect(HistoryFormat.durationPieces(ms: 4_110_000).map(\.unit) == [.hours, .minutes])
    #expect(HistoryFormat.durationPieces(ms: 3_605_000).map(\.value) == ["1"])
}

@Test func theEndOfATranscriptIsItsLastLines() {
    #expect(HistoryFormat.tail(of: "a\nb\nc\nd\n\n  \n", lines: 2) == "c\nd")
    #expect(HistoryFormat.tail(of: "a\nb", lines: 40) == "a\nb")
    // An empty line inside the output is output.
    #expect(HistoryFormat.tail(of: "a\n\nb", lines: 2) == "b")
    #expect(HistoryFormat.tail(of: "a\n\nb", lines: 3) == "a\n\nb")
    #expect(HistoryFormat.tail(of: "\n\n", lines: 40) == "")
    #expect(HistoryFormat.tail(of: "", lines: 40) == "")
}

@Test func theEndOfALongTranscriptStartsAtAWholeLine() {
    // Cut out of a longer file: what is left of the line the cut fell into is dropped.
    #expect(HistoryFormat.end(of: Data("lf line\nwhole\nlast".utf8), isCut: true) == "whole\nlast")
    // The whole file: nothing is dropped.
    #expect(HistoryFormat.end(of: Data("first\nlast".utf8), isCut: false) == "first\nlast")
    // One long line (a full-screen program): kept as it is.
    #expect(HistoryFormat.end(of: Data("no newline".utf8), isCut: true) == "no newline")
    #expect(HistoryFormat.end(of: Data(), isCut: true) == "")
    #expect(HistoryFormat.readEnd(ofFileAt: "/nonexistent/termi-transcript") == nil)
}

@Test func timesOfOtherDaysCarryTheDayAndOfOtherYearsTheYear() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 22)))
    let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 9, minute: 2, second: 17)))
    let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 19, minute: 35)))
    let lastYear = try #require(calendar.date(from: DateComponents(year: 2025, month: 10, day: 3, hour: 19, minute: 35)))

    // Today's carries the seconds; the words around them are the interface language's.
    #expect(HistoryFormat.time(today, now: now, calendar: calendar).contains("17"))
    #expect(!HistoryFormat.time(yesterday, now: now, calendar: calendar).contains("2026"))
    #expect(HistoryFormat.time(lastYear, now: now, calendar: calendar).contains("2025"))
    #expect(HistoryFormat.time(yesterday, now: now, calendar: calendar) != HistoryFormat.time(lastYear, now: now, calendar: calendar))
}

@Test func aSmallTrendIsNotScaledToItsOwnRipple() {
    // 0 % → 1 % stays near the bottom of a ten-point scale.
    #expect(MonitorFormat.percentRange(of: [0, 1, 0]) == 0...10)
    // A steady reading sits in the middle of its scale.
    #expect(MonitorFormat.percentRange(of: [41, 41]) == 36...46)
    #expect(MonitorFormat.percentRange(of: [99.5, 100]).upperBound == 100)
    // A real swing keeps the readings' own range.
    #expect(MonitorFormat.percentRange(of: [10, 60]) == DSSparkline.domain(for: [10, 60]))
    #expect(MonitorFormat.rateRange(of: []) == 0...1)
    #expect(MonitorFormat.rateRange(of: [100, 200]).lowerBound == 0)
    #expect(MonitorFormat.rateRange(of: [100, 200]).upperBound > 200)
}
