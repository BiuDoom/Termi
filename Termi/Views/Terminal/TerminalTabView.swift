import SwiftUI
import AppKit
import SwiftTerm

/// All terminal tabs of the window. Every tab stays in the hierarchy (only the active one is
/// visible) — sessions live in `AppViewModel` anyway, so switching tabs never disconnects.
struct TerminalTabView: View {
    @Environment(AppViewModel.self) private var viewModel
    /// The window's appearance: the glass that floats over the terminal (status bar, state
    /// cards) follows it, while the terminal area follows its terminal theme.
    @Environment(\.colorScheme) private var windowScheme

    var body: some View {
        if viewModel.tabs.isEmpty {
            ContentUnavailableView {
                Label("No terminal open", systemImage: "terminal")
            } actions: {
                Button("New Terminal") {
                    viewModel.addLocalTerminalTab()
                }
                .help("New Terminal (⌘T)")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                ForEach(viewModel.tabs) { tab in
                    let isActive = tab.id == viewModel.activeTabId
                    let terminalTheme = theme(for: tab)
                    PaneLayoutView(tab: tab, layout: tab.layout)
                        .environment(\.terminalWindowScheme, windowScheme)
                        .environment(\.colorScheme, terminalTheme.isDark ? .dark : .light)
                        // The status bar floats on the terminal's own background, below the
                        // panes: it never covers the prompt on the last line.
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            SessionStatusBar(tab: tab, isActive: isActive && viewModel.isViewingTerminal)
                        }
                        // Split dividers are translucent: they sit on the theme's background, not the window's.
                        // Inside the pane area only: by default a background also fills the safe area,
                        // which here lies under the sidebar and the inspector, and would tint them.
                        .background(Color(nsColor: terminalTheme.nsBackground), ignoresSafeAreaEdges: [])
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .zIndex(isActive ? 1 : 0)
                }
            }
            // Tiles, jump chains and group names come from the hosts page's model.
            .task {
                await viewModel.ensureHostsLoaded()
                #if DEBUG
                // -debugLeaveTerminal YES: back to the page once the sessions of -debugConnect
                // are up (a page that shows which hosts have a session, for a screenshot).
                if AppProfile.arguments.bool(forKey: "debugLeaveTerminal") {
                    try? await Task.sleep(for: .seconds(3))
                    if let page = AppProfile.arguments.string(forKey: "debugPage").flatMap(SidebarItem.init(rawValue:)) {
                        viewModel.selectedSidebar = page
                    }
                    viewModel.isViewingTerminal = false
                }
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .dsDataChanged)) { _ in
                // A forwarding rule may have been added or removed.
                for pane in viewModel.tabs.flatMap(\.panes) {
                    guard let session = viewModel.existingSession(for: pane.id) else { continue }
                    Task { await session.reloadPortForwards() }
                }
            }
        }
    }

    /// The terminal area follows its terminal theme, not the window's appearance: split
    /// dividers and pane headers sit on the theme's background.
    private func theme(for tab: TerminalTab) -> TerminalTheme {
        let pane = tab.panes.first { $0.id == tab.focusedPaneId } ?? tab.panes.first
        return viewModel.terminalTheme(of: pane.flatMap { viewModel.existingSession(for: $0.id) })
    }
}

private struct TerminalWindowSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
    /// The window's colour scheme, inside the terminal area (whose own scheme is the theme's);
    /// nil everywhere else.
    var terminalWindowScheme: ColorScheme? {
        get { self[TerminalWindowSchemeKey.self] }
        set { self[TerminalWindowSchemeKey.self] = newValue }
    }
}

extension View {
    /// Under glass that floats over a terminal: a wash of the window's own background. Glass
    /// takes its tone from what is behind it, and a terminal is dark in a light window (or
    /// light in a dark one) — without this the bar turns a murky grey that its text, drawn
    /// for the window's appearance, cannot be read on.
    func terminalGlassBed(_ shape: DSGlassShape) -> some View {
        background(SwiftUI.Color(nsColor: .windowBackgroundColor).opacity(0.82), in: shape.shape)
    }
}

extension AppViewModel {
    /// The host a session runs on, with the system the hosts page knows by now: the session
    /// keeps the record it connected with, and the system is only read after that.
    func currentHost(of session: TerminalSession) -> Host? {
        let saved = (session.connectionHost?.id ?? session.pane.hostId).flatMap { id in
            hostsPage.hosts.first { $0.id == id }
        }
        guard var host = session.connectionHost else { return saved }
        if let saved {
            host.osId = saved.osId
            host.osName = saved.osName
            host.osArch = saved.osArch
            host.osDetectedAt = saved.osDetectedAt
        }
        return host
    }

    /// The colour theme a session's terminal is drawn in: its host's, else the app's.
    func terminalTheme(of session: TerminalSession?) -> TerminalTheme {
        let hostTheme = session?.host?.terminalTheme
        return TerminalTheme.find(hostTheme.flatMap { $0.isEmpty ? nil : $0 } ?? terminalColorTheme)
    }

