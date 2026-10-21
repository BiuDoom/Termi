import Testing
import Foundation
import SwiftUI
@testable import Termi

// MARK: - Shell: the sessions are listed once, in the toolbar

@Test @MainActor func clickingThePageUnderATerminalBringsItBack() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    // The page under the terminal is still Hosts; no row is selected, so choosing Hosts is a change.
    #expect(vm.selectedSidebar == .terminal)
    #expect(vm.sidebarSelection == nil)
    vm.select(.terminal)
    #expect(vm.isViewingTerminal == false)
    #expect(vm.sidebarSelection == .terminal)
}

@Test @MainActor func tabShortcutsLeadBackFromAnyPage() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    vm.addLocalTerminalTab()
    let first = vm.tabs[0].id
    vm.select(.logs)
    vm.selectTab(at: 0)
    #expect(vm.isViewingTerminal)
    #expect(vm.activeTabId == first)
    vm.select(.keys)
    vm.selectNextTab()
    #expect(vm.isViewingTerminal)
}

@Test @MainActor func sidebarBadgesOnlySayWhatIsGoingOn() {
    let vm = AppViewModel()
    let inventory: [SidebarItem] = [.terminal, .snippets, .keys, .identities, .knownHosts, .docker]
    for item in inventory {
        #expect(vm.badge(for: item) == 0)
    }
}

@Test func tilesOnAPageFitTheirWidthAndLeaveRoomForTheMoreMenu() {
    #expect(TabBarView.tileCount(count: 0, available: 200) == 0)
    #expect(TabBarView.tileCount(count: 3, available: 200) == 3)
    #expect(TabBarView.tileCount(count: 6, available: 200) == 6)
    // One more than fit: the "+N" menu takes the place of a tile.
    #expect(TabBarView.tileCount(count: 7, available: 200) == 5)
    #expect(TabBarView.tileCount(count: 2, available: 72) == 2)
    #expect(TabBarView.tileCount(count: 5, available: 72) == 1)
    #expect(TabBarView.tileCount(count: 5, available: 0) == 1)
}

@Test func pageTabsWidthShrinksWithTheWindow() {
    #expect(MainWindowView.pageTabsWidth(detailWidth: 1000) == 200)
    #expect(MainWindowView.pageTabsWidth(detailWidth: 700) == 80)
    #expect(MainWindowView.pageTabsWidth(detailWidth: 300) == 72)
}

@Test @MainActor func tabStateIsSaidInWords() {
    let live = TabItemView.stateDescription(status: .live, panes: 1, isBroadcasting: false)
    #expect(live == String(localized: "Connected"))
    let split = TabItemView.stateDescription(status: .live, panes: 3, isBroadcasting: true)
    #expect(split.contains(String(localized: "Broadcasting input")))
    #expect(split.contains("3"))
    #expect(TabItemView.stateDescription(status: .none, panes: 1, isBroadcasting: false).isEmpty)
}

// MARK: - Hosts page

@Test func filterBarNeedsSomethingToFilterBy() {
    #expect(HostsViewModel.showsFilterBar(hostCount: 8, hasTags: false, hasOnline: false, isFiltering: false) == false)
    #expect(HostsViewModel.showsFilterBar(hostCount: 8, hasTags: true, hasOnline: false, isFiltering: false))
    #expect(HostsViewModel.showsFilterBar(hostCount: 8, hasTags: false, hasOnline: true, isFiltering: false))
    // A filter that is on stays reachable even when what it filtered by is gone.
    #expect(HostsViewModel.showsFilterBar(hostCount: 8, hasTags: false, hasOnline: false, isFiltering: true))
    #expect(HostsViewModel.showsFilterBar(hostCount: 0, hasTags: true, hasOnline: true, isFiltering: true) == false)
}

@Test func gridColumnsFollowTheWidth() {
    #expect(HostsViewModel.gridColumns(width: 200, minimum: 240, spacing: 10) == 1)
    #expect(HostsViewModel.gridColumns(width: 490, minimum: 240, spacing: 10) == 2)
    #expect(HostsViewModel.gridColumns(width: 489, minimum: 240, spacing: 10) == 1)
    #expect(HostsViewModel.gridColumns(width: 750, minimum: 240, spacing: 10) == 3)
    // Nothing at all to stand in: still one column, never none.
    #expect(HostsViewModel.gridColumns(width: 0, minimum: 240, spacing: 10) == 1)
}

