import Testing
import Foundation
@testable import Termi

// The conditions behind the decluttered terminal and SFTP screens: what a pane header writes,
// when a route is drawn, when the transfer bar adds up, when the host picker titles its sections.

// MARK: - Pane header

@Test func paneOfTheTabsHostWritesOnlyItsProgram() {
    let content = PaneHeaderContent.resolve(name: "web-01", tabTitle: "web-01", program: "htop")
    #expect(!content.showsHost)
    #expect(content.text == "htop")
}

@Test func paneWithoutAProgramTitleFallsBackToTheName() {
    let none = PaneHeaderContent.resolve(name: "web-01", tabTitle: "web-01", program: nil)
    #expect(!none.showsHost)
    #expect(none.text == "web-01")
    // An empty title, or one that only repeats the name, is no title.
    #expect(PaneHeaderContent.resolve(name: "web-01", tabTitle: "web-01", program: "").text == "web-01")
    #expect(PaneHeaderContent.resolve(name: "web-01", tabTitle: "web-01", program: "web-01").text == "web-01")
}

@Test func paneOfAnotherHostKeepsItsTileAndName() {
    let other = PaneHeaderContent.resolve(name: "bastion", tabTitle: "web-01", program: "bash")
    #expect(other.showsHost)
    #expect(other.text == "bastion · bash")
    let plain = PaneHeaderContent.resolve(name: "bastion", tabTitle: "web-01", program: nil)
    #expect(plain.showsHost)
    #expect(plain.text == "bastion")
}

@Test func paneHeaderAlwaysSaysTheHostToVoiceOver() {
    #expect(PaneHeaderContent.accessibilityLabel(name: "web-01", program: "htop") == "web-01, htop")
    #expect(PaneHeaderContent.accessibilityLabel(name: "web-01", program: nil) == "web-01")
    #expect(PaneHeaderContent.accessibilityLabel(name: "web-01", program: "web-01") == "web-01")
}

// MARK: - Route

@Test func terminalRouteIsDrawnOnlyThroughAJumpHost() {
    let mac = DSRouteDiagram.Hop.thisMac
    let host = DSRouteDiagram.Hop.endpoint("web-01", symbol: "server.rack")
    let jump = DSRouteDiagram.Hop.endpoint("bastion", symbol: "server.rack")
    #expect(!DSRouteDiagram.passesJumpHost([]))
    #expect(!DSRouteDiagram.passesJumpHost([mac, host]))
    #expect(DSRouteDiagram.passesJumpHost([mac, jump, host]))
}

// MARK: - Transfer bar

@Test func transferSummaryOnlyWhenItAddsSomethingUp() {
    // One running transfer: the total is that row's own number.
    #expect(!TransferQueueView.showsSummary(running: 1, rows: 1))
    #expect(!TransferQueueView.showsSummary(running: 1, rows: 2))
    #expect(!TransferQueueView.showsSummary(running: 0, rows: 2))
    // Two running, or more rows than are in view.
    #expect(TransferQueueView.showsSummary(running: 2, rows: 2))
    #expect(TransferQueueView.showsSummary(running: 1, rows: 3))
    #expect(TransferQueueView.showsSummary(running: 0, rows: 3))
}

@Test func transferBarIsAsHighAsItsRows() {
    let one: CGFloat = TransferQueueView.rowsHeight(running: 1, finished: 0)
    let both: CGFloat = TransferQueueView.rowsHeight(running: 1, finished: 1)
    let done: CGFloat = TransferQueueView.rowsHeight(running: 0, finished: 2)
    #expect(one == 50)
    #expect(both == 88)
    #expect(done == 76)
}

// MARK: - Host picker

@Test func hostPickerTitlesOnlyTellSectionsApart() {
    #expect(!SFTPHostPicker.showsSectionTitles(hasLive: false, groupCount: 1, isSearching: false))
    #expect(!SFTPHostPicker.showsSectionTitles(hasLive: false, groupCount: 0, isSearching: false))
    #expect(SFTPHostPicker.showsSectionTitles(hasLive: true, groupCount: 1, isSearching: false))
    #expect(SFTPHostPicker.showsSectionTitles(hasLive: true, groupCount: 0, isSearching: false))
    #expect(SFTPHostPicker.showsSectionTitles(hasLive: false, groupCount: 2, isSearching: false))
}

@Test func aLoneSectionIsTitledWhileSearchingBecauseTheTitleCountsTheMatches() {
    #expect(SFTPHostPicker.showsSectionTitles(hasLive: false, groupCount: 1, isSearching: true))
    #expect(!SFTPHostPicker.showsSectionTitles(hasLive: false, groupCount: 0, isSearching: true))
}

// MARK: - Local panel

@Test func localAccountIsUserAtTheMacsShortName() {
    #expect(SFTPViewModel.accountText(user: "termi", hostName: "example-host.local") == "termi@example-host")
    #expect(SFTPViewModel.accountText(user: "termi", hostName: "example-host") == "termi@example-host")
    #expect(SFTPViewModel.accountText(user: "termi", hostName: "") == "termi")
}

@MainActor
@Test func theToolbarSwitchShowsHiddenFilesInBothPanels() {
    let viewModel = SFTPViewModel()
    #expect(!viewModel.showsHiddenFiles)
    viewModel.showsHiddenFiles = true
    #expect(viewModel.showHiddenLocal)
    #expect(viewModel.showHiddenRemote)
    viewModel.showsHiddenFiles = false
    #expect(!viewModel.showHiddenLocal)
    #expect(!viewModel.showHiddenRemote)
}
