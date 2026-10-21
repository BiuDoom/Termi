import SwiftUI
import AppKit

/// Identity profiles management — reusable SSH auth configurations: one set of sign-in
/// details, and the hosts and groups that share it.
struct IdentitiesView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = IdentitiesViewModel()
    @State private var selectedId: Int64?

    private var hosts: [Host] { viewModel.scoped(appViewModel.hostsPage.hosts) }
    private var groups: [HostGroup] { viewModel.scoped(appViewModel.hostsPage.allGroups) }

    /// The selected identity if it is listed, else the first one.
    private var currentIdentity: Identity? {
        let listed = viewModel.filteredIdentities
        return listed.first { $0.id == selectedId } ?? listed.first
    }

    private func users(of identity: Identity) -> [Host] {
        guard let id = identity.id else { return [] }
        return VaultUsage.hosts(usingIdentity: id, hosts: hosts, groups: groups)
    }

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if viewModel.showingForm {
                Divider()
                IdentityFormSheet(
                    viewModel: viewModel,
                    identity: viewModel.editingIdentity,
                    affectedHosts: viewModel.editingIdentity.map { users(of: $0).count } ?? 0,
                    isEmbeddedInInspector: true,
                    onCancel: { viewModel.showingForm = false }
                )
                .id(viewModel.editingIdentity?.id ?? -1)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.standard, value: viewModel.showingForm)
            .searchable(text: $viewModel.searchText, prompt: "Search identities")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.addNew()
                    } label: {
                        Label("Add Identity", systemImage: "plus")
                    }
                    .help("Add a new identity profile")
                }
            }
            .task {
                await appViewModel.ensureHostsLoaded()
                await viewModel.loadIdentities()
                takeReveal()
                #if DEBUG
                // -debugVaultSelect <identity name>: start with that identity selected;
                // -debugVaultEdit YES: and with its edit sheet open.
                if let name = AppProfile.arguments.string(forKey: "debugVaultSelect"),
                   let identity = viewModel.identities.first(where: { $0.name == name }) {
                    selectedId = identity.id
                    if AppProfile.arguments.bool(forKey: "debugVaultEdit") { viewModel.edit(identity) }
                }
                #endif
            }
            .onChange(of: DSReveal.shared.target) { _, _ in takeReveal() }
            // An identity that was just added or edited is the one shown.
            .onChange(of: viewModel.savedIdentityId) { _, id in
                guard let id else { return }
                viewModel.searchText = ""
                selectedId = id
                viewModel.savedIdentityId = nil
            }
            .alert("Delete Identity", isPresented: $viewModel.showingDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let identity = viewModel.identityToDelete {
                        Task { await viewModel.deleteIdentity(identity) }
                    }
                }
            } message: {
                if let identity = viewModel.identityToDelete {
                    Text(verbatim: deleteMessage(for: identity))
                }
            }
    }

    /// How many identities a search left; nothing otherwise (the list is the inventory).
    private var subtitle: Text {
        guard !viewModel.searchText.isEmpty, !viewModel.identities.isEmpty else { return Text(verbatim: "") }
        return Text("\(viewModel.filteredIdentities.count) matches")
    }

    /// The usual question, and what deleting it breaks: said here, at the moment of the action.
    private func deleteMessage(for identity: Identity) -> String {
        let question = String(localized: "Delete \"\(identity.name)\"? This cannot be undone.")
        let count = users(of: identity).count
        guard count > 0 else { return question }
        return question + " " + String(localized: "\(count) hosts will no longer be able to sign in with it.")
    }

    /// Another page asked for one of the identities (a key's "used by").
    private func takeReveal() {
        guard let id = appViewModel.takeReveal(for: .identities).flatMap({ Int64($0) }) else { return }
        viewModel.searchText = ""
        selectedId = id
    }

    private func askToDelete(_ identity: Identity) {
        viewModel.identityToDelete = identity
        viewModel.showingDeleteConfirm = true
    }

    // MARK: - Page

    @ViewBuilder
    private var content: some View {
        if !viewModel.hasLoaded {
            DSDelayed { ProgressView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.identities.isEmpty {
            Group {
                if let error = viewModel.error {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(verbatim: error)
                    } actions: {
                        Button("Retry") { Task { await viewModel.loadIdentities() } }
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
        DSEmptyState("No Identities", message: "One set of sign-in details, shared by many hosts",
                     page: .identities) {
            // What an identity is, drawn: one sign-in, several hosts.
            DSRouteDiagram(hops: [.endpoint("ops", symbol: "person.fill"),
                                  .endpoint("web-1", symbol: "server.rack"),
                                  .endpoint("web-2", symbol: "server.rack")])
                // Its wires take all the room they get: held to the width of the text above.
                .frame(maxWidth: 360)
                .opacity(0.6)
                .accessibilityHidden(true)
        } actions: {
            Button("Add Identity") {
                viewModel.addNew()
            }
            .dsButtonStyle(.prominent)
        }
    }

    // MARK: - Master

    @ViewBuilder
    private var master: some View {
        if viewModel.filteredIdentities.isEmpty {
            ContentUnavailableView.search(text: viewModel.searchText)
        } else {
            // One kind of row: no section header (the page title names them).
            DSMasterList(selection: Binding(get: { currentIdentity?.id }, set: { selectedId = $0 }),
                         order: viewModel.filteredIdentities.compactMap(\.id)) {
                ForEach(viewModel.filteredIdentities) { identity in
                    IdentityListRow(identity: identity,
                                    keyName: viewModel.keyName(for: identity.privateKeyId),
                                    users: users(of: identity))
                        .dsListRow(isSelected: currentIdentity?.id == identity.id)
                        .id(identity.id ?? 0)
                        .onTapGesture(count: 2) {
                            // The row that opens is the row that is selected.
                            selectedId = identity.id
                            viewModel.edit(identity)
                        }
                        .onTapGesture { selectedId = identity.id }
                        .accessibilityAction { selectedId = identity.id }
                        .contextMenu {
                            Button {
                                viewModel.edit(identity)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button {
                                VaultPasteboard.copy(identity.username)
                            } label: {
                                Label("Copy Username", systemImage: "doc.on.doc")
                            }
                            Divider()
                            Button(role: .destructive) {
                                askToDelete(identity)
                            } label: {
                                Label("Delete", systemImage: "trash")
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
        if let identity = currentIdentity {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    // A failed save or delete, said where the identities are.
                    if let error = viewModel.error {
                        VaultErrorBanner(message: error) { viewModel.error = nil }
                    }
                    IdentityDetailView(identity: identity,
                                       key: viewModel.key(for: identity.privateKeyId),
                                       users: users(of: identity),
                                       hosts: hosts,
                                       groups: groups,
                                       onEdit: { viewModel.edit(identity) },
                                       onDelete: { askToDelete(identity) })
                }
                .padding(DS.Space.page)
            }
            .id(identity.id)
            .transition(.opacity)
            .animation(DS.Motion.standard, value: viewModel.error)
        } else {
            Color.clear
        }
    }
}

// MARK: - How an identity signs in

private extension Identity {
    var hasStoredPassword: Bool {
        !(passwordEncrypted ?? "").isEmpty
    }

    var authLabel: String {
        switch authType {
        case "privateKey": String(localized: "Private Key")
        case "agent": String(localized: "System SSH Agent")
        case "keyboard-interactive": String(localized: "Keyboard Interactive")
        default: String(localized: "Password")
        }
    }

    var signInLabel: String {
        switch authType {
        case "privateKey": String(localized: "Signs in with a key")
        case "agent": String(localized: "Signs in through the system SSH agent")
        case "keyboard-interactive": String(localized: "Signs in with keyboard-interactive authentication")
        default: String(localized: "Signs in with a password")
        }
    }
}

// MARK: - Identity row

struct IdentityListRow: View {
    let identity: Identity
    let keyName: String?
    let users: [Host]

    var body: some View {
        // Narrow master column: the stack of tiles gives way to a count, the name truncates.
        ViewThatFits(in: .horizontal) {
            layout(isCompact: false)
            layout(isCompact: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilitySummary))
    }

    private func layout(isCompact: Bool) -> some View {
        HStack(spacing: 11) {
            DSIconTile(.monogram(VaultText.monogram(for: identity.username)), tint: DS.Palette.accent, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: identity.name)
                    .font(DS.Font.rowTitle)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(verbatim: identity.username)
                        .font(.system(size: 11, design: .monospaced))
                        .truncationMode(.middle)
                    Text(verbatim: "· \(identity.authLabel)")
                        .font(DS.Font.caption)
                        .layoutPriority(1)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .fixedSize(horizontal: !isCompact, vertical: false)
            Spacer(minLength: DS.Space.xs)
            if users.isEmpty {
                Text("Unused")
                    .font(DS.Font.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            } else if isCompact {
                Text("\(users.count) hosts")
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                DSHostStack(hosts: users, limit: 3)
            }
        }
    }

    private var accessibilitySummary: String {
        var parts = [identity.name, identity.username, identity.authLabel]
        if let keyName { parts.append(keyName) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Identity detail

private struct IdentityDetailView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let identity: Identity
    /// The key it signs in with, when it does and the key still exists.
    let key: SSHKey?
    /// Hosts that sign in with it: their own choice, or their group's default.
    let users: [Host]
    let hosts: [Host]
    let groups: [HostGroup]
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var ownGroups: [HostGroup] {
        identity.id.map { VaultUsage.groups(usingIdentity: $0, groups: groups) } ?? []
    }

    private var usesKey: Bool { identity.authType == "privateKey" }

    private var summary: String {
        var parts: [String] = []
        if !users.isEmpty { parts.append(String(localized: "\(users.count) hosts")) }
        if !ownGroups.isEmpty { parts.append(String(localized: "\(ownGroups.count) groups")) }
        return parts.joined(separator: " · ")
    }

    /// "root · used 40 seconds ago on web-01"; an identity without a key says how it signs in
    /// here too ("postgres · Signs in with a password · Saved"), since it has no credentials card.
    private var subtitle: String {
        var parts = [identity.username]
        if !usesKey {
            parts.append(identity.signInLabel)
            if identity.hasStoredPassword { parts.append(String(localized: "Saved")) }
        }
        if let lastUsed = IdentitiesViewModel.lastUsed(among: users) {
            // `DSRelativeTime`'s wording and rounding: the host's own row and record use it.
            // Its "Just now" is a heading; inside this sentence the first minute has its own words.
            let when = DSRelativeTime.text(for: lastUsed.date)
            let host = lastUsed.host.displayName
            parts.append(Date().timeIntervalSince(lastUsed.date) < 60
                ? String(localized: "used just now on \(host)")
                : String(localized: "used \(when) on \(host)"))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        // A name and words about it: not an address.
        DSDetailHeader(title: identity.name, subtitle: subtitle, isSubtitleMonospaced: false) {
            DSIconTile(.monogram(VaultText.monogram(for: identity.username)), tint: DS.Palette.accent,
                       size: DS.Tile.header, cornerRatio: 0.27)
        } actions: {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            .dsButtonStyle(.prominent)
            .help("Edit Identity")
            DSGlassIconMenu {
                Button {
                    VaultPasteboard.copy(identity.username)
                } label: {
                    Label("Copy Username", systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Identity", systemImage: "trash")
                }
            }
        }

        // A password or the agent is nothing to show: only a key gets a card.
        if usesKey {
            VStack(alignment: .leading, spacing: 0) {
                DSSectionHeader("Credentials")
                VaultHeroCard(fingerprint: key?.fingerprint, allowsSmallImage: true) {
                    credentials
                }
            }
        }

        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Used by These") {
                Text(verbatim: summary)
            }
            DSGroup {
                if users.isEmpty && ownGroups.isEmpty {
                    DSRow {
                        Text("Not used by any host or group")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(users, id: \.connectionKey) { host in
                    VaultHostLink(host: host, detail: note(for: host))
                }
                ForEach(ownGroups) { group in
                    groupRow(group)
                }
            }
        }
    }

    // MARK: Credentials

    /// The key the identity signs in with (only drawn for an identity that uses one).
    private var credentials: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Text(verbatim: identity.signInLabel)
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // The caption stays whole: the chip is what gives way.
                    .layoutPriority(1)
                // Only when there is one: "not saved" is the normal case for a key.
                if identity.hasStoredPassword {
                    // In words while they fit beside the button; the lock alone in a narrow card.
                    ViewThatFits(in: .horizontal) {
                        DSChip("Password saved", symbol: "lock.fill")
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .help("Password saved")
                            .accessibilityLabel(Text("Password saved"))
                    }
                }
                Spacer(minLength: 0)
                if let id = key?.id {
                    Button {
                        appViewModel.reveal(.keys, id: String(id))
                    } label: {
                        HStack(spacing: 4) {
                            Text("Show in Keychain")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .dsButtonStyle(.glass, size: .small)
                    .fixedSize()
                }
            }
            if let key {
                Text(verbatim: key.name)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                    .padding(.top, DS.Space.sm)
                if let fingerprint = key.fingerprint, !fingerprint.isEmpty {
                    Text(verbatim: fingerprint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(fingerprint)
                        .padding(.top, 3)
                }
            } else {
                // The key was deleted, or none was chosen: said, not left blank.
                Label("No key selected", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(DS.Font.body)
                    .padding(.top, DS.Space.xs)
            }
        }
    }

    // MARK: Rows

    /// How many of a group's hosts take the identity from the group ("inherited by 1 of 5"):
    /// the others name an identity, a key or a password of their own.
    private func inheritance(of group: HostGroup) -> String {
        let members = hosts.filter { $0.groupId == group.id }.count
        let inheriting = users.filter { VaultUsage.inheritedGroup(of: $0, groups: groups)?.id == group.id }.count
        return String(localized: "inherited by \(inheriting) of \(members)")
    }

    /// Where the host has the identity from, or when it was last connected to.
    private func note(for host: Host) -> String {
        if let group = VaultUsage.inheritedGroup(of: host, groups: groups) {
            return String(localized: "from group “\(group.name)”")
        }
        guard let date = host.lastConnectedDate else { return String(localized: "Never connected") }
        return DSRelativeTime.text(for: date)
    }

    /// A group whose default identity this is. Not a link: groups have no page of their own.
    private func groupRow(_ group: HostGroup) -> some View {
        HStack(spacing: DS.Space.md) {
            DSIconTile(.symbol("folder.fill"), tint: DSOperatingSystem.local.color, size: DS.Tile.row)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: group.name)
                    .font(DS.Font.body)
                Text(verbatim: String(localized: "Default identity of the group") + " · " + inheritance(of: group))
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, DS.Space.sm)
        .frame(maxWidth: .infinity, minHeight: DS.Height.listRow, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Identity Form Sheet

struct IdentityFormSheet: View {
    let viewModel: IdentitiesViewModel
    let identity: Identity?
    /// Hosts that sign in with the identity being edited: the sheet says a change reaches them.
    var affectedHosts = 0
    var isEmbeddedInInspector: Bool = false
    var onCancel: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var username: String
    @State private var authType: String
    @State private var selectedKeyId: Int64?
    @State private var password = ""
    @State private var hasSavedPassword: Bool
    /// Why the identity could not be saved; shown in the sheet, which stays open.
    @State private var failure: String?

    init(
        viewModel: IdentitiesViewModel,
        identity: Identity?,
        affectedHosts: Int = 0,
        isEmbeddedInInspector: Bool = false,
        onCancel: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.identity = identity
        self.affectedHosts = affectedHosts
        self.isEmbeddedInInspector = isEmbeddedInInspector
        self.onCancel = onCancel
        // Set up front (not in onAppear) so the sheet opens at its final size.
        _name = State(initialValue: identity?.name ?? "")
        _username = State(initialValue: identity?.username ?? "")
        _authType = State(initialValue: identity?.authType ?? "password")
        _selectedKeyId = State(initialValue: identity?.privateKeyId)
        _hasSavedPassword = State(initialValue: !(identity?.passwordEncrypted ?? "").isEmpty)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What the secret is. With a key it is NOT the key's passphrase (that is stored with the
    /// key and answers ssh's passphrase prompt): it answers the server's password prompt, so a
    /// passphrase typed here would be offered to the server. The label says which one it is.
    private var secretTitle: LocalizedStringKey {
        authType == "privateKey" ? "Server Password" : "Password"
    }

    var body: some View {
        if isEmbeddedInInspector {
            DSInspectorPanel(
                identity == nil ? "New Identity" : "Edit Identity",
                onClose: closeForm
            ) {
                formBody
            } footer: {
                HStack {
                    Button("Cancel") { closeForm() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(identity == nil ? "Add" : "Save") {
                        save()
                    }
                    .dsButtonStyle(.prominent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
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
                        Button {
                            save()
                        } label: {
                            if identity == nil {
                                Text("Add")
                            } else {
                                Text("Save")
                            }
                        }
                        .disabled(!isValid)
                    }
                }
        }
    }

    private var formBody: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Production Admin"))
                LabeledContent("Username") {
                    TextField("Username", text: $username, prompt: Text(verbatim: "root"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                }
            } header: {
                if !isEmbeddedInInspector {
                    DSSheetTitle(identity == nil ? LocalizedStringKey("New Identity") : LocalizedStringKey("Edit Identity"))
                }
            }

            Section {
                Picker("Authentication", selection: $authType) {
                    Text("Password").tag("password")
                    Text("Private Key").tag("privateKey")
                    Text("System SSH Agent").tag("agent")
                    if authType == "keyboard-interactive" {
                        Text("Keyboard Interactive").tag("keyboard-interactive")
                    }
                }

                if authType == "privateKey" && !viewModel.availableKeys.isEmpty {
                    Picker("SSH Key", selection: $selectedKeyId) {
                        Text("None").tag(nil as Int64?)
                        ForEach(viewModel.availableKeys) { key in
                            Text(verbatim: "\(key.name) (\(key.type))").tag(key.id as Int64?)
                        }
                    }
                }

                if authType != "agent" {
                    LabeledContent(secretTitle) {
                        ASCIISecureField(hasSavedPassword ? "Saved — type to replace" : "Optional — asked when connecting",
                                         text: $password, isBezeled: false)
                            .accessibilityLabel(Text(secretTitle))
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    if authType == "privateKey" && viewModel.availableKeys.isEmpty {
                        Text("Generate or import keys in Keychain.")
                            .foregroundStyle(.secondary)
                    }
                    if authType == "privateKey" {
                        Text("The key's passphrase is saved with the key, not here.")
                            .foregroundStyle(.secondary)
                    }
                    // Said where the change is made, not under the list of its users.
                    if identity != nil, affectedHosts > 0 {
                        Label("Changing this identity affects \(affectedHosts) hosts", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    if let failure { DSMessage(verbatim: failure) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func save() {
        Task {
            failure = nil
            var i = identity ?? Identity(
                name: "",
                username: "",
                authType: "password",
                createdAt: ""
            )
            i.name = name.trimmingCharacters(in: .whitespaces)
            i.username = username.trimmingCharacters(in: .whitespaces)
            i.authType = authType
            i.privateKeyId = authType == "privateKey" ? selectedKeyId : nil
            if authType == "agent" {
                i.passwordEncrypted = nil
            } else if !password.isEmpty {
                // A password that cannot be encrypted (the vault is not available) is not
                // dropped: the identity would be saved without it and the sheet would close.
                do {
                    i.passwordEncrypted = try await SecureStoreService.shared.encryptStoredValue(password)
                } catch {
                    failure = error.localizedDescription
                    return
                }
            }
            if await viewModel.save(i) {
                closeForm()
            } else {
                failure = viewModel.error
                viewModel.error = nil
            }
        }
    }
}