    /// This Mac, the jump chain and the host, with `status` on the host itself.
    func routeHops(to host: Host, status: DSHostAvatar.Status,
                   jumpStatus: DSHostAvatar.Status = .none) -> [DSRouteDiagram.Hop] {
        var hops = host.routeHops(hosts: hostsPage.hosts, groups: hostsPage.allGroups)
        guard !hops.isEmpty else { return hops }
        for index in hops.indices where index > 0 && index < hops.count - 1 {
            hops[index].status = jumpStatus
        }
        hops[hops.count - 1].status = status
        return hops
    }

    /// The route, when there is one to draw: only through a jump host. "This Mac ···· host"
    /// alone says what the title next to it already says.
    func jumpRouteHops(to host: Host, status: DSHostAvatar.Status,
                       jumpStatus: DSHostAvatar.Status = .none) -> [DSRouteDiagram.Hop]? {
        let hops = routeHops(to: host, status: status, jumpStatus: jumpStatus)
        return DSRouteDiagram.passesJumpHost(hops) ? hops : nil
    }
}

extension DSRouteDiagram {
    /// More than this Mac and the host itself.
    nonisolated static func passesJumpHost(_ hops: [Hop]) -> Bool {
        DSRouteDiagram.addsSomething(hopCount: hops.count)
    }
}

extension TerminalSession.State {
    /// The state in a word, for the status bar.
    var statusTitle: LocalizedStringKey {
        switch self {
        case .running: return "Running"
        case .connected: return "Connected"
        case .idle, .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .ended: return "Session ended"
        case .failed: return "Failed"
        }
    }

    var statusTone: DS.Tone {
        switch self {
        case .running, .connected: return .success
        case .idle, .connecting, .reconnecting: return .warning
        case .ended: return .inactive
        case .failed: return .danger
        }
    }

    var avatarStatus: DSHostAvatar.Status {
        DSHostAvatar.Status(states: [self])
    }
}

extension TerminalSession {
    /// Forwarding rules of the host that are up right now.
    var runningTunnelCount: Int {
        portForwards.filter { PortForwardManager.shared.status(of: $0) == .active }.count
    }
}

// MARK: - Status bar

/// The floating bar under a tab's panes: where the focused pane is connected to, its state and
/// how long it has been up, tunnels and grid size. What does not change by the second (sign-in,
/// the host's record) is the inspector's; whose session it is, the tab's.
private struct SessionStatusBar: View {
    @Environment(AppViewModel.self) private var appViewModel
    /// False while the app is locked: the room stays, the bar (address, clock) does not.
    @Environment(\.isEnabled) private var isEnabled
    let tab: TerminalTab
    /// Hidden tabs keep the room (the terminal must not change size with a tab switch) but
    /// not the bar, whose clock ticks every second.
    let isActive: Bool

    private static let height: CGFloat = 38

    var body: some View {
        Group {
            if isActive, isEnabled, let pane = tab.focusedPane, let session = appViewModel.existingSession(for: pane.id) {
                bar(session)
            } else {
                Color.clear
            }
        }
        .frame(height: Self.height)
        .padding(.horizontal, DS.Space.md)
        .padding(.top, DS.Space.sm)
        .padding(.bottom, DS.Space.md)
    }

