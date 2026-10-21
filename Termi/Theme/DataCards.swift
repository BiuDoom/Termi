import SwiftUI
import AppKit

// The content layer's cards and rows: neutral surfaces, data in the accent, fixed columns.
// Numbers are right-aligned or on a shared baseline with tabular digits, units and labels have
// fixed places, values that sit side by side are divided by a hairline, and nothing wraps.

// MARK: - Tint of the card

private struct DSTintKey: EnvironmentKey {
    static let defaultValue = Color.accentColor
}

extension EnvironmentValues {
    /// The colour of the data inside a card (glyph, meter, trend line, day strip): the accent,
    /// or the card's status tone. Set by `DSStatCard` / `DSGaugeCard`.
    var dsTint: Color {
        get { self[DSTintKey.self] }
        set { self[DSTintKey.self] = newValue }
    }
}

// MARK: - Number card

/// One number that matters: label with a small glyph, the big number and its unit, one line of
/// footnote, and optionally an element along the bottom (`DSMeter`, `DSSparkline`, `DSDayStrip`).
/// The data is the accent; pass a status `tone` only when the number IS a status. `isHero` washes
/// the card in its tone — at most one per screen.
struct DSStatCard<Accessory: View>: View {
    private let title: LocalizedStringKey
    private let value: String
    private let unit: String?
    private let symbol: String?
    private let footnote: String?
    private let tone: DS.Tone
    private let isHero: Bool
    private let lead: DSStatLead?
    private let isFlat: Bool
    private let accessory: Accessory
    @Environment(\.dsFillsRowHeight) private var fillsRowHeight

    /// `lead`: what the value is about, drawn in front of it — the value is then a name
    /// ("Most Connected: web-01"), set a size smaller than a number.
    /// `isFlat`: a card of a row in which no card has a chart under its number — the number is
    /// set one size down (`DS.Font.value`), the row is lower.
    init(_ title: LocalizedStringKey, value: String, unit: String? = nil, symbol: String? = nil,
         footnote: String? = nil, tone: DS.Tone = .accent, isHero: Bool = false, lead: DSStatLead? = nil,
         isFlat: Bool = false, @ViewBuilder accessory: () -> Accessory) {
        self.isFlat = isFlat
        self.title = title
        self.value = value
        self.unit = unit
        self.symbol = symbol
        self.footnote = footnote
        self.tone = tone
        self.isHero = isHero
        self.lead = lead
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSCardLabel(title, symbol: symbol)
            if let lead {
                HStack(spacing: DS.Space.sm) {
                    lead.tile
                    Text(verbatim: value)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .help(Text(verbatim: value))
                }
                // As high as the line of a number, so the footnotes of a row stay on one line.
                .frame(height: 32)
                .padding(.top, 3)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: value)
                        .font(isFlat ? DS.Font.value : DS.Font.stat)
                        .tracking(-0.6)
                        .contentTransition(.numericText())
                    if let unit {
                        Text(verbatim: unit)
                            .font(DS.Font.unit)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 3)
            }
            if let footnote {
                Text(verbatim: footnote)
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 1)
            }
            if fillsRowHeight {
                // The bottom elements of a row of cards sit on one line.
                Spacer(minLength: 0)
            }
            if Accessory.self != EmptyView.self {
                accessory
                    .padding(.top, 9)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, DS.Space.md)
        .padding(.bottom, isFlat ? DS.Space.md : 13)
        .frame(maxWidth: .infinity, maxHeight: fillsRowHeight ? .infinity : nil, alignment: .topLeading)
        .dsCard(hero: isHero ? tone.color : nil)
        .environment(\.dsTint, tone.color)
        .dsAnimated(DS.Motion.standard, value: value)
        .accessibilityElement(children: .combine)
    }
}

extension DSStatCard where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, value: String, unit: String? = nil, symbol: String? = nil,
         footnote: String? = nil, tone: DS.Tone = .accent, isHero: Bool = false, lead: DSStatLead? = nil,
         isFlat: Bool = false) {
        self.init(title, value: value, unit: unit, symbol: symbol, footnote: footnote, tone: tone,
                  isHero: isHero, lead: lead, isFlat: isFlat) { EmptyView() }
    }
}

