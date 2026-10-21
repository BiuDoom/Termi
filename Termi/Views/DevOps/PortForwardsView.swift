import SwiftUI

/// Port Forwards page — every host's tunnel rules: one card per host, each rule one line —
/// its route (where it listens ┄ where it ends; the host is the card's title) with a switch.
/// Tunnels run on the host's shared connection: start them here (no terminal needed), or let
/// them start by themselves when a terminal connects to the host.
struct PortForwardsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = PortForwardViewModel()
    @State private var hostsLoaded = false
    @State private var showingForm = false
    @State private var editingForward: PortForward?
    /// The host a new rule is for ("+" of its card); nil asks for the host first.
    @State private var newRuleHostId: Int64?
    @State private var showingDeleteConfirm = false
    @State private var forwardToDelete: PortForward?

    private var hasLoaded: Bool { hostsLoaded && viewModel.hasLoaded }
    private var isEmpty: Bool { hasLoaded && viewModel.portForwards.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dsStageBackground()
            if showingForm {
                Divider()
                inspectorContent
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.standard, value: showingForm)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addRule()
                    } label: {
                        Label("New Rule", systemImage: "plus")
                    }
                    .labelStyle(.titleAndIcon)
                    // The empty state carries the page's one prominent button itself.
                    .dsButtonStyle(isEmpty && viewModel.error == nil ? .glass : .prominent)
                    .help("Add a port forwarding rule")
                }
            }
            .task {
                // Hosts first, so the cards never show a placeholder name before the real one.
                await appViewModel.ensureHostsLoaded()
                await viewModel.loadAll()
                // The window's host list is read once: a rule of a host that joined since (an
                // import, another window) would be drawn as "Host #n" — read the hosts again.
                let known = Set(appViewModel.hostsPage.hosts.compactMap(\.id))
                if viewModel.portForwards.contains(where: { !known.contains($0.hostId) }) {
                    await appViewModel.hostsPage.loadHosts()
                }
                hostsLoaded = true
                #if DEBUG
                viewModel.applyDebugSample()
                #endif
            }
            .alert("Delete Port Forward", isPresented: $showingDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let pf = forwardToDelete, let id = pf.id {
                        Task {
                            await viewModel.delete(id: id)
                        }
                    }
                }
            } message: {
                // Which rule: the route its row draws, and the host of its card.
                if let pf = forwardToDelete {
                    let host = hostLabel(forHostId: pf.hostId)
                    Text("Delete “\(PortForwardViewModel.routeText(of: pf, hostLabel: host))” on \(host)? This cannot be undone.")
                }
            }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let editing = editingForward {
            PortForwardFormView(
                portForward: editing,
                hostId: editing.hostId,
                isEmbeddedInInspector: true,
                onCancel: { showingForm = false }
            ) { saved in
                Task { await viewModel.save(saved) }
            }
            .id("edit-\(editing.id ?? -1)")
        } else if appViewModel.hostsPage.hosts.isEmpty && newRuleHostId == nil {
            DSInspectorPanel("Add Port Forward", onClose: { showingForm = false }) {
                ContentUnavailableView {
                    Label("No Hosts", systemImage: "server.rack")
                } description: {
                    Text("Add a host first before creating port forwarding rules.")
                } actions: {
                    Button("Show Hosts") {
                        showingForm = false
                        appViewModel.selectedSidebar = .terminal
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            PortForwardFormView(
                hostId: newRuleHostId ?? 0,
                availableHosts: appViewModel.hostsPage.hosts,
                suggestedHostId: suggestedHostId,
                isEmbeddedInInspector: true,
                onCancel: { showingForm = false }
            ) { saved in
                Task { await viewModel.save(saved) }
            }
            .id("new-\(newRuleHostId ?? 0)")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        // Nothing until the first read is over: it is too quick for a spinner, and the empty
        // state must not flash before the rules.
        if !hasLoaded {
            Color.clear
        } else if viewModel.portForwards.isEmpty {
            if let error = viewModel.error {
                errorState(error)
            } else {
                emptyState
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg + 2) {
                    if let error = viewModel.error {
                        OpsErrorBanner(message: error) { viewModel.error = nil }
                            .padding(.horizontal, -DS.Space.xl)
                    }
                    let groups = groupedByHost
                    ForEach(groups, id: \.hostId) { group in
                        // With one host the toolbar's "New Rule" already means this host.
                        hostCard(group, showsAdd: groups.count > 1)
                    }
                }
                .dsCenteredColumn()
                .padding(.horizontal, DS.Space.xl + 2)
                .padding(.top, DS.Space.md)
                .padding(.bottom, DS.Space.xl)
            }
        }
    }

    // MARK: - Hosts and their rules

    private struct HostSection {
        let hostId: Int64
        let host: Host?
        let hostLabel: String
        let forwards: [PortForward]
    }

    private var groupedByHost: [HostSection] {
        let hosts = appViewModel.hostsPage.hosts
        let grouped = Dictionary(grouping: viewModel.portForwards, by: \.hostId)
        return grouped.map { hostId, forwards in
            let host = hosts.first { $0.id == hostId }
            return HostSection(hostId: hostId, host: host, hostLabel: hostLabel(forHostId: hostId), forwards: forwards)
        }
        .sorted { $0.hostLabel.localizedCaseInsensitiveCompare($1.hostLabel) == .orderedAscending }
    }

    /// The name a host's card carries (a placeholder for a host that is gone).
    private func hostLabel(forHostId hostId: Int64) -> String {
        appViewModel.hostsPage.hosts.first { $0.id == hostId }?.displayName ?? String(localized: "Host #\(hostId)")
    }

    private func hostCard(_ group: HostSection, showsAdd: Bool) -> some View {
        let status = appViewModel.avatarStatus(forHostId: group.hostId)
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm + 1) {
                if let host = group.host {
                    DSHostAvatar(host, size: 22, status: status)
                } else {
                    DSHostAvatar(os: .unknown, size: 22)
                }
                Text(verbatim: group.hostLabel)
                    .font(DS.Font.rowTitle)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let address = group.host?.addressDescription, address != group.hostLabel {
                    Text(verbatim: address)
                        .font(DS.Font.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: DS.Space.sm)
                if showsAdd {
                    DSGlassIconButton("plus", help: "Add a rule for this host", size: .small) {
                        addRule(forHost: group.hostId)
                    }
                }
            }
            .padding(.horizontal, DS.Space.xs)
            // The same height with and without the "+".
            .frame(minHeight: DS.Height.smallControl)

            DSGroup {
                ForEach(group.forwards) { pf in
                    PortForwardRowView(
                        forward: pf,
                        host: group.host,
                        hostLabel: group.hostLabel,
                        hostStatus: status,
                        status: viewModel.status(of: pf),
                        onSetAutoStart: { enabled in
                            guard let id = pf.id else { return }
                            Task { await viewModel.toggleEnabled(id: id, enabled: enabled) }
                        },
                        onEdit: {
                            newRuleHostId = nil
                            editingForward = pf
                            showingForm = true
                        },
                        onDelete: {
                            forwardToDelete = pf
                            showingDeleteConfirm = true
                        }
                    )
                }
            }
        }
    }

    /// Only the exception: how many rules there are and which run is on the page itself (the
    /// rows and their switches).
    private var subtitle: Text {
        let failed = viewModel.failedCount
        guard failed > 0 else { return Text(verbatim: "") }
        return Text("\(failed) failed to start").foregroundStyle(DS.Palette.danger)
    }

    // MARK: - Empty / error

    private var emptyState: some View {
        DSEmptyState("Bring a remote port to this Mac",
                     message: "Create tunnels (local, remote or SOCKS) on your hosts. Start them here, or let them start with a terminal session.",
                     page: .portForwards) {
            // What a rule is, drawn the way the page draws one: port ┄ host ┄ target.
            DSRouteDiagram(hops: [
                .endpoint("localhost:8080", symbol: "laptopcomputer"),
                .endpoint(String(localized: "Host"), symbol: "server.rack"),
                .endpoint("127.0.0.1:8080", symbol: "network")
            ])
            .accessibilityHidden(true)
        } actions: {
            Button("New Rule", systemImage: "plus") {
                addRule()
            }
            .dsButtonStyle(.prominent)
        }
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(verbatim: message)
        } actions: {
            Button("Retry") {
                Task { await viewModel.loadAll() }
            }
        }
    }

    // MARK: - Helpers

    /// The host the picker stands on when it opens: the one host that has rules (its card has
    /// no "+" of its own then).
    private var suggestedHostId: Int64? {
        let hostIds = Set(viewModel.portForwards.map(\.hostId))
        guard hostIds.count == 1, let id = hostIds.first,
              appViewModel.hostsPage.hosts.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// "New Rule" of the toolbar and of the empty state. Asks for the host first — unless
    /// there is only one to choose.
    private func addRule() {
        editingForward = nil
        newRuleHostId = PortForwardViewModel.onlyHostId(in: appViewModel.hostsPage.hosts)
        showingForm = true
    }

    private func addRule(forHost hostId: Int64) {
        editingForward = nil
        newRuleHostId = hostId
        showingForm = true
    }
}