    private func bar(_ session: TerminalSession) -> some View {
        let host = appViewModel.currentHost(of: session)
        let state = session.displayState
        let isLive = state == .connected || state == .running
        return HStack(spacing: DS.Space.md) {
            identity(session, host: host)
                .frame(maxWidth: .infinity, alignment: .leading)
            center(session, state: state)
                .fixedSize()
            // Gives up the size first, then the tunnels.
            ViewThatFits(in: .horizontal) {
                facts(session, isLive: isLive, showsSize: true)
                facts(session, isLive: isLive, showsSize: false)
                Color.clear.frame(width: 0, height: 0)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, DS.Space.lg)
        .frame(height: Self.height)
        .dsFloatingBar()
        .terminalGlassBed(.capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Session Status"))
    }

    /// The address only: the tile and the name are on the tab above.
    @ViewBuilder
    private func identity(_ session: TerminalSession, host: Host?) -> some View {
        HStack(spacing: DS.Space.sm) {
            if session.isSSH {
                if let host {
                    Text(verbatim: host.addressDescription)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .truncationMode(.middle)
                    if let jump = host.firstJumpName(hosts: appViewModel.hostsPage.hosts,
                                                     groups: appViewModel.hostsPage.allGroups) {
                        HStack(spacing: DS.Space.xs) {
                            Text(verbatim: "·")
                            Text("via \(jump)")
                        }
                        .layoutPriority(-1)
                    }
                } else {
                    Text(verbatim: session.title)
                        .foregroundStyle(.primary)
                }
            } else {
                Text(verbatim: TerminalSession.localShellName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private func center(_ session: TerminalSession, state: TerminalSession.State) -> some View {
        if tab.isSplit && tab.broadcastInput {
            // Orange says "careful", the words say what: every pane receives what is typed.
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(DS.Palette.warning)
                Text("Input is broadcast to \(tab.panes.count) panes")
                    .foregroundStyle(.primary)
            }
            .fontWeight(.semibold)
        } else {
            HStack(spacing: 7) {
                SessionStateWord(state: state)
                if let since = session.connectedSince, state == .connected || state == .running {
                    SessionClock(since: since)
                }
            }
        }
    }

    private func facts(_ session: TerminalSession, isLive: Bool, showsSize: Bool) -> some View {
        let tunnels = session.runningTunnelCount
        return HStack(spacing: 14) {
            if isLive, tunnels > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(tunnels) tunnels")
                        .monospacedDigit()
                }
            }
            if isLive, showsSize, let columns = session.columns, let rows = session.rows {
                Text(verbatim: "\(columns)×\(rows)")
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel(Text("Grid Size"))
                    .accessibilityValue(Text(verbatim: "\(columns) × \(rows)"))
            }
        }
        .fixedSize()
    }
}

/// The state of the focused session in the status bar: a lit dot and the word, in the bar's
/// own 12 pt (a chip's 11 pt reads as a label beside the address and the clock).
private struct SessionStateWord: View {
    let state: TerminalSession.State

    var body: some View {
        let tone = state.statusTone
        HStack(spacing: 6) {
            DSStatusDot(color: tone.color, isPulsing: tone == .warning, size: 7)
                // States that are over do not glow.
                .shadow(color: tone.color.opacity(tone == .inactive ? 0 : 0.8), radius: 4)
            Text(state.statusTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone == .inactive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A terminal theme in four dots — its background, its text, its green and its blue — next to
/// the theme's name in the inspector (a host with a theme of its own).
struct TerminalThemeDots: View {
    let theme: TerminalTheme
    var size: CGFloat = 9

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.colors(of: theme).enumerated()), id: \.offset) { item in
                let shape = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                shape
                    .fill(SwiftUI.Color(nsColor: item.element))
                    .frame(width: size, height: size)
                    // A dark background on a dark bar (a light one on a light bar) keeps an edge.
                    .overlay(shape.strokeBorder(SwiftUI.Color.primary.opacity(0.22), lineWidth: 0.5))
            }
        }
        .accessibilityHidden(true)
    }

    /// ANSI 2 is green and 4 is blue; a theme with a short palette shows what it has.
    static func colors(of theme: TerminalTheme) -> [NSColor] {
        var colors: [NSColor] = [theme.nsBackground, theme.nsForeground]
        for index in [2, 4] where index < theme.ansiColors.count {
            colors.append(TerminalTheme.nsColor(hex: theme.ansiColors[index]))
        }
        return colors
    }
}

/// "00:12:04", counting up from `since`.
struct SessionClock: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(verbatim: TerminalSession.elapsedText(seconds: Int(context.date.timeIntervalSince(since))))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }
}

/// Recursive split layout of a tab's panes.
struct PaneLayoutView: View {
    let tab: TerminalTab
    let layout: PaneLayout

    var body: some View {
        switch layout {
        case .pane(let paneId):
            if let pane = tab.panes.first(where: { $0.id == paneId }) {
                TerminalPaneView(tab: tab, pane: pane)
            }
        case .split(let axis, let children):
            PaneSplit(tab: tab, axis: axis, children: children)
        }
    }
}

/// One split: its children share the space equally until a divider is dragged.
struct PaneSplit: View {
    let tab: TerminalTab
    let axis: SplitAxis
    let children: [PaneLayout]

    /// Relative size of each child, keyed by its id; a child without an entry weighs 1.
    @State private var weights: [UUID: CGFloat] = [:]
    /// Weights of the two children next to the divider when its drag began.
    @State private var dragStart: (leading: CGFloat, trailing: CGFloat)?

    private static let dividerThickness: CGFloat = 1
    private var minimumLength: CGFloat { axis == .horizontal ? 160 : 90 }

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let available = max(0, total - CGFloat(children.count - 1) * Self.dividerThickness)
            let sum = children.reduce(CGFloat(0)) { $0 + weight(of: $1.id) }
            let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))

            stack {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    let length = sum > 0 ? available * weight(of: child.id) / sum : 0
                    AnyView(PaneLayoutView(tab: tab, layout: child))
                        .frame(width: axis == .horizontal ? length : nil,
                               height: axis == .vertical ? length : nil)
                    if index < children.count - 1 {
                        divider(after: index, available: available, sum: sum)
                    }
                }
            }
        }
    }

    private func weight(of id: UUID) -> CGFloat {
        weights[id] ?? 1
    }

    private func divider(after index: Int, available: CGFloat, sum: CGFloat) -> some View {
        Rectangle()
            .fill(DS.Palette.separator)
            .frame(width: axis == .horizontal ? Self.dividerThickness : nil,
                   height: axis == .vertical ? Self.dividerThickness : nil)
            .overlay {
                // Wider invisible grab area around the hairline.
                Color.clear
                    .frame(width: axis == .horizontal ? 9 : nil, height: axis == .vertical ? 9 : nil)
                    .contentShape(Rectangle())
                    .pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let delta = axis == .horizontal ? value.translation.width : value.translation.height
                                resize(after: index, by: delta, available: available, sum: sum)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .zIndex(1)
    }

    /// Move the divider after `index`: the two neighbours trade space, the others keep theirs.
    private func resize(after index: Int, by delta: CGFloat, available: CGFloat, sum: CGFloat) {
        guard available > 0, sum > 0, index + 1 < children.count else { return }
        let leadingId = children[index].id
        let trailingId = children[index + 1].id
        let start = dragStart ?? (leading: weight(of: leadingId), trailing: weight(of: trailingId))
        if dragStart == nil { dragStart = start }

        let pairWeight = start.leading + start.trailing
        let pairLength = available * pairWeight / sum
        guard pairLength > 0 else { return }
        let minimum = min(minimumLength, pairLength / 2)
        let leadingLength = min(max(available * start.leading / sum + delta, minimum), pairLength - minimum)
        let leadingWeight = pairWeight * leadingLength / pairLength
        weights[leadingId] = leadingWeight
        weights[trailingId] = pairWeight - leadingWeight
    }
}