/// What stands in front of a number card's value when the value is a name.
enum DSStatLead {
    /// A saved host: its tile.
    case host(Host)
    /// A system without a saved host (the host was deleted since).
    case system(DSOperatingSystem)
    /// Any other tile (an identity's monogram, a key).
    case tile(DSIconTile.Content, tint: Color)

    @MainActor @ViewBuilder
    fileprivate var tile: some View {
        switch self {
        case .host(let host): DSHostAvatar(host, size: 24)
        case .system(let system): DSHostAvatar(os: system, size: 24)
        case .tile(let content, let tint): DSIconTile(content, tint: tint, size: 24)
        }
    }
}

/// The label of a card: a small glyph in the card's tint, the name in secondary.
struct DSCardLabel: View {
    private let title: LocalizedStringKey
    private let symbol: String?
    @Environment(\.dsTint) private var tint

    init(_ title: LocalizedStringKey, symbol: String? = nil) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(DS.Font.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: 18)
    }
}

/// Cards in a row that wraps when the page gets narrow. The cards of a row share its width and
/// are equally high (one with a footnote does not stand out of line).
struct DSStatGrid<Content: View>: View {
    private let minimum: CGFloat
    private let widestOfFew: CGFloat?
    private let content: Content

    /// `widestOfFew`: how wide one or two cards may get — they do not stretch across a page.
    /// Nil where the cards ARE the row (two cards filling a settings pane).
    init(minimum: CGFloat = 132, widestOfFew: CGFloat? = 320, @ViewBuilder content: () -> Content) {
        self.minimum = minimum
        self.widestOfFew = widestOfFew
        self.content = content()
    }

    var body: some View {
        DSStatGridLayout(minimum: minimum, spacing: DS.Space.card, widestOfFew: widestOfFew) {
            content
        }
        .environment(\.dsFillsRowHeight, true)
    }
}

/// Equal columns, as many as fit at `minimum` width but never more than there are tiles
/// (an adaptive `LazyVGrid` keeps empty columns, which leaves four tiles in a corner).
private struct DSStatGridLayout: Layout {
    let minimum: CGFloat
    let spacing: CGFloat
    /// One or two tiles do not stretch across the page.
    let widestOfFew: CGFloat?

    private struct Metrics {
        var columns = 1
        var columnWidth: CGFloat = 0
        var rowHeights: [CGFloat] = []
    }

    private func metrics(width proposed: CGFloat?, subviews: Subviews) -> Metrics {
        let count = subviews.count
        guard count > 0 else { return Metrics() }
        let natural = CGFloat(count) * minimum + CGFloat(count - 1) * spacing
        let width = proposed.flatMap { $0.isFinite ? $0 : nil } ?? natural
        let columns = DSStatGrid<EmptyView>.columns(count: count, width: width, minimum: minimum, spacing: spacing)
        let columnWidth = DSStatGrid<EmptyView>.columnWidth(count: count, columns: columns, width: width,
                                                            spacing: spacing, widestOfFew: widestOfFew)
        var rowHeights: [CGFloat] = []
        for start in stride(from: 0, to: count, by: columns) {
            let row = subviews[start..<min(start + columns, count)]
            rowHeights.append(row.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0)
        }
        return Metrics(columns: columns, columnWidth: columnWidth, rowHeights: rowHeights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let grid = metrics(width: proposal.width, subviews: subviews)
        guard !grid.rowHeights.isEmpty else { return .zero }
        let height = grid.rowHeights.reduce(0, +) + CGFloat(grid.rowHeights.count - 1) * spacing
        let used = CGFloat(grid.columns) * grid.columnWidth + CGFloat(grid.columns - 1) * spacing
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? used
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = metrics(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in grid.rowHeights.enumerated() {
            for column in 0..<grid.columns {
                let index = row * grid.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (grid.columnWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: grid.columnWidth, height: height))
            }
            y += height + spacing
        }
    }
}

extension DSStatGrid {
    /// As many equal columns as fit at `minimum` width, never more than there are tiles.
    nonisolated static func columns(count: Int, width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let fitting = max(1, Int((width + spacing) / (minimum + spacing)))
        return min(count, fitting)
    }

