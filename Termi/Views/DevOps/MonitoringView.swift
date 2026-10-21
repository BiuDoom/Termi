import SwiftUI
import Charts

/// Monitoring — pick a server, see its CPU, memory and disk as gauges, CPU and memory over the
/// last five minutes, its load and its network rates.
struct MonitoringView: View {
    @Environment(AppViewModel.self) private var appViewModel

    private var viewModel: MonitorViewModel { appViewModel.monitor }
    @State private var didLoadHosts = false

    var body: some View {
        // No window subtitle: the host is the selected row and the detail's title, the refresh
        // interval is on the switch.
        content
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
            .onDisappear {
                viewModel.stopAutoRefresh()
            }
    }

    #if DEBUG
    /// `-debugMonitorHost <label>` selects that host and turns auto refresh on;
    /// `-debugMonitorHistory YES` puts five minutes of made-up readings in front of the real ones.
    private func applyDebugLaunchArguments() {
        let defaults = AppProfile.arguments
        guard viewModel.selectedHost == nil, let label = defaults.string(forKey: "debugMonitorHost"),
              let host = viewModel.hosts.first(where: { $0.label == label }) else { return }
        viewModel.selectHost(host)
        if defaults.bool(forKey: "debugMonitorHistory") { viewModel.debugSeedHistory() }
        viewModel.startAutoRefresh()
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
            DSMasterDetail(sizing: .fixedMaster(width: ToolsHostMaster<EmptyView>.width,
                                                compactWidth: ToolsHostMaster<EmptyView>.compactWidth)) {
                ToolsHostMaster(hosts: viewModel.hosts, groups: appViewModel.hostsPage.allGroups,
                                selectedKey: viewModel.selectedHost?.connectionKey) { host in
                    viewModel.selectHost(host)
                } trailing: { host in
                    masterReading(host)
                }
            } detail: {
                detail
            }
            // One stage behind the host column and the detail: no seam where they meet.
            .dsStageBackground()
        }
    }

    /// The host's last CPU reading; nothing while it has none (a column of dashes says nothing).
    @ViewBuilder
    private func masterReading(_ host: Host) -> some View {
        if let stats = host.id.flatMap({ viewModel.lastStats[$0] }) {
            let text = MonitorFormat.percent(stats.cpuUsage)
            Text(verbatim: text)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(DS.Motion.standard, value: text)
                .accessibilityLabel(Text("CPU"))
                .accessibilityValue(Text(verbatim: text))
        }
    }

    private var detail: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 520
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    if let host = viewModel.selectedHost {
                        MonitorDashboard(host: host, viewModel: viewModel, isCompact: isCompact,
                                         status: appViewModel.avatarStatus(forHostId: host.id))
                            .id(host.connectionKey)
                            .transition(.opacity)
                    } else {
                        hostPicker(isCompact: isCompact)
                    }
                }
                .padding(.horizontal, isCompact ? DS.Space.lg : DS.Space.page)
                .padding(.top, DS.Space.sm)
                .padding(.bottom, DS.Space.xl)
                // The trend chart takes the height that is left in a tall window.
                .frame(minHeight: proxy.size.height, alignment: .top)
                .animation(DS.Motion.standard, value: viewModel.selectedHost?.connectionKey)
            }
        }
    }

    /// No host chosen: the page as it will look (empty gauges), and the hosts to pick from.
    /// Nothing is selected by itself — reading a host connects to it, which may ask for a password.
    @ViewBuilder
    private func hostPicker(isCompact: Bool) -> some View {
        DSStatGrid(minimum: isCompact ? 96 : 150) {
            MonitorGaugeCard("CPU", symbol: "cpu", percent: nil, detail: "—", isCompact: isCompact)
            MonitorGaugeCard("Memory", symbol: "memorychip", percent: nil, detail: "—", isCompact: isCompact)
            MonitorGaugeCard("Disk", symbol: "internaldrive", percent: nil, detail: "—", isCompact: isCompact)
        }
        .opacity(0.5)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("No Host Selected")
                .font(DS.Font.pageTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Select a host to view its CPU, memory, disk and load.")
                .font(DS.Font.body)
                .foregroundStyle(.secondary)
        }
        .padding(.top, DS.Space.md)

        DSHostPickerGrid(hosts: viewModel.hosts, liveHostIds: appViewModel.connectedHostIds) { host in
            viewModel.selectHost(host)
        }
    }

    nonisolated static func uptimeSummary(_ raw: String) -> String {
        MonitorFormat.uptimeSummary(raw)
    }
}

