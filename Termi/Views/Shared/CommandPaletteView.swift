import SwiftUI

/// Command palette (⌘K): one search field over sessions, hosts, snippets, actions and pages.
/// ↑ / ↓ move the selection, Return (or a click) runs it, ⌘Return opens a host in SFTP, Esc closes.
struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(SecurityViewModel.self) private var securityVM

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var hosts: [Host] = []
    @State private var snippets: [Snippet] = []
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let sections = self.sections
        let rowCount = sections.reduce(0) { $0 + $1.items.count }

        VStack(spacing: 0) {
            searchField

            Divider()

            if sections.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity)
                    .frame(height: Layout.empty)
            } else {
                // As high as its rows, up to the full list: a few results leave no empty band
                // between the last row and the bar.
                resultList(sections)
                    .frame(height: Self.listHeight(rows: rowCount, sections: sections.count))
            }

            Divider()

            hints(count: rowCount, sectionCount: sections.count)
        }
        .frame(width: 620)
        .onAppear {
            isSearchFocused = true
            loadHosts()
            #if DEBUG
            // -debugPaletteQuery <text>: open with a query typed, for screenshots.
            if let debugQuery = AppProfile.arguments.string(forKey: "debugPaletteQuery") {
                query = debugQuery
            }
            #endif
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        // Rows can go away without a new query (a session ends): keep the selection on a row.
        .onChange(of: sections.last.map { $0.startIndex + $0.items.count } ?? 0) { _, count in
            if selectedIndex >= count { selectedIndex = max(0, count - 1) }
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < results.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                // As wide as a row's icon: the query lines up with the row titles.
                .frame(width: PaletteRowView.iconSize)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Type a command, host name, or action…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .autocorrectionDisabled()
                .focused($isSearchFocused)
                .onSubmit { executeSelected() }

            if !query.isEmpty {
                DSRowButton("xmark.circle.fill", help: "Clear") {
                    query = ""
                    isSearchFocused = true
                }
            }

            // A sheet does not close on a click outside: the key cap is the way out for the mouse.
            Button {
                dismiss()
            } label: {
                DSShortcut("esc")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.lg)
    }

    // MARK: - Results

    private func resultList(_ sections: [PaletteSection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    ForEach(sections) { section in
                        // One kind of result needs no heading: its rows say what they are.
                        if sections.count > 1 {
                            Text(section.title)
                                .font(DS.Font.sectionHeader)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, DS.Space.card)
                                .frame(height: DS.Height.sectionHeader, alignment: .bottomLeading)
                                .padding(.bottom, DS.Space.xs)
                                .accessibilityAddTraits(.isHeader)
                                .id(section.id)
                        } else {
                            Color.clear
                                .frame(height: 0)
                                .id(section.id)
                        }

                        ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                            let index = section.startIndex + offset
                            Button {
                                selectedIndex = index
                                executeSelected()
                            } label: {
                                PaletteRowView(item: item, query: trimmedQuery, isSelected: index == selectedIndex)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                            .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, DS.Space.sm)
            }
            .onChange(of: selectedIndex) { _, newValue in
                // Just far enough to keep the selection in view; the first row brings its header along.
                if newValue == 0, let first = sections.first {
                    proxy.scrollTo(first.id, anchor: .top)
                } else if let item = results[safe: newValue] {
                    proxy.scrollTo(item.id)
                }
            }
            .onChange(of: query) { _, _ in
                // New results start at the top (the selection is reset to the first row).
                if let first = sections.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }

    /// What the palette offers for the current query, in display order. Section and action
    /// titles are localized here, so the search matches what is on screen.
    private var sections: [PaletteSection] {
        let q = trimmedQuery
        var groups: [(PaletteSection.Kind, [PaletteItem])] = []

        // Open sessions: the way back to a terminal
        var sessionItems: [PaletteItem] = []
        for tab in appViewModel.tabs where q.isEmpty || tab.title.lowercased().contains(q) {
            let host = appViewModel.host(of: tab)
            var parts = [String(localized: "Switch to session")]
            if tab.isSplit {
                parts.append(String(localized: "\(tab.panes.count) panes"))
            }
            if let jump = host?.firstJumpName(hosts: hosts, groups: appViewModel.hostsPage.allGroups) {
                parts.append(String(localized: "via \(jump)"))
            }
            sessionItems.append(PaletteItem(
                id: "session-\(tab.id.uuidString)",
                icon: .avatar(host, appViewModel.avatarStatus(of: tab)),
                title: tab.title,
                subtitle: parts.joined(separator: " · "),
                kind: .session(tab.id)
            ))
        }
        groups.append((.sessions, sessionItems))

        // Saved hosts: the ones connected to last, or the ones the query names; else a one-off
        // connection to a typed address
        var hostItems: [PaletteItem] = []
        let matchingHosts = q.isEmpty
            ? AppViewModel.recentHosts(hosts, limit: 5)
            : Array(Self.ranked(hosts.filter {
                $0.label.lowercased().contains(q) ||
                $0.hostname.lowercased().contains(q) ||
                $0.username.lowercased().contains(q)
            }, query: q).prefix(8))
        for host in matchingHosts {
            let status = appViewModel.avatarStatus(forHostId: host.id)
            hostItems.append(PaletteItem(
                id: "host-\(host.id.map(String.init) ?? UUID().uuidString)",
                icon: .avatar(host, status),
                title: host.displayName,
                subtitle: host.addressDescription,
                subtitleStyle: .address,
                // A host with a session gets another one: say so, the session is one section up.
                note: status == .none ? nil : String(localized: "Opens another tab"),
                date: host.lastConnectedDate,
                kind: .host(host)
            ))
        }
        if !q.isEmpty {

            // Quick connect to an address that isn't saved
            if matchingHosts.isEmpty, let adHoc = QuickConnectParser.parse(query), query.contains("@") {
                hostItems.append(PaletteItem(
                    id: "connect-\(adHoc.addressDescription)",
                    icon: .action("bolt.fill"),
                    title: String(localized: "Connect to \(adHoc.addressDescription)"),
                    subtitle: String(localized: "Open an SSH session without saving the host"),
                    kind: .quickConnect(adHoc)
                ))
            }
        }
        groups.append((q.isEmpty ? .recentHosts : .hosts, hostItems))

        // Snippets run in the focused terminal
        var snippetItems: [PaletteItem] = []
        if appViewModel.focusedSession?.isLive == true {
            let matchingSnippets = snippets.filter {
                q.isEmpty || $0.name.lowercased().contains(q) || $0.command.lowercased().contains(q)
            }
            for snippet in matchingSnippets.prefix(q.isEmpty ? 5 : 10) {
                snippetItems.append(PaletteItem(
                    id: "snippet-\(snippet.id.map(String.init) ?? snippet.name)",
                    icon: .action("curlybraces"),
                    title: snippet.name,
                    subtitle: snippet.command,
                    subtitleStyle: .command,
                    kind: .snippet(snippet)
                ))
            }
        }
        groups.append((.snippets, snippetItems))

        // Actions
        var commands: [PaletteCommand] = [
            PaletteCommand(.newTerminal, "terminal",
                           String(localized: "New Terminal"),
                           String(localized: "Open a new local terminal tab")),
            PaletteCommand(.quickConnect, "bolt.fill",
                           String(localized: "Quick Connect"),
                           String(localized: "Connect to a host by address")),
            PaletteCommand(.importSSHConfig, "square.and.arrow.down",
                           String(localized: "Import SSH Config"),
                           String(localized: "Import hosts from ~/.ssh/config"))
        ]
        // Locking needs a master password (the menu and the sidebar hide it the same way).
        if securityVM.hasMasterPassword {
            commands.append(PaletteCommand(.lockApp, "lock.fill",
                                           String(localized: "Lock App"),
                                           String(localized: "Require the master password to unlock")))
        }
        if appViewModel.isViewingTerminal, let tab = appViewModel.activeTab {
            commands.append(PaletteCommand(.splitRight, "rectangle.split.2x1",
                                           String(localized: "Split Right"),
                                           String(localized: "Split the focused pane")))
            commands.append(PaletteCommand(.splitDown, "rectangle.split.1x2",
                                           String(localized: "Split Down"),
                                           String(localized: "Split the focused pane")))
            if tab.isSplit {
                commands.append(PaletteCommand(.toggleBroadcast, "dot.radiowaves.left.and.right",
                                               tab.broadcastInput
                                                   ? String(localized: "Stop Broadcasting Input")
                                                   : String(localized: "Broadcast Input to All Panes"),
                                               String(localized: "Type into every pane of this tab")))
            }
            if appViewModel.focusedSession?.isSSH == true {
                commands.append(PaletteCommand(.openSFTP, "folder",
                                               String(localized: "Open SFTP"),
                                               String(localized: "Browse files on this host")))
                commands.append(PaletteCommand(.reconnect, "arrow.clockwise",
                                               String(localized: "Reconnect"),
                                               String(localized: "Reconnect the focused session")))
            }
        }
        groups.append((.actions, commands
            .filter { q.isEmpty || $0.title.lowercased().contains(q) }
            .map { command in
                PaletteItem(
                    id: "action-\(command.action.rawValue)",
                    icon: .action(command.icon),
                    title: command.title,
                    subtitle: command.subtitle,
                    kind: .action(command.action)
                )
            }))

        // Navigation: matches the localized title and, as before, the English page name
        var navigationItems: [PaletteItem] = []
        for nav in SidebarItem.allCases {
            let page = String(localized: String.LocalizationValue(nav.label))
            let title = String(localized: "Go to \(page)")
            guard q.isEmpty || title.lowercased().contains(q) || nav.label.lowercased().contains(q) else { continue }
            navigationItems.append(PaletteItem(
                id: "nav-\(nav.rawValue)",
                icon: .page(nav),
                title: title,
                subtitle: nil,
                kind: .navigation(nav)
            ))
        }
        groups.append((.navigation, navigationItems))

        var result: [PaletteSection] = []
        var startIndex = 0
        for (kind, items) in groups where !items.isEmpty {
            result.append(PaletteSection(id: kind, items: items, startIndex: startIndex))
            startIndex += items.count
        }
        return result
    }

    /// Hosts whose name carries the query come before those that match by address or user only
    /// ("test" finds every host of the user "tester"); the order within each group is kept.
    static func ranked(_ hosts: [Host], query: String) -> [Host] {
        let named = hosts.filter { $0.label.lowercased().contains(query) }
        let others = hosts.filter { !$0.label.lowercased().contains(query) }
        return named + others
    }

    private var trimmedQuery: String {
        query.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// The rows in display order — what the selection index counts.
    private var results: [PaletteItem] {
        sections.flatMap(\.items)
    }

    // MARK: - Execution

    private func executeSelected() {
        guard let item = results[safe: selectedIndex] else { return }

        switch item.kind {
        case .session(let id):
            appViewModel.activateTab(id)

        case .host(let host):
            appViewModel.connect(to: host)

        case .quickConnect(let host):
            appViewModel.addQuickConnectTab(host: host, password: nil)
            appViewModel.selectedSidebar = .terminal

        case .snippet(let snippet):
            if SnippetTemplate.placeholders(in: snippet.command).isEmpty {
                appViewModel.runSnippet(snippet.command, execute: true)
            } else {
                // Needs values for {{placeholders}} — use the snippet panel's form. It sits next
                // to the terminal only: from a page, the terminal comes to the front with it.
                if appViewModel.activeTab != nil {
                    appViewModel.isViewingTerminal = true
                }
                AppProfile.defaults.set(SnippetPanelView.InspectorTab.snippets.rawValue, forKey: "terminalInspectorTab")
                appViewModel.showSnippetPanel = true
            }

        case .navigation(let sidebar):
            if sidebar == .settings {
                // Settings live in their own window (⌘,), not in a page: what is on screen stays.
                openSettings()
            } else {
                // The page may already be the selected one, hidden behind a terminal (Hosts after
                // connecting): nothing reacts to a selection that does not change.
                appViewModel.selectedSidebar = sidebar
                appViewModel.isViewingTerminal = false
            }

        case .action(let action):
            executeAction(action)
        }

        dismiss()
    }

    /// ⌘Return on a host: its files instead of a shell.
    private var selectedHost: Host? {
        if case .host(let host)? = results[safe: selectedIndex]?.kind { return host }
        return nil
    }

    private func openSFTPForSelected() {
        guard let host = selectedHost else { return }
        appViewModel.openSFTP(for: host)
        dismiss()
    }

    // MARK: - Hints

    /// The list at its highest (the sheet is then 480 pt high), and the room of "no results".
    private enum Layout {
        static let fullList: CGFloat = 376
        static let empty: CGFloat = 220
    }

    /// What the rows need: a row takes 48 pt, a section heading 34, the list's padding 16.
    nonisolated static func contentHeight(rows: Int, sections: Int) -> CGFloat {
        let headings = sections > 1 ? sections : 0
        return CGFloat(rows * 48 + headings * 34 + 16)
    }

    /// The list is as high as its rows, never higher than the full list.
    nonisolated static func listHeight(rows: Int, sections: Int) -> CGFloat {
        min(Layout.fullList, contentHeight(rows: rows, sections: sections))
    }

    /// Whether the number of results is worth saying: only when not all of them are in view —
    /// rows on screen can be seen, not counted for the reader.
    nonisolated static func showsResultCount(rows: Int, sections: Int) -> Bool {
        contentHeight(rows: rows, sections: sections) > Layout.fullList
    }

    /// What the keys do, and how many rows there are when some are out of view.
    private func hints(count: Int, sectionCount: Int) -> some View {
        HStack(spacing: DS.Space.lg) {
            HStack(spacing: DS.Space.xs) {
                DSShortcut("↑")
                DSShortcut("↓")
                Text("to select")
            }
            HStack(spacing: DS.Space.xs) {
                DSShortcut("⏎")
                Text("to open")
            }
            Button {
                openSFTPForSelected()
            } label: {
                HStack(spacing: DS.Space.xs) {
                    DSShortcut("⌘")
                    DSShortcut("⏎")
                    Text(verbatim: "SFTP")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(selectedHost == nil)
            .help("Open SFTP")
            .accessibilityLabel(Text("Open SFTP"))

            Spacer(minLength: 0)

            if Self.showsResultCount(rows: count, sections: sectionCount) {
                Text("\(count) results")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.xl)
        .frame(height: 40)
    }

    private func executeAction(_ action: PaletteAction) {
        switch action {
        case .newTerminal:
            appViewModel.addLocalTerminalTab()
            appViewModel.selectedSidebar = .terminal
        case .quickConnect:
            appViewModel.showQuickConnect = true
        case .lockApp:
            securityVM.lock()
        case .importSSHConfig:
            Task {
                do {
                    let summary = try await ImportExportService.shared.importSSHConfig()
                    // The Hosts page may be the one on screen.
                    await appViewModel.hostsPage.loadHosts()
                    appViewModel.addToast(.success, summary.description)
                } catch {
                    appViewModel.addToast(.error, error.localizedDescription)
                }
            }
        case .splitRight:
            appViewModel.splitFocusedPane(.horizontal)
        case .splitDown:
            appViewModel.splitFocusedPane(.vertical)
        case .toggleBroadcast:
            appViewModel.toggleBroadcast()
        case .openSFTP:
            appViewModel.openSFTPForFocusedSession()
        case .reconnect:
            appViewModel.focusedSession?.reconnect()
        }
    }

    // MARK: - Data

    private func loadHosts() {
        Task {
            hosts = (try? await HostRepository.shared.fetchAll()) ?? []
            snippets = (try? await SnippetRepository.shared.fetchAll()) ?? []
        }
    }
}

// MARK: - Palette Item Types

private enum PaletteAction: String {
    case newTerminal
    case quickConnect
    case lockApp
    case importSSHConfig
    case splitRight
    case splitDown
    case toggleBroadcast
    case openSFTP
    case reconnect
}

/// An action as offered in the palette; title and subtitle are already localized.
private struct PaletteCommand {
    let action: PaletteAction
    let icon: String
    let title: String
    let subtitle: String

    init(_ action: PaletteAction, _ icon: String, _ title: String, _ subtitle: String) {
        self.action = action
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
    }
}

private struct PaletteItem: Identifiable {
    enum Icon {
        /// A host's tile with its live state; nil is the local shell.
        case avatar(Host?, DSHostAvatar.Status)
        /// A page: its category tile.
        case page(SidebarItem)
        /// An action or a snippet: a neutral tile with the glyph.
        case action(String)
    }

    let id: String
    let icon: Icon
    /// Display text: localized interface text or user data (host label, snippet name) — never a key.
    let title: String
    let subtitle: String?
    var subtitleStyle = SubtitleStyle.description
    /// Interface text after the subtitle (which may be data).
    var note: String?
    /// When the host was connected to last, at the row's end.
    var date: Date?
    let kind: PaletteItemKind

    enum SubtitleStyle {
        /// Interface text.
        case description
        /// Host address: monospaced, truncated in the middle.
        case address
        /// Shell command: monospaced, truncated at the tail (its beginning says what it does).
        case command
    }
}

private enum PaletteItemKind {
    case session(UUID)
    case host(Host)
    case quickConnect(Host)
    case snippet(Snippet)
    case navigation(SidebarItem)
    case action(PaletteAction)
}

private struct PaletteSection: Identifiable {
    enum Kind: String {
        case sessions, recentHosts, hosts, snippets, actions, navigation
    }

    let id: Kind
    let items: [PaletteItem]
    /// Position of the section's first row among all rows.
    let startIndex: Int

    var title: LocalizedStringKey {
        switch id {
        case .sessions: "Sessions"
        case .recentHosts: "Recent Hosts"
        case .hosts: "Hosts"
        case .snippets: "Snippets"
        case .actions: "Actions"
        case .navigation: "Navigation"
        }
    }
}

// MARK: - Palette Row

/// Tile, title over subtitle, then when the host was last used — on the selected row too: Return
/// is named once, in the bar under the list. The selected row is the accent pill of the master
/// lists, white text on it.
private struct PaletteRowView: View {
    static let iconSize: CGFloat = 28

    let item: PaletteItem
    /// Lowercased query: the part of the title it matches is set in bold.
    let query: String
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)

        HStack(spacing: DS.Space.md) {
            icon

            VStack(alignment: .leading, spacing: 1) {
                Text(CommandPaletteView.highlighted(item.title, query: query))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle = item.subtitle {
                    HStack(spacing: DS.Space.xs) {
                        Text(verbatim: subtitle)
                            .font(item.subtitleStyle == .description ? DS.Font.caption : DS.Font.caption.monospaced())
                            .truncationMode(item.subtitleStyle == .address ? .middle : .tail)
                        if let note = item.note {
                            Text(verbatim: "· \(note)")
                                .font(DS.Font.caption)
                                .layoutPriority(1)
                        }
                    }
                    // On the selection colour the secondary level is too faint to read.
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: DS.Space.sm)

            trailing
        }
        // The selection is the accent pill of the master lists, also while the window is not key.
        .dsListRow(isSelected: isSelected)
        .background(isHovered && !isSelected ? Color.primary.opacity(0.05) : Color.clear, in: shape)
        .onHover { isHovered = $0 }
        .animation(DS.Motion.quick, value: isHovered)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case .avatar(let host?, let status):
            DSHostAvatar(host, size: Self.iconSize, status: status)
        case .avatar(nil, let status):
            DSHostAvatar.local(size: Self.iconSize, status: status)
        case .page(let page):
            DSCategoryTile(page: page, size: Self.iconSize)
                .accessibilityHidden(true)
        case .action(let symbol):
            DSIconTile(.symbol(symbol), tint: Color(nsColor: .systemGray), size: Self.iconSize)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let date = item.date {
            DSRelativeTime(date)
                .font(DS.Font.caption.monospacedDigit())
                // On the selection colour the secondary level is too faint to read.
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
        }
    }

}

extension CommandPaletteView {
    /// Where `query` (lowercased) occurs in `title`, ignoring case; nil when it does not.
    nonisolated static func matchRange(of query: String, in title: String) -> Range<String.Index>? {
        guard !query.isEmpty else { return nil }
        return title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    }

    /// A row title with the part the query matches in bold.
    nonisolated static func highlighted(_ title: String, query: String) -> AttributedString {
        var text = AttributedString(title)
        text.swiftUI.font = .system(size: 13, weight: .medium)
        if let match = matchRange(of: query, in: title),
           let range = Range(match, in: text) {
            // Bold next to medium does not show at this size: the rest steps back to regular.
            text.swiftUI.font = .system(size: 13, weight: .regular)
            text[range].swiftUI.font = .system(size: 13, weight: .bold)
        }
        return text
    }
}
