import AppKit
import SwiftTerm

/// Terminal appearance and behaviour settings (Settings → General → Terminal).
struct TerminalPreferences: Equatable, Sendable {
    /// PostScript font name; empty = the system monospaced font.
    var fontName = ""
    var fontSize: CGFloat = 14
    var colorTheme = "defaultDark"
    /// blinkBlock, steadyBlock, blinkUnderline, steadyUnderline, blinkBar, steadyBar
    var cursorStyle = "blinkBlock"
    var optionAsMeta = true
    var scrollbackLines = 10_000
    /// none, sound, visual
    var bell = "visual"
    var copyOnSelect = false
    /// Close the tab when the remote shell exits normally (`exit`).
    var closeOnExit = true
    var autoReconnect = true

    enum Key {
        static let fontName = "terminal_font_name"
        static let fontSize = "terminal_font_size"
        static let colorTheme = "terminal_color_theme"
        static let cursorStyle = "cursor_style"
        static let optionAsMeta = "terminal_option_as_meta"
        static let scrollback = "terminal_scrollback"
        static let bell = "terminal_bell"
        static let copyOnSelect = "terminal_copy_on_select"
        static let closeOnExit = "terminal_close_on_exit"
        static let autoReconnect = "auto_reconnect"
    }

    static let fontSizeRange: ClosedRange<CGFloat> = 9...32

    init() {}

    init(settings dict: [String: String]) {
        if let value = dict[Key.fontName] { fontName = value }
        if let value = dict[Key.fontSize].flatMap(Double.init) {
            fontSize = min(max(CGFloat(value), Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        }
        if let value = dict[Key.colorTheme] { colorTheme = value }
        if let value = dict[Key.cursorStyle] { cursorStyle = value }
        if let value = dict[Key.optionAsMeta] { optionAsMeta = value != "false" }
        if let value = dict[Key.scrollback].flatMap(Int.init), value >= 100 { scrollbackLines = value }
        if let value = dict[Key.bell] { bell = value }
        if let value = dict[Key.copyOnSelect] { copyOnSelect = value == "true" }
        if let value = dict[Key.closeOnExit] { closeOnExit = value != "false" }
        if let value = dict[Key.autoReconnect] { autoReconnect = value != "false" }
    }

    static func load() async -> TerminalPreferences {
        guard let reader = try? await DatabaseManager.shared.reader,
              let settings = try? await reader.read({ db in try AppSetting.fetchAll(db) }) else {
            return TerminalPreferences()
        }
        return TerminalPreferences(settings: Dictionary(settings.map { ($0.key, $0.value) },
                                                        uniquingKeysWith: { _, last in last }))
    }

    var font: NSFont {
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: fontSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    var swiftTermCursorStyle: CursorStyle {
        switch cursorStyle {
        case "steadyBlock": .steadyBlock
        case "blinkUnderline": .blinkUnderline
        case "steadyUnderline": .steadyUnderline
        case "blinkBar": .blinkBar
        case "steadyBar": .steadyBar
        default: .blinkBlock
        }
    }

    var bellStyle: BellStyle {
        switch bell {
        case "none": .none
        case "sound": .sound
        default: .visual
        }
    }

    struct FontChoice: Hashable, Identifiable {
        /// PostScript name.
        let name: String
        let displayName: String
        var id: String { name }
    }

    /// Fixed-pitch fonts installed on this Mac, for the font picker.
    @MainActor
    static func availableMonospacedFonts() -> [FontChoice] {
        let manager = NSFontManager.shared
        let families = manager.availableFontFamilies.filter { family in
            guard let members = manager.availableMembers(ofFontFamily: family),
                  let first = members.first, let postScriptName = first[0] as? String,
                  let font = NSFont(name: postScriptName, size: 12) else { return false }
            return font.isFixedPitch || family.localizedCaseInsensitiveContains("mono")
        }
        return families.compactMap { family in
            guard let members = manager.availableMembers(ofFontFamily: family) else { return nil }
            // Prefer the "Regular" member.
            let regular = members.first { ($0[1] as? String)?.lowercased() == "regular" } ?? members.first
            guard let postScriptName = regular?[0] as? String else { return nil }
            return FontChoice(name: postScriptName, displayName: family)
        }
    }
}

extension Notification.Name {
    /// Posted by Settings whenever a terminal preference changes; windows reload them.
    static let terminalPreferencesChanged = Notification.Name("dev.termi.Termi.terminalPreferencesChanged")
}
