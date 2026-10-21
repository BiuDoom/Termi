import Testing
import Foundation
import SwiftUI
@testable import Termi

// The pure logic the polish pass added to the shared layer and to the seams between pages.
// Values are computed into typed constants first: Swift 6.0 cannot type-check arithmetic or
// long chains inside an #expect comparison.

// MARK: - Tiles

@Test func monogramCanBeOneLetter() {
    let two: String = DSIconTile.monogram(for: "prod-db-01")
    let one: String = DSIconTile.monogram(for: "prod-db-01", letters: 1)
    let lower: String = DSIconTile.monogram(for: "  root ", letters: 1)
    let chinese: String = DSIconTile.monogram(for: "打包机", letters: 1)
    let empty: String = DSIconTile.monogram(for: "   ", letters: 1)
    #expect(two == "PD")
    #expect(one == "P")
    #expect(lower == "R")
    #expect(chinese == "打")
    #expect(empty == "?")
}

@Test func worstStateWinsForATabAndLiveWinsForAHost() {
    let mixed: [TerminalSession.State] = [.connected, .failed("x"), .connecting]
    let worst: DSHostAvatar.Status = DSHostAvatar.Status(states: mixed, ranking: .worstFirst)
    let liveFirst: DSHostAvatar.Status = DSHostAvatar.Status(states: mixed, ranking: .liveFirst)
    let plain: DSHostAvatar.Status = DSHostAvatar.Status(states: mixed)
    #expect(worst == .failed)
    #expect(liveFirst == .live)
    #expect(plain == .live)

    let busy: DSHostAvatar.Status = DSHostAvatar.Status(states: [.running, .connecting, .ended(message: nil)],
                                                        ranking: .worstFirst)
    let ended: DSHostAvatar.Status = DSHostAvatar.Status(states: [.connected, .ended(message: nil)],
                                                         ranking: .worstFirst)
    let live: DSHostAvatar.Status = DSHostAvatar.Status(states: [.connected, .running], ranking: .worstFirst)
    let none: DSHostAvatar.Status = DSHostAvatar.Status(states: [], ranking: .worstFirst)
    let idle: DSHostAvatar.Status = DSHostAvatar.Status(states: [.idle], ranking: .worstFirst)
    #expect(busy == .busy)
    #expect(ended == .ended)
    #expect(live == .live)
    #expect(none == DSHostAvatar.Status.none)
    #expect(idle == DSHostAvatar.Status.none)
}

@Test func aTabWithNothingWorseToReportIsLive() {
    // The tab bar's rule is unchanged by moving the ranking into the shared layer.
    let empty: DSHostAvatar.Status = AppViewModel.tabStatus(for: [])
    let idle: DSHostAvatar.Status = AppViewModel.tabStatus(for: [.idle])
    let failed: DSHostAvatar.Status = AppViewModel.tabStatus(for: [.connected, .failed("x")])
    #expect(empty == .live)
    #expect(idle == .live)
    #expect(failed == .failed)
}

// MARK: - Cards and charts

@Test func statGridCapsOnlyOneOrTwoCards() {
    let columns: Int = DSStatGrid<EmptyHolder>.columns(count: 2, width: 712, minimum: 132, spacing: 10)
    let capped: CGFloat = DSStatGrid<EmptyHolder>.columnWidth(count: 2, columns: 2, width: 712, spacing: 10,
                                                              widestOfFew: 320)
    let free: CGFloat = DSStatGrid<EmptyHolder>.columnWidth(count: 2, columns: 2, width: 712, spacing: 10,
                                                            widestOfFew: nil)
    let three: CGFloat = DSStatGrid<EmptyHolder>.columnWidth(count: 3, columns: 3, width: 920, spacing: 10,
                                                             widestOfFew: 320)
    #expect(columns == 2)
    #expect(capped == 320)
    #expect(free == 351)
    #expect(three == 300)

    let narrow: Int = DSStatGrid<EmptyHolder>.columns(count: 4, width: 300, minimum: 132, spacing: 10)
    let none: Int = DSStatGrid<EmptyHolder>.columns(count: 0, width: 300, minimum: 132, spacing: 10)
    #expect(narrow == 2)
    #expect(none == 1)
}

@Test func gaugeOpeningShrinksWithTheGauge() {
    let large: CGFloat = DSArcGauge.openingWidth(diameter: 128, lineWidth: 10)
    let small: CGFloat = DSArcGauge.openingWidth(diameter: 84, lineWidth: 8)
    let tiny: CGFloat = DSArcGauge.openingWidth(diameter: 20, lineWidth: 10)
    #expect(large > 64)
    #expect(large < 68)
    #expect(small > 36)
    #expect(small < 40)
    #expect(tiny == 0)
}

