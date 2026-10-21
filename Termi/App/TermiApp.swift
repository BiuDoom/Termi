import SwiftUI

/// Entry point is `main.swift` (the executable doubles as the SSH askpass helper).
struct TermiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var securityVM = SecurityViewModel()
    @FocusedValue(\.appViewModel) private var focusedWindowVM: AppViewModel?
    @Environment(\.openWindow) var openWindow
    @AppStorage("appLanguage", store: AppProfile.defaults) private var appLanguage = "system"

    /// What every menu command acts on. Nil while the app is locked (and at launch, until it is
    /// known whether it is), so no command can reach a window (or the sessions in it) from
    /// behind the lock screen.
    private var focusedVM: AppViewModel? {
        securityVM.hidesContent || focusedWindowVM?.isReplacingData == true ? nil : focusedWindowVM
    }

    private var appLocale: Locale {
        switch appLanguage {
        case "en": Locale(identifier: "en")
        case "zh-Hans": Locale(identifier: "zh-Hans")
        default: .current
        }
    }

    private var isViewingTerminal: Bool {
        focusedVM?.isViewingTerminal == true && focusedVM?.activeTab != nil
    }

    /// The Hosts page is in front with a host selected: its record can be shown or put away.
    private var canToggleHostDetails: Bool {
        guard let focusedVM, !isViewingTerminal, focusedVM.selectedSidebar == .terminal else { return false }
        return focusedVM.hostsPage.selectedHostId != nil
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            // At least 900 × 600, and never smaller than the page on screen needs: a plain
            // minimum frame on the root would let a wider page be clipped on both sides.
            ZStack {
                Color.clear
                    .frame(minWidth: 900, minHeight: 600)
                WindowRootView()
                    .environment(securityVM)
                    .environment(\.locale, appLocale)
            }
            // Every @AppStorage of the scene reads and writes the profile's preferences.
            .defaultAppStorage(AppProfile.defaults)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 800)
        .commands {
            SidebarCommands()

            // File > New Window (⌘N) + New Tab Host Picker (⌘T) + Local Terminal (⌘L)
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Tab — Choose Host…") {
                    focusedVM?.openNewTabPicker()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(focusedVM == nil)

                Button("New Local Terminal") {
                    focusedVM?.addLocalTerminalTab()
                    focusedVM?.selectedSidebar = .terminal
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(focusedVM == nil)

                Button("Quick Connect") {
                    focusedVM?.openNewTabPicker()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(focusedVM == nil)
            }

            // File > Close (⌘W): the focused pane or tab while a terminal is showing, otherwise
            // the window. Replaces the system item, which always closed the whole window.
            CommandGroup(replacing: .saveItem) {
                Button {
                    if isViewingTerminal {
                        focusedVM?.confirmAndCloseFocusedPane()
                    } else if focusedVM?.isShowingNewTabPicker == true {
                        focusedVM?.selectVaults()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                } label: {
                    if isViewingTerminal {
                        Text("Close Tab or Pane")
                    } else {
                        Text("Close Window")
                    }
                }
                .keyboardShortcut("w", modifiers: .command)

                if isViewingTerminal {
                    Button("Close Window") {
                        NSApp.keyWindow?.performClose(nil)
                    }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                }
            }

            // Host menu — create, inspect/edit, connect, SFTP
            CommandMenu("Host") {
                Button("New Host") {
                    focusedVM?.selectVaults()
                    focusedVM?.selectedSidebar = .terminal
                    focusedVM?.hostsPage.newHostGroupId = nil
                    focusedVM?.hostsPage.showingAddHost = true
                }
                .disabled(focusedVM == nil)

                Button("New Group") {
                    focusedVM?.selectVaults()
                    focusedVM?.selectedSidebar = .terminal
                    focusedVM?.hostsPage.showingAddGroup = true
                }
                .disabled(focusedVM == nil)

                Divider()

                Button("Connect Selected Host") {
                    if let host = focusedVM?.hostsPage.selectedHost {
                        focusedVM?.connect(to: host)
                    }
                }
                .disabled(focusedVM?.hostsPage.selectedHost == nil)

                Button(focusedVM?.hostsPage.showsDetails == true && canToggleHostDetails
                       ? "Hide Host Inspector" : "Show Host Inspector") {
                    focusedVM?.hostsPage.toggleDetails()
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!canToggleHostDetails)
            }

            // Go menu — Vaults, SFTP, and sub-pages
            CommandMenu("Go") {
                Button("Vaults — Hosts") {
                    focusedVM?.selectVaults()
                    focusedVM?.selectedSidebar = .terminal
                }
                .keyboardShortcut("1", modifiers: [.command, .control])
                .disabled(focusedVM == nil)

                Button("SFTP Browser") {
                    focusedVM?.selectSFTP()
                }
                .keyboardShortcut("2", modifiers: [.command, .control])
                .disabled(focusedVM == nil)

                Divider()

                Button("Keychain") {
                    focusedVM?.select(.keys)
                }
                .disabled(focusedVM == nil)

                Button("Identities") {
                    focusedVM?.select(.identities)
                }
                .disabled(focusedVM == nil)

                Button("Port Forwarding") {
                    focusedVM?.select(.portForwards)
                }
                .disabled(focusedVM == nil)

                Button("Snippets") {
                    focusedVM?.select(.snippets)
                }
                .disabled(focusedVM == nil)

                Button("Known Hosts") {
                    focusedVM?.select(.knownHosts)
                }
                .disabled(focusedVM == nil)

                Button("History") {
                    focusedVM?.select(.logs)
                }
                .disabled(focusedVM == nil)
            }

            // Tabs menu — duplicate + switching (⌘1-9, ⌘[, ⌘])
            CommandMenu("Tabs") {
                Button("Duplicate Tab") {
                    if let id = focusedVM?.activeTabId {
                        focusedVM?.duplicateTab(id)
                    }
                }
                .disabled(!isViewingTerminal)

                Button("Rename Tab…") {
                    if let id = focusedVM?.activeTabId {
                        focusedVM?.renamingTabId = id
                    }
                }
                .disabled(!isViewingTerminal)

                Divider()

                ForEach(1...9, id: \.self) { n in
                    Button("Select Tab \(n)") {
                        if n == 1 && (focusedVM?.tabs.isEmpty == true) {
                            focusedVM?.selectVaults()
                        } else if n == 2 && (focusedVM?.tabs.isEmpty == true) {
                            focusedVM?.selectSFTP()
                        } else {
                            focusedVM?.selectTab(at: n - 1)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                    .disabled(focusedVM == nil)
                }

                Divider()

                Button("Select Previous Tab") {
                    focusedVM?.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled((focusedVM?.tabs.count ?? 0) < 2)

                Button("Select Next Tab") {
                    focusedVM?.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled((focusedVM?.tabs.count ?? 0) < 2)
            }

            // Terminal menu — panes, broadcast, find, inspector, SFTP
            CommandMenu("Terminal") {
                Button("Split Right") {
                    focusedVM?.splitFocusedPane(.horizontal)
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!isViewingTerminal)

                Button("Split Down") {
                    focusedVM?.splitFocusedPane(.vertical)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!isViewingTerminal)

                Button("Next Pane") {
                    focusedVM?.focusAdjacentPane(forward: true)
                }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(focusedVM?.activeTab?.isSplit != true)

                Button("Previous Pane") {
                    focusedVM?.focusAdjacentPane(forward: false)
                }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(focusedVM?.activeTab?.isSplit != true)

                Button {
                    focusedVM?.toggleBroadcast()
                } label: {
                    if focusedVM?.activeTab?.broadcastInput == true {
                        Text("Stop Broadcasting Input")
                    } else {
                        Text("Broadcast Input to All Panes")
                    }
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(focusedVM?.activeTab?.isSplit != true)

                Divider()

                Button("Find…") {
                    focusedVM?.focusedSession?.showFind()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!isViewingTerminal)

                Button("Find Next") {
                    focusedVM?.focusedSession?.findNext()
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!isViewingTerminal)

                Button("Find Previous") {
                    focusedVM?.focusedSession?.findPrevious()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!isViewingTerminal)

                Button("Clear Buffer") {
                    focusedVM?.focusedSession?.clearBuffer()
                }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(!isViewingTerminal)

                Divider()

                Button("Toggle Terminal Inspector") {
                    focusedVM?.showSnippetPanel.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!isViewingTerminal)

                Button("Open SFTP for Host") {
                    focusedVM?.openSFTPForFocusedSession()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(focusedVM?.focusedSession?.isSSH != true || !isViewingTerminal)

                Button("Reconnect") {
                    focusedVM?.focusedSession?.reconnect()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(focusedVM?.focusedSession?.isSSH != true || !isViewingTerminal)

                Divider()

                Button("Increase Font Size") {
                    focusedVM?.adjustFontSize(by: 1)
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(focusedVM == nil)

                Button("Decrease Font Size") {
                    focusedVM?.adjustFontSize(by: -1)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(focusedVM == nil)

                Button("Reset Font Size") {
                    focusedVM?.adjustFontSize(by: 0)
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(focusedVM == nil)
            }

            CommandGroup(after: .toolbar) {
                Button("Command Palette") {
                    focusedVM?.showCommandPalette = true
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(focusedVM == nil)

                Divider()

                Button("Keyboard Shortcuts") {
                    focusedVM?.showKeyboardShortcuts = true
                }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(focusedVM == nil)

                Button("Lock App") {
                    securityVM.lock()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!securityVM.hasMasterPassword || securityVM.isLocked)
            }
        }

        Settings {
            SettingsWindowContent()
                .environment(securityVM)
                .environment(\.locale, appLocale)
                // The panes size themselves (fixed width, own height); this only keeps the
                // window's width while the lock screen stands in for them.
                .frame(minWidth: 760)
                .defaultAppStorage(AppProfile.defaults)
        }
    }
}

/// The Settings window is a scene of its own: the lock screen of the main windows does not
/// cover it, so it shows one itself. A view rather than an `if` in the scene body, so that the
/// lock state is read (and tracked) in a view body and the window follows every lock / unlock.
private struct SettingsWindowContent: View {
    @Environment(SecurityViewModel.self) private var securityVM

    var body: some View {
        if securityVM.isLocked {
            LockScreenView(securityVM: securityVM)
        } else if securityVM.isLockStateKnown {
            SettingsView()
        } else {
            // Opened before any main window has asked whether the app is locked: ask here,
            // and show nothing until the answer is in.
            Color.clear
                .frame(height: 420)
                .task { await securityVM.checkMasterPassword() }
        }
    }
}
