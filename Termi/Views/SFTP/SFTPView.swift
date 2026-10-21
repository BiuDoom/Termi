import SwiftUI
import AppKit

/// SFTP dual-pane file browser (state lives in the window's AppViewModel).
struct SFTPView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var hostSearch = ""
    private var viewModel: SFTPViewModel { appViewModel.sftp }

    var body: some View {
        // The page's height decides how the transfer bar starts out: in a short window (the
        // minimum size leaves the page 600 pt) it is folded to one line, so the file lists
        // keep their room.
        GeometryReader { proxy in
            page(isShort: proxy.size.height < 640)
        }
        .dsStageBackground()
        .animation(DS.Motion.standard, value: viewModel.notice)
        .animation(DS.Motion.standard, value: viewModel.editItems.isEmpty)
        .animation(DS.Motion.standard, value: viewModel.transfers.isEmpty)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .background { SFTPUploadConflictPrompt(viewModel: viewModel, conflict: viewModel.uploadConflict) }
        .task {
            await appViewModel.ensureHostsLoaded()
            await viewModel.loadHosts()
            viewModel.loadLocalDirectory()
            #if DEBUG
            await viewModel.applyDebugLaunchArguments()
            #endif
        }
        // A host's system is read after it connects, and changes its tile.
        .onReceive(NotificationCenter.default.publisher(for: .dsDataChanged)) { _ in
            Task { await viewModel.loadHosts() }
        }
    }

    @State private var swapEndpoints = false

    private func page(isShort: Bool) -> some View {
        VStack(spacing: DS.Space.md) {
            FilePanelSplit {
                if swapEndpoints {
                    remoteEndpointPane
                } else {
                    LocalFilePanelView(viewModel: viewModel)
                }
            } trailing: {
                if swapEndpoints {
                    LocalFilePanelView(viewModel: viewModel)
                } else {
                    remoteEndpointPane
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.xxs)

            // Shown without a connection too: a copy may be waiting for a reconnect to upload
            // its changes.
            if !viewModel.editItems.isEmpty {
                EditItemsBar(viewModel: viewModel)
                    .padding(.horizontal, DS.Space.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if viewModel.isConnected, !viewModel.transfers.isEmpty {
                TransferQueueView(viewModel: viewModel, isShort: isShort)
                    .padding(.horizontal, DS.Space.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let notice = viewModel.notice {
                NoticeBar(notice: notice) {
                    viewModel.revealNoticeFiles()
                } onClose: {
                    viewModel.notice = nil
                }
                .padding(.horizontal, DS.Space.lg)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, DS.Space.lg)
    }

    private var hasBottomBar: Bool {
        !viewModel.editItems.isEmpty || viewModel.notice != nil
    }

    private var subtitle: Text {
        Text(verbatim: "")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var model = viewModel
        ToolbarItemGroup {
            Toggle(isOn: $model.showsHiddenFiles) {
                Label("Show Hidden Files", systemImage: "eye")
            }
            .help("Show Hidden Files")

            Button {
                withAnimation(DS.Motion.standard) {
                    swapEndpoints.toggle()
                }
            } label: {
                Label("Swap Panes", systemImage: "arrow.left.arrow.right")
            }
            .help("Swap Local and Remote panes")

            if viewModel.isConnected, let host = viewModel.selectedHost {
                Button {
                    appViewModel.connect(to: host)
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .help("Open a terminal on this host")
            }
        }

        if viewModel.isConnected {
            ToolbarItem {
                Button {
                    viewModel.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "eject")
                }
                .disabled(viewModel.hasActiveTransfers)
                .help(viewModel.hasActiveTransfers ? "Wait for transfers to finish" : "Close the SFTP session")
            }
        }
    }

    // MARK: - Remote endpoint pane (Connected browser OR In-Pane Host Picker)

    @ViewBuilder
    private var remoteEndpointPane: some View {
        if viewModel.isConnected {
            RemoteFilePanelView(viewModel: viewModel)
        } else {
            inPaneHostSelector
        }
    }

    private var filteredHosts: [Host] {
        guard !hostSearch.isEmpty else { return viewModel.hosts }
        let query = hostSearch.lowercased()
        return viewModel.hosts.filter {
            $0.label.lowercased().contains(query) || $0.hostname.lowercased().contains(query)
        }
    }

    private var inPaneHostSelector: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Select Remote Host")
                    .font(DS.Font.rowTitle)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.sm)
                if !viewModel.hosts.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField("Filter hosts…", text: $hostSearch)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(width: 140)
                        if !hostSearch.isEmpty {
                            Button {
                                hostSearch = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DS.Palette.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.horizontal, DS.Space.md)
            .frame(height: 42)

            Divider()

            Group {
                if viewModel.hosts.isEmpty {
                    if viewModel.isConnecting || viewModel.connectionError != nil || !viewModel.hostsLoaded {
                        Color.clear
                    } else {
                        DevOpsNoHostsView(error: viewModel.hostsError, onRetry: { Task { await viewModel.loadHosts() } })
                    }
                } else {
                    SFTPHostPicker(hosts: filteredHosts, isSearching: !hostSearch.isEmpty,
                                   isDisabled: viewModel.isConnecting) { host in
                        Task { await viewModel.connect(to: host) }
                    }
                    .overlay {
                        if filteredHosts.isEmpty {
                            ContentUnavailableView.search(text: hostSearch)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { connectionCard }
            .animation(DS.Motion.quick, value: viewModel.isConnecting)
            .animation(DS.Motion.quick, value: viewModel.connectionError)
        }
        .dsCard()
    }

    /// The same card a terminal pane shows: the host's tile, the route (through a jump host),
    /// what to do — here with the address, which this page says nowhere else until it connects.
    @ViewBuilder
    private var connectionCard: some View {
        if viewModel.isConnecting, let host = viewModel.selectedHost {
            // Over a master connection that is already open this takes a moment: no flash.
            DSDelayed {
                SessionStateCard(avatar: DSHostAvatar(host, size: DS.Tile.header, status: .busy),
                                 title: Text("Connecting to \(host.displayName)"),
                                 subtitle: host.addressDescription) {
                    if let hops = appViewModel.jumpRouteHops(to: host, status: .busy) {
                        DSRouteDiagram(hops: hops, activity: .flowing, reachedHops: 1)
                            .frame(maxWidth: .infinity)
                    }
                    // The same line as a terminal pane's card; there is nothing to cancel here.
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Sign-in: \(host.authTitle)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } actions: {
                    EmptyView()
                }
            }
        } else if let error = viewModel.connectionError {
            let host = viewModel.failedHost
            SessionStateCard(avatar: host.map { DSHostAvatar($0, size: DS.Tile.header, status: .failed) }
                                ?? DSHostAvatar(os: .unknown, size: DS.Tile.header, status: .failed),
                             title: Text("Connection Failed"), subtitle: host?.addressDescription,
                             compactNote: error) {
                if let host, let hops = appViewModel.jumpRouteHops(to: host, status: .failed) {
                    DSRouteDiagram(hops: hops, activity: .failed)
                        .frame(maxWidth: .infinity)
                }
                DSMessage(verbatim: error)
                    .multilineTextAlignment(.leading)
            } actions: {
                if let host {
                    // No Return shortcut: the search field is next to it, and Return there
                    // must not start a connection.
                    Button("Retry") {
                        Task { await viewModel.connect(to: host) }
                    }
                    .dsButtonStyle(.prominent)
                }
                Button("Close") { viewModel.dismissConnectionError() }
                    .dsButtonStyle(.glass)
            }
        }
    }
}

/// Decisions belong to the explicit buttons (including Escape's cancel action). SwiftUI can
/// dismiss presentation before invoking a button, so its binding setter must not cancel a
/// transfer. Session/window teardown cancels pending questions through `disconnect()`.
private struct SFTPUploadConflictPrompt: View {
    let viewModel: SFTPViewModel
    let conflict: SFTPUploadConflict?
    /// "Do the same for the other files of this upload", for the question shown.
    @State private var applyToAll = false

    var body: some View {
        // The toggle belongs to the dialogs presented within the view it is applied to: only an
        // upload with other files gets it.
        if conflict?.offersApplyToAll == true {
            prompt.dialogSuppressionToggle("Do the same for the other files of this upload", isSuppressed: $applyToAll)
        } else {
            prompt
        }
    }

    private var prompt: some View {
        Color.clear.frame(width: 0, height: 0)
            .alert(title, isPresented: Binding(
                get: { conflict != nil },
                set: { _ in }
            ), presenting: conflict) { question in
                switch question.kind {
                case .nameTaken:
                    Button("Replace", role: .destructive) { resolve(question, .replace) }
                    Button("Skip") { resolve(question, .skip) }
                    Button("Cancel Upload", role: .cancel) { resolve(question, .cancel) }
                case .unsafeReplace:
                    Button("Overwrite in Place", role: .destructive) { resolve(question, .replace) }
                    Button("Don't Overwrite", role: .cancel) { resolve(question, .skip) }
                }
            } message: { question in
                Text(verbatim: Self.message(for: question))
            }
            .onChange(of: conflict?.id) { _, _ in applyToAll = false }
    }

    private var title: Text {
        if case .unsafeReplace = conflict?.kind { return Text("Overwrite in Place?") }
        return Text("Replace Remote File?")
    }

    private func resolve(_ question: SFTPUploadConflict, _ decision: SFTPUploadDecision) {
        viewModel.resolveUploadConflict(question.id, decision: decision,
                                        applyToAll: question.offersApplyToAll && applyToAll)
    }

    /// What is asked, with what each side has: the size and date of the file on the server and
    /// of the one on this Mac.
    static func message(for question: SFTPUploadConflict) -> String {
        let name = SFTPClient.name(of: question.path)
        switch question.kind {
        case .nameTaken(let existing, let local):
            var lines = [String(localized: "“\(name)” already exists. Replace it with the file from this Mac? The file on the server is replaced only once the new one has been uploaded completely.")]
            lines.append(String(localized: "On the server: \(describe(size: existing.size.map { Int64(clamping: $0) }, modified: existing.modificationDate))"))
            let values = try? local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            lines.append(String(localized: "On this Mac: \(describe(size: values?.fileSize.map(Int64.init), modified: values?.contentModificationDate))"))
            return lines.joined(separator: "\n")
        case .unsafeReplace(let reason):
            return String(localized: "“\(name)” cannot be replaced safely: \(reason.explanation). Overwrite it in place? If the transfer is interrupted, the previous contents of the file are lost.")
        }
    }

    private static func describe(size: Int64?, modified: Date?) -> String {
        var parts: [String] = []
        if let size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let modified { parts.append(modified.formatted(date: .abbreviated, time: .shortened)) }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }
}

// MARK: - Host picker

/// Not connected: the hosts to browse. Those with an open session come first — the browser
/// rides on their connection, no sign-in — then the others by group.
struct SFTPHostPicker: View {
    @Environment(AppViewModel.self) private var appViewModel
    let hosts: [Host]
    /// The list is a search's matches: only then does a section say how many it has.
    let isSearching: Bool
    let isDisabled: Bool
    let onPick: (Host) -> Void

    @State private var columns = 3
    @State private var width: CGFloat = 900
    private static let spacing: CGFloat = DS.Space.card

    private var liveIds: Set<Int64> { appViewModel.connectedHostIds }

    private var liveHosts: [Host] {
        hosts.filter { host in host.id.map { liveIds.contains($0) } ?? false }
    }

    /// The hosts without a session, by group (the hosts page's order); those of no group last.
    private var sections: [(title: Text, hosts: [Host])] {
        let rest = hosts.filter { host in !(host.id.map { liveIds.contains($0) } ?? false) }
        let groups = appViewModel.hostsPage.allGroups
        var result: [(title: Text, hosts: [Host])] = []
        for group in groups {
            let members = rest.filter { $0.groupId == group.id }
            if !members.isEmpty { result.append((Text(verbatim: group.name), members)) }
        }
        let ungrouped = rest.filter { host in host.groupId == nil || !groups.contains { $0.id == host.groupId } }
        if !ungrouped.isEmpty {
            result.append((result.isEmpty ? Text("Hosts") : Text("Ungrouped"), ungrouped))
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let live = liveHosts
                let groups = sections
                // A lone section's title says nothing ("Hosts" over the hosts) — until it
                // carries the number of a search's matches.
                let showsTitles = Self.showsSectionTitles(hasLive: !live.isEmpty, groupCount: groups.count,
                                                          isSearching: isSearching)
                if !live.isEmpty {
                    sectionTitle(Text("Connected"), count: live.count)
                    liveCards(live)
                }
                // One answer for every grid of the page, so the cards' right-hand columns read alike.
                let showsTitle = Self.lastConnectedTitleFits(hosts: groups.flatMap(\.hosts), columnWidth: columnWidth)
                ForEach(Array(groups.enumerated()), id: \.offset) { index, section in
                    if showsTitles {
                        sectionTitle(section.title, count: section.hosts.count)
                            .padding(.top, index == 0 && live.isEmpty ? 0 : DS.Space.xl)
                    }
                    LazyVGrid(columns: gridColumns, spacing: Self.spacing) {
                        ForEach(section.hosts, id: \.connectionKey) { host in
                            card(host, showsLastConnectedTitle: showsTitle)
                        }
                    }
                }
            }
            .padding(.horizontal, width < 560 ? DS.Space.md : DS.Space.page)
            .padding(.top, DS.Space.md)
            .padding(.bottom, DS.Space.xl)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: {
            width = $0
            columns = $0 >= 860 ? 3 : ($0 >= 560 ? 2 : 1)
        }
        .disabled(isDisabled)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns)
    }

    /// Titles tell sections apart: with the hosts that have a session up front, or with more
    /// than one group. A search's matches are counted on the title, so a lone section has one
    /// while searching: the count would otherwise be nowhere.
    nonisolated static func showsSectionTitles(hasLive: Bool, groupCount: Int, isSearching: Bool) -> Bool {
        hasLive || groupCount >= 2 || (isSearching && groupCount >= 1)
    }

    /// The count only for a search's matches: otherwise it is the number of cards underneath.
    private func sectionTitle(_ title: Text, count: Int) -> some View {
        HStack(spacing: 6) {
            title
                .accessibilityAddTraits(.isHeader)
            if isSearching {
                Text(verbatim: count.formatted())
                    .monospacedDigit()
                    .fontWeight(.medium)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(DS.Font.label)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, DS.Space.xs)
        .padding(.bottom, DS.Space.sm)
    }

    // MARK: Hosts with a session

    /// The first one is the page's lead (two columns wide next to a second one), with the one
    /// primary action; the others are plain cards in the same grid.
    @ViewBuilder
    private func liveCards(_ live: [Host]) -> some View {
        let others = Array(live.dropFirst())
        let beside = columns == 3 ? others.first : nil
        let below = beside == nil ? others : Array(others.dropFirst())
        VStack(spacing: Self.spacing) {
            HStack(spacing: Self.spacing) {
                liveCard(live[0], isLead: true)
                if let beside {
                    liveCard(beside, isLead: false)
                        .frame(width: columnWidth)
                }
            }
            if !below.isEmpty {
                LazyVGrid(columns: gridColumns, spacing: Self.spacing) {
                    ForEach(below, id: \.connectionKey) { host in
                        liveCard(host, isLead: false)
                    }
                }
            }
        }
    }

    /// One column of the grid below.
    private var columnWidth: CGFloat {
        max(0, (width - 2 * DS.Space.page - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns))
    }

    private func liveCard(_ host: Host, isLead: Bool) -> some View {
        let sessions = appViewModel.tabs.flatMap(\.panes).filter {
            $0.hostId == host.id && appViewModel.existingSession(for: $0.id)?.isLive == true
        }.count
        return Button {
            onPick(host)
        } label: {
            HStack(spacing: DS.Space.lg) {
                DSHostAvatar(host, size: isLead ? 56 : 44, status: .live)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: host.displayName)
                        .font(.system(size: 20, weight: .bold))
                    Text(verbatim: host.addressDescription)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        DSStatusPill("Uses the open connection", tone: .success, showsBackground: false)
                            .layoutPriority(1)
                        Text(verbatim: "· " + Self.facts(sessions: sessions, system: isLead ? host.system?.name : nil))
                            .font(DS.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
                .lineLimit(1)
                Spacer(minLength: DS.Space.sm)
                if isLead {
                    // Not a button of its own: the whole card opens the host.
                    Label("Browse Files", systemImage: "folder")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, DS.Space.lg + 2)
                        .frame(height: 36)
                        .dsGlass(.capsule, tint: .accentColor, isInteractive: true)
                        .fixedSize()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, DS.Space.xl)
            .frame(height: 116)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard(isInteractive: true, hero: isLead ? Color.accentColor : nil)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Browse Files"))
    }

    /// "2 sessions · Ubuntu 24.04.1 LTS".
    nonisolated static func facts(sessions: Int, system: String?) -> String {
        var parts = [String(localized: "\(sessions) sessions")]
        if let system, !system.isEmpty { parts.append(system) }
        return parts.joined(separator: " · ")
    }

    // MARK: Other hosts

    /// Whether every card of the grid has room for "Last connected" before its time, next to
    /// the whole of its name and address. Measured, not a fixed width: the words are half as
    /// long in Chinese as in English, and an address with a port is longer than one without.
    static func lastConnectedTitleFits(hosts: [Host], columnWidth: CGFloat) -> Bool {
        let caption = NSFont.systemFont(ofSize: 11)
        let title = textWidth(String(localized: "Last connected"), caption)
        // Card padding, tile, the gaps on both sides of the name, the gap after the title, and
        // a little slack: the time is drawn by `DSRelativeTime`, whose wording may differ by a glyph.
        let chrome: CGFloat = 2 * (DS.Space.md + 2) + 36 + DS.Space.md + DS.Space.sm + 3 + 4
        let room = columnWidth - chrome - title
        for host in hosts {
            // "Never connected" stands alone.
            guard let date = host.lastConnectedDate else { continue }
            let name = textWidth(host.displayName, NSFont.systemFont(ofSize: 13, weight: .semibold))
            let address = textWidth(host.addressDescription, NSFont.monospacedSystemFont(ofSize: 11, weight: .regular))
            let time = textWidth(date.formatted(.relative(presentation: .named)), caption)
            if max(name, address) + time > room { return false }
        }
        return true
    }

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    private func card(_ host: Host, showsLastConnectedTitle: Bool) -> some View {
        Button {
            onPick(host)
        } label: {
            // No stack spacing: the gaps of `lastConnectedTitleFits` are the ones written here.
            HStack(spacing: 0) {
                DSHostAvatar(host, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: host.displayName)
                        .font(DS.Font.rowTitle)
                    Text(verbatim: host.addressDescription)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                .padding(.leading, DS.Space.md)
                // The address comes first: in a grid whose cards are too narrow for both, the
                // times lose their "Last connected" before an address loses its middle.
                .layoutPriority(1)
                Spacer(minLength: DS.Space.sm)
                Group {
                    if let date = host.lastConnectedDate {
                        HStack(spacing: 3) {
                            if showsLastConnectedTitle {
                                Text("Last connected")
                            }
                            DSRelativeTime(date)
                        }
                        .fixedSize()
                        // Says the title also where it is not drawn.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Last connected"))
                        .accessibilityValue(Text(verbatim: date.formatted(.relative(presentation: .named))))
                    } else {
                        Text("Never connected")
                            .fixedSize()
                    }
                }
                .font(DS.Font.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            .padding(.horizontal, DS.Space.md + 2)
            .frame(height: 66)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard(isInteractive: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Panel split

/// The local and the remote panel side by side: equal halves until the divider is dragged.
/// (`HSplitView` keeps its panes at their ideal width, which made the page wider than a
/// window at its minimum size.)
private struct FilePanelSplit<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    /// Share of the width taken by the leading panel.
    @State private var fraction: CGFloat = 0.5
    @State private var dragStartFraction: CGFloat?

    /// Narrow enough for both panels to fit the window at its minimum width; the file
    /// lists drop columns as they shrink (`FileColumnVisibility`).
    private static var minimumPanelWidth: CGFloat { 220 }
    /// The gap between the two cards; the divider that is dragged is the gap itself.
    private static var dividerThickness: CGFloat { DS.Space.md }

    var body: some View {
        GeometryReader { proxy in
            let available = max(0, proxy.size.width - Self.dividerThickness)
            let minimum = min(Self.minimumPanelWidth, available / 2)
            let leadingWidth = min(max(available * fraction, minimum), available - minimum)

            HStack(spacing: 0) {
                leading
                    .frame(width: leadingWidth)
                divider(available: available)
                trailing
                    .frame(width: available - leadingWidth)
            }
        }
        .frame(minWidth: Self.minimumPanelWidth * 2 + Self.dividerThickness)
    }

    private func divider(available: CGFloat) -> some View {
        Color.clear
            .frame(width: Self.dividerThickness)
            .overlay {
                Color.clear
                    .frame(width: Self.dividerThickness)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                guard available > 0 else { return }
                                let start = dragStartFraction ?? fraction
                                dragStartFraction = start
                                let minimum = min(Self.minimumPanelWidth, available / 2) / available
                                fraction = min(max(start + value.translation.width / available, minimum), 1 - minimum)
                            }
                            .onEnded { _ in dragStartFraction = nil }
                    )
                    // Double-click evens the panels out again.
                    .onTapGesture(count: 2) {
                        withAnimation(DS.Motion.standard) { fraction = 0.5 }
                    }
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

// MARK: - Transfer queue

/// The floating bar under the panels: each transfer, and — once there is more to add up than
/// the rows in view say themselves — how far the running ones are together. Folded, it is one line.
struct TransferQueueView: View {
    let viewModel: SFTPViewModel
    /// A short window starts folded.
    var isShort = false
    /// Nil until the disclosure is clicked: until then the window's height decides.
    @State private var userExpanded: Bool?

    private var isExpanded: Bool { userExpanded ?? !isShort }

    /// With the summary: room for a running and a finished transfer; more scroll.
    private static let expandedHeight: CGFloat = 112
    /// Rows in view without scrolling.
    nonisolated static let visibleRows = 2
    /// Folding never makes the bar higher: one line is as high as the lowest unfolded bar, the
    /// one with a single finished row (it was 44 pt against that bar's 38).
    nonisolated static let foldedHeight: CGFloat = TransferRow.finishedHeight

    /// The block with the total: only when it adds up something. With one transfer running it
    /// is that row's own number, and with every row in view the counts are the rows.
    nonisolated static func showsSummary(running: Int, rows: Int) -> Bool {
        running >= 2 || rows > visibleRows
    }

    /// The bar's height without the summary: as high as its rows.
    nonisolated static func rowsHeight(running: Int, finished: Int) -> CGFloat {
        CGFloat(running) * TransferRow.runningHeight + CGFloat(finished) * TransferRow.finishedHeight
    }

    /// Running first (the newest on top), then the finished ones.
    private var ordered: [TransferItem] {
        let newestFirst = Array(viewModel.transfers.reversed())
        return newestFirst.filter { $0.state == .running } + newestFirst.filter { $0.state != .running }
    }

    var body: some View {
        // The speed is bytes over time: drawn again every second while something runs — and
        // only then (finished transfers stay in the bar until they are cleared).
        if viewModel.transfers.contains(where: { $0.state == .running }) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                bar
            }
        } else {
            bar
        }
    }

    @ViewBuilder
    private var bar: some View {
        let summary = TransferSummary(viewModel.transfers)
        if isExpanded {
            expanded(summary)
        } else {
            folded(summary)
        }
    }

    @ViewBuilder
    private func expanded(_ summary: TransferSummary) -> some View {
        let rows = ordered
        let firstFinished = rows.first { $0.state != .running }?.id
        let showsSummary = Self.showsSummary(running: summary.running, rows: rows.count)
        let height = showsSummary ? Self.expandedHeight
            : Self.rowsHeight(running: summary.running, finished: summary.finished)
        // A bar of one finished row is lower than twice the usual corner.
        let corner = min(24, height / 2)
        HStack(alignment: .top, spacing: 0) {
            if showsSummary {
                VStack(alignment: .leading, spacing: 2) {
                    disclosure
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: Self.percentText(summary))
                            .font(DS.Font.gauge)
                            .contentTransition(.numericText())
                        if summary.fraction != nil {
                            Text(verbatim: "%")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(verbatim: Self.countsText(summary))
                        .font(DS.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, DS.Space.xl + 2)
                .frame(width: 176, alignment: .leading)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) { Divider() }
            } else {
                // Beside the first row, which it folds away with the others.
                disclosure
                    .fixedSize()
                    .padding(.leading, DS.Space.xl)
                    .frame(height: rows.first?.state == .running ? TransferRow.runningHeight
                           : TransferRow.finishedHeight)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, transfer in
                        TransferRow(transfer: transfer, showsClear: transfer.id == firstFinished) {
                            viewModel.cancelTransfer(transfer.id)
                        } onClear: {
                            viewModel.clearFinishedTransfers()
                        }
                        .overlay(alignment: .top) {
                            if index > 0 { Divider() }
                        }
                    }
                }
                .padding(.leading, DS.Space.lg)
                .padding(.trailing, DS.Space.card)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .dsFloatingBar(.rect(corner))
        .animation(DS.Motion.standard, value: height)
    }

    private func folded(_ summary: TransferSummary) -> some View {
        HStack(spacing: DS.Space.md) {
            disclosure
            Text(verbatim: Self.countsText(summary))
                .font(DS.Font.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let fraction = summary.fraction {
                DSMeter(percent: fraction * 100)
                    .frame(maxWidth: .infinity)
                Text(verbatim: Self.percentText(summary) + "%")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                if summary.speed > 0 {
                    Text(verbatim: Self.speedText(summary.speed))
                        .font(DS.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Spacer(minLength: 0)
            }
            Button("Clear Finished") { viewModel.clearFinishedTransfers() }
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .medium))
                .disabled(summary.finished == 0)
        }
        .lineLimit(1)
        .padding(.horizontal, DS.Space.lg + 2)
        .frame(height: Self.foldedHeight)
        .dsFloatingBar()
    }

    private var disclosure: some View {
        Button {
            withAnimation(DS.Motion.standard) { userExpanded = !isExpanded }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Transfers")
                    .font(DS.Font.label)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Show the transfers as one line" : "Show every transfer")
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
    }

    /// "62", or "—" while nothing runs or no size is known.
    nonisolated static func percentText(_ summary: TransferSummary) -> String {
        guard let fraction = summary.fraction else { return "—" }
        return String(Int((fraction * 100).rounded(.down)))
    }

    /// "1 in progress · 1 finished".
    nonisolated static func countsText(_ summary: TransferSummary) -> String {
        var parts: [String] = []
        if summary.running > 0 { parts.append(String(localized: "\(summary.running) in progress")) }
        if summary.finished > 0 { parts.append(String(localized: "\(summary.finished) finished")) }
        return parts.joined(separator: " · ")
    }

    nonisolated static func speedText(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}

struct TransferRow: View {
    nonisolated static let runningHeight: CGFloat = 50
    nonisolated static let finishedHeight: CGFloat = 38

    let transfer: TransferItem
    /// The first finished row carries "Clear Finished".
    let showsClear: Bool
    let onCancel: () -> Void
    let onClear: () -> Void

    private var isRunning: Bool { transfer.state == .running }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: transfer.direction == .upload ? "arrow.up" : "arrow.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isRunning ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 28)
                .background(isRunning ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(DS.Palette.chip),
                            in: Circle())
                .accessibilityLabel(transfer.direction == .upload ? Text("Upload") : Text("Download"))

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: transfer.name)
                    .font(DS.Font.rowTitle)
                    .truncationMode(.middle)
                if isRunning, !transfer.destination.isEmpty {
                    destination
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
            }
            .lineLimit(1)
            // Gives way before the numbers do.
            .frame(minWidth: 80, idealWidth: 200, maxWidth: 200, alignment: .leading)

            if isRunning {
                VStack(spacing: 6) {
                    DSMeter(percent: transfer.fraction * 100, height: 8)
                    HStack(spacing: 6) {
                        Text(verbatim: amountText)
                            .fontWeight(.semibold)
                            .layoutPriority(1)
                        if transfer.speed > 0 {
                            Text(verbatim: "·")
                                .foregroundStyle(.tertiary)
                            Text(verbatim: TransferQueueView.speedText(transfer.speed))
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        Spacer(minLength: DS.Space.xs)
                        if transfer.awaitingDecision {
                            Text("Waiting for your decision")
                                .foregroundStyle(DS.Palette.warning.mix(with: .primary, by: 0.45))
                        } else if let seconds = transfer.secondsLeft {
                            Text("\(Self.durationText(seconds)) left")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(DS.Font.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                }
                DSRowButton("xmark", help: "Cancel", action: onCancel)
            } else {
                Text(verbatim: finishedDetail)
                    .font(DS.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Space.xs)
                result
                    .help(statusHelp)
                if showsClear {
                    Button("Clear Finished", action: onClear)
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize()
                }
            }
        }
        .frame(height: isRunning ? Self.runningHeight : Self.finishedHeight)
        .animation(DS.Motion.quick, value: transfer.state)
    }

    private var destination: Text {
        transfer.direction == .upload ? Text("Upload to \(transfer.destination)")
            : Text("Download to \(transfer.destination)")
    }

    /// "130.2 / 209.7 MB".
    private var amountText: String {
        let done = ByteCountFormatter.string(fromByteCount: transfer.transferredBytes, countStyle: .file)
        guard transfer.totalBytes > 0 else { return done }
        return done + " / " + ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file)
    }

    /// Where it went, how much, when.
    private var finishedDetail: String {
        var parts: [String] = []
        if !transfer.destination.isEmpty {
            parts.append(transfer.direction == .upload
                ? String(localized: "Upload to \(transfer.destination)")
                : String(localized: "Download to \(transfer.destination)"))
        }
        if transfer.state == .completed {
            parts.append(ByteCountFormatter.string(fromByteCount: transfer.transferredBytes, countStyle: .file))
        }
        if let finishedAt = transfer.finishedAt {
            parts.append(finishedAt.formatted(date: .omitted, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    /// The outcome in a glyph and a word; colour only for what went wrong.
    @ViewBuilder
    private var result: some View {
        switch transfer.state {
        case .running:
            EmptyView()
        case .completed:
            if transfer.skipped.count > 0 {
                outcome("exclamationmark.triangle.fill", DS.Palette.warning,
                        Text("Done · \(transfer.skipped.count) skipped"))
            } else if transfer.kept.count > 0 {
                // What the user chose to keep is no warning.
                outcome("checkmark.circle", Color.secondary,
                        Text("Done · kept \(transfer.kept.count) on the server"))
            } else {
                outcome("checkmark.circle", DS.Palette.success, Text("Done"))
            }
        case .cancelled:
            outcome("slash.circle", Color.secondary, Text("Cancelled"))
        case .failed(let message):
            outcome("xmark.octagon.fill", DS.Palette.danger, Text(verbatim: message))
        }
    }

    private func outcome(_ symbol: String, _ color: Color, _ text: Text) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            text
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(DS.Font.caption)
    }

    /// On hovering the result: a failure in full (the row has one line for it), or what a
    /// completed transfer left out (the first few names).
    private var statusHelp: String {
        if case .failed(let message) = transfer.state { return message }
        guard transfer.state == .completed else { return "" }
        var lines: [String] = []
        if transfer.kept.count > 0 {
            lines.append(String(localized: "Kept the file already on the server: \(Self.names(transfer.kept))"))
        }
        if transfer.skipped.count > 0 {
            lines.append(String(localized: "Left out (links that are not followed, links, folders or special files in the way on the server, pipes, devices and sockets, or names that are one name on this Mac): \(Self.names(transfer.skipped))"))
        }
        return lines.joined(separator: "\n")
    }

    private static func names(_ items: SFTPSkippedItems) -> String {
        var names = items.examples.joined(separator: ", ")
        if items.count > items.examples.count { names += "…" }
        return names
    }

    /// "6 sec", "2 min": one unit is as exact as a guess from the speed so far gets.
    nonisolated static func durationText(_ seconds: Double) -> String {
        Duration.seconds(max(1, seconds.rounded(.up)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
    }
}

// MARK: - Remote editing bar

struct EditItemsBar: View {
    let viewModel: SFTPViewModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.editItems) { item in
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: item.uploadFailed ? "exclamationmark.circle.fill" : "pencil.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(item.uploadFailed ? DS.Palette.danger : Color.accentColor)
                    // The folder next to the name: two files of one name, from two folders, are
                    // otherwise the same row twice, and "Stop Editing" a guess.
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Text(verbatim: item.remoteName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        Text(verbatim: item.remoteFolder)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            // Gives way before the status does; the tooltip has the whole path.
                            .layoutPriority(-1)
                    }
                    .help(Text(verbatim: item.remotePath))
                    Text(verbatim: item.status)
                        .font(.caption)
                        .foregroundStyle(item.uploadFailed
                            ? DS.Palette.danger.mix(with: .primary, by: 0.45)
                            : Color.secondary)
                        .lineLimit(1)
                        .help(Text(verbatim: item.status))
                    Spacer()
                    Button("Open") { viewModel.openForEditing(item.localURL) }
                        .buttonStyle(.link)
                        .font(.callout)
                    Button("Stop Editing") { viewModel.stopEditing(item.id) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                .padding(.horizontal, DS.Space.md + 2)
                .padding(.vertical, DS.Space.sm)
            }
        }
        .dsCard(cornerRadius: DS.Radius.row)
    }
}

/// The page's notice (`SFTPNotice`), until it is closed: above all where the local copies went
/// whose changes never reached the server, with a way to get to them.
private struct NoticeBar: View {
    let notice: SFTPNotice
    let onReveal: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Palette.warning)
                    .accessibilityHidden(true)
                Text(verbatim: notice.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: DS.Space.sm)
                if !notice.files.isEmpty {
                    Button("Reveal in Finder", action: onReveal)
                        .buttonStyle(.link)
                        .font(.callout)
                        .fixedSize()
                }
                DSRowButton("xmark", help: "Close", action: onClose)
            }
            .padding(.horizontal, DS.Space.md + 2)
            // The close button is taller than a line of text: with this the bar is as high as
            // a row of the editing bar above it.
            .padding(.vertical, DS.Space.xs + 2)
        }
        .dsCard(cornerRadius: DS.Radius.row)
    }
}
