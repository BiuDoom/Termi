import Testing
import Foundation
@testable import Termi

// What the vault and data pages show only when it adds something: a group header over several
// addresses, a first-trust date that differs, counts that are not already on the screen.

private func known(_ id: Int64, _ hostname: String, fingerprint: String = "SHA256:aaaa",
                   addedAt: String) -> KnownHost {
    KnownHost(id: id, hostname: hostname, port: 22, keyType: "ssh-ed25519", publicKey: "ssh-ed25519 AAAA",
              fingerprint: fingerprint, addedAt: addedAt)
}

private func record(_ label: String, status: String = "disconnected", durationMs: Int? = nil,
                    at connectedAt: String) -> ConnectionLog {
    ConnectionLog(id: nil, hostId: nil, hostLabel: label, hostname: "10.0.0.5", status: status,
                  errorMessage: nil, durationMs: durationMs, connectedAt: connectedAt, disconnectedAt: nil)
}

private func container(_ name: String, image: String, status: String) -> DockerService.Container {
    DockerService.Container(id: name, name: name, image: image, status: status, ports: "", created: "")
}

@Test func aHostKeyWithOneAddressHasNoGroupHeader() {
    let single = KnownHostGroup(fingerprint: "SHA256:aaaa", entries: [known(1, "web-02", addedAt: "2026-10-03T05:00:00Z")])
    let several = KnownHostGroup(fingerprint: "SHA256:bbbb", entries: [
        known(2, "10.0.12.4", fingerprint: "SHA256:bbbb", addedAt: "2026-10-03T05:00:00Z"),
        known(3, "web-01.example.com", fingerprint: "SHA256:bbbb", addedAt: "2026-10-03T11:00:00Z")
    ])
    let singleHasHeader = KnownHostsViewModel.showsGroupHeader(for: single)
    let severalHaveHeader = KnownHostsViewModel.showsGroupHeader(for: several)
    #expect(!singleHasHeader)
    #expect(severalHaveHeader)
}

@Test func theFirstTrustIsNamedOnlyForALaterAddress() {
    let first = known(2, "10.0.12.4", addedAt: "2026-10-03T05:00:00Z")
    let later = known(3, "web-01.example.com", addedAt: "2026-10-03T11:00:00Z")
    let sameMoment = known(4, "localhost", addedAt: "2026-10-03T05:00:00Z")
    let group = KnownHostGroup(fingerprint: "SHA256:aaaa", entries: [first, later, sameMoment])

    let ofFirst = KnownHostsViewModel.earlierFirstTrust(of: first, in: group)
    let ofLater = KnownHostsViewModel.earlierFirstTrust(of: later, in: group)
    let ofSameMoment = KnownHostsViewModel.earlierFirstTrust(of: sameMoment, in: group)
    #expect(ofFirst == nil)
    #expect(ofLater == "2026-10-03T05:00:00Z")
    #expect(ofSameMoment == nil)
}

@Test func theThirtyDayCountIsWrittenOnlyWhenItIsNotTheTotal() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(TimestampFormatter.date(from: "2026-10-04T22:00:00Z"))
    let recent = [
        record("web", durationMs: 60_000, at: "2026-10-04T09:00:00Z"),
        record("web", durationMs: 60_000, at: "2026-10-03T09:00:00Z")
    ]
    let allRecent = HistorySummary(recent, now: now, calendar: calendar)
    let withAnOldOne = HistorySummary(recent + [record("old", at: "2026-07-01T11:00:00Z")], now: now, calendar: calendar)

    let countOfAllRecent = allRecent.recentCountIfPartial
    let countWithAnOldOne = withAnOldOne.recentCountIfPartial
    #expect(countOfAllRecent == nil)
    #expect(countWithAnOldOne == 2)
}

@Test func theActivityLegendNeedsAFailureInTheWindow() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(TimestampFormatter.date(from: "2026-10-04T22:00:00Z"))
    let fine = HistorySummary([record("web", at: "2026-10-04T09:00:00Z")], now: now, calendar: calendar)
    let oldFailure = HistorySummary([record("web", at: "2026-10-04T09:00:00Z"),
                                     record("web", status: "failed", at: "2026-07-01T09:00:00Z")],
                                    now: now, calendar: calendar)
    let failedToday = HistorySummary([record("web", status: "failed", at: "2026-10-04T09:00:00Z")],
                                     now: now, calendar: calendar)

    let fineHasFailures = fine.hasRecentFailures
    let oldHasFailures = oldFailure.hasRecentFailures
    let todayHasFailures = failedToday.hasRecentFailures
    #expect(!fineHasFailures)
    #expect(!oldHasFailures)
    #expect(todayHasFailures)
}

@Test func theNumberCardsLeaveAMissingCardsRoomToTheChart() {
    let four = HistoryFormat.bandWidth(cards: 4)
    let three = HistoryFormat.bandWidth(cards: 3)
    #expect(four == 590)
    #expect(three == 440)
}

@Test func stoppedContainersAreLeftOutWhenTheHostWasNotAskedForThem() {
    let summary = DockerSummary([
        container("nginx", image: "nginx:1.27", status: "Up 3 days"),
        container("migrate", image: "api:2.4.1", status: "Exited (0) 3 days ago")
    ])
    let all = summary.headline(includesStopped: true).components(separatedBy: " · ")
    let runningOnly = summary.headline(includesStopped: false).components(separatedBy: " · ")
    #expect(all.count == 3)
    #expect(runningOnly.count == 2)
    // Running first, images last, in both.
    #expect(all.first == runningOnly.first)
    #expect(all.last == runningOnly.last)
}

@Test func theCPUGaugeNamesTheProcessesOnceTheHostSaidThem() {
    let unknown = MonitorFormat.cpuDetail(processes: nil)
    let none = MonitorFormat.cpuDetail(processes: 0)
    let some = MonitorFormat.cpuDetail(processes: 148)
    #expect(unknown == "—")
    #expect(none == "—")
    #expect(some.contains("148"))
}
