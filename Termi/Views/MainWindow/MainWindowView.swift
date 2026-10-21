import SwiftUI
import AppKit

/// Main window: system sidebar + detail in a `NavigationSplitView`, unified toolbar.
/// The detail shows the page picked in the sidebar or, on top of it, the terminal tabs.
struct MainWindowView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(SecurityViewModel.self) private var securityVM
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var windowColorScheme
    /// Width of the detail column: what the session tabs may take of the toolbar depends on it.
    @State private var detailWidth: CGFloat = 0

    var body: some View {
        @Bindable var vm = viewModel

        Group {
            if let dbError = viewModel.databaseError {
                databaseErrorView(dbError)
            } else {
                NavigationSplitView(columnVisibility: $vm.sidebarVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 300)
                } detail: {
                    detail
                }
                .overlay(alignment: .bottom) {
                    toastOverlay
                }
                // Switching to another sidebar section leaves the terminal view
                .onChange(of: viewModel.selectedSidebar) { oldValue, newValue in
                    if newValue == .settings {
                        // Settings live in their own window (⌘,), not in a page.
                        openSettings()
                        viewModel.selectedSidebar = oldValue
                    } else if newValue != .terminal {
                        viewModel.isViewingTerminal = false
                    }
                }
                // A session went live: its host is now the one connected to last (the recent
                // hosts menu, the command palette) — once the connection has been recorded.
                .onChange(of: viewModel.connectedHostIds) { _, _ in
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        if viewModel.hostsPage.hasLoaded { await viewModel.hostsPage.loadHosts() }
                    }
                }
                // "Edit Host…" from a terminal pane or connection error
                .sheet(item: $vm.hostToEdit) { host in
                    HostFormView(host: host) { draft in
                        Task { await HostsViewModel.save(draft) }
                    }
                }
                // Register this window with AppDelegate (close confirmation / session teardown)
                .background {
                    WindowRegistrar(viewModel: viewModel)
                }
            }
        }
    }

    // MARK: - Detail

    /// Terminals stay in the hierarchy (hidden with opacity) so sessions survive page switches;
    /// the page is only built while it is on screen, so its toolbar items come and go with it.
    /// Behind the lock screen it is not built either: its sheets, alerts and confirmation
    /// dialogs (which would stay in front of the lock screen) leave the hierarchy with it.
    private var detail: some View {
        @Bindable var vm = viewModel

        return ZStack {
            TerminalTabView()
                .opacity(viewModel.isViewingTerminal ? 1 : 0)
                .allowsHitTesting(viewModel.isViewingTerminal)
                .accessibilityHidden(!viewModel.isViewingTerminal)

            if viewModel.isShowingNewTabPicker && !securityVM.hidesContent {
                NewTabPickerView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            } else if !viewModel.isViewingTerminal && !securityVM.hidesContent {
                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            }
        }
        // The terminal is the content and the toolbar floats over it: its colour runs up to the
        // window's edge. Top only — at the sides the safe area lies under the sidebar and the
        // inspector, which it would tint.
        .background {
            if Self.toolbarFloats, viewModel.isViewingTerminal, !securityVM.hidesContent, let theme = terminalTheme {
                Color(nsColor: theme.nsBackground).ignoresSafeArea(.container, edges: .top)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            detailWidth = width
        }
        .navigationTitle(title)
        // A terminal or the New Tab Host Picker has no title in the toolbar: the surface bar names what is on screen.
        .toolbar(removing: (viewModel.isViewingTerminal || viewModel.isShowingNewTabPicker) ? .title : nil)
        // … and no bar of its own behind the items: they float over the terminal.
        .toolbarBackground(Self.toolbarFloats && viewModel.isViewingTerminal ? .hidden : .automatic, for: .windowToolbar)
        // Snippets sit in the standard trailing inspector, next to the terminal only (and never
        // behind the lock screen).
        .inspector(isPresented: Binding(
            get: { viewModel.showSnippetPanel && viewModel.isViewingTerminal && !securityVM.hidesContent },
            // Leaving the terminal for a page hides the inspector, and the system then writes
            // `false` back: that is not the user closing it — it is there again on return.
            set: { if viewModel.isViewingTerminal, !securityVM.hidesContent { viewModel.showSnippetPanel = $0 } }
        )) {
            SnippetPanelView()
                .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
        }
        .toolbar {
            // Not behind the lock screen: the tabs and the menu name hosts.
            if viewModel.isViewingTerminal, !securityVM.hidesContent, let tab = viewModel.activeTab {
                ToolbarItem(placement: .navigation) {
                    TabBarView(availableWidth: detailWidth - Self.toolbarReserve)
                        .environment(viewModel)
                        // The glass takes its tone from the terminal beneath it, as the system's
                        // own items do: the titles follow the terminal theme, not the window.
                        .environment(\.colorScheme, tabColorScheme)
                }

                // Without a title nothing pushes the tools to the trailing edge.
                ToolbarItem(placement: .primaryAction) {
                    Spacer()
                }

                ToolbarItem(placement: .primaryAction) {
                    RecentHostsMenu()
                        .environment(viewModel)
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        viewModel.splitFocusedPane(.horizontal)
                    } label: {
                        Label("Split Right", systemImage: "rectangle.split.2x1")
                    }
                    .help("Split Right (⌘D)")

                    Button {
                        viewModel.splitFocusedPane(.vertical)
                    } label: {
                        Label("Split Down", systemImage: "rectangle.split.1x2")
                    }
                    .help("Split Down (⇧⌘D)")

                    // Always in the bar, disabled with a single pane: an item that comes and goes
                    // moves its neighbours from under the pointer (a second click on Split Right
                    // hit Split Down).
                    Toggle(isOn: Binding(
                        get: { tab.isSplit && tab.broadcastInput },
                        set: { _ in viewModel.toggleBroadcast() }
                    )) {
                        Label("Broadcast Input to All Panes", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .help("Broadcast Input to All Panes (⇧⌘B)")
                    .disabled(!tab.isSplit)
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $vm.showSnippetPanel.animation(DS.Motion.standard)) {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                    .help("Terminal Inspector (⌘. / ⇧⌘S)")

                    Button {
                        viewModel.openSFTPForFocusedSession()
                    } label: {
                        Label("Open SFTP", systemImage: "folder")
                    }
                    .help("Open SFTP for this host (⇧⌘O)")
                    .disabled(viewModel.focusedSession?.isSSH != true)
                }
            } else if !securityVM.hidesContent {
                // On Vaults / SFTP / NewTabPicker, the top surface switcher + open session tiles + "+" stay in the toolbar.
                ToolbarItem(placement: .navigation) {
                    TabBarView(availableWidth: Self.pageTabsWidth(detailWidth: detailWidth), tilesOnly: true)
                        .environment(viewModel)
                }
            }
        }
    }

    /// The toolbar floats over the terminal only where the system backs its items with glass
    /// (built with the macOS 26 SDK and running on macOS 26). Elsewhere the items have no backing
    /// of their own: over a terminal theme of the opposite brightness their glyphs would not
    /// read, so the toolbar keeps its bar and the tabs keep the window's appearance.
    private static var toolbarFloats: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    private var tabColorScheme: ColorScheme {
        guard Self.toolbarFloats else { return windowColorScheme }
        return terminalTheme?.isDark == false ? .light : .dark
    }

    /// What the toolbar holds next to the session tabs: the recent hosts menu, the five tools,
    /// the gaps between the groups.
    private static let toolbarReserve: CGFloat = 300

    /// What the session tiles may take of a page's toolbar: at most six tiles, fewer in a narrow
    /// window, where the page's own items and its search field need the room.
    nonisolated static func pageTabsWidth(detailWidth: CGFloat) -> CGFloat {
        min(200, max(72, detailWidth - 620))
    }

    /// Theme of the terminal on screen (the same choice as in `TerminalTabView`).
    private var terminalTheme: TerminalTheme? {
        guard let tab = viewModel.activeTab else { return nil }
        let hostTheme = viewModel.existingSession(for: tab.focusedPaneId)?.host?.terminalTheme
        let themeId = hostTheme.flatMap { $0.isEmpty ? nil : $0 } ?? viewModel.terminalColorTheme
        return TerminalTheme.find(themeId)
    }

    /// The window title names what is on screen: the session, or the page.
    private var title: Text {
        // The lock screen hides the title bar, but the title still names the window in the
        // Window menu and in Mission Control.
        if securityVM.isLocked {
            return Text(verbatim: "Termi")
        }
        if viewModel.isViewingTerminal, let tab = viewModel.activeTab {
            return Text(verbatim: tab.title)
        }
        return Text(LocalizedStringKey(viewModel.selectedSidebar.label))
    }

    /// Full-window blocker shown when the database fails to initialize
    private func databaseErrorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Database Error", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text("Termi cannot start because the database failed to initialize.")
            Text(verbatim: message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("Try restarting the app. If the problem persists, check disk space and permissions for ~/Library/Application Support/Termi/")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.selectedSidebar {
        case .terminal:
            HostListView()
        case .sftp:
            SFTPView()
        case .keys:
            KeyManagementView()
        case .knownHosts:
            KnownHostsView()
        case .identities:
            IdentitiesView()
        case .snippets:
            SnippetsView()
        case .batchCommand:
            BatchCommandView()
        case .monitoring:
            MonitoringView()
        case .docker:
            DockerView()
        case .portForwards:
            PortForwardsView()
        case .logs:
            ConnectionLogsView()
        case .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        VStack(spacing: DS.Space.sm) {
            ForEach(viewModel.toasts) { toast in
                Label {
                    Text(verbatim: toast.message)
                        .font(.callout)
                        .lineLimit(3)
                } icon: {
                    Image(systemName: toast.type.icon)
                        .foregroundStyle(toast.type.color)
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.sm + 2)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.Palette.separator, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                .onTapGesture { viewModel.dismissToast(toast.id) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, DS.Space.xl)
        .animation(DS.Motion.standard, value: viewModel.toasts.map(\.id))
    }
}

// MARK: - Toast helpers

extension ToastMessage.ToastType {
    var icon: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: DS.Palette.success
        case .warning: DS.Palette.warning
        case .error: DS.Palette.danger
        case .info: .accentColor
        }
    }
}

// MARK: - WindowRegistrar

/// Zero-size NSView that registers the enclosing NSWindow with AppDelegate, so each window
/// is tracked independently (close confirmation, session teardown).
struct WindowRegistrar: NSViewRepresentable {
    let viewModel: AppViewModel

    func makeNSView(context: Context) -> NSView {
        let view = WindowRegistrarView(viewModel: viewModel)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowRegistrarView: NSView {
    private let viewModel: AppViewModel

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        // Register with AppDelegate so closing the window ends (and confirms) its sessions
        Task { @MainActor in
            AppDelegate.shared?.register(window: window, viewModel: self.viewModel)
        }
    }
}
