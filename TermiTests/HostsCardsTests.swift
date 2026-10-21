import Testing
import Foundation
import SwiftUI
@testable import Termi

// The Hosts page as cards with the record on demand: the panel is closed at start, opens only
// when asked for, follows the selection and closes when its host is gone; which card shows the
// one button; the layout everyone starts on; how many cards stand in a row at the sizes the
// page is checked at.

private func cardsHost(_ id: Int64, _ label: String) -> Termi.Host {
    var host = Termi.Host.defaultValue()
    host.id = id
    host.label = label
    host.hostname = "10.0.0.\(id)"
    return host
}

@MainActor
private func cardsModel() -> HostsViewModel {
    let model = HostsViewModel()
    model.hosts = [cardsHost(1, "a"), cardsHost(2, "b"), cardsHost(3, "c")]
    return model
}

@MainActor
@Test func cardsPageStartsWithNothingSelectedAndThePanelClosed() {
    let model = cardsModel()
    #expect(model.selectedHostId == nil)
    #expect(model.showsDetails == false)
    #expect(model.detailsHostId == nil)
}

@MainActor
@Test func cardsSelectingACardDoesNotOpenThePanel() {
    let model = cardsModel()
    model.pick(2)
    #expect(model.selectedHostId == 2)
    #expect(model.detailsHostId == nil)
}

@MainActor
@Test func cardsCommandIDoesNothingWithoutASelection() {
    let model = cardsModel()
    model.toggleDetails()
    #expect(model.showsDetails == false)
    #expect(model.detailsHostId == nil)
    let pure: Bool = HostsViewModel.detailsShown(afterTogglingFrom: false, selected: nil)
    #expect(pure == false)
}

@MainActor
@Test func cardsCommandITogglesThePanelOfTheSelectedHost() {
    let model = cardsModel()
    model.pick(2)
    model.toggleDetails()
    #expect(model.detailsHostId == 2)
    model.toggleDetails()
    #expect(model.detailsHostId == nil)
    // The card stays selected: only the panel went.
    #expect(model.selectedHostId == 2)
}

@MainActor
@Test func cardsButtonOpensTheRecordOfItsHostAndClosesItAgain() {
    let model = cardsModel()
    model.pick(1)
    // The button of another card: that host is selected (picked, the user clicked it) and shown.
    model.toggleDetails(for: 3)
    #expect(model.selectedHostId == 3)
    #expect(model.pickedHostId == 3)
    #expect(model.detailsHostId == 3)
    // The same button again: the panel goes.
    model.toggleDetails(for: 3)
    #expect(model.detailsHostId == nil)
    #expect(model.selectedHostId == 3)
    // A host the page does not have: nothing.
    model.toggleDetails(for: 99)
    #expect(model.detailsHostId == nil)
    model.toggleDetails(for: nil)
    #expect(model.detailsHostId == nil)
}

@MainActor
@Test func cardsPanelFollowsTheSelection() {
    let model = cardsModel()
    model.toggleDetails(for: 1)
    // A click on another card, an arrow key, a host that was just added.
    model.pick(2)
    #expect(model.detailsHostId == 2)
    model.selectedHostId = 3
    #expect(model.detailsHostId == 3)
    model.hosts = [cardsHost(1, "a"), cardsHost(2, "b"), cardsHost(3, "c"), cardsHost(4, "new")]
    model.reveal(4)
    #expect(model.detailsHostId == 4)
    // Revealed, not picked: ⌫ outside the grid still does not ask about it.
    let target = HostsViewModel.deleteTarget(selected: model.selectedHostId, picked: model.pickedHostId, listHasFocus: false)
    #expect(target == nil)
}

@MainActor
@Test func cardsPanelClosesWhenItsHostIsDeleted() {
    let model = cardsModel()
    model.toggleDetails(for: 2)
    model.hosts = [cardsHost(1, "a"), cardsHost(3, "c")]
    #expect(model.selectedHostId == nil)
    #expect(model.showsDetails == false)
    // Closed, not waiting: the next card that is selected does not bring the panel back.
    model.pick(1)
    #expect(model.detailsHostId == nil)
}

