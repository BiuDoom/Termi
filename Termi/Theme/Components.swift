import SwiftUI
import AppKit

// Shared views of the content layer and the page skeletons. Glass (buttons, floating bars, filter
// chips) is in Glass.swift, tiles in Tiles.swift, cards and rows in DataCards.swift, charts in
// Charts.swift. Everything else is a standard control: TextField, SecureField, Picker, Toggle,
// Form(.grouped), Table, ProgressView.

// MARK: - Status dot

/// Live-state indicator. Pulses while `isPulsing` (connecting, transferring) unless Reduce Motion is on.
struct DSStatusDot: View {
    var color: Color = DS.Palette.success
    var isPulsing = false
    var size: CGFloat = 8
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.35 : 1)
            .onAppear { updatePulse() }
            .onChange(of: isPulsing) { _, _ in updatePulse() }
            .accessibilityHidden(true)
    }

    private func updatePulse() {
        if isPulsing, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dimmed = true }
        } else {
            withAnimation(DS.Motion.quick) { dimmed = false }
        }
    }
}

// MARK: - Chip

/// Capsule label for short metadata: neutral, never colour-coded. `verbatim:` for data (key
/// types, tags), the key initialiser for interface text. `tint` colours only the glyph, and only
/// to say a state ("strong" in green, "weak" in orange).
struct DSChip: View {
    private let text: Text
    private let symbol: String?
    var tint: Color?
    var isMonospaced = false

    init(_ key: LocalizedStringKey, symbol: String? = nil, tint: Color? = nil) {
        text = Text(key)
        self.symbol = symbol
        self.tint = tint
    }

    init(verbatim: String, symbol: String? = nil, tint: Color? = nil, isMonospaced: Bool = false) {
        text = Text(verbatim: verbatim)
        self.symbol = symbol
        self.tint = tint
        self.isMonospaced = isMonospaced
    }

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            }
            text
        }
        .font(isMonospaced ? DS.Font.chip.monospaced() : DS.Font.chip)
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: DS.Height.chip)
        .background(DS.Palette.chip, in: Capsule(style: .continuous))
    }
}

// MARK: - Card

/// A card of the content layer: neutral fill, hairline edge, a soft shadow in light mode. Never
/// glass. `hero` washes it in a tone — at most one such card per screen.
struct DSCardModifier: ViewModifier {
    var isSelected = false
    var isInteractive = false
    var hero: Color?
    var cornerRadius: CGFloat = DS.Radius.card
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        content
            .background {
                shape.fill(DS.Palette.card)
                    // Light mode only: a white card on a light window needs the shadow to lift;
                    // in dark mode the fill is translucent and a shadow would show through it.
                    .shadow(color: .black.opacity(isDark ? 0 : 0.06), radius: 12, x: 0, y: 8)
                    .shadow(color: .black.opacity(isDark ? 0 : 0.04), radius: 1, x: 0, y: 1)
                // The wash lies between the fill and the content: over the content it would
                // dull a host's tile and tint the text.
                if let hero {
                    shape.fill(LinearGradient(colors: [hero.opacity(isDark ? 0.30 : 0.20), hero.opacity(isDark ? 0.07 : 0.04)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay {
                if isInteractive && isHovered {
                    shape.fill(.primary.opacity(0.04)).allowsHitTesting(false)
                }
            }
            .overlay(shape.strokeBorder(edge, lineWidth: isSelected ? 2 : 1)
                // The selected card of a grid: an accent ring with a soft glow.
                .shadow(color: DS.Palette.accent.opacity(isSelected ? 0.5 : 0), radius: 6))
            .contentShape(shape)
            .onHover { if isInteractive { isHovered = $0 } }
            .dsAnimated(DS.Motion.quick, value: isHovered)
            .dsAnimated(DS.Motion.quick, value: isSelected)
            .environment(\.dsIsHovered, isHovered)
    }

    private var edge: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(DS.Palette.accent) }
        if let hero { return AnyShapeStyle(hero.opacity(0.3)) }
        return AnyShapeStyle(DS.Palette.hairline)
    }
}

extension View {
    /// Card surface of the content layer. `isInteractive` adds a hover highlight and publishes
    /// `\.dsIsHovered` to the content (use it to reveal secondary actions); `hero` is a wash of
    /// that colour (one per screen).
    func dsCard(isSelected: Bool = false, isInteractive: Bool = false, hero: Color? = nil,
                cornerRadius: CGFloat = DS.Radius.card) -> some View {
        modifier(DSCardModifier(isSelected: isSelected, isInteractive: isInteractive, hero: hero,
                                cornerRadius: cornerRadius))
    }

    /// Tracks hover for a row and publishes it as `\.dsIsHovered`.
    func dsHoverTracking() -> some View {
        modifier(DSHoverTrackingModifier())
    }
}

private struct DSHoverTrackingModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .environment(\.dsIsHovered, isHovered)
    }
}

private struct DSIsHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the enclosing `dsCard(isInteractive:)` / `dsHoverTracking()` is hovered.
    var dsIsHovered: Bool {
        get { self[DSIsHoveredKey.self] }
        set { self[DSIsHoveredKey.self] = newValue }
    }
}

// MARK: - Row action

