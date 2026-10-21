import SwiftUI

/// Per-window root view. Each WindowGroup instance creates an independent AppViewModel,
/// giving every window its own tabs, sidebar navigation, and toast state.
/// SecurityViewModel is shared across all windows via environment injection from TermiApp.
struct WindowRootView: View {
    @State private var viewModel = AppViewModel()
    @Environment(SecurityViewModel.self) private var securityVM
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    @State private var debugPreview: DebugPreview?
    @State private var showsDebugGallery = false
    #endif

    var body: some View {
        ZStack {
            MainWindowView()
                .id(viewModel.contentGeneration)
                .environment(viewModel)
                .environment(securityVM)
                // Covered is not enough: Tab would still walk into the controls (and the
                // terminals) behind the lock screen.
                .disabled(securityVM.hidesContent || viewModel.isReplacingData)
                .accessibilityHidden(securityVM.hidesContent)

            // Launch: nothing shows before it is known whether the app is locked. Not the lock
            // screen itself, which would flash by when there is no master password.
            if !securityVM.isLockStateKnown {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
                    // Expecting the lock screen: start without the toolbar it is about to hide.
                    .toolbar(securityVM.expectsLockScreen ? .hidden : .automatic, for: .windowToolbar)
            }

            // A container of its own, so that only the lock screen is animated: what it covers
            // (the page leaving with its sheets, the cover above) changes at once.
            ZStack {
                if securityVM.isLocked {
                    LockScreenView(securityVM: securityVM)
                        .environment(viewModel)
                        // In at once — nothing may show through a fade-in — and out with a fade.
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: securityVM.isLocked)

            #if DEBUG
            if showsDebugGallery {
                DSGalleryView()
            }
            #endif
        }
        .focusedSceneValue(\.appViewModel, viewModel)
        .preferredColorScheme(colorScheme(for: viewModel.terminalTheme))
        .modifier(DebugControlState())
        .task {
            await securityVM.checkMasterPassword()
            await viewModel.loadTerminalSettings()
            #if DEBUG
            await DebugSeed.applyIfRequested()
            #endif
            // The hosts behind session tiles and the recent hosts menu.
            await viewModel.ensureHostsLoaded()
            #if DEBUG
            await viewModel.hostsPage.loadHosts()
            await viewModel.hostsPage.loadReferences()
            await applyDebugLaunchArguments()
            #endif
        }
        // Sheets are presented above the lock screen: take them down when the app locks. A page's
        // own sheets and alerts leave with the page (see MainWindowView).
        .onChange(of: securityVM.isLocked) { _, locked in
            AuthPromptPresenter.shared.appLockChanged(locked)
            guard locked else {
                // The terminal asks for the keyboard as it comes back, but yields to text fields,
                // and the lock screen's password field still holds it while fading out.
                if viewModel.isViewingTerminal, let tab = viewModel.activeTab {
                    viewModel.requestFocus(tab.focusedPaneId)
                }
                return
            }
            viewModel.showCommandPalette = false
            viewModel.showQuickConnect = false
            viewModel.showKeyboardShortcuts = false
            viewModel.hostToEdit = nil
            // These live with the window, not with the page: left set, the sheet or alert would
            // come back with the page after unlocking.
            viewModel.hostsPage.dismissSheets()
            viewModel.docker.showingLogs = false
            viewModel.sftp.showingNewFolder = false
            viewModel.sftp.showingRename = false
            viewModel.sftp.showingChmod = false
            viewModel.sftp.showingDeleteConfirm = false
            #if DEBUG
            debugPreview = nil
            #endif
        }
        .sheet(isPresented: $viewModel.showQuickConnect) {
            QuickConnectView()
                .environment(viewModel)
        }
        .sheet(isPresented: $viewModel.showCommandPalette) {
            CommandPaletteView()
                .environment(viewModel)
                .environment(securityVM)
        }
        .sheet(isPresented: $viewModel.showKeyboardShortcuts) {
            KeyboardShortcutsView()
        }
        #if DEBUG
        .sheet(item: $debugPreview) { preview in
            preview.view
                .environment(viewModel)
                .environment(securityVM)
        }
        #endif
    }

    #if DEBUG
    /// Debug builds only — start in a given state, for screenshots and UI checks without
    /// driving the interface:
    /// `open Termi.app --args -debugPage keys -debugSheet palette -debugConnect "a,b" -debugSplit 2`
    private func applyDebugLaunchArguments() async {
        let defaults = AppProfile.arguments
        // -debugSeedHosts <file>: the hosts of a test profile, before anything below looks for
        // them by name. Refused in the standard profile.
        await DebugSeed.applyIfRequested()
        // -debugAppearance Light|Dark, -debugWindowSize 900x600
        if let appearance = defaults.string(forKey: "debugAppearance") {
            viewModel.terminalTheme = appearance
        }
        if let size = defaults.string(forKey: "debugWindowSize")?.split(separator: "x").compactMap({ Double($0) }),
           size.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        if let page = defaults.string(forKey: "debugPage"), let item = SidebarItem(rawValue: page) {
            viewModel.selectedSidebar = item
        }
        switch defaults.string(forKey: "debugSheet") {
        case "quickConnect": viewModel.showQuickConnect = true
        case "palette": viewModel.showCommandPalette = true
        case "shortcuts": viewModel.showKeyboardShortcuts = true
        case "settings": openSettings()
        case "lock": securityVM.isLocked = true
        // -debugSheet gallery -debugGalleryPage 1…6 [-debugGalleryScroll <points>]: the shared
        // components with sample data, in place of the window's content.
        case "gallery":
            // After -debugAppearance has taken effect: a chart built in the same pass as the
            // appearance change keeps its axis labels in the old appearance's colour.
            try? await Task.sleep(for: .milliseconds(400))
            showsDebugGallery = true
        case let name?: debugPreview = await DebugPreview.make(name, securityVM: securityVM)
        default: break
        }
        let savedHosts = (try? await HostRepository.shared.fetchAll()) ?? []
        // -debugSFTP <label | user@host>: a saved host by its name, like -debugConnect.
        if let target = defaults.string(forKey: "debugSFTP") {
            if let host = savedHosts.first(where: { $0.label == target }) {
                viewModel.openSFTP(for: host)
            } else if let adHoc = QuickConnectParser.parse(target) {
                viewModel.openSFTP(for: adHoc)
            }
        }
        // Open a tab per named host (or user@host), then split the last one.
        if let labels = defaults.string(forKey: "debugConnect") {
            let hosts = savedHosts
            for label in labels.split(separator: ",") {
                if label == "local" {
                    viewModel.addLocalTerminalTab()
                } else if let host = hosts.first(where: { $0.label == label }) {
                    viewModel.connect(to: host)
                } else if let adHoc = QuickConnectParser.parse(String(label)) {
                    viewModel.connect(to: adHoc)
                }
            }
            for index in 0..<defaults.integer(forKey: "debugSplit") {
                try? await Task.sleep(for: .milliseconds(300))
                viewModel.splitFocusedPane(index.isMultiple(of: 2) ? .horizontal : .vertical)
            }
            if defaults.bool(forKey: "debugSnippets") { viewModel.showSnippetPanel = true }
            if defaults.bool(forKey: "debugBroadcast") { viewModel.toggleBroadcast() }
        }
        // -debugDumpWindow <file>: the window's frame and minimum size once the page has settled.
        if let path = defaults.string(forKey: "debugDumpWindow") {
            try? await Task.sleep(for: .seconds(3))
            var lines = NSApp.windows.filter { $0.isVisible }.map {
                "\($0.title) frame=\($0.frame.size) min=\($0.minSize) contentMin=\($0.contentMinSize)"
            }
            func walk(_ view: NSView, _ depth: Int) {
                if view is NSSplitView || depth < 3 {
                    lines.append(String(repeating: " ", count: depth) + "\(type(of: view)) \(view.frame)")
                }
                if let split = view as? NSSplitView {
                    for sub in split.arrangedSubviews { lines.append(String(repeating: " ", count: depth + 1) + "pane \(sub.frame)") }
                }
                for sub in view.subviews { walk(sub, depth + 1) }
            }
            if let content = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.contentView {
                walk(content, 0)
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    #endif

    private func colorScheme(for theme: String) -> ColorScheme? {
        switch theme {
        case "Dark": return .dark
        case "Light": return .light
        default: return nil
        }
    }
}

/// Screenshots are taken while the screen is locked, where no window becomes key and every
/// control draws in its inactive state (grey selection, grey primary button). In a debug build
/// `-debugActive YES` makes SwiftUI draw the window's content as in a key window.
private struct DebugControlState: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if AppProfile.arguments.bool(forKey: "debugActive") {
            content.environment(\.controlActiveState, .key)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if DEBUG
/// A sheet shown on its own from `-debugSheet <name>`, with the first records of the
/// database as sample data. Debug builds only.
private struct DebugPreview: Identifiable {
    let id = UUID()
    let view: AnyView

    @MainActor
    static func make(_ name: String, securityVM: SecurityViewModel) async -> DebugPreview? {
        let hosts = (try? await HostRepository.shared.fetchAll()) ?? []
        let view: AnyView
        switch name {
        case "hostForm":
            view = AnyView(HostFormView { _ in })
        case "hostFormEdit":
            guard let host = hosts.first(where: { $0.label == "test-a" }) ?? hosts.first else { return nil }
            view = AnyView(HostFormView(host: host) { _ in })
        case "groupForm":
            view = AnyView(GroupFormView { _ in })
        case "portForwardForm":
            view = AnyView(PortForwardFormView(hostId: hosts.first?.id ?? 0) { _ in })
        case "portForwardPicker":
            view = AnyView(PortForwardHostPickerView { _, _ in })
        case "identityForm":
            view = AnyView(IdentityFormSheet(viewModel: IdentitiesViewModel(), identity: nil))
        case "keyGenerate":
            view = AnyView(KeyGenerateSheet(viewModel: KeysViewModel()))
        case "keyImport":
            view = AnyView(KeyImportSheet(viewModel: KeysViewModel()))
        case "keyInstall":
            guard let key = (try? await SSHKeyRepository.shared.fetchAll())?.first else { return nil }
            view = AnyView(KeyInstallSheet(key: key))
        case "snippetForm":
            view = AnyView(SnippetFormSheet(viewModel: SnippetsViewModel(), snippet: nil))
        case "masterPassword":
            view = AnyView(MasterPasswordSetupView(securityVM: securityVM))
        case "transcript":
            guard let log = (try? await ConnectionLogRepository.shared.fetchAll())?.first,
                  let id = log.id else { return nil }
            view = AnyView(SessionTranscriptView(logId: id, log: log))
        case "containerLogs":
            view = AnyView(ContainerLogsSheet(
                containerName: "web",
                containerId: "4f1c2a9be0d3",
                output: "2026-10-04T00:00:01Z listening on :8080\n2026-10-04T00:00:02Z GET /healthz 200 1ms\n"
            ))
        default:
            return nil
        }
        return DebugPreview(view: view)
    }
}
#endif
