import SwiftUI
import AppKit

/// House style on top of the macOS design language (Liquid Glass, macOS 26).
///
/// Two layers. Controls and navigation — sidebar, toolbar items, buttons, floating bars, sheets —
/// are Liquid Glass and come from the system or from the wrappers in `Glass.swift`. Content —
/// cards, rows, charts — is neutral and never glass. Colour is restrained: neutral surfaces, ONE
/// accent (the system accent colour) for the primary action, selection and data, and green /
/// orange / red for status only, always next to a word or a glyph. The one free colour is a
/// host's tile, which carries the colour of its distribution.
///
/// This file pins down the numbers every screen shares, so each makes the same choice.
enum DS {

    // MARK: Spacing (multiples of 4; 10 between cards, 16 between sections, 26 at content edges)

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        /// Between the cards of a grid.
        static let card: CGFloat = 10
        static let md: CGFloat = 12
        /// Between the sections of a detail; inside a card, left and right.
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        /// Left and right of a detail column.
        static let page: CGFloat = 26
        static let xxxl: CGFloat = 32
    }

    // MARK: Corner radii (continuous; concentric: window 26 → panel 18 → row 10)

    enum Radius {
        /// Key caps, the cells of small figures.
        static let sm: CGFloat = 6
        /// Fields, small boxes.
        static let md: CGFloat = 8
        /// A row of the sidebar.
        static let sidebarRow: CGFloat = 10
        /// A row of a master list; small code blocks.
        static let row: CGFloat = 12
        /// Same as `row` — the name pages written before the redesign use.
        static let lg: CGFloat = 12
        /// Cards and grouped boxes of the content layer.
        static let card: CGFloat = 16
        /// Floating glass panels that sit inside the window (the sidebar).
        static let panel: CGFloat = 18
        /// Sheets, alerts, the command palette.
        static let sheet: CGFloat = 22
    }

    // MARK: Heights

    enum Height {
        /// A two-line row of a master list.
        static let listRow: CGFloat = 46
        /// A row of a grouped card or a form.
        static let formRow: CGFloat = 40
        /// A compact row inside a card (recent connections).
        static let compactRow: CGFloat = 32
        /// A row of the sidebar.
        static let sidebarRow: CGFloat = 32
        /// The header of a list section.
        static let sectionHeader: CGFloat = 28
        /// Buttons.
        static let control: CGFloat = 32
        /// Small buttons, filter chips.
        static let smallControl: CGFloat = 26
        /// Chips and status pills.
        static let chip: CGFloat = 22
        /// A hop of a route diagram.
        static let hop: CGFloat = 34
    }

    // MARK: Type scale (13 body, 11–12 captions, 18 page title, 26 detail title and numbers)

    enum Font {
        /// 13 — rows, values, buttons.
        static let body = SwiftUI.Font.system(size: 13)
        /// 13 semibold — the name in a row.
        static let rowTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// 12 semibold — the label of a card, a section header.
        static let label = SwiftUI.Font.system(size: 12, weight: .semibold)
        /// 12 monospaced — addresses, commands, fingerprints in rows.
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
        /// 11 — footnotes, the second line of a row, trailing times.
        static let caption = SwiftUI.Font.system(size: 11)
        /// 11 medium — chips and pills.
        static let chip = SwiftUI.Font.system(size: 11, weight: .medium)
        /// 11 semibold — the header of a list section.
        static let sectionHeader = SwiftUI.Font.system(size: 11, weight: .semibold)
        /// 18 bold — the page title.
        static let pageTitle = SwiftUI.Font.system(size: 18, weight: .bold)
        /// 26 bold — the title of a detail.
        static let detailTitle = SwiftUI.Font.system(size: 26, weight: .bold)
        /// 26 bold, tabular digits — the number of a stat card.
        static let stat = SwiftUI.Font.system(size: 26, weight: .bold).monospacedDigit()
        /// 22 bold, tabular digits — numbers that sit side by side in one card.
        static let value = SwiftUI.Font.system(size: 22, weight: .bold).monospacedDigit()
        /// 38 bold, tabular digits — the numeral inside a gauge.
        static let gauge = SwiftUI.Font.system(size: 38, weight: .bold).monospacedDigit()
        /// 13 semibold — the unit after a number.
        static let unit = SwiftUI.Font.system(size: 13, weight: .semibold)
    }

    // MARK: Motion — the system's default spring unless a view needs something specific

    enum Motion {
        /// Hover / press feedback.
        static let quick = Animation.easeOut(duration: 0.15)
        /// Selection, insert / remove, layout changes.
        static let standard = Animation.snappy(duration: 0.3)
    }

    // MARK: Tone — the only colours data and status may take

    /// What a number, a meter or a pill may be coloured with. Data is `.accent`; the other four
    /// are states and always come with a word or a glyph.
    enum Tone: Equatable, Sendable {
        case accent, success, warning, danger, inactive

        var color: Color {
            switch self {
            case .accent: return Palette.accent
            case .success: return Palette.success
            case .warning: return Palette.warning
            case .danger: return Palette.danger
            case .inactive: return Palette.inactive
            }
        }

        /// A level is a status: the accent below 60 %, orange from 60 %, red from 85 %.
        static func level(percent: Double) -> Tone {
            if percent >= 85 { return .danger }
            if percent >= 60 { return .warning }
            return .accent
        }
    }

    // MARK: Colour — semantic system colours only

    enum Palette {
        /// The primary action, selection and data. Always the system accent, never a literal blue.
        static let accent = Color.accentColor
        /// Live / connected / done.
        static let success = Color(nsColor: .systemGreen)
        /// Needs attention: connecting, broadcast, a high level.
        static let warning = Color(nsColor: .systemOrange)
        /// Failed / destructive / a critical level.
        static let danger = Color(nsColor: .systemRed)
        /// Stopped, ended, not in use.
        static let inactive = Color(nsColor: .systemGray)
        /// Jump hosts and dynamic forwards, on pages written before the redesign. Not a colour
        /// of its own any more: the accent.
        static let jump = Color.accentColor
        /// Hairline between regions, between the rows of a card and between values in a card.
        static let separator = Color(nsColor: .separatorColor)
        /// A card of the content layer: white in light mode, a faint lift in dark mode.
        static let card = Color(nsColor: .dsDynamic(lightWhite: 1, lightAlpha: 1, darkWhite: 1, darkAlpha: 0.055))
        /// Raised on a card (route hops, the bed of a fingerprint image, the "on" segment).
        static let cardRaised = Color(nsColor: .dsDynamic(lightWhite: 0.1, lightAlpha: 0.08, darkWhite: 1, darkAlpha: 0.10))
        /// The edge of a card.
        static let hairline = Color(nsColor: .dsDynamic(lightWhite: 0.1, lightAlpha: 0.07, darkWhite: 1, darkAlpha: 0.08))
        /// The bed of chips and pills.
        static let chip = Color.primary.opacity(0.09)
        /// Terminal-coloured surfaces (code blocks): dark in both appearances.
        static let terminal = Color(nsColor: NSColor(white: 0.045, alpha: 1))

        private static let identityTints: [Color] = [
            .blue, .purple, .pink, .orange, .teal, .indigo, .mint, .cyan, .green, .brown
        ]

        /// Stable system colour for a name. Only for pages written before the redesign: keys,
        /// identities and tags are not colour-coded any more (use the accent).
        static func identityTint(for name: String) -> Color {
            let hash = name.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
            return identityTints[abs(hash) % identityTints.count]
        }

        /// Preset colours as stored (hex) → the system colour of the same name, so a chosen
        /// colour follows the appearance.
        private static let presetTints: [String: Color] = [
            "#3B82F6": .blue, "#10B981": .green, "#F59E0B": .orange, "#EF4444": .red,
            "#8B5CF6": .purple, "#EC4899": .pink, "#06B6D4": .cyan
        ]

        /// Colour for a stored hex value: the matching system colour for a preset, otherwise
        /// as stored.
        static func tint(hex: String) -> Color? {
            presetTints[hex.uppercased()] ?? Color(hex: hex)
        }

        /// Pages are not colour-coded: every category is the accent.
        static func category(_ item: SidebarItem) -> Color {
            accent
        }

        /// Usage in percent → the colour of its level (gauges, meters).
        static func level(percent: Double) -> Color {
            Tone.level(percent: percent).color
        }
    }
}