    /// The width of a column; one or two tiles are capped at `widestOfFew`.
    nonisolated static func columnWidth(count: Int, columns: Int, width: CGFloat, spacing: CGFloat,
                                        widestOfFew: CGFloat?) -> CGFloat {
        let gaps = CGFloat(max(columns - 1, 0)) * spacing
        let share = max(0, (width - gaps) / CGFloat(max(columns, 1)))
        guard count < 3, let widestOfFew else { return share }
        return min(share, widestOfFew)
    }
}

private struct DSFillsRowHeightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by `DSStatGrid`: its tiles take the height of their row. A card a page builds by
    /// hand reads it to do the same (`maxHeight: .infinity` and a spacer above its bottom element).
    var dsFillsRowHeight: Bool {
        get { self[DSFillsRowHeightKey.self] }
        set { self[DSFillsRowHeightKey.self] = newValue }
    }
}

// MARK: - Gauge card

/// A level as an arc gauge (Monitoring): label, the 270° arc in the level's colour with the
/// numeral in its centre, a detail line under it, and an element along the bottom (a trend line,
/// or a `DSMeter` with its caption). From 60 % the card says so in words too.
struct DSGaugeCard<Accessory: View>: View {
    private let title: LocalizedStringKey
    private let symbol: String?
    private let percent: Double?
    private let detail: String
    private let isHero: Bool
    private let diameter: CGFloat
    private let accessory: Accessory
    @Environment(\.dsFillsRowHeight) private var fillsRowHeight

    /// `percent` nil: no reading yet — the arc is empty and the numeral is a dash.
    /// `diameter`: 128 as drawn; give a smaller one (84) where three cards share a narrow page —
    /// the card then tightens its padding with it.
    init(_ title: LocalizedStringKey, symbol: String? = nil, percent: Double?, detail: String,
         isHero: Bool = false, diameter: CGFloat = 128, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.symbol = symbol
        self.percent = percent
        self.detail = detail
        self.isHero = isHero
        self.diameter = diameter
        self.accessory = accessory()
    }

    /// Below this the card is the compact one: thinner arc, tighter padding, lower accessory.
    private var isCompact: Bool { diameter < 100 }

    private var tone: DS.Tone {
        DS.Tone.level(percent: percent ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: isCompact ? DS.Space.xs : 6) {
                DSCardLabel(title, symbol: symbol)
                Spacer(minLength: 0)
                levelBadge
            }
            // The gauge puts the detail in the arc's opening when it fits there, under the arc
            // when it does not: it never lies on the arc's ends.
            DSArcGauge(percent: percent, detail: detail, diameter: diameter, lineWidth: isCompact ? 8 : 10)
                .padding(.top, isCompact ? DS.Space.xs : 6)
            if fillsRowHeight {
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                accessory
            }
            .frame(height: isCompact ? 22 : 30)
            .frame(maxWidth: .infinity)
            .padding(.top, DS.Space.sm)
        }
        .padding(.horizontal, isCompact ? DS.Space.card : 14)
        .padding(.vertical, isCompact ? DS.Space.card : DS.Space.md)
        .frame(maxWidth: .infinity, maxHeight: fillsRowHeight ? .infinity : nil, alignment: .top)
        .dsCard(hero: isHero ? tone.color : nil)
        .environment(\.dsTint, tone.color)
        .accessibilityElement(children: .combine)
    }

    /// A level is a status, and a status is never colour alone.
    @ViewBuilder
    private var levelBadge: some View {
        switch tone {
        case .warning: DSStatusPill("High", tone: .warning, showsBackground: false)
        case .danger: DSStatusPill("Critical", tone: .danger, showsBackground: false)
        default: EmptyView()
        }
    }
}

extension DSGaugeCard where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, symbol: String? = nil, percent: Double?, detail: String, isHero: Bool = false,
         diameter: CGFloat = 128) {
        self.init(title, symbol: symbol, percent: percent, detail: detail, isHero: isHero, diameter: diameter) {
            EmptyView()
        }
    }
}

// MARK: - Values side by side