// MARK: - Row

/// One forwarding rule in one line: its route, whether it starts by itself, its type, the
/// switch that runs it and a menu (auto-start, copy, edit, delete). A second line appears only
/// for what the switch cannot say: connecting, or failed and why.
struct PortForwardRowView: View {
    let forward: PortForward
    let host: Host?
    let hostLabel: String
    var hostStatus: DSHostAvatar.Status = .none
    let status: PortForwardManager.Status?
    let onSetAutoStart: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var manager: PortForwardManager { .shared }

    private var isRunning: Bool {
        switch status {
        case .active, .starting, .stopFailed: return true
        default: return false
        }
    }

    private var runTitle: LocalizedStringKey {
        isRunning ? "Stop tunnel" : "Start tunnel"
    }

    private var autoStart: Binding<Bool> {
        Binding(get: { forward.enabled }, set: { onSetAutoStart($0) })
    }

    /// The switch IS the tunnel's state: on = running (tunnels run on their own — no terminal
    /// needed). Auto-start is in the menu and shown as the bolt beside the type.
    private var running: Binding<Bool> {
        Binding(get: { isRunning }, set: { _ in toggleRun() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.card) {
            HStack(spacing: DS.Space.card) {
                route
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAction(named: "Edit") { onEdit() }
                    .accessibilityAction(named: "Delete") { onDelete() }
                autoStartMark
                typeChip
                    .fixedSize()
                Toggle(isOn: running) {
                    Text(runTitle)
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                // Connecting cannot be flipped back and forth; "Stop tunnel" stays in the menu.
                .disabled(status == .starting)
                .help(runTitle)
                Menu {
                    menuItems(includesRun: status == .starting)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel(Text("More"))
            }
            stateLine
        }
        .padding(.leading, DS.Space.lg)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu { menuItems(includesRun: true) }
    }

    // MARK: Route

    /// The route in one line, or — when the page is too narrow for it — the rule as text.
    private var route: some View {
        ViewThatFits(in: .horizontal) {
            // The row sits under its host's header: the route does not name the host again.
            DSRouteDiagram(hops: Self.hops(for: forward, host: host, hostLabel: hostLabel, hostStatus: hostStatus,
                                           underHostHeader: true),
                           activity: activity)
            Text(verbatim: forward.sshForward.displayDescription)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var activity: DSRouteDiagram.Activity {
        switch status {
        case .active: return .flowing
        case .failed: return .failed
        default: return .idle
        }
    }

    /// Where it listens, the host, where it ends — in the direction the connections travel.
    /// Under the host's own header (`underHostHeader`) the host in the middle is left out: the
    /// header says it. A rule whose host is gone keeps the middle hop — its header is only a
    /// placeholder.
    static func hops(for rule: PortForward, host: Host?, hostLabel: String,
                     hostStatus: DSHostAvatar.Status = .none, underHostHeader: Bool = false) -> [DSRouteDiagram.Hop] {
        let target = rule.remoteHost.contains(":") ? "[\(rule.remoteHost)]:\(rule.remotePort)"
            : "\(rule.remoteHost):\(rule.remotePort)"
        let listener: DSRouteDiagram.Hop
        let end: DSRouteDiagram.Hop
        switch rule.type {
        case "remote":
            // The host listens; the target is reached from this Mac.
            listener = .endpoint("\(hostLabel):\(rule.localPort)", symbol: "network")
            end = .endpoint(target, symbol: "laptopcomputer")
        case "dynamic":
            // That it is a SOCKS proxy is the "Dynamic" chip's to say.
            listener = .endpoint("localhost:\(rule.localPort)", symbol: "laptopcomputer")
            end = .endpoint(String(localized: "Any destination"), symbol: "globe")
        default:
            listener = .endpoint("localhost:\(rule.localPort)", symbol: "laptopcomputer")
            end = .endpoint(target, symbol: "network")
        }
        if underHostHeader, host != nil { return [listener, end] }
        let via = host.map { DSRouteDiagram.Hop(host: $0, status: hostStatus) }
            ?? .endpoint(hostLabel, symbol: "server.rack")
        return [listener, via, end]
    }

    @ViewBuilder
    private var typeChip: some View {
        switch forward.type {
        case "local": DSChip("Local")
        case "remote": DSChip("Remote")
        case "dynamic":
            DSChip("Dynamic")
                .help("SOCKS proxy")
                .accessibilityHint(Text("SOCKS proxy"))
        default: DSChip(verbatim: forward.type)
        }
    }

    /// Auto-start as a glyph in a slot of its own, so the type chips stay in one column. The
    /// sentence is its tooltip, its label, and the menu's item.
    private var autoStartMark: some View {
        Image(systemName: "bolt")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
            .opacity(forward.enabled ? 1 : 0)
            .help(forward.enabled ? Text("Starts automatically with a terminal session") : Text(verbatim: ""))
            .accessibilityLabel(Text("Starts automatically with a terminal session"))
            .accessibilityHidden(!forward.enabled)
    }

    // MARK: State

    /// Only what the switch cannot say. Running and stopped are the switch and the colour of
    /// the route's line.
    @ViewBuilder
    private var stateLine: some View {
        switch status {
        case .starting:
            DSStatusPill("Connecting…", tone: .warning, isPulsing: true, showsBackground: false)
                .padding(.leading, 2)
        case .failed(let message), .stopFailed(let message):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs + 2) {
                Label(statusIsStopFailure ? "Failed to stop" : "Failed to start", systemImage: "xmark.circle")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Palette.danger)
                    .fixedSize()
                Text(verbatim: "·")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(verbatim: message)
                    .font(.system(size: 11, design: .monospaced))
                    // Mixed toward the label colour like other tinted small text: plain red is
                    // too faint on white.
                    .foregroundStyle(DS.Palette.danger.mix(with: .primary, by: 0.3))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(message)
            }
            .padding(.leading, 2)
        case .active, nil:
            EmptyView()
        }
    }

    // MARK: Menu

    @ViewBuilder
    private func menuItems(includesRun: Bool) -> some View {
        if includesRun {
            Button(action: toggleRun) {
                Label(runTitle, systemImage: isRunning ? "stop.fill" : "play.fill")
            }
        }
        Toggle("Starts automatically with a terminal session", isOn: autoStart)
        Divider()
        if let address = PortForwardViewModel.localAddress(of: forward) {
            Button {
                copy(address)
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
        }
        if let host {
            // Only copied: the app never runs it.
            Button {
                copy(PortForwardViewModel.sshCommand(for: forward, host: host))
            } label: {
                Label("Copy as ssh Command", systemImage: "terminal")
            }
        }
        // Not every forward is HTTP: offered, never shown as a link.
        if forward.type == "local", status == .active,
           let url = URL(string: "http://localhost:\(forward.localPort)") {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
        }
        Divider()
        Button(action: onEdit) {
            Label("Edit", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var statusIsStopFailure: Bool {
        if case .stopFailed = status { return true }
        return false
    }

    private func toggleRun() {
        Task { await manager.toggle(forward) }
    }
}

// MARK: - Error banner

/// A view model's error shown above the page's list until it is closed.
/// (With nothing to list the pages show the error in place of the empty state instead.)
struct OpsErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            DSMessage(verbatim: message)
            DSRowButton("xmark", help: "Close", action: onDismiss)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.sm)
    }
}

// MARK: - Host Picker for adding a port forward from global view

struct PortForwardHostPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var appViewModel
    let onSave: (Int64, PortForward) -> Void

    @State private var hosts: [Host] = []
    @State private var isLoading = true
    @State private var selectedHostId: Int64?
    @State private var showingForwardForm = false

    /// `suggestedHostId`: the host the list stands on when it opens ("Next" goes on at once).
    init(suggestedHostId: Int64? = nil, onSave: @escaping (Int64, PortForward) -> Void) {
        self.onSave = onSave
        _selectedHostId = State(initialValue: suggestedHostId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                DSSheetTitle("Select Host")
                Text("Choose the host the tunnel runs on.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.xl)
            .padding(.bottom, DS.Space.md)

            Divider()

            List(hosts, selection: $selectedHostId) { host in
                // The selection is an Int64: a tag of type Int64? never matches it.
                hostRow(host)
                    .tag(host.id ?? -1)
            }
            .listStyle(.inset)
            // Double-click picks the host and moves on.
            .contextMenu(forSelectionType: Int64.self) { _ in
            } primaryAction: { ids in
                guard let id = ids.first else { return }
                selectedHostId = id
                showingForwardForm = true
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Hosts", systemImage: "server.rack")
                    } description: {
                        Text("Add a host first before creating port forwarding rules.")
                    } actions: {
                        Button("Show Hosts") {
                            dismiss()
                            appViewModel.selectedSidebar = .terminal
                        }
                    }
                }
            }
        }
        .frame(width: 420, height: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Next") {
                    showingForwardForm = true
                }
                .disabled(selectedHostId == nil)
            }
        }
        .task {
            hosts = (try? await HostRepository.shared.fetchAll()) ?? []
            isLoading = false
        }
        .sheet(isPresented: $showingForwardForm) {
            if let hostId = selectedHostId {
                PortForwardFormView(hostId: hostId) { saved in
                    onSave(hostId, saved)
                    dismiss()
                }
            }
        }
    }

    private func hostRow(_ host: Host) -> some View {
        let name = host.displayName
        return HStack(spacing: DS.Space.md) {
            DSHostAvatar(host, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .lineLimit(1)
                Text(verbatim: host.addressDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
}