@MainActor
@Test func cardsPanelClosesWhenAFilterHidesItsHost() {
    let model = cardsModel()
    model.toggleDetails(for: 2)
    // Still shown: stays.
    model.keepSelection(within: [1, 2])
    #expect(model.detailsHostId == 2)
    // A search left only the others.
    model.keepSelection(within: [1, 3])
    #expect(model.selectedHostId == nil)
    #expect(model.showsDetails == false)
}

@MainActor
@Test func cardsPanelStateIsNotAStoredPreference() {
    let model = cardsModel()
    model.toggleDetails(for: 1)
    // A new window, or the next launch: the cards alone.
    let next = HostsViewModel()
    next.hosts = [cardsHost(1, "a")]
    #expect(next.showsDetails == false)
    #expect(next.selectedHostId == nil)
}

@Test func cardsOneButtonShowsOnTheHoveredAndOnTheSelectedCard() {
    #expect(HostsViewModel.showsDetailsButton(isHovered: false, isSelected: false) == false)
    #expect(HostsViewModel.showsDetailsButton(isHovered: true, isSelected: false))
    #expect(HostsViewModel.showsDetailsButton(isHovered: false, isSelected: true))
    #expect(HostsViewModel.showsDetailsButton(isHovered: true, isSelected: true))
}

@Test func cardsEveryoneStartsOnTheGridUnderANewPreferenceKey() {
    #expect(HostsViewModel.Layout.standard == .grid)
    // The old key holds "list" for every existing user, with the old meaning.
    #expect(HostsViewModel.Layout.preferenceKey == "hostsLayout")
    #expect(HostsViewModel.Layout.preferenceKey != "hostsViewMode")
    #expect(HostsViewModel.Layout.stored(nil) == .grid)
    #expect(HostsViewModel.Layout.stored("list") == .list)
    #expect(HostsViewModel.Layout.stored("grid") == .grid)
    #expect(HostsViewModel.Layout.stored("table") == .grid)
}

@MainActor
@Test func cardsColumnsAtTheSizesThePageIsCheckedAt() {
    // Page widths behind a 228 pt sidebar; the grid keeps 34 pt of padding, the panel takes
    // its width and a hairline.
    let insets: CGFloat = 34
    let panel: CGFloat = HostListView.panelWidth + 1
    let minimum: CGFloat = HostListView.cardMinimum
    let regular: CGFloat = 1200 - 228
    let smallest: CGFloat = 900 - 228
    let regularWidth: CGFloat = regular - insets
    let regularBesidePanel: CGFloat = regular - panel - insets
    let smallestWidth: CGFloat = smallest - insets
    let smallestBesidePanel: CGFloat = smallest - panel - insets
    #expect(HostsViewModel.gridColumns(width: regularWidth, minimum: minimum, spacing: DS.Space.card) == 3)
    #expect(HostsViewModel.gridColumns(width: regularBesidePanel, minimum: minimum, spacing: DS.Space.card) == 2)
    #expect(HostsViewModel.gridColumns(width: smallestWidth, minimum: minimum, spacing: DS.Space.card) == 2)
    #expect(HostsViewModel.gridColumns(width: smallestBesidePanel, minimum: minimum, spacing: DS.Space.card) == 1)
}

@MainActor
@Test func cardsALinkFromAnotherPageOpensTheRecordOfItsHost() {
    let window = AppViewModel()
    window.selectedSidebar = .keys
    let page = window.hostsPage
    page.hosts = [cardsHost(1, "a"), cardsHost(2, "b"), cardsHost(3, "c")]
    // What would hide the host on the page.
    page.searchText = "zzz"
    page.selectedTag = "prod"
    page.showsOnlineOnly = true
    let asked = page.revealCount

    window.reveal(host: cardsHost(2, "b"))

    #expect(window.selectedSidebar == .terminal)
    #expect(page.detailsHostId == 2)
    #expect(page.hostToBringIntoView == 2)
    #expect(page.revealedHostId == 2)
    let askedOnce: Bool = page.revealCount == asked + 1
    #expect(askedOnce)
    #expect(page.searchText.isEmpty)
    #expect(page.selectedTag == nil)
    #expect(page.showsOnlineOnly == false)
    // The page chose it, not the user: ⌫ outside the grid does not ask about it.
    let target = HostsViewModel.deleteTarget(selected: page.selectedHostId, picked: page.pickedHostId, listHasFocus: false)
    #expect(target == nil)

    // The same link while the panel already shows that host: it stays (a toggle would close it).
    window.reveal(host: cardsHost(2, "b"))
    #expect(page.detailsHostId == 2)
}

