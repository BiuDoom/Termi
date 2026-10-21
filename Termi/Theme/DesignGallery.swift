#if DEBUG
import SwiftUI
import AppKit

/// Every shared component with sample data, laid out like the approved mockups so that the two
/// can be compared side by side. Debug builds only:
/// `-debugSheet gallery -debugGalleryPage 1…6 [-debugGalleryScroll <points>]`
/// 1 tiles and glass · 2 a host's detail (Main) · 3 gauges and values (Monitoring) ·
/// 4 master list, fingerprint, rows (Keys) · 5 skeletons and the rest · 6 the vault page shell.
struct DSGalleryView: View {
    private let page: Int
    private let scroll: CGFloat?
    @State private var selectedHost: String? = "host-2"
    @State private var filter = 0
    @State private var forwardRuns = true
    @State private var forwardStopped = false

    init() {
        let defaults = AppProfile.arguments
        page = max(1, defaults.integer(forKey: "debugGalleryPage"))
        scroll = defaults.object(forKey: "debugGalleryScroll") == nil
            ? nil : CGFloat(defaults.double(forKey: "debugGalleryScroll"))
    }

    var body: some View {
        Group {
            if let scroll {
                // A fixed offset instead of a scroll view: a screenshot of "the part 600 pt
                // down" has to come out the same every time.
                GeometryReader { _ in
                    content
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: -scroll)
                }
                .clipped()
            } else {
                ScrollView { content }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsStageBackground()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            switch page {
            case 2: hostDetail
            case 3: monitoring
            case 4: keys
            case 5: skeletons
            case 6: vaultShell
            default: tilesAndGlass
            }
        }
        .padding(.horizontal, DS.Space.page)
        .padding(.vertical, DS.Space.xl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func section<Content: View>(_ title: String, _ note: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.card) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text(verbatim: title)
                    .font(DS.Font.label)
                if let note {
                    Text(verbatim: note)
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
    }

    // MARK: Page 1 — tiles and glass

    @ViewBuilder
    private var tilesAndGlass: some View {
        HStack(alignment: .top, spacing: DS.Space.xxxl) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                section("DSHostAvatar", "16 · 20 · 30 · 38 · 48 · 64, lit from the top-left; glow from 36") {
                    HStack(alignment: .bottom, spacing: DS.Space.lg) {
                        ForEach(Array(Sample.ladder.enumerated()), id: \.offset) { index, size in
                            DSHostAvatar(os: Sample.systems[index % Sample.systems.count], size: size, status: .live)
                        }
                    }
                }
                section("Status", "none · live · busy · failed · ended · local · on a selected row") {
                    HStack(spacing: DS.Space.md) {
                        ForEach(Array(Sample.statuses.enumerated()), id: \.offset) { index, status in
                            DSHostAvatar(os: Sample.systems[index], size: DS.Tile.card, status: status)
                        }
                        DSHostAvatar.local(size: DS.Tile.card, status: .live)
                        DSHostAvatar(Sample.hosts[5], size: DS.Tile.card)
                        HStack(spacing: DS.Space.md) {
                            DSHostAvatar(os: Sample.systems[0], size: DS.Tile.row, status: .live)
                            DSHostAvatar(os: Sample.systems[1], size: DS.Tile.row, status: .failed)
                        }
                        .padding(DS.Space.sm)
                        .background(DS.Palette.accent, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
                    }
                }
                section("DSCategoryTile · DSIconTile(.monogram) · DSHostStack") {
                    HStack(spacing: DS.Space.md) {
                        DSCategoryTile("key.fill")
                        DSCategoryTile(page: .knownHosts, size: DS.Tile.large)
                        DSCategoryTile("curlybraces", size: DS.Tile.card)
                        DSCategoryTile(page: .sftp, size: DS.Tile.row)
                        DSIconTile(.monogram("R"), tint: DS.Palette.accent, size: DS.Tile.row)
                        DSCategoryTile("person.fill", size: DS.Tile.sidebar)
                        DSHostStack(hosts: Array(Sample.hosts.prefix(3)))
                        DSHostStack(hosts: Sample.hosts)
                    }
                }
                section("DSChip · DSStatusPill") {
                    HStack(spacing: 6) {
                        DSStatusPill(verbatim: "Connected · 2 sessions")
                        DSChip(verbatim: "Ubuntu 24.04 LTS · aarch64")
                        DSChip(verbatim: "#prod")
                        DSChip(verbatim: "ED25519", isMonospaced: true)
                        DSChip(verbatim: "Passphrase", symbol: "lock")
                        DSChip(verbatim: "Strong", symbol: "checkmark.circle", tint: DS.Palette.success)
                        DSChip(verbatim: "Weak", symbol: "exclamationmark.triangle", tint: DS.Palette.warning)
                    }
                    HStack(spacing: 6) {
                        DSStatusPill(verbatim: "Connecting", tone: .warning, isPulsing: true)
                        DSStatusPill(verbatim: "Failed", tone: .danger)
                        DSStatusPill(verbatim: "Ended", tone: .inactive)
                        DSStatusPill(verbatim: "Running", showsBackground: false)
                        DSStatusPill(verbatim: "Stopped", tone: .inactive, showsBackground: false)
                    }
                }
            }
            section("DSSidebarLabel", "accent glyph, no tile") {
                List {
                    Section {
                        ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                            DSSidebarLabel(item: item)
                                .badge(index.isMultiple(of: 3) ? 0 : index * 2 + 1)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(width: 216, height: 440)
                .dsGlass(.rect(DS.Radius.panel))
            }
        }

        section("Buttons", "dsButtonStyle(.prominent) — one per screen · .glass · DSGlassIconButton · small") {
            DSGlassContainer(spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.sm) {
                    Button {} label: { Label { Text(verbatim: "Connect") } icon: { Image(systemName: "bolt.fill") } }
                        .dsButtonStyle(.prominent)
                    Button {} label: { Label { Text(verbatim: "SFTP") } icon: { Image(systemName: "folder") } }
                        .dsButtonStyle(.glass)
                    DSGlassIconButton("ellipsis", help: raw("More")) {}
                    Button {} label: { Text(verbatim: "Disabled") }
                        .dsButtonStyle(.glass)
                        .disabled(true)
                    Button(role: .destructive) {} label: { Text(verbatim: "Delete") }
                        .dsButtonStyle(.glass)
                    Divider().frame(height: 20)
                    Button {} label: { Text(verbatim: "Install") }
                        .dsButtonStyle(.prominent, size: .small)
                    Button {} label: { Text(verbatim: "Copy") }
                        .dsButtonStyle(.glass, size: .small)
                    DSGlassIconButton("arrow.clockwise", help: raw("Refresh"), size: .small) {}
                }
            }
        }
        section("DSFilterChip", "glass capsule; the chosen one is inverted") {
            DSGlassContainer(spacing: 7) {
                HStack(spacing: 7) {
                    ForEach(Array(Sample.filters.enumerated()), id: \.offset) { index, item in
                        DSFilterChip(verbatim: item.0, count: item.1, isSelected: filter == index) { filter = index }
                    }
                }
            }
        }
        HStack(alignment: .top, spacing: DS.Space.xxl) {
            section("dsFloatingBar", "capsule: status bar, transfer bar, selection actions") {
                HStack(spacing: DS.Space.md) {
                    DSStatusPill(verbatim: "Connected", showsBackground: false)
                    Text(verbatim: "deploy@10.0.12.4")
                        .font(DS.Font.mono)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "120 × 36")
                        .font(DS.Font.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    DSRowButton("magnifyingglass", help: raw("Find")) {}
                }
                .padding(.horizontal, DS.Space.lg)
                .frame(height: 40)
                .dsFloatingBar()
            }
            section("dsFloatingPanel", "command palette, state cards") {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text(verbatim: "web")
                        Spacer()
                        DSShortcut("⌘K")
                    }
                    .font(.system(size: 15))
                    Divider()
                    DSHostRow(Sample.hosts[1], status: .live) { Text(verbatim: "Connect") }
                        .dsListRow(isSelected: true)
                    DSHostRow(Sample.hosts[2]) { Text(verbatim: "yesterday") }
                        .dsListRow(isSelected: false)
                }
                .padding(DS.Space.md)
                .frame(width: 340)
                .dsFloatingPanel()
            }
        }
        .padding(.bottom, DS.Space.xxxl)
    }