/// Borderless icon button for rows and bars; always has a tooltip and an accessibility label.
struct DSRowButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var role: ButtonRole?
    let action: () -> Void

    init(_ systemName: String, help: LocalizedStringKey, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

// MARK: - Inline message

/// Message shown where the problem is: icon, text, tinted background.
struct DSMessage: View {
    enum Style {
        case error, warning, info

        var color: Color {
            switch self {
            case .error: DS.Palette.danger
            case .warning: DS.Palette.warning
            case .info: .accentColor
            }
        }

        var symbol: String {
            switch self {
            case .error: "exclamationmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .info: "info.circle.fill"
            }
        }
    }

    private let text: Text
    var style: Style = .error

    init(_ key: LocalizedStringKey, style: Style = .error) {
        text = Text(key)
        self.style = style
    }

    init(verbatim: String, style: Style = .error) {
        text = Text(verbatim: verbatim)
        self.style = style
    }

    var body: some View {
        Label {
            text
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: style.symbol)
                .foregroundStyle(style.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(style.color.opacity(0.1), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
    }
}

// MARK: - Keyboard shortcut hint

/// Shortcut shown next to a command, e.g. `DSShortcut("⌘K")`.
struct DSShortcut: View {
    let keys: String

    init(_ keys: String) {
        self.keys = keys
    }

    var body: some View {
        Text(verbatim: keys)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Sheet title

/// Title of a sheet, in the first section header (a sheet has no title bar).
struct DSSheetTitle: View {
    private let title: Text

    init(_ key: LocalizedStringKey) {
        title = Text(key)
    }

    var body: some View {
        title
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Delayed appearance

/// Shows its content only once it has lasted `delay`: a state that is usually over within a
/// moment (connecting over an open master connection) never flashes on screen.
struct DSDelayed<Content: View>: View {
    var delay: Duration = .milliseconds(300)
    @ViewBuilder var content: Content
    @State private var isShown = false

    var body: some View {
        content
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
            .dsAnimated(DS.Motion.quick, value: isShown)
            .task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                isShown = true
            }
    }
}

// MARK: - Copy button

/// Copy button that confirms in place: the icon turns into a checkmark for a moment.
struct DSCopyButton: View {
    private let title: LocalizedStringKey?
    private let help: LocalizedStringKey
    private let action: () -> Void
    @State private var showsCopied = false
    @State private var copyCount = 0

    /// Icon only, for rows.
    init(help: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = nil
        self.help = help
        self.action = action
    }

    /// With a title, for bars ("Copy All"): only the icon changes, so the width stays.
    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.help = title
        self.action = action
    }

    private var symbol: String { showsCopied ? "checkmark" : "doc.on.doc" }

    var body: some View {
        Group {
            if let title {
                Button(action: copy) {
                    Label(title, systemImage: symbol)
                        .contentTransition(.symbolEffect(.replace))
                }
            } else {
                DSRowButton(symbol, help: help, action: copy)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .task(id: copyCount) {
            guard showsCopied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.quick) { showsCopied = false }
        }
    }

    private func copy() {
        action()
        withAnimation(DS.Motion.quick) { showsCopied = true }
        copyCount += 1
    }
}

extension Host {
    var lastConnectedDate: Date? {
        lastConnectedAt.flatMap { TimestampFormatter.date(from: $0) }
    }

    /// Glyph for how the host signs in.
    var authSymbol: String {
        if identityId != nil { return "person.fill" }
        switch authType {
        case "privateKey": return "key.fill"
        case "agent": return "person.badge.key.fill"
        default: return "ellipsis.rectangle.fill"
        }
    }

    var authTitle: String {
        if identityId != nil { return String(localized: "Identity") }
        switch authType {
        case "privateKey": return String(localized: "SSH Key")
        case "agent": return String(localized: "SSH Agent")
        default: return String(localized: "Password")
        }
    }
}

/// Standard two-line host row: avatar, name (with the jump mark), address, something trailing.
/// Put it in `.dsListRow(isSelected:)`: on the selected row its second line turns white with it.
struct DSHostRow<Trailing: View>: View {
    private let host: Host
    private let status: DSHostAvatar.Status
    private let avatarSize: CGFloat
    private let showsJump: Bool
    private let trailing: Trailing

    init(_ host: Host, status: DSHostAvatar.Status = .none, avatarSize: CGFloat = DS.Tile.row,
         showsJump: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.host = host
        self.status = status
        self.avatarSize = avatarSize
        self.showsJump = showsJump
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 11) {
            DSHostAvatar(host, size: avatarSize, status: status)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(verbatim: host.displayName)
                        .font(DS.Font.rowTitle)
                        .lineLimit(1)
                    if showsJump {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Via Jump Host"))
                    }
                }
                Text(verbatim: host.addressDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: DS.Space.xs)
            trailing
                .font(DS.Font.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension DSHostRow where Trailing == EmptyView {
    init(_ host: Host, status: DSHostAvatar.Status = .none, avatarSize: CGFloat = DS.Tile.row,
         showsJump: Bool = false) {
        self.init(host, status: status, avatarSize: avatarSize, showsJump: showsJump) { EmptyView() }
    }
}

/// Hosts to pick from when a page needs one (SFTP, Monitoring, Docker): hosts with an open
/// connection first — picking one of those never asks for a password.
struct DSHostPickerGrid: View {
    let hosts: [Host]
    var liveHostIds: Set<Int64> = []
    var limit = 8
    let onPick: (Host) -> Void

    private var ordered: [Host] {
        let sorted = hosts.sorted { lhs, rhs in
            let lhsLive = lhs.id.map { liveHostIds.contains($0) } ?? false
            let rhsLive = rhs.id.map { liveHostIds.contains($0) } ?? false
            if lhsLive != rhsLive { return lhsLive }
            return (lhs.lastConnectedAt ?? "") > (rhs.lastConnectedAt ?? "")
        }
        return Array(sorted.prefix(limit))
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: DS.Space.sm)],
                  alignment: .leading, spacing: DS.Space.sm) {
            ForEach(ordered, id: \.connectionKey) { host in
                let isLive = host.id.map { liveHostIds.contains($0) } ?? false
                Button {
                    onPick(host)
                } label: {
                    HStack(spacing: DS.Space.md) {
                        DSHostAvatar(host, size: DS.Tile.card, status: isLive ? .live : .none)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: host.displayName)
                                .font(DS.Font.rowTitle)
                                .lineLimit(1)
                            if isLive {
                                Text("Uses the open connection")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                DSRelativeTime(host.lastConnectedDate)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(DS.Space.md)
                    .dsCard(isInteractive: true)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Status pill, relative time

/// A state, always as a lit dot + words (never colour alone). The pill itself is neutral.
struct DSStatusPill: View {
    private let text: Text
    private let tone: DS.Tone
    private let isPulsing: Bool
    private let showsBackground: Bool
    private let isHollow: Bool

    /// `isHollow`: a ring instead of a dot — something that is switched off ("Stopped"), as
    /// opposed to something that is over.
    init(_ key: LocalizedStringKey, tone: DS.Tone = .success, isPulsing: Bool = false, showsBackground: Bool = true,
         isHollow: Bool = false) {
        self.text = Text(key)
        self.tone = tone
        self.isPulsing = isPulsing
        self.showsBackground = showsBackground
        self.isHollow = isHollow
    }

    init(verbatim: String, tone: DS.Tone = .success, isPulsing: Bool = false, showsBackground: Bool = true,
         isHollow: Bool = false) {
        self.text = Text(verbatim: verbatim)
        self.tone = tone
        self.isPulsing = isPulsing
        self.showsBackground = showsBackground
        self.isHollow = isHollow
    }

    @ViewBuilder
    private var dot: some View {
        if isHollow {
            Circle()
                .strokeBorder(tone.color, lineWidth: 1.5)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        } else {
            DSStatusDot(color: tone.color, isPulsing: isPulsing, size: 7)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            dot
                // Lit: states that are over (`inactive`) do not glow.
                .shadow(color: tone.color.opacity(tone == .inactive || isHollow ? 0 : 0.8), radius: 4)
            text
                .font(DS.Font.chip)
                .foregroundStyle(tone == .inactive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
        }
        .padding(.horizontal, showsBackground ? 9 : 0)
        .frame(height: DS.Height.chip)
        .background(showsBackground ? DS.Palette.chip : Color.clear, in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// "3 minutes ago", kept current; the tooltip gives the time to the second.
struct DSRelativeTime: View {
    private let date: Date?
    private let placeholder: LocalizedStringKey

    init(_ date: Date?, placeholder: LocalizedStringKey = "Never") {
        self.date = date
        self.placeholder = placeholder
    }

    init(iso: String?, placeholder: LocalizedStringKey = "Never") {
        self.date = iso.flatMap { TimestampFormatter.date(from: $0) }
        self.placeholder = placeholder
    }

    @Environment(\.dsIsSelected) private var isSelected

    /// Redrawn once a minute, on the minute for every instance: two places that show the same
    /// moment (a list row and the card next to it) change together and never differ by one.
    static var schedule: PeriodicTimelineSchedule {
        .periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 60)
    }

    /// "Just now" within the first minute (a count of seconds would be stale at once), else the
    /// system's wording: "5 minutes ago", "yesterday", "last week". The one rule for every place
    /// that says how long ago something was.
    nonisolated static func text(for date: Date, now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return String(localized: "Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The same text as a number and its unit ("5" + "minutes ago") for a card that sets the
    /// number large; wordings without a leading number ("yesterday") are the value alone.
    nonisolated static func parts(for date: Date, now: Date = Date()) -> (value: String, unit: String?) {
        let text = Self.text(for: date, now: now)
        let digits = text.prefix { $0.isNumber }
        let unit = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, !unit.isEmpty else { return (text, nil) }
        return (String(digits), unit)
    }

    var body: some View {
        if let date {
            TimelineView(Self.schedule) { context in
                Text(verbatim: Self.text(for: date, now: context.date))
            }
            .help(Text(verbatim: date.formatted(date: .abbreviated, time: .standard)))
        } else {
            Text(placeholder)
                // Tertiary grey disappears on a selected row's accent pill.
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
        }
    }
}

// MARK: - Page skeletons

/// Skeleton A. Not an HSplitView (panes open at their ideal width on macOS 26) and not a
/// second `.inspector` (the window's only inspector belongs to the terminal).
struct DSMasterDetail<Master: View, Detail: View>: View {
    enum Sizing: Equatable {
        /// Fixed master column, the detail takes the rest (list pages).
        case fixedMaster(width: CGFloat, compactWidth: CGFloat)
        /// Flexible master, fixed trailing detail that leaves below `hidesBelow` (table / grid pages).
        case fixedDetail(width: CGFloat, hidesBelow: CGFloat)
    }

    private let sizing: Sizing
    private let master: Master
    private let detail: Detail

    init(sizing: Sizing = .fixedMaster(width: DS.Layout.masterWidth, compactWidth: DS.Layout.masterCompactWidth),
         @ViewBuilder master: () -> Master, @ViewBuilder detail: () -> Detail) {
        self.sizing = sizing
        self.master = master()
        self.detail = detail()
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                switch sizing {
                case .fixedMaster(let width, let compactWidth):
                    master
                        .frame(width: proxy.size.width < DS.Layout.compactThreshold ? compactWidth : width)
                        .frame(maxHeight: .infinity)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .fixedDetail(let width, let hidesBelow):
                    master
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if proxy.size.width >= hidesBelow {
                        Divider()
                        detail
                            .frame(width: width)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

extension View {
    /// Skeleton B and detail content: at most `maxWidth` wide, centred.
    func dsCenteredColumn(maxWidth: CGFloat = DS.Layout.columnMaxWidth) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }

    /// A row of a master list: 46 pt, and while selected the accent pill (white text, soft glow
    /// of the accent). Publishes `\.dsIsSelected` to its content.
    func dsListRow(isSelected: Bool, height: CGFloat = DS.Height.listRow) -> some View {
        modifier(DSListRowModifier(isSelected: isSelected, height: height))
    }

    /// The window's quiet wash of the accent behind the content of the detail column: the
    /// colour the glass above it refracts. The same on every page.
    func dsStageBackground() -> some View {
        background { DSStageBackground() }
    }
}

// MARK: - Master list

private struct DSIsSelectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the selected `dsListRow`.
    var dsIsSelected: Bool {
        get { self[DSIsSelectedKey.self] }
        set { self[DSIsSelectedKey.self] = newValue }
    }
}

private struct DSListRowModifier: ViewModifier {
    let isSelected: Bool
    let height: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
        content
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            // White on the pill; `.secondary` inside follows (white, dimmed).
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .background {
                if isSelected {
                    shape
                        .fill(LinearGradient(stops: [
                            .init(color: DS.Palette.accent.mix(with: .white, by: 0.16), location: 0),
                            .init(color: DS.Palette.accent, location: 0.55),
                            .init(color: DS.Palette.accent.mix(with: .black, by: 0.1), location: 1)
                        ], startPoint: .top, endPoint: .bottom))
                        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0)],
                                                                   startPoint: .top, endPoint: .center)))
                        .shadow(color: DS.Palette.accent.opacity(0.42), radius: 11, x: 0, y: 8)
                }
            }
            .contentShape(shape)
            .environment(\.dsIsSelected, isSelected)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The header of a section of a master list: its name, and how many it holds.
struct DSListSectionHeader: View {
    private let title: Text
    private let count: Int?
    private var trailing: AnyView?

    init(_ key: LocalizedStringKey, count: Int? = nil) {
        self.title = Text(key)
        self.count = count
    }

    /// For data: a group's name.
    init(verbatim: String, count: Int? = nil) {
        self.title = Text(verbatim: verbatim)
        self.count = count
    }

    /// A group's name with a control at the end of the line (a checkbox for the whole group,
    /// a menu), after the count.
    init<Trailing: View>(verbatim: String, count: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(verbatim: verbatim)
        self.count = count
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(spacing: 6) {
            title
                .font(DS.Font.sectionHeader)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let count {
                Text(verbatim: count.formatted())
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            if let trailing {
                trailing
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: DS.Height.sectionHeader)
    }
}

/// The master column: rows in a scroll view, one of them selected. Rows are built by the page
/// (`DSHostRow` or its own) with `.dsListRow(isSelected:)`, `.id(<their id>)` and a tap that sets
/// the selection; ↑ / ↓ walk `order` while the list has the keyboard.
struct DSMasterList<ID: Hashable, Content: View>: View {
    @Binding private var selection: ID?
    private let order: [ID]
    private let content: Content

    init(selection: Binding<ID?>, order: [ID], @ViewBuilder content: () -> Content) {
        self._selection = selection
        self.order = order
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 10)
                .padding(.bottom, DS.Space.sm)
            }
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard let next = Self.neighbour(of: selection, in: order, direction: direction) else { return }
                selection = next
                proxy.scrollTo(next)
            }
        }
    }

    /// The id above / below the selected one; the first when nothing is selected.
    nonisolated static func neighbour(of selection: ID?, in order: [ID], direction: MoveCommandDirection) -> ID? {
        guard !order.isEmpty else { return nil }
        guard let selection, let index = order.firstIndex(of: selection) else { return order.first }
        switch direction {
        case .up: return index > 0 ? order[index - 1] : nil
        case .down: return index < order.count - 1 ? order[index + 1] : nil
        default: return nil
        }
    }
}

private struct DSStageBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                // Dark mode: deeper than the window colour, so that the faint lift of a card
                // and the glow of the data read against it.
                Color.black.opacity(isDark ? 0.4 : 0)
                // Top-right and bottom-left: where the toolbar's and the sidebar's glass sit.
                wash(width: 720, height: 460, at: UnitPoint(x: 0.82, y: -0.12), opacity: isDark ? 0.20 : 0.16,
                     in: proxy.size)
                wash(width: 620, height: 560, at: UnitPoint(x: -0.10, y: 1.12), opacity: isDark ? 0.14 : 0.12,
                     in: proxy.size)
            }
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One soft ellipse of the accent that has faded out at 72 % of its radii.
    private func wash(width: CGFloat, height: CGFloat, at point: UnitPoint, opacity: Double, in size: CGSize) -> some View {
        let radius = height * 0.72
        return RadialGradient(colors: [DS.Palette.accent.opacity(opacity), DS.Palette.accent.opacity(0)],
                              center: .center, startRadius: 0, endRadius: radius)
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(x: width / height, y: 1)
            .position(x: size.width * point.x, y: size.height * point.y)
    }
}

/// Top of every detail: what is selected, and what to do with it. Title and actions share the
/// first line, the chips run under both and wrap. When the line gets short the title gives way
/// first (it truncates down to `DSDetailHeaderMetrics.titleFloor`), so a lone "more" button stays
/// in its corner; only when even that does not fit do the actions take a line of their own under
/// the chips.
struct DSDetailHeader<Icon: View, Accessory: View, Actions: View>: View {
    private let title: String
    private let subtitle: String?
    private let isSubtitleMonospaced: Bool
    private let icon: Icon
    private let accessory: Accessory
    private let actions: Actions

    /// `isSubtitleMonospaced`: true for an address or a fingerprint; false for a sentence
    /// ("Ubuntu 24.04 · up 41 days").
    init(title: String, subtitle: String? = nil, isSubtitleMonospaced: Bool = true, @ViewBuilder icon: () -> Icon,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.isSubtitleMonospaced = isSubtitleMonospaced
        self.icon = icon()
        self.accessory = accessory()
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                icon
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: DS.Space.lg) {
                        titleBlock
                            // What the fit is judged by: the title may be cut down to the floor
                            // before the actions leave the line. Given more, it takes it.
                            .frame(minWidth: 0, idealWidth: DSDetailHeaderMetrics.titleIdealWidth(title),
                                   maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: DS.Space.sm) { actions }
                            .fixedSize()
                            .padding(.top, DS.Space.xs)
                    }
                    chips
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(alignment: .center, spacing: DS.Space.lg) {
                    icon
                    VStack(alignment: .leading, spacing: 0) {
                        titleBlock
                        chips
                    }
                }
                HStack(spacing: DS.Space.sm) { actions }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .font(DS.Font.detailTitle)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(isSubtitleMonospaced ? DS.Font.mono : DS.Font.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(isSubtitleMonospaced ? .middle : .tail)
                    .textSelection(.enabled)
            }
        }
    }

    /// Chips and the status pill: one line, wrapping when it is too short. They never decide
    /// whether the actions fit (ideal width 0): they can always wrap.
    private var chips: some View {
        DSFlow(spacing: 6) { accessory }
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.top, 5)
    }
}

enum DSDetailHeaderMetrics {
    /// The least a title keeps before the actions move under it.
    static let titleFloor: CGFloat = 180

    /// The title's width as the fit is judged: its own, but no more than the floor.
    @MainActor
    static func titleIdealWidth(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 26, weight: .bold)
        let natural = (title as NSString).size(withAttributes: [.font: font]).width
        return idealWidth(natural: natural)
    }

    nonisolated static func idealWidth(natural: CGFloat) -> CGFloat {
        guard natural.isFinite else { return titleFloor }
        return min(max(natural.rounded(.up), 0), titleFloor)
    }
}

// MARK: - Unified Vault Card & Right-Side Live Inspector

/// Trailing edit / inspector button on a Vault card or row (`pencil` when closed, filled when open).
/// Reserves its 28×28 slot so text never shifts on hover.
struct DSCardInspectorButton: View {
    let isOpen: Bool
    let isVisible: Bool
    var isOnAccent = false
    var symbol: String = "pencil"
    var openHelp: LocalizedStringKey = "Edit & Details (⌘I)"
    var closeHelp: LocalizedStringKey = "Hide Inspector (⌘I)"
    let action: () -> Void

    static let side: CGFloat = 28

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Self.side, height: Self.side)
                .background(
                    isOnAccent
                        ? AnyShapeStyle(Color.white.opacity(0.18))
                        : (isOpen ? AnyShapeStyle(DS.Palette.accent.opacity(0.16)) : AnyShapeStyle(DS.Palette.chip)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? closeHelp : openHelp)
        .accessibilityLabel(isOpen ? Text(closeHelp) : Text(openHelp))
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .dsAnimated(DS.Motion.quick, value: isVisible)
    }

    private var tint: AnyShapeStyle {
        if isOnAccent { return AnyShapeStyle(Color.white) }
        return isOpen ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(.secondary)
    }
}

/// Minimal two-line Vault card (Termius-aligned): 40pt tile/avatar + line 1 bold title + line 2 quiet subtitle
/// + hover/selected trailing edit button.
struct DSVaultCard<Avatar: View, Badge: View>: View {
    let title: String
    let subtitle: String
    var isSubtitleMonospaced: Bool = true
    var isSelected: Bool = false
    var isInspectorOpen: Bool = false
    var isPlaceholder: Bool = false
    var isHoverForced: Bool = false
    var onSelect: (() -> Void)? = nil
    var onPrimaryAction: (() -> Void)? = nil
    var onToggleInspector: (() -> Void)? = nil
    @ViewBuilder let avatar: () -> Avatar
    @ViewBuilder let badge: () -> Badge

    static var height: CGFloat { 66 }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            avatar()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(isPlaceholder ? .secondary : .primary)
                        .lineLimit(1)
                    badge()
                }
                Text(verbatim: subtitle)
                    .font(isSubtitleMonospaced ? .system(size: 11, design: .monospaced) : DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            if let onToggleInspector {
                DSVaultCardInspectorSlot(
                    isOpen: isInspectorOpen,
                    isSelected: isSelected,
                    isHoverForced: isHoverForced,
                    action: onToggleInspector
                )
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, DS.Space.md)
        .frame(height: Self.height)
        .dsCard(isSelected: isSelected || isInspectorOpen, isInteractive: true)
        .onTapGesture(count: 2) {
            if let onPrimaryAction {
                onPrimaryAction()
            } else {
                onToggleInspector?()
            }
        }
        .simultaneousGesture(TapGesture(count: 1).onEnded { _ in
            onSelect?()
        })
    }
}

extension DSVaultCard where Badge == EmptyView {
    init(title: String, subtitle: String, isSubtitleMonospaced: Bool = true, isSelected: Bool = false,
         isInspectorOpen: Bool = false, isPlaceholder: Bool = false, isHoverForced: Bool = false,
         onSelect: (() -> Void)? = nil, onPrimaryAction: (() -> Void)? = nil,
         onToggleInspector: (() -> Void)? = nil, @ViewBuilder avatar: @escaping () -> Avatar) {
        self.init(title: title, subtitle: subtitle, isSubtitleMonospaced: isSubtitleMonospaced,
                  isSelected: isSelected, isInspectorOpen: isInspectorOpen, isPlaceholder: isPlaceholder,
                  isHoverForced: isHoverForced, onSelect: onSelect, onPrimaryAction: onPrimaryAction,
                  onToggleInspector: onToggleInspector, avatar: avatar, badge: { EmptyView() })
    }
}

private struct DSVaultCardInspectorSlot: View {
    let isOpen: Bool
    let isSelected: Bool
    let isHoverForced: Bool
    let action: () -> Void
    @Environment(\.dsIsHovered) private var isHovered

    var body: some View {
        DSCardInspectorButton(
            isOpen: isOpen,
            isVisible: isHovered || isHoverForced || isSelected || isOpen,
            action: action
        )
    }
}

/// Right-side 380pt live inspector container for Vault pages: top bar with title, optional back
/// button for sub-views, trailing actions and close button (`→|`), scrollable content, and an
/// optional pinned bottom primary CTA bar.
struct DSInspectorPanel<HeaderActions: View, Content: View, Footer: View>: View {
    private let title: LocalizedStringKey
    private let onBack: (() -> Void)?
    private let onClose: () -> Void
    private let headerActions: HeaderActions
    private let content: Content
    private let footer: Footer

    init(_ title: LocalizedStringKey, onBack: (() -> Void)? = nil, onClose: @escaping () -> Void,
         @ViewBuilder headerActions: () -> HeaderActions,
         @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.onBack = onBack
        self.onClose = onClose
        self.headerActions = headerActions()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                if let onBack {
                    DSRowButton("chevron.left", help: "Back", action: onBack)
                }
                Text(title)
                    .font(DS.Font.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                headerActions
                DSRowButton("arrow.right.to.line", help: "Hide Inspector (⌘I)", action: onClose)
            }
            .padding(.leading, DS.Space.xl)
            .padding(.trailing, DS.Space.lg)
            .frame(height: 38)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    content
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.md)
                .padding(.bottom, DS.Space.xxl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if Footer.self != EmptyView.self {
                Divider()
                HStack(spacing: DS.Space.sm) {
                    footer
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.md)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
            }
        }
        .frame(width: DS.Layout.inspectorWidth)
        .frame(maxHeight: .infinity)
        .onKeyPress(.escape) {
            if let onBack {
                onBack()
            } else {
                onClose()
            }
            return .handled
        }
    }
}

extension DSInspectorPanel where HeaderActions == EmptyView, Footer == EmptyView {
    init(_ title: LocalizedStringKey, onBack: (() -> Void)? = nil, onClose: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.init(title, onBack: onBack, onClose: onClose,
                  headerActions: { EmptyView() }, content: content, footer: { EmptyView() })
    }
}

extension DSInspectorPanel where HeaderActions == EmptyView {
    init(_ title: LocalizedStringKey, onBack: (() -> Void)? = nil, onClose: @escaping () -> Void,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(title, onBack: onBack, onClose: onClose,
                  headerActions: { EmptyView() }, content: content, footer: footer)
    }
}

extension DSInspectorPanel where Footer == EmptyView {
    init(_ title: LocalizedStringKey, onBack: (() -> Void)? = nil, onClose: @escaping () -> Void,
         @ViewBuilder headerActions: () -> HeaderActions, @ViewBuilder content: () -> Content) {
        self.init(title, onBack: onBack, onClose: onClose,
                  headerActions: headerActions, content: content, footer: { EmptyView() })
    }
}

/// Children in a line that wraps (chips, tags). A child wider than a line is offered the line.
struct DSFlow: Layout {
    var spacing: CGFloat = 6

    /// Where each child goes: origins and sizes for a line of `width`, and the height it takes.
    nonisolated static func arrange(sizes: [CGSize], width: CGFloat, spacing: CGFloat)
        -> (origins: [CGPoint], height: CGFloat, width: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, sizes.isEmpty ? 0 : y + rowHeight, widest)
    }

    private func sizes(of subviews: Subviews, width: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let natural = subview.sizeThatFits(.unspecified)
            guard natural.width > width else { return natural }
            return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .greatestFiniteMagnitude
        let result = Self.arrange(sizes: sizes(of: subviews, width: width), width: width, spacing: spacing)
        return CGSize(width: result.width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(of: subviews, width: bounds.width)
        let result = Self.arrange(sizes: sizes, width: bounds.width, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading,
                          proposal: ProposedViewSize(sizes[index]))
        }
    }
}

extension DSDetailHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, isSubtitleMonospaced: Bool = true, @ViewBuilder icon: () -> Icon,
         @ViewBuilder actions: () -> Actions) {
        self.init(title: title, subtitle: subtitle, isSubtitleMonospaced: isSubtitleMonospaced, icon: icon,
                  accessory: { EmptyView() }, actions: actions)
    }
}

