import Testing
import Foundation
import SwiftUI
@testable import Termi

// The logic behind the shared components in Theme/: the fingerprint image, connection statistics,
// the per-day buckets and bar heights of the activity chart, jump routes, avatar states, level
// colours, the operating-system lookup, the scale of trend lines.

// MARK: - Randomart

// Truth from the real tool: `ssh-keygen -lv -f <key>.pub` (OpenSSH 10.3) on eight throwaway keys
// (ED25519, RSA 2048 / 3072, ECDSA 256 / 521), the nine lines inside the frame.

private let randomartSamples: [(fingerprint: String, art: [String])] = [
    ("SHA256:UXdTqQ5eYjWgM1NMEAXkxO/PvLHjkPJ5gxclG58Fttc", [
        "        o*O=o o.o",
        "        oooo +oo ",
        "        .*. ..oo.",
        "         .+= =..E",
        "        S + = *.o",
        "           o.+ o ",
        "         . o=..  ",
        "          o.oOo  ",
        "           o+++  "
    ]),
    ("SHA256:f+nj62iZv0WHcIdMHtP3vDSr3eA/U2eSujrTBqutOZU", [
        "              +. ",
        "             + +o",
        "            . =.+",
        "             o =o",
        "        S  .  +.=",
        "         .E  o+++",
        "         ..*oo+++",
        "        .oB+=o.+.",
        "        +=+OO= .+"
    ]),
    ("SHA256:Gwi/Zq7EPpZtuAMX3Nls5M3OkmImKHKkBj2fAi2xuyU", [
        "                 ",
        ".       .        ",
        " = ... * o       ",
        "= = ooo.= o      ",
        ".* + oo.S+       ",
        "E.*.= +.ooo      ",
        "o* +oB+...       ",
        ".  o*+o          ",
        "   .+*.          "
    ]),
    // RSA 2048: the picture depends on the digest only, not on the key type.
    ("SHA256:J2NmN1kY3L5CjTTiVCDPJIGOJyMxIy2Eh39HkGNBQM4", [
        "o=oo+=+.o+o.     ",
        "Ooo = .*o +o.    ",
        ".BE+ o ooo.=.    ",
        ". = + . . ooo    ",
        " . = .  S.=  .   ",
        "       + =...    ",
        "           .     ",
        "                 ",
        "                 "
    ]),
    // RSA 3072.
    ("SHA256:xB5xetCBamSTig8gmcV6I4IUK+VWt9FSrP200hOZcNs", [
        " *+ . o=+oo.     ",
        "=+o. .*+==o      ",
        "=+o. +.*=o.=     ",
        "*.= . +o.o* E    ",
        ".o + .  S+ o     ",
        "    .   . =      ",
        "         . .     ",
        "                 ",
        "                 "
    ]),
    // ECDSA 256: the fingerprint has "+" and "/" in it.
    ("SHA256:3vThAFr7QQNFnaNKm0JvienzCjte2XljHUFxIm//+ek", [
        "        .o+.+o.  ",
        "         . ++o   ",
        "        o o.+.   ",
        "      .o.+.o o   ",
        "     ..=S=+ o .  ",
        "      ++B= * o ..",
        "    ..oo+ * +  ..",
        "    .+o  o .    o",
        "   .o..+.     .E."
    ]),
    // ECDSA 521.
    ("SHA256:phEQxEVJziQEZxw5Am5LjclIhnu4nSyltm2c4v2q0p0", [
        "o+.*XB=.         ",
        "B =o=*.          ",
        ".X o .+          ",
        "= +    .         ",
        " O .  . S        ",
        "+.+    +         ",
        ".o+....          ",
        ".oo=E            ",
        "oo+oo.           "
    ]),
    // ED25519.
    ("SHA256:cbYJW7JWjJHIVMt2hr7AV3oXeleVeKf73uC6Hcb1tF0", [
        "     o.oo.    . o",
        "      o..*   . oo",
        "        X X . ..o",
        "     . o / + ... ",
        "      o S = o ..E",
        "       + o o o.o=",
        "        .     =oo",
        "             + oo",
        "            ooo.o"
    ])
]

@Test func randomartMatchesSSHKeygen() {
    for sample in randomartSamples {
        let art = Randomart(fingerprint: sample.fingerprint)
        #expect(art?.ascii == sample.art.joined(separator: "\n"), "\(sample.fingerprint)")
    }
}

