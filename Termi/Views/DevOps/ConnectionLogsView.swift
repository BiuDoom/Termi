import SwiftUI

private struct TranscriptID: Identifiable {
    let id: Int64
}

/// History page — what the connections add up to, the past connections in a sortable table,
/// and the selected one with the end of its saved session beside it.
struct ConnectionLogsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = ConnectionLogsViewModel()
    @State private var transcriptSelection: TranscriptID?
    @State private var selection: ConnectionLog.ID?
    @State private var sortOrder = [KeyPathComparator(\ConnectionLog.connectedAt, order: .reverse)]
    /// The table has the keyboard when the page opens: ↑ ↓ walk the records at once, and the
    /// selected record is drawn in the accent (a table that is not focused draws it grey).
    @FocusState private var isTableFocused: Bool
    /// Once per visit: the table comes back after a search that matched nothing, and must not
    /// take the keyboard from the search field then.
    @State private var didFocusTable = false

    /// Below this page width the session panel leaves and a double-click opens the transcript.
    private static let panelThreshold: CGFloat = 900

    private var rows: [ConnectionLog] {
        viewModel.logs.sorted(using: sortOrder)
    }

    private var selectedLog: ConnectionLog? {
        guard let selection else { return nil }
        return viewModel.logs.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.error, !viewModel.hasNoRecords {
                OpsErrorBanner(message: error) { viewModel.error = nil }
            }
            content
        }
        .dsStageBackground()
        .searchable(text: $viewModel.searchText, prompt: "Search hosts, states or errors")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh (⌘R)")
            }

            ToolbarItem {
                Menu {
                    Button("Clear History…", role: .destructive) {
                        viewModel.showingClearConfirm = true
                    }
                    .disabled(viewModel.hasNoRecords)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More")
            }
        }
        .task {
            // The rows show the hosts' tiles.
            await appViewModel.ensureHostsLoaded()
            await viewModel.loadLogs()
            selectFirstIfNeeded()
            #if DEBUG
            applyDebugLaunchArguments()
            #endif
        }
        // The search asks the database (every record, not the listed ones) once the typing pauses.
        .onChange(of: viewModel.searchText) { _, _ in
            viewModel.searchTextChanged()
        }
        // A new reading is on screen: the selected record stays while it is still listed.
        .onChange(of: viewModel.listVersion) { _, _ in
            selectFirstIfNeeded()
        }
        // The words of the command that asked ("Clear History…"). It says everything that
        // goes: the records, and the terminal output that was saved with them.
        .alert("Clear History", isPresented: $viewModel.showingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await viewModel.clearAll() }
            }
        } message: {
            Text("Clear the whole connection history? The saved session output is deleted with it. This cannot be undone.")
        }
        .sheet(item: $transcriptSelection) { item in
            SessionTranscriptView(logId: item.id, log: viewModel.logs.first { $0.id == item.id })
        }
    }

    /// How many records the search matches among all of them; nothing otherwise (the first
    /// card has the total), and nothing when it matches none (the table's place says that).
    private var subtitle: Text {
        guard let matches = viewModel.matchCount, matches > 0 else { return Text(verbatim: "") }
        return Text("\(matches) matches")
    }

    #if DEBUG
    /// `-debugLogsSelect timed|failed` selects the newest record that has a duration / that failed
    /// (the newest record of the test data has neither); `-debugLogsSearch <text>` types a
    /// search; `-debugLogsClear YES` asks whether to clear the history.
    private func applyDebugLaunchArguments() {
        if let text = AppProfile.arguments.string(forKey: "debugLogsSearch") {
            viewModel.searchText = text
        }
        if AppProfile.arguments.bool(forKey: "debugLogsClear") {
            viewModel.showingClearConfirm = true
        }
        switch AppProfile.arguments.string(forKey: "debugLogsSelect") {
        case "timed": selection = rows.first { ($0.durationMs ?? 0) >= 60_000 }?.id ?? selection
        case "failed": selection = rows.first { $0.outcome == .failed }?.id ?? selection
        default: break
        }
    }
    #endif

    // MARK: - Content

    /// Nothing at all until the first read is over: it is too quick for a spinner, and the
    /// empty state must not flash before the table.
    @ViewBuilder
    private var content: some View {
        if !viewModel.hasLoaded {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.hasNoRecords {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                let isWide = proxy.size.width >= Self.panelThreshold
                VStack(spacing: DS.Space.md) {
                    HistoryBand(summary: viewModel.summary, topHost: topHost, isWide: isWide)
                    HStack(alignment: .top, spacing: DS.Space.md) {
                        tableCard(width: proxy.size.width - (isWide ? 44 + DS.Space.md + DS.Layout.sidePanelWidth : 2 * DS.Space.lg))
                        if isWide {
                            HistorySessionPanel(log: selectedLog, host: selectedLog.flatMap { host(for: $0) },
                                                onReconnect: { appViewModel.connect(to: $0) },
                                                onOpenTranscript: { showTranscript($0) })
                                .frame(width: DS.Layout.sidePanelWidth)
                        }
                    }
                }
                .padding(.horizontal, isWide ? 22 : DS.Space.lg)
                .padding(.top, DS.Space.sm)
                .padding(.bottom, isWide ? DS.Space.xl : DS.Space.lg)
            }
        }
    }

    private var topHost: Host? {
        guard let id = viewModel.summary.top?.hostId else { return nil }
        return appViewModel.hostsPage.hosts.first { $0.id == id }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let error = viewModel.error {
            ContentUnavailableView {
                Label("Error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error)
            } actions: {
                Button("Retry") {
                    Task { await reload() }
                }
            }
        } else {
            DSEmptyState("No Connection Logs", message: "Sessions are recorded here once you connect", page: .logs)
        }
    }

    // MARK: - Table

    /// The table only while there is something to list: an empty table would put its header
    /// and row stripes behind the "no results" state.
    private func tableCard(width: CGFloat) -> some View {
        Group {
            if viewModel.logs.isEmpty {
                ContentUnavailableView.search(text: viewModel.listedSearch)
            } else {
                VStack(spacing: 0) {
                    logsTable(width: width)
                        .scrollContentBackground(.hidden)
                        .focused($isTableFocused)
                        .onAppear {
                            guard !didFocusTable else { return }
                            didFocusTable = true
                            isTableFocused = true
                        }
                    // The numbers above count every record, and a search asks every record; the
                    // table lists the newest ones. Said once, where the list ends.
                    if let cut = viewModel.cut {
                        Divider()
                        cutLine(cut)
                            .font(DS.Font.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCard()
    }

    private func cutLine(_ cut: HistoryCut) -> Text {
        switch cut {
        case .latest(let listed, let total): Text("The latest \(listed) of \(total) records are listed")
        case .matches(let listed, let total): Text("The latest \(listed) of \(total) matches are listed")
        }
    }

    /// Four fixed columns. A table opens its columns at their ideal widths and does not share
    /// out what is left: Host's ideal width is what the other columns leave of the card.
    private func logsTable(width: CGFloat) -> some View {
        // 18 + 128 + 96 for the other columns, and what the table's insets and gaps take.
        let hostWidth = max(150, width - 18 - 128 - 96 - 80)
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            // Sorts by status; the mark needs no header.
            TableColumn(Text(verbatim: ""), value: \.status) { log in
                HistoryMark(outcome: log.outcome)
            }
            .width(18)

            TableColumn("Host", value: \.hostLabel) { log in
                HistoryHostCell(log: log, host: host(for: log))
            }
            .width(min: 150, ideal: hostWidth)

            // Not "Connected": that word is a state.
            TableColumn("Time", value: \.connectedAt) { log in
                timeCell(log)
            }
            .width(min: 112, ideal: 128, max: 150)

            TableColumn("Duration", value: \.sortableDuration) { log in
                durationCell(log)
            }
            .width(min: 76, ideal: 96, max: 120)
        }
        // Double-click opens the session's transcript.
        .contextMenu(forSelectionType: ConnectionLog.ID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            if let log = log(for: ids), hasTranscript(log) {
                showTranscript(log)
            }
        }
    }

    // MARK: - Cells

    /// Absolute, to the second for today: finding a connection takes its exact time.
    @ViewBuilder
    private func timeCell(_ log: ConnectionLog) -> some View {
        if let date = log.dsStartedAt {
            Text(verbatim: HistoryFormat.time(date))
                .monospacedDigit()
                .lineLimit(1)
                .help(Text(verbatim: date.formatted(date: .complete, time: .standard)))
        } else {
            Text(verbatim: log.connectedAt)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func durationCell(_ log: ConnectionLog) -> some View {
        if let ms = log.durationMs, ms > 0 {
            Text(verbatim: DSLogStats.durationText(ms: ms))
                .monospacedDigit()
                .lineLimit(1)
        } else if log.isInProgress {
            Text("In progress")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // No duration was recorded (a failed connection): nothing, not a dash.
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<ConnectionLog.ID>) -> some View {
        if let log = log(for: ids) {
            if hasTranscript(log) {
                Button {
                    showTranscript(log)
                } label: {
                    Label("View Session Transcript", systemImage: "doc.text.magnifyingglass")
                }
            }
            if let host = host(for: log) {
                Button {
                    appViewModel.connect(to: host)
                } label: {
                    Label("Reconnect", systemImage: "bolt")
                }
            }
            Divider()
            Button {
                copy(log.addressToCopy(savedHost: host(for: log)))
            } label: {
                Label("Copy Address", systemImage: "doc.on.clipboard")
            }
            if let error = log.errorMessage, !error.isEmpty {
                Button {
                    copy(error)
                } label: {
                    Label("Copy Error Message", systemImage: "doc.on.doc")
                }
            }
        }
    }

    // MARK: - Helpers

    private func reload() async {
        viewModel.error = nil
        await viewModel.loadLogs()
        selectFirstIfNeeded()
    }

    /// The page opens with the newest record selected, and a search or a reload that removed
    /// the selected one moves to the first that is listed.
    private func selectFirstIfNeeded() {
        selection = ConnectionLogsViewModel.selection(keeping: selection, in: rows)
    }

    /// The saved host a record belongs to, while it still exists.
    private func host(for log: ConnectionLog) -> Host? {
        guard let hostId = log.hostId else { return nil }
        return appViewModel.hostsPage.hosts.first { $0.id == hostId }
    }

    private func log(for ids: Set<ConnectionLog.ID>) -> ConnectionLog? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return viewModel.logs.first { $0.id == id }
    }

    private func hasTranscript(_ log: ConnectionLog) -> Bool {
        guard let logId = log.id else { return false }
        return FileManager.default.fileExists(atPath: TerminalSession.transcriptPath(for: logId))
    }

    private func showTranscript(_ log: ConnectionLog) {
        guard let logId = log.id else { return }
        transcriptSelection = TranscriptID(id: logId)
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private extension ConnectionLog {
    /// Sort key for the optional column (missing values sort first).
    var sortableDuration: Int { durationMs ?? -1 }

    var statusTone: DS.Tone {
        switch status.lowercased() {
        case "connected": isInProgress ? .success : .inactive
        case "disconnected": .inactive
        case "failed", "error": .danger
        default: .warning
        }
    }
}

// MARK: - Band

/// What the history adds up to: the number cards and — when there is room — the last 30 days.
private struct HistoryBand: View {
    let summary: HistorySummary
    let topHost: Host?
    let isWide: Bool

    /// Only the connections whose duration was recorded count; when none was there is no card.
    private var average: (value: String, unit: HistoryFormat.Unit)? {
        HistoryFormat.durationParts(ms: summary.stats.averageDurationMs)
    }

    var body: some View {
        if isWide {
            HStack(spacing: DS.Space.card) {
                cards
                    .frame(width: HistoryFormat.bandWidth(cards: average == nil ? 3 : 4))
                // The number cards set the height of the band; the chart's card takes exactly it.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .overlay { activity }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            cards
        }
    }

    /// Beside the 30-day chart the cards are numbers only: the chart draws the series. Without
    /// it (a narrow page) the first card keeps its own small trend.
    private var cards: some View {
        DSStatGrid(minimum: 120) {
            DSStatCard("Connections", value: summary.stats.totalText, symbol: "waveform.path.ecg",
                       footnote: String(localized: "\(summary.today) today"), isHero: true) {
                if !isWide {
                    DSSparkline(values: summary.days.map { Double($0.total) }, minimumSpan: 4)
                        .frame(height: 22)
                }
            }
            DSStatCard("Success Rate", value: successValue, unit: summary.stats.total > 0 ? "%" : nil,
                       symbol: "checkmark.circle", footnote: String(localized: "\(summary.stats.failed) failed"))
            if let average {
                DSStatCard("Average Duration", value: average.value, unit: average.unit.title, symbol: "timer",
                           footnote: summary.longestDurationMs.map {
                               String(localized: "Longest \(DSLogStats.durationText(ms: $0))")
                           } ?? " ") {
                    // The durations are drawn nowhere else on a narrow page.
                    if !isWide {
                        DSSparkline(values: summary.durations)
                            .frame(height: 22)
                    }
                }
            }
            DSStatCard("Most Connected", value: summary.top?.name ?? "—", symbol: "star",
                       footnote: summary.top.map { top in
                           String(localized: "\(top.count) times · \(MonitorFormat.percent(top.share))")
                       } ?? " ",
                       lead: summary.top.map { _ in topHost.map { DSStatLead.host($0) } ?? .system(.unknown) })
        }
    }

    private var successPercent: Double {
        guard summary.stats.total > 0 else { return 0 }
        return Double(summary.stats.total - summary.stats.failed) / Double(summary.stats.total) * 100
    }

    /// Rounded down: "100 %" is only said when nothing failed.
    private var successValue: String {
        summary.stats.total > 0 ? "\(Int(successPercent))" : "—"
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Last 30 Days")
                    .font(DS.Font.label)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                // Not when every connection is from these 30 days: the first card has that number.
                if let count = summary.recentCountIfPartial {
                    Text("\(count) times")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                // Two colours need a legend; one series does not.
                if summary.hasRecentFailures {
                    DSActivityLegend()
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            DSActivityChart(days: summary.days, height: 29, marksFailures: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, DS.Space.card)
        .padding(.bottom, DS.Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dsCard()
    }
}

// MARK: - Table cells

/// How the connection went. The colour is never alone: the glyph differs, and the tooltip and
/// the accessibility label say it. On the selected row everything is the row's text colour.
private struct HistoryMark: View {
    let outcome: ConnectionLog.Outcome
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(style)
            .frame(width: 18)
            .help(title)
            .accessibilityLabel(Text(title))
    }

    private var symbol: String {
        switch outcome {
        case .succeeded: "checkmark.circle"
        case .failed: "xmark.circle"
        case .inProgress: "circle.dotted"
        }
    }

    private var title: LocalizedStringKey {
        switch outcome {
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .inProgress: "In progress"
        }
    }

    private var style: AnyShapeStyle {
        if prominence == .increased { return AnyShapeStyle(.primary) }
        return outcome == .failed ? AnyShapeStyle(DS.Palette.danger) : AnyShapeStyle(.tertiary)
    }
}

/// The host of a record: its tile, its name over its address — or, when the connection failed,
/// name and address on one line and the error under them.
private struct HistoryHostCell: View {
    let log: ConnectionLog
    let host: Host?
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: DS.Space.card) {
            if let host {
                DSHostAvatar(host, size: 24)
            } else {
                // A host that was deleted since, or was never saved.
                DSHostAvatar(os: .unknown, size: 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let error = log.errorSummary {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        name
                            .layoutPriority(1)
                        if log.showsAddress { address }
                    }
                    Text(verbatim: error)
                        .font(DS.Font.caption)
                        .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(DS.Palette.danger))
                        .help(log.errorMessage ?? error)
                } else {
                    name
                    if log.showsAddress { address }
                }
            }
            .lineLimit(1)
        }
        // Same row height with or without the second line.
        .frame(minHeight: 32)
    }

    private var name: some View {
        Text(verbatim: log.displayName)
            .fontWeight(.semibold)
            .truncationMode(log.showsAddress ? .tail : .middle)
    }

    private var address: some View {
        Text(verbatim: log.hostname)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .truncationMode(.middle)
    }
}

// MARK: - Session panel

/// The selected record: who, how it ended, how long it took (when that was recorded), what the
/// session printed last, and the two things to do with it.
private struct HistorySessionPanel: View {
    let log: ConnectionLog?
    let host: Host?
    let onReconnect: (Host) -> Void
    let onOpenTranscript: (ConnectionLog) -> Void

    private enum Output: Equatable {
        case loading
        /// No transcript file, or nothing in it.
        case none
        case text(String)
    }

    private static let tailLines = 40
    @State private var output = Output.loading

    var body: some View {
        Group {
            if let log {
                VStack(alignment: .leading, spacing: 14) {
                    header(log)
                    duration(log)
                    if let error = log.errorMessage, !error.isEmpty {
                        DSMessage(verbatim: error)
                    }
                    session
                    actions(log)
                }
                .padding(.horizontal, 14)
                .padding(.top, DS.Space.lg)
                .padding(.bottom, 14)
                .id(log.id)
                .transition(.opacity)
            } else {
                ContentUnavailableView {
                    Label("No Record Selected", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Select a record to see its session")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .dsCard()
        .animation(DS.Motion.quick, value: log?.id)
        .task(id: log?.id) { await loadOutput() }
    }

    private func header(_ log: ConnectionLog) -> some View {
        HStack(spacing: DS.Space.md) {
            if let host {
                DSHostAvatar(host, size: 36)
            } else {
                DSHostAvatar(os: .unknown, size: 36)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: log.displayName)
                    .font(.system(size: 16, weight: .bold))
                Text(verbatim: log.hostname)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .lineLimit(1)
            Spacer(minLength: DS.Space.xs)
            DSStatusPill(log.statusLabel, tone: log.statusTone)
        }
    }

    /// The duration large, and under it the start and the end with a line between them. Without
    /// a recorded duration (a failed connection, a session still open) there is neither: one
    /// line says when it started.
    @ViewBuilder
    private func duration(_ log: ConnectionLog) -> some View {
        if let ms = log.durationMs, ms > 0 {
            timedDuration(log, ms: ms)
        } else {
            startedLine(log)
        }
    }

    /// "Started Today 21:57:30" — and "In progress" for a session that has not ended.
    private func startedLine(_ log: ConnectionLog) -> some View {
        let date = TimestampFormatter.date(from: log.connectedAt)
        return HStack(spacing: 6) {
            Text("Started")
                .foregroundStyle(.secondary)
            Text(verbatim: date.map { HistoryFormat.time($0) } ?? log.connectedAt)
                .fontWeight(.medium)
                .monospacedDigit()
            if log.isInProgress {
                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)
                Text("In progress")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .help(Text(verbatim: date.map { $0.formatted(date: .complete, time: .standard) } ?? log.connectedAt))
        .padding(.horizontal, DS.Space.xxs)
        .accessibilityElement(children: .combine)
    }

    private func timedDuration(_ log: ConnectionLog, ms: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            DSCardLabel("Duration", symbol: "timer")
            durationValue(ms: ms)
                .frame(height: 32, alignment: .bottomLeading)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(alignment: .bottom, spacing: DS.Space.sm) {
                endpoint("Started", iso: log.connectedAt, alignment: .leading)
                // Decorative: the two times say it.
                Capsule()
                    .fill(DS.Palette.accent.opacity(0.26))
                    .frame(height: 2)
                    .overlay(alignment: .leading) { Circle().fill(DS.Palette.accent).frame(width: 6, height: 6) }
                    .overlay(alignment: .trailing) { Circle().fill(DS.Palette.accent).frame(width: 6, height: 6) }
                    .padding(.bottom, 7)
                    .accessibilityHidden(true)
                endpoint("Ended", iso: log.disconnectedAt, alignment: .trailing)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, DS.Space.xxs)
    }

    /// "4 min 12 sec": the numerals large, their units small beside them, as on the number cards.
    private func durationValue(ms: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            ForEach(Array(HistoryFormat.durationPieces(ms: ms).enumerated()), id: \.offset) { index, piece in
                Text(verbatim: piece.value)
                    .font(DS.Font.stat)
                    .padding(.leading, index > 0 ? 5 : 0)
                Text(verbatim: piece.unit.title)
                    .font(DS.Font.unit)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: DSLogStats.durationText(ms: ms)))
    }

    private func endpoint(_ title: LocalizedStringKey, iso: String?, alignment: HorizontalAlignment) -> some View {
        let date = iso.flatMap { TimestampFormatter.date(from: $0) }
        return VStack(alignment: alignment, spacing: 0) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
            if let date {
                Text(verbatim: HistoryFormat.time(date))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .help(Text(verbatim: date.formatted(date: .complete, time: .standard)))
            } else {
                Text(verbatim: "—")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// The end of what the session printed, on a terminal-coloured surface (dark in both
    /// appearances, like the terminal itself).
    private var session: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Session Output") {
                if case .text = output {
                    Text("Last \(Self.tailLines) lines")
                }
            }
            Group {
                switch output {
                case .loading:
                    DSDelayed { ProgressView().controlSize(.small) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .none:
                    Text("No output was saved for this connection")
                        .font(DS.Font.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(DS.Space.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .text(let text):
                    GeometryReader { proxy in
                        ScrollView {
                            Text(verbatim: text)
                                .font(.system(size: 10.5, design: .monospaced))
                                .lineSpacing(3)
                                .foregroundStyle(Color(white: 0.82))
                                .textSelection(.enabled)
                                .padding(DS.Space.card)
                                // A short session starts at the top of the block.
                                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                        }
                        // A long one shows its newest lines: those are the ones asked for.
                        .defaultScrollAnchor(.bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Palette.terminal, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
            .environment(\.colorScheme, .dark)
        }
    }

    private func actions(_ log: ConnectionLog) -> some View {
        HStack(spacing: DS.Space.sm) {
            Button {
                if let host { onReconnect(host) }
            } label: {
                Label("Reconnect", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .dsButtonStyle(.prominent)
            // The record of a host that was deleted since, or of an address typed once.
            .disabled(host == nil)

            Button {
                onOpenTranscript(log)
            } label: {
                Label("Open Full Transcript", systemImage: "doc.text")
                    .frame(maxWidth: .infinity)
            }
            .dsButtonStyle(.glass)
            .disabled(output == .none || output == .loading)
        }
        .lineLimit(1)
    }

    private func loadOutput() async {
        guard let logId = log?.id else {
            output = .none
            return
        }
        output = .loading
        let path = TerminalSession.transcriptPath(for: logId)
        let lines = Self.tailLines
        let tail = await Task.detached(priority: .userInitiated) {
            guard let raw = HistoryFormat.readEnd(ofFileAt: path) else { return "" }
            return HistoryFormat.tail(of: plainText(fromTerminalOutput: raw), lines: lines)
        }.value
        guard !Task.isCancelled else { return }
        output = tail.isEmpty ? .none : .text(tail)
    }
}

private extension ConnectionLog {
    /// The status as a key of the string catalog (a status the app does not know is shown as stored).
    var statusLabel: LocalizedStringKey {
        switch status.lowercased() {
        case "connected": "Connected"
        case "disconnected": "Disconnected"
        case "failed", "error": "Failed"
        default: LocalizedStringKey(status.capitalized)
        }
    }
}

// MARK: - Session Transcript View

/// The terminal output saved for one session: monospaced, selectable, scrollable.
struct SessionTranscriptView: View {
    let logId: Int64
    var log: ConnectionLog?
    @State private var content = ""
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        // Fixed, like ContainerLogsSheet: a ScrollView's content height is its ideal height,
        // so the sheet would otherwise grow with the transcript.
        .frame(width: 700, height: 500)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onExitCommand { dismiss() }
        .task { await loadTranscript() }
    }

    private var header: some View {
        HStack(spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.headline)
                    .lineLimit(1)
                if let log {
                    Text(verbatim: log.showsAddress
                         ? "\(log.hostname) · \(Self.formattedDate(log.connectedAt))"
                         : Self.formattedDate(log.connectedAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: DS.Space.md)

            DSCopyButton("Copy All") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            }
            .disabled(content.isEmpty)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
    }

    private var title: Text {
        if let label = log?.hostLabel, !label.isEmpty {
            return Text(verbatim: label)
        }
        return Text("Session #\(logId)")
    }

    @ViewBuilder
    private var transcript: some View {
        if isLoading {
            DSDelayed { ProgressView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if content.isEmpty {
            ContentUnavailableView {
                Label("No Transcript", systemImage: "doc.text")
            } description: {
                Text("No terminal output was captured for this session.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(verbatim: content)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.vertical, DS.Space.lg)
            }
        }
    }

    private static func formattedDate(_ iso: String) -> String {
        guard let date = TimestampFormatter.date(from: iso) else { return iso }
        return DisplayDateFormatter.mediumDateShortTime.string(from: date)
    }

    private func loadTranscript() async {
        let path = TerminalSession.transcriptPath(for: logId)
        isLoading = true
        let stripped = await Task.detached(priority: .userInitiated) {
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
            return plainText(fromTerminalOutput: raw)
        }.value
        content = stripped
        isLoading = false
    }
}

/// Terminal output as readable text. Escape sequences are dropped (OSC window titles, CSI
/// including private modes such as ESC[?2004h, DCS / APC strings, two-character escapes).
/// A carriage return keeps its meaning — the line is redrawn from its start — so only what
/// follows the last one stays (prompt redraws, progress bars). The remaining control
/// characters go; tab and newline stay.
private func plainText(fromTerminalOutput raw: String) -> String {
    let escapeSequences = [
        #"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"#,          // OSC … BEL / ST
        #"\x1b\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]"#,  // CSI, private parameters included
        #"\x1b[PX^_][^\x1b]*\x1b\\"#,                    // DCS / SOS / PM / APC … ST
        #"\x1b[\x20-\x2f]*[\x30-\x7e]"#,                 // remaining short escapes
    ].joined(separator: "|")
    // The order matters. The third pass is anchored to the line start: tried at every
    // character instead, it takes quadratic time on a long line (a full-screen program
    // writes tens of thousands of characters without a newline).
    let passes: [(pattern: String, replacement: String)] = [
        (escapeSequences, ""),
        (#"\r+\n"#, "\n"),
        (#"(?m)^[^\n]*\r"#, ""),
        (#"[\x00-\x08\x0b-\x1f\x7f]"#, ""),
    ]
    return passes.reduce(raw) {
        $0.replacingOccurrences(of: $1.pattern, with: $1.replacement, options: .regularExpression)
    }
}