/// One pane: its header (while the tab is split), the terminal and the connection-state cards.
struct TerminalPaneView: View {
    @Environment(AppViewModel.self) private var appViewModel
    /// False while the app is locked (the window's content is disabled behind the lock screen).
    @Environment(\.isEnabled) private var isEnabled
    let tab: TerminalTab
    let pane: TerminalPane

    var body: some View {
        // No session: the pane was closed and this view is on its way out.
        if let session = appViewModel.session(for: pane) {
            content(session)
        }
    }

    private func content(_ session: TerminalSession) -> some View {
        let isFocused = tab.focusedPaneId == pane.id
        let isActiveTab = tab.id == appViewModel.activeTabId && appViewModel.isViewingTerminal && isEnabled
        let isShownTab = tab.id == appViewModel.activeTabId
        return VStack(spacing: 0) {
            // The header says where typing goes: the focused pane's is lit, and while
            // broadcasting every pane's is, in the warning colour. (A ring around the pane
            // used to say it, drawn over the terminal's first and last columns.)
            //
            // Only the tab on screen has its chrome (header, close button, state card): a tab
            // behind another one is transparent, but accessibility still listed its header and
            // "Close Pane" button — VoiceOver reached controls nobody can see. The terminal
            // itself stays mounted, in a pane of the same size (no resize reaches the shell).
            if tab.isSplit {
                if isShownTab {
                    PaneHeader(tab: tab, pane: pane, session: session, isFocused: isFocused)
                } else {
                    // A plain colour is no accessibility element; with `accessibilityHidden`
                    // it became one (an "unknown" element), hidden or not.
                    SwiftUI.Color.clear
                        .frame(height: PaneHeader.height)
                }
            }
            ZStack {
                TerminalHostView(session: session, generation: session.viewGeneration,
                                 wantsFocus: isFocused && isActiveTab, isVisible: isActiveTab,
                                 colorTheme: appViewModel.terminalColorTheme)
                if isShownTab {
                    SessionOverlayView(session: session, pane: pane)
                        // Behind a page or the lock screen the card stays: with the terminal no longer
                        // first responder, Return / Esc would otherwise trigger its Retry / Reconnect /
                        // Cancel buttons.
                        .disabled(!isActiveTab)
                }
            }
        }
        .task(id: pane.id) {
            session.startIfNeeded()
        }
    }
}

/// What a pane's header writes. The tab above already carries the host's tile and name: a pane
/// of that same host says only what tells it from its neighbours, the program running in it.
struct PaneHeaderContent: Equatable {
    /// Tile and name: a pane of another host than the tab's.
    var showsHost: Bool
    /// The one line of text.
    var text: String

    /// `name` is the pane's host (or the pane's own name, for a local shell).
    nonisolated static func resolve(name: String, tabTitle: String, program: String?) -> PaneHeaderContent {
        let program = program.flatMap { $0.isEmpty || $0 == name ? nil : $0 }
        guard name == tabTitle else {
            return PaneHeaderContent(showsHost: true, text: program.map { name + " · " + $0 } ?? name)
        }
        // Nothing runs that has a title of its own: the name is all there is to write.
        return PaneHeaderContent(showsHost: false, text: program ?? name)
    }

    /// For VoiceOver the host is always said: it does not see the tab while it is in a pane.
    nonisolated static func accessibilityLabel(name: String, program: String?) -> String {
        guard let program, !program.isEmpty, program != name else { return name }
        return name + ", " + program
    }
}

/// The strip above a pane of a split tab: what runs in it (and the host's tile and name when
/// that is not the tab's host), lit where typing goes.
private struct PaneHeader: View {
    @Environment(AppViewModel.self) private var appViewModel
    let tab: TerminalTab
    let pane: TerminalPane
    let session: TerminalSession
    let isFocused: Bool
    @State private var isHovered = false

    /// The strip's height; a pane of a tab that is not shown keeps it free.
    static let height: CGFloat = 26

    private var isBroadcasting: Bool { tab.broadcastInput }

