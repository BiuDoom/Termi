import SwiftUI
import AppKit

// Tiles: the rounded squares that say WHAT something is. A host's tile carries its distribution
// (the only free colour in the app); a category tile is the accent with a white glyph.

// MARK: - Icon tile

/// Rounded square lit from the top-left like a system icon: a subtle gradient of its colour, a
/// hairline highlight, and from 36 pt up a soft glow of its own colour. White mark.
struct DSIconTile: View {
    enum Content: Equatable, Sendable {
        /// An SF Symbol.
        case symbol(String)
        /// A template image of the asset catalog (distribution marks).
        case asset(String)
        /// One or two letters (identities).
        case monogram(String)
    }

    let content: Content
    var tint: Color = .accentColor
    var size: CGFloat = DS.Tile.row
    /// Corner radius as a share of the size: 0.24 for hosts, 0.27 for categories.
    var cornerRatio: CGFloat = 0.24

    init(content: Content, tint: Color = .accentColor, size: CGFloat = DS.Tile.row, cornerRatio: CGFloat = 0.24) {
        self.content = content
        self.tint = tint
        self.size = size
        self.cornerRatio = cornerRatio
    }

    init(_ content: Content, tint: Color = .accentColor, size: CGFloat = DS.Tile.row, cornerRatio: CGFloat = 0.24) {
        self.init(content: content, tint: tint, size: size, cornerRatio: cornerRatio)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * cornerRatio, style: .continuous)
        shape
            .fill(LinearGradient(stops: [
                .init(color: tint.mix(with: .white, by: 0.24), location: 0),
                .init(color: tint, location: 0.46),
                .init(color: tint.mix(with: .black, by: 0.2), location: 1)
            ], startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)))
            // The lit edge: bright along the top, a faint line all around.
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.14)],
                                                       startPoint: .top, endPoint: .center),
                                        lineWidth: size >= 36 ? 1 : 0.5))
            .frame(width: size, height: size)
            .overlay { mark }
            .foregroundStyle(.white)
            .shadow(color: tint.opacity(size >= 36 ? 0.42 : 0), radius: size * 0.2, x: 0, y: size * 0.14)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        switch content {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * (size <= 24 ? 0.56 : 0.48), weight: .medium))
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.64, height: size * 0.64)
        case .monogram(let letters):
            Text(verbatim: letters)
                .font(.system(size: size * 0.44, weight: .bold))
        }
    }

    /// Up to `letters` (1 or 2) characters that stand for a name ("prod-db-01" → "PD" or "P",
    /// "打包机" → "打").
    nonisolated static func monogram(for name: String, letters: Int = 2) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        if !first.isASCII { return String(first) }
        if letters < 2 { return String(first).uppercased() }
        let parts = trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if parts.count >= 2, let a = parts[0].first, let b = parts[1].first {
            return (String(a) + String(b)).uppercased()
        }
        return String(trimmed.prefix(2)).uppercased()
    }
}

/// The tile of a record's header and of empty states: the accent, a white glyph. Pages are not
/// colour-coded, so there is no colour to choose.
struct DSCategoryTile: View {
    private let symbol: String
    private let size: CGFloat

    init(_ symbol: String, size: CGFloat = DS.Tile.header) {
        self.symbol = symbol
        self.size = size
    }

    /// The tile of a sidebar page.
    init(page: SidebarItem, size: CGFloat = DS.Tile.header) {
        self.init(page.tileSymbol, size: size)
    }

    var body: some View {
        DSIconTile(.symbol(symbol), tint: DS.Palette.accent, size: size, cornerRatio: 0.27)
    }
}

// MARK: - Operating systems

