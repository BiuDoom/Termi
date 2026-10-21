import SwiftUI

/// Host row shared by the tools pages (batch command, monitoring, Docker):
/// icon tile, name, address.
struct DevOpsHostRowView: View {
    let host: Host

    var body: some View {
        HStack(spacing: DS.Space.md) {
            DSIconTile(content: host.tileContent, tint: host.tint, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: Self.title(for: host))
                    .lineLimit(1)
                Text(verbatim: host.addressDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .accessibilityElement(children: .combine)
    }

    /// The host's name, or its address when it has none.
    static func title(for host: Host) -> String {
        host.displayName
    }
}

// MARK: - Detail line

/// One line of a row: a short text that matters (name, state) followed by a longer detail
/// (address, image, ports). The detail takes the room that is left and truncates; when not even
/// `minDetailWidth` is left it is dropped instead of squeezing the first text.
struct DevOpsDetailLine<Primary: View, Detail: View>: View {
    private let minDetailWidth: CGFloat
    private let primary: Primary
    private let detail: Detail

    init(minDetailWidth: CGFloat = 64, @ViewBuilder primary: () -> Primary, @ViewBuilder detail: () -> Detail) {
        self.minDetailWidth = minDetailWidth
        self.primary = primary()
        self.detail = detail()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                primary
                    .layoutPriority(1)
                detail
                    .frame(minWidth: minDetailWidth, idealWidth: minDetailWidth, maxWidth: .infinity, alignment: .leading)
            }
            primary
        }
    }
}

// MARK: - Host list (leading column)

/// Leading column of a master–detail tools page: the hosts, one of them selected.
struct DevOpsHostList: View {
    static let columnWidth: CGFloat = 240

    let hosts: [Host]
    let selectedHost: Host?
    let onSelect: (Host) -> Void

    var body: some View {
        List(hosts, id: \.connectionKey, selection: selection) { host in
            DevOpsHostRowView(host: host)
        }
        .listStyle(.inset)
        .frame(width: Self.columnWidth)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { selectedHost?.connectionKey },
            set: { key in
                // A click below the last row clears the list's selection; the page keeps its host.
                guard let key, key != selectedHost?.connectionKey,
                      let host = hosts.first(where: { $0.connectionKey == key }) else { return }
                onSelect(host)
            }
        )
    }
}

// MARK: - Selected host after a reload

/// What became of the host a tools page has selected, once the hosts are read again. The page
/// models live as long as the window, so the host may have been edited or deleted on the Hosts
/// page since it was picked.
enum DevOpsHostSelection: Equatable {
    /// Deleted: there is nothing to show any more.
    case gone
    /// Still the record that was picked: what the page shows belongs to it.
    case same(Host)
    /// Saved again since (address, user, credentials, jump host…): what the page shows may
    /// come from another machine or account.
    case changed(Host)

    init(of selected: Host, in hosts: [Host]) {
        guard let current = hosts.first(where: { $0.connectionKey == selected.connectionKey }) else {
            self = .gone
            return
        }
        self = current.isSameSave(as: selected) ? .same(current) : .changed(current)
    }
}

extension Host {
    /// True when `other` is this host as it was last saved. Not `==`: connecting stamps
    /// `lastConnectedAt` and reordering changes `sortOrder`, neither changes where or how the
    /// host connects. Every save stamps `updatedAt` — also one that only replaces the password,
    /// which is kept in the vault and not in the record.
    func isSameSave(as other: Host) -> Bool {
        var copy = self
        copy.lastConnectedAt = other.lastConnectedAt
        copy.sortOrder = other.sortOrder
        return copy == other
    }
}

// MARK: - No hosts

/// Fills a tools page while there is no host to work on (or the hosts could not be read).
struct DevOpsNoHostsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    var error: String?
    var onRetry: (() -> Void)?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: error)
                } actions: {
                    if let onRetry { Button("Retry", action: onRetry) }
                }
            } else {
                ContentUnavailableView {
                    Label("No Hosts", systemImage: "server.rack")
                } description: {
                    Text("No hosts configured. Add hosts in the Hosts section first.")
                } actions: {
                    Button("Show Hosts") { appViewModel.selectedSidebar = .terminal }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