@Test @MainActor func gaugeDetailLeavesTheOpeningWhenItIsTooWide() {
    let shortFits: Bool = DSArcGauge.detailFitsOpening("0.42", diameter: 128, lineWidth: 10)
    let longFits: Bool = DSArcGauge.detailFitsOpening("437.5 / 1024.0 GB", diameter: 128, lineWidth: 10)
    let smallFits: Bool = DSArcGauge.detailFitsOpening("0.8 / 7.8 GB", diameter: 84, lineWidth: 8)
    #expect(shortFits)
    #expect(longFits == false)
    #expect(smallFits == false)
}

@Test func sparklineScaleHasAMinimumSpan() {
    let plain: ClosedRange<Double> = DSSparkline.domain(for: [3, 3.2, 3.1])
    let plainSpan: Double = plain.upperBound - plain.lowerBound
    #expect(plainSpan < 1)

    let wide: ClosedRange<Double> = DSSparkline.domain(for: [3, 3.2, 3.1], minimumSpan: 10)
    let wideSpan: Double = wide.upperBound - wide.lowerBound
    let middle: Double = (wide.upperBound + wide.lowerBound) / 2
    let spanError: Double = abs(wideSpan - 10)
    let middleError: Double = abs(middle - 3.1)
    #expect(spanError < 0.0001)
    #expect(middleError < 0.0001)

    // A scale that is already wider is left alone, and a given range always wins.
    let untouched: ClosedRange<Double> = DSSparkline.domain(for: [0, 100], minimumSpan: 10)
    let given: ClosedRange<Double> = DSSparkline.domain(for: [3, 4], range: 0...50, minimumSpan: 500)
    #expect(untouched.lowerBound == -12)
    #expect(untouched.upperBound == 112)
    let expected: ClosedRange<Double> = 0...50
    #expect(given == expected)
}

@Test func failedMarkIsAShareOfTheBar() {
    let day = Date(timeIntervalSince1970: 0)
    let days: [DSActivityChart.Day] = [
        DSActivityChart.Day(date: day, succeeded: 8, failed: 0),
        DSActivityChart.Day(date: day.addingTimeInterval(86_400), succeeded: 6, failed: 2),
        DSActivityChart.Day(date: day.addingTimeInterval(172_800), succeeded: 0, failed: 3),
        DSActivityChart.Day(date: day.addingTimeInterval(259_200), succeeded: 99, failed: 1),
        DSActivityChart.Day(date: day.addingTimeInterval(345_600), succeeded: 0, failed: 0),
        DSActivityChart.Day(date: day.addingTimeInterval(432_000), succeeded: 1, failed: 9)
    ]
    let bars: [CGFloat] = [40, 40, 20, 60, 2, 6]
    let marks: [CGFloat] = DSActivityChart.failedHeights(for: days, barHeights: bars)
    #expect(marks.count == 6)
    #expect(marks[0] == 0)
    // A quarter of the bar.
    #expect(marks[1] == 10)
    // Nothing succeeded: the mark is the whole bar.
    #expect(marks[2] == 20)
    // One in a hundred is still seen.
    #expect(marks[3] == 3)
    #expect(marks[4] == 0)
    // Something succeeded: the mark never takes a 6 pt bar whole.
    #expect(marks[5] == 3)
}

@Test func durationsAreTheTwoLargestUnits() {
    let none: [(value: Int, unit: DSLogStats.DurationUnit)] = DSLogStats.durationPieces(ms: nil)
    #expect(none.isEmpty)

    let short: [(value: Int, unit: DSLogStats.DurationUnit)] = DSLogStats.durationPieces(ms: 400)
    #expect(short.count == 1)
    #expect(short[0].value == 1)
    #expect(short[0].unit == .seconds)

    let minutes: [(value: Int, unit: DSLogStats.DurationUnit)] = DSLogStats.durationPieces(ms: 252_000)
    #expect(minutes.count == 2)
    #expect(minutes[0].value == 4)
    #expect(minutes[0].unit == .minutes)
    #expect(minutes[1].value == 12)
    #expect(minutes[1].unit == .seconds)

    // A whole number of minutes has no "0 sec"; hours go with minutes, never with seconds.
    let whole: [(value: Int, unit: DSLogStats.DurationUnit)] = DSLogStats.durationPieces(ms: 120_000)
    #expect(whole.count == 1)
    #expect(whole[0].value == 2)
    let hours: [(value: Int, unit: DSLogStats.DurationUnit)] = DSLogStats.durationPieces(ms: 4_085_000)
    #expect(hours.count == 2)
    #expect(hours[0].value == 1)
    #expect(hours[0].unit == .hours)
    #expect(hours[1].value == 8)
    #expect(hours[1].unit == .minutes)

    let text: String = DSLogStats.durationText(ms: 252_000)
    #expect(text.contains("4"))
    #expect(text.contains("12"))
    #expect(text.contains(" "))
}

