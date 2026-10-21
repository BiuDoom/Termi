import Testing
import Foundation
@testable import Termi

// The hosts page: that a fresh page selects nothing, the "online" filter, Quick Connect's saved
// host and recent addresses, and how the record words its numbers.

private func wp2Host(_ id: Int64, _ label: String, user: String = "tester", address: String = "10.0.0.5",
                     port: Int = 22, lastConnectedAt: String? = nil) -> Termi.Host {
    var host = Termi.Host.defaultValue()
    host.id = id
    host.label = label
    host.username = user
    host.hostname = address
    host.port = port
    host.lastConnectedAt = lastConnectedAt
    return host
}

private func wp2Log(hostId: Int64?, label: String, durationMs: Int? = nil,
                    connectedAt: String = "2026-10-04T10:00:00Z") -> ConnectionLog {
    ConnectionLog(hostId: hostId, hostLabel: label, hostname: "10.0.0.5", status: "disconnected",
                  durationMs: durationMs, connectedAt: connectedAt)
}

@MainActor
@Test func freshPageSelectsNoHost() {
    // The cards stand alone: not the host connected to last, not the first by name.
    let model = HostsViewModel()
    model.hosts = [
        wp2Host(1, "b", lastConnectedAt: "2026-10-01T08:00:00Z"),
        wp2Host(2, "a", lastConnectedAt: "2026-10-04T08:00:00Z"),
        wp2Host(3, "c")
    ]
    #expect(model.selectedHostId == nil)
    #expect(model.selectedHost == nil)
}

@MainActor
@Test func aDeletedSelectionClearsInsteadOfMovingOn() {
    let model = HostsViewModel()
    model.hosts = [wp2Host(1, "a", lastConnectedAt: "2026-10-04T08:00:00Z"), wp2Host(2, "b")]
    model.selectedHostId = 2
    // A reload that still has the host keeps it selected.
    model.hosts = [wp2Host(1, "a", lastConnectedAt: "2026-10-04T08:00:00Z"), wp2Host(2, "b")]
    #expect(model.selectedHostId == 2)
    // It is gone: no other card is outlined in its place.
    model.hosts = [wp2Host(1, "a", lastConnectedAt: "2026-10-04T08:00:00Z")]
    #expect(model.selectedHostId == nil)
}

@Test func onlineFilterKeepsLiveHostsAndDropsEmptyGroups() {
    var group = HostGroup(name: "prod", sortOrder: 0, createdAt: "2026-10-04T10:00:00Z")
    group.id = 7
    let groups: [(group: HostGroup?, hosts: [Termi.Host])] = [
        (nil, [wp2Host(1, "a"), wp2Host(2, "b")]),
        (group, [wp2Host(3, "c")])
    ]
    let online = HostsViewModel.keepingOnline(groups, onlineHostIds: [2])
    #expect(online.count == 1)
    #expect(online.first?.group == nil)
    #expect(online.first?.hosts.map(\.id) == [2])
    #expect(HostsViewModel.keepingOnline(groups, onlineHostIds: []).isEmpty)
}

@Test func quickConnectFindsTheSavedHostAtTheTypedAddress() {
    let hosts = [wp2Host(1, "web", user: "root", address: "Web.Example", port: 2222)]
    #expect(HostsViewModel.savedHost(matching: "root@web.example:2222", in: hosts)?.id == 1)
    // Without a user the address alone decides; a different user is a different connection.
    #expect(HostsViewModel.savedHost(matching: "web.example:2222", in: hosts)?.id == 1)
    #expect(HostsViewModel.savedHost(matching: "deploy@web.example:2222", in: hosts) == nil)
    #expect(HostsViewModel.savedHost(matching: "root@web.example", in: hosts) == nil)
    #expect(HostsViewModel.savedHost(matching: "", in: hosts) == nil)
}

@Test func recentQuickConnectionsAreUnsavedAndOnePerAddress() {
    let logs = [
        wp2Log(hostId: nil, label: "a@h1"),
        wp2Log(hostId: 3, label: "saved"),
        wp2Log(hostId: nil, label: "a@h1"),
        wp2Log(hostId: nil, label: "b@h2"),
        wp2Log(hostId: nil, label: ""),
        wp2Log(hostId: nil, label: "c@h3")
    ]
    #expect(HostsViewModel.recentAdHoc(from: logs).map(\.hostLabel) == ["a@h1", "b@h2", "c@h3"])
    #expect(HostsViewModel.recentAdHoc(from: logs, limit: 2).map(\.hostLabel) == ["a@h1", "b@h2"])
}

@Test func lastConnectedIsANumberAndItsUnit() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(HostDetailFormat.lastConnected(now.addingTimeInterval(-185), now: now).value == "3")
    #expect(HostDetailFormat.lastConnected(now.addingTimeInterval(-185), now: now).unit != nil)
    #expect(HostDetailFormat.lastConnected(now.addingTimeInterval(-10_805), now: now).value == "3")
    // Five days, not two: "the day before yesterday" is one word in some languages.
    #expect(HostDetailFormat.lastConnected(now.addingTimeInterval(-432_005), now: now).value == "5")
    // The edges: under a minute and never are words, a month back is "last month".
    #expect(HostDetailFormat.lastConnected(now.addingTimeInterval(-20), now: now).unit == nil)
    #expect(HostDetailFormat.lastConnected(nil, now: now).unit == nil)
    #expect(HostDetailFormat.lastConnected(now.addingTimeInterval(-3_456_000), now: now).unit == nil)
    // A clock that ran ahead does not produce a negative number.
    #expect(HostDetailFormat.lastConnected(now.addingTimeInterval(90), now: now).unit == nil)
}