/// What a host runs, as far as its tile is concerned: the one lookup from a distribution id to
/// its name, tile colour and mark.
struct DSOperatingSystem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// The distribution's own colour, dark enough for a white mark.
    let color: Color
    let mark: DSIconTile.Content

    /// A host whose system was not read yet, or is not in the table.
    static let unknown = DSOperatingSystem(id: "unknown", name: String(localized: "Unrecognized"),
                                           color: Color(red: 0.36, green: 0.42, blue: 0.51),
                                           mark: .symbol("server.rack"))
    /// The local shell.
    static let local = DSOperatingSystem(id: "local", name: String(localized: "This Mac"),
                                         color: Color(red: 0.43, green: 0.43, blue: 0.45),
                                         mark: .symbol("laptopcomputer"))

    /// A Linux without a mark of its own (and any distribution the table does not have).
    static let linux = DSOperatingSystem(id: "linux", name: "Linux", color: slate, mark: .asset("OS/linux"))

    /// Tile colour of the systems that have none of their own.
    private static let slate = rgb(0x4B5563)

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    /// A system with a mark in the asset catalog ("OS" folder; Simple Icons, CC0).
    private static func marked(_ id: String, _ name: String, _ hex: UInt32, _ asset: String) -> DSOperatingSystem {
        DSOperatingSystem(id: id, name: name, color: rgb(hex), mark: .asset("OS/" + asset))
    }

    /// A Linux distribution without a mark in the set: the Linux mark on the slate tile.
    private static func plainLinux(_ id: String, _ name: String) -> DSOperatingSystem {
        DSOperatingSystem(id: id, name: name, color: slate, mark: linux.mark)
    }

    /// The table: one entry per id of `HostSystem.ids`. Colours are the brands' own, darkened
    /// where a white mark on them would fall under 3:1.
    private static let all: [DSOperatingSystem] = [
        local,
        linux,
        marked("ubuntu", "Ubuntu", 0xE95420, "ubuntu"),
        marked("debian", "Debian", 0xC70036, "debian"),
        marked("centos", "CentOS", 0x6A3C9A, "centos"),
        marked("rhel", "Red Hat Enterprise Linux", 0xE00000, "redhat"),
        marked("rocky", "Rocky Linux", 0x0E9F6E, "rockylinux"),
        marked("almalinux", "AlmaLinux", 0x0F4266, "almalinux"),
        marked("fedora", "Fedora", 0x3C6EB4, "fedora"),
        marked("opensuse", "openSUSE", 0x4F8F17, "opensuse"),
        marked("sles", "SUSE Linux Enterprise", 0x29A067, "suse"),
        marked("arch", "Arch Linux", 0x1481B8, "archlinux"),
        marked("alpine", "Alpine Linux", 0x0D597F, "alpinelinux"),
        plainLinux("kylin", String(localized: "Kylin")),
        plainLinux("openeuler", "openEuler"),
        plainLinux("uos", String(localized: "UOS")),
        marked("deepin", "deepin", 0x007CFF, "deepin"),
        marked("amzn", "Amazon Linux", 0xCC7A00, "amazonwebservices"),
        marked("ol", "Oracle Linux", 0xC74634, "oracle"),
        marked("kali", "Kali Linux", 0x557C94, "kalilinux"),
        marked("linuxmint", "Linux Mint", 0x6E9C37, "linuxmint"),
        marked("manjaro", "Manjaro", 0x2EA44F, "manjaro"),
        marked("gentoo", "Gentoo", 0x54487A, "gentoo"),
        marked("nixos", "NixOS", 0x5277C3, "nixos"),
        marked("raspbian", "Raspberry Pi OS", 0xA22846, "raspberrypi"),
        marked("openwrt", "OpenWrt", 0x0096BD, "openwrt"),
        marked("proxmox", "Proxmox VE", 0xE06E00, "proxmox"),
        marked("truenas", "TrueNAS", 0x0095D5, "truenas"),
        // Synology's mark in the set is a wide wordmark: unreadable on a tile.
        plainLinux("synology", "Synology DSM"),
        marked("freebsd", "FreeBSD", 0xAB2B28, "freebsd"),
        marked("openbsd", "OpenBSD", 0xA98D22, "openbsd"),
        marked("netbsd", "NetBSD", 0xEB6300, "netbsd"),
        marked("darwin", "macOS", 0x6E6E73, "apple"),
        marked("windows", "Windows", 0x0078D4, "windows")
    ]

    private static let known: [String: DSOperatingSystem] =
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// The system for an id as stored ("ubuntu", "debian" …); `unknown` for nil and for ids
    /// the table does not have.
    static func resolve(_ id: String?) -> DSOperatingSystem {
        guard let id else { return unknown }
        return known[id.lowercased()] ?? unknown
    }
}

// MARK: - Host presentation

extension Host {
    /// The host's name, or its address when it has none.
    var displayName: String {
        label.isEmpty ? hostname : label
    }

    /// What the host runs, as read after it last connected; the default until then.
    var operatingSystem: DSOperatingSystem {
        DSOperatingSystem.resolve(osId)
    }

