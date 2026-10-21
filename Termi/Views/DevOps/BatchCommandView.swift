import SwiftUI

/// Batch command — tick hosts (leading column), write a command (top of the trailing column),
/// run it on all of them and read what came back: how the run went, then the answers host
/// by host or grouped by what they said.
struct BatchCommandView: View {
    @Environment(AppViewModel.self) private var appViewModel

    private var viewModel: BatchCommandViewModel { appViewModel.batchCommand }
    @State private var didLoadHosts = false
    @State private var resultMode: ResultMode = .byHost
    /// Rows the user opened or closed; the others follow `BatchResultRow.opensByDefault`.
    @State private var expansion: [UUID: Bool] = [:]

    private enum ResultMode: Hashable {
        case byHost, byOutput
    }

    var body: some View {
        content
            .task {
                await viewModel.loadHosts()
                didLoadHosts = true
                await appViewModel.ensureHostsLoaded()
                await viewModel.loadSnippets()
                #if DEBUG
                await applyDebugLaunchArguments()
                #endif
            }
            // A host's tile shows its system, which is read after it connects.
            .onReceive(NotificationCenter.default.publisher(for: .dsDataChanged)) { _ in
                Task { await viewModel.loadHosts() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if didLoadHosts && viewModel.allHosts.isEmpty {
            // loadHosts does not clear the error it left: without this a successful retry would
            // still show it.
            DevOpsNoHostsView(error: viewModel.error, onRetry: {
                viewModel.error = nil
                Task { await viewModel.loadHosts() }
            })
        } else {
            DSMasterDetail(sizing: .fixedMaster(width: 260, compactWidth: 220)) {
                hostColumn
            } detail: {
                commandColumn
            }
            .dsStageBackground()
            // Both columns begin with a fixed row, not a scroll view, and the system then draws
            // an opaque band behind the toolbar. An empty scroll view at the top edge (always
            // "at its top") keeps the toolbar clear, like on the other pages.
            .background(alignment: .top) {
                ScrollView {}
                    .frame(height: 1)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Hosts (leading column)

    private var hostColumn: some View {
        let sections = BatchCommandViewModel.hostSections(hosts: viewModel.allHosts,
                                                          groups: appViewModel.hostsPage.allGroups)
        return VStack(spacing: 0) {
            // In the column of the rows' checkboxes. How many are ticked is said once, next
            // to Run.
            selectAllToggle
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.card * 2)
                .frame(height: 34)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        // One untitled section = no groups at all: no header.
                        if sections.count > 1 || section.title != nil {
                            sectionHeader(section)
                        }
                        ForEach(section.hosts, id: \.connectionKey) { host in
                            BatchHostRow(host: host, status: appViewModel.avatarStatus(forHostId: host.id),
                                         isOn: isSelected(host))
                        }
                    }
                }
                .padding(.horizontal, DS.Space.card)
                .padding(.bottom, DS.Space.sm)
            }
        }
    }

    private func sectionHeader(_ section: BatchCommandViewModel.HostSection) -> some View {
        let title = section.title ?? String(localized: "Ungrouped")
        return HStack(spacing: DS.Space.sm) {
            Text(verbatim: title)
                .font(DS.Font.sectionHeader)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            // Ticked, empty, or a dash when only some of the group are.
            Toggle(sources: section.hosts.map { isSelected($0) }, isOn: \.self) {
                Text(verbatim: title)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help("Select All")
        }
        .padding(.horizontal, DS.Space.card)
        .frame(height: DS.Height.sectionHeader)
    }

    /// Ticks every host, or clears the ticks once they all are; a dash when only some are.
    /// The checkbox shows a dash when its sources disagree: "all are ticked" and "any is
    /// ticked" disagree exactly then. Only the first one acts when the box is clicked.
    private var selectAllToggle: some View {
        let hosts = viewModel.allHosts.count
        let ticked = viewModel.selectedHosts.count
        let all = Binding(get: { hosts > 0 && ticked == hosts },
                          set: { isOn in
                              if isOn { viewModel.selectAllHosts() } else { viewModel.deselectAllHosts() }
                          })
        let any = Binding(get: { ticked > 0 }, set: { _ in })
        return Toggle(sources: [all, any], isOn: \.self) {
            Text("Select All")
                .font(DS.Font.body)
                .padding(.leading, DS.Space.xs)
        }
        .toggleStyle(.checkbox)
        .accessibilityValue(Text("\(ticked) of \(hosts) selected"))
    }

    private func isSelected(_ host: Host) -> Binding<Bool> {
        Binding(
            get: { host.id.map { viewModel.selectedHostIds.contains($0) } ?? false },
            set: { isOn in
                guard let id = host.id else { return }
                if isOn {
                    viewModel.selectedHostIds.insert(id)
                } else {
                    viewModel.selectedHostIds.remove(id)
                }
            }
        )
    }

    // MARK: - Command + results (trailing column)

    private var hasRun: Bool {
        !viewModel.results.isEmpty || viewModel.isExecuting
    }

    private var commandColumn: some View {
        VStack(spacing: DS.Space.md + 2) {
            VStack(spacing: DS.Space.md + 2) {
                if let error = viewModel.error {
                    DSMessage(verbatim: error)
                }
                commandEditor
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.md)

            if hasRun {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.md + 2) {
                        summaryCard
                        resultControls
                        switch resultMode {
                        case .byHost: resultsByHost
                        case .byOutput: resultsByOutput
                        }
                    }
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.bottom, DS.Space.xl)
                }
            } else {
                emptyState
            }
        }
    }

    // MARK: Editor

    private var commandEditor: some View {
        // The hosts Run will reach — not the ticks, which could name a host that is gone.
        let count = viewModel.selectedHosts.count

        return VStack(spacing: 0) {
            TextEditor(text: Bindable(viewModel).command)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(.horizontal, DS.Space.card)
                .padding(.top, DS.Space.md)
                .frame(height: 66)
                .accessibilityLabel(Text("Command"))
                .overlay(alignment: .topLeading) {
                    if viewModel.command.isEmpty {
                        Text("Command")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            // Where the editor draws its first character.
                            .padding(.leading, DS.Space.card + 5)
                            .padding(.top, DS.Space.md)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }

            HStack(spacing: DS.Space.sm) {
                // Too narrow for the titles: the menus keep their glyphs.
                ViewThatFits(in: .horizontal) {
                    editorFooter(count: count, showsTitles: true)
                    editorFooter(count: count, showsTitles: false)
                }

                Button {
                    Task { await viewModel.execute() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play")
                        Text("Run")
                        Text(verbatim: "⌘↩")
                            .fontWeight(.medium)
                            .opacity(0.8)
                            .accessibilityHidden(true)
                    }
                }
                .dsButtonStyle(.prominent)
                .fixedSize()
                .keyboardShortcut(.return, modifiers: .command)
                .help("Run command on selected hosts (⌘↩)")
                .disabled(!canRun)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.top, DS.Space.card)
            .padding(.bottom, DS.Space.md)
        }
        .dsCard()
    }

    private func editorFooter(count: Int, showsTitles: Bool) -> some View {
        HStack(spacing: DS.Space.sm) {
            Menu {
                ForEach(viewModel.commandHistory, id: \.self) { command in
                    Button {
                        viewModel.command = command
                    } label: {
                        Text(verbatim: command)
                    }
                }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .modifier(EditorMenuStyle(showsTitle: showsTitles))
            .disabled(viewModel.commandHistory.isEmpty)
            .help("Commands run before")

            Menu {
                ForEach(viewModel.snippets) { snippet in
                    // A batch has no place to fill variables in: a template would be run with
                    // its {{braces}} on every ticked host. Such snippets are listed, not offered.
                    let needsValues = !SnippetTemplate.placeholders(in: snippet.command).isEmpty
                    Button {
                        viewModel.insert(snippet)
                    } label: {
                        if needsValues {
                            Text("\(snippet.name) — has variables")
                        } else {
                            Text(verbatim: snippet.name)
                        }
                    }
                    .disabled(needsValues)
                }
            } label: {
                Label("Snippets", systemImage: "curlybraces")
            }
            .modifier(EditorMenuStyle(showsTitle: showsTitles))
            .disabled(viewModel.snippets.isEmpty)
            .help("Insert a saved snippet")

            Spacer(minLength: DS.Space.sm)

            Text("On \(count) hosts")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private struct EditorMenuStyle: ViewModifier {
        let showsTitle: Bool

        func body(content: Content) -> some View {
            if showsTitle {
                content
                    .labelStyle(.titleAndIcon)
                    .dsButtonStyle(.glass, size: .small)
                    .fixedSize()
            } else {
                content
                    .labelStyle(.iconOnly)
                    .dsButtonStyle(.glass, size: .small)
                    .fixedSize()
            }
        }
    }

    private var canRun: Bool {
        !viewModel.command.trimmingCharacters(in: .whitespaces).isEmpty
            && !viewModel.selectedHosts.isEmpty
            && !viewModel.isExecuting
    }

    // MARK: Summary

    private var summaryCard: some View {
        let summary = viewModel.summary
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.page) {
                summaryNumber(summary)
                VStack(alignment: .leading, spacing: DS.Space.card) {
                    summaryBar(summary)
                    HStack(spacing: DS.Space.lg + 2) {
                        summaryCounts(summary)
                        Spacer(minLength: 0)
                        summaryFootnote(summary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.card) {
                HStack(alignment: .firstTextBaseline) {
                    summaryNumber(summary)
                    Spacer(minLength: DS.Space.sm)
                    summaryFootnote(summary)
                }
                summaryBar(summary)
                if summary.failed > 0 || summary.pending > 0 {
                    HStack(spacing: DS.Space.lg) {
                        summaryCounts(summary)
                    }
                }
            }
        }
        .padding(.horizontal, DS.Space.lg + 2)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .animation(DS.Motion.standard, value: summary)
    }

    private func summaryNumber(_ summary: BatchCommandViewModel.Summary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Text(verbatim: summary.succeeded.formatted())
                .font(DS.Font.gauge)
                .contentTransition(.numericText())
            Text("/ \(summary.total) succeeded")
                .font(DS.Font.unit)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// The number beside it is the green part; the red and the grey are said in words below.
    private func summaryBar(_ summary: BatchCommandViewModel.Summary) -> some View {
        DSSegmentBar(segments: [
            .init(id: "succeeded", value: Double(summary.succeeded), tint: DS.Palette.success),
            .init(id: "failed", value: Double(summary.failed), tint: DS.Palette.danger),
            .init(id: "pending", value: Double(summary.pending), tint: DS.Palette.inactive.opacity(0.35))
        ], height: 8)
    }

    /// Only what the big number does not say: the failures (the bar shows them by colour
    /// alone) and what is still out. Nothing when every host answered well.
    @ViewBuilder
    private func summaryCounts(_ summary: BatchCommandViewModel.Summary) -> some View {
        Group {
            if summary.failed > 0 {
                DSStatusPill("\(summary.failed) with errors", tone: .danger, showsBackground: false)
            }
            if summary.pending > 0 {
                DSStatusPill("\(summary.pending) still running", tone: .warning, isPulsing: true, showsBackground: false)
            }
        }
        .monospacedDigit()
        .contentTransition(.numericText())
        .fixedSize()
    }

    @ViewBuilder
    private func summaryFootnote(_ summary: BatchCommandViewModel.Summary) -> some View {
        if let startedAt = viewModel.lastRunAt {
            let time = startedAt.formatted(date: .omitted, time: .standard)
            let slowest = summary.slowestMs.map { " · " + String(localized: "Slowest \($0) ms") } ?? ""
            Text(verbatim: time + slowest)
                .font(DS.Font.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: Result controls

    private var resultControls: some View {
        HStack(spacing: DS.Space.card) {
            resultModePicker

            Spacer(minLength: DS.Space.sm)

            DSCopyButton("Copy All Output") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(BatchCommandViewModel.transcript(of: viewModel.results), forType: .string)
            }
            .dsButtonStyle(.glass, size: .small)
            .fixedSize()
            .disabled(viewModel.results.isEmpty)

            DSGlassIconButton("xmark", help: "Clear", size: .small) {
                viewModel.clearResults()
                expansion = [:]
            }
            .disabled(viewModel.isExecuting)
        }
    }

    /// The two ways to read the answers, in one glass capsule. Not the system's segmented
    /// control: its selected segment is filled with the accent, which on this page belongs to
    /// Run alone.
    private var resultModePicker: some View {
        HStack(spacing: 2) {
            resultModeSegment("By Host", mode: .byHost)
            resultModeSegment("By Output", mode: .byOutput)
        }
        .padding(3)
        .dsGlass(.capsule)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Results"))
    }

    private func resultModeSegment(_ title: LocalizedStringKey, mode: ResultMode) -> some View {
        let isSelected = resultMode == mode
        return Button {
            resultMode = mode
        } label: {
            Text(title)
                .font(DS.Font.label.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, DS.Space.md)
                .frame(height: 24)
                .background {
                    if isSelected {
                        Capsule(style: .continuous).fill(Color.primary.opacity(0.14))
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // AppKit does not pass a button's selected trait on: the value says it.
        .accessibilityValue(isSelected ? Text("Selected") : Text(verbatim: ""))
    }

    // MARK: Results

    private var resultsByHost: some View {
        let results = BatchCommandViewModel.ordered(viewModel.results)
        return DSGroup {
            ForEach(results) { result in
                BatchResultRow(result: result,
                               status: appViewModel.avatarStatus(forHostId: result.host.id),
                               isExpanded: isExpanded(result))
            }
            ForEach(viewModel.pendingHosts, id: \.connectionKey) { host in
                HStack(spacing: DS.Space.card) {
                    DSHostAvatar(host, size: 28, status: appViewModel.avatarStatus(forHostId: host.id))
                    Text(verbatim: host.displayName)
                        .font(DS.Font.rowTitle)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.sm)
                    ProgressView()
                        .controlSize(.small)
                }
                // Under the avatars of the answered rows (their chevron column stays empty).
                .padding(.leading, DS.Space.md + 16 + DS.Space.card)
                .padding(.trailing, DS.Space.lg)
                .frame(minHeight: 50)
                .help(host.addressDescription)
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text("Running"))
            }
        }
    }

    private func isExpanded(_ result: BatchCommandService.HostResult) -> Binding<Bool> {
        Binding(
            get: {
                expansion[result.id]
                    ?? BatchResultRow.opensByDefault(failed: result.isFailure, resultCount: viewModel.results.count)
            },
            set: { expansion[result.id] = $0 }
        )
    }

    private var resultsByOutput: some View {
        let groups = BatchCommandViewModel.outputGroups(of: viewModel.results)
        return VStack(alignment: .leading, spacing: DS.Space.card) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: DS.Space.card) {
                    HStack(spacing: DS.Space.sm) {
                        if group.hosts.count == 1, let host = group.hosts.first {
                            Text(verbatim: host.displayName)
                                .font(DS.Font.rowTitle)
                                .help(host.addressDescription)
                        } else {
                            Text("\(group.hosts.count) hosts returned the same output")
                                .font(DS.Font.rowTitle)
                        }
                        if group.isFailure {
                            DSChip("Failed", symbol: "xmark", tint: DS.Palette.danger)
                                .fixedSize()
                        }
                        Spacer(minLength: DS.Space.sm)
                        DSHostStack(hosts: group.hosts, limit: 8)
                            .help(group.hosts.map(\.displayName).joined(separator: ", "))
                    }
                    .lineLimit(1)
                    if group.text.isEmpty {
                        Text("(no output)")
                            .font(DS.Font.mono)
                            .foregroundStyle(.tertiary)
                    } else {
                        DSCodeBlock(group.text, size: .small, lineLimit: 8)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsCard()
            }
        }
    }

    // MARK: Nothing run yet

    private var emptyState: some View {
        // The shortcut is on the Run button, the last commands in its History menu.
        DSEmptyState("Nothing run yet", message: "Tick hosts, type a command, and run it on all of them.",
                     page: .batchCommand)
    }

    #if DEBUG
    /// Debug builds, for screenshots:
    /// `-debugBatchRun <command>` ticks the hosts of `-debugBatchHosts a,b` (default
    /// "test-agent") and really runs the command on them;
    /// `-debugBatchSample host|output` shows made-up results without connecting anywhere.
    private func applyDebugLaunchArguments() async {
        let defaults = AppProfile.arguments
        if let sample = defaults.string(forKey: "debugBatchSample") {
            viewModel.loadDebugSample(sameOutput: sample == "output")
            resultMode = sample == "output" ? .byOutput : .byHost
        } else if let command = defaults.string(forKey: "debugBatchRun") {
            let labels = (defaults.string(forKey: "debugBatchHosts") ?? "test-agent").split(separator: ",").map(String.init)
            viewModel.selectedHostIds = Set(viewModel.allHosts.filter { labels.contains($0.label) }.compactMap(\.id))
            viewModel.command = command
            await viewModel.execute()
        }
    }
    #endif
}

// MARK: - Host Row

/// A host with its checkbox; the whole row toggles it.
private struct BatchHostRow: View {
    let host: Host
    let status: DSHostAvatar.Status
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: DS.Space.sm + 1) {
            Toggle(isOn: $isOn) {
                Text(verbatim: "\(host.displayName), \(host.addressDescription)")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            HStack(spacing: DS.Space.sm + 1) {
                DSHostAvatar(host, size: 24, status: status)
                Text(verbatim: host.displayName)
                    .font(DS.Font.rowTitle)
                    .lineLimit(1)
                    // The hosts the command will not reach step back.
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: DS.Height.formRow)
            .contentShape(Rectangle())
            .onTapGesture { isOn.toggle() }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, DS.Space.card)
        // Several hosts may share a name; the address tells them apart.
        .help(host.addressDescription)
    }
}

// MARK: - Result Row

/// What one host answered: its tile and name, how it ended, how long it took, the first line;
/// opened, the whole output.
struct BatchResultRow: View {
    let result: BatchCommandService.HostResult
    var status: DSHostAvatar.Status = .none
    @Binding var isExpanded: Bool

    private var failed: Bool { result.isFailure }

    /// Output without the newline the remote shell ends it with.
    private var output: String {
        BatchCommandViewModel.trimmed(result.output)
    }

    /// Failures are what needs reading; a single answer has nothing to be compared with.
    nonisolated static func opensByDefault(failed: Bool, resultCount: Int) -> Bool {
        failed || resultCount == 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DS.Motion.quick) { isExpanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            // Several hosts may share a name; the address tells them apart.
            .help(result.host.addressDescription)
            .accessibilityValue(failed ? Text("Failed") : Text("Succeeded"))
            .accessibilityHint(isExpanded ? Text("Hide Output") : Text("Show Output"))

            if isExpanded {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    if let error = result.error {
                        errorBlock(error)
                    }
                    if !output.isEmpty {
                        if !result.stderr.isEmpty {
                            Text("Standard Output").font(DS.Font.caption).foregroundStyle(.secondary)
                        }
                        DSCodeBlock(output, size: .small)
                    }
                    if !result.stderr.isEmpty {
                        Text("Standard Error").font(DS.Font.caption).foregroundStyle(.secondary)
                        DSCodeBlock(result.stderr, size: .small)
                    } else if output.isEmpty && !failed {
                        Text("(no output)")
                            .font(DS.Font.mono)
                            .foregroundStyle(.tertiary)
                    }
                }
                // Under the name.
                .padding(.leading, DS.Space.md + 16 + DS.Space.card + 28 + DS.Space.card)
                .padding(.trailing, DS.Space.lg)
                .padding(.bottom, 14)
            }
        }
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.transcript, forType: .string)
            } label: {
                Label("Copy Output", systemImage: "doc.on.doc")
            }
        }
    }

    /// What ssh or the host said, as it said it: the same dark well the output is shown in,
    /// in the failure's colour (the "Failed" chip above says it in a word).
    private func errorBlock(_ error: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        return HStack(alignment: .top, spacing: DS.Space.md) {
            Text(verbatim: error)
                .foregroundStyle(DS.Palette.danger.mix(with: .primary, by: 0.3))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            DSCopyButton(help: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(error, forType: .string)
            }
            // As high as a line of text: the icon sits on the first line.
            .padding(.vertical, -3)
        }
        .font(.system(size: 12, design: .monospaced))
        .lineSpacing(3)
        .padding(.vertical, 11)
        .padding(.leading, 14)
        .padding(.trailing, DS.Space.md)
        .background(DS.Palette.terminal, in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.09)))
        // The well is dark whatever the window is, like the output's.
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: DS.Space.card) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 16)
                .accessibilityHidden(true)

            DSHostAvatar(result.host, size: 28, status: status)

            VStack(alignment: .leading, spacing: 3) {
                titleLine
                if !isExpanded {
                    let line = BatchCommandViewModel.firstLine(of: result.error ?? (result.output.isEmpty ? result.stderr : result.output))
                    if !line.isEmpty {
                        Text(verbatim: line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(failed ? AnyShapeStyle(DS.Palette.danger.mix(with: .primary, by: 0.3))
                                             : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .padding(.leading, DS.Space.md)
        .padding(.trailing, DS.Space.lg)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var titleLine: some View {
        HStack(spacing: DS.Space.card) {
            Text(verbatim: result.host.displayName)
                .font(DS.Font.rowTitle)
                .lineLimit(1)
            // The state in a glyph and a word; the colour only repeats it.
            if failed {
                if result.error == nil {
                    DSChip(verbatim: String(result.exitCode), symbol: "xmark", tint: DS.Palette.danger, isMonospaced: true)
                        .fixedSize()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Exit code \(Int(result.exitCode))"))
                } else {
                    DSChip("Failed", symbol: "xmark", tint: DS.Palette.danger)
                        .fixedSize()
                }
            } else {
                DSChip(verbatim: "0", symbol: "checkmark", tint: DS.Palette.success, isMonospaced: true)
                    .fixedSize()
                    // One element: a label on the bare chip lands on its glyph and on its text.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Exit code \(0)"))
            }
            Spacer(minLength: DS.Space.sm)
            Text(verbatim: "\(result.durationMs) ms")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 52, alignment: .trailing)
                .fixedSize()
        }
    }
}