@Test func durationsReadAsAClock() {
    #expect(HostDetailFormat.clock(ms: nil) == "—")
    #expect(HostDetailFormat.clock(ms: 0) == "—")
    #expect(HostDetailFormat.clock(ms: 400) == "0:01")
    #expect(HostDetailFormat.clock(ms: 8_000) == "0:08")
    #expect(HostDetailFormat.clock(ms: 252_000) == "4:12")
    #expect(HostDetailFormat.clock(ms: 4_085_000) == "1:08:05")
}

@Test func successRateIsAWholePercentOrNothing() {
    #expect(HostDetailFormat.successPercent(total: 0, failed: 0) == nil)
    #expect(HostDetailFormat.successPercent(total: 12, failed: 3) == 75)
    #expect(HostDetailFormat.successPercent(total: 3, failed: 1) == 67)
    #expect(HostDetailFormat.successPercent(total: 5, failed: 0) == 100)
}

@Test func recentDurationsAreOldestFirstInSeconds() {
    let logs = [
        wp2Log(hostId: 1, label: "a", durationMs: 3_000),
        wp2Log(hostId: 1, label: "a"),
        wp2Log(hostId: 1, label: "a", durationMs: 0),
        wp2Log(hostId: 1, label: "a", durationMs: 2_000),
        wp2Log(hostId: 1, label: "a", durationMs: 1_000)
    ]
    #expect(HostDetailFormat.recentDurations(in: logs) == [1, 2, 3])
    #expect(HostDetailFormat.recentDurations(in: logs, limit: 2) == [2, 3])
}

@Test func theRecordNamesThePortAndTheFirstLine() {
    #expect(HostDetailFormat.fullAddress(of: wp2Host(1, "a", user: "deploy", address: "10.0.12.4")) == "deploy@10.0.12.4:22")
    #expect(HostDetailFormat.fullAddress(of: wp2Host(1, "a", user: "deploy", address: "10.0.12.4", port: 2222))
            == "deploy@10.0.12.4:2222")
    #expect(HostDetailFormat.firstLine(of: "  Permission denied\nmore") == "Permission denied")
    #expect(HostDetailFormat.firstLine(of: "\n") == nil)
    #expect(HostDetailFormat.firstLine(of: nil) == nil)
}

@Test func dayAndTimeNamesTodayAndYesterday() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let now = Date()
    let today = HostDetailFormat.dayAndTime(now, showsSeconds: true, calendar: calendar)
    // Calendar days, not 24 hours: a day with a clock change is shorter or longer.
    let dayBefore = calendar.date(byAdding: .day, value: -1, to: now) ?? now
    let tenDaysBefore = calendar.date(byAdding: .day, value: -10, to: now) ?? now
    let yesterday = HostDetailFormat.dayAndTime(dayBefore, showsSeconds: true, calendar: calendar)
    let older = HostDetailFormat.dayAndTime(tenDaysBefore, showsSeconds: false, calendar: calendar)
    #expect(today != yesterday)
    #expect(today.hasPrefix(String(localized: "Today")))
    #expect(yesterday.hasPrefix(String(localized: "Yesterday")))
    #expect(!older.hasPrefix(String(localized: "Today")) && !older.hasPrefix(String(localized: "Yesterday")))
}

@Test func onlyTheNewestUnfinishedRowsAreOpenSessions() {
    var logs = (1...4).map { index -> ConnectionLog in
        var log = wp2Log(hostId: 1, label: "a", durationMs: index == 2 ? 5_000 : nil)
        log.id = Int64(index)
        return log
    }
    logs[2].status = "failed"
    // Newest first: 1 is open, 2 has ended, 3 failed, 4 never got to close.
    #expect(HostDetailFormat.openLogIds(in: logs, sessionCount: 0).isEmpty)
    #expect(HostDetailFormat.openLogIds(in: logs, sessionCount: 1) == [1])
    #expect(HostDetailFormat.openLogIds(in: logs, sessionCount: 2) == [1, 4])
}

@MainActor
@Test func theOnlineFilterOnlyNarrowsWhileItIsOn() {
    let model = HostsViewModel()
    model.hosts = [wp2Host(1, "a"), wp2Host(2, "b")]
    #expect(model.visibleGroups(onlineHostIds: [2]).flatMap(\.hosts).compactMap(\.id).sorted() == [1, 2])
    model.showsOnlineOnly = true
    #expect(model.visibleGroups(onlineHostIds: [2]).flatMap(\.hosts).compactMap(\.id) == [2])
    // Nothing online: nothing listed (the page says so in words and turns the filter off).
    #expect(model.visibleGroups(onlineHostIds: []).isEmpty)
}

@MainActor
@Test func aTagChipCountsTheHostsThatCarryIt() {
    let model = HostsViewModel()
    let prod = Termi.Tag(id: 1, name: "prod", color: "#3B82F6", createdAt: "2026-10-04T10:00:00Z")
    let db = Termi.Tag(id: 2, name: "db", color: "#3B82F6", createdAt: "2026-10-04T10:00:00Z")
    model.tagsByHost = [1: [prod, db], 2: [prod], 3: []]
    #expect(model.hostCount(forTag: "prod") == 2)
    #expect(model.hostCount(forTag: "db") == 1)
    #expect(model.hostCount(forTag: "none") == 0)
}
