import SwiftUI

extension AppViewModel {
    /// The sidebar lists pages only: the open sessions are the tabs in the toolbar. While a
    /// terminal or the New Tab Host Picker is shown no row is selected — the page under it is not
    /// what is on screen, and a click on its row has to be a change of selection to bring the page back.
    var sidebarSelection: SidebarItem? {
        (isViewingTerminal || isShowingNewTabPicker) ? nil : selectedSidebar
    }

    func select(_ item: SidebarItem?) {
        guard let item else { return }
        selectedSidebar = item
        isViewingTerminal = false
        isShowingNewTabPicker = false
        sidebarVisibility = (item == .sftp) ? .detailOnly : .all
    }

    /// The number next to a page in the sidebar; 0 shows nothing. Only what is going on right
    /// now (transfers, tunnels): how many records a page holds is said on the page.
    func badge(for item: SidebarItem) -> Int {
        switch item {
        case .sftp: return sftp.transfers.filter { $0.state == .running }.count
        case .portForwards: return PortForwardManager.shared.statuses.values.filter { $0 == .active }.count
        case .terminal, .snippets, .keys, .identities, .knownHosts, .docker,
             .batchCommand, .monitoring, .logs, .settings: return 0
        }
    }
}

/// Source-list sidebar (system sidebar style): what you connect with, what is stored in the
/// vault, and the ops tools. Pages only — the sessions are the tabs in the toolbar. Settings live
/// in the Settings window (⌘,).
struct SidebarView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(SecurityViewModel.self) private var securityVM

    private let connectItems: [SidebarItem] = [.terminal, .sftp, .portForwards, .snippets]
    private let vaultItems: [SidebarItem] = [.keys, .identities, .knownHosts]
    private let toolItems: [SidebarItem] = [.batchCommand, .monitoring, .docker, .logs]

    var body: some View {
        // The footer sits under the list, not over it: in a small window the rows would show
        // through it.
        VStack(spacing: 0) {
            sections
            footer
        }
    }

    private var sections: some View {
        List(selection: selection) {
            Section("Connect") {
                ForEach(connectItems) { row($0) }
            }
            Section("Vault") {
                ForEach(vaultItems) { row($0) }
            }
            Section("Tools") {
                ForEach(toolItems) { row($0) }
            }
        }
        .listStyle(.sidebar)
        // The selection is the tinted pill of `selectionTint`, with or without the keyboard
        // focus: the system's own highlight (a solid accent bar while the list has the focus)
        // is switched off.
        .background(SidebarSelectionQuieter(selection: viewModel.sidebarSelection))
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { viewModel.sidebarSelection },
            set: { viewModel.select($0) }
        )
    }

    private func row(_ item: SidebarItem) -> some View {
        DSSidebarLabel(item: item)
            .fontWeight(viewModel.sidebarSelection == item ? .semibold : nil)
            .badge(viewModel.badge(for: item))
            .tag(item)
            .listRowBackground(selectionTint(item))
    }

    /// The system's selection pill, tinted with the accent (the same pill as the active tab).
    @ViewBuilder
    private func selectionTint(_ row: SidebarItem) -> some View {
        if viewModel.sidebarSelection == row {
            let pill = RoundedRectangle(cornerRadius: DS.Radius.sidebarRow, style: .continuous)
            pill
                .fill(Color.accentColor.opacity(0.2))
                .overlay(pill.strokeBorder(Color.accentColor.opacity(0.34), lineWidth: 1))
                // The row's background spans the column; the system's pill is inset.
                .padding(.horizontal, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.xs) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")

            Spacer(minLength: 0)

            if securityVM.hasMasterPassword {
                DSRowButton("lock", help: "Lock App (⇧⌘L)") {
                    securityVM.lock()
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
    }
}

/// Switches off the highlight AppKit draws for the selected row of the sidebar's list. SwiftUI
/// has no way to say so: `listRowBackground` only replaces the unfocused look, and a focused
/// sidebar still paints the solid accent bar over it. Arrow keys, VoiceOver and the selection
/// itself are unchanged — only who draws it.
private struct SidebarSelectionQuieter: NSViewRepresentable {
    /// Not used: a change of selection is when the list rebuilds its rows, so apply again.
    let selection: SidebarItem?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // After this update: the list may not be in the window yet.
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            Self.table(near: view)?.selectionHighlightStyle = .none
        }
    }

    /// The closest table to `view`: the list this view is the background of.
    private static func table(near view: NSView) -> NSTableView? {
        var ancestor = view.superview
        var levels = 0
        while let current = ancestor, levels < 6 {
            if let table = firstTable(in: current, depth: 0) { return table }
            ancestor = current.superview
            levels += 1
        }
        return nil
    }

    private static func firstTable(in view: NSView, depth: Int) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        guard depth < 8 else { return nil }
        for child in view.subviews {
            if let table = firstTable(in: child, depth: depth + 1) { return table }
        }
        return nil
    }
}