/// Values that sit side by side in one card: equal columns, a hairline between them.
struct DSDividedRow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    subview
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, index > 0 ? DS.Space.lg : 0)
                        .padding(.trailing, index < subviews.count - 1 ? DS.Space.lg : 0)
                        .overlay(alignment: .leading) {
                            if index > 0 {
                                Rectangle()
                                    .fill(DS.Palette.separator)
                                    .frame(width: 1)
                            }
                        }
                }
            }
        }
    }
}

/// One value of a row of values, every datum in a fixed place: glyph | number | unit | something
/// trailing (a trend line), and a caption above or below. Give `valueWidth` (and `unitWidth`)
/// when several cells must line up: the number is then right-aligned in that column.
struct DSValueCell<Trailing: View>: View {
    enum CaptionPlacement: Equatable, Sendable {
        case above, below
    }

    private let value: String
    private let unit: String?
    private let caption: String
    private let captionPlacement: CaptionPlacement
    private let symbol: String?
    private let valueWidth: CGFloat?
    private let unitWidth: CGFloat?
    private let trailing: Trailing
    @Environment(\.dsTint) private var tint

    init(value: String, unit: String? = nil, caption: String, captionPlacement: CaptionPlacement = .below,
         symbol: String? = nil, valueWidth: CGFloat? = nil, unitWidth: CGFloat? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.value = value
        self.unit = unit
        self.caption = caption
        self.captionPlacement = captionPlacement
        self.symbol = symbol
        self.valueWidth = valueWidth
        self.unitWidth = unitWidth
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 0) {
                if captionPlacement == .above { captionText }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(tint)
                            .frame(width: 22, alignment: .leading)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: value)
                        .font(DS.Font.value)
                        .tracking(-0.4)
                        .frame(width: valueWidth, alignment: .trailing)
                    if let unit {
                        Text(verbatim: unit)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, DS.Space.xs)
                            .frame(width: unitWidth, alignment: .leading)
                    }
                }
                .frame(height: 28)
                if captionPlacement == .below { captionText }
            }
            .lineLimit(1)
            .fixedSize()
            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var captionText: some View {
        Text(verbatim: caption)
            .font(DS.Font.caption)
            .foregroundStyle(.secondary)
    }
}

extension DSValueCell where Trailing == EmptyView {
    init(value: String, unit: String? = nil, caption: String, captionPlacement: CaptionPlacement = .below,
         symbol: String? = nil, valueWidth: CGFloat? = nil, unitWidth: CGFloat? = nil) {
        self.init(value: value, unit: unit, caption: caption, captionPlacement: captionPlacement, symbol: symbol,
                  valueWidth: valueWidth, unitWidth: unitWidth) { EmptyView() }
    }
}

// MARK: - Group card and rows

/// The header above a group card: its name, and something trailing (a count, a link).
struct DSSectionHeader<Trailing: View>: View {
    private let title: LocalizedStringKey
    private let trailing: Trailing

    init(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(DS.Font.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DS.Space.sm)
            trailing
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.bottom, 7)
    }
}

extension DSSectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.init(title) { EmptyView() }
    }
}

/// A group card: rows on one neutral card, a hairline between them. Rows are `DSRow`,
/// `DSKeyValueRow`, `DSLinkRow`, or anything else (a chart with its own padding).
struct DSGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    if index > 0 {
                        Rectangle()
                            .fill(DS.Palette.separator)
                            .frame(height: 1)
                    }
                    subview
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCard()
    }
}

/// A row of a group card: 40 pt (32 when compact), its content in one line.
struct DSRow<Content: View>: View {
    private let isCompact: Bool
    private let content: Content

    init(isCompact: Bool = false, @ViewBuilder content: () -> Content) {
        self.isCompact = isCompact
        self.content = content()
    }

    var body: some View {
        HStack(spacing: DS.Space.card) {
            content
        }
        .font(DS.Font.body)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, isCompact ? 5 : DS.Space.sm)
        .frame(maxWidth: .infinity, minHeight: isCompact ? DS.Height.compactRow : DS.Height.formRow, alignment: .leading)
    }
}

