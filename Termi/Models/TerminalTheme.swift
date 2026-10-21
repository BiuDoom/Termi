import SwiftUI

/// A terminal color theme defining background, foreground, cursor, selection, and 16 ANSI colors.
struct TerminalTheme: Identifiable, Equatable {
    let id: String          // Unique key (e.g. "dracula")
    let name: String        // Display name
    let isDark: Bool        // Whether this is a dark-background theme

    // Core colors (hex strings)
    let background: String
    let foreground: String
    let cursor: String
    let selection: String

    // ANSI 16-color palette (indices 0–15)
    let ansiColors: [String]   // Must contain exactly 16 hex strings

    /// Convert a hex string (#RRGGBB) to NSColor
    static func nsColor(hex: String) -> NSColor {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let val = UInt64(h, radix: 16) else {
            return .textColor
        }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    var nsBackground: NSColor { Self.nsColor(hex: background) }
    var nsForeground: NSColor { Self.nsColor(hex: foreground) }
    var nsCursor: NSColor { Self.nsColor(hex: cursor) }
    var nsSelection: NSColor { Self.nsColor(hex: selection) }
}

// MARK: - Built-in Themes

extension TerminalTheme {

    /// All built-in themes
    static let builtIn: [TerminalTheme] = [
        .defaultDark, .defaultLight, .dracula, .solarizedDark, .solarizedLight,
        .nord, .monokai, .oneDark, .tokyoNight, .gruvboxDark, .catppuccinMocha, .rosePine,
    ]

    /// Look up a theme by id, falling back to Default Dark
    static func find(_ id: String) -> TerminalTheme {
        builtIn.first(where: { $0.id == id }) ?? .defaultDark
    }

    // MARK: Default Dark

    static let defaultDark = TerminalTheme(
        id: "defaultDark",
        name: "Default Dark",
        isDark: true,
        background: "#1A1A1E",
        foreground: "#E6E6E6",
        cursor: "#E6E6E6",
        selection: "#3A3A4A",
        ansiColors: [
            "#1A1A1E", "#FF5F56", "#5AF78E", "#F3F99D",
            "#57C7FF", "#FF6AC1", "#9AEDFE", "#F1F1F0",
            "#686868", "#FF5F56", "#5AF78E", "#F3F99D",
            "#57C7FF", "#FF6AC1", "#9AEDFE", "#FFFFFF",
        ]
    )

    // MARK: Default Light

    static let defaultLight = TerminalTheme(
        id: "defaultLight",
        name: "Default Light",
        isDark: false,
        background: "#FAFAFA",
        foreground: "#1A1A1E",
        cursor: "#1A1A1E",
        selection: "#C8D8E8",
        ansiColors: [
            "#000000", "#C91B00", "#00C200", "#C7C400",
            "#0225C7", "#CA30C7", "#00C5C7", "#C7C7C7",
            "#686868", "#FF6E67", "#5FFA68", "#FFFC67",
            "#6871FF", "#FF77FF", "#60FDFF", "#FFFFFF",
        ]
    )

    // MARK: Dracula

    static let dracula = TerminalTheme(
        id: "dracula",
        name: "Dracula",
        isDark: true,
        background: "#282A36",
        foreground: "#F8F8F2",
        cursor: "#F8F8F2",
        selection: "#44475A",
        ansiColors: [
            "#21222C", "#FF5555", "#50FA7B", "#F1FA8C",
            "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
            "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5",
            "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF",
        ]
    )

    // MARK: Solarized Dark

    static let solarizedDark = TerminalTheme(
        id: "solarizedDark",
        name: "Solarized Dark",
        isDark: true,
        background: "#002B36",
        foreground: "#839496",
        cursor: "#839496",
        selection: "#073642",
        ansiColors: [
            "#073642", "#DC322F", "#859900", "#B58900",
            "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83",
            "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
        ]
    )

    // MARK: Solarized Light