    var body: some View {
        let content = PaneHeaderContent.resolve(name: name, tabTitle: tab.title, program: session.programTitle)
        HStack(spacing: 7) {
            if content.showsHost {
                avatar
            }
            // Broadcasting is the strip's colour (and the status bar's sentence, and the
            // toolbar's switch): no glyph of its own here.
            Text(verbatim: content.text)
                .fontWeight(.semibold)
                .foregroundStyle(isFocused ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .truncationMode(.middle)
                .accessibilityLabel(Text(verbatim: PaneHeaderContent.accessibilityLabel(
                    name: name, program: session.programTitle)))
                .accessibilityValue(isBroadcasting ? Text("Broadcasting") : Text(verbatim: ""))
            Spacer(minLength: DS.Space.xs)
            DSRowButton("xmark", help: "Close Pane") {
                // The same question as ⌘W, which is asked of the focused pane.
                appViewModel.focus(paneId: pane.id)
                appViewModel.confirmAndCloseFocusedPane()
            }
            .opacity(isFocused || isHovered ? 1 : 0)
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .padding(.leading, DS.Space.card)
        .padding(.trailing, DS.Space.xs)
        .frame(height: Self.height)
        // Inside the strip only: a background also fills the safe area by default, and the
        // lit header of a pane then ran up under the toolbar and across under the inspector.
        .background(headerFill, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isFocused ? AnyShapeStyle(lineColor.opacity(0.55)) : AnyShapeStyle(DS.Palette.separator))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            appViewModel.focus(paneId: pane.id)
            appViewModel.requestFocus(pane.id)
        }
        .animation(DS.Motion.quick, value: isFocused)
        .animation(DS.Motion.quick, value: isBroadcasting)
        .help(isBroadcasting ? Text("Broadcast Input to All Panes (⇧⌘B)") : Text(verbatim: ""))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    @ViewBuilder
    private var avatar: some View {
        if !session.isSSH {
            DSHostAvatar.local(size: DS.Tile.tab)
        } else if let host = appViewModel.currentHost(of: session) {
            DSHostAvatar(host, size: DS.Tile.tab)
        } else {
            DSHostAvatar(os: .unknown, size: DS.Tile.tab)
        }
    }

    /// A local shell takes the program's title as its own: its header keeps the pane's name.
    private var name: String {
        session.isSSH ? session.title : pane.title
    }

    private var lineColor: SwiftUI.Color {
        isBroadcasting ? DS.Palette.warning : SwiftUI.Color.accentColor
    }

    private var headerFill: SwiftUI.Color {
        if isBroadcasting { return DS.Palette.warning.opacity(isFocused ? 0.30 : 0.16) }
        return isFocused ? SwiftUI.Color.accentColor.opacity(0.30) : SwiftUI.Color.primary.opacity(0.05)
    }
}

/// Hosts the session's terminal view. The view is owned by the session and only re-parented
/// here, so SwiftUI re-creating this wrapper (splits, tab switches) never touches the shell.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    /// Changes when the session swaps its terminal view (reconnect).
    let generation: Int
    let wantsFocus: Bool
    /// False while the pane is hidden (another tab or another page is showing).
    let isVisible: Bool
    /// Current colour theme: a change re-runs `updateNSView` so the inset takes the new background.
    let colorTheme: String

    func makeNSView(context: Context) -> TerminalContainerNSView {
        let container = TerminalContainerNSView()
        session.viewHost = container
        container.attach(session.ensureTerminalView())
        return container
    }

    func updateNSView(_ container: TerminalContainerNSView, context: Context) {
        // A wrapper that has been replaced (closing a pane of a nested split rebuilds its
        // sibling's) is updated once more before it leaves; taking the view back here would
        // carry it out of the window and leave the pane blank.
        if session.viewHost == nil { session.viewHost = container }
        guard session.viewHost === container else { return }
        container.attach(session.ensureTerminalView())
        container.needsLayout = true
        // SwiftUI only makes a hidden pane transparent; hiding the terminal itself takes it
        // out of the key-view loop and of hit testing.
        container.setTerminal(hidden: !isVisible, wantsFocus: wantsFocus)
    }

    /// The pane decides the terminal's size, never the other way round: whatever AppKit's
    /// constraints inside the terminal ask for (SwiftTerm's find bar wants 440 pt), a pane
    /// that grew past its share would cover its neighbour.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalContainerNSView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

final class TerminalContainerNSView: NSView {
    private weak var terminal: NSView?
    private var pendingFocus = false
    private var stateUpdateScheduled = false

    /// True while the pane is not on screen (another tab or page is showing, or the app is locked).
    private(set) var isTerminalHidden = false

    /// What the pane is to be once the current view update is over. Nothing is applied here:
    /// hiding the first responder makes AppKit look for the next key view, which asks the
    /// hosting view's focus system and so re-enters SwiftUI's view graph in the middle of its
    /// update. With the lock screen coming up that update never ended and the app hung.
    func setTerminal(hidden: Bool, wantsFocus: Bool) {
        isTerminalHidden = hidden
        if hidden {
            pendingFocus = false
        } else if wantsFocus {
            pendingFocus = true
        }
        let needsChange = terminal?.isHidden != hidden || pendingFocus
            || (hidden && window?.firstResponder === terminal)
        guard needsChange, !stateUpdateScheduled else { return }
        stateUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateUpdateScheduled = false
            self.applyTerminalState()
        }
    }

    private func applyTerminalState() {
        // The session re-parents its view: only touch it while it is still ours.
        guard let terminal, terminal.superview === self else { return }
        if isTerminalHidden {
            // Otherwise AppKit leaves the terminal as first responder, and keystrokes meant for
            // the visible page or the lock screen reach the shell.
            if let window, window.firstResponder === terminal {
                window.makeFirstResponder(nil)
            }
            terminal.isHidden = true
        } else {
            terminal.isHidden = false
            applyPendingFocus()
        }
    }

    /// Breathing room between the text and the pane's edges (filled with the terminal's
    /// own background colour, so it reads as part of the terminal).
    /// As wide as a pane header's leading padding: the text starts under the header's tile.
    private static let contentInset = NSSize(width: 10, height: 4)

    private var terminalFrame: NSRect {
        bounds.insetBy(dx: Self.contentInset.width, dy: Self.contentInset.height)
    }

    func attach(_ view: NSView) {
        guard view.superview !== self else { return }
        terminal?.removeFromSuperview()
        view.removeFromSuperview()
        view.frame = terminalFrame
        view.autoresizingMask = [.width, .height]
        view.isHidden = isTerminalHidden
        addSubview(view)
        terminal = view
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPendingFocus()
    }

    private func applyPendingFocus() {
        guard pendingFocus, let window, let terminal else { return }
        pendingFocus = false
        DispatchQueue.main.async { [weak window, weak terminal] in
            guard let window, let terminal, window.firstResponder !== terminal,
                  window.attachedSheet == nil else { return }
            // Don't steal focus from text fields (e.g. the snippet search box).
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return }
            window.makeFirstResponder(terminal)
        }
    }

