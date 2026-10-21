import SwiftUI

/// Keychain page — the SSH keys stored in the encrypted vault, each one known by its
/// fingerprint image: generate, import, copy the public key, install it on hosts, delete.
struct KeyManagementView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = KeysViewModel()
    @State private var keyToInstall: SSHKey?
    @State private var selectedKeyId: Int64?

    private var hosts: [Host] { appViewModel.hostsPage.hosts }
    private var groups: [HostGroup] { appViewModel.hostsPage.allGroups }

    /// The selected key if it is listed, else the first one: the detail is never empty while
    /// there is a key to show.
    private var currentKey: SSHKey? {
        let listed = viewModel.filteredKeys
        return listed.first { $0.id == selectedKeyId } ?? orderedKeys.first
    }

    private func users(of key: SSHKey) -> [Host] {
        guard let id = key.id else { return [] }
        return VaultUsage.hosts(usingKey: id, hosts: hosts, identities: viewModel.identities, groups: groups)
    }

    private func isUsed(_ key: SSHKey) -> Bool {
        guard let id = key.id else { return false }
        return !users(of: key).isEmpty
            || !VaultUsage.identities(usingKey: id, identities: viewModel.identities).isEmpty
    }

    private var keysInUse: [SSHKey] { viewModel.filteredKeys.filter { isUsed($0) } }
    private var idleKeys: [SSHKey] { viewModel.filteredKeys.filter { !isUsed($0) } }
    /// As listed: the keys in use first.
    private var orderedKeys: [SSHKey] { keysInUse + idleKeys }

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if viewModel.showingGenerate {
                Divider()
                KeyGenerateSheet(
                    viewModel: viewModel,
                    isEmbeddedInInspector: true,
                    onCancel: { viewModel.showingGenerate = false }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if viewModel.showingImport {
                Divider()
                KeyImportSheet(
                    viewModel: viewModel,
                    isEmbeddedInInspector: true,
                    onCancel: { viewModel.showingImport = false }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let key = keyToInstall {
                Divider()
                KeyInstallSheet(
                    key: key,
                    isEmbeddedInInspector: true,
                    onCancel: { keyToInstall = nil }
                )
                .id(key.id ?? -1)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.standard, value: viewModel.showingGenerate)
        .animation(DS.Motion.standard, value: viewModel.showingImport)
        .animation(DS.Motion.standard, value: keyToInstall?.id)
            .navigationSubtitle(subtitle)
            .searchable(text: $viewModel.searchText, prompt: "Search keys")
            .toolbar {
                ToolbarItem {
                    Button {
                        keyToInstall = nil
                        viewModel.showingGenerate = false
                        viewModel.showingImport = true
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    .help("Import an SSH key from file")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        keyToInstall = nil
                        viewModel.showingImport = false
                        viewModel.showingGenerate = true
                    } label: {
                        Label("Generate…", systemImage: "plus")
                    }
                    .help("Generate a new SSH key pair")
                }
            }
            .task {
                await appViewModel.ensureHostsLoaded()
                await viewModel.loadKeys()
                takeReveal()
                #if DEBUG
                // -debugVaultSelect <key name>: start with that key selected.
                if let name = AppProfile.arguments.string(forKey: "debugVaultSelect"),
                   let key = viewModel.keys.last(where: { $0.name == name }) {
                    selectedKeyId = key.id
                }
                #endif
            }
            .onChange(of: DSReveal.shared.target) { _, _ in takeReveal() }
            // A key that was just generated or imported is the one shown.
            .onChange(of: viewModel.addedKeyId) { _, id in
                guard let id else { return }
                viewModel.searchText = ""
                selectedKeyId = id
                viewModel.addedKeyId = nil
            }
            .alert("Delete Key", isPresented: $viewModel.showingDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let key = viewModel.keyToDelete {
                        Task { await viewModel.deleteKey(key) }
                    }
                }
            } message: {
                if let key = viewModel.keyToDelete {
                    Text(verbatim: deleteMessage(for: key))
                }
            }
    }

    /// How many keys a search left; nothing otherwise (the section headers count the keys).
    private var subtitle: Text {
        guard !viewModel.searchText.isEmpty, !viewModel.keys.isEmpty else { return Text(verbatim: "") }
        return Text("\(viewModel.filteredKeys.count) matches")
    }

    /// The usual question, and what deleting it breaks.
    private func deleteMessage(for key: SSHKey) -> String {
        let question = String(localized: "Are you sure you want to delete \"\(key.name)\"? This cannot be undone.")
        let count = users(of: key).count
        guard count > 0 else { return question }
        return question + " " + String(localized: "\(count) hosts will no longer be able to sign in with it.")
    }

    /// Another page asked for one of the keys (an identity's "Show in Keychain").
    private func takeReveal() {
        guard let id = appViewModel.takeReveal(for: .keys).flatMap({ Int64($0) }) else { return }
        viewModel.searchText = ""
        selectedKeyId = id
    }

    private func askToDelete(_ key: SSHKey) {
        viewModel.keyToDelete = key
        viewModel.showingDeleteConfirm = true
    }

    // MARK: - Page

    @ViewBuilder
    private var content: some View {
        if !viewModel.hasLoaded {
            // Nothing until the first read is done: no empty state flashing by on the way in.
            DSDelayed { ProgressView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.keys.isEmpty {
            Group {
                // Keys that could not be read are not "No SSH Keys".
                if let error = viewModel.error {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(verbatim: error)
                    } actions: {
                        Button("Retry") { Task { await viewModel.loadKeys() } }
                    }
                } else {
                    emptyState
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

    private var emptyState: some View {
        DSEmptyState("No SSH Keys",
                     message: "Generate a new key or import an existing one. Private keys stay in the encrypted vault on this Mac.",
                     page: .keys) {
            Button("Generate Key") {
                keyToInstall = nil
                viewModel.showingImport = false
                viewModel.showingGenerate = true
            }
            .dsButtonStyle(.prominent)
            Button("Import Key") {
                keyToInstall = nil
                viewModel.showingGenerate = false
                viewModel.showingImport = true
            }
            .dsButtonStyle(.glass)
        }
    }

    // MARK: - Master

    @ViewBuilder
    private var master: some View {
        if viewModel.filteredKeys.isEmpty {
            ContentUnavailableView.search(text: viewModel.searchText)
        } else {
            DSMasterList(selection: Binding(get: { currentKey?.id }, set: { selectedKeyId = $0 }),
                         order: orderedKeys.compactMap(\.id)) {
                if viewModel.isGenerating {
                    HStack(spacing: DS.Space.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating…")
                            .font(DS.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: DS.Height.compactRow)
                }
                if !keysInUse.isEmpty {
                    DSListSectionHeader("In Use", count: keysInUse.count)
                    ForEach(keysInUse) { row($0, isUnused: false) }
                }
                if !idleKeys.isEmpty {
                    DSListSectionHeader("Unused", count: idleKeys.count)
                    ForEach(idleKeys) { row($0, isUnused: true) }
                }
            }
            .padding(.top, DS.Space.xs)
        }
    }

    private func row(_ key: SSHKey, isUnused: Bool) -> some View {
        let bits = KeyStrength.bits(type: key.type, publicKey: key.publicKey)
        return KeyListRow(key: key,
                          typeLabel: KeyStrength.label(type: key.type, bits: bits),
                          isWeak: KeyStrength.rating(type: key.type, bits: bits) == .weak,
                          hasPassphrase: key.id.map { viewModel.keysWithPassphrase.contains($0) } ?? false,
                          users: users(of: key),
                          isUnused: isUnused)
            .dsListRow(isSelected: currentKey?.id == key.id, height: 52)
            .id(key.id ?? 0)
            .onTapGesture { selectedKeyId = key.id }
            .accessibilityAction { selectedKeyId = key.id }
            .contextMenu {
                Button {
                    viewModel.copyPublicKey(key)
                } label: {
                    Label("Copy Public Key", systemImage: "doc.on.doc")
                }
                .disabled(key.publicKey.isEmpty)
                Button {
                    VaultPasteboard.copy(key.fingerprint ?? "")
                } label: {
                    Label("Copy Fingerprint", systemImage: "number")
                }
                .disabled((key.fingerprint ?? "").isEmpty)
                Button {
                    viewModel.showingGenerate = false
                    viewModel.showingImport = false
                    keyToInstall = key
                } label: {
                    Label("Install on Host…", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(key.publicKey.isEmpty)
                Divider()
                Button(role: .destructive) {
                    askToDelete(key)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let key = currentKey {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    // A failed generate, import or delete, said where the keys are.
                    if let error = viewModel.error {
                        VaultErrorBanner(message: error) { viewModel.error = nil }
                    }
                    KeyDetailView(key: key,
                                  hasPassphrase: key.id.map { viewModel.keysWithPassphrase.contains($0) } ?? false,
                                  directHosts: key.id.map { VaultUsage.hosts(directlyUsingKey: $0, hosts: hosts, groups: groups) } ?? [],
                                  identities: key.id.map { VaultUsage.identities(usingKey: $0, identities: viewModel.identities) } ?? [],
                                  hosts: hosts,
                                  groups: groups,
                                  onInstall: {
                                      viewModel.showingGenerate = false
                                      viewModel.showingImport = false
                                      keyToInstall = key
                                  },
                                  onDelete: { askToDelete(key) })
                }
                .padding(DS.Space.page)
            }
            .id(key.id)
            .transition(.opacity)
            .animation(DS.Motion.standard, value: viewModel.error)
        } else {
            Color.clear
        }
    }
}

// MARK: - Key row

/// A key in the list: its fingerprint image, name, type, and the hosts it signs in.
private struct KeyListRow: View {
    let key: SSHKey
    let typeLabel: String
    let isWeak: Bool
    let hasPassphrase: Bool
    let users: [Host]
    /// Listed under "Unused": the section header says it for the eye, the label for VoiceOver.
    let isUnused: Bool
    @Environment(\.dsIsSelected) private var isSelected

    var body: some View {
        // Narrow master column: the stack of tiles gives way to a count, the name truncates.
        ViewThatFits(in: .horizontal) {
            layout(isCompact: false)
            layout(isCompact: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilitySummary))
    }

    private var accessibilitySummary: String {
        var parts = [key.name, typeLabel]
        if isUnused { parts.append(String(localized: "Unused")) }
        return parts.joined(separator: ", ")
    }

    private func layout(isCompact: Bool) -> some View {
        HStack(spacing: DS.Space.card) {
            // White on the selection pill, where the accent would not show.
            DSRandomart(fingerprint: key.fingerprint, cell: 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(verbatim: key.name)
                        .font(DS.Font.rowTitle)
                        .lineLimit(1)
                    if hasPassphrase {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Has passphrase"))
                    }
                }
                HStack(spacing: 5) {
                    DSChip(verbatim: typeLabel, isMonospaced: true)
                    if isWeak {
                        DSChip("Weak", symbol: "exclamationmark.triangle.fill",
                               tint: isSelected ? nil : DS.Palette.warning)
                    }
                }
            }
            .fixedSize(horizontal: !isCompact, vertical: false)
            Spacer(minLength: DS.Space.xs)
            // No hosts: nothing at the end of the row (its section says whether it is in use).
            if !users.isEmpty {
                if isCompact {
                    Text("\(users.count) hosts")
                        .font(DS.Font.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else {
                    DSHostStack(hosts: users, limit: 3)
                }
            }
        }
    }
}

// MARK: - Key detail

private struct KeyDetailView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let key: SSHKey
    let hasPassphrase: Bool
    /// Hosts that name the key themselves.
    let directHosts: [Host]
    /// Identities that sign in with the key.
    let identities: [Identity]
    let hosts: [Host]
    let groups: [HostGroup]
    let onInstall: () -> Void
    let onDelete: () -> Void

    private var bits: Int? { KeyStrength.bits(type: key.type, publicKey: key.publicKey) }
    private var createdAt: Date? { TimestampFormatter.date(from: key.createdAt) }

    private func hosts(of identity: Identity) -> [Host] {
        guard let id = identity.id else { return [] }
        return VaultUsage.hosts(usingIdentity: id, hosts: hosts, groups: groups)
    }

    /// Hosts the key signs in through one of its identities, with that identity.
    private var lentHosts: [(host: Host, identity: Identity)] {
        identities.flatMap { identity in hosts(of: identity).map { (host: $0, identity: identity) } }
    }

    private var hostCount: Int { directHosts.count + lentHosts.count }

    /// "ED25519 · October 3, 2026" / "RSA 4096 · …": what the key is and when it joined the vault.
    private var subtitle: String {
        let type = KeyStrength.label(type: key.type, bits: bits)
        guard let createdAt else { return type }
        return "\(type) · \(createdAt.formatted(date: .long, time: .omitted))"
    }

    /// The same, to the minute, for the tooltip.
    private var subtitleHelp: String {
        guard let createdAt else { return subtitle }
        return DisplayDateFormatter.mediumDateShortTime.string(from: createdAt)
    }

    var body: some View {
        // A type and a date: words, not an address.
        DSDetailHeader(title: key.name, subtitle: subtitle, isSubtitleMonospaced: false) {
            DSCategoryTile(page: .keys)
        } accessory: {
            if hasPassphrase {
                DSChip("Has passphrase", symbol: "lock.fill")
            }
            switch KeyStrength.rating(type: key.type, bits: bits) {
            case .strong?: DSChip("Strong", symbol: "checkmark.seal.fill", tint: DS.Palette.success)
            case .weak?: DSChip("Weak", symbol: "exclamationmark.triangle.fill", tint: DS.Palette.warning)
            case nil: EmptyView()
            }
        } actions: {
            // Not the share glyph: the public key's card has that one.
            Button(action: onInstall) {
                Label("Install on Host…", systemImage: "square.and.arrow.up.on.square")
            }
            .dsButtonStyle(.prominent)
            .disabled(key.publicKey.isEmpty)
            .help("Install the public key on a host (authorized_keys)")
            // Copying is done on the cards, next to what is copied.
            DSGlassIconMenu {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Key", systemImage: "trash")
                }
            }
        }
        .help(Text(verbatim: subtitleHelp))

        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Fingerprint")
            VaultHeroCard(fingerprint: key.fingerprint) {
                VaultFingerprintColumn(fingerprint: key.fingerprint,
                                       note: String(localized: "Same image as ssh-keygen -lv"))
            }
        }

        if !key.publicKey.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                DSSectionHeader("Public Key")
                VaultPublicKeyCard(publicKey: key.publicKey)
            }
        }

        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Used By") {
                if hostCount > 0 || !identities.isEmpty {
                    Text(verbatim: usedBySummary)
                }
            }
            DSGroup {
                if hostCount == 0 && identities.isEmpty {
                    DSRow {
                        Text("Not used by any host or identity")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(directHosts, id: \.connectionKey) { host in
                    VaultHostLink(host: host)
                }
                ForEach(identities) { identity in
                    DSLinkRow(identity.name, subtitle: String(localized: "Identity") + " · " + identity.username, action: {
                        if let id = identity.id { appViewModel.reveal(.identities, id: String(id)) }
                    }, icon: {
                        DSIconTile(.monogram(VaultText.monogram(for: identity.username)), tint: DS.Palette.accent,
                                   size: DS.Tile.row)
                    }, trailing: {
                        let users = hosts(of: identity)
                        if users.isEmpty {
                            Text("Identity")
                        } else {
                            DSHostStack(hosts: users, limit: 3)
                        }
                    })
                }
                ForEach(lentHosts, id: \.host.connectionKey) { item in
                    VaultHostLink(host: item.host, detail: String(localized: "via identity \(item.identity.name)"))
                }
            }
        }
    }

    private var usedBySummary: String {
        var parts: [String] = []
        if hostCount > 0 { parts.append(String(localized: "\(hostCount) hosts")) }
        if !identities.isEmpty { parts.append(String(localized: "\(identities.count) identities")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Shared pieces of the vault pages

enum VaultPasteboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension AppViewModel {
    /// How many panes of this window are sessions of the saved host.
    func vaultSessionCount(forHostId hostId: Int64?) -> Int {
        guard let hostId else { return 0 }
        return tabs.flatMap(\.panes).filter { $0.hostId == hostId }.count
    }
}

/// A failed save or delete, at the top of the detail, with a way to put it away.
struct VaultErrorBanner: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            DSMessage(verbatim: message)
            DSRowButton("xmark", help: "Close", action: onClose)
        }
    }
}

/// A saved host that uses the record: its tile with the live state, where it leads, and its
/// sessions (or a note) at the end.
struct VaultHostLink: View {
    @Environment(AppViewModel.self) private var appViewModel
    let host: Host
    var detail: String?

    var body: some View {
        let status = appViewModel.avatarStatus(forHostId: host.id)
        let sessions = appViewModel.vaultSessionCount(forHostId: host.id)
        DSLinkRow(host.displayName, subtitle: host.addressDescription, action: {
            appViewModel.reveal(host: host)
        }, icon: {
            DSHostAvatar(host, size: DS.Tile.row, status: status)
        }, trailing: {
            if status == .live, sessions > 0 {
                DSStatusPill(verbatim: String(localized: "\(sessions) sessions"))
            } else if let detail {
                Text(verbatim: detail)
            }
        })
    }
}

/// The one tinted card of a vault detail: a fingerprint image, large, with what belongs to it
/// next to it — or under it when the detail column is narrow. Without a fingerprint that can
/// be drawn there is no image (never a placeholder).
struct VaultHeroCard<Content: View>: View {
    private let fingerprint: String?
    private let allowsSmallImage: Bool
    private let content: Content

    /// `allowsSmallImage`: where the image only accompanies the record (an identity's key), a
    /// narrow column keeps it small beside the text instead of stacking it large above — the
    /// rows under the card stay in sight.
    init(fingerprint: String?, allowsSmallImage: Bool = false, @ViewBuilder content: () -> Content) {
        self.fingerprint = fingerprint
        self.allowsSmallImage = allowsSmallImage
        self.content = content()
    }

    private var hasImage: Bool {
        fingerprint.flatMap { Randomart(fingerprint: $0) } != nil
    }

    var body: some View {
        Group {
            if hasImage {
                ViewThatFits(in: .horizontal) {
                    sideBySide(cell: 10, columnWidth: 320)
                    sideBySide(cell: 8, columnWidth: 300)
                    if allowsSmallImage {
                        sideBySide(cell: 5, columnWidth: 224)
                    }
                    // Stacked: the image as wide as the card lets it be, not a stamp in a corner.
                    stacked(cell: 14)
                    stacked(cell: 12)
                    stacked(cell: 10)
                }
            } else {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(hero: DS.Palette.accent)
    }

    private func stacked(cell: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            DSRandomart(fingerprint: fingerprint, cell: cell)
                .fixedSize()
            // The ideal width is what ViewThatFits measures: the image decides, not the
            // fingerprint's one-line width.
            content
                .frame(idealWidth: 200, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sideBySide(cell: CGFloat, columnWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: DS.Space.xl) {
            DSRandomart(fingerprint: fingerprint, cell: cell)
            // The ideal width is what ViewThatFits measures: without it the fingerprint's
            // one-line width would count and the layout would never fit.
            content
                .frame(minWidth: columnWidth, idealWidth: columnWidth, maxWidth: .infinity,
                       maxHeight: .infinity, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Next to the image: the fingerprint in full with a way to copy it at the end of its line,
/// and what it is good for.
struct VaultFingerprintColumn: View {
    let fingerprint: String?
    let note: String

    /// The hash name stands back, the digest is what is compared.
    private var text: AttributedString {
        let value = fingerprint ?? ""
        guard let colon = value.firstIndex(of: ":") else { return AttributedString(VaultText.breakable(value)) }
        var name = AttributedString(String(value[...colon]))
        name.swiftUI.foregroundColor = .secondary
        return name + AttributedString(VaultText.breakable(String(value[value.index(after: colon)...])))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fingerprint, !fingerprint.isEmpty {
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    Text(text)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(Text(verbatim: fingerprint))
                    DSCopyButton(help: "Copy Fingerprint") { VaultPasteboard.copy(fingerprint) }
                        .vaultIconButton()
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Palette.accent)
                        .accessibilityHidden(true)
                    Text(verbatim: note)
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } else {
                Text("No fingerprint")
                    .font(DS.Font.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// A small round glass button around a borderless icon button (copy, share) on a card.
    func vaultIconButton() -> some View {
        frame(width: 28, height: 28)
            .dsGlass(.circle, isInteractive: true)
    }
}

/// A public key: content, not a command — on a card, with copy and share.
struct VaultPublicKeyCard: View {
    let publicKey: String

    var body: some View {
        DSGroup {
            HStack(alignment: .top, spacing: DS.Space.md) {
                // Copied with the button: the displayed text carries break opportunities.
                Text(verbatim: VaultText.breakable(publicKey.trimmingCharacters(in: .whitespacesAndNewlines)))
                    .font(DS.Font.mono)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    DSCopyButton(help: "Copy Public Key") { VaultPasteboard.copy(publicKey) }
                        .vaultIconButton()
                    ShareLink(item: publicKey) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Share")
                    .accessibilityLabel(Text("Share"))
                    .vaultIconButton()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, DS.Space.md)
        }
    }
}

/// What identifies a key in a sheet: its fingerprint image, name, type and fingerprint.
private struct KeyIdentityView: View {
    let key: SSHKey

    var body: some View {
        HStack(spacing: DS.Space.md) {
            if let fingerprint = key.fingerprint, Randomart(fingerprint: fingerprint) != nil {
                DSRandomart(fingerprint: fingerprint, cell: 4)
            } else {
                DSCategoryTile(page: .keys, size: DS.Tile.card)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.sm) {
                    Text(verbatim: key.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    DSChip(verbatim: key.type.uppercased(), isMonospaced: true)
                }

                if let fingerprint = key.fingerprint, !fingerprint.isEmpty {
                    Text(verbatim: fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(fingerprint)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// First section header of a sheet: its title, and a spinner while it works.
private struct KeySheetTitle: View {
    let title: LocalizedStringKey
    var isBusy = false

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            DSSheetTitle(title)
            Spacer(minLength: 0)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

/// Said where a private key enters the vault (the generate and import sheets), not under the list.
private struct KeyVaultNote: View {
    var body: some View {
        Label("Private keys are stored only in this Mac's encrypted vault", systemImage: "lock")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension SSHKeyGenerator.KeyType {
    /// `displayName` as a catalog key (the property itself is a plain `String`).
    var localizedName: LocalizedStringKey {
        switch self {
        case .ed25519: "Ed25519 (Recommended)"
        case .rsa: "RSA (4096-bit)"
        }
    }
}

// MARK: - Install Sheet

/// Appends a public key to ~/.ssh/authorized_keys on chosen hosts (like ssh-copy-id).
struct KeyInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var appViewModel
    let key: SSHKey
    var isEmbeddedInInspector: Bool = false
    var onCancel: (() -> Void)? = nil

    @State private var hosts: [Host] = []
    @State private var didLoadHosts = false
    @State private var selected: Set<Int64> = []
    @State private var results: [Int64: Result<Void, InstallError>] = [:]
    @State private var running: Set<Int64> = []

    struct InstallError: Error {
        let message: String
    }

    var body: some View {
        if isEmbeddedInInspector {
            DSInspectorPanel("Install Public Key", onClose: closeForm) {
                formBody
            } footer: {
                HStack {
                    if !allInstalled {
                        if results.isEmpty {
                            Button("Cancel") { closeForm() }
                                .keyboardShortcut(.cancelAction)
                        } else {
                            Button("Close") { closeForm() }
                                .keyboardShortcut(.cancelAction)
                        }
                    }
                    Spacer()
                    if allInstalled {
                        Button("Done") { closeForm() }
                            .dsButtonStyle(.prominent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Group {
                            if hasFailures {
                                Button("Retry") { install() }
                            } else {
                                Button("Install") { install() }
                            }
                        }
                        .dsButtonStyle(.prominent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected.isEmpty || !running.isEmpty)
                    }
                }
            }
            .onExitCommand { closeForm() }
            .task {
                hosts = (try? await HostRepository.shared.fetchAll()) ?? []
                didLoadHosts = true
            }
        } else {
            formBody
                .frame(width: 480, height: 460)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if !allInstalled {
                            if results.isEmpty {
                                Button("Cancel") { closeForm() }
                            } else {
                                Button("Close") { closeForm() }
                            }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if allInstalled {
                            Button("Done") { closeForm() }
                        } else {
                            Group {
                                if hasFailures {
                                    Button("Retry") { install() }
                                } else {
                                    Button("Install") { install() }
                                }
                            }
                            .disabled(selected.isEmpty || !running.isEmpty)
                        }
                    }
                }
                .onExitCommand { closeForm() }
                .task {
                    hosts = (try? await HostRepository.shared.fetchAll()) ?? []
                    didLoadHosts = true
                }
        }
    }

    private var formBody: some View {
        Form {
            Section {
                KeyIdentityView(key: key)
            } header: {
                if !isEmbeddedInInspector {
                    DSSheetTitle("Install Public Key")
                }
            } footer: {
                Text("The key is appended to ~/.ssh/authorized_keys on each selected host (once). You may be asked for the host's password.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                if !didLoadHosts {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else if hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Hosts", systemImage: "server.rack")
                    } description: {
                        Text("No hosts configured. Add hosts in the Hosts section first.")
                    } actions: {
                        Button("Show Hosts") {
                            closeForm()
                            appViewModel.selectedSidebar = .terminal
                        }
                    }
                } else {
                    ForEach(hosts) { host in
                        hostRow(host)
                    }
                }
            } header: {
                HStack(spacing: DS.Space.sm) {
                    Text("Hosts")
                    Spacer(minLength: 0)
                    if hosts.count > 1 {
                        selectAllButton
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func closeForm() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    // MARK: State

    private func succeeded(_ id: Int64) -> Bool {
        if case .success? = results[id] { return true }
        return false
    }

    private var hasFailures: Bool {
        selected.contains { if case .failure? = results[$0] { return true } else { return false } }
    }

    /// Every ticked host has the key: nothing is left to do but close.
    private var allInstalled: Bool {
        !selected.isEmpty && running.isEmpty && selected.allSatisfy { succeeded($0) }
    }

    // MARK: Host row

    private func hostRow(_ host: Host) -> some View {
        let id = host.id ?? -1
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.md) {
                Toggle(isOn: selection(of: id)) {
                    HStack(spacing: DS.Space.sm) {
                        DSHostAvatar(host, size: DS.Tile.sidebar)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: host.label.isEmpty ? host.hostname : host.label)
                                .lineLimit(1)
                            Text(verbatim: host.addressDescription)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .toggleStyle(.checkbox)

                Spacer(minLength: DS.Space.sm)

                if running.contains(id) {
                    ProgressView()
                        .controlSize(.small)
                } else if case .success? = results[id] {
                    Label {
                        Text("Installed")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(DS.Palette.success)
                    }
                    .font(.callout)
                }
            }

            if !running.contains(id), case .failure(let error)? = results[id] {
                DSMessage(verbatim: error.message.isEmpty ? String(localized: "Installation failed") : error.message)
            }
        }
    }

    /// Checks every host (⌘A), or clears the selection once they all are.
    @ViewBuilder
    private var selectAllButton: some View {
        let allIds = Set(hosts.compactMap(\.id))
        if selected.isSuperset(of: allIds) {
            Button("Deselect All") { selected.removeAll() }
        } else {
            Button("Select All") { selected = allIds }
                .keyboardShortcut("a", modifiers: .command)
        }
    }

    private func selection(of id: Int64) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn {
                    selected.insert(id)
                } else {
                    selected.remove(id)
                }
            }
        )
    }

    private func install() {
        let publicKey = key.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = publicKey.shellEscaped
        // A file whose last line lacks its newline gets one first, or the key would be glued onto
        // that line. No $() or braces: the remote login shell may be csh. LC_ALL=C because in a
        // UTF-8 locale GNU grep's "." skips the lone last byte of a multi-byte character.
        let command = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && "
            + "(grep -qxF \(quoted) ~/.ssh/authorized_keys || "
            + "(tail -c 1 ~/.ssh/authorized_keys | env LC_ALL=C grep -q . && echo >> ~/.ssh/authorized_keys; "
            + "printf '%s\\n' \(quoted) >> ~/.ssh/authorized_keys))"
        // A retry only goes to the hosts that failed and the newly ticked ones.
        for host in hosts where selected.contains(host.id ?? -1) {
            guard let id = host.id, !succeeded(id) else { continue }
            running.insert(id)
            results[id] = nil
            Task {
                do {
                    let result = try await SSHService.shared.run(command, on: host)
                    results[id] = result.exitCode == 0
                        ? .success(())
                        : .failure(InstallError(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
                } catch {
                    results[id] = .failure(InstallError(message: error.localizedDescription))
                }
                running.remove(id)
            }
        }
    }
}

// MARK: - Generate Sheet

struct KeyGenerateSheet: View {
    let viewModel: KeysViewModel
    var isEmbeddedInInspector: Bool = false
    var onCancel: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keyType: SSHKeyGenerator.KeyType = .ed25519
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    /// Why the last attempt failed (shown in the sheet, which stays open).
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (passphrase.isEmpty || passphrase == confirmPassphrase)
    }

    private var passphrasesDiffer: Bool {
        // Not while the confirmation is still being typed (it is the beginning of the passphrase).
        !passphrase.isEmpty && !confirmPassphrase.isEmpty && !passphrase.hasPrefix(confirmPassphrase)
    }

    var body: some View {
        Group {
            if isEmbeddedInInspector {
                DSInspectorPanel("Generate SSH Key", onClose: closeForm) {
                    formBody
                } footer: {
                    HStack {
                        Button("Cancel") { closeForm() }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Generate") {
                            submitGenerate()
                        }
                        .dsButtonStyle(.prominent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid || viewModel.isGenerating)
                    }
                }
            } else {
                formBody
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 460)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { closeForm() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Generate") {
                                submitGenerate()
                            }
                            .disabled(!isValid || viewModel.isGenerating)
                        }
                    }
            }
        }
        .animation(DS.Motion.standard, value: passphrasesDiffer)
        .animation(DS.Motion.standard, value: failure)
        .onAppear { nameFocused = true }
    }

    private var formBody: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text(verbatim: keyType == .rsa ? "id_rsa" : "id_ed25519"))
                    .autocorrectionDisabled()
                    .focused($nameFocused)

                Picker("Type", selection: $keyType) {
                    ForEach(SSHKeyGenerator.KeyType.allCases, id: \.self) { type in
                        Text(type.localizedName).tag(type)
                    }
                }
            } header: {
                if !isEmbeddedInInspector {
                    KeySheetTitle(title: "Generate SSH Key", isBusy: viewModel.isGenerating)
                }
            }

            Section {
                LabeledContent("Passphrase") {
                    ASCIISecureField("Optional", text: $passphrase, isBezeled: false)
                }
                // Always there (inactive until a passphrase is typed), so the sheet keeps its size.
                LabeledContent {
                    ASCIISecureField("Retype Passphrase", text: $confirmPassphrase, isBezeled: false)
                } label: {
                    Text("Confirm Passphrase")
                        .foregroundStyle(passphrase.isEmpty ? .tertiary : .primary)
                }
                .disabled(passphrase.isEmpty)
            } footer: {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    KeyVaultNote()
                    if passphrasesDiffer {
                        DSMessage("Passphrases don't match")
                            .transition(.opacity)
                    } else if let failure {
                        DSMessage(verbatim: failure)
                            .transition(.opacity)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func closeForm() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    private func submitGenerate() {
        Task {
            failure = nil
            let saved = await viewModel.generateKey(
                name: name.trimmingCharacters(in: .whitespaces),
                type: keyType,
                passphrase: passphrase
            )
            if saved {
                closeForm()
            } else {
                failure = viewModel.error
                viewModel.error = nil
            }
        }
    }
}

// MARK: - Import Sheet

struct KeyImportSheet: View {
    let viewModel: KeysViewModel
    var isEmbeddedInInspector: Bool = false
    var onCancel: (() -> Void)? = nil

    enum ImportMode: String, CaseIterable {
        case file = "From File"
        case manual = "Manual Input"
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: ImportMode = .file
    @State private var name = ""
    // File mode
    @State private var filePath = ""
    // Manual mode
    @State private var privateKeyText = ""
    @State private var publicKeyText = ""
    @State private var passphrase = ""
    @State private var isImporting = false
    /// Why the last attempt failed (shown in the sheet, which stays open).
    @State private var failure: String?

    /// Where the key goes, and why the last attempt failed.
    private var failureFooter: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            KeyVaultNote()
            if let failure {
                DSMessage(verbatim: failure)
                    .transition(.opacity)
            }
        }
    }

    private var isValid: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        switch mode {
        case .file:
            return hasName && !filePath.isEmpty
        case .manual:
            return hasName && !privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        Group {
            if isEmbeddedInInspector {
                DSInspectorPanel("Import SSH Key", onClose: closeForm) {
                    formBody
                } footer: {
                    HStack {
                        Button("Cancel") { closeForm() }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Import") {
                            submitImport()
                        }
                        .dsButtonStyle(.prominent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid || isImporting)
                    }
                }
            } else {
                formBody
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 460)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { closeForm() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Import") {
                                submitImport()
                            }
                            .disabled(!isValid || isImporting)
                        }
                    }
            }
        }
        .animation(DS.Motion.standard, value: mode)
        .animation(DS.Motion.standard, value: failure)
        .onChange(of: mode) { failure = nil }
    }

    private var formBody: some View {
        Form {
            Section {
                Picker("Source", selection: $mode) {
                    ForEach(ImportMode.allCases, id: \.self) { m in
                        Text(LocalizedStringKey(m.rawValue)).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Name", text: $name, prompt: Text(verbatim: "id_ed25519"))
                    .autocorrectionDisabled()
            } header: {
                if !isEmbeddedInInspector {
                    KeySheetTitle(title: "Import SSH Key", isBusy: isImporting)
                }
            }

            switch mode {
            case .file:
                Section {
                    // The chooser next to the label, the path on a line of its own: a path needs
                    // the whole width, and the row keeps its shape whatever its length.
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        HStack(spacing: DS.Space.sm) {
                            Text("Private Key File")
                            Spacer(minLength: 0)
                            Button("Browse…") {
                                selectFile()
                            }
                        }
                        TextField("Private Key File", text: $filePath, prompt: Text(verbatim: "/path/to/private_key"))
                            .labelsHidden()
                            .font(.callout.monospaced())
                            .truncationMode(.middle)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    failureFooter
                }

            case .manual:
                Section("Private Key") {
                    keyEditor(
                        text: $privateKeyText,
                        placeholder: "-----BEGIN OPENSSH PRIVATE KEY-----",
                        height: 120,
                        label: "Private Key"
                    )
                }

                Section("Public Key (optional)") {
                    keyEditor(
                        text: $publicKeyText,
                        placeholder: "ssh-ed25519 AAAA…",
                        height: 60,
                        label: "Public Key (optional)"
                    )
                }

                Section {
                    LabeledContent("Passphrase") {
                        ASCIISecureField("Optional", text: $passphrase, isBezeled: false)
                    }
                } footer: {
                    failureFooter
                }
            }
        }
        .formStyle(.grouped)
    }

    private func closeForm() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    private func submitImport() {
        Task {
            isImporting = true
            defer { isImporting = false }
            failure = nil
            let saved: Bool
            switch mode {
            case .file:
                saved = await viewModel.importKey(
                    name: name.trimmingCharacters(in: .whitespaces),
                    filePath: filePath
                )
            case .manual:
                saved = await viewModel.importKeyFromText(
                    name: name.trimmingCharacters(in: .whitespaces),
                    privateKey: privateKeyText,
                    publicKey: publicKeyText,
                    passphrase: passphrase
                )
            }
            if saved {
                closeForm()
            } else {
                failure = viewModel.error
                viewModel.error = nil
            }
        }
    }

    /// Pasted key material: monospaced, on the form row's own background, scrolls by itself.
    private func keyEditor(text: Binding<String>, placeholder: String, height: CGFloat,
                           label: LocalizedStringKey) -> some View {
        TextEditor(text: text)
            .font(.callout.monospaced())
            .scrollContentBackground(.hidden)
            .scrollDisabled(false)
            .autocorrectionDisabled()
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(verbatim: placeholder)
                        .font(.callout.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(Text(label))
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = String(localized: "Select an SSH private key file")

        if panel.runModal() == .OK, let url = panel.url {
            filePath = url.path
            if name.isEmpty {
                name = url.lastPathComponent
            }
        }
    }
}