    /// The colour of the host's tile: the one chosen for it, otherwise its distribution's.
    var tint: Color {
        if let hex = color, !hex.isEmpty, let chosen = DS.Palette.tint(hex: hex) {
            return chosen
        }
        return operatingSystem.color
    }

    /// The mark on the host's tile: its distribution's.
    var tileContent: DSIconTile.Content {
        operatingSystem.mark
    }
}

// MARK: - Host avatar

/// A host wherever it shows up: its tile, with the live state on the bottom-right corner.
struct DSHostAvatar: View {
    enum Status: Equatable, Sendable {
        case none, live, busy, needsInput, unread, failed, ended

        var tone: DS.Tone {
            switch self {
            case .none, .live: return .success
            case .busy, .needsInput: return .warning
            case .unread: return .accent
            case .failed: return .danger
            case .ended: return .inactive
            }
        }

        /// Non-colour symbol drawn when the status requires attention (`needsInput`, `failed`)
        /// or when Differentiate Without Color is enabled.
        var badgeSymbol: String? {
            switch self {
            case .needsInput: return "key.fill"
            case .failed: return "exclamationmark"
            default: return nil
            }
        }
    }

    private let content: DSIconTile.Content
    private let tint: Color
    private let size: CGFloat
    private let status: Status
    /// What the mark stands for ("Ubuntu"), for assistive technologies; nil for the generic tile.
    private var systemName: String?

    init(_ host: Host, size: CGFloat = DS.Tile.row, status: Status = .none) {
        self.init(content: host.tileContent, tint: host.tint, size: size, status: status)
        systemName = host.system == nil ? nil : host.operatingSystem.name
    }

    /// A system without a saved host (an ad-hoc connection, a sample). `tint` overrides the
    /// distribution's colour.
    init(os: DSOperatingSystem, tint: Color? = nil, size: CGFloat = DS.Tile.row, status: Status = .none) {
        self.init(content: os.mark, tint: tint ?? os.color, size: size, status: status)
        systemName = os == .unknown ? nil : os.name
    }

    init(content: DSIconTile.Content, tint: Color, size: CGFloat = DS.Tile.row, status: Status = .none) {
        self.content = content
        self.tint = tint
        self.size = size
        self.status = status
    }

    /// The local shell.
    static func local(size: CGFloat = DS.Tile.row, status: Status = .none) -> DSHostAvatar {
        DSHostAvatar(os: .local, size: size, status: status)
    }