    override func layout() {
        super.layout()
        terminal?.frame = terminalFrame
        wantsLayer = true
        layer?.backgroundColor = (terminal as? TerminalView)?.nativeBackgroundColor.cgColor
    }
}

// MARK: - State cards

/// The card or bottom banner over a pane that is not (yet, or no longer) a running shell.
struct SessionOverlayView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let session: TerminalSession
    let pane: TerminalPane
    @State private var showRawSSHLog = false

    var body: some View {
        let state = session.displayState
        let host = appViewModel.currentHost(of: session)
        ZStack {
            switch state {
            case .idle, .running, .connected:
                EmptyView()

            case .connecting:
                // Over an open master connection (split, duplicated tab) this is over within a
                // moment: the card only shows once connecting takes long enough to be read.
                DSDelayed {
                    SessionStateCard(avatar: avatar(host, .busy), title: Text("Connecting to \(session.title)")) {
                        // Nothing is reached yet: the wires stay grey until the session is up.
                        route(host, status: .busy, activity: .flowing, reachedHops: 1)
                        ConnectionStepperView(activeStep: 1, isFailed: false)
                        if let host {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Sign-in: \(host.authTitle)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } actions: {
                        Button {
                            session.cancelConnecting()
                        } label: {
                            Text("Cancel")
                                .frame(minWidth: 88)
                        }
                        .keyboardShortcut(.cancelAction)
                        .dsButtonStyle(.glass)
                    }
                }

            case .reconnecting(let attempt, let retryAt):
                if session.hasTerminalOutput {
                    VStack {
                        Spacer(minLength: 0)
                        SessionReconnectBanner(
                            tone: .warning,
                            title: Text("Connection lost"),
                            subtitle: nil
                        ) {
                            RetryCountdown(attempt: attempt, retryAt: retryAt)
                        } actions: {
                            Button("Reconnect Now") { session.reconnect() }
                                .dsButtonStyle(.prominent, size: .small)
                            Button("Close") { appViewModel.closePane(pane.id) }
                                .dsButtonStyle(.glass, size: .small)
                        }
                    }
                } else {
                    SessionStateCard(avatar: avatar(host, .busy), title: Text("Connection lost")) {
                        route(host, status: .busy, activity: .idle)
                        RetryCountdown(attempt: attempt, retryAt: retryAt)
                    } actions: {
                        Button("Reconnect Now") { session.reconnect() }
                            .dsButtonStyle(.prominent)
                        Button("Close") { appViewModel.closePane(pane.id) }
                            .dsButtonStyle(.glass)
                    }
                }

            case .ended(let message):
                if let message {
                    if session.hasTerminalOutput {
                        VStack {
                            Spacer(minLength: 0)
                            SessionReconnectBanner(
                                tone: .inactive,
                                title: Text(verbatim: message),
                                subtitle: nil
                            ) {
                                EmptyView()
                            } actions: {
                                if session.isSSH {
                                    Button("Reconnect") { session.reconnect() }
                                        .keyboardShortcut(.defaultAction)
                                        .dsButtonStyle(.prominent, size: .small)
                                }
                                Button("Close") { appViewModel.closePane(pane.id) }
                                    .dsButtonStyle(.glass, size: .small)
                            }
                        }
                    } else {
                        SessionStateCard(avatar: avatar(host, .ended), title: Text(verbatim: message)) {
                            EmptyView()
                        } actions: {
                            if session.isSSH {
                                Button("Reconnect") { session.reconnect() }
                                    .keyboardShortcut(.defaultAction)
                                    .dsButtonStyle(.prominent)
                            }
                            Button("Close") { appViewModel.closePane(pane.id) }
                                .dsButtonStyle(.glass)
                        }
                    }
                }

            case .failed(let message):
                if session.hasTerminalOutput {
                    VStack {
                        Spacer(minLength: 0)
                        SessionReconnectBanner(
                            tone: .danger,
                            title: Text("Connection Failed"),
                            subtitle: message
                        ) {
                            EmptyView()
                        } actions: {
                            Button("Retry") { session.reconnect() }
                                .keyboardShortcut(.defaultAction)
                                .dsButtonStyle(.prominent, size: .small)
                            DSCopyButton("Copy Error") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message, forType: .string)
                            }
                            .dsButtonStyle(.glass, size: .small)
                            Button("Close") { appViewModel.closePane(pane.id) }
                                .dsButtonStyle(.glass, size: .small)
                        }
                    }
                } else {
                    SessionStateCard(avatar: avatar(host, .failed), title: Text("Connection Failed"),
                                     compactNote: message) {
                        route(host, status: .failed, activity: .failed)
                        ConnectionStepperView(activeStep: 1, isFailed: true)
                        DSMessage(verbatim: firstLine(of: message))
                            .multilineTextAlignment(.leading)
                        DisclosureGroup("Raw SSH Log", isExpanded: $showRawSSHLog) {
                            ScrollView {
                                Text(verbatim: message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(DS.Space.sm)
                            }
                            .frame(maxHeight: 110)
                            .background(
                                SwiftUI.Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                            )
                            .padding(.top, DS.Space.xs)
                        }
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                    } actions: {
                        Button("Retry") { session.reconnect() }
                            .keyboardShortcut(.defaultAction)
                            .dsButtonStyle(.prominent)
                        if let host = session.host, host.id != nil {
                            Button("Edit Host…") { appViewModel.hostToEdit = host }
                                .dsButtonStyle(.glass)
                        }
                        DSCopyButton("Copy Error") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message, forType: .string)
                        }
                        .dsButtonStyle(.glass)
                        Button("Close") { appViewModel.closePane(pane.id) }
                            .dsButtonStyle(.glass)
                    }
                }
            }
        }
        .animation(DS.Motion.quick, value: state)
    }

    private func firstLine(of message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.components(separatedBy: .newlines).first ?? trimmed
    }

    private func avatar(_ host: Host?, _ status: DSHostAvatar.Status) -> DSHostAvatar {
        if let host { return DSHostAvatar(host, size: DS.Tile.header, status: status) }
        return DSHostAvatar(os: .unknown, size: DS.Tile.header, status: status)
    }

    /// Only through a jump host: a direct connection's route is the card's title.
    @ViewBuilder
    private func route(_ host: Host?, status: DSHostAvatar.Status, activity: DSRouteDiagram.Activity,
                       reachedHops: Int? = nil) -> some View {
        if let host, let hops = appViewModel.jumpRouteHops(to: host, status: status) {
            DSRouteDiagram(hops: hops, activity: activity, reachedHops: reachedHops)
                .frame(maxWidth: .infinity)
        }
    }
}