// MARK: - Header and flow

@Test func headerTitleGivesWayDownToTheFloor() {
    let short: CGFloat = DSDetailHeaderMetrics.idealWidth(natural: 92.3)
    let long: CGFloat = DSDetailHeaderMetrics.idealWidth(natural: 420)
    let broken: CGFloat = DSDetailHeaderMetrics.idealWidth(natural: .infinity)
    #expect(short == 93)
    #expect(long == 180)
    #expect(broken == 180)
}

@Test func flowWrapsWhenALineIsFull() {
    let chip = CGSize(width: 100, height: 22)
    let sizes: [CGSize] = [chip, chip, chip]
    let oneLine = DSFlow.arrange(sizes: sizes, width: 400, spacing: 6)
    #expect(oneLine.height == 22)
    #expect(oneLine.width == 312)
    #expect(oneLine.origins[2].x == 212)
    #expect(oneLine.origins[2].y == 0)

    let wrapped = DSFlow.arrange(sizes: sizes, width: 250, spacing: 6)
    #expect(wrapped.height == 50)
    #expect(wrapped.width == 206)
    #expect(wrapped.origins[1].x == 106)
    #expect(wrapped.origins[2].x == 0)
    #expect(wrapped.origins[2].y == 28)

    let nothing = DSFlow.arrange(sizes: [], width: 250, spacing: 6)
    #expect(nothing.height == 0)
    #expect(nothing.origins.isEmpty)

    // A child wider than the line still gets a line of its own, not an endless loop.
    let wide = DSFlow.arrange(sizes: [CGSize(width: 300, height: 22), chip], width: 250, spacing: 6)
    #expect(wide.origins[0].x == 0)
    #expect(wide.origins[1].y == 28)
}

// MARK: - Route

@Test func theMiddleHopOfThreeIsCentred() {
    let origins: [CGFloat] = DSRouteDiagram.hopOrigins(widths: [150, 100, 60], in: 600, gap: 34)
    #expect(origins.count == 3)
    #expect(origins[0] == 0)
    #expect(origins[1] == 250)
    #expect(origins[2] == 540)

    // Whatever the ends are: two routes in one card share the middle column.
    let other: [CGFloat] = DSRouteDiagram.hopOrigins(widths: [80, 100, 190], in: 600, gap: 34)
    #expect(other[1] == 250)
}

@Test func hopsArePushedApartBeforeTheyOverlap() {
    // The first hop reaches past where the centred middle one would start.
    let crowded: [CGFloat] = DSRouteDiagram.hopOrigins(widths: [200, 100, 60], in: 500, gap: 34)
    #expect(crowded[0] == 0)
    #expect(crowded[1] == 234)
    #expect(crowded[2] == 440)

    let four: [CGFloat] = DSRouteDiagram.hopOrigins(widths: [90, 90, 90, 90], in: 900, gap: 34)
    #expect(four[1] == 255)
    #expect(four[2] == 555)
    #expect(four[3] == 810)

    let two: [CGFloat] = DSRouteDiagram.hopOrigins(widths: [90, 120], in: 400, gap: 34)
    #expect(two[0] == 0)
    #expect(two[1] == 280)
    let one: [CGFloat] = DSRouteDiagram.hopOrigins(widths: [90], in: 400, gap: 34)
    #expect(one == [0])
}

@Test func routeRowWidthCountsItsWires() {
    let ideal: CGFloat = DSRouteDiagram.rowWidth(hopWidths: [150, 100, 60], wire: 28, spacing: 8)
    let single: CGFloat = DSRouteDiagram.rowWidth(hopWidths: [150], wire: 28, spacing: 8)
    let empty: CGFloat = DSRouteDiagram.rowWidth(hopWidths: [], wire: 28, spacing: 8)
    #expect(ideal == 398)
    #expect(single == 150)
    #expect(empty == 0)
}

