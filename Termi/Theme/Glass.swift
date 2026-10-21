import SwiftUI

// Liquid Glass (macOS 26) — the ONLY file that names a glass API. Pages use these wrappers.
//
// Glass is the layer of controls and navigation that floats above content: buttons, floating
// bars, panels, filter chips. Never a content card, never glass on glass, tint only for the one
// primary action. The sidebar, the toolbar and sheets get their glass from the system.
//
// The same source builds with three toolchains. Everything that needs the macOS 26 SDK sits inside
// `#if compiler(>=6.2)` (Xcode 16.2 does not know the symbols) AND `if #available(macOS 26.0, *)`
// (the app still runs on macOS 15), with a material / bordered fallback in both other branches.

// MARK: - Shapes

/// The shapes a glass surface comes in.
enum DSGlassShape: Equatable, Sendable {
    case capsule
    case circle
    case rect(CGFloat)

    var shape: AnyShape {
        switch self {
        case .capsule: return AnyShape(Capsule(style: .continuous))
        case .circle: return AnyShape(Circle())
        case .rect(let radius): return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

// MARK: - Glass surface

private struct DSGlassModifier: ViewModifier {
    let shape: DSGlassShape
    let tint: Color?
    let isInteractive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency {
            opaqueFallback(content)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(Glass.regular.tint(tint).interactive(isInteractive), in: shape.shape)
            } else {
                fallback(content)
            }
            #else
            fallback(content)
            #endif
        }
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.shape.fill(.regularMaterial)
                    if let tint {
                        shape.shape.fill(tint.opacity(0.85))
                    }
                    shape.shape.stroke(contrast == .increased ? Color.primary.opacity(0.35) : DS.Palette.hairline)
                }
            }
    }

    private func opaqueFallback(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.shape.fill(Color(nsColor: .controlBackgroundColor))
                    if let tint {
                        shape.shape.fill(tint.opacity(0.92))
                    }
                    shape.shape.stroke(contrast == .increased ? Color.primary.opacity(0.45) : DS.Palette.separator)
                }
            }
    }
}

private struct DSFloatingModifier: ViewModifier {
    let shape: DSGlassShape
    let lift: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .modifier(DSGlassModifier(shape: shape, tint: nil, isInteractive: false))
            // What makes it float: a wide, soft shadow under the glass.
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.16), radius: lift, x: 0, y: lift * 0.7)
    }
}

extension View {
    /// A custom glass surface behind this view. `tint` only for prominence (the one primary
    /// action); `isInteractive` for surfaces that are pressed.
    func dsGlass(_ shape: DSGlassShape = .capsule, tint: Color? = nil, isInteractive: Bool = false) -> some View {
        modifier(DSGlassModifier(shape: shape, tint: tint, isInteractive: isInteractive))
    }

    /// A floating bar: the session tab bar, the terminal status bar, the SFTP transfer bar,
    /// selection action bars. The content brings its own padding.
    func dsFloatingBar(_ shape: DSGlassShape = .capsule) -> some View {
        modifier(DSFloatingModifier(shape: shape, lift: 20))
    }

    /// A floating panel: the command palette, the state cards over a terminal. Inside it
    /// everything is content (no glass on glass).
    func dsFloatingPanel(cornerRadius: CGFloat = DS.Radius.sheet) -> some View {
        modifier(DSFloatingModifier(shape: .rect(cornerRadius), lift: 36))
    }
}

/// Groups glass shapes that sit close together, so they are drawn (and blend) as one.
struct DSGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Buttons

/// The two emphases a button has. One `.prominent` per screen.
enum DSButtonKind: Equatable, Sendable {
    /// A secondary action: clear glass.
    case glass
    /// The one primary action: glass tinted with the accent.
    case prominent
}

enum DSButtonSize: Equatable, Sendable {
    /// 32 pt: detail headers, sheets.
    case regular
    /// 26 pt: inside cards and bars.
    case small

    var controlSize: ControlSize {
        switch self {
        case .regular: return .large
        case .small: return .regular
        }
    }
}

private struct DSButtonStyleModifier: ViewModifier {
    let kind: DSButtonKind
    let size: DSButtonSize

    func body(content: Content) -> some View {
        styled(content)
            .buttonBorderShape(.capsule)
            .controlSize(size.controlSize)
            .fontWeight(.semibold)
    }