@Test func randomartReadsTheFingerprintOutOfAKeygenLine() {
    let sample = randomartSamples[0]
    let line = "256 \(sample.fingerprint) probe1 (ED25519)"
    #expect(Randomart(fingerprint: line) == Randomart(fingerprint: sample.fingerprint))
    #expect(Randomart(fingerprint: line)?.ascii == sample.art.joined(separator: "\n"))
    // ssh's own prompt ends the fingerprint with a full stop.
    let prompt = "ED25519 key fingerprint is \(sample.fingerprint).\nAre you sure you want to continue connecting?"
    #expect(Randomart(fingerprint: prompt) == Randomart(fingerprint: sample.fingerprint))
}

@Test func randomartGeometry() throws {
    let art = try #require(Randomart(fingerprint: randomartSamples[0].fingerprint))
    #expect(art.cells.count == Randomart.columns * Randomart.rows)
    #expect(art.start == 4 * Randomart.columns + 8)
    #expect(art.cells.allSatisfy { $0 <= 14 })
    // 32 digest bytes, four moves each.
    #expect(art.cells.reduce(0) { $0 + Int($1) } == 128)
}

@Test func randomartRefusesWhatIsNotASHA256Fingerprint() {
    #expect(Randomart(fingerprint: "MD5:aa:bb") == nil)
    #expect(Randomart(fingerprint: "SHA256:!!!") == nil)
    #expect(Randomart(fingerprint: "SHA256:") == nil)
    // Base64, but not the 32 bytes of a SHA-256 digest: no picture rather than a made-up one.
    #expect(Randomart(fingerprint: "SHA256:abcd") == nil)
    #expect(Randomart(fingerprint: "SHA256:UXdTqQ5eYjWgM1NMEAXkxO/PvLHjkPJ5gxclG58F") == nil)
    #expect(Randomart(fingerprint: "") == nil)
}

// MARK: - Connection statistics

private func makeLog(status: String = "disconnected", durationMs: Int? = nil,
                     connectedAt: String = "2026-10-04T08:00:00Z") -> ConnectionLog {
    ConnectionLog(hostId: 1, hostLabel: "test-a", hostname: "10.0.0.5", status: status,
                  durationMs: durationMs, connectedAt: connectedAt)
}

@Test func logStatsWithoutDataShowDashes() {
    let stats = DSLogStats([])
    #expect(stats.total == 0)
    #expect(stats.failed == 0)
    #expect(stats.averageDurationMs == nil)
    #expect(stats.totalText == "—")
    #expect(stats.successRateText == "—")
    #expect(stats.averageDurationText == "—")
}

@Test func logStatsAverageSkipsMissingDurations() {
    let stats = DSLogStats([
        makeLog(durationMs: nil),
        makeLog(durationMs: 0),
        makeLog(durationMs: 60_000),
        makeLog(durationMs: 120_000)
    ])
    #expect(stats.total == 4)
    #expect(stats.averageDurationMs == 90_000)
    #expect(stats.averageDurationText != "—")

    // Old records carry no duration at all: a dash, never a zero.
    let old = DSLogStats([makeLog(durationMs: nil), makeLog(durationMs: 0)])
    #expect(old.averageDurationMs == nil)
    #expect(old.averageDurationText == "—")
}

@Test func logStatsSuccessRate() {
    let stats = DSLogStats([makeLog(), makeLog(status: "failed"), makeLog(status: "connected")])
    #expect(stats.total == 3)
    #expect(stats.failed == 1)
    #expect(stats.totalText == "3")
    #expect(stats.successRateText.contains("67"))
    #expect(DSLogStats([makeLog(status: "Error")]).failed == 1)
}

@Test func logStatsDurationText() {
    #expect(DSLogStats.durationText(ms: nil) == "—")
    #expect(DSLogStats.durationText(ms: 0) == "—")
    #expect(DSLogStats.durationText(ms: -5) == "—")
    // Below a second still reads as a duration, not as nothing.
    #expect(DSLogStats.durationText(ms: 400) == DSLogStats.durationText(ms: 1000))
    #expect(DSLogStats.durationText(ms: 400) != "—")
}

// MARK: - Activity chart