/// A row that names a value: the key in a fixed column, then the value. Inside
/// `dsKeyColumn(fitting:)` the column is as wide as the longest key of the group in the current
/// language; otherwise 76 pt (four Chinese characters — too narrow for "Authentication").
struct DSKeyValueRow<Value: View>: View {
    private let key: LocalizedStringKey
    private let keyWidth: CGFloat?
    private let value: Value

    /// `keyWidth` nil: the column of the group (`dsKeyColumn(fitting:)`), else 76.
    init(_ key: LocalizedStringKey, keyWidth: CGFloat? = nil, @ViewBuilder value: () -> Value) {
        self.key = key
        self.keyWidth = keyWidth
        self.value = value()
    }

    var body: some View {
        DSRow {
            DSKeyLabel(key, width: keyWidth)
            value
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

extension DSKeyValueRow where Value == Text {
    /// A plain value; `isMonospaced` for addresses, commands, fingerprints.
    init(_ key: LocalizedStringKey, value: String, isMonospaced: Bool = false, keyWidth: CGFloat? = nil) {
        self.init(key, keyWidth: keyWidth) {
            Text(verbatim: value)
                .font(isMonospaced ? DS.Font.mono : DS.Font.body)
        }
    }
}

/// The key of a key–value row, for rows a page lays out itself: in the key column of the group.
struct DSKeyLabel: View {
    private let key: LocalizedStringKey
    private let width: CGFloat?
    @Environment(\.dsKeyColumn) private var column

    init(_ key: LocalizedStringKey, width: CGFloat? = nil) {
        self.key = key
        self.width = width
    }

    var body: some View {
        if width == nil, !column.isEmpty {
            // Every key of the group, hidden, under the one that shows: the column is as wide
            // as the longest, measured by the text system itself in the current language.
            ZStack(alignment: .leading) {
                ForEach(Array(column.enumerated()), id: \.offset) { _, other in
                    Text(other).hidden()
                }
                Text(key)
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(key))
        } else {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: width ?? 76, alignment: .leading)
        }
    }
}

private struct DSKeyColumnKey: EnvironmentKey {
    // Computed: `LocalizedStringKey` is not Sendable in every SDK this builds with.
    static var defaultValue: [LocalizedStringKey] { [] }
}

extension EnvironmentValues {
    /// The keys that share a column; set by `dsKeyColumn(fitting:)`.
    var dsKeyColumn: [LocalizedStringKey] {
        get { self[DSKeyColumnKey.self] }
        set { self[DSKeyColumnKey.self] = newValue }
    }
}

extension View {
    /// Gives the `DSKeyValueRow`s / `DSKeyLabel`s inside (a `DSGroup`, a whole detail) one key
    /// column that fits the longest of `keys`.
    func dsKeyColumn(fitting keys: [LocalizedStringKey]) -> some View {
        environment(\.dsKeyColumn, keys)
    }
}

/// A row that leads somewhere ("used by web-01 ›"): icon, title over an optional second line,
/// something trailing, a chevron.
struct DSLinkRow<Icon: View, Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let action: () -> Void
    private let icon: Icon
    private let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, action: @escaping () -> Void,
         @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.icon = icon()
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.md) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(DS.Font.body)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: DS.Space.sm)
                trailing
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, DS.Space.sm)
            .frame(maxWidth: .infinity, minHeight: subtitle == nil ? DS.Height.formRow : DS.Height.listRow, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension DSLinkRow where Trailing == Text {
    /// With a short trailing text ("via identity ops").
    init(_ title: String, subtitle: String? = nil, detail: String? = nil, action: @escaping () -> Void,
         @ViewBuilder icon: () -> Icon) {
        self.init(title, subtitle: subtitle, action: action, icon: icon) {
            Text(verbatim: detail ?? "")
        }
    }
}

extension DSLinkRow where Icon == DSHostAvatar, Trailing == Text {
    /// A saved host.
    init(host: Host, status: DSHostAvatar.Status = .none, detail: String? = nil, action: @escaping () -> Void) {
        self.init(host.displayName, subtitle: host.addressDescription, detail: detail, action: action) {
            DSHostAvatar(host, size: DS.Tile.row, status: status)
        }
    }
}
