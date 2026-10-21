import SwiftUI
import os.log

// MARK: - Navigation

enum SidebarItem: String, CaseIterable, Identifiable {
    case terminal = "terminal"
    case sftp = "sftp"
    case keys = "keys"
    case knownHosts = "knownHosts"
    case identities = "identities"
    case snippets = "snippets"
    case batchCommand = "batchCommand"
    case monitoring = "monitoring"
    case docker = "docker"
    case portForwards = "portForwards"
    case logs = "logs"
    case settings = "settings"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terminal: "Hosts"
        case .sftp: "SFTP"
        case .keys: "Keychain"
        case .knownHosts: "Known Hosts"
        case .identities: "Identities"
        case .snippets: "Snippets"
        case .batchCommand: "Batch Command"
        case .monitoring: "Monitoring"
        case .docker: "Docker"
        case .portForwards: "Port Forwarding"
        case .logs: "History"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .terminal: "server.rack"
        case .sftp: "folder.badge.gearshape"
        case .keys: "key"
        case .knownHosts: "checkmark.shield"
        case .identities: "person.crop.rectangle"
        case .snippets: "curlybraces.square"
        case .batchCommand: "text.and.command.macwindow"
        case .monitoring: "chart.bar"
        case .docker: "shippingbox"
        case .portForwards: "arrow.left.arrow.right"
        case .logs: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

// MARK: - Panes & tabs

enum SplitAxis: Equatable {
    /// Panes side by side.
    case horizontal
    /// Panes stacked.
    case vertical
}

/// Layout tree of the panes in a tab.
indirect enum PaneLayout: Equatable {
    case pane(UUID)
    case split(SplitAxis, [PaneLayout])

    /// Stable identity of a subtree (its first pane).
    var id: UUID {
        switch self {
        case .pane(let id): id
        case .split(_, let children): children.first?.id ?? UUID()
        }
    }

    var paneIds: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, let children): children.flatMap(\.paneIds)
        }
    }

    /// Insert `newPane` next to `target`, splitting along `axis`.
    func inserting(_ newPane: UUID, nextTo target: UUID, axis: SplitAxis) -> PaneLayout {
        switch self {
        case .pane(let id):
            return id == target ? .split(axis, [.pane(id), .pane(newPane)]) : self
        case .split(let splitAxis, let children):
            if splitAxis == axis, let index = children.firstIndex(of: .pane(target)) {
                var updated = children
                updated.insert(.pane(newPane), at: index + 1)
                return .split(splitAxis, updated)
            }
            return .split(splitAxis, children.map { $0.inserting(newPane, nextTo: target, axis: axis) })
        }
    }

    /// Remove a pane, collapsing splits left with a single child. Nil when nothing is left.
    func removing(_ target: UUID) -> PaneLayout? {
        switch self {
        case .pane(let id):
            return id == target ? nil : self
        case .split(let axis, let children):
            let remaining = children.compactMap { $0.removing(target) }
            switch remaining.count {
            case 0: return nil
            case 1: return remaining[0]
            default: return .split(axis, remaining)
            }
        }
    }

    /// The pane next to `target` in the split it sits in — the one that takes over its space
    /// when it closes: the following sibling, else the preceding one. Nil for a lone pane.
    func neighbor(of target: UUID) -> UUID? {
        guard case .split(_, let children) = self else { return nil }
        if let index = children.firstIndex(of: .pane(target)) {
            if index + 1 < children.count { return children[index + 1].paneIds.first }
            return index > 0 ? children[index - 1].paneIds.last : nil
        }
        for child in children {
            if let found = child.neighbor(of: target) { return found }
        }
        return nil
    }
}

struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var panes: [TerminalPane]
    var layout: PaneLayout
    var focusedPaneId: UUID
    /// Keystrokes in one pane are typed into every pane of the tab.
    var broadcastInput = false

    init(title: String = "Local", isSSH: Bool = false, hostId: Int64? = nil) {
        self.init(pane: TerminalPane(title: title, isSSH: isSSH, hostId: hostId))
    }

    init(pane: TerminalPane) {
        id = UUID()
        title = pane.title
        panes = [pane]
        layout = .pane(pane.id)
        focusedPaneId = pane.id
    }

    // The tab's first pane describes the tab (tab icon, duplicate, "connected" state).
    var isSSH: Bool {
        get { panes.first?.isSSH ?? false }
        set { if !panes.isEmpty { panes[0].isSSH = newValue } }
    }

    var hostId: Int64? {
        get { panes.first?.hostId }
        set { if !panes.isEmpty { panes[0].hostId = newValue } }
    }

    var adHocHost: Host? {
        get { panes.first?.adHocHost }
        set { if !panes.isEmpty { panes[0].adHocHost = newValue } }
    }

    var adHocPassword: String? {
        get { panes.first?.adHocPassword }
        set { if !panes.isEmpty { panes[0].adHocPassword = newValue } }
    }

    var focusedPane: TerminalPane? {
        panes.first { $0.id == focusedPaneId } ?? panes.first
    }

    var isSplit: Bool { panes.count > 1 }

    // Equatable is synthesized over every field on purpose: SwiftUI skips re-rendering
    // `ForEach(tabs)` while the tabs compare equal, so an id-only `==` hides layout, focus,
    // title and broadcast changes until a tab is added or removed.
}

// MARK: - Workspaces

struct TerminalWorkspace: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var hostIds: [Int64]
}

// MARK: - Toast

struct ToastMessage: Identifiable {
    let id = UUID()
    let type: ToastType
    let message: String

    enum ToastType {
        case success, warning, error, info
    }
}

// MARK: - AppViewModel