@Test func activityChartDaysAreContiguousAndAscending() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(TimestampFormatter.date(from: "2026-10-04T12:00:00Z"))
    let logs = [
        makeLog(connectedAt: "2026-10-04T08:00:00Z"),
        makeLog(status: "failed", connectedAt: "2026-10-03T23:59:00Z"),
        makeLog(connectedAt: "2026-10-01T00:00:00Z"),
        makeLog(connectedAt: "2026-10-01T10:00:00Z"),
        makeLog(status: "failed", connectedAt: "2026-10-01T11:00:00Z"),
        // Outside the window, and not a date at all.
        makeLog(connectedAt: "2026-09-01T10:00:00Z"),
        makeLog(connectedAt: "yesterday")
    ]

    let days = DSActivityChart.days(from: logs, count: 7, now: now, calendar: calendar)

    #expect(days.count == 7)
    #expect(days.map(\.date) == days.map(\.date).sorted())
    #expect(days.first?.date == TimestampFormatter.date(from: "2026-09-28T00:00:00Z"))
    #expect(days.last?.date == TimestampFormatter.date(from: "2026-10-04T00:00:00Z"))
    #expect(days.map(\.succeeded) == [0, 0, 0, 2, 0, 0, 1])
    #expect(days.map(\.failed) == [0, 0, 0, 1, 0, 1, 0])
}

@Test func activityChartDaysWithoutLogs() {
    let days = DSActivityChart.days(from: [], count: 14)
    #expect(days.count == 14)
    #expect(days.allSatisfy { $0.succeeded == 0 && $0.failed == 0 })
    #expect(Set(days.map(\.id)).count == 14)
    #expect(DSActivityChart.days(from: [], count: 0).isEmpty)
}

// MARK: - Routes

private func makeHost(_ id: Int64, _ label: String, jump: Int64? = nil, group: Int64? = nil) -> Termi.Host {
    var host = Termi.Host.defaultValue()
    host.id = id
    host.label = label
    host.hostname = "\(label).example"
    host.jumpHostId = jump
    host.groupId = group
    return host
}

@Test @MainActor func routeFollowsTheHostsOwnJumpChain() {
    let bastion = makeHost(1, "bastion")
    let gateway = makeHost(2, "gateway", jump: 1)
    let database = makeHost(3, "db", jump: 2)
    let hosts = [bastion, gateway, database]

    let hops = database.routeHops(hosts: hosts, groups: [])
    #expect(hops.map(\.id) == ["this-mac", "host-1", "host-2", "host-3"])
    #expect(hops.map(\.hostId) == [nil, 1, 2, 3])
    #expect(database.firstJumpName(hosts: hosts, groups: []) == "gateway")

    #expect(bastion.routeHops(hosts: hosts, groups: []).map(\.id) == ["this-mac", "host-1"])
    #expect(bastion.firstJumpName(hosts: hosts, groups: []) == nil)
}

@Test @MainActor func routeFallsBackToTheGroupsJumpHost() {
    let bastion = makeHost(1, "bastion", group: 7)
    let web = makeHost(2, "web", group: 7)
    let own = makeHost(3, "own", jump: 2, group: 7)
    let hosts = [bastion, web, own]
    let group = HostGroup(id: 7, name: "prod", sortOrder: 0, createdAt: TimestampFormatter.now(), jumpHostId: 1)

    #expect(web.routeHops(hosts: hosts, groups: [group]).map(\.id) == ["this-mac", "host-1", "host-2"])
    // The group's jump host is a member of the group: it does not jump through itself.
    #expect(bastion.routeHops(hosts: hosts, groups: [group]).map(\.id) == ["this-mac", "host-1"])
    // A host's own jump host wins over the group's.
    #expect(own.routeHops(hosts: hosts, groups: [group]).map(\.id)
            == ["this-mac", "host-1", "host-2", "host-3"])
    // A jump host that was deleted ends the chain.
    #expect(makeHost(4, "orphan", jump: 99).routeHops(hosts: hosts, groups: []).map(\.id)
            == ["this-mac", "host-4"])
}

@Test @MainActor func routeWithALoopEndsAndRepeatsNothing() {
    let a = makeHost(1, "a", jump: 2)
    let b = makeHost(2, "b", jump: 1)
    let selfJump = makeHost(3, "c", jump: 3)
    let hosts = [a, b, selfJump]

    let hops = a.routeHops(hosts: hosts, groups: [])
    #expect(hops.map(\.id) == ["this-mac", "host-2", "host-1"])
    #expect(Set(hops.map(\.id)).count == hops.count)
    #expect(selfJump.routeHops(hosts: hosts, groups: []).map(\.id) == ["this-mac", "host-3"])
}

// MARK: - Avatar status, tones, levels

@Test @MainActor func avatarStatusOfASetOfSessions() {
    #expect(DSHostAvatar.Status(states: []) == .none)
    #expect(DSHostAvatar.Status(states: [.idle]) == .none)
    #expect(DSHostAvatar.Status(states: [.failed("x"), .connected]) == .live)
    #expect(DSHostAvatar.Status(states: [.running]) == .live)
    #expect(DSHostAvatar.Status(states: [.ended(message: nil), .connecting]) == .busy)
    #expect(DSHostAvatar.Status(states: [.reconnecting(attempt: 1, retryAt: Date()), .failed("x")]) == .busy)
    #expect(DSHostAvatar.Status(states: [.ended(message: nil), .failed("x")]) == .failed)
    #expect(DSHostAvatar.Status(states: [.ended(message: "bye"), .idle]) == .ended)
}

