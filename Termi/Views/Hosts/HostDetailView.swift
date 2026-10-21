import SwiftUI

/// The record of one host, in the panel the Hosts page opens on demand: who it is and what to do with it, how the
/// connections to it went, the way there, its forwarding rules, its recent sessions and how it
/// is set up. Built from the shared cards; the page behind it draws the stage.
struct HostDetailView: View {
    let host: Host
    let viewModel: HostsViewModel
    let actions: HostActions
    /// Set when the record stands in a panel that can be closed: a bar above the record names
    /// the panel and carries its close control (it does not scroll away with the record).
    var onClose: (() -> Void)? = nil

    @Environment(AppViewModel.self) private var appViewModel
    @State private var transcript: TranscriptTarget?

    private struct TranscriptTarget: Identifiable {
        let id: Int64
    }

    /// What makes the record read its own data again.
    private struct LoadKey: Equatable {
        let hostId: Int64?
        let revision: Int
        /// A session that just ended is in the chart right away.
        let tabCount: Int
    }

    /// Below this width the header stacks and the cards go two by two (the 380 pt panel of the
    /// grid, and the detail of the minimum window).
    private static let compactWidth: CGFloat = 560

    private var logs: [ConnectionLog] { viewModel.logs(for: host.id) }
    private var status: DSHostAvatar.Status { appViewModel.avatarStatus(forHostId: host.id) }
    private var sessionCount: Int { appViewModel.liveSessionCount(forHostId: host.id) }
    /// Known at once from the host itself, before its history is read.
    private var hasHistory: Bool { HostDetailFormat.hasHistory(lastConnected: host.lastConnectedDate, recordCount: logs.count) }

    var body: some View {
        VStack(spacing: 0) {
            if let onClose {
                panelBar(onClose: onClose)
            }
            record
        }
        .task(id: LoadKey(hostId: host.id, revision: viewModel.revision, tabCount: appViewModel.tabs.count)) {
            if let id = host.id {
                await viewModel.loadDetail(for: id)
            }
        }
        .sheet(item: $transcript) { target in
            SessionTranscriptView(logId: target.id, log: logs.first { $0.id == target.id })
        }
    }