/// Per-window application state: navigation, terminal tabs/panes and their sessions.
@Observable
@MainActor
final class AppViewModel {
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "AppViewModel")

    private(set) var isReplacingData = false
    private(set) var contentGeneration = UUID()

    // Navigation — Hosts is the default landing page
    var selectedSidebar: SidebarItem = .terminal
    var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    var showCommandPalette = false

    // Tabs — start empty; tabs are created on demand (connect or ⌘T)
    var tabs: [TerminalTab] = []
    var activeTabId: UUID?
    /// True when the full-window `⌘T` / `+` New Tab Host Picker is shown.
    var isShowingNewTabPicker = false
    /// Tab currently in inline-rename mode in `TabBarView`.
    var renamingTabId: UUID?
    /// Saved multi-pane workspace templates.
    var workspaces: [TerminalWorkspace] = []

    // Sheets / panels
    var showQuickConnect = false
    var showKeyboardShortcuts = false
    var showSnippetPanel = false
    /// Host to edit, requested from a terminal pane ("Edit Host…").
    var hostToEdit: Host?

    // Toast
    var toasts: [ToastMessage] = []

    // True when a terminal session tab is shown instead of a page
    var isViewingTerminal: Bool = false

    // Terminal appearance
    var terminalPreferences = TerminalPreferences()
    /// App appearance: "Dark", "Light" or "System".
    var terminalTheme: String = "Dark"
    var terminalFontSize: CGFloat { terminalPreferences.fontSize }
    var terminalColorTheme: String { terminalPreferences.colorTheme }

    /// SFTP browser state lives with the window so it survives page switches.
    private(set) var sftp = SFTPViewModel()
    /// So do the tool pages: results, the selected host and its last reading are still there
    /// after a look at a terminal or another page.
    private(set) var batchCommand = BatchCommandViewModel()
    private(set) var monitor = MonitorViewModel()
    private(set) var docker = DockerViewModel()
    /// The hosts page too: its tag filter, search and selection are still there after a session.
    private(set) var hostsPage = HostsViewModel()

    /// Pane id → session. Sessions are created with their pane and started by its view;
    /// closing a pane closes its session.
    private var sessions: [UUID: TerminalSession] = [:]

    // Critical error state — shown as full-screen blocker when database fails
    var databaseError: String?

    var activeTab: TerminalTab? {
        tabs.first { $0.id == activeTabId }
    }

    /// Session of the focused pane of the active tab.
    var focusedSession: TerminalSession? {
        guard let pane = activeTab?.focusedPane else { return nil }
        return sessions[pane.id]
    }

    @ObservationIgnored nonisolated(unsafe) private var observers: [Any] = []
    @ObservationIgnored private var networkToken: UUID?

    init() {
        DataReplacementCoordinator.shared.register(self)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .terminalPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.loadTerminalSettings() }
        })
        observers.append(center.addObserver(forName: .terminalThemeChanged, object: nil, queue: .main) { [weak self] notification in
            guard let theme = notification.userInfo?["theme"] as? String else { return }
            Task { @MainActor [weak self] in self?.terminalTheme = theme }
        })
        observers.append(center.addObserver(forName: .databaseInitFailed, object: nil, queue: .main) { [weak self] notification in
            guard let message = notification.userInfo?["message"] as? String else { return }
            Task { @MainActor [weak self] in self?.databaseError = message }
        })
        // A host's system was read after it connected, or a record was saved in another window:
        // this window's hosts (the hosts page, the palette, every "used by" list) follow.
        observers.append(center.addObserver(forName: .dsDataChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hostsPage.hasLoaded else { return }
                await self.hostsPage.loadHosts()
            }
        })
        networkToken = NetworkMonitor.shared.onConnectivityRestored { [weak self] in
            self?.retryPendingReconnects()
        }
        loadWorkspaces()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func prepareForDataReplacement() {
        isReplacingData = true
        closeAllTabs()
        monitor.stopAutoRefresh()
        sftp.disconnect()
        showCommandPalette = false
        showQuickConnect = false
        showKeyboardShortcuts = false
        showSnippetPanel = false
        isShowingNewTabPicker = false
        renamingTabId = nil
        hostToEdit = nil
        hostsPage.invalidateSnapshot()
        contentGeneration = UUID()
    }

    func finishDataReplacement() async {
        let savedNotice = sftp.notice
        sftp = SFTPViewModel()
        sftp.notice = savedNotice
        batchCommand = BatchCommandViewModel()
        monitor = MonitorViewModel()
        docker = DockerViewModel()
        hostsPage = HostsViewModel()
        selectedSidebar = .terminal
        sidebarVisibility = .all
        isShowingNewTabPicker = false
        isReplacingData = false
        contentGeneration = UUID()
        await hostsPage.loadHosts()
        await hostsPage.loadReferences()
        await loadTerminalSettings()
    }

    // MARK: - Top Surface Switching & Workspaces

    /// Switch to the Vaults surface (Hosts / Keys / Port Forwards / Snippets / Tools) and expand the sidebar.
    func selectVaults() {
        isShowingNewTabPicker = false
        isViewingTerminal = false
        if selectedSidebar == .sftp {
            selectedSidebar = .terminal
        }
        sidebarVisibility = .all
    }

    /// Switch to the full-width SFTP dual-pane surface and collapse the sidebar.
    func selectSFTP() {
        isShowingNewTabPicker = false
        isViewingTerminal = false
        selectedSidebar = .sftp
        sidebarVisibility = .detailOnly
    }

    /// Open the full-window `⌘T` / `+` New Tab Host Picker and collapse the sidebar.
    func openNewTabPicker() {
        guard !isReplacingData else { return }
        isShowingNewTabPicker = true
        isViewingTerminal = false
        sidebarVisibility = .detailOnly
    }

    private static let workspacesKey = "terminalWorkspaces"

    func loadWorkspaces() {
        guard let data = AppProfile.defaults.data(forKey: Self.workspacesKey),
              let decoded = try? JSONDecoder().decode([TerminalWorkspace].self, from: data) else {
            workspaces = []
            return
        }
        workspaces = decoded
    }

    private func persistWorkspaces() {
        if let data = try? JSONEncoder().encode(workspaces) {
            AppProfile.defaults.set(data, forKey: Self.workspacesKey)
        }
    }

    func saveWorkspace(name: String, hostIds: [Int64]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hostIds.isEmpty else { return }
        workspaces.append(TerminalWorkspace(name: trimmed, hostIds: hostIds))
        persistWorkspaces()
    }

    func deleteWorkspace(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        persistWorkspaces()
    }

    func openWorkspace(_ workspace: TerminalWorkspace) {
        let chosen = workspace.hostIds.compactMap { id in
            hostsPage.hosts.first { $0.id == id }
        }
        guard !chosen.isEmpty else { return }
        connectMultiple(hosts: chosen, asSplitTab: true, customTitle: workspace.name)
    }

    /// Connect multiple hosts either as separate tabs or as a single multi-pane split tab.
    func connectMultiple(hosts: [Host], asSplitTab: Bool, customTitle: String? = nil) {
        guard !isReplacingData, let first = hosts.first else { return }
        if !asSplitTab || hosts.count == 1 {
            for host in hosts {
                connect(to: host)
            }
            return
        }
        let firstPane = TerminalPane(
            title: first.displayName,
            isSSH: true,
            hostId: first.id,
            adHocHost: first.id == nil ? first : nil
        )
        var tab = TerminalTab(pane: firstPane)
        if let customTitle, !customTitle.isEmpty {
            tab.title = customTitle
        }
        for (idx, host) in hosts.dropFirst().enumerated() {
            let pane = TerminalPane(
                title: host.displayName,
                isSSH: true,
                hostId: host.id,
                adHocHost: host.id == nil ? host : nil
            )
            let targetId = tab.panes.last?.id ?? firstPane.id
            let axis: SplitAxis = idx.isMultiple(of: 2) ? .horizontal : .vertical
            tab.panes.append(pane)
            tab.layout = tab.layout.inserting(pane.id, nextTo: targetId, axis: axis)
        }
        addTab(tab)
    }

    /// Display title of a tab in the tab bar: adds `(2)`, `(3)` when multiple open tabs share the same title.
    func displayTitle(for tab: TerminalTab) -> String {
        let matching = tabs.filter { $0.title == tab.title }
        guard matching.count > 1, let ordinal = matching.firstIndex(where: { $0.id == tab.id }), ordinal > 0 else {
            return tab.title
        }
        return "\(tab.title) (\(ordinal + 1))"
    }

    /// Reconnect all disconnected/failed SSH panes in the given tab.
    func reconnectTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        for pane in tab.panes {
            sessions[pane.id]?.reconnect()
        }
        activateTab(id)
    }

    // MARK: - Settings

    func loadTerminalSettings() async {
        let preferences = await TerminalPreferences.load()
        terminalPreferences = preferences
        for session in sessions.values {
            session.apply(preferences: preferences)
        }
        if let reader = try? await DatabaseManager.shared.reader,
           let theme = try? await reader.read({ db in try AppSetting.fetchOne(db, key: "terminal_theme") }) {
            terminalTheme = theme.value
        }
    }

    // MARK: - Sessions

    /// Session for a pane (normally created together with the pane). Nil once the pane is
    /// closed: SwiftUI can evaluate the body of its view one more time on the way out, and
    /// that must not bring a session back for it.
    func session(for pane: TerminalPane) -> TerminalSession? {
        if let session = sessions[pane.id] { return session }
        guard tabs.contains(where: { $0.panes.contains { $0.id == pane.id } }) else { return nil }
        return makeSession(for: pane)
    }

    @discardableResult
    private func makeSession(for pane: TerminalPane) -> TerminalSession {
        let session = TerminalSession(pane: pane, preferences: terminalPreferences)
        session.onFocus = { [weak self] in self?.focus(paneId: pane.id) }
        session.onRequestClose = { [weak self] in self?.closePane(pane.id) }
        session.menuBuilder = { [weak self] session in self?.contextMenu(for: session) }
        sessions[pane.id] = session
        if let tabIndex = tabs.firstIndex(where: { $0.panes.contains { $0.id == pane.id } }) {
            wireBroadcast(tabIndex: tabIndex)
        }
        return session
    }

    func existingSession(for paneId: UUID) -> TerminalSession? {
        sessions[paneId]
    }

    private func closeSession(_ paneId: UUID) {
        sessions.removeValue(forKey: paneId)?.close()
    }

    private func retryPendingReconnects() {
        for session in sessions.values {
            session.retryReconnectNow()
        }
    }

    /// Host ids with a live terminal session (host cards show them as connected).
    var connectedHostIds: Set<Int64> {
        Set(tabs.flatMap(\.panes).compactMap { pane -> Int64? in
            guard let hostId = pane.hostId, sessions[pane.id]?.isLive == true else { return nil }
            return hostId
        })
    }

    /// What a tab's tile says about its sessions — the worst state across its panes: failed,
    /// then connecting, then ended, then live. A local shell carries no state.
    func avatarStatus(of tab: TerminalTab) -> DSHostAvatar.Status {
        guard tab.isSSH else { return .none }
        return Self.tabStatus(for: tab.panes.compactMap { sessions[$0.id]?.state })
    }

    nonisolated static func tabStatus(for states: [TerminalSession.State]) -> DSHostAvatar.Status {
        // An SSH tab always says something: with nothing worse to report it is live.
        let worst = DSHostAvatar.Status(states: states, ranking: .worstFirst)
        return worst == .none ? .live : worst
    }

    /// The host a tab stands for (the one of its focused pane), as the hosts list knows it — that
    /// copy carries the system read after connecting — else as the session knows it. Nil for a
    /// local shell.
    func host(of tab: TerminalTab) -> Host? {
        guard let pane = tab.focusedPane, pane.isSSH else { return nil }
        if let hostId = pane.hostId, let saved = hostsPage.hosts.first(where: { $0.id == hostId }) {
            return saved
        }
        return sessions[pane.id]?.connectionHost ?? pane.adHocHost
    }

    /// The hosts connected to last, most recent first; hosts never connected to are left out.
    nonisolated static func recentHosts(_ hosts: [Host], limit: Int) -> [Host] {
        let dated = hosts.compactMap { host in host.lastConnectedDate.map { (host, $0) } }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    // MARK: - Tab Management

    func addLocalTerminalTab() {
        addTab(TerminalTab(title: String(localized: "Local")))
    }

    func addSSHTab(title: String, hostId: Int64) {
        addTab(TerminalTab(title: title, isSSH: true, hostId: hostId))
    }

    /// Open a terminal tab for a saved host.
    func connect(to host: Host) {
        guard !isReplacingData else { return }
        guard let hostId = host.id else {
            addQuickConnectTab(host: host, password: nil)
            return
        }
        addSSHTab(title: host.label.isEmpty ? host.hostname : host.label, hostId: hostId)
        selectedSidebar = .terminal
    }

    func addQuickConnectTab(host: Host, password: String?) {
        let pane = TerminalPane(title: host.label.isEmpty ? host.addressDescription : host.label,
                                isSSH: true, adHocHost: host, adHocPassword: password)
        addTab(TerminalTab(pane: pane))
    }

    private func addTab(_ tab: TerminalTab) {
        tabs.append(tab)
        tab.panes.forEach { makeSession(for: $0) }
        activeTabId = tab.id
        isShowingNewTabPicker = false
        isViewingTerminal = true
        sidebarVisibility = .detailOnly
        logger.debug("Added tab \(tab.title)")
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs.remove(at: index)
        closing.panes.forEach { closeSession($0.id) }
        if activeTabId == id {
            if tabs.isEmpty {
                activeTabId = nil
                isViewingTerminal = false
                if selectedSidebar != .sftp && !isShowingNewTabPicker {
                    sidebarVisibility = .all
                }
            } else {
                activeTabId = tabs[min(index, tabs.count - 1)].id
            }
        }
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activateTab(tabs[index].id)
    }

    func activateTab(_ id: UUID) {
        activeTabId = id
        isShowingNewTabPicker = false
        isViewingTerminal = true
        selectedSidebar = .terminal
        sidebarVisibility = .detailOnly
    }

    func selectPreviousTab() {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex(where: { $0.id == activeTabId }) ?? 0
        activateTab(tabs[(index - 1 + tabs.count) % tabs.count].id)
    }

    func selectNextTab() {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex(where: { $0.id == activeTabId }) ?? tabs.count - 1
        activateTab(tabs[(index + 1) % tabs.count].id)
    }

    func closeOtherTabs(_ id: UUID) {
        for tab in tabs where tab.id != id {
            tab.panes.forEach { closeSession($0.id) }
        }
        tabs.removeAll { $0.id != id }
        activeTabId = id
    }

    func closeTabsToRight(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        for tab in tabs[(index + 1)...] {
            tab.panes.forEach { closeSession($0.id) }
        }
        tabs.removeSubrange((index + 1)...)
        if let activeTabId, !tabs.contains(where: { $0.id == activeTabId }) {
            self.activeTabId = id
        }
    }

    func closeAllTabs() {
        for tab in tabs {
            tab.panes.forEach { closeSession($0.id) }
        }
        tabs.removeAll()
        activeTabId = nil
        isViewingTerminal = false
    }

    /// New tab running what the tab's focused pane runs (a new session on the same connection).
    func duplicateTab(_ id: UUID) {
        guard let source = tabs.first(where: { $0.id == id }), let pane = source.focusedPane else { return }
        let copy = pane.duplicated()
        var tab = TerminalTab(pane: copy)
        tab.title = source.title
        addTab(tab)
    }

    func moveTab(from source: UUID, to target: UUID) {
        guard let fromIndex = tabs.firstIndex(where: { $0.id == source }),
              let toIndex = tabs.firstIndex(where: { $0.id == target }),
              fromIndex != toIndex else { return }
        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: toIndex)
    }

    func renameTab(_ id: UUID, to title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            tabs[index].title = trimmed
        }
    }

    // MARK: - Panes

    /// Split the focused pane of the active tab; the new pane runs the same thing.
    func splitFocusedPane(_ axis: SplitAxis) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == activeTabId }),
              let focused = tabs[tabIndex].focusedPane else { return }
        splitPane(focused.id, axis: axis, in: tabIndex)
    }

    func splitPane(_ paneId: UUID, axis: SplitAxis) {
        guard let tabIndex = tabs.firstIndex(where: { $0.panes.contains { $0.id == paneId } }) else { return }
        splitPane(paneId, axis: axis, in: tabIndex)
    }

    private func splitPane(_ paneId: UUID, axis: SplitAxis, in tabIndex: Int) {
        guard let pane = tabs[tabIndex].panes.first(where: { $0.id == paneId }) else { return }
        let newPane = pane.duplicated()
        tabs[tabIndex].panes.append(newPane)
        makeSession(for: newPane)
        tabs[tabIndex].layout = tabs[tabIndex].layout.inserting(newPane.id, nextTo: paneId, axis: axis)
        tabs[tabIndex].focusedPaneId = newPane.id
        activeTabId = tabs[tabIndex].id
        isViewingTerminal = true
        wireBroadcast(tabIndex: tabIndex)
    }

    /// Close a pane; closing the last pane closes the tab.
    func closePane(_ paneId: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.panes.contains { $0.id == paneId } }) else { return }
        guard tabs[tabIndex].panes.count > 1, let layout = tabs[tabIndex].layout.removing(paneId) else {
            closeTab(tabs[tabIndex].id)
            return
        }
        let neighbor = tabs[tabIndex].layout.neighbor(of: paneId)
        closeSession(paneId)
        tabs[tabIndex].panes.removeAll { $0.id == paneId }
        tabs[tabIndex].layout = layout
        // One pane left: there is nothing to broadcast to and no control left to turn it off
        // with — the tab badge would stay lit and the next split would broadcast unasked.
        if !tabs[tabIndex].isSplit { tabs[tabIndex].broadcastInput = false }
        if tabs[tabIndex].focusedPaneId == paneId {
            // Typing continues in the pane that grew into the closed one's place.
            tabs[tabIndex].focusedPaneId = neighbor ?? layout.paneIds.first ?? tabs[tabIndex].panes[0].id
            requestFocus(tabs[tabIndex].focusedPaneId)
        }
        wireBroadcast(tabIndex: tabIndex)
    }

    /// Close the focused pane (or the tab when it has one pane).
    func closeFocusedPane() {
        guard let pane = activeTab?.focusedPane else { return }
        closePane(pane.id)
    }

    /// ⌘W: like `closeFocusedPane`, asking first when a live SSH session would be disconnected.
    func confirmAndCloseFocusedPane() {
        guard let pane = activeTab?.focusedPane, confirmDisconnecting([pane]) else { return }
        closePane(pane.id)
    }

    /// The tab's close button and its menu ask the same question as ⌘W.
    func confirmAndCloseTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), confirmDisconnecting(tab.panes) else { return }
        closeTab(id)
    }

    func confirmAndCloseOtherTabs(_ id: UUID) {
        guard confirmDisconnecting(tabs.filter { $0.id != id }.flatMap(\.panes)) else { return }
        closeOtherTabs(id)
    }

    func confirmAndCloseTabsToRight(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              confirmDisconnecting(tabs[(index + 1)...].flatMap(\.panes)) else { return }
        closeTabsToRight(id)
    }

    func confirmAndCloseAllTabs() {
        guard confirmDisconnecting(tabs.flatMap(\.panes)) else { return }
        closeAllTabs()
    }

    /// Asks before the live SSH sessions among `panes` are disconnected, unless the question
    /// is turned off (Settings › General). False when the user cancels.
    private func confirmDisconnecting(_ panes: [TerminalPane]) -> Bool {
        let live = panes.filter { $0.isSSH && sessions[$0.id]?.state == .connected }
        guard let first = live.first,
              !AppProfile.defaults.bool(forKey: "suppressSSHCloseConfirmation") else { return true }
        let count = live.count
        let alert = NSAlert()
        alert.messageText = String(localized: "Close SSH Session?")
        alert.informativeText = count == 1
            // One session ends; other panes and tabs of the host stay connected.
            ? String(localized: "The session on \(sessions[first.id]?.title ?? first.title) will end.")
            : String(localized: "\(count) SSH session(s) in this window will be disconnected.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: count == 1 ? String(localized: "Close") : String(localized: "Disconnect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")
        let response = alert.runModal()
        // "Don't ask again" belongs to the answer: ticked and then cancelled, nothing was decided.
        if response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on {
            AppProfile.defaults.set(true, forKey: "suppressSSHCloseConfirmation")
        }
        return response == .alertFirstButtonReturn
    }

    /// Connected SSH sessions of this window: what closing it, or quitting, disconnects.
    var liveSSHSessionCount: Int {
        sessions.values.filter { $0.isSSH && $0.state == .connected }.count
    }

    /// The window is about to close: its sessions end with it. Asks first when live SSH
    /// sessions would be disconnected, SFTP transfers cancelled or remote editing ended with
    /// changes the server has not received; returns false when the user cancels.
    func confirmCloseWindow() -> Bool {
        let live = liveSSHSessionCount
        // "Don't ask again" covers SSH sessions only: what SFTP would lose always asks.
        let sftpWarnings = SFTPViewModel.closeWarnings(for: [sftp])
        let asksForSessions = live > 0 && !AppProfile.defaults.bool(forKey: "suppressSSHCloseConfirmation")
        if asksForSessions || !sftpWarnings.isEmpty {
            // One alert that names everything closing ends.
            var warnings = sftpWarnings
            if live > 0 {
                warnings.insert(String(localized: "\(live) SSH session(s) in this window will be disconnected."), at: 0)
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "Close Window?")
            alert.informativeText = warnings.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: sftpWarnings.isEmpty
                ? String(localized: "Disconnect") : String(localized: "Close Window"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        closeAllTabs()
        sftp.disconnect()
        return true
    }

    func focus(paneId: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.panes.contains { $0.id == paneId } }) else { return }
        if tabs[tabIndex].focusedPaneId != paneId {
            tabs[tabIndex].focusedPaneId = paneId
        }
    }

    /// Move focus to the next / previous pane of the active tab.
    func focusAdjacentPane(forward: Bool) {
        guard let tab = activeTab, tab.isSplit else { return }
        let order = tab.layout.paneIds
        guard let index = order.firstIndex(of: tab.focusedPaneId) else { return }
        let next = order[(index + (forward ? 1 : order.count - 1)) % order.count]
        focus(paneId: next)
        requestFocus(next)
    }

    /// Ask the pane's terminal view to become first responder once it is on screen.
    func requestFocus(_ paneId: UUID) {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.sessions[paneId]?.focus()
        }
    }

    // MARK: - Broadcast input

    func toggleBroadcast() {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        tabs[tabIndex].broadcastInput.toggle()
        wireBroadcast(tabIndex: tabIndex)
    }

    private func wireBroadcast(tabIndex: Int) {
        let tab = tabs[tabIndex]
        let paneIds = tab.panes.map(\.id)
        for paneId in paneIds {
            guard let session = sessions[paneId] else { continue }
            if tab.broadcastInput && paneIds.count > 1 {
                session.onUserInput = { [weak self] bytes in
                    guard let self else { return }
                    for peerId in paneIds where peerId != paneId {
                        self.sessions[peerId]?.sendToProcess(bytes)
                    }
                }
            } else {
                session.onUserInput = nil
            }
        }
    }

    // MARK: - Session actions

    /// Type a snippet into the focused session (broadcast applies).
    func runSnippet(_ command: String, execute: Bool) {
        guard let session = focusedSession else { return }
        var text = command
        if execute && !text.hasSuffix("\n") {
            text += "\r"
        }
        session.type(text)
        // Only while the terminal is on screen: from another page (command palette) focusing it
        // would send the following keystrokes to a shell the user cannot see.
        if isViewingTerminal {
            session.focus()
        }
    }

    func openSFTP(for host: Host) {
        guard !isReplacingData else { return }
        selectedSidebar = .sftp
        isViewingTerminal = false
        isShowingNewTabPicker = false
        sidebarVisibility = .detailOnly
        Task { await sftp.connect(to: host) }
    }

    func openSFTPForFocusedSession() {
        guard let host = focusedSession?.connectionHost else { return }
        openSFTP(for: host)
    }

    private func contextMenu(for session: TerminalSession) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(BlockMenuItem(String(localized: "Copy"), enabled: session.hasSelection) { session.copySelection() })
        menu.addItem(BlockMenuItem(String(localized: "Paste")) { session.paste() })
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem(String(localized: "Find…")) { session.showFind() })
        menu.addItem(BlockMenuItem(String(localized: "Clear Buffer")) { session.clearBuffer() })
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem(String(localized: "Split Right")) { [weak self] in
            self?.splitPane(session.id, axis: .horizontal)
        })
        menu.addItem(BlockMenuItem(String(localized: "Split Down")) { [weak self] in
            self?.splitPane(session.id, axis: .vertical)
        })
        if session.isSSH {
            menu.addItem(.separator())
            if let host = session.connectionHost {
                menu.addItem(BlockMenuItem(String(localized: "Open SFTP")) { [weak self] in
                    self?.openSFTP(for: host)
                })
                if host.id != nil {
                    menu.addItem(BlockMenuItem(String(localized: "Edit Host…")) { [weak self] in
                        self?.hostToEdit = host
                    })
                }
            }
            menu.addItem(BlockMenuItem(String(localized: "Reconnect")) { session.reconnect() })
        }
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem(String(localized: "Close Pane")) { [weak self] in
            guard let self, self.confirmDisconnecting([session.pane]) else { return }
            self.closePane(session.id)
        })
        return menu
    }

    // MARK: - Font size (⌘+ / ⌘- / ⌘0)

    func adjustFontSize(by delta: CGFloat) {
        let range = TerminalPreferences.fontSizeRange
        let size = delta == 0 ? 14 : min(max(terminalPreferences.fontSize + delta, range.lowerBound), range.upperBound)
        guard size != terminalPreferences.fontSize || delta == 0 else { return }
        Task {
            let generation = DataSnapshot.current
            if let writer = try? await DatabaseManager.shared.writer {
                // A replaced vault's settings win over a keystroke that was still in flight.
                try? await DataSnapshot.$expected.withValue(generation) {
                    try await DataSnapshot.write(writer) { db in
                        try AppSetting(key: TerminalPreferences.Key.fontSize, value: String(Int(size)))
                            .insert(db, onConflict: .replace)
                    }
                }
            }
            NotificationCenter.default.post(name: .terminalPreferencesChanged, object: nil)
        }
    }

    // MARK: - Toast

    @ObservationIgnored
    private var toastTasks: [UUID: Task<Void, Never>] = [:]

    func addToast(_ type: ToastMessage.ToastType, _ message: String) {
        let toast = ToastMessage(type: type, message: message)
        toasts.append(toast)

        // An error or a warning takes longer to read than "done"; a click still dismisses it.
        let seconds: Double = (type == .error || type == .warning) ? 8 : 3
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismissToast(toast.id)
        }
        toastTasks[toast.id] = task
    }

    func dismissToast(_ id: UUID) {
        toastTasks[id]?.cancel()
        toastTasks[id] = nil
        toasts.removeAll { $0.id == id }
    }
}