@Test @MainActor func avatarStatusOfAHostWithoutSessions() {
    let vm = AppViewModel()
    #expect(vm.avatarStatus(forHostId: nil) == .none)
    #expect(vm.avatarStatus(forHostId: 42) == .none)
}

@Test func avatarStatusTones() {
    #expect(DSHostAvatar.Status.live.tone == .success)
    #expect(DSHostAvatar.Status.busy.tone == .warning)
    #expect(DSHostAvatar.Status.failed.tone == .danger)
    #expect(DSHostAvatar.Status.ended.tone == .inactive)
}

// A level is a status: the accent below 60 %, orange from 60 %, red from 85 %.
@Test func usageLevelThresholds() {
    #expect(DS.Tone.level(percent: 0) == .accent)
    #expect(DS.Tone.level(percent: 59.9) == .accent)
    #expect(DS.Tone.level(percent: 60) == .warning)
    #expect(DS.Tone.level(percent: 84.9) == .warning)
    #expect(DS.Tone.level(percent: 85) == .danger)
    #expect(DS.Tone.level(percent: 250) == .danger)
    #expect(DS.Tone.level(percent: -3) == .accent)
    #expect(DS.Palette.level(percent: 10) == DS.Palette.accent)
    #expect(DS.Palette.level(percent: 70) == DS.Palette.warning)
    #expect(DS.Palette.level(percent: 90) == DS.Palette.danger)
}

@Test func tonesMapToTheirColours() {
    #expect(DS.Tone.accent.color == DS.Palette.accent)
    #expect(DS.Tone.success.color == DS.Palette.success)
    #expect(DS.Tone.warning.color == DS.Palette.warning)
    #expect(DS.Tone.danger.color == DS.Palette.danger)
    #expect(DS.Tone.inactive.color == DS.Palette.inactive)
}

// Pages are not colour-coded: every category is the accent.
@Test func everySidebarItemHasAGlyphAndIsTheAccent() {
    for item in SidebarItem.allCases {
        #expect(!item.tileSymbol.isEmpty)
        #expect(!item.glyph.isEmpty)
        #expect(DS.Palette.category(item) == DS.Palette.accent)
    }
}

// MARK: - Operating systems

@Test func operatingSystemLookupFallsBackToTheDefault() {
    #expect(DSOperatingSystem.resolve(nil) == .unknown)
    #expect(DSOperatingSystem.resolve("") == .unknown)
    #expect(DSOperatingSystem.resolve("no-such-system") == .unknown)
    #expect(DSOperatingSystem.resolve("local") == .local)
    #expect(DSOperatingSystem.resolve("LOCAL") == .local)
    #expect(DSOperatingSystem.unknown.mark == .symbol("server.rack"))
    #expect(DSOperatingSystem.local.mark == .symbol("laptopcomputer"))
    #expect(DSOperatingSystem.unknown.color != DS.Palette.accent)
}

@Test func hostTileTakesItsSystemAndAChosenColourWins() {
    var host = makeHost(1, "web")
    #expect(host.operatingSystem == .unknown)
    #expect(host.tileContent == .symbol("server.rack"))
    #expect(host.tint == DSOperatingSystem.unknown.color)

    host.color = "#3b82f6"
    #expect(host.tint == Color.blue)
    host.color = ""
    #expect(host.tint == DSOperatingSystem.unknown.color)
}

// MARK: - Data shaping of the small charts

@Test func sparklineDomain() {
    #expect(DSSparkline.domain(for: []) == 0...1)
    #expect(DSSparkline.domain(for: [.nan, .infinity]) == 0...1)
    // A flat series sits in the middle of the height.
    #expect(DSSparkline.domain(for: [5, 5, 5]) == 4...6)
    // Otherwise from the lowest to the highest value, with room so the line is not cut.
    let domain = DSSparkline.domain(for: [10, 20, 60])
    #expect(domain.lowerBound < 10 && domain.lowerBound > 0)
    #expect(domain.upperBound > 60 && domain.upperBound < 70)
    // A given range wins (percentages are drawn on 0…100).
    #expect(DSSparkline.domain(for: [10, 20, 60], range: 0...100) == 0...100)
    #expect(DSSparkline.domain(for: [], range: 0...100) == 0...100)
}