// MARK: - Host column of the tools pages

/// The master column of Monitoring and Docker: the saved hosts by group, one of them selected,
/// each with the page's own reading at the trailing edge.
struct ToolsHostMaster<Trailing: View>: View {
    static var width: CGFloat { 280 }
    static var compactWidth: CGFloat { 240 }

    @Environment(AppViewModel.self) private var appViewModel
    private let hosts: [Host]
    private let groups: [HostGroup]
    private let selectedKey: String?
    private let onSelect: (Host) -> Void
    private let trailing: (Host) -> Trailing

    init(hosts: [Host], groups: [HostGroup], selectedKey: String?, onSelect: @escaping (Host) -> Void,
         @ViewBuilder trailing: @escaping (Host) -> Trailing) {
        self.hosts = hosts
        self.groups = groups
        self.selectedKey = selectedKey
        self.onSelect = onSelect
        self.trailing = trailing
    }

    var body: some View {
        let sections = ToolsHostSections.make(hosts: hosts, groups: groups)
        DSMasterList(selection: selection, order: sections.flatMap { $0.hosts.map(\.connectionKey) }) {
            ForEach(sections) { section in
                // One unnamed section — no groups in use — needs no header.
                if sections.count > 1 || section.group != nil {
                    if let group = section.group {
                        DSListSectionHeader(verbatim: group.name, count: section.hosts.count)
                    } else {
                        DSListSectionHeader("Ungrouped", count: section.hosts.count)
                    }
                }
                ForEach(section.hosts, id: \.connectionKey) { host in
                    DSHostRow(host, status: appViewModel.avatarStatus(forHostId: host.id)) {
                        trailing(host)
                    }
                    .dsListRow(isSelected: selectedKey == host.connectionKey)
                    .id(host.connectionKey)
                    .onTapGesture { pick(host.connectionKey) }
                    // A tap gesture is nothing VoiceOver can press: the row is a button to it.
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { pick(host.connectionKey) }
                }
            }
        }
        .padding(.top, DS.Space.xs)
    }

    private var selection: Binding<String?> {
        Binding(get: { selectedKey }, set: { pick($0) })
    }

    /// Picking the selected host again does nothing: its readings stay.
    private func pick(_ key: String?) {
        guard let key, key != selectedKey, let host = hosts.first(where: { $0.connectionKey == key }) else { return }
        onSelect(host)
    }
}

/// The hosts of a tools page in the order they are listed: the groups in their order, then the
/// hosts that are in none (or in one that is gone).
struct ToolsHostSections: Identifiable {
    let group: HostGroup?
    let hosts: [Host]
    var id: Int64 { group?.id ?? -1 }

    static func make(hosts: [Host], groups: [HostGroup]) -> [ToolsHostSections] {
        var sections: [ToolsHostSections] = []
        for group in groups {
            let members = hosts.filter { $0.groupId != nil && $0.groupId == group.id }
            if !members.isEmpty {
                sections.append(ToolsHostSections(group: group, hosts: members))
            }
        }
        let grouped = Set(sections.flatMap { $0.hosts.map(\.connectionKey) })
        let rest = hosts.filter { !grouped.contains($0.connectionKey) }
        if !rest.isEmpty {
            sections.append(ToolsHostSections(group: nil, hosts: rest))
        }
        return sections
    }
}

// MARK: - Dashboard

