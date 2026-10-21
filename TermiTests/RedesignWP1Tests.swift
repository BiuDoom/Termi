import Testing
import Foundation
@testable import Termi

// MARK: - Sidebar selection

@Test @MainActor func sidebarSelectionNamesThePageAndNothingOverATerminal() {
    let vm = AppViewModel()
    #expect(vm.sidebarSelection == .terminal)

    // The sessions are the toolbar's tabs: over a terminal the sidebar selects nothing.
    vm.addLocalTerminalTab()
    let first = vm.tabs[0].id
    #expect(vm.sidebarSelection == nil)

    vm.select(.keys)
    #expect(vm.selectedSidebar == .keys)
    #expect(vm.isViewingTerminal == false)
    #expect(vm.sidebarSelection == .keys)

    // A tab leads back to its terminal from any page.
    vm.activateTab(first)
    #expect(vm.isViewingTerminal)
    #expect(vm.activeTabId == first)
    #expect(vm.sidebarSelection == nil)

    // Clearing the list's selection changes nothing.
    vm.select(nil)
    #expect(vm.isViewingTerminal)
    #expect(vm.sidebarSelection == nil)
}

@Test @MainActor func sidebarBadgesWithoutDataShowNothing() {
    let vm = AppViewModel()
    for item in SidebarItem.allCases {
        #expect(vm.badge(for: item) == 0)
    }
}

// MARK: - Tab state

@Test func tabStatusIsTheWorstStateOfItsPanes() {
    #expect(AppViewModel.tabStatus(for: []) == .live)
    #expect(AppViewModel.tabStatus(for: [.connected, .connected]) == .live)
    #expect(AppViewModel.tabStatus(for: [.connected, .connecting]) == .busy)
    #expect(AppViewModel.tabStatus(for: [.connected, .reconnecting(attempt: 1, retryAt: Date())]) == .busy)
    #expect(AppViewModel.tabStatus(for: [.connected, .ended(message: nil)]) == .ended)
    #expect(AppViewModel.tabStatus(for: [.connecting, .ended(message: nil)]) == .busy)
    #expect(AppViewModel.tabStatus(for: [.connecting, .ended(message: nil), .failed("refused")]) == .failed)
}

@Test @MainActor func localTabCarriesNoState() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    #expect(vm.avatarStatus(of: vm.tabs[0]) == .none)
    #expect(vm.host(of: vm.tabs[0]) == nil)
}

// MARK: - Recent hosts

@Test func recentHostsAreTheLastConnectedOnesNewestFirst() {
    func host(_ label: String, _ lastConnected: String?) -> Termi.Host {
        var host = Termi.Host.defaultValue()
        host.label = label
        host.lastConnectedAt = lastConnected
        return host
    }
    let hosts = [
        host("old", "2026-10-01T08:00:00Z"),
        host("never", nil),
        host("new", "2026-10-04T08:00:00Z"),
        host("mid", "2026-10-02T08:00:00Z")
    ]
    #expect(AppViewModel.recentHosts(hosts, limit: 8).map(\.label) == ["new", "mid", "old"])
    #expect(AppViewModel.recentHosts(hosts, limit: 2).map(\.label) == ["new", "mid"])
    #expect(AppViewModel.recentHosts([], limit: 8).isEmpty)
}

// MARK: - Tab bar sizing

@Test func tabsKeepTheirNaturalWidthWhileTheyFit() {
    #expect(TabBarView.sizing(count: 0, available: 100) == .natural)
    #expect(TabBarView.sizing(count: 3, available: 900) == .natural)
}

@Test func tabsShareTheWidthBeforeTheyTurnIntoTiles() {
    let chrome = TabBarView.Metrics.chrome
    // Three tabs in 400 pt of room: 132 each (two 2 pt gaps).
    #expect(TabBarView.sizing(count: 3, available: 400 + chrome) == .equal(132))
    // Four tabs in 324 pt would be 79 pt each — below the minimum: tiles around the active tab.
    #expect(TabBarView.sizing(count: 4, available: 324 + chrome) == .compact(active: 200, visible: 4))
    // Twenty tabs: as many tiles as fit next to an active tab of at least the minimum width
    // and the "+N" menu (32 pt).
    #expect(TabBarView.sizing(count: 20, available: 324 + chrome) == .compact(active: 100, visible: 7))
    // Less room than one tab needs still shows the active tab.
    #expect(TabBarView.sizing(count: 5, available: 0) == .compact(active: 92, visible: 1))
}

@Test func visibleTabsAlwaysHoldTheActiveOne() {
    #expect(TabBarView.visibleRange(count: 20, active: 0, visible: 8) == 0..<8)
    #expect(TabBarView.visibleRange(count: 20, active: 7, visible: 8) == 0..<8)
    #expect(TabBarView.visibleRange(count: 20, active: 8, visible: 8) == 1..<9)
    #expect(TabBarView.visibleRange(count: 20, active: 19, visible: 8) == 12..<20)
    #expect(TabBarView.visibleRange(count: 3, active: 2, visible: 8) == 0..<3)
    #expect(TabBarView.visibleRange(count: 3, active: 1, visible: 0) == 1..<2)
}

@Test func tabsThatDoNotFitAreListedInTabOrder() {
    #expect(TabBarView.hidden([0, 1, 2, 3, 4], shown: 1..<3) == [0, 3, 4])
    #expect(TabBarView.hidden([0, 1, 2], shown: 0..<3).isEmpty)
    #expect(TabBarView.hidden([0, 1, 2], shown: 2..<9) == [0, 1])
    #expect(TabBarView.hidden([Int](), shown: 0..<1).isEmpty)
}

@Test @MainActor func closingTheLastTabGoesBackToThePage() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    vm.addLocalTerminalTab()
    let first = vm.tabs[0].id
    let second = vm.tabs[1].id
    #expect(vm.activeTabId == second)

    // Closing the session on screen moves to its neighbour …
    vm.closeTab(second)
    #expect(vm.activeTabId == first)
    #expect(vm.sidebarSelection == nil)
    // … and closing the last one goes back to the page.
    vm.closeTab(first)
    #expect(vm.sidebarSelection == .terminal)
}

// MARK: - Command palette

@Test func paletteMatchIgnoresCase() {
    let title = "Web-01"
    let match = CommandPaletteView.matchRange(of: "web", in: title)
    #expect(match.map { String(title[$0]) } == "Web")
    #expect(CommandPaletteView.matchRange(of: "db", in: title) == nil)
    #expect(CommandPaletteView.matchRange(of: "", in: title) == nil)
}

@Test func paletteTitleKeepsItsTextWhenHighlighted() {
    #expect(String(CommandPaletteView.highlighted("web-01", query: "web").characters) == "web-01")
    #expect(CommandPaletteView.highlighted("web-01", query: "web").runs.count == 2)
    #expect(CommandPaletteView.highlighted("web-01", query: "zzz").runs.count == 1)
}
