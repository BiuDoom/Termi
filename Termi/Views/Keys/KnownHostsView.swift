import SwiftUI

/// Known Hosts management — the host keys trusted on first connection, grouped by key: the
/// addresses under one fingerprint image are the same machine.
struct KnownHostsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = KnownHostsViewModel()
    @State private var selectedId: Int64?

    private var savedHosts: [Host] { appViewModel.hostsPage.hosts }

    /// As listed: group after group.
    private var orderedEntries: [KnownHost] { viewModel.groups.flatMap(\.entries) }

    /// The selected entry if it is listed, else the first one.
    private var currentEntry: KnownHost? {
        let listed = orderedEntries
        return listed.first { $0.id == selectedId } ?? listed.first
    }

    /// Only once the saved hosts are known: before that — or after a read that failed and left
    /// none — every entry would look orphaned.
    private var orphans: [KnownHost] {
        let page = appViewModel.hostsPage
        guard page.hasLoaded, !(page.hosts.isEmpty && page.error != nil) else { return [] }
        return KnownHostsViewModel.orphans(viewModel.hosts, hosts: savedHosts)
    }

    /// How many addresses a search left; nothing otherwise (the list is the inventory).
    private var subtitle: Text {
        guard !viewModel.searchText.isEmpty, !viewModel.hosts.isEmpty else { return Text(verbatim: "") }
        return Text("\(viewModel.filteredHosts.count) matches")
    }

    var body: some View {
        content
            .searchable(text: $viewModel.searchText, prompt: "Search known hosts")
            .navigationSubtitle(subtitle)
            .toolbar {
                // In a menu, not a toolbar button: these remove many entries at once, and the
                // detail's own menu removes one.
                ToolbarItem {
                    Menu {
                        Button("Remove Entries Without a Saved Host…", role: .destructive) {
                            // The list the confirmation shows is made from a fresh read.
                            Task { await viewModel.askToDeleteOrphans() }
                        }
                        .disabled(orphans.isEmpty)
                        Button("Remove All Known Hosts…", role: .destructive) {
                            viewModel.showingDeleteAllConfirm = true
                        }
                        .disabled(viewModel.hosts.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .help("More")
                }
            }
            .task {
                await appViewModel.ensureHostsLoaded()
                await viewModel.loadHosts()
                takeReveal()
                #if DEBUG
                await applyDebugLaunchArguments()
                #endif
            }
            .onChange(of: DSReveal.shared.target) { _, _ in takeReveal() }
            // A host key trusted while the page is open (a first connection) shows up.
            .onReceive(NotificationCenter.default.publisher(for: .dsDataChanged)) { _ in
                Task { await viewModel.refresh() }
            }
            // The words of the command that asked: "Remove…" everywhere, never "Delete".
            .alert("Remove Known Host", isPresented: $viewModel.showingDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    if let host = viewModel.hostToDelete {
                        Task { await viewModel.deleteHost(host) }
                    }
                }
            } message: {
                if let host = viewModel.hostToDelete {
                    // The address as plain text: a number in a localized string gets a
                    // thousands separator ("127.0.0.1:2,223").
                    let address = "\(host.hostname):\(host.port)"
                    Text("Remove \"\(address)\" from known hosts? You'll need to re-verify next time.")
                }
            }
            .alert("Remove All Known Hosts", isPresented: $viewModel.showingDeleteAllConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Remove All", role: .destructive) {
                    Task { await viewModel.deleteAllHosts() }
                }
            } message: {
                Text("This will remove all trusted host fingerprints. You'll need to re-verify each host.")
            }
            .alert("Remove Entries Without a Saved Host", isPresented: $viewModel.showingDeleteOrphansConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    // Exactly the entries that were listed.
                    let listed = viewModel.orphansToDelete
                    Task { await viewModel.deleteHosts(listed) }
                }
            } message: {
                Text(verbatim: orphansMessage)
            }
    }

    /// Every entry that will be removed, by its full address, then what it costs.
    private var orphansMessage: String {
        let addresses = viewModel.orphansToDelete.map { "\($0.hostname):\($0.port)" }.joined(separator: "\n")
        return addresses + "\n\n" + String(localized: "No saved host uses these addresses. You'll need to re-verify them next time.")
    }

    /// Another page asked for one of the entries.
    private func takeReveal() {
        guard let id = appViewModel.takeReveal(for: .knownHosts).flatMap({ Int64($0) }) else { return }
        viewModel.searchText = ""
        selectedId = id
    }

    private func askToDelete(_ entry: KnownHost) {
        viewModel.hostToDelete = entry
        viewModel.showingDeleteConfirm = true
    }

    #if DEBUG
    /// `-debugVaultSelect 127.0.0.1:2223` selects that entry; `-debugHostKeyPrompt new|changed`
    /// puts the host key prompt on the window (see `AuthPromptPresenter.debugPresentHostKey`).
    private func applyDebugLaunchArguments() async {
        let defaults = AppProfile.arguments
        if let address = defaults.string(forKey: "debugVaultSelect"),
           let entry = viewModel.hosts.first(where: { "\($0.hostname):\($0.port)" == address }) {
            selectedId = entry.id
        }
        if let kind = defaults.string(forKey: "debugHostKeyPrompt") {
            let entries = orderedEntries
            await AuthPromptPresenter.shared.debugPresentHostKey(
                fingerprint: entries.first?.fingerprint,
                savedFingerprint: kind == "changed" ? entries.last?.fingerprint : nil
            )
        }
    }
    #endif

    // MARK: - Page

    @ViewBuilder
    private var content: some View {
        if !viewModel.hasLoaded {
            // Nothing until the first read is done: no empty state flashing by on the way in.
            DSDelayed { ProgressView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.hosts.isEmpty {
            Group {
                if let error = viewModel.error {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(verbatim: error)
                    } actions: {
                        Button("Retry") { Task { await viewModel.loadHosts() } }
                    }
                } else {
                    DSEmptyState("No Known Hosts",
                                 message: "Host fingerprints will be saved when you first connect.",
                                 page: .knownHosts)
                }
            }
            .dsStageBackground()
        } else {
            // One stage behind both columns, as in the design: the list is not a second surface.
            DSMasterDetail {
                master
            } detail: {
                detail
            }
            .dsStageBackground()
        }
    }

    // MARK: - Master

    @ViewBuilder
    private var master: some View {
        if viewModel.filteredHosts.isEmpty {
            ContentUnavailableView.search(text: viewModel.searchText)
        } else {
            DSMasterList(selection: Binding(get: { currentEntry?.id }, set: { selectedId = $0 }),
                         order: orderedEntries.compactMap(\.id)) {
                ForEach(Array(viewModel.groups.enumerated()), id: \.element.id) { index, group in
                    // A header over a single row would say one record twice ("1 address" above
                    // the address): only a key that several addresses presented gets one.
                    let hasHeader = KnownHostsViewModel.showsGroupHeader(for: group)
                    if hasHeader {
                        KnownHostGroupHeader(group: group)
                            .padding(.top, index > 0 ? 6 : 0)
                    }
                    ForEach(group.entries) { entry in
                        KnownHostListRow(entry: entry,
                                         savedHosts: KnownHostsViewModel.savedHosts(for: entry, in: savedHosts))
                            .dsListRow(isSelected: currentEntry?.id == entry.id, height: DS.Height.compactRow)
                            // The same gap between machines, with or without a header.
                            .padding(.top, !hasHeader && index > 0 ? 6 : 0)
                            .id(entry.id ?? 0)
                            .onTapGesture { selectedId = entry.id }
                            .accessibilityAction { selectedId = entry.id }
                            .contextMenu {
                                Button {
                                    VaultPasteboard.copy(entry.fingerprint)
                                } label: {
                                    Label("Copy Fingerprint", systemImage: "doc.on.doc")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    askToDelete(entry)
                                } label: {
                                    Label("Remove…", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .padding(.top, DS.Space.xs)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = currentEntry,
           let group = viewModel.groups.first(where: { $0.fingerprint == entry.fingerprint }) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    // A failed removal, said where the entries are.
                    if let error = viewModel.error {
                        VaultErrorBanner(message: error) { viewModel.error = nil }
                    }
                    KnownHostDetailView(entry: entry,
                                        group: group,
                                        savedHosts: savedHosts,
                                        onSelect: { selectedId = $0.id },
                                        onDelete: { askToDelete(entry) })
                }
                .padding(DS.Space.page)
            }
            .id(entry.id)
            .transition(.opacity)
            .animation(DS.Motion.standard, value: viewModel.error)
        } else {
            Color.clear
        }
    }
}

// MARK: - List

/// One host key: its image, type, the start of its fingerprint, how many addresses presented it.
private struct KnownHostGroupHeader: View {
    let group: KnownHostGroup

    private var keyType: String {
        KnownHostsViewModel.shortKeyType(group.entries.first?.keyType ?? "")
    }

    var body: some View {
        // Narrow master column: the image and the count stay, the text of the fingerprint goes.
        ViewThatFits(in: .horizontal) {
            layout(showsFingerprint: true)
            layout(showsFingerprint: false)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func layout(showsFingerprint: Bool) -> some View {
        HStack(spacing: 6) {
            DSRandomart(fingerprint: group.fingerprint, cell: 3)
            DSChip(verbatim: keyType, isMonospaced: true)
            if showsFingerprint {
                Text(verbatim: KnownHostsViewModel.shortFingerprint(group.fingerprint, length: 10))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: DS.Space.xs)
            Text("\(group.entries.count) addresses")
                .font(DS.Font.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .lineLimit(1)
    }
}

/// One address: the saved host it belongs to (a quiet dot when there is none), and the address.
private struct KnownHostListRow: View {
    let entry: KnownHost
    let savedHosts: [Host]

    var body: some View {
        HStack(spacing: 9) {
            if let host = savedHosts.first {
                DSHostAvatar(host, size: DS.Tile.sidebar)
                Text(verbatim: host.displayName)
                    .font(DS.Font.rowTitle)
                    .lineLimit(1)
                if savedHosts.count > 1 {
                    Text(verbatim: "+\(savedHosts.count - 1)")
                        .font(DS.Font.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(Text(verbatim: savedHosts.dropFirst().map(\.displayName).joined(separator: ", ")))
                }
            } else {
                KnownHostNoHostMark()
            }
            Spacer(minLength: DS.Space.xs)
            Text(verbatim: "\(entry.hostname):\(entry.port)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.hostname) port \(String(entry.port)), \(entry.keyType)")
    }
}

/// Where a host's tile would be: this address has no saved host.
private struct KnownHostNoHostMark: View {
    var body: some View {
        Circle()
            .fill(.tertiary)
            .frame(width: 6, height: 6)
            .frame(width: DS.Tile.sidebar, height: DS.Tile.sidebar)
            .accessibilityHidden(true)
    }
}

// MARK: - Detail

private struct KnownHostDetailView: View {
    let entry: KnownHost
    let group: KnownHostGroup
    let savedHosts: [Host]
    let onSelect: (KnownHost) -> Void
    let onDelete: () -> Void

    private var keyType: String { KnownHostsViewModel.shortKeyType(entry.keyType) }
    private var trustedAt: Date? { TimestampFormatter.date(from: entry.addedAt) }
    private var others: [KnownHost] { group.entries.filter { $0.id != entry.id } }
    private var ownHosts: [Host] { KnownHostsViewModel.savedHosts(for: entry, in: savedHosts) }

    private func trustedText(_ iso: String) -> String {
        guard let date = TimestampFormatter.date(from: iso) else { return iso }
        return String(localized: "Trusted \(date.formatted(.dateTime.month().day().hour().minute()))")
    }

    /// Under the title the date is complete, as the list showed it before: an entry can be
    /// years old, and the day alone would not say so.
    private var trustedInFull: String {
        guard let date = trustedAt else { return entry.addedAt }
        return String(localized: "Trusted \(DisplayDateFormatter.mediumDateShortTime.string(from: date))")
    }

    /// What the fingerprint is good for — and, when this address was not the first to present
    /// the key, when the key was first trusted (the subtitle has this address's own date).
    private var note: String {
        let confirmed = String(localized: "You confirmed it on the first connection. If the host key changes, the connection is refused.")
        guard let first = KnownHostsViewModel.earlierFirstTrust(of: entry, in: group),
              let date = TimestampFormatter.date(from: first) else { return confirmed }
        let when = DisplayDateFormatter.mediumDateShortTime.string(from: date)
        // A line of its own: the first sentence ends differently in each language.
        return confirmed + "\n" + String(localized: "First trusted \(when)")
    }

    var body: some View {
        // A key type and a date: words, not an address.
        DSDetailHeader(title: "\(entry.hostname):\(entry.port)", subtitle: "\(keyType) · \(trustedInFull)",
                       isSubtitleMonospaced: false) {
            DSCategoryTile(page: .knownHosts)
        } actions: {
            // Copying is done on the cards, next to what is copied.
            DSGlassIconMenu {
                Button(role: .destructive, action: onDelete) {
                    Label("Remove…", systemImage: "trash")
                }
            }
        }

        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Fingerprint")
            VaultHeroCard(fingerprint: entry.fingerprint) {
                VaultFingerprintColumn(fingerprint: entry.fingerprint, note: note)
            }
        }

        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // No count: it would be the number of rows right under it.
                DSSectionHeader("Other Addresses of This Machine")
                DSGroup {
                    ForEach(others) { other in
                        Button {
                            onSelect(other)
                        } label: {
                            addressRow(other)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        if !ownHosts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                DSSectionHeader("Saved Hosts")
                DSGroup {
                    ForEach(ownHosts, id: \.connectionKey) { host in
                        VaultHostLink(host: host)
                    }
                }
            }
        }

        if !entry.publicKey.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                DSSectionHeader("Public Key")
                VaultPublicKeyCard(publicKey: entry.publicKey)
            }
        }
    }

    /// Another address of the same machine: fixed columns, the trust date goes first when narrow.
    private func addressRow(_ other: KnownHost) -> some View {
        let host = KnownHostsViewModel.savedHosts(for: other, in: savedHosts).first
        return DSRow {
            if let host {
                DSHostAvatar(host, size: DS.Tile.sidebar)
            } else {
                KnownHostNoHostMark()
            }
            Text(verbatim: "\(other.hostname):\(other.port)")
                .font(DS.Font.mono)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
            if let host {
                Text(verbatim: host.displayName)
                    .fontWeight(.medium)
            } else {
                Text("No saved host")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                Text(verbatim: trustedText(other.addedAt))
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Color.clear
                    .frame(width: 0, height: 0)
            }
        }
        .contentShape(Rectangle())
    }
}
