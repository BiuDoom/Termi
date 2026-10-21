import SwiftUI

/// Snippets page — saved commands. Master: the snippets by category (search, category filter).
/// Detail: the command as it will be typed, the values of its {{variables}}, and where to run
/// it.
struct SnippetsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = SnippetsViewModel()
    @State private var selectedId: Int64?
    /// A row to bring into view (its id is the row's `.id`).
    @State private var scrollTarget: Int64?

    private var canRun: Bool {
        appViewModel.focusedSession?.isLive == true
    }

    /// The ids in the order the master list shows them.
    private var order: [Int64] {
        viewModel.sections.flatMap { $0.snippets.compactMap(\.id) }
    }

    private var selectedSnippet: Snippet? {
        guard let selectedId else { return nil }
        return viewModel.filteredSnippets.first { $0.id == selectedId }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.error, !viewModel.snippets.isEmpty {
                OpsErrorBanner(message: error) { viewModel.error = nil }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsStageBackground()
        .searchable(text: $viewModel.searchText, prompt: "Search snippets")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.addNew()
                } label: {
                    Label("Add Snippet", systemImage: "plus")
                }
                .help("Add a new snippet")
            }
        }
        .task {
            await viewModel.loadSnippets()
            await appViewModel.ensureHostsLoaded()
            #if DEBUG
            applyDebugLaunchArguments()
            #endif
            syncSelection()
        }
        .onChange(of: viewModel.categories) { _, categories in
            // A filter on a category that no longer exists would hide every snippet.
            if let selected = viewModel.selectedCategory, !categories.contains(selected) {
                viewModel.selectedCategory = nil
            }
        }
        .onChange(of: order) { _, _ in syncSelection() }
        .onChange(of: DSReveal.shared.target) { _, _ in syncSelection() }
        .onChange(of: viewModel.addedSnippetId) { _, added in
            guard let added else { return }
            viewModel.addedSnippetId = nil
            select(added)
        }
        .alert("Delete Snippet", isPresented: $viewModel.showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let snippet = viewModel.snippetToDelete {
                    Task { await viewModel.deleteSnippet(snippet) }
                }
            }
        } message: {
            if let snippet = viewModel.snippetToDelete {
                Text("Delete \"\(snippet.name)\"? This cannot be undone.")
            }
        }
    }

    /// How many snippets a search left; nothing otherwise (the total is the rows themselves,
    /// or the "All" filter's count).
    private var subtitle: Text {
        guard !viewModel.searchText.isEmpty, !viewModel.snippets.isEmpty else { return Text(verbatim: "") }
        return Text("\(viewModel.filteredSnippets.count) matches")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                mainStage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.showingForm {
                HStack(spacing: 0) {
                    Divider()
                    SnippetFormSheet(
                        viewModel: viewModel,
                        snippet: viewModel.editingSnippet,
                        isEmbeddedInInspector: true,
                        onCancel: { viewModel.showingForm = false }
                    )
                    .id(viewModel.editingSnippet?.id ?? -1)
                }
                .frame(width: DS.Layout.inspectorWidth + 1)
                .frame(maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.standard, value: viewModel.showingForm)
        .clipped()
    }

    @ViewBuilder
    private var mainStage: some View {
        // Nothing until the first read is over: it is too quick for a spinner, and the
        // empty state must not flash before the snippets.
        if !viewModel.hasLoaded {
            Color.clear
        } else if viewModel.snippets.isEmpty {
            if let error = viewModel.error {
                errorState(error)
            } else {
                emptyState
            }
        } else {
            if !viewModel.categories.isEmpty {
                filterBar
            }
            if viewModel.filteredSnippets.isEmpty {
                if viewModel.searchText.isEmpty {
                    ContentUnavailableView.search
                } else {
                    ContentUnavailableView.search(text: viewModel.searchText)
                }
            } else {
                DSMasterDetail {
                    master
                } detail: {
                    detail
                }
            }
        }
    }

    // MARK: - Category filter

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            DSGlassContainer(spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.sm) {
                    DSFilterChip("All", count: viewModel.snippets.count, isSelected: viewModel.selectedCategory == nil) {
                        viewModel.selectedCategory = nil
                    }
                    ForEach(viewModel.categories, id: \.self) { category in
                        DSFilterChip(verbatim: category, count: viewModel.count(inCategory: category),
                                     isSelected: viewModel.selectedCategory == category) {
                            viewModel.selectedCategory = category
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.xs)
            .padding(.bottom, DS.Space.md)
        }
    }

    // MARK: - Master

    private var master: some View {
        // The list scrolls by itself for the arrow keys only: a selection made elsewhere (a
        // snippet just added, one another page asked for) is brought into view from here.
        ScrollViewReader { proxy in
            masterList
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    scrollTarget = nil
                    withAnimation(DS.Motion.standard) { proxy.scrollTo(target) }
                }
        }
    }

    private var masterList: some View {
        DSMasterList(selection: $selectedId, order: order) {
            ForEach(viewModel.sections) { section in
                // A category's count is on its filter above; the header repeats it only when
                // a search left fewer.
                if let title = section.title {
                    DSListSectionHeader(verbatim: title, count: viewModel.headerCount(for: section))
                } else if viewModel.sections.count > 1 {
                    DSListSectionHeader("Uncategorized", count: viewModel.headerCount(for: section))
                }
                ForEach(section.snippets) { snippet in
                    SnippetRowView(snippet: snippet)
                        .dsListRow(isSelected: selectedId == snippet.id, height: 50)
                        .id(snippet.id ?? -1)
                        .onTapGesture { selectedId = snippet.id }
                        .accessibilityAction { selectedId = snippet.id }
                        .accessibilityAction(named: "Copy Command") { viewModel.copyCommand(snippet) }
                        .accessibilityAction(named: "Edit") { viewModel.edit(snippet) }
                        .accessibilityAction(named: "Delete") { askToDelete(snippet) }
                        .contextMenu {
                            Button {
                                run(snippet)
                            } label: {
                                Label("Run in terminal", systemImage: "play.fill")
                            }
                            .disabled(!canRun)
                            Button {
                                viewModel.copyCommand(snippet)
                            } label: {
                                Label("Copy Command", systemImage: "doc.on.doc")
                            }
                            Divider()
                            Button {
                                viewModel.edit(snippet)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                askToDelete(snippet)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .padding(.top, DS.Space.xs)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let snippet = selectedSnippet {
            SnippetDetailView(snippet: snippet, viewModel: viewModel) {
                askToDelete(snippet)
            }
            // A new detail per snippet: the values typed for one are not another's.
            .id(snippet.id)
            .transition(.opacity)
        } else {
            Color.clear
        }
    }

    // MARK: - Empty / error

    private var emptyState: some View {
        DSEmptyState("No Snippets", message: "Save the commands you type often, and leave blanks with {{variables}}.",
                     page: .snippets) {
            Button("New Snippet", systemImage: "plus") {
                viewModel.addNew()
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
                Task {
                    viewModel.error = nil
                    await viewModel.loadSnippets()
                }
            }
        }
    }

    // MARK: - Helpers

    private func askToDelete(_ snippet: Snippet) {
        viewModel.snippetToDelete = snippet
        viewModel.showingDeleteConfirm = true
    }

    /// Keeps one snippet selected: the one another page asked for, else the one that was, else
    /// the first.
    private func syncSelection() {
        if let revealed = appViewModel.takeReveal(for: .snippets).flatMap({ Int64($0) }),
           viewModel.snippets.contains(where: { $0.id == revealed }) {
            select(revealed)
            return
        }
        if let selectedId, order.contains(selectedId) { return }
        selectedId = order.first
    }

    /// Selects a snippet that exists and brings its row into view.
    private func select(_ id: Int64) {
        // It may be hidden by the search or the category filter.
        if SnippetsViewModel.filtersHide(id, shown: order, all: viewModel.snippets.compactMap(\.id)) {
            viewModel.searchText = ""
            viewModel.selectedCategory = nil
        }
        selectedId = id
        scrollTarget = id
    }

    /// Run in the window's focused terminal (snippets with {{variables}} open the snippet panel).
    private func run(_ snippet: Snippet) {
        appViewModel.selectedSidebar = .terminal
        appViewModel.isViewingTerminal = true
        if SnippetTemplate.placeholders(in: snippet.command).isEmpty {
            appViewModel.runSnippet(snippet.command, execute: true)
        } else {
            // The inspector remembers its last tab: asked for a snippet, it shows the snippets.
            AppProfile.defaults.set(SnippetPanelView.InspectorTab.snippets.rawValue, forKey: "terminalInspectorTab")
            appViewModel.showSnippetPanel = true
        }
    }

    #if DEBUG
    /// `-debugSnippet <name>` selects a snippet; `-debugSnippetSessions local[,<host label>]`
    /// opens sessions behind the page so that "Run In" has rows. For screenshots.
    private func applyDebugLaunchArguments() {
        let defaults = AppProfile.arguments
        if let name = defaults.string(forKey: "debugSnippet"),
           let id = viewModel.snippets.first(where: { $0.name == name })?.id {
            selectedId = id
        }
        if let labels = defaults.string(forKey: "debugSnippetSessions") {
            for label in labels.split(separator: ",") {
                if label == "local" {
                    appViewModel.addLocalTerminalTab()
                } else if let host = appViewModel.hostsPage.hosts.first(where: { $0.label == label }) {
                    appViewModel.connect(to: host)
                }
            }
            // Opening a tab shows the terminal: back to this page within the same update.
            appViewModel.selectedSidebar = .snippets
            appViewModel.isViewingTerminal = false
        }
    }
    #endif
}

// MARK: - Snippet Row

/// A snippet in the master list: its name over the first line of its command, and how many
/// values it asks for.
struct SnippetRowView: View {
    let snippet: Snippet
    @Environment(\.dsIsSelected) private var isSelected

    var body: some View {
        let variables = SnippetTemplate.placeholders(in: snippet.command).count

        HStack(spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: snippet.name)
                    .font(DS.Font.rowTitle)
                    .lineLimit(1)
                Text(verbatim: SnippetsViewModel.firstLine(of: snippet.command))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: DS.Space.xs)
            if variables > 0 {
                // On the selected row the accent glyph would vanish into the accent pill.
                DSChip(verbatim: variables.formatted(), symbol: "curlybraces", tint: isSelected ? nil : DS.Palette.accent)
                    .fixedSize()
                    .help("Asks for these values when it runs")
                    // One element: a label on the bare chip lands on its glyph and on its text.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(variables) variables"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

/// One snippet: what it is, its command with the values filled in (what will be typed), the
/// values, the sessions it can run in — when there is a choice — and the hosts that run it
/// when they connect.
private struct SnippetDetailView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let snippet: Snippet
    let viewModel: SnippetsViewModel
    let onDelete: () -> Void

    @State private var values: [String: String] = SnippetDetailView.initialValues
    /// The variable whose field has the keyboard: the field draws its own focus ring.
    @FocusState private var focusedVariable: String?

    /// `-debugSnippetValues name=world,lines=200` (debug builds): values for screenshots.
    private static var initialValues: [String: String] {
        #if DEBUG
        if let pairs = AppProfile.arguments.string(forKey: "debugSnippetValues") {
            var values: [String: String] = [:]
            for pair in pairs.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { values[parts[0]] = parts[1] }
            }
            return values
        }
        #endif
        return [:]
    }

    private var placeholders: [String] {
        SnippetTemplate.placeholders(in: snippet.command)
    }

    /// What is typed into the terminal.
    private var rendered: String {
        placeholders.isEmpty ? snippet.command : SnippetTemplate.render(snippet.command, values: values)
    }

    private var canRun: Bool {
        appViewModel.focusedSession?.isLive == true
    }

    /// Every variable has a value: a command with a hole in it is never typed into a shell.
    private var isComplete: Bool {
        SnippetTemplate.missingValues(in: snippet.command, values: values).isEmpty
    }

    /// The category alone: the variables are the section below.
    private var subtitle: String {
        snippet.category ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                header
                if let description = snippet.description, !description.isEmpty {
                    Text(verbatim: description)
                        .font(DS.Font.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                let targets = runTargets
                // One block: the template with the values typed below filled in — what is
                // sent, and what its copy button copies ("…" copies the template).
                VStack(alignment: .leading, spacing: 0) {
                    DSSectionHeader("Command") {
                        // With several sessions the list below says (and chooses) where.
                        if !SnippetsViewModel.showsRunTargets(sessionCount: targets.count), canRun,
                           let title = appViewModel.activeTab?.title {
                            Text("Will be sent to \(title)")
                        }
                    }
                    DSCodeBlock(template: snippet.command, values: values, prompt: "$")
                }
                if !placeholders.isEmpty {
                    section("Variables") {
                        variables
                    }
                }
                if SnippetsViewModel.showsRunTargets(sessionCount: targets.count) {
                    section("Run In") {
                        targetList(targets)
                    }
                } else if !canRun {
                    // Nothing open, or the one session has ended: the header's Run is off and
                    // no row says why.
                    section("Run In") {
                        DSGroup { connectFirstRow }
                    }
                }
                if !startupHosts.isEmpty {
                    section("Startup Snippet For") {
                        DSGroup {
                            ForEach(startupHosts, id: \.connectionKey) { host in
                                DSLinkRow(host: host, status: appViewModel.avatarStatus(forHostId: host.id)) {
                                    appViewModel.reveal(host: host)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.top, DS.Space.sm)
            .padding(.bottom, DS.Space.xl)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader(title)
            content()
        }
    }

    // MARK: Header

    private var header: some View {
        DSDetailHeader(title: snippet.name) {
            DSCategoryTile("curlybraces", size: DS.Tile.header)
        } accessory: {
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(DS.Font.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } actions: {
            Button("Run", systemImage: "play") {
                run()
            }
            .dsButtonStyle(.prominent)
            .disabled(!canRun || !isComplete)
            .help(!canRun ? "Connect to a host first"
                  : isComplete ? "Run in the focused terminal" : "Fill in every variable first")
            Button("Edit") {
                viewModel.edit(snippet)
            }
            .dsButtonStyle(.glass)
            DSGlassIconMenu {
                Button {
                    viewModel.copyCommand(snippet)
                } label: {
                    Label("Copy Command", systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: Variables

    private var variables: some View {
        // One column for the names: as wide as the longest, within reason.
        let longest = placeholders.map(\.count).max() ?? 0
        let nameWidth = min(max(CGFloat(longest) * 7.5 + 4, 44), 150)
        return DSGroup {
            ForEach(placeholders, id: \.self) { name in
                DSRow {
                    Text(verbatim: name)
                        .font(DS.Font.mono.weight(.semibold))
                        .truncationMode(.middle)
                        .frame(width: nameWidth, alignment: .leading)
                    variableField(name)
                }
            }
        }
    }

    /// A value's field: a well in the row, as high as the row's other controls.
    private func variableField(_ name: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
        let isFocused = focusedVariable == name
        return TextField(text: value(for: name)) {
            Text(verbatim: name)
        }
        .textFieldStyle(.plain)
        .font(DS.Font.mono)
        .autocorrectionDisabled()
        .focused($focusedVariable, equals: name)
        .padding(.horizontal, DS.Space.card)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06), in: shape)
        .overlay {
            shape.strokeBorder(isFocused ? DS.Palette.accent.opacity(0.7) : Color.primary.opacity(0.1),
                               lineWidth: isFocused ? 2 : 1)
        }
    }

    private func value(for name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    // MARK: Run In

    /// An open terminal tab the snippet can be typed into.
    private struct Target: Identifiable {
        let id: UUID
        let title: String
        let detail: String
        let host: Host?
        let status: DSHostAvatar.Status
        let isCurrent: Bool
        let isLive: Bool
    }

    private var runTargets: [Target] {
        appViewModel.tabs.map { tab in
            let host = tab.hostId.flatMap { id in appViewModel.hostsPage.hosts.first { $0.id == id } } ?? tab.adHocHost
            let sessions = tab.panes.compactMap { appViewModel.existingSession(for: $0.id) }
            var detail: [String] = []
            if let host {
                detail.append(host.addressDescription)
            } else {
                // A local tab has no address: its shell says what the command will be typed into.
                detail.append(TerminalSession.localShellName)
            }
            if tab.isSplit { detail.append(String(localized: "\(tab.panes.count) panes")) }
            return Target(id: tab.id, title: tab.title, detail: detail.joined(separator: " · "), host: host,
                          status: DSHostAvatar.Status(states: sessions.map(\.state)),
                          isCurrent: tab.id == appViewModel.activeTabId,
                          isLive: appViewModel.existingSession(for: tab.focusedPaneId)?.isLive == true)
        }
    }

    /// No terminal to type into: why Run is off, and the way out.
    private var connectFirstRow: some View {
        DSRow {
            Text("Connect to a host first")
                .foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.sm)
            Button("Show Hosts") {
                appViewModel.selectedSidebar = .terminal
            }
            .dsButtonStyle(.glass, size: .small)
        }
    }

    private func targetList(_ targets: [Target]) -> some View {
        DSGroup {
            ForEach(targets) { target in
                DSRow {
                    if let host = target.host {
                        DSHostAvatar(host, size: 22, status: target.status)
                    } else {
                        DSHostAvatar.local(size: 22, status: target.status)
                    }
                    Text(verbatim: target.title)
                        .font(DS.Font.rowTitle)
                        .layoutPriority(1)
                    if target.isCurrent {
                        Text("Current")
                            .font(DS.Font.chip.weight(.semibold))
                            .foregroundStyle(DS.Palette.accent)
                            .fixedSize()
                    }
                    Text(verbatim: target.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                    Spacer(minLength: DS.Space.xs)
                    Button("Run", systemImage: "play") {
                        run(in: target)
                    }
                    .dsButtonStyle(.glass, size: .small)
                    .fixedSize()
                    .disabled(!target.isLive || !isComplete)
                    .help(isComplete ? "" : "Fill in every variable first")
                    .accessibilityLabel(Text("Run in \(target.title)"))
                }
            }
        }
    }

    /// Hosts that run this snippet when they connect.
    private var startupHosts: [Host] {
        guard let id = snippet.id else { return [] }
        return appViewModel.hostsPage.hosts.filter { $0.startupSnippetId == id }
    }

    // MARK: Actions

    /// Type the command, with the values above, into the focused terminal and show it.
    private func run() {
        guard isComplete else { return }
        appViewModel.selectedSidebar = .terminal
        appViewModel.isViewingTerminal = true
        appViewModel.runSnippet(rendered, execute: true)
    }

    private func run(in target: Target) {
        guard isComplete else { return }
        appViewModel.activateTab(target.id)
        appViewModel.runSnippet(rendered, execute: true)
    }
}

// MARK: - Snippet Form Sheet

struct SnippetFormSheet: View {
    let viewModel: SnippetsViewModel
    let snippet: Snippet?
    var isEmbeddedInInspector: Bool = false
    var onCancel: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var command = ""
    @State private var description = ""
    @State private var category = ""

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Group {
            if isEmbeddedInInspector {
                DSInspectorPanel(
                    snippet == nil ? "New Snippet" : "Edit Snippet",
                    onClose: cancel
                ) {
                    VStack(alignment: .leading, spacing: DS.Space.lg) {
                        DSGroup {
                            DSRow {
                                DSKeyLabel("Name")
                                TextField("Name", text: $name)
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                            }
                            DSRow {
                                DSKeyLabel("Category")
                                TextField("Category", text: $category, prompt: Text("Optional"))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                            }
                            DSRow {
                                DSKeyLabel("Description")
                                TextField("Description", text: $description, prompt: Text("Optional"))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                            }
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            DSSectionHeader("Command")
                            DSGroup {
                                TextEditor(text: $command)
                                    .font(.body.monospaced())
                                    .autocorrectionDisabled()
                                    .scrollContentBackground(.hidden)
                                    .scrollDisabled(false)
                                    .frame(height: 140)
                                    .padding(DS.Space.sm)
                                    .accessibilityLabel("Command")
                            }
                            Text("Use {{name}} for values you fill in when the snippet runs, e.g. tail -f {{logfile}}")
                                .font(DS.Font.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, DS.Space.xs)
                        }
                    }
                } footer: {
                    HStack(spacing: DS.Space.sm) {
                        Spacer(minLength: 0)
                        Button("Cancel") { cancel() }
                            .keyboardShortcut(.cancelAction)
                            .dsButtonStyle(.glass)
                        Button(snippet == nil ? "Add" : "Save", action: save)
                            .keyboardShortcut(.defaultAction)
                            .dsButtonStyle(.prominent)
                            .disabled(!isValid)
                    }
                }
            } else {
                Form {
                    Section {
                        TextField("Name", text: $name)
                        TextField("Category", text: $category, prompt: Text("Optional"))
                        TextField("Description", text: $description, prompt: Text("Optional"))
                    } header: {
                        if snippet == nil {
                            DSSheetTitle("New Snippet")
                        } else {
                            DSSheetTitle("Edit Snippet")
                        }
                    }

                    Section {
                        TextEditor(text: $command)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .scrollContentBackground(.hidden)
                            .scrollDisabled(false)
                            .frame(height: 120)
                            .accessibilityLabel("Command")
                    } header: {
                        Text("Command")
                    } footer: {
                        Text("Use {{name}} for values you fill in when the snippet runs, e.g. tail -f {{logfile}}")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 520)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { cancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: save) {
                            if snippet == nil {
                                Text("Add")
                            } else {
                                Text("Save")
                            }
                        }
                        .disabled(!isValid)
                    }
                }
            }
        }
        .onAppear {
            if let s = snippet {
                name = s.name
                command = s.command
                description = s.description ?? ""
                category = s.category ?? ""
            }
        }
    }

    private func cancel() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    private func save() {
        Task {
            var s = snippet ?? Snippet(
                name: "",
                command: "",
                sortOrder: 0,
                createdAt: ""
            )
            s.name = name.trimmingCharacters(in: .whitespaces)
            s.command = command.trimmingCharacters(in: .whitespaces)
            s.description = description.isEmpty ? nil : description
            s.category = category.isEmpty ? nil : category
            await viewModel.save(s)
            cancel()
        }
    }
}