/// 3-step SSH connection progress indicator (`Connecting` → `Authenticating` → `Opening Shell`).
private struct ConnectionStepperView: View {
    let activeStep: Int
    let isFailed: Bool

    private let steps: [LocalizedStringKey] = [
        "Connecting",
        "Authenticating",
        "Opening Shell"
    ]

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 5) {
                    stepIcon(for: index)
                    Text(title)
                        .font(.system(size: 11, weight: index <= activeStep ? .semibold : .regular))
                        .foregroundStyle(index <= activeStep ? .primary : .tertiary)
                }
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(index < activeStep ? DS.Palette.success.opacity(0.6) : DS.Palette.separator)
                        .frame(width: 16, height: 1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func stepIcon(for index: Int) -> some View {
        if index < activeStep {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DS.Palette.success)
        } else if index == activeStep {
            if isFailed {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Palette.danger)
            } else {
                DSStatusDot(color: DS.Palette.warning, isPulsing: true, size: 7)
            }
        } else {
            Circle()
                .strokeBorder(SwiftUI.Color.secondary.opacity(0.35), lineWidth: 1)
                .frame(width: 9, height: 9)
        }
    }
}

/// Non-destructive bottom banner shown when an already-active terminal session disconnects or drops,
/// keeping the scrollback output above it visible and selectable.
private struct SessionReconnectBanner<Accessory: View, Actions: View>: View {
    let tone: DS.Tone
    let title: Text
    let subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var actions: Actions
    @Environment(\.terminalWindowScheme) private var windowScheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: DS.Space.md) {
            DSStatusDot(color: tone.color, isPulsing: tone == .warning, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.sm) {
                    title
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    accessory
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(subtitle)
                }
            }
            Spacer(minLength: DS.Space.md)
            HStack(spacing: DS.Space.sm) {
                actions
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm + 2)
        .dsFloatingPanel(cornerRadius: DS.Radius.card)
        .terminalGlassBed(.rect(DS.Radius.card))
        .padding(.horizontal, DS.Space.md)
        .padding(.bottom, DS.Space.sm)
        .environment(\.colorScheme, windowScheme ?? colorScheme)
    }
}

