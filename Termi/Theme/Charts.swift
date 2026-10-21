import SwiftUI
import AppKit
import Charts

// Data drawn as data. Everything here is the accent (or the tint of the card it sits in, which
// is a status tone only when the number is a status), with a soft glow of its own colour.

// MARK: - Meter

/// A share as a thin bar. In a card it takes the card's tint.
struct DSMeter: View {
    /// 0…100.
    let percent: Double
    var tint: Color?
    var height: CGFloat = 6
    @Environment(\.dsTint) private var cardTint

    var body: some View {
        let color = tint ?? cardTint
        GeometryReader { proxy in
            Capsule()
                .fill(color)
                .frame(width: proxy.size.width * Self.fraction(percent: percent))
                .shadow(color: color.opacity(0.7), radius: 5)
        }
        .frame(height: height)
        .background(color.opacity(0.22), in: Capsule())
        .dsAnimated(DS.Motion.standard, value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(verbatim: "\(Int(percent.rounded()))%"))
    }

    /// The filled share of the bar, 0…1.
    nonisolated static func fraction(percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(max(percent, 0), 100) / 100
    }
}

// MARK: - Day strip

/// A strip of days: lit when something happened that day. In a card it takes the card's tint.
struct DSDayStrip: View {
    /// Oldest first.
    let days: [Bool]
    var tint: Color?
    @Environment(\.dsTint) private var cardTint

    var body: some View {
        let color = tint ?? cardTint
        HStack(spacing: 3) {
            ForEach(Array(days.enumerated()), id: \.offset) { day in
                Capsule()
                    .fill(day.element ? color : color.opacity(0.22))
                    .shadow(color: color.opacity(day.element ? 0.6 : 0), radius: 4)
                    .frame(maxWidth: .infinity)
                    .frame(height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Active days"))
        .accessibilityValue(Text(verbatim: "\(days.filter { $0 }.count) / \(days.count)"))
    }

    /// Which of the days had a connection (succeeded or failed).
    nonisolated static func days(from activity: [DSActivityChart.Day]) -> [Bool] {
        activity.map { $0.succeeded + $0.failed > 0 }
    }
}

// MARK: - Trend line

/// Trend without axes: a line over a faint area, with a soft glow. In a card it takes the
/// card's tint.
struct DSSparkline: View {
    let values: [Double]
    var tint: Color?
    /// The scale; without it the line fills the height between its lowest and highest value.
    var range: ClosedRange<Double>?
    var lineWidth: CGFloat = 2
    /// The least the scale spans when it is taken from the values: with it, two or three nearly
    /// equal samples draw as a nearly flat line instead of a full-height ramp.
    var minimumSpan: Double = 0
    @Environment(\.dsTint) private var cardTint

    var body: some View {
        let color = tint ?? cardTint
        Chart(Array(values.enumerated()), id: \.offset) { point in
            AreaMark(x: .value("Time", point.offset), yStart: .value("Baseline", domain.lowerBound),
                     yEnd: .value("Value", point.element))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.03)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", point.offset), y: .value("Value", point.element))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(values.count - 1, 1))
        .chartYScale(domain: domain)
        .shadow(color: color.opacity(0.55), radius: 2.5)
        .frame(minHeight: 20)
        .opacity(values.count > 1 ? 1 : 0)
        // The line is a picture of numbers: assistive technologies get where it went.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Trend"))
        .accessibilityValue(Text(verbatim: Self.summary(of: values)))
        .accessibilityHidden(values.count < 2)
    }

    /// "8 – 38": the lowest and the highest value of the series; empty without values.
    nonisolated static func summary(of values: [Double]) -> String {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return "" }
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        return low == high ? low.formatted(format) : "\(low.formatted(format)) – \(high.formatted(format))"
    }

    private var domain: ClosedRange<Double> {
        Self.domain(for: values, range: range, minimumSpan: minimumSpan)
    }

    /// The scale of a trend line: the given range, otherwise from the lowest to the highest
    /// value with a little room so the line is not cut at the edges. A flat series sits in the
    /// middle; no values give 0…1.
    /// `minimumSpan` widens a narrower scale around its middle.
    nonisolated static func domain(for values: [Double], range: ClosedRange<Double>? = nil,
                                   minimumSpan: Double = 0) -> ClosedRange<Double> {
        if let range { return range }
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return 0...1 }
        var lower = low - 1
        var upper = high + 1
        if high != low {
            let room = (high - low) * 0.12
            lower = low - room
            upper = high + room
        }
        let missing = minimumSpan - (upper - lower)
        if missing > 0 {
            lower -= missing / 2
            upper += missing / 2
        }
        return lower...upper
    }
}

// MARK: - Arc gauge

/// A level as a 270° arc in the level's colour (the accent below 60 %, orange from 60, red from
/// 85) with the numeral in its centre and a detail line in the opening — or under the arc when
/// the line is wider than the opening (a small gauge, a long text).
struct DSArcGauge: View {
    /// 0…100; nil when there is no reading yet.
    let percent: Double?
    var detail: String?
    var diameter: CGFloat = 128
    var lineWidth: CGFloat = 10