@MainActor
@Test func cardsALinkBeforeTheFirstReadKeepsItsHostUntilTheReadSaysOtherwise() {
    // The Hosts page was never opened in this window: nothing is read yet.
    let model = HostsViewModel()
    model.showRecord(of: 2)
    #expect(model.detailsHostId == 2)
    model.hosts = [cardsHost(1, "a"), cardsHost(2, "b")]
    #expect(model.detailsHostId == 2)
    // A host the read does not bring (deleted meanwhile): no selection, no panel.
    let other = HostsViewModel()
    other.showRecord(of: 9)
    other.hosts = [cardsHost(1, "a")]
    #expect(other.selectedHostId == nil)
    #expect(other.showsDetails == false)
}

@MainActor
@Test func cardsAPickDoesNotOutliveTheSelectionItMade() {
    let model = cardsModel()
    model.pick(2)
    // A search hid the host: nothing is selected, and nothing is "picked" any more.
    model.keepSelection(within: [1, 3])
    #expect(model.selectedHostId == nil)
    #expect(model.pickedHostId == nil)
    // The page selects the same host by itself later (a link, a reveal): not the user's choice.
    model.reveal(2)
    #expect(model.selectedHostId == 2)
    let afterFilter = HostsViewModel.deleteTarget(selected: model.selectedHostId, picked: model.pickedHostId, listHasFocus: false)
    #expect(afterFilter == nil)

    // The same when an arrow key moved the selection on and the page came back to the host.
    model.pick(2)
    model.selectedHostId = 3
    #expect(model.pickedHostId == nil)
    model.showRecord(of: 2)
    let afterArrow = HostsViewModel.deleteTarget(selected: model.selectedHostId, picked: model.pickedHostId, listHasFocus: false)
    #expect(afterArrow == nil)
    // A click is still a pick.
    model.pick(2)
    let clicked = HostsViewModel.deleteTarget(selected: model.selectedHostId, picked: model.pickedHostId, listHasFocus: false)
    #expect(clicked == 2)
}

@MainActor
@Test func cardsBesideThePanelInTheSmallestWindowACardFitsTheRoom() {
    // 900 pt window, 228 pt sidebar, the panel and its hairline: 291 pt for the grid, 257 for a card.
    let grid: CGFloat = 900 - 228 - HostListView.panelWidth - 1
    let room: CGFloat = grid - HostListView.gridInsets
    let narrow: CGFloat = HostListView.cardWidthMinimum(gridWidth: grid)
    let fits: Bool = narrow <= room
    #expect(fits)
    #expect(HostsViewModel.gridColumns(width: room, minimum: narrow, spacing: DS.Space.card) == 1)
    // With room to spare, and before the grid is measured, the minimum is the card's own.
    let wide: CGFloat = HostListView.cardWidthMinimum(gridWidth: 972)
    let unmeasured: CGFloat = HostListView.cardWidthMinimum(gridWidth: 0)
    #expect(wide == HostListView.cardMinimum)
    #expect(unmeasured == HostListView.cardMinimum)
}

@Test func cardsTagsGiveWayToTheirNumberInsteadOfBeingSqueezed() {
    // What the card's third line tries in turn: two tags by name, one, none (then "+N").
    #expect(HostCardView.shownTagCounts(of: 0) == [0])
    #expect(HostCardView.shownTagCounts(of: 1) == [1, 0])
    #expect(HostCardView.shownTagCounts(of: 2) == [2, 1, 0])
    #expect(HostCardView.shownTagCounts(of: 5) == [2, 1, 0])
}

@Test func cardsAHostThatWasNeverConnectedToHasNoNumbersToShow() {
    // Nothing is drawn for what does not exist: no cards of dashes, no empty chart.
    let never = HostDetailFormat.hasHistory(lastConnected: nil, recordCount: 0)
    #expect(!never)
    // Known from the host itself before its history is read…
    let connectedBefore = HostDetailFormat.hasHistory(lastConnected: Date(timeIntervalSince1970: 1_700_000_000), recordCount: 0)
    #expect(connectedBefore)
    // …and a host whose only attempts failed has a history too.
    let onlyFailures = HostDetailFormat.hasHistory(lastConnected: nil, recordCount: 2)
    #expect(onlyFailures)
}
