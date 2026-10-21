import SwiftUI

/// Session tabs as one capsule group in the window toolbar (the toolbar gives it its glass):
/// a host tile with the live state, the title, the number of panes; the active tab is a pill.
/// This is the one list of the open sessions. On a page it stays in the toolbar with every tab
/// reduced to its tile (`tilesOnly`): one click leads back to that session.
struct TabBarView: View {
    @Environment(AppViewModel.self) private var viewModel
    /// The width the group may take in the toolbar.
    let availableWidth: CGFloat
    /// On a page: tiles only, no "+" — nothing here competes with the page's own toolbar.
    var tilesOnly = false
    /// Shows the leading `Vaults` and `SFTP` surface pills inside the toolbar bar.
    var showsSurfaceSwitcher = true

    @Namespace private var namespace

    private var isVaultSurfaceActive: Bool {
        !viewModel.isViewingTerminal && !viewModel.isShowingNewTabPicker && viewModel.selectedSidebar != .sftp
    }

    private var isSFTPSurfaceActive: Bool {
        !viewModel.isViewingTerminal && !viewModel.isShowingNewTabPicker && viewModel.selectedSidebar == .sftp
    }

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            if showsSurfaceSwitcher {
                surfacePill(
                    title: "Vaults",
                    symbol: "server.rack",
                    isActive: isVaultSurfaceActive,
                    badge: 0,
                    help: "Vaults (Hosts, Keys, Port Forwarding, Snippets)",
                    action: { viewModel.selectVaults() }
                )

                surfacePill(
                    title: "SFTP",
                    symbol: "folder",
                    isActive: isSFTPSurfaceActive,
                    badge: viewModel.badge(for: .sftp),
                    help: "SFTP File Browser",
                    action: { viewModel.selectSFTP() }
                )

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, Metrics.dividerInset)
            }

            if tilesOnly {
                if !viewModel.tabs.isEmpty {
                    let visible = Self.tileCount(count: viewModel.tabs.count, available: availableWidth)
                    let active = viewModel.tabs.firstIndex { $0.id == viewModel.activeTabId } ?? 0
                    let range = Self.visibleRange(count: viewModel.tabs.count, active: active, visible: visible)
                    tabs(viewModel.tabs[range], width: nil, compact: true)
                    moreMenu(shown: range)
                }

                Button {
                    viewModel.openNewTabPicker()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(viewModel.isShowingNewTabPicker ? DS.Palette.accent : .secondary)
                        .frame(width: Metrics.plusWidth, height: Metrics.height)
                        .background {
                            if viewModel.isShowingNewTabPicker {
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.2))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("New Tab — Choose Host or Workspace (⌘T)")
                .accessibilityLabel(Text("New Tab"))
                .contextMenu {
                    Button("New Tab — Choose Host (⌘T)") { viewModel.openNewTabPicker() }
                    Button("New Local Terminal (⌘L)") { viewModel.addLocalTerminalTab() }
                }
            } else {
                if !viewModel.tabs.isEmpty {
                    titledTabs

                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, Metrics.dividerInset)
                }

                Button {
                    viewModel.openNewTabPicker()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(viewModel.isShowingNewTabPicker ? DS.Palette.accent : .secondary)
                        .frame(width: Metrics.plusWidth, height: Metrics.height)
                        .background {
                            if viewModel.isShowingNewTabPicker {
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.2))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("New Tab — Choose Host or Workspace (⌘T)")
                .accessibilityLabel(Text("New Tab"))
                .contextMenu {
                    Button("New Tab — Choose Host (⌘T)") { viewModel.openNewTabPicker() }
                    Button("New Local Terminal (⌘L)") { viewModel.addLocalTerminalTab() }
                }
            }
        }
        .padding(.horizontal, Metrics.inset)
        .animation(DS.Motion.standard, value: viewModel.tabs.map(\.id))
        .animation(DS.Motion.standard, value: viewModel.activeTabId)
        .animation(DS.Motion.standard, value: viewModel.isShowingNewTabPicker)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Sessions"))
    }

    private func surfacePill(
        title: LocalizedStringKey,
        symbol: String,
        isActive: Bool,
        badge: Int,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        let shape = Capsule(style: .continuous)
        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isActive ? DS.Palette.accent : .secondary)
                Text(title)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                if badge > 0 {
                    Text(verbatim: badge.formatted())
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 15)
                        .background(DS.Palette.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 9)
            .frame(height: Metrics.height)
            .background {
                if isActive {
                    shape
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay(shape.strokeBorder(Color.accentColor.opacity(0.34), lineWidth: 1))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private var titledTabs: some View {
        switch Self.sizing(count: viewModel.tabs.count, available: availableWidth) {
        case .natural:
            tabs(viewModel.tabs, width: nil, compact: false)
        case .equal(let width):
            // The share is a limit, not a size: a short title in a tab stretched to its
            // share reads as a tab with something missing.
            tabs(viewModel.tabs, width: width, compact: false, isLimit: true)
        case .compact(let activeWidth, let visible):
            // Not a scroll view: inside a toolbar item it loses its offset. The tabs that do
            // not fit are in the "+N" menu.
            let active = viewModel.tabs.firstIndex { $0.id == viewModel.activeTabId } ?? 0
            let range = Self.visibleRange(count: viewModel.tabs.count, active: active, visible: visible)
            tabs(viewModel.tabs[range], width: activeWidth, compact: true)
            moreMenu(shown: range)
        }
    }

    /// "+N": the tabs that do not fit — the only other place they are listed.
    @ViewBuilder
    private func moreMenu(shown range: Range<Int>) -> some View {
        if range.count < viewModel.tabs.count {
            Menu {
                ForEach(Self.hidden(viewModel.tabs, shown: range)) { tab in
                    Button {
                        viewModel.activateTab(tab.id)
                    } label: {
                        // A menu shows a plain image, not a tile: the system's mark.
                        Label {
                            Text(verbatim: viewModel.displayTitle(for: tab))
                        } icon: {
                            RecentHostsMenu.menuImage(for: viewModel.host(of: tab)?.tileContent ?? .symbol("laptopcomputer"))
                        }
                    }
                }
            } label: {
                Text(verbatim: "+\(viewModel.tabs.count - range.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: Metrics.more - Metrics.spacing, height: Metrics.height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sessions")
            .accessibilityLabel(Text("Sessions"))
        }
    }

    private func tabs(_ shown: ArraySlice<TerminalTab>, width: CGFloat?, compact: Bool, isLimit: Bool = false) -> some View {
        ForEach(shown) { tab in
            let index = viewModel.tabs.firstIndex { $0.id == tab.id } ?? 0
            let isActive = tab.id == viewModel.activeTabId && viewModel.isViewingTerminal && !viewModel.isShowingNewTabPicker
            TabItemView(
                tab: tab,
                displayTitle: viewModel.displayTitle(for: tab),
                host: viewModel.host(of: tab),
                status: viewModel.avatarStatus(of: tab),
                isActive: isActive,
                // ⌘1…⌘9 select the first nine tabs.
                shortcut: index < 9 ? "⌘\(index + 1)" : nil,
                width: width,
                widthIsLimit: isLimit,
                // Squeezed: only the active tab keeps its title, the others are their tile.
                showsTileOnly: compact && !isActive,
                namespace: namespace,
                onSelect: { viewModel.activateTab(tab.id) },
                onClose: { viewModel.confirmAndCloseTab(tab.id) },
                onDrop: { sourceId in viewModel.moveTab(from: sourceId, to: tab.id) }
            )
            .transition(.opacity)
        }
    }

    private func tabs(_ shown: [TerminalTab], width: CGFloat?, compact: Bool, isLimit: Bool = false) -> some View {
        tabs(shown[...], width: width, compact: compact, isLimit: isLimit)
    }

    // MARK: - Sizing

    enum Metrics {
        static let height: CGFloat = 28
        static let spacing: CGFloat = 2
        static let inset: CGFloat = 4
        static let plusWidth: CGFloat = 28
        static let dividerInset: CGFloat = 3
        /// A tab is never narrower than this (tile, a few letters, the close button) …
        static let minTab: CGFloat = 92
        /// … and never wider than this, however long its title.
        static let maxTab: CGFloat = 200
        /// A tab reduced to its tile.
        static let tileTab: CGFloat = 30
        /// The "+N" menu of the tabs that do not fit, with its gap.
        static let more: CGFloat = 32
        /// Everything in the group that is not a tab: insets, the divider, the + button.
        static let chrome: CGFloat = 2 * inset + 2 * spacing + 1 + 2 * dividerInset + plusWidth
    }

    enum Sizing: Equatable {
        /// Every tab as wide as its title needs (between the minimum and the maximum).
        case natural
        /// Tabs share the width.
        case equal(CGFloat)
        /// The active tab at `active` points, the others as tiles; `visible` tabs fit in all.
        case compact(active: CGFloat, visible: Int)
    }

    /// How `count` tabs share `available` points of toolbar: at their natural width while even
    /// the widest titles fit, then squeezed equally, then as tiles around the active tab.
    nonisolated static func sizing(count: Int, available: CGFloat) -> Sizing {
        guard count > 0 else { return .natural }
        let n = CGFloat(count)
        let gaps = Metrics.spacing * (n - 1)
        let room = max(available - Metrics.chrome, Metrics.minTab)
        if n * Metrics.maxTab + gaps <= room { return .natural }
        let equal = ((room - gaps) / n).rounded(.down)
        if equal >= Metrics.minTab { return .equal(equal) }
        let tile = Metrics.tileTab + Metrics.spacing
        var space = room
        var fit = 1 + Int(((space - Metrics.minTab) / tile).rounded(.down))
        if fit < count {
            // The "+N" menu of the tabs left out takes room too.
            space = max(room - Metrics.more, Metrics.minTab)
            fit = 1 + Int(((space - Metrics.minTab) / tile).rounded(.down))
        }
        let visible = min(count, fit)
        let active = min(Metrics.maxTab, space - CGFloat(visible - 1) * tile)
        return .compact(active: active.rounded(.down), visible: visible)
    }

    /// How many of `count` tabs fit as tiles into `available` points (on a page); when not all
    /// do, the "+N" menu takes its room first. Never fewer than one.
    nonisolated static func tileCount(count: Int, available: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let tile = Metrics.tileTab + Metrics.spacing
        let room = available - 2 * Metrics.inset + Metrics.spacing
        let all = Int((room / tile).rounded(.down))
        if all >= count { return count }
        return max(1, Int(((room - Metrics.more) / tile).rounded(.down)))
    }

    /// The tabs outside the shown range, in tab order.
    nonisolated static func hidden<Tab>(_ tabs: [Tab], shown: Range<Int>) -> [Tab] {
        let range = shown.clamped(to: 0..<tabs.count)
        return Array(tabs[..<range.lowerBound]) + Array(tabs[range.upperBound...])
    }

    /// Which tabs are shown when only `visible` of `count` fit: a window that holds the active one.
    nonisolated static func visibleRange(count: Int, active: Int, visible: Int) -> Range<Int> {
        let shown = max(1, min(visible, count))
        let start = min(max(0, active - shown + 1), max(0, count - shown))
        return start..<(start + shown)
    }
}

// MARK: - Tab Item

struct TabItemView: View {
    @Environment(AppViewModel.self) private var viewModel
    let tab: TerminalTab
    var displayTitle: String? = nil
    /// Nil for a local shell.
    let host: Host?
    let status: DSHostAvatar.Status
    let isActive: Bool
    let shortcut: String?
    /// Nil: as wide as the title needs.
    let width: CGFloat?
    /// `width` is the most the tab may take; a shorter title keeps its natural width.
    var widthIsLimit = false
    /// Only the tile: the tab bar is out of room.
    var showsTileOnly = false
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDrop: (_ sourceId: UUID) -> Void

    @State private var isHovered = false
    @State private var isDropTarget = false
    @State private var draftTitle = ""
    @FocusState private var isRenameFocused: Bool

    private var shownTitle: String {
        displayTitle ?? tab.title
    }

    private var isRenaming: Bool {
        viewModel.renamingTabId == tab.id
    }

    var body: some View {
        let shape = Capsule(style: .continuous)

        content
        .frame(height: TabBarView.Metrics.height)
        .frame(minWidth: showsTileOnly ? TabBarView.Metrics.tileTab : (widthIsLimit ? TabBarView.Metrics.minTab : (width ?? TabBarView.Metrics.minTab)),
               maxWidth: showsTileOnly ? TabBarView.Metrics.tileTab : (width ?? TabBarView.Metrics.maxTab),
               alignment: showsTileOnly ? .center : .leading)
        .fixedSize(horizontal: width == nil || widthIsLimit, vertical: false)
        // An inactive tab keeps no room for its close button: under the pointer the button
        // comes in over the end of the title, which fades out — the tab keeps its width.
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: showsCloseOnHover && isHovered ? 10 : 0)
                Color.clear
                    .frame(width: showsCloseOnHover && isHovered ? 24 : 0)
            }
        }
        .overlay(alignment: .trailing) {
            if showsCloseOnHover {
                closeButton
                    .opacity(isHovered ? 1 : 0)
                    .padding(.trailing, 6)
            }
        }
        .background {
            if isActive {
                // The same pill as the sidebar's selection; it slides from tab to tab.
                shape
                    .fill(Color.accentColor.opacity(0.24))
                    .background(Color.primary.opacity(0.08), in: shape)
                    .overlay(shape.strokeBorder(Color.accentColor.opacity(0.34), lineWidth: 1))
                    .matchedGeometryEffect(id: "activeTab", in: namespace)
            } else if isHovered {
                shape.fill(Color.primary.opacity(0.06))
            }
        }
        .overlay {
            if isDropTarget {
                shape.strokeBorder(.tint, lineWidth: 2)
            }
        }
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            startRenaming()
        }
        .simultaneousGesture(TapGesture(count: 1).onEnded { _ in onSelect() })
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                draftTitle = tab.title
                isRenameFocused = true
            }
        }
        .animation(DS.Motion.quick, value: isHovered)
        .help(tooltip)
        .contextMenu {
            TabMenuItems(tab: tab, status: status)
        }
        // Inside a toolbar item a right-click never reaches `.contextMenu` (the toolbar answers
        // it with "Icon and Text / Icon Only"): the same commands as an AppKit menu, plus middle-click close.
        .overlay { TabRightClickMenu(tab: tab, status: status) }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let uuidString = items.first,
                  let sourceId = UUID(uuidString: uuidString) else { return false }
            onDrop(sourceId)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shownTitle) tab")
        // The tile's dot is colour only.
        .accessibilityValue(Text(verbatim: Self.stateDescription(status: status, panes: tab.isSplit ? tab.panes.count : 1,
                                                                 isBroadcasting: tab.broadcastInput)))
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { onSelect() }
    }

    private func startRenaming() {
        draftTitle = tab.title
        viewModel.renamingTabId = tab.id
        isRenameFocused = true
    }

    private func commitRename() {
        viewModel.renameTab(tab.id, to: draftTitle)
        if viewModel.renamingTabId == tab.id {
            viewModel.renamingTabId = nil
        }
    }

    /// What the tile's dot and the marks of an inactive tab say, in words: the active tab shows
    /// neither the number of panes nor the broadcast mark (the panes are right under it).
    static func stateDescription(status: DSHostAvatar.Status, panes: Int, isBroadcasting: Bool) -> String {
        var parts: [String] = []
        if let state = status.stateText { parts.append(state) }
        if panes > 1 { parts.append(String(localized: "\(panes) panes")) }
        if isBroadcasting { parts.append(String(localized: "Broadcasting input")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var content: some View {
        if showsTileOnly {
            avatar
        } else {
            full
        }
    }

    private var full: some View {
        HStack(spacing: 7) {
            avatar

            if isRenaming {
                TextField("Tab Title", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($isRenameFocused)
                    .onSubmit { commitRename() }
                    .onKeyPress(.escape) {
                        viewModel.renamingTabId = nil
                        return .handled
                    }
                    .frame(minWidth: 56, maxWidth: 130)
            } else {
                Text(verbatim: shownTitle)
                    .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            // On the active tab neither says anything: its panes are on screen under it.
            if tab.isSplit, !isActive {
                Text(verbatim: "\(tab.panes.count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color.primary.opacity(0.14), in: Capsule())
                    .help("Split panes")
            }

            if tab.broadcastInput, !isActive {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.warning)
                    .help("Broadcasting input")
                    .accessibilityLabel(Text("Broadcasting input"))
            }

            if isActive {
                Spacer(minLength: 0)

                closeButton
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, isActive ? 6 : 10)
    }

    /// An inactive tab with its title shows the close button only under the pointer.
    private var showsCloseOnHover: Bool {
        !isActive && !showsTileOnly
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Color.primary.opacity(isHovered ? 0.1 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close Tab")
        .accessibilityLabel(Text("Close Tab"))
    }

    @ViewBuilder
    private var avatar: some View {
        if let host {
            DSHostAvatar(host, size: DS.Tile.sidebar, status: status)
        } else {
            DSHostAvatar.local(size: DS.Tile.sidebar, status: status)
        }
    }

    /// The whole title (a tab truncates it) and the tab's shortcut.
    private var tooltip: Text {
        if let shortcut {
            return Text(verbatim: "\(shownTitle) (\(shortcut))")
        }
        return Text(verbatim: shownTitle)
    }
}

private extension DSHostAvatar.Status {
    /// The state in words, for assistive technologies.
    var stateText: String? {
        switch self {
        case .none: return nil
        case .live: return String(localized: "Connected")
        case .busy: return String(localized: "Connecting…")
        case .needsInput: return String(localized: "Waiting for authentication input")
        case .unread: return String(localized: "Connected, new output")
        case .failed: return String(localized: "Failed")
        case .ended: return String(localized: "Disconnected")
        }
    }
}

// MARK: - Tab menu

/// What can be done with a tab: its context menu.
struct TabMenuItems: View {
    @Environment(AppViewModel.self) private var viewModel
    let tab: TerminalTab
    var status: DSHostAvatar.Status = .none

    var body: some View {
        if tab.isSSH && (status == .failed || status == .ended) {
            Button("Reconnect") { viewModel.reconnectTab(tab.id) }
            Divider()
        }
        Button("Rename Tab…") { viewModel.renamingTabId = tab.id }
        Button("Duplicate Tab") { viewModel.duplicateTab(tab.id) }
        Button("Split Right") {
            viewModel.activateTab(tab.id)
            viewModel.splitFocusedPane(.horizontal)
        }
        Button("Split Down") {
            viewModel.activateTab(tab.id)
            viewModel.splitFocusedPane(.vertical)
        }
        Divider()
        Button("Close Tab") { viewModel.confirmAndCloseTab(tab.id) }
        Button("Close Other Tabs") { viewModel.confirmAndCloseOtherTabs(tab.id) }
        Button("Close Tabs to the Right") { viewModel.confirmAndCloseTabsToRight(tab.id) }
        Divider()
        Button("Close All Tabs", role: .destructive) { viewModel.confirmAndCloseAllTabs() }
    }
}

/// Opens `TabMenuItems`' commands on a right-click (or control-click) on a session tab in the
/// toolbar, and closes the tab on a middle-click. Every other event passes through to the tab below.
struct TabRightClickMenu: NSViewRepresentable {
    @Environment(AppViewModel.self) private var viewModel
    let tab: TerminalTab
    var status: DSHostAvatar.Status = .none

    func makeNSView(context: Context) -> TabRightClickView {
        let view = TabRightClickView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: TabRightClickView, context: Context) {
        update(nsView)
    }

    private func update(_ view: TabRightClickView) {
        let viewModel = viewModel
        let id = tab.id
        var items: [TabRightClickView.Entry?] = []
        if tab.isSSH && (status == .failed || status == .ended) {
            items.append(TabRightClickView.Entry(String(localized: "Reconnect")) { viewModel.reconnectTab(id) })
            items.append(nil)
        }
        items.append(contentsOf: [
            TabRightClickView.Entry(String(localized: "Rename Tab…")) { viewModel.renamingTabId = id },
            TabRightClickView.Entry(String(localized: "Duplicate Tab")) { viewModel.duplicateTab(id) },
            TabRightClickView.Entry(String(localized: "Split Right")) {
                viewModel.activateTab(id)
                viewModel.splitFocusedPane(.horizontal)
            },
            TabRightClickView.Entry(String(localized: "Split Down")) {
                viewModel.activateTab(id)
                viewModel.splitFocusedPane(.vertical)
            },
            nil,
            TabRightClickView.Entry(String(localized: "Close Tab")) { viewModel.confirmAndCloseTab(id) },
            TabRightClickView.Entry(String(localized: "Close Other Tabs")) { viewModel.confirmAndCloseOtherTabs(id) },
            TabRightClickView.Entry(String(localized: "Close Tabs to the Right")) { viewModel.confirmAndCloseTabsToRight(id) },
            nil,
            TabRightClickView.Entry(String(localized: "Close All Tabs")) { viewModel.confirmAndCloseAllTabs() }
        ])
        view.entries = items
        view.onMiddleClick = { viewModel.confirmAndCloseTab(id) }
    }
}

final class TabRightClickView: NSView {
    struct Entry {
        let title: String
        let run: @MainActor () -> Void

        init(_ title: String, run: @escaping @MainActor () -> Void) {
            self.title = title
            self.run = run
        }
    }

    /// The menu's commands in order; nil is a separator.
    var entries: [Entry?] = []
    var onMiddleClick: (@MainActor () -> Void)?

    private var monitor: Any?

    /// The view itself takes no events: clicks, drags and the pointer go to the tab below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The toolbar takes a right-click before any view in it is asked, so the click is
    /// picked up on its way in: over this tab it opens the tab's menu instead.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .otherMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .otherMouseUp, event.buttonNumber == 2, self.isPointInside(event) {
                self.onMiddleClick?()
                return nil
            }
            guard self.opensMenu(event), let menu = self.menu(for: event) else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil
        }
    }

    private func isPointInside(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    private func opensMenu(_ event: NSEvent) -> Bool {
        let asksForMenu = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
        guard asksForMenu else { return false }
        return isPointInside(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (index, entry) in entries.enumerated() {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(runEntry(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runEntry(_ sender: NSMenuItem) {
        guard entries.indices.contains(sender.tag), let entry = entries[sender.tag] else { return }
        entry.run()
    }
}

// MARK: - Recent hosts

/// Toolbar menu next to the tabs: the hosts connected to last; picking one opens a session.
struct RecentHostsMenu: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        let hosts = AppViewModel.recentHosts(viewModel.hostsPage.hosts, limit: 8)

        Menu {
            Section("Recent Hosts") {
                if hosts.isEmpty {
                    Text("No recent hosts")
                }
                ForEach(hosts, id: \.connectionKey) { host in
                    Button {
                        viewModel.connect(to: host)
                    } label: {
                        Label {
                            Text(verbatim: host.displayName)
                        } icon: {
                            Self.menuImage(for: host.tileContent)
                        }
                    }
                }
            }
        } label: {
            Label("Recent Hosts", systemImage: "clock")
        }
        .help("Recent Hosts")
    }

    /// A menu shows a plain image, not a tile: the system's mark, or the generic server glyph.
    static func menuImage(for content: DSIconTile.Content) -> Image {
        switch content {
        case .symbol(let name): return Image(systemName: name)
        case .asset(let name): return Image(name)
        case .monogram: return Image(systemName: "server.rack")
        }
    }
}