/// "Attempt 3 · 0:12" with a ring that empties until the next try.
private struct RetryCountdown: View {
    let attempt: Int
    let retryAt: Date

    var body: some View {
        // The whole wait, so the ring does not start over when the card is drawn again.
        let delay = TerminalSession.reconnectDelay(attempt: attempt)
        HStack(spacing: DS.Space.sm) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let left = max(0, retryAt.timeIntervalSince(context.date))
                ProgressView(value: min(1, left / max(delay, 0.1)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Text("Attempt \(attempt)")
            // A range needs its end after its start: nothing to count once the time is up.
            // (One reading of the clock: two could straddle `retryAt`, and the range would trap.)
            let now = Date()
            if retryAt > now {
                Text(timerInterval: now...retryAt, countsDown: true)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

/// A floating glass card over a pane: the host's tile, what happened, the route (through a jump
/// host), what to do. A terminal pane's card has no address — the status bar under it has; the
/// SFTP page, which has no status bar, passes it as `subtitle`.
/// A pane too small for it (a split) gets the title, the reason in two lines and the actions;
/// a smaller one still, the title and the actions (the reason is the title's tooltip). The SFTP
/// page shows the same card while it connects.
struct SessionStateCard<Detail: View, Actions: View>: View {
    let avatar: DSHostAvatar
    let title: Text
    var subtitle: String?
    /// What went wrong, for the small card (the large one says it in `detail`).
    var compactNote: String?
    @ViewBuilder var detail: Detail
    @ViewBuilder var actions: Actions
    @Environment(\.terminalWindowScheme) private var windowScheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                avatar
                heading(size: 22)
                    .padding(.top, 18)
                // One block: a modifier on `detail` itself lands on each of its views. Its lines
                // (route, sign-in, countdown, reason) stand 14 pt apart, whichever of them the
                // card has — the route is only there through a jump host.
                if Detail.self != EmptyView.self {
                    VStack(spacing: 14) { detail }
                        .padding(.top, 22)
                }
                if Actions.self != EmptyView.self {
                    actionRow
                        .padding(.top, 22)
                }
            }
            .padding(.horizontal, DS.Space.xxxl)
            .padding(.top, DS.Space.xxxl)
            .padding(.bottom, DS.Space.xxl)
            .frame(maxWidth: 480)
            .dsFloatingPanel()
            .terminalGlassBed(.rect(DS.Radius.sheet))
            .padding(DS.Space.lg)

            if let compactNote, !compactNote.isEmpty {
                compact(note: compactNote)
            }
            compact(note: nil)
                .help(Text(verbatim: compactNote ?? ""))
        }
        // Glass follows the window, not the terminal theme underneath.
        .environment(\.colorScheme, windowScheme ?? colorScheme)
        .transition(.opacity)
    }

    private func compact(note: String?) -> some View {
        VStack(spacing: DS.Space.md) {
            heading(size: 15)
            if let note {
                Text(verbatim: note)
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(Text(verbatim: note))
            }
            if Actions.self != EmptyView.self {
                actionRow
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: 360)
        .dsFloatingPanel(cornerRadius: DS.Radius.card)
        .terminalGlassBed(.rect(DS.Radius.card))
        .padding(DS.Space.sm)
    }

    private func heading(size: CGFloat) -> some View {
        VStack(spacing: 5) {
            title
                .font(.system(size: size, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var actionRow: some View {
        ActionFlow(spacing: DS.Space.sm) { actions }
    }
}

/// The actions of a state card in one centred row; in a pane too narrow for that they wrap
/// into centred rows (two by two) instead of a column of four that fills the pane.
private struct ActionFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, width: bounds.width) {
            var x = bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(of subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extended = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && extended > width {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = extended
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return balanced(rows, of: subviews, width: width)
    }

    /// Four buttons that need two rows go two and two, not three and one.
    private func balanced(_ greedy: [Row], of subviews: Subviews, width: CGFloat) -> [Row] {
        guard greedy.count > 1 else { return greedy }
        let perRow = Int((Double(subviews.count) / Double(greedy.count)).rounded(.up))
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if current.indices.count == perRow {
                rows.append(current)
                current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        // An even split can be wider than the greedy rows were: then those stand.
        return rows.contains { $0.width > width } ? greedy : rows
    }
}