    static let solarizedLight = TerminalTheme(
        id: "solarizedLight",
        name: "Solarized Light",
        isDark: false,
        background: "#FDF6E3",
        foreground: "#657B83",
        cursor: "#657B83",
        selection: "#EEE8D5",
        ansiColors: [
            "#073642", "#DC322F", "#859900", "#B58900",
            "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83",
            "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
        ]
    )

    // MARK: Nord

    static let nord = TerminalTheme(
        id: "nord",
        name: "Nord",
        isDark: true,
        background: "#2E3440",
        foreground: "#D8DEE9",
        cursor: "#D8DEE9",
        selection: "#434C5E",
        ansiColors: [
            "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
            "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
            "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
            "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4",
        ]
    )

    // MARK: Monokai

    static let monokai = TerminalTheme(
        id: "monokai",
        name: "Monokai",
        isDark: true,
        background: "#272822",
        foreground: "#F8F8F2",
        cursor: "#F8F8F0",
        selection: "#49483E",
        ansiColors: [
            "#272822", "#F92672", "#A6E22E", "#F4BF75",
            "#66D9EF", "#AE81FF", "#A1EFE4", "#F8F8F2",
            "#75715E", "#F92672", "#A6E22E", "#F4BF75",
            "#66D9EF", "#AE81FF", "#A1EFE4", "#F9F8F5",
        ]
    )

    // MARK: One Dark

    static let oneDark = TerminalTheme(
        id: "oneDark",
        name: "One Dark",
        isDark: true,
        background: "#282C34",
        foreground: "#ABB2BF",
        cursor: "#528BFF",
        selection: "#3E4451",
        ansiColors: [
            "#282C34", "#E06C75", "#98C379", "#E5C07B",
            "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
            "#545862", "#E06C75", "#98C379", "#E5C07B",
            "#61AFEF", "#C678DD", "#56B6C2", "#C8CCD4",
        ]
    )

    // MARK: Tokyo Night

    static let tokyoNight = TerminalTheme(
        id: "tokyoNight",
        name: "Tokyo Night",
        isDark: true,
        background: "#1A1B26",
        foreground: "#A9B1D6",
        cursor: "#C0CAF5",
        selection: "#33467C",
        ansiColors: [
            "#15161E", "#F7768E", "#9ECE6A", "#E0AF68",
            "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
            "#414868", "#F7768E", "#9ECE6A", "#E0AF68",
            "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5",
        ]
    )

    // MARK: Gruvbox Dark

    static let gruvboxDark = TerminalTheme(
        id: "gruvboxDark",
        name: "Gruvbox Dark",
        isDark: true,
        background: "#282828",
        foreground: "#EBDBB2",
        cursor: "#EBDBB2",
        selection: "#3C3836",
        ansiColors: [
            "#282828", "#CC241D", "#98971A", "#D79921",
            "#458588", "#B16286", "#689D6A", "#A89984",
            "#928374", "#FB4934", "#B8BB26", "#FABD2F",
            "#83A598", "#D3869B", "#8EC07C", "#EBDBB2",
        ]
    )

    // MARK: Catppuccin Mocha

    static let catppuccinMocha = TerminalTheme(
        id: "catppuccinMocha",
        name: "Catppuccin Mocha",
        isDark: true,
        background: "#1E1E2E",
        foreground: "#CDD6F4",
        cursor: "#F5E0DC",
        selection: "#45475A",
        ansiColors: [
            "#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF",
            "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
            "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF",
            "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8",
        ]
    )

    // MARK: Rosé Pine

    static let rosePine = TerminalTheme(
        id: "rosePine",
        name: "Rosé Pine",
        isDark: true,
        background: "#191724",
        foreground: "#E0DEF4",
        cursor: "#524F67",
        selection: "#2A283E",
        ansiColors: [
            "#26233A", "#EB6F92", "#31748F", "#F6C177",
            "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4",
            "#6E6A86", "#EB6F92", "#31748F", "#F6C177",
            "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4",
        ]
    )
}