extension DSDetailHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, isSubtitleMonospaced: Bool = true, @ViewBuilder icon: () -> Icon,
         @ViewBuilder accessory: () -> Accessory) {
        self.init(title: title, subtitle: subtitle, isSubtitleMonospaced: isSubtitleMonospaced, icon: icon,
                  accessory: accessory, actions: { EmptyView() })
    }
}

extension DSDetailHeader where Accessory == EmptyView, Actions == EmptyView {
    init(title: String, subtitle: String? = nil, isSubtitleMonospaced: Bool = true, @ViewBuilder icon: () -> Icon) {
        self.init(title: title, subtitle: subtitle, isSubtitleMonospaced: isSubtitleMonospaced, icon: icon,
                  accessory: { EmptyView() }, actions: { EmptyView() })
    }
}

/// Empty state with a next step: the page's tile, one sentence, the main action.
struct DSEmptyState<Actions: View>: View {
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey
    private let symbol: String
    private let actions: Actions
    private var detail: AnyView?

    init(_ title: LocalizedStringKey, message: LocalizedStringKey, symbol: String,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.actions = actions()
    }

    /// With something between the sentence and the actions that shows what the page is for
    /// (a sample route).
    init<Detail: View>(_ title: LocalizedStringKey, message: LocalizedStringKey, symbol: String,
                       @ViewBuilder detail: () -> Detail, @ViewBuilder actions: () -> Actions) {
        self.init(title, message: message, symbol: symbol, actions: actions)
        self.detail = AnyView(detail())
    }