@Test func meterAndGaugeClampTheirShare() {
    #expect(DSMeter.fraction(percent: 0) == 0)
    #expect(DSMeter.fraction(percent: 98) == 0.98)
    #expect(DSMeter.fraction(percent: 140) == 1)
    #expect(DSMeter.fraction(percent: -5) == 0)
    #expect(DSMeter.fraction(percent: .nan) == 0)
    #expect(DSArcGauge.sweep(percent: 50) == 0.5)
    #expect(DSArcGauge.sweep(percent: 101) == 1)
    #expect(DSArcGauge.sweep(percent: -1) == 0)
    #expect(DSArcGauge.sweep(percent: .infinity) == 0)
}

private func makeDay(_ offset: Int, succeeded: Int, failed: Int = 0) -> DSActivityChart.Day {
    DSActivityChart.Day(date: Date(timeIntervalSince1970: Double(offset) * 86_400), succeeded: succeeded, failed: failed)
}

@Test func dayStripLightsTheDaysWithConnections() {
    let days = [makeDay(0, succeeded: 2), makeDay(1, succeeded: 0), makeDay(2, succeeded: 0, failed: 1)]
    #expect(DSDayStrip.days(from: days) == [true, false, true])
    #expect(DSDayStrip.days(from: []).isEmpty)
    #expect(days.map(\.total) == [2, 0, 1])
}

@Test func activityBarHeights() {
    let days = [makeDay(0, succeeded: 9), makeDay(1, succeeded: 0), makeDay(2, succeeded: 2, failed: 1)]
    let heights = DSActivityChart.barHeights(for: days, height: 52)
    // The busiest day is the full height, an empty day a flat line, the rest in proportion.
    #expect(heights == [52, 2, 21])
    #expect(DSActivityChart.barHeights(for: [makeDay(0, succeeded: 0)], height: 52) == [2])
    #expect(DSActivityChart.barHeights(for: [], height: 52).isEmpty)
}

// MARK: - Code block, master list

@Test func codeBlockFindsTheVariablesOfACommand() {
    let command = "tar czf {{archive}}.tgz -C {{dir}} ."
    #expect(DSCodeBlock.variableRanges(in: command).map { String(command[$0]) } == ["{{archive}}", "{{dir}}"])
    #expect(DSCodeBlock.variableRanges(in: "ls -la").isEmpty)
    // An opening without a closing is not a variable.
    #expect(DSCodeBlock.variableRanges(in: "echo {{open").isEmpty)
    let mixed = "{{a}} {{b"
    #expect(DSCodeBlock.variableRanges(in: mixed).map { String(mixed[$0]) } == ["{{a}}"])
    let wide = "部署 {{目标}} 完成"
    #expect(DSCodeBlock.variableRanges(in: wide).map { String(wide[$0]) } == ["{{目标}}"])
}

@Test func masterListWalksItsOrder() {
    typealias Master = DSMasterList<String, EmptyView>
    let order = ["a", "b", "c"]
    #expect(Master.neighbour(of: "b", in: order, direction: .down) == "c")
    #expect(Master.neighbour(of: "b", in: order, direction: .up) == "a")
    // The ends stay where they are.
    #expect(Master.neighbour(of: "c", in: order, direction: .down) == nil)
    #expect(Master.neighbour(of: "a", in: order, direction: .up) == nil)
    // Nothing selected, or a selection that left the list: the first row.
    #expect(Master.neighbour(of: nil, in: order, direction: .down) == "a")
    #expect(Master.neighbour(of: "gone", in: order, direction: .up) == "a")
    #expect(Master.neighbour(of: "a", in: order, direction: .left) == nil)
    #expect(Master.neighbour(of: nil, in: [], direction: .down) == nil)
}

@Test @MainActor func revealIsTakenOnceByThePageOfTheSameWindow() {
    let window = AppViewModel()
    let other = AppViewModel()
    window.isViewingTerminal = true

    window.reveal(.keys, id: "7")

    #expect(window.selectedSidebar == .keys)
    #expect(window.isViewingTerminal == false)
    #expect(other.takeReveal(for: .keys) == nil)
    #expect(window.takeReveal(for: .identities) == nil)
    #expect(window.takeReveal(for: .keys) == "7")
    #expect(window.takeReveal(for: .keys) == nil)
}

@Test @MainActor func revealOfAHostSelectsItOnTheHostsPage() {
    let window = AppViewModel()
    window.selectedSidebar = .logs

    window.reveal(host: makeHost(5, "web"))

    #expect(window.selectedSidebar == .terminal)
    #expect(window.hostsPage.selectedHostId == 5)
    #expect(window.takeReveal(for: .terminal) == nil)
}
