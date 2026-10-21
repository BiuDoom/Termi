import SwiftUI

/// The one skeleton every vault page shares (hosts, keys, port forwarding, snippets, known
/// hosts): a toolbar row — the split create button and page shortcuts on the left, search,
/// filters and view controls on the right — above a content area for the card grid, with the
/// inspector panel sitting at the trailing edge while it is open. The grid reflows to make room
/// for the panel; the panel itself is a `DSInspectorPanel`.
struct DSVaultPage<Leading: View, Trailing: View, Content: View, Inspector: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    @ViewBuilder var inspector: () -> Inspector

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.md) {
                leading()
                Spacer(minLength: DS.Space.xl)
                trailing()
            }
            .padding(.leading, DS.Space.page)
            .padding(.trailing, DS.Space.lg)
            .frame(height: 44)
            Divider()
            HStack(spacing: 0) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                inspector()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The vault page's card grid: as many whole columns of cards as the room allows — three in a
/// wide window, two once the inspector takes its share or the window narrows, one at the
/// smallest. The rule lives in `DSItemGridColumns` so pages and tests agree on it.

/// The column rule of `DSItemGrid`, outside the generic view so pages and tests can call it.
enum DSItemGridColumns {
    /// Below twice this width a second column would squeeze every card; one column instead.
    static let minimumCardWidth: CGFloat = 260
    /// Three columns want at least this much room; less means two.
    static let threeColumnWidth: CGFloat = 980

    /// The number of columns for a content width: three from 980 pt, else two from twice the
    /// card minimum, else one — and never more than two while the inspector is open.
    static func count(width: CGFloat, inspectorVisible: Bool) -> Int {
        let base = width >= threeColumnWidth ? 3 : width >= minimumCardWidth * 2 ? 2 : 1
        return inspectorVisible ? min(2, base) : base
    }
}
struct DSItemGrid<Card: View>: View {
    /// Whether the inspector panel is open next to the grid (the caller knows; the grid only
    /// reflows).
    var inspectorVisible = false
    @ViewBuilder var card: () -> Card

    var body: some View {
        GeometryReader { space in
            let columns = DSItemGridColumns.count(width: space.size.width, inspectorVisible: inspectorVisible)
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.card), count: columns),
                    spacing: DS.Space.card) {
                        card()
                    }
                    .padding(.horizontal, DS.Space.page)
                    .padding(.vertical, DS.Space.lg)
            }
        }
    }
}

/// The toolbar's split create button: the button itself performs the page's most frequent
/// creation, the chevron opens the rest of the ways (a group, an import from ~/.ssh/config, a
/// generated key — whatever the page offers).
struct DSCreateButton<Actions: View>: View {
    let title: LocalizedStringKey
    var systemImage = "plus"
    let action: () -> Void
    @ViewBuilder var menu: () -> Actions

    var body: some View {
        HStack(spacing: 1) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .font(DS.Font.body.weight(.semibold))
                    .padding(.horizontal, DS.Space.md)
                    .frame(height: DS.Height.control)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CreateActionStyle())
            Divider()
                .frame(height: DS.Height.smallControl)
            Menu {
                menu()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, DS.Space.sm)
                    .frame(height: DS.Height.control)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(CreateActionStyle())
            .accessibilityLabel(Text("More ways to create"))
        }
        .clipShape(Capsule())
    }

    /// The accent fill both halves share: this is the page's one primary action.
    private struct CreateActionStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(.white)
                .opacity(isEnabled ? 1 : 0.45)
                .background(DS.Palette.accent.opacity(configuration.isPressed ? 0.75 : 1))
        }
    }
}