/// The readings of the selected host.
private struct MonitorDashboard: View {
    let host: Host
    let viewModel: MonitorViewModel
    let isCompact: Bool
    let status: DSHostAvatar.Status

    private var stats: MonitorService.ServerStats? { viewModel.stats }
    private var history: [MonitorViewModel.Sample] { viewModel.history }

    var body: some View {
        header

        if let error = viewModel.error {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                DSMessage(verbatim: error)
                Button("Retry") {
                    Task { await viewModel.fetchStats() }
                }
                .dsButtonStyle(.glass, size: .small)
                .disabled(viewModel.isLoading)
                .padding(.top, DS.Space.xs)
            }
        }

        Group {
            gauges
            MonitorTrendCard(history: history, isAutoRefresh: viewModel.isAutoRefresh, isCompact: isCompact)
            tiles
        }
        // A reading that could not be renewed stays, dimmed: it is a moment old.
        .opacity(viewModel.error != nil && stats != nil ? 0.5 : 1)
    }

    // MARK: Header

    private var header: some View {
        DSDetailHeader(title: host.displayName) {
            DSHostAvatar(host, size: DS.Tile.header, status: status)
        } accessory: {
            HStack(spacing: DS.Space.sm) {
                // The first reading connects, which may take a while (or ask for a password).
                if stats == nil && viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Loading…"))
                }
                Text(verbatim: facts)
                    .font(DS.Font.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .help(factsHelp)
            }
        } actions: {
            autoRefreshToggle
            DSGlassIconButton("arrow.clockwise", help: "Refresh (⌘R)") {
                Task { await viewModel.fetchStats() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(viewModel.isLoading)
        }
    }

    /// "Ubuntu 24.04 LTS · Up 41 days"; the address until the host has answered. (The number of
    /// processes is under the CPU gauge.)
    private var facts: String {
        guard let stats else { return host.systemDescription ?? host.addressDescription }
        var parts = [host.osName ?? stats.hostname]
        if !stats.uptime.isEmpty { parts.append(MonitorFormat.uptimeText(stats.uptime)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What the line had to leave out or shorten: the host's own name and `uptime` as it printed it.
    private var factsHelp: String {
        guard let stats else { return host.addressDescription }
        return [stats.hostname, host.systemDescription ?? "", stats.uptime.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var autoRefreshToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.isAutoRefresh },
            set: { newValue in
                if newValue {
                    viewModel.startAutoRefresh()
                } else {
                    viewModel.stopAutoRefresh()
                }
            }
        )) {
            Text("Auto Refresh")
                .font(DS.Font.label)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.leading, 13)
        .padding(.trailing, DS.Space.sm)
        .frame(height: DS.Height.control)
        .dsGlass(.capsule)
        .help("Automatically refresh stats every 5 seconds")
    }

    // MARK: Gauges

    /// The three levels. Their trend is drawn once, in the chart below — on the narrow page
    /// too: a line under CPU and memory would repeat it, and leave a hole under the disk.
    private var gauges: some View {
        DSStatGrid(minimum: isCompact ? 96 : 150) {
            MonitorGaugeCard("CPU", symbol: "cpu", percent: stats?.cpuUsage,
                             detail: MonitorFormat.cpuDetail(processes: stats?.processes),
                             isHero: true, isCompact: isCompact)
            MonitorGaugeCard("Memory", symbol: "memorychip", percent: stats?.memPercent,
                             detail: stats.map { MonitorFormat.pair(used: $0.memUsed, total: $0.memTotal) } ?? "—",
                             isCompact: isCompact)
            MonitorGaugeCard("Disk", symbol: "internaldrive", percent: stats?.diskPercent,
                             detail: stats.map { MonitorFormat.pair(used: $0.diskUsed, total: $0.diskTotal) } ?? "—",
                             isCompact: isCompact)
        }
    }

    // MARK: Load and network

    @ViewBuilder
    private var tiles: some View {
        if isCompact {
            loadCard
            networkCard
        } else {
            HStack(alignment: .top, spacing: DS.Space.card) {
                loadCard
                    .frame(width: 280)
                networkCard
            }
        }
    }

    private var loadCard: some View {
        MonitorTile("Load", symbol: "gauge.medium") {
            DSDividedRow {
                DSValueCell(value: stats.map { MonitorFormat.load($0.loadAvg1) } ?? "—", caption: String(localized: "1 min"))
                DSValueCell(value: stats.map { MonitorFormat.load($0.loadAvg5) } ?? "—", caption: String(localized: "5 min"))
                DSValueCell(value: stats.map { MonitorFormat.load($0.loadAvg15) } ?? "—", caption: String(localized: "15 min"))
            }
        }
    }

    private var networkCard: some View {
        MonitorTile("Network", symbol: "network") {
            DSDividedRow {
                rateCell(symbol: "arrow.down", rate: history.last?.rxRate, rates: history.map(\.rxRate),
                         total: stats.map { String(localized: "\(MonitorFormat.bytes($0.networkRx)) received") })
                rateCell(symbol: "arrow.up", rate: history.last?.txRate, rates: history.map(\.txRate),
                         total: stats.map { String(localized: "\(MonitorFormat.bytes($0.networkTx)) sent") })
            }
        }
    }

    /// arrow | rate (right-aligned) | unit | trend — the same columns in both halves. A rate
    /// needs two readings: until then it is a dash.
    private func rateCell(symbol: String, rate: Double?, rates: [Double], total: String?) -> some View {
        let parts = history.count > 1 ? rate.map { MonitorFormat.rate($0) } : nil
        return DSValueCell(value: parts?.value ?? "—", unit: parts?.unit ?? MonitorFormat.rate(0).unit,
                           caption: total ?? "—", symbol: symbol, valueWidth: 42, unitWidth: 44) {
            DSSparkline(values: Array(rates.dropFirst()), range: MonitorFormat.rateRange(of: Array(rates.dropFirst())),
                        lineWidth: 1.75)
                .frame(minWidth: 24, maxWidth: 64)
                .frame(height: 28)
        }
    }
}

/// One level of the host as an arc gauge. The card ends under the gauge — `DSGaugeCard` keeps
/// a slot for a bottom element whether it has one or not; here nothing stands there (the trend
/// is drawn once, in the chart below) and the height belongs to what follows.
private struct MonitorGaugeCard: View {
    private let title: LocalizedStringKey
    private let symbol: String
    private let percent: Double?
    private let detail: String
    private let isHero: Bool
    /// Three cards share a narrow page: a smaller gauge, a thinner arc, tighter padding.
    private let isCompact: Bool
    @Environment(\.dsFillsRowHeight) private var fillsRowHeight

    init(_ title: LocalizedStringKey, symbol: String, percent: Double?, detail: String, isHero: Bool = false,
         isCompact: Bool) {
        self.title = title
        self.symbol = symbol
        self.percent = percent
        self.detail = detail
        self.isHero = isHero
        self.isCompact = isCompact
    }

    private var tone: DS.Tone { DS.Tone.level(percent: percent ?? 0) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: isCompact ? DS.Space.xs : 6) {
                DSCardLabel(title, symbol: symbol)
                Spacer(minLength: 0)
                levelBadge
            }
            DSArcGauge(percent: percent, detail: detail, diameter: isCompact ? 84 : 128, lineWidth: isCompact ? 8 : 10)
                .padding(.top, isCompact ? DS.Space.xs : 6)
        }
        .padding(.horizontal, isCompact ? DS.Space.card : 14)
        .padding(.vertical, isCompact ? DS.Space.card : DS.Space.md)
        .frame(maxWidth: .infinity, maxHeight: fillsRowHeight ? .infinity : nil, alignment: .top)
        .dsCard(hero: isHero ? tone.color : nil)
        .environment(\.dsTint, tone.color)
        // One element that reads the card whole — "CPU: 23%, 9 processes" — whatever is drawn
        // inside it (combined children once read "CPU, Trend" and left the number out).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: MonitorFormat.gaugeReading(percent: percent, detail: detail, level: levelWord)))
    }

    private var levelWord: String? {
        switch tone {
        case .warning: String(localized: "High")
        case .danger: String(localized: "Critical")
        default: nil
        }
    }

    /// A level is a status, and a status is never colour alone (as `DSGaugeCard` says it).
    @ViewBuilder
    private var levelBadge: some View {
        switch tone {
        case .warning: DSStatusPill("High", tone: .warning, showsBackground: false)
        case .danger: DSStatusPill("Critical", tone: .danger, showsBackground: false)
        default: EmptyView()
        }
    }
}

