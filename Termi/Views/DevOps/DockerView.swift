import SwiftUI

/// Docker — pick a host, manage its containers: start, stop, restart, remove, read logs.
struct DockerView: View {
    @Environment(AppViewModel.self) private var appViewModel

    private var viewModel: DockerViewModel { appViewModel.docker }
    @State private var didLoadHosts = false
    @State private var containerToRemove: String?
    @State private var containerToRemoveName: String = ""
    @State private var selection: DockerService.Container.ID?
    /// The table takes the keyboard when a row is picked (↑ / ↓ then walk the containers):
    /// a click alone selected the row and left the keyboard with the window.
    @FocusState private var isTableFocused: Bool
    /// Containers a start, stop or restart was sent to and has not answered yet (`docker stop`
    /// may take ten seconds): one command at a time per container.
    @State private var busy: Set<String> = []

    var body: some View {
        content
            .navigationSubtitle(subtitle)
            .task {
                await appViewModel.ensureHostsLoaded()
                await viewModel.loadHosts()
                didLoadHosts = true
                #if DEBUG
                applyDebugLaunchArguments()
                #endif
            }
            // A host's detected system (its tile) or the host itself changed on another page.
            .onReceive(NotificationCenter.default.publisher(for: .dsDataChanged)) { _ in
                Task { await viewModel.loadHosts() }
            }
            .onChange(of: viewModel.showAll) {
                Task { await viewModel.loadContainers() }
            }
            // The model stays with the window: a log sheet left open (a terminal took the page's
            // place under it) would come back with the page.
            .onDisappear {
                viewModel.showingLogs = false
            }
            .confirmationDialog(
                "Remove Container",
                isPresented: Binding(
                    get: { containerToRemove != nil },
                    set: { if !$0 { containerToRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let id = containerToRemove {
                        Task { await viewModel.removeContainer(id) }
                    }
                    containerToRemove = nil
                }
                Button("Cancel", role: .cancel) {
                    containerToRemove = nil
                }
            } message: {
                Text("Are you sure you want to remove container \"\(containerToRemoveName)\"? This action cannot be undone.")
            }
    }

    /// Only what the page shows nowhere else: that the host is being asked. (The host is the
    /// selected row and the detail's title, the counts are under that title.)
    private var subtitle: Text {
        guard viewModel.selectedHost != nil, viewModel.isLoading else { return Text(verbatim: "") }
        return Text("Loading…")
    }

    private var summary: DockerSummary {
        DockerSummary(viewModel.containers)
    }

    private var selected: DockerService.Container? {
        viewModel.containers.first { $0.id == selection }
    }

    #if DEBUG
    /// `-debugDockerSample <label>`: that host with sample containers, the second one selected
    /// (the test hosts run no Docker). `-debugDockerHost <label>`: that host, really asked.
    private func applyDebugLaunchArguments() {
        let defaults = AppProfile.arguments
        guard viewModel.selectedHost == nil else { return }
        if let label = defaults.string(forKey: "debugDockerSample"),
           let host = viewModel.hosts.first(where: { $0.label == label }) {
            viewModel.debugShowSample(on: host)
            selection = viewModel.containers.dropFirst().first?.id
        } else if let label = defaults.string(forKey: "debugDockerHost"),
                  let host = viewModel.hosts.first(where: { $0.label == label }) {
            viewModel.selectHost(host)
        }
    }
    #endif

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if didLoadHosts && viewModel.hosts.isEmpty {
            // loadHosts does not clear the error it left: without this a successful retry would
            // still show it.
            DevOpsNoHostsView(error: viewModel.error, onRetry: {
                viewModel.error = nil
                Task { await viewModel.loadHosts() }
            })
        } else {
            HStack(spacing: 0) {
                DSMasterDetail(sizing: .fixedMaster(width: ToolsHostMaster<EmptyView>.width,
                                                    compactWidth: ToolsHostMaster<EmptyView>.compactWidth)) {
                    ToolsHostMaster(hosts: viewModel.hosts, groups: appViewModel.hostsPage.allGroups,
                                    selectedKey: viewModel.selectedHost?.connectionKey) { host in
                        selection = nil
                        viewModel.selectHost(host)
                    } trailing: { host in
                        masterCount(host)
                    }
                } detail: {
                    detail
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.showingLogs {
                    HStack(spacing: 0) {
                        Divider()
                        ContainerLogsSheet(
                            containerName: viewModel.containers.first { $0.id == viewModel.logContainerId }?.name,
                            containerId: viewModel.logContainerId,
                            output: viewModel.logOutput,
                            isLoading: viewModel.isLoadingLogs,
                            error: viewModel.logError,
                            isEmbeddedInInspector: true,
                            onCancel: { viewModel.showingLogs = false }
                        )
                    }
                    .frame(width: DS.Layout.inspectorWidth + 1)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(DS.Motion.standard, value: viewModel.showingLogs)
            .clipped()
            // One stage behind the host column and the detail: no seam where they meet.
            .dsStageBackground()
        }
    }

    /// Running / all of the host whose containers are listed; nothing for the others.
    @ViewBuilder
    private func masterCount(_ host: Host) -> some View {
        if viewModel.hasLoaded, host.connectionKey == viewModel.selectedHost?.connectionKey {
            let text = viewModel.showAll ? "\(summary.running.count)/\(summary.total)" : "\(summary.running.count)"
            Text(verbatim: text)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .accessibilityLabel(Text("Running"))
                .accessibilityValue(Text(verbatim: text))
        }
    }

    private var detail: some View {
        GeometryReader { proxy in
            // The five-column table needs more room than the rest of the page.
            let isCompact = proxy.size.width < 600
            Group {
                if let host = viewModel.selectedHost {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        header(host)
                        // A failed action leaves the list as it was; say what went wrong above it.
                        if let error = viewModel.error, !viewModel.containers.isEmpty {
                            DSMessage(verbatim: error)
                        }
                        containerCard(isCompact: isCompact, width: proxy.size.width - 2 * DS.Space.page)
                    }
                    .id(host.connectionKey)
                    .transition(.opacity)
                } else {
                    ScrollView {
                        hostPicker
                    }
                }
            }
            .padding(.horizontal, isCompact ? DS.Space.lg : DS.Space.page)
            .padding(.top, DS.Space.sm)
            .padding(.bottom, isCompact ? DS.Space.lg : DS.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(DS.Motion.standard, value: viewModel.selectedHost?.connectionKey)
        }
    }

    /// No host chosen: the hosts to pick from. Nothing is selected by itself — listing
    /// containers connects, which may ask for a password.
    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("No Host Selected")
                    .font(DS.Font.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("Select a host to manage Docker containers.")
                    .font(DS.Font.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, DS.Space.md)

            DSHostPickerGrid(hosts: viewModel.hosts, liveHostIds: appViewModel.connectedHostIds) { host in
                selection = nil
                viewModel.selectHost(host)
            }
        }
    }

    // MARK: - Header

    /// Under the name: what the table adds up to, and the one number it does not show (images).
    /// Nothing before the host has answered, or when it has no containers (the card says that).
    private var headline: String? {
        guard viewModel.hasLoaded, summary.total > 0 else { return nil }
        return summary.headline(includesStopped: viewModel.showAll)
    }

    private func header(_ host: Host) -> some View {
        // The counts lie under the title and the actions, as Monitoring's facts do: beside the
        // actions the line would lose its end — the images — in a narrow window. (The address
        // is in the selected row.)
        DSDetailHeader(title: host.displayName) {
            DSHostAvatar(host, size: DS.Tile.header, status: appViewModel.avatarStatus(forHostId: host.id))
        } accessory: {
            if let headline {
                Text(verbatim: headline)
                    .font(DS.Font.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } actions: {
            // Running only, or stopped containers as well.
            DockerScopePicker(showAll: Bindable(viewModel).showAll)

            DSGlassIconButton("arrow.clockwise", help: "Refresh container list (⌘R)") {
                Task { await viewModel.loadContainers() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(viewModel.isLoading)
        }
    }

    // MARK: - Containers

    /// The table on a card, with the actions for the selected container floating over its end.
    private func containerCard(isCompact: Bool, width: CGFloat) -> some View {
        Group {
            if viewModel.containers.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    // Two tables with fixed columns each (Swift 6.0 has no conditional columns):
                    // at the minimum window width image and ports move under name and state.
                    if isCompact {
                        compactTable
                    } else {
                        wideTable(width: width)
                    }
                }
                .scrollContentBackground(.hidden)
                .focused($isTableFocused)
                // A click selects the row but does not make the table first responder here.
                .onChange(of: selection) { _, selected in
                    if selected != nil { isTableFocused = true }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    actionBar
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCard()
    }

    /// A table opens its columns at their ideal widths and does not share out what is left (nor
    /// shrink them when they do not fit — it scrolls sideways): the image column's ideal width is
    /// what the other columns leave of the card.
    private func wideTable(width: CGFloat) -> some View {
        // What the table's own insets and the gaps between five columns take.
        let room = width - 95
        let ports: CGFloat = room >= 560 ? 152 : 100
        // A name is short: what its column gives up lets an image with a registry path and a
        // tag show whole.
        let image = max(80, room - 16 - 76 - 146 - ports)
        return Table(viewModel.containers, selection: $selection) {
            TableColumn(Text(verbatim: "")) { container in
                stateMark(container)
            }
            .width(16)

            TableColumn("Name") { container in
                Text(verbatim: container.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .padding(.vertical, DS.Space.sm)
                    .help(details(container))
            }
            .width(min: 70, ideal: 76, max: 160)

            TableColumn("Image") { container in
                Text(verbatim: container.image)
                    .font(DS.Font.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 80, ideal: image)

            TableColumn("Ports") { container in
                ContainerPorts(labels: container.portLabels)
                    .help(container.ports)
            }
            .width(min: 70, ideal: ports, max: 200)

            TableColumn("Status") { container in
                Text(verbatim: container.status)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 146, max: 220)
        }
        .contextMenu(forSelectionType: DockerService.Container.ID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            openLogs(for: ids)
        }
    }

    private var compactTable: some View {
        Table(viewModel.containers, selection: $selection) {
            TableColumn(Text(verbatim: "")) { container in
                stateMark(container)
            }
            .width(16)

            TableColumn("Name") { container in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: container.name)
                        .fontWeight(.semibold)
                    Text(verbatim: container.image)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                .padding(.vertical, DS.Space.xs)
                .help(details(container))
            }
            .width(min: 110, ideal: 150)

            TableColumn("Status") { container in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: container.status)
                        .monospacedDigit()
                    // No published ports: no second line (not a dash).
                    if !container.portLabels.isEmpty {
                        Text(verbatim: container.portLabels.joined(separator: " "))
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(container.ports)
            }
            .width(min: 100, ideal: 140)
        }
        .contextMenu(forSelectionType: DockerService.Container.ID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            openLogs(for: ids)
        }
    }

    /// Running green, paused or restarting orange, anything else (created, exited) grey — the
    /// Status column says it in words. A spinner while a command for the container is out.
    @ViewBuilder
    private func stateMark(_ container: DockerService.Container) -> some View {
        if busy.contains(container.id) {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16)
        } else {
            DSStatusDot(color: stateColor(container), isPulsing: container.phase == .transitional)
                .shadow(color: stateColor(container).opacity(container.phase == .running ? 0.7 : 0), radius: 4)
                .frame(width: 16)
        }
    }

    private func stateColor(_ container: DockerService.Container) -> Color {
        switch container.phase {
        case .running: DS.Palette.success
        case .transitional: DS.Palette.warning
        case .stopped: DS.Palette.inactive
        }
    }

    /// Everything a row may have to truncate, for the tooltip.
    private func details(_ container: DockerService.Container) -> String {
        [container.name, container.image, container.status, container.ports]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isLoading || (!viewModel.hasLoaded && viewModel.error == nil) {
            DSDelayed { ProgressView() }
        } else if let error = viewModel.error {
            // Docker is missing, or this user may not use it: the host's own words, selectable.
            ContentUnavailableView {
                Label("Error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error)
                    .textSelection(.enabled)
            } actions: {
                Button("Retry") {
                    Task { await viewModel.loadContainers() }
                }
            }
        } else if viewModel.showAll {
            DSEmptyState("No Containers", message: "No containers on this host", page: .docker)
        } else {
            DSEmptyState("No Containers", message: "No running containers on this host", page: .docker) {
                Button("Show All") { viewModel.showAll = true }
                    .dsButtonStyle(.glass)
            }
        }
    }

    // MARK: - Actions

    /// The actions for the selected container, and its name: whom they act on. (Its state is in
    /// its row, right above.) Start and stop are both there, the one that does not apply
    /// disabled, so nothing moves under the pointer when the state changes.
    private var actionBar: some View {
        // With titles while they fit beside the name; the glyphs alone in a narrow card.
        ViewThatFits(in: .horizontal) {
            actionBar(showsTitles: true)
            actionBar(showsTitles: false)
        }
        .padding(.leading, 18)
        .padding(.trailing, DS.Space.card)
        .frame(height: 48)
        .dsFloatingBar()
        .padding(DS.Space.md)
    }

    private func actionBar(showsTitles: Bool) -> some View {
        let container = selected
        let isBusy = container.map { busy.contains($0.id) } ?? false
        let isRunning = container?.isRunning ?? false
        return HStack(spacing: DS.Space.xxs) {
            if let container {
                Text(verbatim: container.name)
                    .font(DS.Font.rowTitle)
                    .lineLimit(1)
                    // What "fits" is judged with a short name: a long one truncates before
                    // the buttons lose their titles.
                    .frame(idealWidth: 64, alignment: .leading)
            } else {
                Text("Select a container")
                    .font(DS.Font.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.sm)
            Group {
                barButton("Start", symbol: "play", isDisabled: container == nil || isRunning || isBusy) { container in
                    run(container) { await viewModel.startContainer(container.id) }
                }
                barButton("Stop", symbol: "stop", isDisabled: container == nil || !isRunning || isBusy) { container in
                    run(container) { await viewModel.stopContainer(container.id) }
                }
                barButton("Restart", symbol: "arrow.clockwise", isDisabled: container == nil || isBusy) { container in
                    run(container) { await viewModel.restartContainer(container.id) }
                }
                barDivider
                barButton("Remove", symbol: "trash", role: .destructive, isDisabled: container == nil || isBusy) { container in
                    askToRemove(container)
                }
                barDivider
            }
            .labelStyle(BarLabelStyle(isCompact: !showsTitles))

            Button {
                if let container { Task { await viewModel.showLogs(for: container.id) } }
            } label: {
                Label("Logs", systemImage: "doc.text")
            }
            .dsButtonStyle(.prominent, size: .small)
            .disabled(container == nil)
        }
    }

    private func barButton(_ title: LocalizedStringKey, symbol: String, role: ButtonRole? = nil, isDisabled: Bool,
                           action: @escaping (DockerService.Container) -> Void) -> some View {
        Button(role: role) {
            if let container = selected { action(container) }
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, DS.Space.sm)
                .frame(height: DS.Height.control)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive && !isDisabled ? AnyShapeStyle(DS.Palette.danger) : AnyShapeStyle(.primary))
        .disabled(isDisabled)
        .help(title)
    }

    private var barDivider: some View {
        Rectangle()
            .fill(DS.Palette.separator)
            .frame(width: 1, height: 18)
            .padding(.horizontal, DS.Space.xs)
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<DockerService.Container.ID>) -> some View {
        if let container = container(for: ids) {
            let isBusy = busy.contains(container.id)
            if container.isRunning {
                Button { run(container) { await viewModel.stopContainer(container.id) } } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(isBusy)
            } else {
                Button { run(container) { await viewModel.startContainer(container.id) } } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(isBusy)
            }
            Button { run(container) { await viewModel.restartContainer(container.id) } } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .disabled(isBusy)
            Button { Task { await viewModel.showLogs(for: container.id) } } label: {
                Label("Logs", systemImage: "doc.text")
            }
            Divider()
            Button { copy(container.name) } label: {
                Label("Copy Name", systemImage: "doc.on.doc")
            }
            Button { copy(container.id) } label: {
                Label("Copy Container ID", systemImage: "number")
            }
            Divider()
            Button(role: .destructive) { askToRemove(container) } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(isBusy)
        }
    }

    private func container(for ids: Set<DockerService.Container.ID>) -> DockerService.Container? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return viewModel.containers.first { $0.id == id }
    }

    /// Double-click: the container's logs.
    private func openLogs(for ids: Set<DockerService.Container.ID>) {
        guard let container = container(for: ids) else { return }
        Task { await viewModel.showLogs(for: container.id) }
    }

    private func askToRemove(_ container: DockerService.Container) {
        containerToRemoveName = container.name
        containerToRemove = container.id
    }

    /// Start, stop, restart: one at a time per container. Its row shows the command as pending
    /// until the host answers.
    private func run(_ container: DockerService.Container, _ action: @escaping () async -> Void) {
        guard !busy.contains(container.id) else { return }
        busy.insert(container.id)
        Task {
            await action()
            busy.remove(container.id)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Title and icon while the bar has room, the icon alone when it has not (the title is
/// the button's tooltip and accessibility label either way).
private struct BarLabelStyle: LabelStyle {
    let isCompact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if isCompact {
            configuration.icon
        } else {
            HStack(spacing: 5) {
                configuration.icon
                configuration.title
            }
        }
    }
}

/// The published ports of a container: up to two chips and "+N" — fewer when the column is
/// narrow. Nothing for a container that publishes none.
private struct ContainerPorts: View {
    let labels: [String]

    var body: some View {
        if !labels.isEmpty {
            ViewThatFits(in: .horizontal) {
                chips(2)
                chips(1)
                Text(verbatim: labels.joined(separator: " "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Ports"))
            .accessibilityValue(Text(verbatim: labels.joined(separator: ", ")))
        }
    }

    private func chips(_ count: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(labels.prefix(count), id: \.self) { label in
                DSChip(verbatim: label, isMonospaced: true)
            }
            if labels.count > count {
                Text(verbatim: "+\(labels.count - count)")
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}

// MARK: - Container Logs Sheet

struct ContainerLogsSheet: View {
    /// Nil when the container is no longer in the list.
    var containerName: String?
    let containerId: String
    let output: String
    /// The logs were asked for and the host has not answered yet.
    var isLoading = false
    /// Why the logs could not be read.
    var error: String?
    var isEmbeddedInInspector: Bool = false
    var onCancel: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private static let logContentID = "logContent"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logs")
                        .font(.headline)
                    Text(verbatim: containerName.map { "\($0) · \(containerId)" } ?? containerId)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: DS.Space.md)

                DSCopyButton("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .disabled(output.isEmpty)

                if isEmbeddedInInspector {
                    DSRowButton("arrow.right.to.line", help: "Close Logs", action: cancel)
                }
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.md)

            Divider()

            logBody
                .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: isEmbeddedInInspector ? nil : 680, height: isEmbeddedInInspector ? nil : 460)
        .frame(maxWidth: isEmbeddedInInspector ? .infinity : nil, maxHeight: isEmbeddedInInspector ? .infinity : nil)
        .toolbar {
            if !isEmbeddedInInspector {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { cancel() }
                }
            }
        }
        .onExitCommand { cancel() }
    }

    private func cancel() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    /// Loading, failed, or the logs: only the logs are set as log text.
    @ViewBuilder
    private var logBody: some View {
        if isLoading {
            // A host whose connection is open answers within a moment: no flash.
            DSDelayed { ProgressView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView {
                Label("Couldn't Load Logs", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    logText
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.xl)
                        .padding(.vertical, DS.Space.lg)
                        .id(Self.logContentID)
                }
                // The logs are there when this appears: start at the newest lines.
                .onChange(of: output, initial: true) { _, _ in
                    proxy.scrollTo(Self.logContentID, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var logText: some View {
        if output.isEmpty {
            Text("(no output)")
                .foregroundStyle(.tertiary)
        } else {
            Text(verbatim: output)
        }
    }
}

// MARK: - Running | All

/// Running or all containers: two words in one glass capsule, the chosen one on a neutral
/// plate. The system's segmented control fills the chosen segment with the accent, which on
/// this page belongs to Logs alone.
private struct DockerScopePicker: View {
    @Binding var showAll: Bool

    var body: some View {
        HStack(spacing: 2) {
            segment("Running", value: false)
            segment("All", value: true)
        }
        .padding(3)
        .frame(height: DS.Height.control)
        .dsGlass(.capsule)
        .fixedSize()
        // One control with two values for VoiceOver and the keyboard, as the picker it replaces.
        .accessibilityRepresentation {
            Picker("Containers", selection: $showAll) {
                Text("Running").tag(false)
                Text("All").tag(true)
            }
        }
    }

    private func segment(_ title: LocalizedStringKey, value: Bool) -> some View {
        let isChosen = showAll == value
        return Button {
            showAll = value
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isChosen ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                .lineLimit(1)
                .padding(.horizontal, DS.Space.md)
                .frame(maxHeight: .infinity)
                .background {
                    if isChosen {
                        Capsule().fill(DS.Palette.chip)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