    @ViewBuilder
    private func styled(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            switch kind {
            case .glass: content.buttonStyle(.glass)
            case .prominent:
                #if DEBUG
                // Screenshots are taken in a window that is not key, where the system draws the
                // prominent button without its tint: `-debugActive YES` paints it as in a key window.
                if AppProfile.arguments.bool(forKey: "debugActive") {
                    content.buttonStyle(DSDebugProminentStyle(size: size))
                } else {
                    content.buttonStyle(.glassProminent)
                }
                #else
                content.buttonStyle(.glassProminent)
                #endif
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        switch kind {
        case .glass: content.buttonStyle(.bordered)
        case .prominent: content.buttonStyle(.borderedProminent)
        }
    }
}

#if DEBUG
/// The prominent button as a key window shows it, for screenshots only (`-debugActive YES`).
private struct DSDebugProminentStyle: ButtonStyle {
    let size: DSButtonSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, size == .regular ? 14 : 10)
            .frame(height: size == .regular ? 30 : 24)
            .background(Color.accentColor, in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
    }
}
#endif

extension View {
    /// The style of a button: glass, or prominent glass for the one primary action.
    func dsButtonStyle(_ kind: DSButtonKind = .glass, size: DSButtonSize = .regular) -> some View {
        modifier(DSButtonStyleModifier(kind: kind, size: size))
    }
}

/// A round glass button with only a symbol ("more", "refresh", "copy"); always has a tooltip
/// and an accessibility label.
struct DSGlassIconButton: View {
    private let systemName: String
    private let help: LocalizedStringKey
    private let size: DSButtonSize
    private let role: ButtonRole?
    private let action: () -> Void

    init(_ systemName: String, help: LocalizedStringKey, size: DSButtonSize = .regular, role: ButtonRole? = nil,
         action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.size = size
        self.role = role
        self.action = action
    }

    var body: some View {
        let side = size == .regular ? DS.Height.control : DS.Height.smallControl
        // Not the system's glass button style: with a circular border shape that sizes itself
        // to the symbol, and an ellipsis is not as high as an arrow.
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: size == .regular ? 14 : 12, weight: .semibold))
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(DSGlassModifier(shape: .circle, tint: nil, isInteractive: true))
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// A round glass button that opens a menu ("more"): the same circle as `DSGlassIconButton`,
/// whatever the symbol's own height is.
struct DSGlassIconMenu<Items: View>: View {
    private let systemName: String
    private let help: LocalizedStringKey
    private let size: DSButtonSize
    private let items: Items

    init(_ systemName: String = "ellipsis", help: LocalizedStringKey = "More", size: DSButtonSize = .regular,
         @ViewBuilder items: () -> Items) {
        self.systemName = systemName
        self.help = help
        self.size = size
        self.items = items()
    }

    var body: some View {
        let side = size == .regular ? DS.Height.control : DS.Height.smallControl
        Menu {
            items
        } label: {
            // The frame is the label's: a menu styled as a button takes its height from the
            // symbol, and an ellipsis alone would give a flat capsule.
            Image(systemName: systemName)
                .font(.system(size: size == .regular ? 14 : 12, weight: .semibold))
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(DSGlassModifier(shape: .circle, tint: nil, isInteractive: true))
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

// MARK: - Filter chip

/// A filter under the toolbar: a glass capsule, inverted while it is the chosen one.
struct DSFilterChip: View {
    private let title: Text
    private let count: Int?
    private let isSelected: Bool
    private let action: () -> Void

    init(_ key: LocalizedStringKey, count: Int? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = Text(key)
        self.count = count
        self.isSelected = isSelected
        self.action = action
    }

    /// For data: a tag, a group name.
    init(verbatim: String, count: Int? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = Text(verbatim: verbatim)
        self.count = count
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                title
                if let count {
                    Text(verbatim: count.formatted())
                        .monospacedDigit()
                        .opacity(0.7)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: DS.Height.smallControl)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(DSFilterChipSurface(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DSFilterChipSurface: ViewModifier {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if isSelected {
            // Inverted: the label colour as the surface, the window colour as the text.
            content
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .background(Color.primary, in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.16), radius: 7, x: 0, y: 4)
        } else {
            content
                .foregroundStyle(.secondary)
                .modifier(DSGlassModifier(shape: .capsule, tint: nil, isInteractive: true))
        }
    }
}