@Test func wiresToHopsNotReachedYetStayPending() {
    #expect(DSRouteDiagram.isReached(hop: 2, reachedHops: nil))
    #expect(DSRouteDiagram.isReached(hop: 1, reachedHops: 2))
    #expect(DSRouteDiagram.isReached(hop: 2, reachedHops: 2) == false)
    #expect(DSRouteDiagram.isReached(hop: 1, reachedHops: 1) == false)
}

// MARK: - Code block

@Test func codeBlockPutsValuesInPlaceAndKeepsEmptyVariables() {
    let command = "tar czf {{archive}}.tgz -C {{ directory }} . && scp {{archive}}.tgz {{target}}:/data/"
    let filled = DSCodeBlock.fill(command, values: ["archive": "release-42", "directory": "/srv/app", "target": ""])
    #expect(filled.text == "tar czf release-42.tgz -C /srv/app . && scp release-42.tgz {{target}}:/data/")
    #expect(filled.highlights.count == 4)
    let shown: [String] = filled.highlights.map { String(filled.text[$0]) }
    #expect(shown == ["release-42", "/srv/app", "release-42", "{{target}}"])
}

@Test func codeBlockWithoutVariablesIsLeftAlone() {
    let plain = DSCodeBlock.fill("uptime", values: ["x": "y"])
    #expect(plain.text == "uptime")
    #expect(plain.highlights.isEmpty)

    // Characters that take several UTF-16 units before a value do not shift its range.
    let wide = DSCodeBlock.fill("echo 😀 {{name}}", values: ["name": "世界"])
    #expect(wide.text == "echo 😀 世界")
    let shown: [String] = wide.highlights.map { String(wide.text[$0]) }
    #expect(shown == ["世界"])
}

// MARK: - Seams

@Test func aSnippetIsCompleteOnlyWhenEveryVariableHasAValue() {
    let command = "tail -n {{lines}} {{file}} | grep {{lines}}"
    let none: [String] = SnippetTemplate.missingValues(in: command, values: [:])
    let some: [String] = SnippetTemplate.missingValues(in: command, values: ["lines": "200", "file": ""])
    let all: [String] = SnippetTemplate.missingValues(in: command, values: ["lines": "200", "file": "/var/log/syslog"])
    let plain: [String] = SnippetTemplate.missingValues(in: "uptime", values: [:])
    #expect(none == ["lines", "file"])
    #expect(some == ["file"])
    #expect(all.isEmpty)
    #expect(plain.isEmpty)
}

@Test func deleteOnlyAsksAboutAHostSomebodyChose() {
    // The page selected a host by itself, the keyboard is elsewhere: ⌫ does nothing.
    let auto: Int64? = HostsViewModel.deleteTarget(selected: 7, picked: nil, listHasFocus: false)
    // The user clicked that host.
    let picked: Int64? = HostsViewModel.deleteTarget(selected: 7, picked: 7, listHasFocus: false)
    // The user clicked another host earlier; the selection has moved on by itself since.
    let stale: Int64? = HostsViewModel.deleteTarget(selected: 7, picked: 3, listHasFocus: false)
    // The list has the keyboard: its arrows chose the row.
    let focused: Int64? = HostsViewModel.deleteTarget(selected: 7, picked: nil, listHasFocus: true)
    let nothing: Int64? = HostsViewModel.deleteTarget(selected: nil, picked: 7, listHasFocus: true)
    #expect(auto == nil)
    #expect(picked == 7)
    #expect(stale == nil)
    #expect(focused == 7)
    #expect(nothing == nil)
}

@Test @MainActor func pickingAHostSelectsIt() {
    let model = HostsViewModel()
    #expect(model.pickedHostId == nil)
    model.pick(5)
    #expect(model.selectedHostId == 5)
    #expect(model.pickedHostId == 5)
}

/// Only to name `DSStatGrid`'s static helpers: its content type does not matter to them.
private typealias EmptyHolder = EmptyView

@Test func aFilterNeverLeavesAHiddenHostSelected() {
    // The selected host is still listed: nothing moves.
    let kept: Int64? = HostsViewModel.selection(7, keptWithin: [3, 7, 9])
    // A tag filter or a search took it off the page: it is given up, and no card the user
    // never chose is selected in its place.
    let hidden: Int64? = HostsViewModel.selection(7, keptWithin: [3, 9])
    let fresh: Int64? = HostsViewModel.selection(nil, keptWithin: [3, 9])
    let empty: Int64? = HostsViewModel.selection(7, keptWithin: [])
    #expect(kept == 7)
    #expect(hidden == nil)
    #expect(fresh == nil)
    #expect(empty == nil)
}
