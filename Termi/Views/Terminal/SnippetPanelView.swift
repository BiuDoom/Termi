import SwiftUI

/// The 4-tab inspector next to the terminal: Find, Snippets, History (session info & recent logs),
/// and Themes (live terminal color theme & font size switcher).
struct SnippetPanelView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(SecurityViewModel.self) private var securityVM
    /// "find", "snippets", "history" (or legacy "info"), or "themes"; ⇧⌘S opens the inspector on whichever was shown last.
    @AppStorage("terminalInspectorTab", store: AppProfile.defaults) private var tab = InspectorTab.snippets.rawValue
    @State private var snippets: [Snippet] = []
    /// False until the first read has finished: nothing is drawn before that, so opening the
    /// inspector does not flash the empty state.
    @State private var didLoad = false
    @State private var searchText = ""
    @State private var pending: PendingSnippet?

    enum InspectorTab: String {
        case find, snippets, history, themes, info
    }

    private var normalizedTab: Binding<String> {
        Binding(
            get: { tab == InspectorTab.info.rawValue ? InspectorTab.history.rawValue : tab },
            set: { tab = $0 }
        )
    }

    struct PendingSnippet: Identifiable {
        let id = UUID()
        let snippet: Snippet
        let execute: Bool
        let placeholders: [String]
    }

    private var filtered: [Snippet] {
        guard !searchText.isEmpty else { return snippets }
        let query = searchText.lowercased()
        return snippets.filter {
            $0.name.lowercased().contains(query)
                || $0.command.lowercased().contains(query)
                || ($0.category?.lowercased().contains(query) ?? false)
        }
    }

    private var canRun: Bool {
        appViewModel.focusedSession?.isLive == true
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: normalizedTab) {
                Text("Find").tag(InspectorTab.find.rawValue)
                Text("Snippets").tag(InspectorTab.snippets.rawValue)
                Text("History").tag(InspectorTab.history.rawValue)
                Text("Themes").tag(InspectorTab.themes.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, DS.Space.md + 2)
            .padding(.top, DS.Space.md)
            .padding(.bottom, DS.Space.sm)

            switch normalizedTab.wrappedValue {
            case InspectorTab.find.rawValue:
                TerminalFindInspectorTab()
            case InspectorTab.history.rawValue, InspectorTab.info.rawValue:
                SessionInfoView(snippets: snippets)
            case InspectorTab.themes.rawValue:
                TerminalThemesInspectorTab()
            default:
                snippetsTab
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // The panel stays mounted while another page is showing, so reload on every return to
        // the terminal (snippets may have been added or edited meanwhile).
        .task(id: appViewModel.isViewingTerminal) {
            guard appViewModel.isViewingTerminal else { return }
            snippets = (try? await SnippetRepository.shared.fetchAll()) ?? []
            didLoad = true
        }
        .sheet(item: $pending) { pending in
            SnippetVariablesSheet(pending: pending) { values in
                let command = SnippetTemplate.render(pending.snippet.command, values: values)
                appViewModel.runSnippet(command, execute: pending.execute)
            }
        }
        // The panel stays mounted behind the lock screen, and its sheet would stay in front.
        .onChange(of: securityVM.isLocked) { _, locked in
            if locked { pending = nil }
        }
    }

    // MARK: - Snippets

    private var snippetsTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                TextField("Search snippets", text: $searchText, prompt: Text("Search snippets"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                DSRowButton("square.and.pencil", help: "Manage snippets") {
                    appViewModel.selectedSidebar = .snippets
                    appViewModel.isViewingTerminal = false
                }
            }
            .padding(.horizontal, DS.Space.md + 2)
            .padding(.vertical, DS.Space.xs)

            if !didLoad {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snippets.isEmpty {
                ContentUnavailableView {
                    Label("No Snippets", systemImage: "curlybraces.square")
                } description: {
                    Text("Save frequently used commands in Snippets. Use {{name}} for values you fill in when running.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Self.sections(of: filtered), id: \.title) { section in
                        Section {
                            ForEach(section.snippets) { snippet in
                                row(snippet)
                                    .listRowSeparator(.hidden)
                            }
                        } header: {
                            if let title = section.title {
                                Text(verbatim: title)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                // The inspector's own surface shows through.
                .scrollContentBackground(.hidden)
            }

            if !canRun {
                Divider()
                Text("Focus a connected terminal to run snippets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.md + 2)
                    .padding(.vertical, DS.Space.sm)
            }
        }
    }

    struct SnippetSection {
        /// Nil for snippets without a category (no header).
        let title: String?
        let snippets: [Snippet]
    }

    /// Snippets by category, in the order the categories first appear; those without one first.
    nonisolated static func sections(of snippets: [Snippet]) -> [SnippetSection] {
        var order: [String] = []
        var byCategory: [String: [Snippet]] = [:]
        var plain: [Snippet] = []
        for snippet in snippets {
            let category = snippet.category?.trimmingCharacters(in: .whitespaces) ?? ""
            if category.isEmpty {
                plain.append(snippet)
            } else {
                if byCategory[category] == nil { order.append(category) }
                byCategory[category, default: []].append(snippet)
            }
        }
        var sections: [SnippetSection] = []
        if !plain.isEmpty { sections.append(SnippetSection(title: nil, snippets: plain)) }
        sections += order.map { SnippetSection(title: $0, snippets: byCategory[$0] ?? []) }
        return sections
    }

    private func row(_ snippet: Snippet) -> some View {
        let variables = SnippetTemplate.placeholders(in: snippet.command).count
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                Text(verbatim: snippet.name)
                    .font(DS.Font.rowTitle)
                    .lineLimit(1)
                if variables > 0 {
                    // The run asks for this many values first.
                    DSChip(verbatim: "{} \(variables)", isMonospaced: true)
                        .help("Asks for the values of its {{variables}} before it runs")
                }
                Spacer(minLength: DS.Space.xs)
                DSRowButton("text.insert", help: "Paste into terminal") {
                    run(snippet, execute: false)
                }
                .disabled(!canRun)
                DSRowButton("play.fill", help: "Run in terminal") {
                    run(snippet, execute: true)
                }
                .disabled(!canRun)
            }
            Text(verbatim: snippet.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if canRun { run(snippet, execute: true) }
        }
        .accessibilityElement(children: .contain)
    }

    private func run(_ snippet: Snippet, execute: Bool) {
        let placeholders = SnippetTemplate.placeholders(in: snippet.command)
        if placeholders.isEmpty {
            appViewModel.runSnippet(snippet.command, execute: execute)
        } else {
            pending = PendingSnippet(snippet: snippet, execute: execute, placeholders: placeholders)
        }
    }
}

// MARK: - Info

/// What does not change by the second about the focused session: through what it goes, how it
/// signs in, its forwarding rules, the host's record, and recent connection history.
private struct SessionInfoView: View {
    @Environment(AppViewModel.self) private var appViewModel
    /// For the name of the host's startup snippet.
    let snippets: [Snippet]
    @State private var recentLogs: [ConnectionLog] = []

    var body: some View {
        if let session = appViewModel.focusedSession {
            let host = session.isSSH ? appViewModel.currentHost(of: session) : nil
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(session, host: host)
                        // Only through a jump host: a direct route is the name above.
                        if let host, let hops = appViewModel.jumpRouteHops(
                            to: host, status: session.displayState.avatarStatus,
                            jumpStatus: session.isLive ? .live : .none) {
                            DSRouteDiagram(hops: hops, activity: session.isLive ? .flowing : .idle, style: .compact)
                                .padding(.top, DS.Space.lg)
                        }
                        if let host {
                            hostRows(host, theme: session.host?.terminalTheme)
                        } else if !session.isSSH {
                            InspectorRow("Shell", isFirst: true) {
                                Text(verbatim: TerminalSession.localShellName)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                            }
                            .padding(.top, DS.Space.sm)
                        }
                        forwards(session)
                        if !recentLogs.isEmpty {
                            InspectorSectionTitle("Recent Sessions")
                            ForEach(Array(recentLogs.prefix(5).enumerated()), id: \.offset) { index, log in
                                InspectorRow(
                                    log.status == "failed" ? "Failed" : "Connected",
                                    isFirst: index == 0
                                ) {
                                    if let date = TimestampFormatter.date(from: log.connectedAt) {
                                        Text(verbatim: DSRelativeTime.text(for: date))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        // Right under what they are about, not at the far end of the panel.
                        if let host, host.id != nil {
                            actions(host)
                        }
                    }
                    .padding(.horizontal, DS.Space.md + 2)
                    .padding(.bottom, DS.Space.md)
                }
            }
            // Rules are read when the shell comes up; this covers a session that was already up.
            .task(id: session.id) {
                await session.reloadPortForwards()
                if let hostId = host?.id {
                    recentLogs = (try? await ConnectionLogRepository.shared.fetchForHost(hostId)) ?? []
                } else {
                    recentLogs = []
                }
            }
        } else {
            ContentUnavailableView {
                Label("No terminal open", systemImage: "terminal")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Whose record this is, in one line. The address and the state are in the status bar.
    private func header(_ session: TerminalSession, host: Host?) -> some View {
        HStack(spacing: DS.Space.card) {
            if let host {
                DSHostAvatar(host, size: DS.Tile.row)
            } else if session.isSSH {
                DSHostAvatar(os: .unknown, size: DS.Tile.row)
            } else {
                DSHostAvatar.local(size: DS.Tile.row)
            }
            Text(verbatim: session.isSSH ? session.title : session.pane.title)
                .font(DS.Font.pageTitle)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, DS.Space.md)
    }

    @ViewBuilder
    private func forwards(_ session: TerminalSession) -> some View {
        if session.isSSH, !session.portForwards.isEmpty {
            // No count here: the status bar has the tunnels that are up, and the switches
            // below say which.
            InspectorSectionTitle("Port Forwards")
            ForEach(Array(session.portForwards.enumerated()), id: \.offset) { index, rule in
                ForwardRow(rule: rule, isFirst: index == 0)
            }
        }
    }

    /// How the host is signed in to, then what its record says. The terminal theme only when
    /// the host has one of its own: the app's is a setting, and the terminal is drawn in it.
    @ViewBuilder
    private func hostRows(_ host: Host, theme: String?) -> some View {
        let group = appViewModel.hostsPage.allGroups.first { $0.id == host.groupId }
        let tags = host.id.flatMap { appViewModel.hostsPage.tagsByHost[$0] } ?? []
        let startup = host.startupSnippetId.flatMap { id in snippets.first { $0.id == id } }
        InspectorSectionTitle("Host")
        InspectorRow("Authentication", isFirst: true) {
            Image(systemName: host.authSymbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(verbatim: host.authTitle)
        }
        if let system = host.systemDescription {
            InspectorRow("Operating System") {
                Text(verbatim: system)
                    .truncationMode(.middle)
            }
        }
        if group != nil || !tags.isEmpty {
            InspectorRow("Group") {
                if let group {
                    Text(verbatim: group.name)
                }
                if !tags.isEmpty {
                    Text(verbatim: tags.map { "#" + $0.name }.joined(separator: " "))
                        .foregroundStyle(.secondary)
                }
            }
        }
        if let theme, !theme.isEmpty {
            let hostTheme = TerminalTheme.find(theme)
            InspectorRow("Terminal Theme") {
                TerminalThemeDots(theme: hostTheme)
                Text(LocalizedStringKey(hostTheme.name))
            }
        }
        if let startup {
            InspectorRow("Startup Snippet") {
                Text(verbatim: startup.command)
                    .font(.system(size: 11, design: .monospaced))
                    .truncationMode(.tail)
                    .help(Text(verbatim: startup.command))
            }
        }
    }

    private func actions(_ host: Host) -> some View {
        // Plain bordered buttons: the inspector is the glass, what is in it is content.
        VStack(spacing: DS.Space.sm) {
            Button {
                appViewModel.monitor.selectHost(host)
                appViewModel.selectedSidebar = .monitoring
                appViewModel.isViewingTerminal = false
            } label: {
                Label("Open in Monitoring", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity)
            }
            Button {
                appViewModel.reveal(host: host)
            } label: {
                Label("Show in Hosts", systemImage: "server.rack")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .fontWeight(.semibold)
        .padding(.top, DS.Space.xl)
    }
}

// MARK: - Find Tab

private struct TerminalFindInspectorTab: View {
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                InspectorSectionTitle("Search Buffer")
                VStack(spacing: DS.Space.sm) {
                    Button {
                        appViewModel.focusedSession?.showFind()
                    } label: {
                        Label("Open Find Bar (⌘F)", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .dsButtonStyle(.prominent)

                    HStack(spacing: DS.Space.sm) {
                        Button {
                            appViewModel.focusedSession?.findPrevious()
                        } label: {
                            Label("Previous (⇧⌘G)", systemImage: "chevron.up")
                                .frame(maxWidth: .infinity)
                        }
                        .dsButtonStyle(.glass)

                        Button {
                            appViewModel.focusedSession?.findNext()
                        } label: {
                            Label("Next (⌘G)", systemImage: "chevron.down")
                                .frame(maxWidth: .infinity)
                        }
                        .dsButtonStyle(.glass)
                    }
                }

                InspectorSectionTitle("Buffer Actions")
                VStack(spacing: DS.Space.sm) {
                    Button {
                        appViewModel.focusedSession?.copySelection()
                    } label: {
                        Label("Copy Selection", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .dsButtonStyle(.glass)
                    .disabled(appViewModel.focusedSession?.hasSelection != true)

                    Button {
                        appViewModel.focusedSession?.clearBuffer()
                    } label: {
                        Label("Clear Scrollback (⌘K)", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .dsButtonStyle(.glass)
                    .disabled(appViewModel.focusedSession == nil)
                }
            }
            .padding(.horizontal, DS.Space.md + 2)
            .padding(.bottom, DS.Space.md)
        }
    }
}

// MARK: - Themes Tab

private struct TerminalThemesInspectorTab: View {
    @Environment(AppViewModel.self) private var appViewModel

    private var activeThemeId: String {
        appViewModel.terminalTheme(of: appViewModel.focusedSession).id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                InspectorSectionTitle("Color Theme")
                ForEach(TerminalTheme.builtIn) { theme in
                    let isSelected = theme.id == activeThemeId
                    Button {
                        applyTheme(theme.id)
                    } label: {
                        HStack(spacing: DS.Space.sm) {
                            TerminalThemeDots(theme: theme, size: 10)
                            Text(LocalizedStringKey(theme.name))
                                .font(DS.Font.rowTitle)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: DS.Space.xs)
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(DS.Palette.accent)
                            }
                        }
                        .padding(.horizontal, DS.Space.sm + 2)
                        .padding(.vertical, DS.Space.xs + 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                                .fill(isSelected ? DS.Palette.accent.opacity(0.14) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.md + 2)
            .padding(.bottom, DS.Space.md)
        }
    }

    private func applyTheme(_ themeId: String) {
        let generation = DataSnapshot.current
        Task {
            if let writer = try? await DatabaseManager.shared.writer {
                try? await DataSnapshot.$expected.withValue(generation) {
                    try await DataSnapshot.write(writer) { db in
                        let setting = AppSetting(key: TerminalPreferences.Key.colorTheme, value: themeId)
                        try setting.insert(db, onConflict: .replace)
                    }
                }
            }
            NotificationCenter.default.post(name: .terminalPreferencesChanged, object: nil)
        }
    }
}

/// The title of a group of rows in the inspector.
private struct InspectorSectionTitle: View {
    private let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(DS.Font.label)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DS.Space.lg)
            .padding(.bottom, DS.Space.xs)
    }
}

/// Key on the left, value at the right edge, a hairline above every row but the first.
private struct InspectorRow<Value: View>: View {
    private let key: LocalizedStringKey
    private let isFirst: Bool
    private let value: Value

    init(_ key: LocalizedStringKey, isFirst: Bool = false, @ViewBuilder value: () -> Value) {
        self.key = key
        self.isFirst = isFirst
        self.value = value()
    }

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Text(key)
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: DS.Space.sm)
            HStack(spacing: 6) { value }
                .fontWeight(.medium)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .frame(minHeight: 34)
        .overlay(alignment: .top) {
            if !isFirst { Divider() }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One forwarding rule of the host: what it forwards and its switch. The switch is the state;
/// a word only for what a switch cannot say — it is starting, or it failed and why.
private struct ForwardRow: View {
    let rule: PortForward
    let isFirst: Bool

    var body: some View {
        let manager = PortForwardManager.shared
        let status = manager.status(of: rule)
        HStack(spacing: DS.Space.card) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind)
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize()
                    exception(status)
                }
                Text(verbatim: Self.summary(of: rule))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // Both ends matter (which port, where to): tighten before cutting.
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
                    .help(Text(verbatim: Self.summary(of: rule)))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Toggle(isOn: Binding(
                get: { manager.isRunning(rule) },
                set: { _ in Task { await manager.toggle(rule) } }
            )) {
                // Read out with the switch: which kind of rule it turns on.
                HStack(spacing: DS.Space.xs) {
                    Text(kind)
                    Text(verbatim: Self.summary(of: rule))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .frame(minHeight: 38)
        .overlay(alignment: .top) {
            if !isFirst { Divider() }
        }
    }

    private var kind: LocalizedStringKey {
        switch rule.type {
        case "remote": return "Remote"
        case "dynamic": return "Dynamic"
        default: return "Local"
        }
    }

    @ViewBuilder
    private func exception(_ status: PortForwardManager.Status?) -> some View {
        switch status {
        case .starting:
            DSStatusPill("Starting…", tone: .warning, isPulsing: true, showsBackground: false)
        case .failed(let message), .stopFailed(let message):
            DSStatusPill("Failed", tone: .danger, showsBackground: false)
                .fixedSize()
            // The reason next to the word (it used to be a tooltip only); in full on hover.
            Text(verbatim: message)
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
                .truncationMode(.tail)
                .help(Text(verbatim: message))
        case .active, nil:
            EmptyView()
        }
    }

    /// "localhost:18080 → 127.0.0.1:8080", "SOCKS localhost:1080".
    nonisolated static func summary(of rule: PortForward) -> String {
        switch rule.type {
        case "dynamic": return "SOCKS localhost:\(rule.localPort)"
        case "remote": return "remote:\(rule.localPort) → \(rule.remoteHost):\(rule.remotePort)"
        default: return "localhost:\(rule.localPort) → \(rule.remoteHost):\(rule.remotePort)"
        }
    }
}

/// Asks for the values of a snippet's `{{placeholders}}`.
struct SnippetVariablesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pending: SnippetPanelView.PendingSnippet
    let onRun: ([String: String]) -> Void
    @State private var values: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(pending.placeholders, id: \.self) { name in
                    TextField(name, text: Binding(
                        get: { values[name] ?? "" },
                        set: { values[name] = $0 }
                    ))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                }
            } header: {
                Text(verbatim: pending.snippet.name)
            } footer: {
                // Live preview of the command with the values filled in.
                Text(verbatim: SnippetTemplate.render(pending.snippet.command, values: values))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    onRun(values)
                    dismiss()
                } label: {
                    if pending.execute {
                        Text("Run")
                    } else {
                        Text("Paste")
                    }
                }
                // A command with a hole in it is never sent: every variable needs a value.
                .disabled(!SnippetTemplate.missingValues(in: pending.snippet.command, values: values).isEmpty)
                .help(SnippetTemplate.missingValues(in: pending.snippet.command, values: values).isEmpty
                      ? "" : "Fill in every variable first")
            }
        }
    }
}