// MARK: - Layout, tile sizes

extension DS {
    /// The two page skeletons: master–detail and centred column.
    enum Layout {
        static let masterWidth: CGFloat = 320
        static let masterCompactWidth: CGFloat = 260
        /// Below this content width the master column takes its compact width.
        static let compactThreshold: CGFloat = 760
        static let columnMaxWidth: CGFloat = 760
        static let sidePanelWidth: CGFloat = 340
        /// Right-side live inspector width across Vault pages (380 pt).
        static let inspectorWidth: CGFloat = 380
    }

    /// The only sizes an icon tile / host avatar comes in.
    enum Tile {
        /// Session tabs, pane headers.
        static let tab: CGFloat = 16
        /// Sidebar rows, route hops, stacks.
        static let sidebar: CGFloat = 20
        /// Rows of a master list.
        static let row: CGFloat = 30
        /// Grid cards, picker cards.
        static let card: CGFloat = 38
        /// State cards, sheets.
        static let large: CGFloat = 48
        /// The header of a detail, empty states.
        static let header: CGFloat = 64
    }
}

private extension NSColor {
    /// A neutral that differs between the appearances — a white level and an alpha for each;
    /// no hue, so it takes the tone of what is behind it.
    static func dsDynamic(lightWhite: CGFloat, lightAlpha: CGFloat, darkWhite: CGFloat, darkAlpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(white: darkWhite, alpha: darkAlpha)
            }
            return NSColor(white: lightWhite, alpha: lightAlpha)
        }
    }
}

// MARK: Motion under Reduce Motion

/// `.animation(_:value:)` that stands still when Reduce Motion is on. Every animation the theme
/// plays goes through this, so the accessibility setting is honoured in one place.
private struct DSAnimatedValue<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// See `DSAnimatedValue` — the form the call sites use.
    func dsAnimated(_ animation: Animation?, value: some Equatable) -> some View {
        modifier(DSAnimatedValue(animation: animation, value: value))
    }
}