    var body: some View {
        DSIconTile(content: content, tint: tint, size: size)
            // The ring around the dot is a notch cut out of the tile, so whatever is behind —
            // the window, a card, a selected row, glass — is the ring's colour.
            .overlay(alignment: .bottomTrailing) {
                if status != .none {
                    Circle()
                        .frame(width: dotSize + 2 * gap, height: dotSize + 2 * gap)
                        .offset(x: overhang + gap, y: overhang + gap)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .overlay(alignment: .bottomTrailing) {
                if status != .none {
                    ZStack {
                        DSStatusDot(color: status.tone.color,
                                    isPulsing: status == .busy || status == .needsInput,
                                    size: dotSize)
                        if let symbol = status.badgeSymbol, dotSize >= 8 {
                            Image(systemName: symbol)
                                .font(.system(size: max(5, dotSize * 0.55), weight: .black))
                                .foregroundStyle(.white)
                                .accessibilityHidden(true)
                        }
                    }
                    .offset(x: overhang, y: overhang)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .dsAnimated(DS.Motion.standard, value: status)
            // The mark is a picture and the dot is colour only: assistive technologies get the
            // system and the state in words.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: systemName ?? ""))
            .accessibilityValue(statusLabel)
            .accessibilityHidden(status == .none && systemName == nil)
    }

    private var statusLabel: Text {
        switch status {
        case .none: return Text(verbatim: "")
        case .live: return Text("Connected")
        case .busy: return Text("Connecting…")
        case .needsInput: return Text("Waiting for authentication input")
        case .unread: return Text("Connected, new output")
        case .failed: return Text("Failed")
        case .ended: return Text("Disconnected")
        }
    }

    private var dotSize: CGFloat { max(7, (size * (size <= 30 ? 0.3 : 0.24)).rounded()) }
    private var gap: CGFloat { size >= 36 ? 2.5 : 2 }
    private var overhang: CGFloat { 3 }
}

extension DSHostAvatar.Status {
    /// How the states of several sessions add up to one.
    enum Ranking: Equatable, Sendable {
        /// Live wins, then busy, failed, ended: "can this host be reached" (host lists).
        case liveFirst
        /// Failed wins, then busy, ended, live: "does anything here need a look" (a tab's tile).
        case worstFirst
    }

    /// The state a set of sessions adds up to under `ranking`.
    init(states: [TerminalSession.State], ranking: Ranking) {
        let liveFirst = DSHostAvatar.Status(states: states)
        guard ranking == .worstFirst, liveFirst != .none else {
            self = liveFirst
            return
        }
        var busy = false
        var failed = false
        var ended = false
        for state in states {
            switch state {
            case .connecting, .reconnecting: busy = true
            case .failed: failed = true
            case .ended: ended = true
            case .connected, .running, .idle: break
            }
        }
        if failed {
            self = .failed
        } else if busy {
            self = .busy
        } else if ended {
            self = .ended
        } else {
            self = .live
        }
    }

    /// The state a set of sessions adds up to: live wins, then busy, failed, ended.
    init(states: [TerminalSession.State]) {
        var live = false
        var busy = false
        var failed = false
        var ended = false
        for state in states {
            switch state {
            case .connected, .running: live = true
            case .connecting, .reconnecting: busy = true
            case .failed: failed = true
            case .ended: ended = true
            case .idle: break
            }
        }
        if live {
            self = .live
        } else if busy {
            self = .busy
        } else if failed {
            self = .failed
        } else if ended {
            self = .ended
        } else {
            self = .none
        }
    }
}

/// Overlapping host tiles: "used by these".
struct DSHostStack: View {
    let hosts: [Host]
    var limit = 4
    var size: CGFloat = DS.Tile.sidebar

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            HStack(spacing: -size * 0.3) {
                ForEach(Array(hosts.prefix(limit)), id: \.connectionKey) { host in
                    DSIconTile(content: host.tileContent, tint: host.tint, size: size)
                        // Each tile cuts a gap out of the one under it, so the row, card or
                        // sidebar behind shows through (a ring in the window colour is wrong
                        // on a selected row).
                        .background {
                            RoundedRectangle(cornerRadius: size * 0.24 + gap, style: .continuous)
                                .padding(-gap)
                                .blendMode(.destinationOut)
                        }
                }
            }
            .compositingGroup()
            if hosts.count > limit {
                Text(verbatim: "+\(hosts.count - limit)")
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(hosts.count) hosts"))
    }

    private var gap: CGFloat { max(1.5, (size * 0.06).rounded()) }
}

// MARK: - Sidebar

extension SidebarItem {
    /// Line glyph of the sidebar row (drawn in the accent, without a tile).
    var glyph: String {
        switch self {
        case .terminal: return "server.rack"
        case .sftp: return "folder"
        case .portForwards: return "arrow.left.arrow.right"
        case .snippets: return "curlybraces"
        case .keys: return "key"
        case .identities: return "person"
        case .knownHosts: return "checkmark.shield"
        case .batchCommand: return "square.stack.3d.up"
        case .monitoring: return "waveform.path.ecg"
        case .docker: return "shippingbox"
        case .logs: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }

    /// Filled glyph for the page's category tile (record headers, empty states).
    var tileSymbol: String {
        switch self {
        case .terminal: return "server.rack"
        case .sftp: return "folder.fill"
        case .portForwards: return "arrow.left.arrow.right"
        case .snippets: return "curlybraces"
        case .keys: return "key.fill"
        case .identities: return "person.fill"
        case .knownHosts: return "checkmark.shield.fill"
        case .batchCommand: return "square.stack.3d.up.fill"
        case .monitoring: return "waveform.path.ecg"
        case .docker: return "shippingbox.fill"
        case .logs: return "clock.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Sidebar row label: an accent glyph WITHOUT a tile, then the title.
struct DSSidebarLabel: View {
    let item: SidebarItem

    var body: some View {
        Label {
            Text(LocalizedStringKey(item.label))
        } icon: {
            // Thin line icons, as drawn: the sidebar's own symbol weight reads heavier and
            // more saturated than the titles next to it.
            Image(systemName: item.glyph)
                .fontWeight(.light)
                .foregroundStyle(DS.Palette.accent)
        }
    }
}