@Test func arrowKeysMoveThroughTheGrid() {
    // Two groups in two columns:   1 2      6 7
    //                              3 4      8
    //                              5
    let sections: [[Int64]] = [[1, 2, 3, 4, 5], [], [6, 7, 8]]
    func move(_ from: Int64?, _ direction: MoveCommandDirection) -> Int64? {
        HostsViewModel.gridNeighbour(of: from, in: sections, columns: 2, direction: direction)
    }
    #expect(move(nil, .down) == 1)
    #expect(move(99, .right) == 1)
    #expect(move(1, .right) == 2)
    #expect(move(2, .right) == 3)
    #expect(move(3, .left) == 2)
    #expect(move(1, .left) == nil)
    #expect(move(1, .up) == nil)
    #expect(move(1, .down) == 3)
    #expect(move(4, .down) == 5)
    #expect(move(4, .up) == 2)
    // Into the next group, over the empty one, keeping the column.
    #expect(move(5, .down) == 6)
    #expect(move(5, .right) == 6)
    #expect(move(6, .up) == 5)
    #expect(move(7, .up) == 5)
    #expect(move(7, .down) == 8)
    #expect(move(8, .down) == nil)
    #expect(move(8, .right) == nil)
    #expect(HostsViewModel.gridNeighbour(of: nil, in: [[]], columns: 2, direction: .down) == nil)
    // A column count of zero (the grid not measured yet) is one column.
    #expect(HostsViewModel.gridNeighbour(of: 1, in: sections, columns: 0, direction: .down) == 2)
}

// MARK: - Host record

@Test func routeIsDrawnOnlyThroughAJumpHost() {
    #expect(DSRouteDiagram.addsSomething(hopCount: 2) == false)
    #expect(DSRouteDiagram.addsSomething(hopCount: 3))
    #expect(DSRouteDiagram.addsSomething(hopCount: 0) == false)
}

@Test func recentCountIsSaidOnlyWhenItIsAnotherNumber() {
    #expect(HostDetailFormat.showsRecentCount(recent: 266, total: 266) == false)
    #expect(HostDetailFormat.showsRecentCount(recent: 50, total: 164))
    #expect(HostDetailFormat.showsRecentCount(recent: 0, total: 0) == false)
}

@Test func theCardAndTheRowSayTheSameMoment() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let offsets: [TimeInterval] = [-20, -290, -3_500, -10_805, -172_805, -3_456_000]
    for offset in offsets {
        let date = now.addingTimeInterval(offset)
        let row = DSRelativeTime.text(for: date, now: now)
        let card = HostDetailFormat.lastConnected(date, now: now)
        let joined = card.unit.map { card.value + $0 } ?? card.value
        let rowPlain = row.replacingOccurrences(of: " ", with: "")
        let cardPlain = joined.replacingOccurrences(of: " ", with: "")
        #expect(rowPlain == cardPlain)
    }
    let never = HostDetailFormat.lastConnected(nil, now: now)
    #expect(never.unit == nil)
    let justNow = DSRelativeTime.parts(for: now.addingTimeInterval(-5), now: now)
    #expect(justNow.unit == nil)
    let ahead = DSRelativeTime.parts(for: now.addingTimeInterval(90), now: now)
    #expect(ahead.unit == nil)
}

// MARK: - Quick Connect

@Test func quickConnectNamesOnlyWhatTheAddressLeftOut() {
    let complete = QuickConnectParser.defaults(filledIn: "deploy@10.0.12.9:2222")
    #expect(complete?.user == false)
    #expect(complete?.port == false)
    let noPort = QuickConnectParser.defaults(filledIn: "deploy@10.0.12.9")
    #expect(noPort?.user == false)
    #expect(noPort?.port == true)
    let bare = QuickConnectParser.defaults(filledIn: "  example.com ")
    #expect(bare?.user == true)
    #expect(bare?.port == true)
    let bracketed = QuickConnectParser.defaults(filledIn: "root@[::1]:2200")
    #expect(bracketed?.port == false)
    let v6 = QuickConnectParser.defaults(filledIn: "root@::1")
    #expect(v6?.port == true)
    #expect(QuickConnectParser.defaults(filledIn: "user@host:port") == nil)
    #expect(QuickConnectParser.defaults(filledIn: "") == nil)
}

// MARK: - Command palette

@Test func paletteCountsResultsOnlyWhenSomeAreOutOfView() {
    #expect(CommandPaletteView.showsResultCount(rows: 4, sections: 3) == false)
    #expect(CommandPaletteView.showsResultCount(rows: 7, sections: 1) == false)
    #expect(CommandPaletteView.showsResultCount(rows: 8, sections: 1))
    #expect(CommandPaletteView.showsResultCount(rows: 7, sections: 3))
}

@Test func paletteIsAsHighAsItsRows() {
    let few: CGFloat = CommandPaletteView.listHeight(rows: 4, sections: 1)
    #expect(few == 208)
    let headed: CGFloat = CommandPaletteView.listHeight(rows: 4, sections: 3)
    #expect(headed == 310)
    let many: CGFloat = CommandPaletteView.listHeight(rows: 40, sections: 3)
    #expect(many == 376)
}
