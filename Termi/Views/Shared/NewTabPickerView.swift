import SwiftUI

/// Full-window New Tab Host Picker (`⌘T` / `+` in the top surface bar), aligned with Termius:
/// - Large top search & direct `ssh user@host -p port` input bar + inline `Local Terminal (⌘L)` button
/// - Saved multi-pane Workspace templates
/// - Multi-selectable Recent & All Hosts grid with a floating batch-connect / save-workspace bar
struct NewTabPickerView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var query = ""
    @State private var adHocPassword = ""
    @State private var selectedHostIds: Set<Int64> = []
    @State private var isCreatingWorkspace = false
    @State private var workspaceName = ""
    @FocusState private var isSearchFocused: Bool

    private var hostsVM: HostsViewModel { appViewModel.hostsPage }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip optional leading `ssh ` command prefix so users can paste `ssh user@host -p 2222`.
    static func normalizedSSHInput(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("ssh ") {
            text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        // Convert `-p <port>` flag into `:port` if present
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if let pIndex = parts.firstIndex(of: "-p"), pIndex + 1 < parts.count {
            let port = parts[pIndex + 1]
            let remaining = parts.enumerated().compactMap { idx, token -> String? in
                (idx == pIndex || idx == pIndex + 1) ? nil : token
            }
            if let target = remaining.first, !target.contains(":") {
                return "\(target):\(port)"
            }
        }
        return text
    }

    private var normalizedInput: String {
        Self.normalizedSSHInput(trimmedQuery)
    }

    private var matchingHosts: [Host] {
        let all = hostsVM.hosts
        guard !trimmedQuery.isEmpty else { return all }
        let q = trimmedQuery.lowercased()
        return CommandPaletteView.ranked(
            all.filter {
                $0.label.lowercased().contains(q) ||
                $0.hostname.lowercased().contains(q) ||
                $0.username.lowercased().contains(q)
            },
            query: q
        )
    }

    private var recentHosts: [Host] {
        AppViewModel.recentHosts(matchingHosts, limit: 8)
    }

    private var quickConnectCandidate: Host? {
        guard !normalizedInput.isEmpty else { return nil }
        if HostsViewModel.savedHost(matching: normalizedInput, in: hostsVM.hosts) != nil {
            return nil
        }
        return QuickConnectParser.parse(normalizedInput)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    headerSearchBar

                    if let candidate = quickConnectCandidate {
                        directConnectCard(candidate)
                    }

                    if !appViewModel.workspaces.isEmpty || isCreatingWorkspace {
                        workspacesSection
                    }

                    if !recentHosts.isEmpty && trimmedQuery.isEmpty {
                        hostSection(
                            title: "Recent Connections",
                            subtitle: "Click to select multiple · Double-click to connect",
                            hosts: recentHosts
                        )
                    }

                    hostSection(
                        title: trimmedQuery.isEmpty ? "All Hosts" : "Matching Hosts",
                        subtitle: matchingHosts.isEmpty ? nil : "\(matchingHosts.count)",
                        hosts: matchingHosts
                    )
                }
                .padding(.horizontal, DS.Space.page)
                .padding(.top, DS.Space.xxl)
                .padding(.bottom, selectedHostIds.isEmpty ? DS.Space.xxl : 96)
                .dsCenteredColumn(maxWidth: 860)
            }

            if !selectedHostIds.isEmpty {
                selectionFloatingBar
                    .padding(.bottom, DS.Space.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsStageBackground()
        .animation(DS.Motion.standard, value: selectedHostIds.isEmpty)
        .animation(DS.Motion.standard, value: isCreatingWorkspace)
        .task {
            await appViewModel.ensureHostsLoaded()
            isSearchFocused = true
        }
        .onKeyPress(.escape) {
            if !selectedHostIds.isEmpty {
                selectedHostIds.removeAll()
                return .handled
            }
            if !query.isEmpty {
                query = ""
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Search & Direct Connect Bar

    private var headerSearchBar: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(spacing: DS.Space.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(
                "Find a host or type ssh user@host -p 22 to connect…",
                text: $query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .autocorrectionDisabled()
            .focused($isSearchFocused)
            .onSubmit { submitPrimaryAction() }

            if !query.isEmpty {
                DSRowButton("xmark.circle.fill", help: "Clear") {
                    query = ""
                    isSearchFocused = true
                }
            }

            Divider()
                .frame(height: 22)

            Button {
                appViewModel.addLocalTerminalTab()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                    Text("Local Terminal")
                    DSShortcut("⌘L")
                }
            }
            .dsButtonStyle(.glass, size: .small)
            .keyboardShortcut("l", modifiers: .command)
            .help("Open a local shell tab (⌘L)")
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(height: 52)
        .background(DS.Palette.card, in: shape)
        .overlay(
            shape.strokeBorder(
                isSearchFocused ? AnyShapeStyle(DS.Palette.accent.opacity(0.75)) : AnyShapeStyle(DS.Palette.hairline),
                lineWidth: isSearchFocused ? 1.5 : 1
            )
        )
    }

    // MARK: - Direct SSH Connect Card

    private func directConnectCard(_ candidate: Host) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSSectionHeader("Direct SSH Connection")
            DSGroup {
                DSRow {
                    DSHostAvatar(candidate, size: DS.Tile.row)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connect to \(candidate.addressDescription)")
                            .font(DS.Font.rowTitle)
                        Text("Temporary session · Press Return to connect")
                            .font(DS.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DS.Space.sm)
                    Button {
                        appViewModel.addQuickConnectTab(
                            host: candidate,
                            password: adHocPassword.isEmpty ? nil : adHocPassword
                        )
                    } label: {
                        Label("Connect", systemImage: "bolt.fill")
                    }
                    .dsButtonStyle(.prominent, size: .small)
                }
                DSKeyValueRow("Password") {
                    ASCIISecureField("Optional — asked in pane when connecting", text: $adHocPassword, isBezeled: false) {
                        appViewModel.addQuickConnectTab(
                            host: candidate,
                            password: adHocPassword.isEmpty ? nil : adHocPassword
                        )
                    }
                }
            }
        }
    }

    // MARK: - Workspaces Section

    private var workspacesSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSSectionHeader("Workspaces") {
                Text("Multi-pane split templates")
            }

            if isCreatingWorkspace {
                DSGroup {
                    DSRow {
                        Image(systemName: "rectangle.split.2x2")
                            .foregroundStyle(DS.Palette.accent)
                        TextField("Workspace name (e.g. Prod Cluster)", text: $workspaceName)
                            .textFieldStyle(.plain)
                            .onSubmit { saveCurrentWorkspace() }
                        Spacer(minLength: DS.Space.sm)
                        Button("Cancel") {
                            isCreatingWorkspace = false
                            workspaceName = ""
                        }
                        .dsButtonStyle(.glass, size: .small)
                        Button("Save Workspace") {
                            saveCurrentWorkspace()
                        }
                        .dsButtonStyle(.prominent, size: .small)
                        .disabled(workspaceName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            if !appViewModel.workspaces.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240, maximum: 400), spacing: DS.Space.card)],
                    alignment: .leading,
                    spacing: DS.Space.card
                ) {
                    ForEach(appViewModel.workspaces) { workspace in
                        let resolvedHosts = workspace.hostIds.compactMap { id in
                            hostsVM.hosts.first { $0.id == id }
                        }
                        Button {
                            appViewModel.openWorkspace(workspace)
                        } label: {
                            HStack(spacing: DS.Space.md) {
                                DSIconTile(.symbol("rectangle.split.2x2"), tint: DS.Palette.accent, size: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: workspace.name)
                                        .font(DS.Font.rowTitle)
                                        .lineLimit(1)
                                    Text("\(resolvedHosts.count) panes · \(resolvedHosts.map(\.displayName).joined(separator: ", "))")
                                        .font(DS.Font.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(DS.Space.md)
                            .dsCard(isInteractive: true)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open Workspace") {
                                appViewModel.openWorkspace(workspace)
                            }
                            Divider()
                            Button("Delete Workspace", role: .destructive) {
                                appViewModel.deleteWorkspace(workspace.id)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Host Grid Section

    private func hostSection(title: LocalizedStringKey, subtitle: LocalizedStringKey?, hosts: [Host]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSSectionHeader(title) {
                if let subtitle {
                    Text(subtitle)
                }
            }

            if hosts.isEmpty {
                DSGroup {
                    DSRow {
                        Text("No matching hosts. Press Return to connect if you typed an SSH address.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240, maximum: 380), spacing: DS.Space.card)],
                    alignment: .leading,
                    spacing: DS.Space.card
                ) {
                    ForEach(hosts) { host in
                        let isSelected = host.id.map { selectedHostIds.contains($0) } ?? false
                        let status = appViewModel.avatarStatus(forHostId: host.id)
                        DSVaultCard(
                            title: host.displayName,
                            subtitle: "ssh · \(host.addressDescription)",
                            isSelected: isSelected,
                            onSelect: { toggleHostSelection(host) },
                            onPrimaryAction: { appViewModel.connect(to: host) }
                        ) {
                            DSHostAvatar(host, size: 40, status: status)
                        } badge: {
                            if host.firstJumpName(hosts: hostsVM.hosts, groups: hostsVM.allGroups) != nil {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Connect") { appViewModel.connect(to: host) }
                            Button("Open SFTP") { appViewModel.openSFTP(for: host) }
                            if let id = host.id {
                                Button(isSelected ? "Deselect" : "Select for Batch / Workspace") {
                                    if isSelected {
                                        selectedHostIds.remove(id)
                                    } else {
                                        selectedHostIds.insert(id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bottom Multi-Select Action Bar

    private var selectionFloatingBar: some View {
        let chosenHosts = hostsVM.hosts.filter { host in
            guard let id = host.id else { return false }
            return selectedHostIds.contains(id)
        }
        return DSGlassContainer(spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.md) {
                Text("\(chosenHosts.count) selected")
                    .font(DS.Font.label.monospacedDigit())
                    .padding(.leading, DS.Space.sm)

                Button("Clear") {
                    selectedHostIds.removeAll()
                }
                .dsButtonStyle(.glass, size: .small)

                if chosenHosts.count >= 2 {
                    Button {
                        workspaceName = chosenHosts.prefix(2).map(\.displayName).joined(separator: " + ")
                        isCreatingWorkspace = true
                    } label: {
                        Label("Save as Workspace…", systemImage: "rectangle.split.2x2")
                    }
                    .dsButtonStyle(.glass, size: .small)

                    Button {
                        appViewModel.connectMultiple(hosts: chosenHosts, asSplitTab: true)
                        selectedHostIds.removeAll()
                    } label: {
                        Label("Open in Split Tab", systemImage: "rectangle.split.2x1")
                    }
                    .dsButtonStyle(.glass, size: .small)
                }

                Button {
                    appViewModel.connectMultiple(hosts: chosenHosts, asSplitTab: false)
                    selectedHostIds.removeAll()
                } label: {
                    Label("Connect \(chosenHosts.count) Hosts", systemImage: "bolt.fill")
                }
                .dsButtonStyle(.prominent, size: .small)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .dsFloatingBar()
        }
    }

    // MARK: - Actions

    private func toggleHostSelection(_ host: Host) {
        guard let id = host.id else { return }
        if selectedHostIds.contains(id) {
            selectedHostIds.remove(id)
        } else {
            selectedHostIds.insert(id)
        }
    }

    private func submitPrimaryAction() {
        let selected = hostsVM.hosts.filter { host in
            guard let id = host.id else { return false }
            return selectedHostIds.contains(id)
        }
        if !selected.isEmpty {
            appViewModel.connectMultiple(hosts: selected, asSplitTab: false)
            selectedHostIds.removeAll()
            return
        }
        if matchingHosts.count == 1, let first = matchingHosts.first {
            appViewModel.connect(to: first)
            return
        }
        if let candidate = quickConnectCandidate {
            appViewModel.addQuickConnectTab(
                host: candidate,
                password: adHocPassword.isEmpty ? nil : adHocPassword
            )
            return
        }
        if let first = matchingHosts.first, !trimmedQuery.isEmpty {
            appViewModel.connect(to: first)
        }
    }

    private func saveCurrentWorkspace() {
        let name = workspaceName.trimmingCharacters(in: .whitespaces)
        let ids = Array(selectedHostIds)
        guard !name.isEmpty, !ids.isEmpty else { return }
        appViewModel.saveWorkspace(name: name, hostIds: ids)
        isCreatingWorkspace = false
        workspaceName = ""
    }
}