/// A card of the bottom row: its label, then values side by side.
private struct MonitorTile<Content: View>: View {
    private let title: LocalizedStringKey
    private let symbol: String
    private let content: Content

    init(_ title: LocalizedStringKey, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            DSCardLabel(title, symbol: symbol)
            content
        }
        .padding(.horizontal, 14)
        .padding(.top, DS.Space.md)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }
}

// MARK: - Trend chart

/// CPU and memory over the readings that were taken (five minutes at most): CPU in the accent
/// over a faint area, memory as a quiet grey line, the peak of the CPU named. The only place
/// the two series are drawn; the current values are on the gauges.
private struct MonitorTrendCard: View {
    let history: [MonitorViewModel.Sample]
    let isAutoRefresh: Bool
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: 14) {
                // What is drawn is said by the legend at the other end of the line.
                Text("Last 5 Minutes")
                    .font(DS.Font.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                key("CPU", color: DS.Palette.accent, glows: true)
                key("Memory", color: .secondary, glows: false)
            }
            .frame(height: 18)

            if history.count > 1 {
                chart
            } else {
                placeholder
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, DS.Space.md)
        .padding(.top, DS.Space.md)
        .padding(.bottom, DS.Space.sm)
        .frame(minHeight: isCompact ? 150 : 200, idealHeight: isCompact ? 150 : 200, maxHeight: .infinity)
        .dsCard()
    }

    /// The legend: a line in the series' colour and its name. The current reading is on the gauge.
    private func key(_ title: LocalizedStringKey, color: Color, glows: Bool) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color)
                .frame(width: 14, height: 3)
                .shadow(color: color.opacity(glows ? 0.7 : 0), radius: 4)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// One reading is a point, not a trend.
    private var placeholder: some View {
        VStack(spacing: DS.Space.sm) {
            if isAutoRefresh {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Turn on auto refresh to draw a trend")
                    .font(DS.Font.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chart: some View {
        let accent = DS.Palette.accent
        let peak = MonitorFormat.peak(of: history)
        return Chart {
            ForEach(history) { sample in
                LineMark(x: .value("Time", sample.date), y: .value("Memory", sample.memory),
                         series: .value("Series", "memory"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(history) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value("CPU", sample.cpu))
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.34), accent.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", sample.date), y: .value("CPU", sample.cpu),
                         series: .value("Series", "cpu"))
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let peak {
                PointMark(x: .value("Time", peak.date), y: .value("CPU", peak.cpu))
                    .symbol {
                        Circle()
                            .strokeBorder(accent, lineWidth: 1.5)
                            .frame(width: 8, height: 8)
                    }
            }
            if let last = history.last {
                PointMark(x: .value("Time", last.date), y: .value("Memory", last.memory))
                    .symbol {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 7, height: 7)
                    }
                PointMark(x: .value("Time", last.date), y: .value("CPU", last.cpu))
                    .symbol {
                        Circle()
                            .fill(accent)
                            .frame(width: 8, height: 8)
                    }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: MonitorFormat.timeDomain(of: history))
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 25, 50, 75, 100]) { _ in
                AxisGridLine()
                AxisValueLabel()
                    .font(.system(size: 10).monospacedDigit())
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: isCompact ? 3 : 5)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                AxisValueLabel(format: MonitorFormat.axisTime(for: history))
                    .font(.system(size: 10).monospacedDigit())
            }
        }
        .chartLegend(.hidden)
        // The peak's label, placed by hand next to its point (a mark annotation is laid out
        // against the whole plot and ends up far from it).
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let peak, let frame = proxy.plotFrame, let x = proxy.position(forX: peak.date),
                   let y = proxy.position(forY: peak.cpu) {
                    let origin = geometry[frame].origin
                    Text("Peak \(MonitorFormat.percent(peak.cpu))")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(width: 0, height: 0, alignment: .bottomLeading)
                        .position(x: origin.x + x + 8, y: max(origin.y + y - 4, 12))
                }
            }
        }
        .accessibilityLabel(Text("CPU and Memory · Last 5 Minutes"))
    }
}