    /// "Host Details" and the way out, as in a sidebar's header.
    private func panelBar(onClose: @escaping () -> Void) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text("Host Details")
                .font(DS.Font.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            DSRowButton("arrow.right.to.line", help: "Hide Details (⌘I)", action: onClose)
        }
        .padding(.leading, DS.Space.xl)
        .padding(.trailing, DS.Space.lg)
        .frame(height: 34)
    }

    private var record: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < Self.compactWidth
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    if isCompact {
                        compactHeader
                    } else {
                        header
                    }
                    // A host that was never connected to has no numbers: no cards of dashes.
                    if hasHistory {
                        stats
                    }
                    routeSection
                    forwardsSection(isCompact: isCompact)
                    if !logs.isEmpty {
                        activitySection(isCompact: isCompact)
                    }
                    configurationSection
                    hostKeySection
                }
                .padding(.horizontal, isCompact ? DS.Space.xl : DS.Space.page)
                .padding(.top, DS.Space.xs)
                .padding(.bottom, DS.Space.xxl)
                .dsCenteredColumn()
            }
        }
    }

    // MARK: - Header

    /// Tile, name and address, the actions at the top right; the chips run under them.
    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            DSHostAvatar(host, size: DS.Tile.header, status: status)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: DS.Space.md) {
                    VStack(alignment: .leading, spacing: 3) {
                        title(DS.Font.detailTitle)
                        address
                    }
                    Spacer(minLength: 0)
                    actionButtons(fillsWidth: false)
                        .fixedSize()
                        .padding(.top, DS.Space.xs)
                }
                if hasChips {
                    chips(showsSystem: true)
                        .padding(.top, 5)
                }
            }
        }
    }

    /// The same, stacked: identity, chips, then the actions across the width.
    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: DS.Space.card) {
            HStack(spacing: 14) {
                DSHostAvatar(host, size: DS.Tile.large, status: status)
                VStack(alignment: .leading, spacing: 2) {
                    title(.system(size: 22, weight: .bold))
                    address
                    // The system is a third line of the identity here: as a chip it would take
                    // a row of its own in the narrow panel.
                    if let system = host.systemDescription {
                        Text(verbatim: system)
                            .font(DS.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                            .help(systemSource)
                            .accessibilityHint(systemSource)
                    }
                }
            }
            if hasCompactChips {
                chips(showsSystem: false)
            }
            actionButtons(fillsWidth: true)
        }
    }

    private func title(_ font: Font) -> some View {
        Text(verbatim: host.displayName)
            .font(font)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }

    private var address: some View {
        // With the port, also when it is 22: this is the record.
        Text(verbatim: HostDetailFormat.fullAddress(of: host))
            .font(DS.Font.mono)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    /// A host nobody is connected to, whose system was never read and that has no tags, has no
    /// chips: the line goes instead of standing empty.
    private var hasChips: Bool {
        status != .none || host.systemDescription != nil || !viewModel.tags(for: host).isEmpty
    }

    /// The chips of the narrow header: the state and the tags.
    private var hasCompactChips: Bool {
        status != .none || !viewModel.tags(for: host).isEmpty
    }

    private func chips(showsSystem: Bool) -> some View {
        FlowLayout(spacing: 6) {
            statusPill
            // The one place the record names the system: where it comes from is its tooltip.
            if showsSystem, let system = host.systemDescription {
                DSChip(verbatim: system)
                    .textSelection(.enabled)
                    .help(systemSource)
                    .accessibilityHint(systemSource)
            }
            ForEach(viewModel.tags(for: host)) { tag in
                DSChip(verbatim: "#\(tag.name)")
            }
        }
    }

    /// How the system got here: read from the host when it connects, and when that last was.
    private var systemSource: Text {
        guard let date = host.systemDetectedDate else { return Text("Read automatically after the host connects") }
        return Text("Read automatically when connecting · last read \(HostDetailFormat.dayAndTime(date, showsSeconds: false))")
    }

    /// The live state in words; a host nobody is connected to says nothing.
    @ViewBuilder
    private var statusPill: some View {
        switch status {
        case .live:
            DSStatusPill(verbatim: String(localized: "Connected · \(sessionCount) sessions"))
        case .busy:
            DSStatusPill("Connecting…", tone: .warning, isPulsing: true)
        case .needsInput:
            DSStatusPill("Awaiting Input", tone: .warning, isPulsing: true)
        case .unread:
            DSStatusPill("New Output", tone: .accent)
        case .failed:
            DSStatusPill("Connection Failed", tone: .danger)
        case .ended:
            DSStatusPill("Disconnected", tone: .inactive)
        case .none:
            EmptyView()
        }
    }

    private func actionButtons(fillsWidth: Bool) -> some View {
        DSGlassContainer(spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                // Return belongs to the search field: no default-action shortcut here.
                Button {
                    actions.onConnect()
                } label: {
                    Label("Connect", systemImage: "bolt.fill")
                        .frame(maxWidth: fillsWidth ? .infinity : nil)
                }
                .dsButtonStyle(.prominent)
                if let onOpenSFTP = actions.onOpenSFTP {
                    Button {
                        onOpenSFTP()
                    } label: {
                        Label("SFTP", systemImage: "folder")
                    }
                    .dsButtonStyle(.glass)
                    .help("Open SFTP")
                }
                // The record is read here and changed in the form: one click away, not in a menu.
                DSGlassIconButton("pencil", help: "Edit") { actions.onEdit() }
                DSGlassIconMenu {
                    HostMenuItems(host: host, actions: actions, includesPrimary: false)
                }
            }
        }
    }

    // MARK: - Numbers

    /// Four numbers, no charts: the fourteen days are drawn once, in the chart below. A footnote
    /// is there when it adds to its number; a card whose number does not exist is not there.
    private var stats: some View {
        let summary = DSLogStats(logs)
        let recent = DSActivityChart.days(from: logs, count: 14).reduce(0) { $0 + $1.total }
        let percent = HostDetailFormat.successPercent(total: summary.total, failed: summary.failed)
        let longest = HostDetailFormat.recentDurations(in: logs).max()
        return TimelineView(DSRelativeTime.schedule) { context in
            let last = HostDetailFormat.lastConnected(host.lastConnectedDate, now: context.date)
            DSStatGrid {
                if host.lastConnectedDate != nil {
                    DSStatCard("Last Connected", value: last.value, unit: last.unit, symbol: "clock",
                               footnote: host.lastConnectedDate.map { HostDetailFormat.dayAndTime($0, showsSeconds: false) },
                               isFlat: true)
                }
                if summary.total > 0 {
                    DSStatCard("Connections", value: summary.totalText, symbol: "waveform.path.ecg",
                               footnote: HostDetailFormat.showsRecentCount(recent: recent, total: summary.total)
                                   ? String(localized: "\(recent) in the last 14 days") : nil,
                               isFlat: true)
                }
                if let percent {
                    DSStatCard("Success Rate", value: String(percent), unit: "%",
                               symbol: "checkmark.circle",
                               footnote: summary.failed > 0 ? String(localized: "\(summary.failed) failed") : nil,
                               isFlat: true)
                }
                if let average = summary.averageDurationMs, average > 0 {
                    DSStatCard("Average Duration", value: HostDetailFormat.clock(ms: average), symbol: "timer",
                               footnote: longest.map { String(localized: "Longest \(DSLogStats.durationText(ms: Int($0 * 1000)))") },
                               isFlat: true)
                }
            }
        }
    }

    // MARK: - Route

    /// The way to the host — drawn when it leads through a jump host. A direct connection is
    /// "this Mac → the host", which the header already is.
    @ViewBuilder
    private var routeSection: some View {
        let route = host.routeHops(hosts: viewModel.hosts, groups: viewModel.allGroups)
        let hops = route.enumerated().map { index, hop -> DSRouteDiagram.Hop in
            var hop = hop
            hop.status = appViewModel.avatarStatus(forHostId: hop.hostId)
            // The last hop is this host: its address is in the header right above.
            if index == route.count - 1 { hop.detail = nil }
            return hop
        }
        if DSRouteDiagram.addsSomething(hopCount: hops.count) {
            VStack(alignment: .leading, spacing: 0) {
                DSSectionHeader("Route")
                DSGroup {
                    DSRouteDiagram(hops: hops, activity: routeActivity) { id in
                        viewModel.pick(id)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, DS.Space.sm)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                }
            }
        }
    }

    private var routeActivity: DSRouteDiagram.Activity {
        switch status {
        case .live: return .flowing
        case .failed: return .failed
        default: return .idle
        }
    }

    // MARK: - Port forwards

    @ViewBuilder
    private func forwardsSection(isCompact: Bool) -> some View {
        let rules = viewModel.forwards(for: host.id)
        if !rules.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                DSSectionHeader("Port Forwarding")
                DSGroup {
                    ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                        forwardRow(rule, isCompact: isCompact)
                    }
                }
            }
        }
    }

    private func forwardRow(_ rule: PortForward, isCompact: Bool) -> some View {
        let manager = PortForwardManager.shared
        return DSRow {
            forwardKind(rule)
            Text(verbatim: rule.sshForward.displayDescription)
                .font(isCompact ? .system(size: 11, design: .monospaced) : DS.Font.mono)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(Text(verbatim: rule.sshForward.displayDescription))
            Spacer(minLength: 0)
            // The switch says running / stopped; words only for what it cannot show.
            forwardState(manager.status(of: rule))
                .fixedSize()
            Toggle(isOn: Binding(get: { manager.isRunning(rule) },
                                 set: { _ in Task { await manager.toggle(rule) } })) {
                Text(verbatim: rule.sshForward.displayDescription)
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .help(manager.isRunning(rule) ? "Stop tunnel" : "Start tunnel")
        }
    }

    @ViewBuilder
    private func forwardKind(_ rule: PortForward) -> some View {
        switch rule.type {
        case "local": DSChip("Local")
        case "remote": DSChip("Remote")
        case "dynamic": DSChip("Dynamic")
        default: DSChip(verbatim: rule.type)
        }
    }

    @ViewBuilder
    private func forwardState(_ state: PortForwardManager.Status?) -> some View {
        switch state {
        case .starting:
            DSStatusPill("Connecting…", tone: .warning, isPulsing: true, showsBackground: false)
        case .failed(let message), .stopFailed(let message):
            DSStatusPill("Failed", tone: .danger, showsBackground: false)
                .help(Text(verbatim: message))
        case .active, nil:
            EmptyView()
        }
    }

    // MARK: - Activity

    private func activitySection(isCompact: Bool) -> some View {
        let days = DSActivityChart.days(from: logs, count: 14)
        let today = days.last?.total ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Last 14 Days") {
                // The total of the fourteen days is on the Connections card.
                if today > 0 {
                    Text("\(today) today")
                }
            }
            DSGroup {
                // The only drawing of the series: it has the room the cards' charts gave back.
                // Fourteen empty days are not drawn.
                if !logs.isEmpty {
                    DSActivityChart(days: days, height: isCompact ? 64 : 80)
                        .padding(.horizontal, DS.Space.md)
                        .padding(.top, DS.Space.md)
                        .padding(.bottom, DS.Space.sm)
                }
                if logs.isEmpty {
                    DSRow(isCompact: true) {
                        Text("Not connected yet")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(logs.prefix(5).enumerated()), id: \.offset) { _, log in
                        logRow(log)
                    }
                }
            }
        }
    }

    private func logRow(_ log: ConnectionLog) -> some View {
        DSRow(isCompact: true) {
            Image(systemName: log.dsDidFail ? "xmark.circle" : "checkmark.circle")
                .foregroundStyle(log.dsDidFail ? DS.Palette.danger : DS.Palette.success)
                .accessibilityLabel(log.dsDidFail ? Text("Failed") : Text("Connected"))
            Text(verbatim: log.dsStartedAt.map { HostDetailFormat.dayAndTime($0, showsSeconds: true) } ?? log.connectedAt)
                .font(.system(size: 12).monospacedDigit())
                .layoutPriority(1)
            Spacer(minLength: DS.Space.sm)
            logTail(log)
            // A fixed column: the durations stay in line whether a row has a transcript or not.
            Group {
                if let id = log.id, FileManager.default.fileExists(atPath: TerminalSession.transcriptPath(for: id)) {
                    DSRowButton("doc.plaintext", help: "Session Transcript") {
                        transcript = TranscriptTarget(id: id)
                    }
                }
            }
            .frame(width: 22)
        }
    }

    @ViewBuilder
    private func logTail(_ log: ConnectionLog) -> some View {
        if log.dsDidFail {
            let message = HostDetailFormat.firstLine(of: log.errorMessage) ?? String(localized: "Failed")
            Text(verbatim: message)
                .font(DS.Font.caption)
                // Towards the label colour: plain red is too faint on a light card.
                .foregroundStyle(DS.Palette.danger.mix(with: .primary, by: 0.25))
                .truncationMode(.tail)
                .help(Text(verbatim: log.errorMessage ?? message))
        } else if HostDetailFormat.openLogIds(in: logs, sessionCount: sessionCount).contains(log.id ?? -1) {
            Text("In progress")
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
        } else if let duration = log.durationMs, duration > 0 {
            // No duration recorded: nothing, not a dash.
            Text(verbatim: DSLogStats.durationText(ms: duration))
                .font(DS.Font.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Configuration

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Configuration")
            DSGroup {
                authenticationRow
                // Once read, the system is in the header; here only the note that it will be.
                if host.systemDescription == nil {
                    systemRow
                }
                if let group = viewModel.allGroups.first(where: { $0.id == host.groupId }) {
                    row("Group") {
                        Text(verbatim: group.name)
                    }
                }
                if let snippet = viewModel.snippets.first(where: { $0.id == host.startupSnippetId }), let id = snippet.id {
                    linkRow("Startup Snippet") {
                        appViewModel.reveal(.snippets, id: String(id))
                    } value: {
                        Text(verbatim: HostDetailFormat.firstLine(of: snippet.command) ?? snippet.name)
                            .font(DS.Font.mono)
                            .truncationMode(.tail)
                    }
                }
                if let themeId = host.terminalTheme {
                    let theme = TerminalTheme.find(themeId)
                    row("Terminal Theme") {
                        DSThemeSwatches(theme: theme)
                        Text(verbatim: theme.name)
                    }
                }
                if host.agentForwarding || host.x11Forwarding {
                    row("Forwarding") {
                        if host.agentForwarding { DSChip("Agent forwarding", symbol: "checkmark") }
                        if host.x11Forwarding { DSChip("X11 forwarding", symbol: "checkmark") }
                    }
                }
                if let notes = host.notes, !notes.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.card) {
                        keyLabel("Notes")
                        Text(verbatim: notes)
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(DS.Font.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, DS.Space.card)
                }
            }
        }
    }

    private static let keys: [LocalizedStringKey] = ["Authentication", "Operating System", "Group", "Startup Snippet",
                                                     "Terminal Theme", "Forwarding", "Notes"]

    /// The key of a row, in a column as wide as the longest key is in the current language
    /// (the values of all rows start on one line, without a width chosen for one language).
    private func keyLabel(_ key: LocalizedStringKey) -> some View {
        DSKeyLabel(key)
            .dsKeyColumn(fitting: Self.keys)
            .padding(.trailing, DS.Space.xs)
    }

    private func row<Value: View>(_ key: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        DSRow {
            keyLabel(key)
            value()
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var authenticationRow: some View {
        if let identity = viewModel.identities.first(where: { $0.id == host.identityId }), let id = identity.id {
            linkRow("Authentication") {
                appViewModel.reveal(.identities, id: String(id))
            } value: {
                Image(systemName: "person")
                    .foregroundStyle(.secondary)
                Text(verbatim: identity.name)
                Text(verbatim: "· \(identity.username)")
                    .foregroundStyle(.secondary)
            }
        } else if host.authType == "privateKey",
                  let key = viewModel.keys.first(where: { $0.id == host.privateKeyId }), let id = key.id {
            linkRow("Authentication") {
                appViewModel.reveal(.keys, id: String(id))
            } value: {
                Image(systemName: "key")
                    .foregroundStyle(.secondary)
                Text(verbatim: key.name)
                Text(verbatim: "· \(key.type.uppercased())")
                    .foregroundStyle(.secondary)
            }
        } else if host.authType == "agent" {
            row("Authentication") {
                Image(systemName: "person.badge.key")
                    .foregroundStyle(.secondary)
                Text("System SSH agent / ~/.ssh keys")
            }
        } else {
            let isSaved = host.id.map { viewModel.savedPasswordHostIds.contains($0) } ?? false
            row("Authentication") {
                Image(systemName: "ellipsis.rectangle")
                    .foregroundStyle(.secondary)
                Text("Password")
                (Text(verbatim: "· ") + Text(isSaved ? "Saved" : "Asked when connecting"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var systemRow: some View {
        row("Operating System") {
            Text("Read after the first connection")
                .foregroundStyle(.tertiary)
        }
    }

    /// A row that names a value and leads to its record on another page.
    private func linkRow<Value: View>(_ key: LocalizedStringKey, action: @escaping () -> Void,
                                      @ViewBuilder value: () -> Value) -> some View {
        let content = value()
        return Button(action: action) {
            DSRow {
                keyLabel(key)
                content
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Host key

    private var hostKeySection: some View {
        let known = viewModel.knownHosts.first { $0.hostname == host.hostname && $0.port == host.port }
        return VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Host Key")
            DSGroup {
                if let known, let id = known.id {
                    Button {
                        appViewModel.reveal(.knownHosts, id: String(id))
                    } label: {
                        HStack(spacing: DS.Space.md) {
                            DSRandomart(fingerprint: known.fingerprint, cell: 4)
                            VStack(alignment: .leading, spacing: 3) {
                                DSChip(verbatim: known.keyType.replacingOccurrences(of: "ssh-", with: "").uppercased())
                                Text(verbatim: known.fingerprint)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, DS.Space.card)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    DSRow {
                        Text("Asked on first connection")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Formatting

/// How the record words its numbers. Pure, so that the rules have tests.
enum HostDetailFormat {
    /// A host has numbers to show once it was connected to: the host itself says so before
    /// its history is read, and a record that failed before the first success counts too.
    static func hasHistory(lastConnected: Date?, recordCount: Int) -> Bool {
        lastConnected != nil || recordCount > 0
    }

    /// "user@host:22": the record names the port also when it is the default.
    static func fullAddress(of host: Host) -> String {
        host.port == 22 ? "\(host.addressDescription):22" : host.addressDescription
    }

    /// When the host was last connected to, as the number of a card and its unit: "3" +
    /// "minutes ago". The wording and the rounding are `DSRelativeTime`'s — the list row next to
    /// the card says the same moment and must say the same number.
    static func lastConnected(_ date: Date?, now: Date = Date()) -> (value: String, unit: String?) {
        guard let date else { return (String(localized: "Never"), nil) }
        return DSRelativeTime.parts(for: date, now: now)
    }

    /// "n in the last 14 days" under the number of connections: only when it is another number.
    static func showsRecentCount(recent: Int, total: Int) -> Bool {
        total > 0 && recent != total
    }

    /// "Today 21:57", "Yesterday 09:12:45", else the date and the time.
    static func dayAndTime(_ date: Date, showsSeconds: Bool, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: showsSeconds ? .standard : .shortened)
        if calendar.isDateInToday(date) {
            return "\(String(localized: "Today")) \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "\(String(localized: "Yesterday")) \(time)"
        }
        return "\(date.formatted(.dateTime.month().day())) \(time)"
    }

    /// Whole percent of the connections that did not fail; nil without connections.
    static func successPercent(total: Int, failed: Int) -> Int? {
        guard total > 0 else { return nil }
        return Int((Double(total - failed) / Double(total) * 100).rounded())
    }

    /// A duration as a clock, "4:12" or "1:08:05"; "—" when none was recorded.
    static func clock(ms: Int?) -> String {
        guard let ms, ms > 0 else { return "—" }
        let seconds = max(1, ms / 1000)
        let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        let tail = (rest < 10 ? "0" : "") + String(rest)
        if hours > 0 {
            return "\(hours):\(minutes < 10 ? "0" : "")\(minutes):\(tail)"
        }
        return "\(minutes):\(tail)"
    }

    /// The recorded durations of the latest sessions in seconds, oldest first (`logs` newest first).
    static func recentDurations(in logs: [ConnectionLog], limit: Int = 12) -> [Double] {
        logs.compactMap(\.durationMs).filter { $0 > 0 }.prefix(limit).reversed().map { Double($0) / 1000 }
    }

    /// The log rows of the sessions that are open now: the newest unfinished ones, as many as
    /// there are live sessions (older unfinished rows are sessions that never got to close).
    static func openLogIds(in logs: [ConnectionLog], sessionCount: Int) -> Set<Int64> {
        guard sessionCount > 0 else { return [] }
        let open = logs.filter { !$0.dsDidFail && $0.disconnectedAt == nil && $0.durationMs == nil }
        return Set(open.prefix(sessionCount).compactMap(\.id))
    }

    static func firstLine(of text: String?) -> String? {
        let line = text?.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }
}