    private var clamped: Double { min(max(percent ?? 0, 0), 100) }

    var body: some View {
        if let detail, !Self.detailFitsOpening(detail, diameter: diameter, lineWidth: lineWidth) {
            VStack(spacing: 0) {
                gauge(detail: nil)
                detailText(detail)
                    .minimumScaleFactor(0.8)
            }
        } else {
            gauge(detail: detail)
        }
    }

    private func detailText(_ detail: String) -> some View {
        Text(verbatim: detail)
            .font(.system(size: Self.detailFontSize, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private static let detailFontSize: CGFloat = 11

    /// How much room a line of text has between the two ends of the arc.
    nonisolated static func openingWidth(diameter: CGFloat, lineWidth: CGFloat) -> CGFloat {
        // The ends sit at ±45° from straight down on the circle through the middle of the
        // stroke; their round caps reach half a line width further in. 4 pt of air each side.
        let chord = (diameter - lineWidth) * 0.7071
        return max(0, chord - lineWidth - 8)
    }

    /// Whether `detail` can stand in the opening without touching the arc.
    static func detailFitsOpening(_ detail: String, diameter: CGFloat, lineWidth: CGFloat) -> Bool {
        let font = NSFont.monospacedDigitSystemFont(ofSize: detailFontSize, weight: .medium)
        let width = (detail as NSString).size(withAttributes: [.font: font]).width
        return width.rounded(.up) <= openingWidth(diameter: diameter, lineWidth: lineWidth)
    }

    private func gauge(detail: String?) -> some View {
        let color = DS.Palette.level(percent: clamped)
        return ZStack {
            arc(to: 1)
                .stroke(color.opacity(0.2), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            arc(to: Self.sweep(percent: clamped))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .shadow(color: color.opacity(0.6), radius: 3)
                .opacity(percent == nil || clamped == 0 ? 0 : 1)
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
        .overlay {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: percent == nil ? "—" : "\(Int(clamped.rounded()))")
                    .font(.system(size: (diameter * 0.3).rounded(), weight: .bold).monospacedDigit())
                    .tracking(-1.2)
                    .contentTransition(.numericText())
                if percent != nil {
                    Text(verbatim: "%")
                        .font(.system(size: (diameter * 0.12).rounded(), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .offset(y: -diameter * 0.03)
        }
        // The opening of the arc is at the bottom: the box ends where the arc does.
        .frame(height: diameter * 0.94, alignment: .top)
        .overlay(alignment: .bottom) {
            if let detail {
                detailText(detail)
                    .fixedSize()
            }
        }
        .dsAnimated(DS.Motion.standard, value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(verbatim: percent == nil ? "—" : "\(Int(clamped.rounded()))%"))
    }

    /// The arc from its start (bottom-left) over `share` of its 270°.
    private func arc(to share: Double) -> some Shape {
        Circle()
            .trim(from: 0, to: 0.75 * share)
            .rotation(.degrees(135))
    }

    /// The share of the arc that is drawn for a percentage, 0…1.
    nonisolated static func sweep(percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(max(percent, 0), 100) / 100
    }
}

// MARK: - Segment bar

/// Proportions as one bar (succeeded / failed / pending).
struct DSSegmentBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let tint: Color
    }

    let segments: [Segment]
    var height: CGFloat = 6
    /// Room between the segments; with it every segment is a capsule of its own.
    var gap: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let shown = segments.filter { $0.value > 0 }
            let total = max(shown.reduce(0) { $0 + $1.value }, 1)
            let room = max(0, proxy.size.width - gap * CGFloat(max(shown.count - 1, 0)))
            HStack(spacing: gap) {
                ForEach(shown) { segment in
                    RoundedRectangle(cornerRadius: gap > 0 ? height / 2 : 0, style: .continuous)
                        .fill(segment.tint)
                        .frame(width: room * segment.value / total)
                }
            }
        }
        .frame(height: height)
        .background(Color.primary.opacity(gap > 0 ? 0 : 0.1))
        .clipShape(Capsule())
        .dsAnimated(DS.Motion.standard, value: segments.map(\.value))
        .accessibilityHidden(true)
    }
}

// MARK: - Connection statistics

extension ConnectionLog {
    var dsDidFail: Bool {
        let value = status.lowercased()
        return value == "failed" || value == "error"
    }

    var dsStartedAt: Date? {
        TimestampFormatter.date(from: connectedAt)
    }
}

/// What a set of connection logs adds up to. No data is "—", never 0.
struct DSLogStats: Equatable {
    let total: Int
    let failed: Int
    /// Mean of the durations that were recorded (> 0); nil when none was.
    let averageDurationMs: Int?

    init(_ logs: [ConnectionLog]) {
        total = logs.count
        failed = logs.filter(\.dsDidFail).count
        let durations = logs.compactMap(\.durationMs).filter { $0 > 0 }
        averageDurationMs = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count
    }

    var totalText: String {
        total == 0 ? "—" : total.formatted()
    }

    var successRateText: String {
        guard total > 0 else { return "—" }
        return (Double(total - failed) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
    }

    var averageDurationText: String {
        Self.durationText(ms: averageDurationMs)
    }

    /// "4 min 12 sec": the two largest units, the second left out when it is zero, a space
    /// between number and unit in every language (the system's abbreviated form sets Chinese
    /// without them).
    static func durationText(ms: Int?) -> String {
        durationPieces(ms: ms).map { piece in
            switch piece.unit {
            case .hours: return String(localized: "\(piece.value) hr")
            case .minutes: return String(localized: "\(piece.value) min")
            case .seconds: return String(localized: "\(piece.value) sec")
            }
        }.joined(separator: " ").ifEmpty("—")
    }

    enum DurationUnit: Equatable, Sendable {
        case hours, minutes, seconds
    }

    /// A duration as its two largest units; under a second counts as one second. Empty without one.
    nonisolated static func durationPieces(ms: Int?) -> [(value: Int, unit: DurationUnit)] {
        guard let ms, ms > 0 else { return [] }
        let seconds = max(ms / 1000, 1)
        let all: [(value: Int, unit: DurationUnit)] = [
            (value: seconds / 3600, unit: .hours),
            (value: seconds % 3600 / 60, unit: .minutes),
            (value: seconds % 60, unit: .seconds)
        ]
        let leading = Array(all.drop { $0.value == 0 }.prefix(2))
        return leading.enumerated().compactMap { index, piece in
            index > 0 && piece.value == 0 ? nil : piece
        }
    }
}

// MARK: - Activity chart

/// Connections per day as bars in the accent; today's bar is brighter and glows, a day without
/// connections is a flat line. Under it the first day and "Today". With `marksFailures` the
/// failed share of a day is the top of its bar in the danger colour — a status, said in words
/// by `DSActivityLegend`.
struct DSActivityChart: View {
    struct Day: Identifiable, Equatable {
        let date: Date
        let succeeded: Int
        let failed: Int
        var id: Date { date }
        var total: Int { succeeded + failed }
    }

    let days: [Day]
    var height: CGFloat = 52
    var marksFailures = false

    var body: some View {
        let heights = Self.barHeights(for: days, height: height)
        let failed = marksFailures ? Self.failedHeights(for: days, barHeights: heights) : []
        VStack(spacing: 5) {
            // Thirty days need narrower gaps than fourteen.
            HStack(alignment: .bottom, spacing: days.count > 20 ? 3 : 5) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    VStack(spacing: 2) {
                        if marksFailures, failed[index] > 0 {
                            Capsule()
                                .fill(DS.Palette.danger)
                                .frame(height: failed[index])
                        }
                        bar(day, isToday: index == days.count - 1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: heights[index])
                    .help(Text(verbatim: "\(day.date.formatted(.dateTime.month().day())) · \(day.total)"))
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack {
                if let first = days.first {
                    Text(verbatim: first.date.formatted(.dateTime.month().day()))
                }
                Spacer(minLength: 0)
                if !days.isEmpty {
                    Text("Today")
                }
            }
            .font(DS.Font.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .dsAnimated(DS.Motion.standard, value: days)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Connections per day"))
        .accessibilityValue(Text(verbatim: days.map { String($0.total) }.joined(separator: ", ")))
    }

    /// How much of each day's bar is the failed mark: its share of the bar, at least 3 pt when
    /// anything failed, and never the whole bar while something succeeded (2 pt of gap and
    /// 3 pt of bar stay). 0 for a day without failures.
    nonisolated static func failedHeights(for days: [Day], barHeights: [CGFloat]) -> [CGFloat] {
        zip(days, barHeights).map { day, height in
            guard day.failed > 0, day.total > 0 else { return 0 }
            if day.succeeded == 0 { return height }
            let share = (height * CGFloat(day.failed) / CGFloat(day.total)).rounded()
            return min(max(share, 3), max(height - 5, 3))
        }
    }

    @ViewBuilder
    private func bar(_ day: Day, isToday: Bool) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 2, bottomTrailingRadius: 2,
                                           topTrailingRadius: 4, style: .continuous)
        if day.total == 0 {
            Capsule().fill(DS.Palette.cardRaised)
        } else if marksFailures, day.succeeded == 0 {
            // Everything failed that day: the mark above is the whole bar.
            EmptyView()
        } else if isToday {
            shape
                .fill(LinearGradient(colors: [DS.Palette.accent.mix(with: .white, by: 0.3), DS.Palette.accent],
                                     startPoint: .top, endPoint: .bottom))
                .shadow(color: DS.Palette.accent.opacity(0.6), radius: 7)
        } else {
            shape.fill(LinearGradient(colors: [DS.Palette.accent, DS.Palette.accent.opacity(0.3)],
                                      startPoint: .top, endPoint: .bottom))
        }
    }

    /// How high each day's bar is drawn: 2 pt for a day without connections, otherwise from
    /// 6 pt up to the full height for the busiest day.
    nonisolated static func barHeights(for days: [Day], height: CGFloat) -> [CGFloat] {
        let peak = days.map(\.total).max() ?? 0
        return days.map { day in
            guard day.total > 0, peak > 0 else { return 2 }
            return (6 + (height - 6) * CGFloat(day.total) / CGFloat(peak)).rounded()
        }
    }

    /// The last `count` days up to today, one entry per day (empty days included).
    nonisolated static func days(from logs: [ConnectionLog], count: Int, now: Date = Date(),
                     calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        var buckets: [Date: (ok: Int, failed: Int)] = [:]
        for log in logs {
            guard let started = log.dsStartedAt else { continue }
            let day = calendar.startOfDay(for: started)
            var bucket = buckets[day] ?? (ok: 0, failed: 0)
            if log.dsDidFail {
                bucket.failed += 1
            } else {
                bucket.ok += 1
            }
            buckets[day] = bucket
        }
        return (0..<count).reversed().compactMap { offset -> Day? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let bucket = buckets[day] ?? (ok: 0, failed: 0)
            return Day(date: day, succeeded: bucket.ok, failed: bucket.failed)
        }
    }
}

/// What the two colours of a `DSActivityChart(marksFailures: true)` mean, in words.
struct DSActivityLegend: View {
    var body: some View {
        HStack(spacing: DS.Space.md) {
            entry("Succeeded", color: DS.Palette.accent)
            entry("Failed", color: DS.Palette.danger)
        }
        .font(DS.Font.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func entry(_ title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
        }
    }
}

private extension String {
    func ifEmpty(_ placeholder: String) -> String {
        isEmpty ? placeholder : self
    }
}
