import Testing
import Foundation
@testable import Termi

// MARK: - Tab Management

@Test @MainActor func addLocalTerminalTab() {
    let vm = AppViewModel()
    #expect(vm.tabs.isEmpty)
    #expect(vm.activeTabId == nil)

    vm.addLocalTerminalTab()

    #expect(vm.tabs.count == 1)
    #expect(vm.activeTabId == vm.tabs[0].id)
    #expect(vm.tabs[0].title == String(localized: "Local"))
    #expect(vm.tabs[0].isSSH == false)
}

@Test @MainActor func addSSHTab() {
    let vm = AppViewModel()
    vm.addSSHTab(title: "prod-server", hostId: 42)

    #expect(vm.tabs.count == 1)
    #expect(vm.tabs[0].isSSH == true)
    #expect(vm.tabs[0].hostId == 42)
    #expect(vm.tabs[0].title == "prod-server")
    #expect(vm.activeTabId == vm.tabs[0].id)
}

@Test @MainActor func addMultipleTabs() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    vm.addSSHTab(title: "server1", hostId: 1)
    vm.addLocalTerminalTab()

    #expect(vm.tabs.count == 3)
    // Active tab should be the last added
    #expect(vm.activeTabId == vm.tabs[2].id)
}

@Test @MainActor func closeTabSwitchesToNext() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    vm.addLocalTerminalTab()
    vm.addLocalTerminalTab()

    let firstTabId = vm.tabs[0].id
    let secondTabId = vm.tabs[1].id

    // Activate first tab, then close it
    vm.activeTabId = firstTabId
    vm.closeTab(firstTabId)

    #expect(vm.tabs.count == 2)
    // Should switch to next tab (which was at index 1, now at index 0)
    #expect(vm.activeTabId == secondTabId)
}

@Test @MainActor func closeLastRemainingTab() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    let tabId = vm.tabs[0].id

    vm.closeTab(tabId)

    #expect(vm.tabs.isEmpty)
    #expect(vm.activeTabId == nil)
}

@Test @MainActor func closeInactiveTab() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    vm.addLocalTerminalTab()

    let firstTabId = vm.tabs[0].id
    let secondTabId = vm.tabs[1].id

    // Active is second tab
    #expect(vm.activeTabId == secondTabId)

    // Close first (inactive) tab
    vm.closeTab(firstTabId)

    #expect(vm.tabs.count == 1)
    // Active tab should remain unchanged
    #expect(vm.activeTabId == secondTabId)
}

@Test @MainActor func closeNonexistentTabNoOp() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    let fakeId = UUID()

    vm.closeTab(fakeId)

    #expect(vm.tabs.count == 1)
}

@Test @MainActor func selectTab() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    vm.addLocalTerminalTab()
    vm.addLocalTerminalTab()

    vm.selectTab(at: 0)
    #expect(vm.activeTabId == vm.tabs[0].id)

    vm.selectTab(at: 2)
    #expect(vm.activeTabId == vm.tabs[2].id)
}

@Test @MainActor func selectTabOutOfBoundsNoOp() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    let originalActive = vm.activeTabId

    vm.selectTab(at: -1)
    #expect(vm.activeTabId == originalActive)

    vm.selectTab(at: 999)
    #expect(vm.activeTabId == originalActive)
}

@Test @MainActor func closeOtherTabs() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    vm.addLocalTerminalTab()
    vm.addLocalTerminalTab()

    let keepId = vm.tabs[1].id
    vm.closeOtherTabs(keepId)

    #expect(vm.tabs.count == 1)
    #expect(vm.tabs[0].id == keepId)
    #expect(vm.activeTabId == keepId)
}

@Test @MainActor func closeTabsToRight() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab() // 0
    vm.addLocalTerminalTab() // 1
    vm.addLocalTerminalTab() // 2
    vm.addLocalTerminalTab() // 3

    let pivotId = vm.tabs[1].id
    vm.closeTabsToRight(pivotId)

    #expect(vm.tabs.count == 2) // tabs 0 and 1 remain
    #expect(vm.tabs[0].title == String(localized: "Local"))
    #expect(vm.tabs[1].id == pivotId)
}

@Test @MainActor func closeAllTabs() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    vm.addLocalTerminalTab()
    vm.addLocalTerminalTab()

    vm.closeAllTabs()

    #expect(vm.tabs.isEmpty)
    #expect(vm.activeTabId == nil)
}

@Test @MainActor func moveTab() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    vm.addSSHTab(title: "S1", hostId: 1)
    vm.addSSHTab(title: "S2", hostId: 2)

    let firstId = vm.tabs[0].id
    let lastId = vm.tabs[2].id

    vm.moveTab(from: firstId, to: lastId)

    // After move, the tab order should change
    #expect(vm.tabs.count == 3)
    // The first tab should now be at position where lastId was
    #expect(vm.tabs[2].id == firstId)
}

@Test @MainActor func moveTabSamePositionNoOp() {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    let tabId = vm.tabs[0].id

    vm.moveTab(from: tabId, to: tabId)
    #expect(vm.tabs.count == 1) // No crash, no change
}

@Test @MainActor func activeTabComputedProperty() {
    let vm = AppViewModel()
    #expect(vm.activeTab == nil)

    vm.addLocalTerminalTab()
    #expect(vm.activeTab != nil)
    #expect(vm.activeTab?.id == vm.activeTabId)
}

@Test @MainActor func addToast() {
    let vm = AppViewModel()
    #expect(vm.toasts.isEmpty)

    vm.addToast(.success, "Operation completed")

    #expect(vm.toasts.count == 1)
    #expect(vm.toasts[0].message == "Operation completed")
}

@Test @MainActor func addMultipleToasts() {
    let vm = AppViewModel()
    vm.addToast(.success, "OK")
    vm.addToast(.error, "Failed")
    vm.addToast(.warning, "Careful")

    #expect(vm.toasts.count == 3)
}

@Test @MainActor func defaultSidebarIsTerminal() {
    let vm = AppViewModel()
    #expect(vm.selectedSidebar == .terminal)
}

@Test @MainActor func defaultTerminalFontSize() {
    let vm = AppViewModel()
    #expect(vm.terminalFontSize == 14)
}