    /// The same with the tile of a sidebar page.
    init<Detail: View>(_ title: LocalizedStringKey, message: LocalizedStringKey, page: SidebarItem,
                       @ViewBuilder detail: () -> Detail, @ViewBuilder actions: () -> Actions) {
        self.init(title, message: message, symbol: page.tileSymbol, detail: detail, actions: actions)
    }

    /// With the tile of a sidebar page.
    init(_ title: LocalizedStringKey, message: LocalizedStringKey, page: SidebarItem,
         @ViewBuilder actions: () -> Actions) {
        self.init(title, message: message, symbol: page.tileSymbol, actions: actions)
    }

    var body: some View {
        VStack(spacing: DS.Space.sm) {
            DSCategoryTile(symbol, size: DS.Tile.header)
                .padding(.bottom, DS.Space.md)
            Text(title)
                .font(DS.Font.pageTitle)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(DS.Font.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let detail {
                detail
                    .frame(maxWidth: 480)
                    .padding(.top, DS.Space.md)
            }
            HStack(spacing: DS.Space.sm) { actions }
                .padding(.top, DS.Space.md)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension DSEmptyState where Actions == EmptyView {
    init(_ title: LocalizedStringKey, message: LocalizedStringKey, page: SidebarItem) {
        self.init(title, message: message, page: page) { EmptyView() }
    }
}

// MARK: - Route diagram

struct DSFlowLine: Shape {
    var isVertical = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if isVertical {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
        return path
    }
}

/// A relationship drawn as a route: This Mac ┄ jump ┄ host, or local port ┄ host ┄ target. Hops
/// are pills with a tile, wires are dotted. The first hop stands at the leading edge, the last
/// at the trailing edge and the ones between at even steps — so the middle hop of three is
/// centred, and routes stacked in one card share their columns. Falls back to a column when the
/// row does not fit. Live = green with a soft glow, failed = red (the words are the page's: a
/// status pill next to it).
struct DSRouteDiagram: View {
    /// A route is worth drawing when it leads through someone: "this Mac → the host" is what
    /// the title next to it already says. One rule for every place that shows a route.
    nonisolated static func addsSomething(hopCount: Int) -> Bool {
        hopCount > 2
    }

    struct Hop: Identifiable, Equatable {
        let id: String
        let title: String
        let content: DSIconTile.Content
        let tint: Color
        var hostId: Int64?
        var status: DSHostAvatar.Status = .none
        /// The hop's address; shown at the end of its line in the column form.
        var detail: String?

        static var thisMac: Hop {
            let mac = DSOperatingSystem.local
            return Hop(id: "this-mac", title: mac.name, content: mac.mark, tint: mac.color)
        }

        /// A port, an address, "any destination".
        static func endpoint(_ title: String, symbol: String = "network") -> Hop {
            Hop(id: "endpoint-\(symbol)-\(title)", title: title, content: .symbol(symbol),
                tint: DSOperatingSystem.local.color)
        }
    }

    enum Activity: Equatable {
        case idle, flowing, failed
    }

    enum Style: Equatable, Sendable {
        /// Pills in a row; a column when the row does not fit.
        case pills
        /// Tiles with their names underneath, for narrow panels (the inspector): never a column.
        case compact
    }

    let hops: [Hop]
    var activity: Activity = .idle
    var style: Style = .pills
    /// How many hops are reached so far, counted from the first; nil = the whole route is in
    /// the state `activity` says. While connecting, the wires to hops not reached yet stay grey.
    var reachedHops: Int?
    /// Called for hops that are saved hosts.
    var onSelectHost: ((Int64) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    /// One dot and the gap after it.
    private static let dotPeriod: CGFloat = 5
    fileprivate static let minimumWire: CGFloat = 18
    fileprivate static let idealWire: CGFloat = 28

    var body: some View {
        Group {
            switch style {
            case .pills: pills
            case .compact: compact
            }
        }
        .onAppear { restartFlow() }
        .onChange(of: activity) { _, _ in restartFlow() }
        // With `onSelectHost` the hops are buttons and stay reachable.
        .accessibilityElement(children: onSelectHost == nil ? .ignore : .contain)
        .accessibilityLabel(Text(verbatim: hops.map(\.title).joined(separator: " → ")))
        .accessibilityValue(activity == .failed ? Text("Failed") : Text(verbatim: ""))
    }

    private var pills: some View {
        ViewThatFits(in: .horizontal) {
            DSRouteRow(spacing: DS.Space.sm, minimumWire: Self.minimumWire, idealWire: Self.idealWire) {
                ForEach(Array(hops.enumerated()), id: \.element.id) { index, hop in
                    if index > 0 { line(to: index) }
                    node(hop)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hops.enumerated()), id: \.element.id) { index, hop in
                    if index > 0 {
                        // Under the centre of the tiles.
                        DSFlowLine(isVertical: true)
                            .stroke(color(to: index), style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                                         dash: [0.01, Self.dotPeriod]))
                            .frame(width: 2, height: 12)
                            .padding(.leading, 7 + DS.Tile.sidebar / 2 - 1)
                    }
                    HStack(spacing: DS.Space.sm) {
                        node(hop)
                        Spacer(minLength: 0)
                        if let detail = hop.detail {
                            Text(verbatim: detail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    /// Tiles with their names underneath, dotted wires between them at the tiles' centres.
    private var compact: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(hops.enumerated()), id: \.element.id) { index, hop in
                if index > 0 {
                    line(to: index)
                        .padding(.top, 13)
                }
                VStack(spacing: 5) {
                    DSHostAvatar(content: hop.content, tint: hop.tint, size: 28, status: hop.status)
                    Text(verbatim: hop.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 60)
            }
        }
    }

    /// Whether the wire that ends at hop `index` is in the route's state, or still pending.
    private func isReached(_ index: Int) -> Bool {
        Self.isReached(hop: index, reachedHops: reachedHops)
    }

    nonisolated static func isReached(hop index: Int, reachedHops: Int?) -> Bool {
        guard let reachedHops else { return true }
        return index < reachedHops
    }

    private func color(to index: Int) -> Color {
        guard isReached(index) else { return Color.secondary.opacity(0.6) }
        switch activity {
        case .idle: return Color.secondary.opacity(0.6)
        case .flowing: return DS.Palette.success
        case .failed: return DS.Palette.danger
        }
    }

    /// The wire that ends at hop `index`.
    private func line(to index: Int) -> some View {
        let isLit = activity == .flowing && isReached(index)
        return DSFlowLine()
            .stroke(color(to: index), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.01, Self.dotPeriod],
                                                         dashPhase: isLit ? phase : 0))
            .frame(minWidth: Self.minimumWire, idealWidth: Self.idealWire, maxWidth: .infinity)
            .frame(height: 2)
            .shadow(color: DS.Palette.success.opacity(isLit ? 0.9 : 0), radius: 2.5)
            // Scoped to the wire. A `withAnimation` around the change would also catch whatever
            // else appears in the same update — glass buttons would materialise forever.
            .animation(flows ? .linear(duration: 0.6).repeatForever(autoreverses: false) : nil, value: phase)
    }

    @ViewBuilder
    private func node(_ hop: Hop) -> some View {
        let label = HStack(spacing: DS.Space.sm) {
            DSHostAvatar(content: hop.content, tint: hop.tint, size: DS.Tile.sidebar, status: hop.status)
            Text(verbatim: hop.title)
                .font(DS.Font.label)
                .lineLimit(1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 13)
        .frame(height: DS.Height.hop)
        .background(DS.Palette.cardRaised, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(DS.Palette.hairline))
        .fixedSize()

        if let hostId = hop.hostId, let onSelectHost {
            Button {
                onSelectHost(hostId)
            } label: {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var flows: Bool {
        activity == .flowing && !reduceMotion
    }

    private func restartFlow() {
        phase = flows ? -(Self.dotPeriod + 0.01) : 0
    }

    /// Where the hops of a row stand (their leading edges) in `width`: the first at 0, the last
    /// at the end, the ones between centred on even steps — pushed apart where two would come
    /// closer than `gap`.
    nonisolated static func hopOrigins(widths: [CGFloat], in width: CGFloat, gap: CGFloat) -> [CGFloat] {
        let count = widths.count
        guard count > 1 else { return widths.map { _ in 0 } }
        var origins: [CGFloat] = []
        for (index, hopWidth) in widths.enumerated() {
            let centre = width * CGFloat(index) / CGFloat(count - 1)
            origins.append(centre - hopWidth / 2)
        }
        origins[0] = 0
        origins[count - 1] = max(width - widths[count - 1], 0)
        // From the trailing edge inwards, then from the leading edge: nothing overlaps, and the
        // first hop keeps its place.
        for index in stride(from: count - 2, through: 1, by: -1) {
            origins[index] = min(origins[index], origins[index + 1] - gap - widths[index])
        }
        for index in 1..<count {
            origins[index] = max(origins[index], origins[index - 1] + widths[index - 1] + gap)
        }
        return origins
    }

    /// The width of a row whose wires are `wire` long.
    nonisolated static func rowWidth(hopWidths: [CGFloat], wire: CGFloat, spacing: CGFloat) -> CGFloat {
        let wires = CGFloat(max(hopWidths.count - 1, 0))
        return hopWidths.reduce(0, +) + wires * (wire + 2 * spacing)
    }
}

/// Lays out hop, wire, hop, wire, hop … (see `DSRouteDiagram.hopOrigins`); the wires take the
/// room between the hops.
private struct DSRouteRow: Layout {
    let spacing: CGFloat
    let minimumWire: CGFloat
    let idealWire: CGFloat

    private func hopSizes(_ subviews: Subviews) -> [CGSize] {
        stride(from: 0, to: subviews.count, by: 2).map { subviews[$0].sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = hopSizes(subviews)
        let widths = sizes.map(\.width)
        let height = sizes.map(\.height).max() ?? 0
        let minimum = DSRouteDiagram.rowWidth(hopWidths: widths, wire: minimumWire, spacing: spacing)
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: DSRouteDiagram.rowWidth(hopWidths: widths, wire: idealWire, spacing: spacing),
                          height: height)
        }
        return CGSize(width: max(width, minimum), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = hopSizes(subviews)
        let widths = sizes.map(\.width)
        let origins = DSRouteDiagram.hopOrigins(widths: widths, in: bounds.width, gap: minimumWire + 2 * spacing)
        for (index, origin) in origins.enumerated() {
            subviews[index * 2].place(at: CGPoint(x: bounds.minX + origin, y: bounds.midY), anchor: .leading,
                                      proposal: ProposedViewSize(sizes[index]))
            guard index > 0 else { continue }
            let start = origins[index - 1] + widths[index - 1] + spacing
            let length = max(origin - spacing - start, 0)
            subviews[index * 2 - 1].place(at: CGPoint(x: bounds.minX + start, y: bounds.midY), anchor: .leading,
                                          proposal: ProposedViewSize(width: length, height: 2))
        }
    }
}

extension DSRouteDiagram.Hop {
    init(host: Host, status: DSHostAvatar.Status = .none) {
        self.init(id: host.connectionKey, title: host.displayName, content: host.tileContent,
                  tint: host.tint, hostId: host.id, status: status, detail: host.addressDescription)
    }
}

extension Host {
    /// This Mac, the jump chain (outermost first), this host. Same rule as
    /// `SSHService`: a host's own jump host, otherwise its group's (never itself).
    func routeHops(hosts: [Host], groups: [HostGroup]) -> [DSRouteDiagram.Hop] {
        func jumpId(of host: Host) -> Int64? {
            if let id = host.jumpHostId { return id }
            guard let groupId = host.groupId,
                  let group = groups.first(where: { $0.id == groupId }),
                  let id = group.jumpHostId, id != host.id else { return nil }
            return id
        }

        var chain: [Host] = [self]
        var visited = Set<Int64>()
        if let id { visited.insert(id) }
        var current = self
        while chain.count < 8, let next = jumpId(of: current), !visited.contains(next),
              let jump = hosts.first(where: { $0.id == next }) {
            visited.insert(next)
            chain.insert(jump, at: 0)
            current = jump
        }
        return [.thisMac] + chain.map { DSRouteDiagram.Hop(host: $0) }
    }

    /// Name of the first jump host on the way, if any.
    func firstJumpName(hosts: [Host], groups: [HostGroup]) -> String? {
        let hops = routeHops(hosts: hosts, groups: groups)
        return hops.count > 2 ? hops[hops.count - 2].title : nil
    }
}

// MARK: - Fingerprint image

/// OpenSSH's "drunken bishop" walk over the SHA-256 digest of a key — the picture
/// `ssh-keygen -lv` prints. Nil when the text is not a SHA256 fingerprint (never a made-up image).
struct Randomart: Equatable, Sendable {
    static let columns = 17
    static let rows = 9

    /// Visit counts (0…14), row by row.
    let cells: [UInt8]
    let start: Int
    let end: Int

    init?(fingerprint: String) {
        guard let prefix = fingerprint.range(of: "SHA256:") else { return nil }
        // Only the base64 characters: ssh's own prompt ends the fingerprint with a full stop.
        var base64 = String(fingerprint[prefix.upperBound...].prefix {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/")
        })
        while base64.count % 4 != 0 { base64.append("=") }
        // A SHA-256 digest is 32 bytes; anything else is not a fingerprint.
        guard let digest = Data(base64Encoded: base64), digest.count == 32 else { return nil }

        var cells = [UInt8](repeating: 0, count: Self.columns * Self.rows)
        var x = Self.columns / 2
        var y = Self.rows / 2
        let start = y * Self.columns + x
        for byte in digest {
            var bits = byte
            for _ in 0..<4 {
                x = min(max(x + ((bits & 1) != 0 ? 1 : -1), 0), Self.columns - 1)
                y = min(max(y + ((bits & 2) != 0 ? 1 : -1), 0), Self.rows - 1)
                let index = y * Self.columns + x
                if cells[index] < 14 { cells[index] += 1 }
                bits >>= 2
            }
        }
        self.cells = cells
        self.start = start
        self.end = y * Self.columns + x
    }

    /// The nine lines inside the frame `ssh-keygen -lv` draws.
    var ascii: String {
        let symbols = Array(" .o+=*BOX@%&#/^")
        var lines: [String] = []
        for row in 0..<Self.rows {
            var line = ""
            for column in 0..<Self.columns {
                let index = row * Self.columns + column
                if index == end {
                    line.append("E")
                } else if index == start {
                    line.append("S")
                } else {
                    line.append(symbols[Int(cells[index])])
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// A key fingerprint as an image, in the accent. `cell` 4 → 68×36 (rows), 8 → 136×72,
/// 12 → 204×108 (details). On the selected row of a master list (an accent pill) it turns white
/// by itself — an accent image on the accent would be gone.
struct DSRandomart: View {
    let fingerprint: String?
    /// Nil: the accent, white on a selected row.
    var tint: Color?
    var cell: CGFloat = 8
    @Environment(\.dsIsSelected) private var isSelected

    var body: some View {
        let art = fingerprint.flatMap { Randomart(fingerprint: $0) }
        let tint = self.tint ?? (isSelected ? Color.white : DS.Palette.accent)
        Canvas { context, size in
            guard let art else { return }
            let step = size.width / CGFloat(Randomart.columns)
            // Half points: the cells keep sharp edges at 4 pt.
            let inset = max(0.5, (step * 0.16).rounded() / 2)
            for index in art.cells.indices {
                let column = CGFloat(index % Randomart.columns)
                let row = CGFloat(index / Randomart.columns)
                let rect = CGRect(x: column * step, y: row * step, width: step, height: step)
                    .insetBy(dx: inset, dy: inset)
                let shape = Path(roundedRect: rect, cornerRadius: step * 0.2)
                if index == art.end {
                    // Where the walk ended: the brightest cell.
                    context.fill(shape, with: .color(tint.mix(with: .white, by: 0.35)))
                } else {
                    // Plain cells only; the start is told apart in the tooltip's text form (S).
                    let count = Double(art.cells[index])
                    guard count > 0 else { continue }
                    context.fill(shape, with: .color(tint.opacity(min(0.28 + count * 0.2, 1))))
                }
            }
        }
        .frame(width: cell * CGFloat(Randomart.columns), height: cell * CGFloat(Randomart.rows))
        .padding(max(2, cell * 0.5))
        .background(isSelected ? Color.white.opacity(0.16) : DS.Palette.cardRaised,
                    in: RoundedRectangle(cornerRadius: max(4, cell), style: .continuous))
        .overlay {
            if art == nil {
                Image(systemName: "questionmark")
                    .foregroundStyle(.tertiary)
            }
        }
        .help(Text(verbatim: art?.ascii ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Key fingerprint image"))
        .accessibilityValue(Text(verbatim: art == nil ? "" : (fingerprint ?? "")))
    }
}

// MARK: - Code block

/// Monospaced text that is typed into or came out of a terminal — commands, output — on a
/// terminal-coloured surface (dark in both appearances). Not for content that merely is
/// monospaced: a public key or a fingerprint sits on a card (`DSGroup`).
struct DSCodeBlock: View {
    enum Size: Equatable, Sendable {
        /// 13 pt on a 16 pt-radius block: the command of a snippet.
        case regular
        /// 12 pt on a 12 pt-radius block: inside cards and sheets.
        case small
    }

    private let text: AttributedString
    private let plain: String
    private let prompt: String?
    private let size: Size
    private let lineLimit: Int?

    init(_ plain: String, prompt: String? = nil, size: Size = .regular, lineLimit: Int? = nil) {
        self.text = AttributedString(plain)
        self.plain = plain
        self.prompt = prompt
        self.size = size
        self.lineLimit = lineLimit
    }

    /// A snippet command: its `{{variables}}` highlighted.
    init(template command: String, prompt: String? = nil, size: Size = .regular, lineLimit: Int? = nil) {
        var attributed = AttributedString(command)
        for range in Self.variableRanges(in: command) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].swiftUI.foregroundColor = DS.Palette.accent.mix(with: .white, by: 0.55)
            attributed[lower..<upper].swiftUI.backgroundColor = DS.Palette.accent.opacity(0.26)
        }
        self.text = attributed
        self.plain = command
        self.prompt = prompt
        self.size = size
        self.lineLimit = lineLimit
    }

    /// A snippet command as it will run: every `{{variable}}` that has a value is replaced by
    /// it and highlighted; the ones still empty stay as written (highlighted too). The copy
    /// button copies what is shown.
    init(template command: String, values: [String: String], prompt: String? = nil, size: Size = .regular,
         lineLimit: Int? = nil) {
        let filled = Self.fill(command, values: values)
        var attributed = AttributedString(filled.text)
        for range in filled.highlights {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].swiftUI.foregroundColor = DS.Palette.accent.mix(with: .white, by: 0.55)
            attributed[lower..<upper].swiftUI.backgroundColor = DS.Palette.accent.opacity(0.26)
        }
        self.text = attributed
        self.plain = filled.text
        self.prompt = prompt
        self.size = size
        self.lineLimit = lineLimit
    }

    /// `command` with the non-empty `values` put in place of their `{{variables}}`, and where the
    /// substituted values and the remaining variables are in the result. Names are matched as
    /// `SnippetTemplate` does (spaces inside the braces do not count).
    nonisolated static func fill(_ command: String, values: [String: String])
        -> (text: String, highlights: [Range<String.Index>]) {
        var text = ""
        // Offsets in characters: the ranges are made once the text is whole.
        var spans: [(start: Int, length: Int)] = []
        var cursor = command.startIndex
        for range in variableRanges(in: command) {
            text += command[cursor..<range.lowerBound]
            let name = command[range].dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
            let value = values[name] ?? ""
            let shown = value.isEmpty ? String(command[range]) : value
            spans.append((start: text.count, length: shown.count))
            text += shown
            cursor = range.upperBound
        }
        text += command[cursor...]
        let highlights = spans.map { span -> Range<String.Index> in
            let lower = text.index(text.startIndex, offsetBy: span.start)
            return lower..<text.index(lower, offsetBy: span.length)
        }
        return (text, highlights)
    }

    /// Where the `{{variables}}` of a command are, braces included; an opening without a closing
    /// is not one.
    nonisolated static func variableRanges(in command: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = command.startIndex
        while searchStart < command.endIndex,
              let open = command.range(of: "{{", range: searchStart..<command.endIndex),
              let close = command.range(of: "}}", range: open.upperBound..<command.endIndex) {
            ranges.append(open.lowerBound..<close.upperBound)
            searchStart = close.upperBound
        }
        return ranges
    }

    var body: some View {
        let isSmall = size == .small
        let shape = RoundedRectangle(cornerRadius: isSmall ? DS.Radius.row : DS.Radius.card, style: .continuous)
        HStack(alignment: .top, spacing: DS.Space.md) {
            if let prompt {
                Text(verbatim: prompt)
                    .foregroundStyle(Color(white: 0.5))
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                // Wraps to as many lines as it needs (up to the limit); left to itself it
                // stays on one line and cuts the middle out of a command.
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            DSCopyButton(help: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(plain, forType: .string)
            }
            // As high as a line of text: the icon sits on the first line.
            .padding(.vertical, -3)
        }
        .font(.system(size: isSmall ? 12 : 13, design: .monospaced))
        .lineSpacing(isSmall ? 3 : 5)
        .foregroundStyle(Color(white: 0.92))
        .padding(.vertical, isSmall ? 11 : 15)
        .padding(.leading, isSmall ? 14 : 18)
        .padding(.trailing, isSmall ? 12 : 14)
        .background(DS.Palette.terminal, in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.09)))
        // The surface is dark whatever the window is: the controls on it are too.
        .environment(\.colorScheme, .dark)
    }
}

/// The colours of a terminal theme (terminal themes are the one place hex colours come from).
struct DSThemeSwatches: View {
    let theme: TerminalTheme
    var count = 8
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(theme.ansiColors.prefix(count).enumerated()), id: \.offset) { item in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: TerminalTheme.nsColor(hex: item.element)))
                    .frame(width: size, height: size)
            }
        }
        .padding(3)
        .background(Color(nsColor: theme.nsBackground), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        // A dark theme on a dark window (a light one on a light window) still has an edge.
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(DS.Palette.hairline))
        .accessibilityHidden(true)
    }
}

// MARK: - Going from one page to a record on another

struct DSRevealTarget: Equatable {
    let page: SidebarItem
    let id: String
    let window: ObjectIdentifier
}

/// "Show this key / identity / known host on its page": set by the page that links, taken by the
/// page that shows it. Hosts go through `hostsPage.selectedHostId` (that model lives with the window).
@MainActor
@Observable
final class DSReveal {
    static let shared = DSReveal()
    var target: DSRevealTarget?

    private init() {}
}

extension Notification.Name {
    /// Posted after a save or delete of hosts, keys, identities, snippets, known hosts or port
    /// forwards: the sidebar refreshes its counts.
    static let dsDataChanged = Notification.Name("dev.termi.Termi.dataChanged")
}

extension AppViewModel {
    /// Open `page` with the record `id` (its database id as text) selected.
    func reveal(_ page: SidebarItem, id: String) {
        if page == .terminal {
            // The Hosts page shows a record only when asked: this link asks for it.
            if let hostId = Int64(id) { hostsPage.showRecord(of: hostId) }
        } else {
            DSReveal.shared.target = DSRevealTarget(page: page, id: id, window: ObjectIdentifier(self))
        }
        selectedSidebar = page
        isViewingTerminal = false
    }

    func reveal(host: Host) {
        guard let id = host.id else { return }
        reveal(.terminal, id: String(id))
    }

    /// The record this window asked `page` to show, once.
    func takeReveal(for page: SidebarItem) -> String? {
        guard let target = DSReveal.shared.target, target.page == page,
              target.window == ObjectIdentifier(self) else { return nil }
        DSReveal.shared.target = nil
        return target.id
    }

    /// Pages that show "used by these hosts" need the hosts before the Hosts page was opened.
    func ensureHostsLoaded() async {
        if !hostsPage.hasLoaded {
            await hostsPage.loadHosts()
        }
    }

    /// Live state of a saved host across this window's sessions.
    func avatarStatus(forHostId hostId: Int64?) -> DSHostAvatar.Status {
        guard let hostId else { return .none }
        let states = tabs.flatMap(\.panes)
            .filter { $0.hostId == hostId }
            .compactMap { existingSession(for: $0.id)?.state }
        return DSHostAvatar.Status(states: states)
    }
}
