import SwiftUI

/// What can be done with a host from its row, its card and its record.
struct HostActions {
    let onConnect: () -> Void
    var onOpenSFTP: (() -> Void)? = nil
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    /// Opens the record panel for the host — or closes it when it shows this host
    /// (`showsDetails`). Nil inside the panel itself.
    var onToggleDetails: (() -> Void)? = nil
    var showsDetails = false
}

/// The menu of a host: the context menu of its row and card, and the "more" menu of its record
/// (there without the actions that are buttons next to it).
struct HostMenuItems: View {
    let host: Host
    let actions: HostActions
    var includesPrimary = true

    var body: some View {
        if includesPrimary {
            Button { actions.onConnect() } label: {
                Label("Connect", systemImage: "bolt.fill")
            }
            if let onOpenSFTP = actions.onOpenSFTP {
                Button { onOpenSFTP() } label: {
                    Label("Open SFTP", systemImage: "folder")
                }
            }
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(host.addressDescription, forType: .string)
        } label: {
            Label("Copy Address", systemImage: "doc.on.clipboard")
        }
        if let onToggleDetails = actions.onToggleDetails {
            Button { onToggleDetails() } label: {
                if actions.showsDetails {
                    Label("Hide Details", systemImage: "info.circle")
                } else {
                    Label("Show Details", systemImage: "info.circle")
                }
            }
        }
        Divider()
        if includesPrimary {
            Button { actions.onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
        Button { actions.onDuplicate() } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) { actions.onDelete() } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - The way to the record

/// The one button a card or row carries: it opens the host's record in the panel (and closes
/// the panel that shows it). There while the pointer is on the card and while the card is the
/// selected one; its room is always kept, so the text beside it never moves or gets covered.
private struct HostDetailsButton: View {
    let isOpen: Bool
    let isVisible: Bool
    /// On the accent pill of a selected list row.
    var isOnAccent = false
    let action: () -> Void

    static let side: CGFloat = 28

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: Self.side, height: Self.side)
                .background(isOnAccent ? AnyShapeStyle(Color.white.opacity(0.18)) : AnyShapeStyle(DS.Palette.chip),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide Inspector (⌘I)" : "Inspect & Edit Host (⌘I)")
        .accessibilityLabel(isOpen ? Text("Hide Details") : Text("Show Details"))
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .animation(DS.Motion.quick, value: isVisible)
    }

    private var tint: AnyShapeStyle {
        if isOnAccent { return AnyShapeStyle(Color.white) }
        return isOpen ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(.secondary)
    }
}

// MARK: - List row

/// A host in the list layout: tile with its live state, name, address, and at the trailing edge
/// its sessions or when it was last connected to, then the button to its record (hovered or
/// selected). Click selects, double-click connects.
struct HostListRow: View {
    let host: Host
    var status: DSHostAvatar.Status = .none
    var sessionCount = 0
    var showsJump = false
    var isSelected = false
    /// Debug screenshots: drawn as with the pointer on it.
    var isHoverForced = false
    var onSelect: (() -> Void)? = nil
    let actions: HostActions

    var body: some View {
        DSHostRow(host, status: status, showsJump: showsJump) {
            HostListRowTrailing(host: host, sessionCount: sessionCount, isHoverForced: isHoverForced, actions: actions)
        }
        .dsListRow(isSelected: isSelected)
        .dsHoverTracking()
        .onTapGesture(count: 2) { actions.onConnect() }
        .simultaneousGesture(TapGesture(count: 1).onEnded { _ in onSelect?() })
        .contextMenu { HostMenuItems(host: host, actions: actions) }
        .accessibilityValue(sessionCount > 0 ? Text("\(sessionCount) sessions") : Text(verbatim: ""))
        .accessibilityHint("Double-click to connect, single-click to select")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { onSelect?() }
        .accessibilityAction(named: "Connect") { actions.onConnect() }
        .accessibilityAction(named: "Edit") { actions.onEdit() }
        // Says what it does now, like the button and the menu item.
        .accessibilityAction(named: actions.showsDetails ? "Hide Details" : "Show Details") { actions.onToggleDetails?() }
    }
}

private struct HostListRowTrailing: View {
    let host: Host
    let sessionCount: Int
    let isHoverForced: Bool
    let actions: HostActions
    @Environment(\.dsIsHovered) private var isHovered
    @Environment(\.dsIsSelected) private var isSelected

    var body: some View {
        HStack(spacing: DS.Space.md) {
            state
            if let onToggleDetails = actions.onToggleDetails {
                HostDetailsButton(isOpen: actions.showsDetails,
                                  isVisible: HostsViewModel.showsDetailsButton(isHovered: isHovered || isHoverForced,
                                                                               isSelected: isSelected),
                                  isOnAccent: isSelected, action: onToggleDetails)
                    // The row is one element (its children combined) with "Show Details" as a
                    // named action: the button's label must not be read into the row's.
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var state: some View {
        if sessionCount > 0 {
            if isSelected {
                // On the accent pill the words alone: a neutral pill would cut a hole into it.
                Text("\(sessionCount) sessions")
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                DSStatusPill(verbatim: String(localized: "\(sessionCount) sessions"))
            }
        } else if host.lastConnectedDate != nil {
            // A host that was never connected to says nothing here.
            DSRelativeTime(host.lastConnectedDate)
        }
    }
}

// MARK: - Card

/// A single host card in the hosts grid: tile with its live state, name, address, and a third
/// line with how it signs in, its sessions or when it was last connected to, and its tags.
/// Click selects, double-click connects; hovered or selected it shows one button, the way to
/// its record. Everything else a host can do is in the context menu and in that record.
struct HostCardView: View {
    let host: Host
    var tags: [Tag] = []
    var status: DSHostAvatar.Status = .none
    var sessionCount = 0
    var showsJump = false
    var isSelected: Bool = false
    /// Debug screenshots: drawn as with the pointer on it.
    var isHoverForced = false
    var onSelect: (() -> Void)? = nil
    let actions: HostActions

    static let height: CGFloat = 66

    var body: some View {
        HStack(spacing: DS.Space.md) {
            DSHostAvatar(host, size: 40, status: status)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(verbatim: host.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if showsJump {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .help("Connects through a jump host")
                    }
                }
                secondLine
            }
            // The text gives way to the button's room, not the other way round.
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            if let onToggleDetails = actions.onToggleDetails {
                HostCardDetailsSlot(isOpen: actions.showsDetails, isSelected: isSelected, isHoverForced: isHoverForced,
                                    action: onToggleDetails)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, DS.Space.md)
        .frame(height: Self.height)
        .overlay {
            if isHoverForced {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(.primary.opacity(0.04))
                    .allowsHitTesting(false)
            }
        }
        .dsCard(isSelected: isSelected, isInteractive: true)
        .onTapGesture(count: 2) { actions.onConnect() }
        .simultaneousGesture(TapGesture(count: 1).onEnded { _ in onSelect?() })
        .contextMenu { HostMenuItems(host: host, actions: actions) }
        // One element: the button inside is its named action, not a second unlabeled control.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(host.displayName), \(host.username) at \(host.hostname)")
        .accessibilityValue(sessionCount > 0 ? Text("Connected") : Text(verbatim: ""))
        .accessibilityHint("Double-click to connect, single-click to select")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { actions.onConnect() }
        .accessibilityAction(named: "Edit") { actions.onEdit() }
        // Says what it does now, like the button and the menu item.
        .accessibilityAction(named: actions.showsDetails ? "Hide Details" : "Show Details") { actions.onToggleDetails?() }
    }

    /// Second line: `user@host` (monospaced secondary) + optional compact tag chip when space permits.
    private var secondLine: some View {
        ViewThatFits(in: .horizontal) {
            secondLine(tagCount: min(tags.count, 1))
            if !tags.isEmpty {
                secondLine(tagCount: 0)
            }
        }
        .frame(height: 18)
    }

    /// How many tags the card tries to show by name, most first; the rest is "+N".
    nonisolated static func shownTagCounts(of count: Int) -> [Int] {
        Array(Set([min(count, 2), min(count, 1), 0])).sorted(by: >)
    }

    private func secondLine(tagCount shown: Int) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: host.addressDescription)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !tags.isEmpty {
                ForEach(tags.prefix(shown)) { tag in
                    DSChip(verbatim: tag.name)
                }
                if tags.count > shown {
                    Text(verbatim: "+\(tags.count - shown)")
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }
}

/// Reads the card's hover (published by `dsCard(isInteractive:)` around it).
private struct HostCardDetailsSlot: View {
    let isOpen: Bool
    let isSelected: Bool
    let isHoverForced: Bool
    let action: () -> Void
    @Environment(\.dsIsHovered) private var isHovered

    var body: some View {
        HostDetailsButton(isOpen: isOpen,
                          isVisible: HostsViewModel.showsDetailsButton(isHovered: isHovered || isHoverForced,
                                                                       isSelected: isSelected),
                          action: action)
    }
}

// MARK: - Color hex extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6,
              let rgb = UInt64(hexSanitized, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