    // MARK: Page 2 — a host's detail (Main.png)

    @ViewBuilder
    private var hostDetail: some View {
        DSDetailHeader(title: "web-01", subtitle: "deploy@10.0.12.4:22") {
            DSHostAvatar(os: Sample.systems[0], size: DS.Tile.header, status: .live)
        } accessory: {
            DSStatusPill(verbatim: "Connected · 2 sessions")
            DSChip(verbatim: "Ubuntu 24.04 LTS · aarch64")
            DSChip(verbatim: "#prod")
            DSChip(verbatim: "#web")
        } actions: {
            Button {} label: { Label { Text(verbatim: "Connect") } icon: { Image(systemName: "bolt.fill") } }
                .dsButtonStyle(.prominent)
            Button {} label: { Label { Text(verbatim: "SFTP") } icon: { Image(systemName: "folder") } }
                .dsButtonStyle(.glass)
            DSGlassIconButton("ellipsis", help: raw("More")) {}
        }

        DSStatGrid {
            DSStatCard(raw("Last Connected"), value: "3", unit: "minutes ago", symbol: "clock", footnote: "Today 21:57") {
                DSDayStrip(days: DSDayStrip.days(from: Sample.days(14)))
            }
            DSStatCard(raw("Connections"), value: "164", symbol: "waveform.path.ecg", footnote: "50 in the last 14 days") {
                DSSparkline(values: Sample.daily).frame(height: 20)
            }
            DSStatCard(raw("Success"), value: "98", unit: "%", symbol: "checkmark.circle", footnote: "3 failed") {
                DSMeter(percent: 98)
            }
            DSStatCard(raw("Average"), value: "4:12", symbol: "timer", footnote: "longest 1 h 8 min") {
                DSSparkline(values: Sample.durations).frame(height: 20)
            }
        }

        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader(raw("Route"))
            DSGroup {
                DSRouteDiagram(hops: [.thisMac, .init(host: Sample.hosts[0], status: .live),
                                      .init(host: Sample.hosts[1], status: .live)],
                               activity: .flowing) { _ in }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
            }
        }

        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader(raw("Port Forwards"))
            DSGroup {
                DSRow {
                    DSChip(verbatim: "Local")
                    Text(verbatim: "localhost:18080 → 127.0.0.1:8080")
                        .font(DS.Font.mono)
                    Spacer(minLength: 0)
                    DSStatusPill(verbatim: "Running", showsBackground: false)
                    Toggle(isOn: $forwardRuns) { EmptyView() }
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                DSRow {
                    DSChip(verbatim: "Dynamic")
                    Text(verbatim: "SOCKS  localhost:1080")
                        .font(DS.Font.mono)
                    Spacer(minLength: 0)
                    DSStatusPill(verbatim: "Stopped", tone: .inactive, showsBackground: false)
                    Toggle(isOn: $forwardStopped) { EmptyView() }
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }

        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader(raw("Last 14 Days")) {
                Text(verbatim: "50 connections · 5 today")
            }
            DSGroup {
                DSActivityChart(days: Sample.days(14))
                    .padding(.horizontal, DS.Space.md)
                    .padding(.top, DS.Space.md)
                    .padding(.bottom, DS.Space.sm)
                logRow(ok: true, when: "Today 21:57:32", tail: "4 min 12 s")
                logRow(ok: true, when: "Today 18:03:11", tail: "26 min 40 s")
                logRow(ok: false, when: "Yesterday 09:12:45", tail: "Permission denied (publickey)")
            }
        }

        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader(raw("Configuration"))
            DSGroup {
                DSKeyValueRow(raw("Sign-in")) {
                    Image(systemName: "key")
                        .foregroundStyle(.secondary)
                    Text(verbatim: "web-deploy")
                    Text(verbatim: "· ED25519")
                        .foregroundStyle(.secondary)
                }
                DSKeyValueRow(raw("System"), value: "Ubuntu 24.04.1 LTS · aarch64")
                DSKeyValueRow(raw("Startup"), value: "tmux attach -t main", isMonospaced: true)
            }
        }
    }

    private func logRow(ok: Bool, when: String, tail: String) -> some View {
        DSRow(isCompact: true) {
            Image(systemName: ok ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(ok ? DS.Palette.success : DS.Palette.danger)
            Text(verbatim: when)
                .font(.system(size: 12).monospacedDigit())
            Spacer(minLength: DS.Space.sm)
            Text(verbatim: tail)
                .font(DS.Font.caption.monospacedDigit())
                .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(DS.Palette.danger))
            Image(systemName: "doc.plaintext")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Page 3 — gauges and values (Monitoring.png)

    @ViewBuilder
    private var monitoring: some View {
        DSDetailHeader(title: "web-01", subtitle: nil) {
            DSHostAvatar(os: Sample.systems[0], size: DS.Tile.header, status: .live)
        } accessory: {
            Text(verbatim: "Ubuntu 24.04 LTS · up 41 days · 148 processes")
                .font(DS.Font.body)
                .foregroundStyle(.secondary)
        } actions: {
            DSGlassIconButton("arrow.clockwise", help: raw("Refresh")) {}
        }

        DSStatGrid(minimum: 200) {
            DSGaugeCard(raw("CPU"), symbol: "cpu", percent: 12, detail: "load 0.42", isHero: true) {
                DSSparkline(values: Sample.cpu, range: 0...50, lineWidth: 1.75)
            }
            DSGaugeCard(raw("Memory"), symbol: "memorychip", percent: 41, detail: "3.1 / 7.6 GB") {
                DSSparkline(values: Sample.memory, range: 0...100, lineWidth: 1.75)
            }
            DSGaugeCard(raw("Disk"), symbol: "internaldrive", percent: 63, detail: "49 / 78 GB") {
                VStack(spacing: 6) {
                    HStack {
                        Text(verbatim: "Free")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: "29 GB")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .font(DS.Font.caption)
                    DSMeter(percent: 63)
                }
            }
        }

        HStack(alignment: .top, spacing: DS.Space.card) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                DSCardLabel(raw("Load"), symbol: "gauge.with.dots.needle.33percent")
                DSDividedRow {
                    DSValueCell(value: "0.42", caption: "1 min")
                    DSValueCell(value: "0.31", caption: "5 min")
                    DSValueCell(value: "0.18", caption: "15 min")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, DS.Space.md)
            .frame(width: 264, alignment: .leading)
            .dsCard()

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                DSCardLabel(raw("Network"), symbol: "network")
                DSDividedRow {
                    DSValueCell(value: "1.2", unit: "MB/s", caption: "3.4 GB received", symbol: "arrow.down",
                                valueWidth: 42, unitWidth: 44) {
                        DSSparkline(values: Sample.cpu, lineWidth: 1.5).frame(width: 64, height: 24)
                    }
                    DSValueCell(value: "84", unit: "KB/s", caption: "5.18 GB sent", symbol: "arrow.up",
                                valueWidth: 42, unitWidth: 44) {
                        DSSparkline(values: Sample.durations, lineWidth: 1.5).frame(width: 64, height: 24)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
        }

        section("Levels", "accent below 60 % · orange from 60 % (“High”) · red from 85 % (“Critical”) · no reading") {
            DSStatGrid(minimum: 150) {
                DSGaugeCard(raw("Swap"), percent: 59, detail: "1.2 / 2 GB")
                DSGaugeCard(raw("Disk"), symbol: "internaldrive", percent: 60, detail: "47 / 78 GB")
                DSGaugeCard(raw("Disk"), symbol: "internaldrive", percent: 91, detail: "437 / 480 GB") {
                    DSMeter(percent: 91)
                }
                DSGaugeCard(raw("Memory"), symbol: "memorychip", percent: nil, detail: "—")
            }
        }
        section("DSGaugeCard(diameter: 84)", "three in a narrow page: the detail moves under the arc") {
            DSStatGrid(minimum: 96) {
                DSGaugeCard(raw("CPU"), symbol: "cpu", percent: 12, detail: "load 0.42", isHero: true, diameter: 84) {
                    DSSparkline(values: Sample.cpu, range: 0...50, lineWidth: 1.75)
                }
                DSGaugeCard(raw("Memory"), symbol: "memorychip", percent: 41, detail: "3.1 / 7.6 GB", diameter: 84)
                DSGaugeCard(raw("Disk"), symbol: "internaldrive", percent: 63, detail: "437.5 / 1024.0 GB", diameter: 84)
            }
            .frame(width: 420)
        }
        section("DSActivityChart(marksFailures:) · DSActivityLegend · DSStatCard(lead:) · dsKeyColumn",
                "failed days carry a red mark, said in words by the legend") {
            HStack(alignment: .top, spacing: DS.Space.card) {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack {
                        DSCardLabel(raw("Last 30 Days"))
                        Spacer(minLength: 0)
                        DSActivityLegend()
                    }
                    DSActivityChart(days: Sample.days(30), height: 60, marksFailures: true)
                }
                .padding(14)
                .frame(width: 320)
                .dsCard()
                DSStatGrid(widestOfFew: nil) {
                    DSStatCard(raw("Most Connected"), value: "web-01", symbol: "star", footnote: "164 times · 40%",
                               lead: .system(Sample.systems[0])) {
                        DSMeter(percent: 40)
                    }
                    DSStatCard(raw("Connections"), value: "412", symbol: "waveform.path.ecg", footnote: "8 today") {
                        DSSparkline(values: [3, 3.2, 3.1], minimumSpan: 10)
                            .frame(height: 22)
                    }
                }
                DSGroup {
                    DSKeyValueRow(raw("Authentication"), value: "SSH Agent")
                    DSKeyValueRow(raw("Port"), value: "22", isMonospaced: true)
                }
                .dsKeyColumn(fitting: [raw("Authentication"), raw("Port")])
                .frame(width: 260)
            }
        }
        section("DSStatCard", "status tones only when the number is a status; one hero per screen") {
            DSStatGrid {
                DSStatCard(raw("Running"), value: "3", symbol: "play.circle", footnote: "of 5 containers", tone: .success,
                           isHero: true) {
                    DSMeter(percent: 60)
                }
                DSStatCard(raw("Failed"), value: "2", symbol: "xmark.circle", footnote: "last 14 days", tone: .danger) {
                    DSDayStrip(days: [false, false, true, false, false, false, false, false, true, false, false, false, false, false])
                }
                DSStatCard(raw("Stopped"), value: "2", symbol: "stop.circle", tone: .inactive)
                DSStatCard(raw("Port Forwards"), value: "—")
            }
        }
    }

    // MARK: Page 4 — master list, fingerprint, rows (Keys.png)

    @ViewBuilder
    private var keys: some View {
        HStack(alignment: .top, spacing: DS.Space.xl) {
            VStack(alignment: .leading, spacing: 0) {
                masterList
            }
            .frame(width: DS.Layout.masterWidth, height: 440)

            VStack(alignment: .leading, spacing: DS.Space.lg) {
                DSDetailHeader(title: "ops-bastion", subtitle: "ED25519 · Oct 3, 2026") {
                    DSCategoryTile("key.fill")
                } accessory: {
                    DSChip(verbatim: "Passphrase", symbol: "lock")
                    DSChip(verbatim: "Strong", symbol: "checkmark.circle", tint: DS.Palette.success)
                } actions: {
                    Button {} label: { Label { Text(verbatim: "Install…") } icon: { Image(systemName: "square.and.arrow.up") } }
                        .dsButtonStyle(.prominent)
                    DSGlassIconButton("ellipsis", help: raw("More")) {}
                }

                VStack(alignment: .leading, spacing: 0) {
                    DSSectionHeader(raw("Fingerprint"))
                    HStack(alignment: .top, spacing: DS.Space.lg) {
                        DSRandomart(fingerprint: Sample.fingerprints[0], cell: 10)
                        VStack(alignment: .leading, spacing: DS.Space.sm) {
                            Text(verbatim: Sample.fingerprints[0])
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                            DSDividedRow {
                                DSValueCell(value: "256", unit: "bit", caption: "Length", captionPlacement: .above)
                                DSValueCell(value: "4", caption: "Hosts", captionPlacement: .above)
                                DSValueCell(value: "1", caption: "Identities", captionPlacement: .above)
                            }
                        }
                    }
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCard(hero: DS.Palette.accent)
                }

                VStack(alignment: .leading, spacing: 0) {
                    DSSectionHeader(raw("Public Key"))
                    // Content, not a command: a card (Keys mockup), not the terminal-coloured block.
                    DSGroup {
                        HStack(alignment: .top, spacing: DS.Space.md) {
                            Text(verbatim: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEeOgGko0WJlWv/f7jxbZFtH8zgznY9eUqVKqEtMZGP demo@example.com")
                                .font(DS.Font.mono)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            DSCopyButton(help: raw("Copy")) {}
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, DS.Space.md)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    DSSectionHeader(raw("Used By")) {
                        Text(verbatim: "4 hosts · 1 identity")
                    }
                    DSGroup {
                        DSLinkRow(Sample.hosts[0].displayName, subtitle: Sample.hosts[0].addressDescription, action: {}, icon: {
                            DSHostAvatar(Sample.hosts[0], size: DS.Tile.row, status: .live)
                        }, trailing: {
                            DSStatusPill(verbatim: "1 session")
                        })
                        DSLinkRow("ops", subtitle: "identity · root", action: {}, icon: {
                            DSIconTile(.monogram("R"), tint: DS.Palette.accent, size: DS.Tile.row)
                        }, trailing: {
                            DSHostStack(hosts: Array(Sample.hosts.suffix(3)))
                        })
                        DSLinkRow(host: Sample.hosts[3], detail: "via identity ops") {}
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        section("DSCodeBlock", "terminal-coloured in both appearances; {{variables}} highlighted; wraps unless limited") {
            DSCodeBlock(template: "tar czf {{archive}}.tgz -C {{directory}} . && scp {{archive}}.tgz {{target}}:/data/",
                        prompt: "$")
            DSCodeBlock(template: "tar czf {{archive}}.tgz -C {{directory}} . && scp {{archive}}.tgz {{target}}:/data/",
                        values: ["archive": "release-42", "directory": "/srv/app"], prompt: "$")
            HStack(alignment: .top, spacing: DS.Space.card) {
                DSCodeBlock("ssh -J ops@bastion.example.com:2222 deploy@10.20.1.11", size: .small)
                DSCodeBlock(String(repeating: "drwxr-xr-x  2 deploy deploy 4096 Oct  4 08:00 releases\n", count: 6),
                            size: .small, lineLimit: 3)
            }
        }
        section("DSRandomart", "cell 4 · 8, and no fingerprint") {
            HStack(alignment: .top, spacing: DS.Space.lg) {
                ForEach(Array(Sample.fingerprints.enumerated()), id: \.offset) { item in
                    DSRandomart(fingerprint: item.element, cell: 4)
                }
                DSRandomart(fingerprint: nil, cell: 4)
                DSRandomart(fingerprint: Sample.fingerprints[1], cell: 8)
                // On the accent pill of a selected row the image is white.
                HStack(spacing: DS.Space.md) {
                    DSRandomart(fingerprint: Sample.fingerprints[0], cell: 4)
                    Text(verbatim: "deploy-key")
                        .font(DS.Font.rowTitle)
                    Spacer(minLength: 0)
                }
                .dsListRow(isSelected: true)
                .frame(width: 220)
                DSIconTile(.monogram(DSIconTile.monogram(for: "root", letters: 1)), tint: DS.Palette.accent,
                           size: DS.Tile.card)
            }
        }
    }

    private var masterList: some View {
        DSMasterList(selection: $selectedHost, order: Sample.hosts.map(\.connectionKey)) {
            DSListSectionHeader(verbatim: "Production", count: 4)
            ForEach(Array(Sample.hosts.prefix(4).enumerated()), id: \.element.connectionKey) { index, host in
                hostRow(host, index: index)
            }
            DSListSectionHeader(verbatim: "Ungrouped", count: Sample.hosts.count - 4)
            ForEach(Array(Sample.hosts.dropFirst(4).enumerated()), id: \.element.connectionKey) { index, host in
                hostRow(host, index: index + 4)
            }
        }
    }

    private func hostRow(_ host: Host, index: Int) -> some View {
        let isSelected = selectedHost == host.connectionKey
        return DSHostRow(host, status: index < 2 ? .live : .none, showsJump: index == 1 || index == 3) {
            if index == 0, !isSelected {
                DSStatusPill(verbatim: "1 session")
            } else if index == 1 {
                Text(verbatim: "2 sessions")
            } else {
                DSRelativeTime(host.lastConnectedDate)
            }
        }
        .dsListRow(isSelected: isSelected)
        .id(host.connectionKey)
        .onTapGesture { selectedHost = host.connectionKey }
    }

    // The vault page shell (spec section 三.3 / WP1): toolbar with the split create button,
    // adaptive card grid, inspector panel at the trailing edge.
    private var vaultShell: some View {
        section("DSVaultPage", "toolbar · 3→2 column grid · inspector panel") {
            DSVaultPage(leading: {
                DSCreateButton(title: "New Host", systemImage: "plus",
                               action: {},
                               menu: {
                                   Button("New Group") {}
                                   Button("Import from ~/.ssh/config") {}
                               })
                DSRowButton("terminal", help: "Local Terminal (⌘L)", action: {})
            }, trailing: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("Filter hosts…")
                        .font(DS.Font.body)
                        .foregroundStyle(.secondary)
                    Divider().frame(height: DS.Height.smallControl)
                    DSRowButton("square.grid.2x2", help: "Grid", action: {})
                    DSRowButton("list.bullet", help: "List", action: {})
                }
            }, content: {
                DSItemGrid(inspectorVisible: true, card: {
                    sampleCard("prod-web-01", "ssh · deploy@10.0.1.11", symbol: "server.rack", tint: .indigo)
                    sampleCard("bastion", "ssh · ops@10.0.1.5", symbol: "shield.lefthalf.filled", tint: .orange)
                    sampleCard("db-primary", "ssh · root@10.0.2.20", symbol: "cylinder.split.1x2", tint: .teal)
                    sampleCard("ci-runner", "ssh · ci@10.0.3.30", symbol: "gearshape.2", tint: .pink)
                })
            }, inspector: {
                DSInspectorPanel("Edit Host", onClose: {}) {
                    VStack(alignment: .leading, spacing: DS.Space.lg) {
                        Text(verbatim: "prod-web-01").font(DS.Font.detailTitle)
                        Text(verbatim: "ssh · deploy@10.0.1.11").font(DS.Font.mono).foregroundStyle(.secondary)
                    }
                }
            })
            .frame(height: 620)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(.quaternary))
        }
    }

    private func sampleCard(_ name: String, _ detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: DS.Space.md) {
            DSIconTile(content: .symbol(symbol), tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(DS.Font.rowTitle)
                Text(verbatim: detail).font(DS.Font.mono).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.lg)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    // MARK: Page 5 — skeletons and the rest

    @ViewBuilder
    private var skeletons: some View {
        section("DSMasterDetail", ".fixedMaster (default): master 320 / 260, the selected row is the accent pill") {
            DSMasterDetail {
                masterList
                    .padding(.top, DS.Space.sm)
            } detail: {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    DSDetailHeader(title: "web-01", subtitle: "deploy@10.0.12.4:22") {
                        DSHostAvatar(os: Sample.systems[0], size: DS.Tile.header, status: .live)
                    } accessory: {
                        DSStatusPill(verbatim: "Connected")
                    } actions: {
                        Button {} label: { Text(verbatim: "Connect") }
                            .dsButtonStyle(.prominent)
                    }
                    DSStatGrid {
                        DSStatCard(raw("Connections"), value: "42")
                        DSStatCard(raw("Success"), value: "98", unit: "%")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.page)
                .padding(.top, DS.Space.sm)
            }
            .frame(height: 330)
        }
        HStack(alignment: .top, spacing: DS.Space.xl) {
            section("DSEmptyState", "the page's tile, one sentence, the next step") {
                DSEmptyState(raw("No Hosts"), message: raw("Add a host to connect to it."), page: .terminal) {
                    Button {} label: { Text(verbatim: "New Host") }
                        .dsButtonStyle(.prominent)
                    Button {} label: { Text(verbatim: "Import…") }
                        .dsButtonStyle(.glass)
                }
                .frame(height: 250)
                .dsCard()
                DSEmptyState(raw("Bring a remote port to this Mac"), message: raw("A rule is a route."),
                             page: .portForwards) {
                    DSRouteDiagram(hops: [.endpoint("localhost:8080", symbol: "laptopcomputer"),
                                          .init(host: Sample.hosts[1]), .endpoint("127.0.0.1:80")])
                } actions: {
                    Button {} label: { Text(verbatim: "New Rule") }
                        .dsButtonStyle(.prominent)
                }
                .frame(height: 300)
                .dsCard()
            }
            section("DSHostPickerGrid", "live hosts first") {
                DSHostPickerGrid(hosts: Sample.hosts, liveHostIds: [2, 5], limit: 4) { _ in }
            }
        }
        section("DSRouteDiagram", "idle · flowing · failed · endpoints · the same in 300 pt: a column") {
            DSRouteDiagram(hops: [.thisMac, .init(host: Sample.hosts[1])])
            DSRouteDiagram(hops: [.thisMac, .init(host: Sample.hosts[0]), .init(host: Sample.hosts[3]),
                                  .init(host: Sample.hosts[4], status: .failed)],
                           activity: .failed)
            DSRouteDiagram(hops: [.endpoint("localhost:18080", symbol: "laptopcomputer"),
                                  .init(host: Sample.hosts[1], status: .live), .endpoint("127.0.0.1:8080")],
                           activity: .flowing)
                .frame(maxWidth: 560)
            DSRouteDiagram(hops: [.thisMac, .init(host: Sample.hosts[0], status: .live),
                                  .init(host: Sample.hosts[1], status: .live)],
                           activity: .flowing)
                .frame(width: 300, alignment: .leading)
        }
        section("DSRouteDiagram — columns, pending hops, compact",
                "the middle hop is centred whatever the ends are · reachedHops: 2 · style: .compact") {
            VStack(spacing: DS.Space.sm) {
                DSRouteDiagram(hops: [.endpoint("localhost:18080", symbol: "laptopcomputer"),
                                      .init(host: Sample.hosts[1], status: .live), .endpoint("127.0.0.1:8080")],
                               activity: .flowing)
                DSRouteDiagram(hops: [.endpoint("SOCKS localhost:1080", symbol: "laptopcomputer"),
                                      .init(host: Sample.hosts[1], status: .live),
                                      .endpoint("Any destination", symbol: "globe")])
            }
            .frame(maxWidth: 560)
            DSRouteDiagram(hops: [.thisMac, .init(host: Sample.hosts[0], status: .live),
                                  .init(host: Sample.hosts[3], status: .busy)],
                           activity: .flowing, reachedHops: 2)
                .frame(maxWidth: 420)
            DSRouteDiagram(hops: [.thisMac, .init(host: Sample.hosts[0], status: .live),
                                  .init(host: Sample.hosts[1], status: .live)],
                           activity: .flowing, style: .compact)
                .frame(width: 248)
        }
        section("DSDetailHeader", "chips wrap under title and actions · at 420 pt the title gives way, the lone action stays") {
            DSDetailHeader(title: "web-01", subtitle: "deploy@10.0.12.4:22") {
                DSHostAvatar(os: Sample.systems[0], size: DS.Tile.header, status: .live)
            } accessory: {
                DSStatusPill(verbatim: "Connected · 2 sessions")
                DSChip(verbatim: "Ubuntu 24.04 LTS · aarch64")
                DSChip(verbatim: "#prod")
                DSChip(verbatim: "#web")
                DSStatusPill(verbatim: "Stopped", tone: .inactive, isHollow: true)
            } actions: {
                Button {} label: { Text(verbatim: "Connect") }
                    .dsButtonStyle(.prominent)
                Button {} label: { Text(verbatim: "SFTP") }
                    .dsButtonStyle(.glass)
                DSGlassIconMenu {
                    Button {} label: { Text(verbatim: "Duplicate") }
                    Button(role: .destructive) {} label: { Text(verbatim: "Delete") }
                }
            }
            .frame(width: 640)
            DSDetailHeader(title: "bastion.example.com:22", subtitle: "ED25519 · trusted 2026-09-12") {
                DSCategoryTile(page: .knownHosts)
            } accessory: {
                DSChip(verbatim: "4 addresses")
            } actions: {
                DSGlassIconMenu(size: .small) {
                    Button {} label: { Text(verbatim: "Remove…") }
                }
            }
            .frame(width: 420)
            DSDetailHeader(title: "web-01", subtitle: "Ubuntu 24.04 LTS · up 41 days · 148 processes",
                           isSubtitleMonospaced: false) {
                DSHostAvatar(os: Sample.systems[0], size: DS.Tile.header, status: .live)
            } actions: {
                Button {} label: { Text(verbatim: "Connect") }
                    .dsButtonStyle(.prominent)
                Button {} label: { Text(verbatim: "SFTP") }
                    .dsButtonStyle(.glass)
            }
            .frame(width: 330)
        }
        HStack(alignment: .top, spacing: DS.Space.xl) {
            section("DSSegmentBar · DSMessage") {
                DSSegmentBar(segments: [
                    .init(id: "ok", value: 9, tint: DS.Palette.success),
                    .init(id: "failed", value: 2, tint: DS.Palette.danger),
                    .init(id: "pending", value: 3, tint: DS.Palette.inactive)
                ])
                DSSegmentBar(segments: [
                    .init(id: "local", value: 2, tint: DS.Palette.accent),
                    .init(id: "remote", value: 1, tint: DS.Palette.accent.opacity(0.6)),
                    .init(id: "dynamic", value: 1, tint: DS.Palette.accent.opacity(0.35))
                ], gap: 3)
                DSMessage(verbatim: "Permission denied (publickey).")
                DSMessage(verbatim: "The host key changed since the last connection.", style: .warning)
            }
            section("DSThemeSwatches · DSRelativeTime") {
                ForEach(Array(TerminalTheme.builtIn.prefix(3))) { theme in
                    HStack(spacing: DS.Space.md) {
                        DSThemeSwatches(theme: theme)
                        Text(verbatim: theme.name)
                    }
                }
                HStack(spacing: DS.Space.lg) {
                    DSRelativeTime(Date().addingTimeInterval(-190))
                    DSRelativeTime(nil)
                }
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Sample text stays out of the string catalog: a key that is not a literal is not extracted.
private func raw(_ text: String) -> LocalizedStringKey {
    LocalizedStringKey(text)
}

/// Sample data of the gallery: made up, never read from the database.
private enum Sample {
    static let ladder: [CGFloat] = [DS.Tile.tab, DS.Tile.sidebar, DS.Tile.row, DS.Tile.card, DS.Tile.large,
                                    DS.Tile.header]
    static let statuses: [DSHostAvatar.Status] = [.none, .live, .busy, .failed, .ended]

    /// A few rows of the lookup table: the marks hosts get once their system is read.
    static let systems: [DSOperatingSystem] =
        ["ubuntu", "debian", "rocky", "kylin", "windows", "darwin"].map { DSOperatingSystem.resolve($0) } + [.unknown]

    static let filters: [(String, Int)] = [("All", 12), ("Online", 2), ("#prod", 5), ("#web", 2), ("#db", 2), ("#edge", 3)]

    static let hosts: [Host] = [
        host(1, "bastion", "ops", "203.0.113.10", color: "#EF4444", ago: 190),
        host(2, "web-01", "deploy", "10.0.12.4", color: "#F59E0B", ago: 3_600 * 5),
        host(3, "web-02", "deploy", "10.0.12.5", color: "#F59E0B", ago: 86_400),
        host(4, "db-primary", "postgres", "10.0.20.2", color: "#10B981", ago: 86_400 * 3),
        host(5, "k8s-node-1", "root", "10.0.30.11", color: nil, ago: 86_400 * 7),
        host(6, "打包机", "root", "192.168.55.40", color: nil, ago: nil),
        host(7, "win-ad", "Administrator", "192.0.2.5", color: "#3B82F6", ago: 60 * 40),
        host(8, "", "root", "198.51.100.7", color: nil, ago: nil)
    ]

    static func host(_ id: Int64, _ label: String, _ user: String, _ address: String, port: Int = 22,
                     color: String?, ago: TimeInterval?) -> Host {
        var host = Host.defaultValue()
        host.id = id
        host.label = label
        host.username = user
        host.hostname = address
        host.port = port
        host.color = color
        host.authType = id.isMultiple(of: 2) ? "privateKey" : "agent"
        host.lastConnectedAt = ago.map { TimestampFormatter.string(from: Date().addingTimeInterval(-$0)) }
        return host
    }

    static let fingerprints = [
        "SHA256:UXdTqQ5eYjWgM1NMEAXkxO/PvLHjkPJ5gxclG58Fttc",
        "SHA256:f+nj62iZv0WHcIdMHtP3vDSr3eA/U2eSujrTBqutOZU",
        "SHA256:Gwi/Zq7EPpZtuAMX3Nls5M3OkmImKHKkBj2fAi2xuyU"
    ]

    static let daily: [Double] = [3, 5, 1, 4, 9, 2, 1, 1, 6, 3, 1, 4, 7, 5]
    static let durations: [Double] = [2, 6, 3, 9, 4, 4, 12, 5, 3, 7, 26, 4]
    static let cpu: [Double] = [8, 11, 9, 14, 38, 18, 12, 9, 10, 11, 9, 12, 10, 16, 12, 11, 9, 13, 12, 11, 12]
    static let memory: [Double] = [38, 39, 39, 40, 40, 40, 41, 41, 40, 41, 41, 42, 41, 41, 42, 41, 41, 42]

    static func days(_ count: Int) -> [DSActivityChart.Day] {
        let succeeded = [5, 7, 4, 1, 3, 6, 0, 0, 2, 9, 4, 1, 5, 3]
        let failed = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset -> DSActivityChart.Day? in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DSActivityChart.Day(date: date, succeeded: succeeded[offset % succeeded.count],
                                       failed: failed[offset % failed.count])
        }
    }
}
#endif