// MARK: - Formatting

/// How the monitoring page writes its numbers. Pure, for the tests.
enum MonitorFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// What a gauge card says to assistive technologies after its title: "23%, 9 processes",
    /// with the level's word when it has one ("91%, 7.2 / 8 GB, Critical"); the detail alone
    /// before the host has answered.
    static func gaugeReading(percent: Double?, detail: String, level: String?) -> String {
        var parts: [String] = []
        if let percent { parts.append(Self.percent(percent)) }
        if !detail.isEmpty, detail != "—" { parts.append(detail) }
        if let level { parts.append(level) }
        return parts.isEmpty ? String(localized: "No data") : parts.joined(separator: ", ")
    }

    /// "12%"
    static func percent(_ value: Double) -> String {
        "\(Int(MonitorViewModel.clampedPercent(value).rounded()))%"
    }

    /// Under the CPU gauge: "148 processes" (the load has its own card); a dash before the host
    /// has answered or when it did not say.
    static func cpuDetail(processes: Int?) -> String {
        guard let processes, processes > 0 else { return "—" }
        return String(localized: "\(processes) processes")
    }

    /// Load averages: two decimals, one from 10 up (the column is narrow).
    static func load(_ value: Double) -> String {
        String(format: value < 10 ? "%.2f" : "%.1f", locale: .current, value)
    }

    /// One decimal below 10, none from there: "3.1", "49".
    private static func figure(_ value: Double) -> String {
        String(format: value < 9.95 ? "%.1f" : "%.0f", locale: .current, value)
    }

    /// The power of 1024 a byte count is written in (0 = bytes … 5 = PB).
    private static func exponent(for bytes: Double) -> Int {
        var exponent = 0
        var value = bytes
        while value >= 1024, exponent < units.count - 1 {
            value /= 1024
            exponent += 1
        }
        return exponent
    }

    /// "3.4 GB"
    static func bytes(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        let exponent = Self.exponent(for: value)
        return "\(figure(value / pow(1024, Double(exponent)))) \(units[exponent])"
    }

    /// "3.1 / 7.6 GB": used and total with the unit written once — or each with its own
    /// ("27 GB / 1.4 TB") when the used amount would round to nothing in the total's unit.
    static func pair(used: Int64, total: Int64) -> String {
        guard total > 0 else { return "—" }
        let exponent = Self.exponent(for: Double(total))
        let divisor = pow(1024, Double(exponent))
        let usedValue = Double(max(used, 0)) / divisor
        if used > 0, usedValue < 0.1 { return "\(bytes(used)) / \(bytes(total))" }
        return "\(figure(usedValue)) / \(figure(Double(total) / divisor)) \(units[exponent])"
    }

    /// A transfer rate as its number and its unit: ("1.2", "MB/s").
    static func rate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let value = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        let exponent = Self.exponent(for: value)
        let scaled = value / pow(1024, Double(exponent))
        return (exponent == 0 ? String(format: "%.0f", scaled) : figure(scaled), units[exponent] + "/s")
    }

    /// `uptime` prints " 10:32:01 up 12 days,  3:04,  2 users,  load average: …"; the page only
    /// needs "12 days, 3:04". Anything in another shape is returned as it came.
    static func uptimeSummary(_ raw: String) -> String {
        guard let match = raw.firstMatch(of: /\bup\s+(.+?),\s*(?:\d+\s+users?|load averages?)/) else {
            return raw
        }
        return match.1.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Seconds the host has been up, from what `uptime` printed ("up 41 days,  3:12", "up 5 min",
    /// "up 2 hrs"); nil when it has another shape.
    static func uptimeSeconds(_ raw: String) -> Int? {
        let summary = uptimeSummary(raw)
        var seconds = 0
        var found = false
        if let match = summary.firstMatch(of: /(\d+)\s+days?/), let days = Int(match.1) {
            seconds += days * 86_400
            found = true
        }
        if let match = summary.firstMatch(of: /(\d+):(\d\d)/), let hours = Int(match.1), let minutes = Int(match.2) {
            seconds += hours * 3600 + minutes * 60
            found = true
        }
        if let match = summary.firstMatch(of: /(\d+)\s+(?:hrs?|hours?)/), let hours = Int(match.1) {
            seconds += hours * 3600
            found = true
        }
        if let match = summary.firstMatch(of: /(\d+)\s+mins?/), let minutes = Int(match.1) {
            seconds += minutes * 60
            found = true
        }
        if let match = summary.firstMatch(of: /(\d+)\s+secs?/), let secs = Int(match.1) {
            seconds += secs
            found = true
        }
        return found ? seconds : nil
    }

    /// "Up 41 days" in the interface language (the largest unit only); `uptime`'s own words when
    /// they could not be read.
    static func uptimeText(_ raw: String) -> String {
        guard let seconds = uptimeSeconds(raw) else { return uptimeSummary(raw) }
        let span = Duration.seconds(max(seconds, 60))
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 1))
        return String(localized: "Up \(span)")
    }

    /// The highest CPU reading, when it is worth naming: there is a trend, the peak is not the
    /// newest reading (which the gauge already gives), and it stands out from it.
    static func peak(of history: [MonitorViewModel.Sample]) -> MonitorViewModel.Sample? {
        guard history.count > 2, let last = history.last,
              let peak = history.max(by: { $0.cpu < $1.cpu }),
              peak.id != last.id, peak.cpu - last.cpu >= 5 else { return nil }
        return peak
    }

    /// The scale of a small percent trend: the readings' own range, but never less than ten
    /// points wide — scaled to itself, a step from 0 % to 1 % would fill the card like a surge.
    static func percentRange(of values: [Double], minimumSpan: Double = 10) -> ClosedRange<Double> {
        let domain = DSSparkline.domain(for: values)
        let span = domain.upperBound - domain.lowerBound
        guard span < minimumSpan else { return domain }
        // Widen around the readings, without leaving 0…100 at either end.
        let low = min(max(domain.lowerBound - (minimumSpan - span) / 2, 0), 100 - minimumSpan)
        return low...(low + minimumSpan)
    }

    /// The scale of a small rate trend: from zero, so that a steady rate is a level line and
    /// its ripple is not drawn as peaks.
    static func rateRange(of rates: [Double]) -> ClosedRange<Double> {
        let peak = rates.filter(\.isFinite).max() ?? 0
        return 0...max(peak * 1.12, 1)
    }

    /// The labels of the time axis: to the second while the trend is short, to the minute once
    /// it spans more than two.
    static func axisTime(for history: [MonitorViewModel.Sample]) -> Date.FormatStyle {
        let domain = timeDomain(of: history)
        let base = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        return domain.upperBound.timeIntervalSince(domain.lowerBound) > 120 ? base : base.second(.twoDigits)
    }

    /// The time axis: from the first reading to the newest, at least a minute wide so that the
    /// first few readings are not stretched across the card.
    static func timeDomain(of history: [MonitorViewModel.Sample]) -> ClosedRange<Date> {
        let end = history.last?.date ?? Date()
        let start = history.first?.date ?? end
        return min(start, end.addingTimeInterval(-60))...end
    }
}
