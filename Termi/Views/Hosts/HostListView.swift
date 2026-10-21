import SwiftUI

/// Hosts page — the hosts as cards over the whole page (or as rows), with search-to-connect,
/// filters and groups. The record of a host is not beside them by default: it opens in a panel
/// at the trailing edge when asked for (the card's button, ⌘I, the context menu) and closes
/// again — the owner's request, after Termius.
/// Search lives in the toolbar; typing `user@host` and pressing Return connects.
struct HostListView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var isImporting = false
    @AppStorage(HostsViewModel.Layout.preferenceKey, store: AppProfile.defaults)
    private var layout = HostsViewModel.Layout.standard

    /// Width of the page: the search field of a narrow window has no room for the long prompt.
    @State private var pageWidth: CGFloat = 0

    /// In a narrow window the toolbar's search field is short: the prompt says the same in
    /// fewer words instead of being cut in the middle of "user@host".
    private var searchPrompt: LocalizedStringKey {
        pageWidth > 0 && pageWidth < 800 ? "Search, or user@host" : "Find a host or type user@host to connect"
    }

    /// Lives with the window: the tag filter, the search and the selection are still there
    /// after a look at a terminal, which takes the page out of the window.
    private var viewModel: HostsViewModel { appViewModel.hostsPage }

    /// Three cards in a row in the default window, two beside the open panel; two and one in
    /// the smallest window.
    static let cardMinimum: CGFloat = 264
    /// The record panel: the width `HostDetailView`'s compact layout is drawn for.
    static let panelWidth: CGFloat = 380
    /// The grid's leading and trailing padding.
    static let gridInsets: CGFloat = DS.Space.xl + 14
    /// Beside the panel in the smallest window the cards have a little less than their minimum:
    /// the one column takes what is there instead of reaching under the panel.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Self.cardWidthMinimum(gridWidth: gridWidth), maximum: 640), spacing: DS.Space.card)]
    }

    /// The least a card is given in a grid `gridWidth` points wide (its padding included; 0 = not
    /// measured yet): `cardMinimum`, or all the room when there is less.
    static func cardWidthMinimum(gridWidth: CGFloat) -> CGFloat {
        let room = gridWidth - gridInsets
        return room > 0 ? max(120, min(cardMinimum, room)) : cardMinimum
    }
    /// Width the cards share: how many stand in a row, for the arrow keys.
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                pageWidth = width
            }
            .searchable(text: Bindable(viewModel).searchText, prompt: searchPrompt)
            .onSubmit(of: .search, submitSearch)
            .toolbar { toolbarContent }
            // ⌘I (the record of the selected host, and away with it) is the View menu's
            // "Show Host Details" — see TermiApp's commands.
            // One stage behind the cards and the record: no seam where they meet.
            .dsStageBackground()
            .task {
                // The sessions may have ended while a terminal had this page's place.
                if appViewModel.connectedHostIds.isEmpty { viewModel.showsOnlineOnly = false }
                await viewModel.loadHosts()
                await viewModel.loadReferences()
                #if DEBUG
                applyDebugLaunchArguments()
                #endif
            }
            // The last live session ended: "online" would leave an empty list behind.
            .onChange(of: appViewModel.connectedHostIds.isEmpty) { _, isEmpty in
                if isEmpty { viewModel.showsOnlineOnly = false }
            }
            // The model stays when the page goes: a sheet or alert left open (a terminal took
            // the page's place under it) would come back with the page.
            .onDisappear { viewModel.dismissSheets() }
            // A filter or a search took the selected host off the page: the selection goes (and
            // with it the panel) instead of Return / ⌫ acting on a host that is not there.
            .onChange(of: visibleHostIds, initial: true) { _, ids in
                // Before the first read nothing is shown yet: a host another page asked for stays.
                if viewModel.hasLoaded { viewModel.keepSelection(within: ids) }
            }
            .onChange(of: appViewModel.tabs.count) { _, _ in
                if viewModel.sortOrder == .recent {
                    Task { await viewModel.loadHosts() }
                }
            }
            .alert(deleteTitle, isPresented: Bindable(viewModel).showingDeleteConfirm) {
                Button("Cancel", role: .cancel) {
                    viewModel.hostToDelete = nil
                    viewModel.groupToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let host = viewModel.hostToDelete {
                        Task { await viewModel.deleteHost(host) }
                    } else if let group = viewModel.groupToDelete {
                        Task { await viewModel.deleteGroup(group) }
                    }
                    viewModel.hostToDelete = nil
                    viewModel.groupToDelete = nil
                }
            } message: {
                if let group = viewModel.groupToDelete {
                    Text("Delete the group “\(group.name)”? Its hosts are kept and become ungrouped.")
                } else {
                    // Everything that goes with the host, not only its entry in the list.
                    Text("Delete “\(viewModel.hostToDelete?.displayName ?? "")”? Its connection history and the saved session output are deleted with it. This cannot be undone.")
                }
            }
            .focusSection()
            // ⌫ anywhere on the page: only for a host that was picked by hand. (With the
            // keyboard in the list, the list's own handler below answers.)
            .onDeleteCommand { requestDelete(listHasFocus: false) }
    }

    private func requestDelete(listHasFocus: Bool) {
        guard let id = HostsViewModel.deleteTarget(selected: viewModel.selectedHostId, picked: viewModel.pickedHostId,
                                                   listHasFocus: listHasFocus),
              visibleHostIds.contains(id),
              let host = viewModel.hosts.first(where: { $0.id == id }) else { return }
        viewModel.hostToDelete = host
        viewModel.showingDeleteConfirm = true
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Picker("View", selection: $layout) {
                Label("View as Grid", systemImage: "square.grid.2x2")
                    .tag(HostsViewModel.Layout.grid)
                    .help("View as Grid")
                Label("View as List", systemImage: "list.bullet")
                    .tag(HostsViewModel.Layout.list)
                    .help("View as List")
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
        }

        ToolbarItem {
            Menu {
                Picker("Sort By", selection: Bindable(viewModel).sortOrder) {
                    Text("Name").tag(HostsViewModel.SortOrder.name)
                    Text("Recently used").tag(HostsViewModel.SortOrder.recent)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort By")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    viewModel.newHostGroupId = nil
                    viewModel.showingAddHost = true
                } label: {
                    Label("New Host", systemImage: "plus")
                }
                Button {
                    viewModel.showingAddGroup = true
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
                Divider()
                Button {
                    appViewModel.openNewTabPicker()
                } label: {
                    Label("New Tab — Choose Host…", systemImage: "plus.rectangle.on.rectangle")
                }
                Button {
                    appViewModel.addLocalTerminalTab()
                } label: {
                    Label("New Local Terminal", systemImage: "terminal")
                }
                .keyboardShortcut("l", modifiers: .command)
                Button {
                    importSSHConfig()
                } label: {
                    Label("Import from ~/.ssh/config", systemImage: "square.and.arrow.down")
                }
                .disabled(isImporting)
            } label: {
                Label("New Host", systemImage: "plus")
            } primaryAction: {
                viewModel.newHostGroupId = nil
                viewModel.showingAddHost = true
            }
            .help("Add a host")
        }
    }

    /// One alert asks about a host or about a group.
    private var deleteTitle: LocalizedStringKey {
        viewModel.groupToDelete != nil ? "Delete Group" : "Delete Host"
    }

    // MARK: - Content

    private var hasActiveInspector: Bool {
        viewModel.showingAddHost
            || viewModel.editingHost != nil
            || viewModel.showingAddGroup
            || viewModel.editingGroup != nil
            || detailsHost != nil
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 0) {
            mainStage
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if hasActiveInspector {
                HStack(spacing: 0) {
                    Divider()
                    inspectorContent
                }
                .frame(width: Self.panelWidth + 1)
                .frame(maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.standard, value: hasActiveInspector)
        .clipped()
    }

    @ViewBuilder
    private var mainStage: some View {
        if !viewModel.hasLoaded {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.error, viewModel.totalHostCount == 0, viewModel.allGroups.isEmpty {
            // The hosts could not be read: not "No Hosts".
            ContentUnavailableView {
                Label("Error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error)
            } actions: {
                Button("Retry") { Task { await viewModel.loadHosts() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.totalHostCount == 0 && viewModel.searchText.isEmpty && viewModel.allGroups.isEmpty {
            emptyState
        } else if viewModel.filteredGroupedHosts.allSatisfy({ $0.hosts.isEmpty }) && !viewModel.searchText.isEmpty {
            noMatches
        } else {
            VStack(spacing: 0) {
                // A failed save, delete or duplicate: the hosts are still there to read.
                if let error = viewModel.error {
                    OpsErrorBanner(message: error) { viewModel.error = nil }
                }
                if showsFilterBar {
                    filterBar
                        .transition(.opacity)
                }
                // Around both layouts: a host that was just added or duplicated is scrolled to.
                ScrollViewReader { proxy in
                    Group {
                        if layout == .grid {
                            hostGrid
                        } else {
                            hostList
                        }
                    }
                    // The page came (back) into the window with a host selected — another
                    // page's "Show in Hosts" chose it while this one was away: its card may be
                    // below the fold.
                    .task {
                        guard let id = viewModel.hostToBringIntoView else { return }
                        await Task.yield()
                        proxy.scrollTo(id, anchor: .center)
                    }
                    .onChange(of: viewModel.revealCount) { _, _ in
                        guard let id = viewModel.revealedHostId else { return }
                        // A host added while a search or filter is on may not be among the
                        // cards: no selection (and no record) of a host the page does not show.
                        viewModel.keepSelection(within: visibleHostIds)
                        guard viewModel.selectedHostId == id else { return }
                        // After this update: the new host's row is not laid out yet.
                        Task { @MainActor in
                            await Task.yield()
                            withAnimation(DS.Motion.standard) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                    // The panel took room from under the selected card: it stays in view.
                    .onChange(of: viewModel.detailsHostId) { old, id in
                        guard let id else { return }
                        Task { @MainActor in
                            if old == nil {
                                // The cards are still where three columns put them: asked
                                // now, the card counts as in view and then reflows out of it.
                                try? await Task.sleep(for: .milliseconds(350))
                            } else {
                                await Task.yield()
                            }
                            // Another card may have been chosen while this one waited for
                            // the reflow: scrolling back to it would move that one away.
                            guard viewModel.detailsHostId == id else { return }
                            withAnimation(DS.Motion.standard) { proxy.scrollTo(id) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(DS.Motion.standard, value: showsFilterBar)
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if viewModel.showingAddHost {
            HostFormView(
                groupId: viewModel.newHostGroupId,
                isEmbeddedInInspector: true,
                onCancel: { viewModel.showingAddHost = false }
            ) { draft in
                Task { await viewModel.save(draft) }
            }
            .id("add-host-\(viewModel.newHostGroupId ?? -1)")
            .transition(.opacity)
        } else if let editingHost = viewModel.editingHost {
            HostFormView(
                host: editingHost,
                isEmbeddedInInspector: true,
                onCancel: { viewModel.editingHost = nil }
            ) { draft in
                Task { await viewModel.save(draft) }
            }
            .id("edit-host-\(editingHost.id ?? -1)")
            .transition(.opacity)
        } else if viewModel.showingAddGroup {
            GroupFormView(
                isEmbeddedInInspector: true,
                onCancel: { viewModel.showingAddGroup = false }
            ) { group in
                Task { await viewModel.saveGroup(group) }
            }
            .id("add-group")
            .transition(.opacity)
        } else if let editingGroup = viewModel.editingGroup {
            GroupFormView(
                group: editingGroup,
                isEmbeddedInInspector: true,
                onCancel: { viewModel.editingGroup = nil }
            ) { updated in
                Task { await viewModel.saveGroup(updated) }
            }
            .id("edit-group-\(editingGroup.id ?? -1)")
            .transition(.opacity)
        } else if let host = detailsHost {
            detailsPanel(for: host)
        }
    }

    /// The host the panel is open for: the selected one, while the details are shown.
    private var detailsHost: Host? {
        guard let id = viewModel.detailsHostId else { return nil }
        return viewModel.hosts.first { $0.id == id }
    }

    /// The record of the selected host, with the bar that closes the panel.
    private func detailsPanel(for host: Host) -> some View {
        // Inside the panel "Show Details" would point at itself.
        var actions = actions(for: host)
        actions.onToggleDetails = nil
        return HostDetailView(host: host, viewModel: viewModel, actions: actions, onClose: { viewModel.hideDetails() })
        // A new record, not the old one sliding to new values.
        .id(host.id)
        .transition(.opacity)
    }

    /// The bar is there while there is something to filter by (a tag, a live session) or a
    /// filter is on; without either it would be one chip that changes nothing.
    private var showsFilterBar: Bool {
        HostsViewModel.showsFilterBar(hostCount: viewModel.totalHostCount, hasTags: !viewModel.allTagNames.isEmpty,
                                      hasOnline: !onlineHostIds.isEmpty,
                                      isFiltering: viewModel.selectedTag != nil || viewModel.showsOnlineOnly)
    }

    /// "Ungrouped" says something only next to groups; without any it would head the whole list.
    private var showsUngroupedHeader: Bool {
        !viewModel.allGroups.isEmpty
    }

    /// Filters under the toolbar: everything, the hosts with a live session, one tag.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            DSGlassContainer(spacing: 7) {
                HStack(spacing: 7) {
                    DSFilterChip("All", count: viewModel.totalHostCount,
                                 isSelected: viewModel.selectedTag == nil && !viewModel.showsOnlineOnly) {
                        withAnimation(DS.Motion.standard) {
                            viewModel.selectedTag = nil
                            viewModel.showsOnlineOnly = false
                        }
                    }
                    DSFilterChip("Online", count: onlineHostIds.count, isSelected: viewModel.showsOnlineOnly) {
                        withAnimation(DS.Motion.standard) { viewModel.showsOnlineOnly.toggle() }
                    }
                    // Nothing to filter to: it would only empty the list.
                    .disabled(onlineHostIds.isEmpty && !viewModel.showsOnlineOnly)
                    ForEach(viewModel.allTagNames, id: \.self) { tag in
                        DSFilterChip(verbatim: "#\(tag)", count: viewModel.hostCount(forTag: tag),
                                     isSelected: viewModel.selectedTag == tag) {
                            withAnimation(DS.Motion.standard) {
                                viewModel.selectedTag = viewModel.selectedTag == tag ? nil : tag
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.xs)
                .padding(.bottom, DS.Space.card)
            }
        }
    }

    private var emptyState: some View {
        DSEmptyState("No Hosts",
                     message: "Add your first host, or type user@host in the search field to connect right away.",
                     page: .terminal) {
            Button("Add Host") {
                viewModel.newHostGroupId = nil
                viewModel.showingAddHost = true
            }
            .dsButtonStyle(.prominent)
            Button("Import ~/.ssh/config") { importSSHConfig() }
                .dsButtonStyle(.glass)
                .disabled(isImporting)
        }
    }

    @ViewBuilder
    private var noMatches: some View {
        if let candidate = viewModel.quickConnectCandidate {
            ContentUnavailableView {
                Label("Connect to \(candidate.addressDescription)", systemImage: "bolt.horizontal.circle")
            } description: {
                Text("Press Return to open an SSH session. You'll be asked for the password if needed.")
            } actions: {
                Button("Connect") { submitSearch() }
                    .keyboardShortcut(.defaultAction)
                    .dsButtonStyle(.prominent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView.search(text: viewModel.searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - List mode

    private var hostList: some View {
        let groups = visibleGroups
        // The whole page wide: the rows are read across, name at one edge, state at the other.
        return DSMasterList(selection: Bindable(viewModel).selectedHostId,
                            order: groups.flatMap { $0.hosts.compactMap(\.id) }) {
            if groups.isEmpty {
                filteredOutNote
                    .padding(.horizontal, 10)
                    .padding(.top, DS.Space.sm)
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { _, item in
                if let group = item.group {
                    HostGroupHeader(title: group.name, count: item.hosts.count, note: defaultsNote(of: group),
                                    isCompact: true) {
                        groupActions(group)
                    }
                } else if showsUngroupedHeader {
                    DSListSectionHeader("Ungrouped", count: item.hosts.count)
                } else {
                    // The room the header gave the first row above it.
                    Color.clear.frame(height: DS.Space.xs)
                }
                if item.hosts.isEmpty {
                    emptyGroupNote
                        .padding(.horizontal, 10)
                        .padding(.bottom, DS.Space.sm)
                }
                ForEach(item.hosts) { host in
                    HostListRow(host: host,
                                status: appViewModel.avatarStatus(forHostId: host.id),
                                sessionCount: appViewModel.liveSessionCount(forHostId: host.id),
                                showsJump: host.firstJumpName(hosts: viewModel.hosts, groups: viewModel.allGroups) != nil,
                                isSelected: host.id == viewModel.selectedHostId,
                                isHoverForced: isHoverForced(host),
                                onSelect: { viewModel.pick(host.id) },
                                actions: actions(for: host))
                        .id(host.id)
                }
            }
        }
        .onKeyPress(.return) { connectToSelection() }
        // The list has the keyboard: ⌫ is about the row its arrows stand on.
        .onDeleteCommand { requestDelete(listHasFocus: true) }
    }

    // MARK: - Grid mode

    private var hostGrid: some View {
        let sections = visibleGroups.map { $0.hosts.compactMap(\.id) }
        return ScrollViewReader { proxy in
            ScrollView {
                gridContent
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        gridWidth = width
                    }
            }
            // The same keys as the list: the arrows move the selection (here in two dimensions),
            // Return connects, ⌫ asks to delete.
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                let columns = HostsViewModel.gridColumns(width: gridWidth - Self.gridInsets,
                                                         minimum: Self.cardWidthMinimum(gridWidth: gridWidth),
                                                         spacing: DS.Space.card)
                guard let next = HostsViewModel.gridNeighbour(of: viewModel.selectedHostId, in: sections,
                                                              columns: columns, direction: direction) else { return }
                viewModel.selectedHostId = next
                proxy.scrollTo(next)
            }
            .onKeyPress(.return) { connectToSelection() }
            .onDeleteCommand { requestDelete(listHasFocus: true) }
        }
    }

    private var gridContent: some View {
            LazyVStack(alignment: .leading, spacing: DS.Space.sm) {
                if visibleGroups.isEmpty {
                    filteredOutNote
                        .padding(.horizontal, DS.Space.xs)
                        .padding(.top, DS.Space.sm)
                }
                ForEach(Array(visibleGroups.enumerated()), id: \.offset) { _, item in
                    if let group = item.group {
                        HostGroupHeader(title: group.name, count: item.hosts.count, note: defaultsNote(of: group),
                                        isCompact: false) {
                            groupActions(group)
                        }
                    } else if showsUngroupedHeader {
                        HostGroupHeader(title: String(localized: "Ungrouped"), count: item.hosts.count, note: nil,
                                        isCompact: false) {
                            EmptyView()
                        }
                    }
                    if item.hosts.isEmpty {
                        emptyGroupNote
                            .padding(.horizontal, DS.Space.xs)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.card) {
                            ForEach(item.hosts) { host in
                                card(for: host)
                                    .id(host.id)
                            }
                        }
                        .padding(.bottom, DS.Space.sm)
                    }
                }
            }
            .padding(.leading, DS.Space.xl)
            .padding(.trailing, Self.gridInsets - DS.Space.xl)
            // The room a section header gives the first cards above them.
            .padding(.top, showsUngroupedHeader ? 0 : DS.Space.xs)
            .padding(.bottom, DS.Space.lg)
    }

    /// Return connects to the selected host, like a double-click.
    private func connectToSelection() -> KeyPress.Result {
        guard let host = viewModel.selectedHost, let id = host.id, visibleHostIds.contains(id) else { return .ignored }
        appViewModel.connect(to: host)
        return .handled
    }

    private func card(for host: Host) -> some View {
        HostCardView(
            host: host,
            tags: viewModel.tags(for: host),
            status: appViewModel.avatarStatus(forHostId: host.id),
            sessionCount: appViewModel.liveSessionCount(forHostId: host.id),
            showsJump: host.firstJumpName(hosts: viewModel.hosts, groups: viewModel.allGroups) != nil,
            isSelected: host.id == viewModel.selectedHostId,
            isHoverForced: isHoverForced(host),
            onSelect: { viewModel.pick(host.id) },
            actions: actions(for: host)
        )
    }

    /// Debug screenshots only (`-debugHostHover`): no pointer is involved.
    private func isHoverForced(_ host: Host) -> Bool {
        #if DEBUG
        return host.id != nil && host.id == debugHoveredHostId
        #else
        return false
        #endif
    }

    // MARK: - Shared pieces

    /// The hosts the list or the grid shows now, in their order.
    private var visibleHostIds: [Int64] {
        visibleGroups.flatMap { $0.hosts.compactMap(\.id) }
    }

    private var visibleGroups: [(group: HostGroup?, hosts: [Host])] {
        viewModel.visibleGroups(onlineHostIds: onlineHostIds)
    }

    private var onlineHostIds: Set<Int64> {
        appViewModel.connectedHostIds
    }

    private var emptyGroupNote: some View {
        Text("No hosts in this group yet.")
            .font(DS.Font.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The filters together leave no host (a tag none of whose hosts is online): said in words,
    /// the filter bar above is where to change it.
    private var filteredOutNote: some View {
        Text("No hosts match the filters")
            .font(DS.Font.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(for host: Host) -> HostActions {
        HostActions(
            onConnect: { appViewModel.connect(to: host) },
            onOpenSFTP: { appViewModel.openSFTP(for: host) },
            onEdit: { viewModel.editingHost = host },
            onDuplicate: { Task { await viewModel.duplicateHost(host) } },
            onDelete: {
                viewModel.groupToDelete = nil
                viewModel.hostToDelete = host
                viewModel.showingDeleteConfirm = true
            },
            onToggleDetails: { viewModel.toggleDetails(for: host.id) },
            showsDetails: host.id != nil && host.id == viewModel.detailsHostId
        )
    }

    /// What the hosts of a group take from it: "Default user deploy · Default jump host bastion".
    private func defaultsNote(of group: HostGroup) -> String? {
        var parts: [String] = []
        if let user = group.username, !user.isEmpty {
            parts.append(String(localized: "Default user \(user)"))
        }
        if let jumpId = group.jumpHostId, let jump = viewModel.hosts.first(where: { $0.id == jumpId }) {
            parts.append(String(localized: "Default jump host \(jump.displayName)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func groupActions(_ group: HostGroup) -> some View {
        Button("New Host in Group") {
            viewModel.newHostGroupId = group.id
            viewModel.showingAddHost = true
        }
        Button("Edit Group…") { viewModel.editingGroup = group }
        Divider()
        Button("Delete Group", role: .destructive) {
            viewModel.hostToDelete = nil
            viewModel.groupToDelete = group
            viewModel.showingDeleteConfirm = true
        }
    }

    // MARK: - Actions

    private func submitSearch() {
        // Return in the search field and the "Connect" default button can both answer one key
        // press: the first empties the field, and an empty search connects to nothing.
        guard !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let visible = visibleGroups.flatMap(\.hosts)
        if visible.count == 1, let host = visible.first {
            appViewModel.connect(to: host)
            viewModel.searchText = ""
        } else if let candidate = viewModel.quickConnectCandidate {
            // A saved host opens as itself, anything else as an unsaved quick connection.
            appViewModel.connect(to: candidate)
            viewModel.searchText = ""
        }
    }

    private func importSSHConfig() {
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let summary = try await ImportExportService.shared.importSSHConfig()
                await viewModel.loadHosts()
                appViewModel.addToast(.success, summary.description)
            } catch {
                appViewModel.addToast(.error, error.localizedDescription)
            }
        }
    }

    #if DEBUG
    /// Debug builds only — states of this page for screenshots:
    /// `-debugHostSelect <label>` selects a host (the panel stays closed), `-debugHostDetails
    /// <label>` selects it and opens the panel, `-debugHostHover <label>` draws its card as
    /// with the pointer on it, `-debugHostEdit <label>` opens its form,
    /// `-debugHostsOnline YES` turns the "online" filter on, and `-debugHostsAfterConnect YES`
    /// comes back to this page once `-debugConnect` has opened its sessions.
    private func applyDebugLaunchArguments() {
        guard !Self.didApplyDebugArguments else { return }
        Self.didApplyDebugArguments = true
        let defaults = AppProfile.arguments
        if let label = defaults.string(forKey: "debugHostSelect"),
           let host = viewModel.hosts.first(where: { $0.label == label }) {
            viewModel.selectedHostId = host.id
        }
        if let label = defaults.string(forKey: "debugHostDetails"),
           let host = viewModel.hosts.first(where: { $0.label == label }) {
            viewModel.toggleDetails(for: host.id)
        }
        if let label = defaults.string(forKey: "debugHostHover"),
           let host = viewModel.hosts.first(where: { $0.label == label }) {
            debugHoveredHostId = host.id
        }
        // `-debugHostDelete <label>` asks whether to delete that host.
        if let label = defaults.string(forKey: "debugHostDelete"),
           let host = viewModel.hosts.first(where: { $0.label == label }) {
            viewModel.groupToDelete = nil
            viewModel.hostToDelete = host
            viewModel.showingDeleteConfirm = true
        }
        if let label = defaults.string(forKey: "debugHostEdit"),
           let host = viewModel.hosts.first(where: { $0.label == label }) {
            viewModel.editingHost = host
        }
        if defaults.bool(forKey: "debugHostsAfterConnect") {
            let app = appViewModel
            let page = viewModel
            let online = defaults.bool(forKey: "debugHostsOnline")
            // Not tied to the page: the terminal takes its place while the sessions open.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                app.selectedSidebar = .terminal
                app.isViewingTerminal = false
                page.showsOnlineOnly = online
            }
        }
    }

    private static var didApplyDebugArguments = false
    @State private var debugHoveredHostId: Int64?
    #endif
}

extension AppViewModel {
    /// How many of this window's live sessions are on the host.
    func liveSessionCount(forHostId hostId: Int64?) -> Int {
        guard let hostId else { return 0 }
        return tabs.flatMap(\.panes)
            .filter { $0.hostId == hostId && existingSession(for: $0.id)?.isLive == true }
            .count
    }
}

/// The header of a group of hosts: its name, how many it holds, and its actions. The list
/// keeps to the name and the count; the grid also says what its hosts take from the group.
private struct HostGroupHeader<Actions: View>: View {
    let title: String
    let count: Int
    let note: String?
    let isCompact: Bool
    @ViewBuilder let actions: () -> Actions
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(isCompact ? DS.Font.sectionHeader : DS.Font.label)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if !isCompact {
                countText
            }
            Spacer(minLength: DS.Space.sm)
            if let note, !isCompact {
                Text(verbatim: note)
                    .font(DS.Font.caption)
                    .lineLimit(1)
            }
            if Actions.self != EmptyView.self {
                Menu {
                    actions()
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                // In the list the header is quiet until pointed at; the context menu has the same.
                .opacity(isCompact && !isHovered ? 0 : 1)
            }
            if isCompact {
                countText
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, isCompact ? 10 : DS.Space.xs)
        .frame(height: isCompact ? DS.Height.sectionHeader : 30)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(note.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
        .contextMenu { actions() }
    }

    private var countText: some View {
        Text(verbatim: count.formatted())
            .font(.system(size: 11, weight: .medium).monospacedDigit())
    }
}
