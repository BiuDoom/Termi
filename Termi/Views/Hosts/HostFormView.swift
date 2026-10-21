import SwiftUI

/// Add / edit host sheet: one grouped form built from standard controls.
struct HostFormView: View {
    @State private var dataGeneration = DataSnapshot.current
    @Environment(\.dismiss) private var dismiss
    /// For the live state in the preview; the form also opens where there is none.
    @Environment(AppViewModel.self) private var appViewModel: AppViewModel?

    private enum KeyChoice: Hashable {
        case noKey
        case agent
        case key(Int64)
    }

    let isEditing: Bool
    var isEmbeddedInInspector: Bool = false
    var onCancel: (() -> Void)? = nil
    let onSave: (HostDraft) -> Void
    private let original: Host

    // General
    @State private var label: String
    @State private var hostname: String
    @State private var port: String
    @State private var groupId: Int64?
    @State private var tags: [String] = []
    @State private var newTag = ""
    // Credentials
    @State private var identityId: Int64?
    @State private var username: String
    @State private var keyChoice: KeyChoice
    @State private var password = ""
    @State private var hasSavedPassword = false
    @State private var clearSavedPassword = false
    // Connection
    @State private var jumpHostId: Int64?
    @State private var agentForwarding: Bool
    @State private var x11Forwarding: Bool
    @State private var portForwards: [PortForward] = []
    @State private var showingPortForwardForm = false
    @State private var editingPortForward: PortForward?
    // Terminal
    @State private var startupSnippetId: Int64?
    @State private var terminalTheme: String
    @State private var color: String
    @State private var notes: String

    // Choices loaded from the database
    @State private var sshKeys: [SSHKey] = []
    @State private var identities: [Identity] = []
    @State private var groups: [HostGroup] = []
    @State private var otherHosts: [Host] = []
    @State private var snippets: [Snippet] = []
    @State private var knownTags: [String] = []
    /// Hints that depend on the loaded choices wait for them, so they don't flash while loading.
    @State private var choicesLoaded = false

    /// The host colour is stored as a hex string; the names are for tooltips and VoiceOver.
    private let colorPresets: [(hex: String, name: LocalizedStringKey)] = [
        ("#3B82F6", "Blue"), ("#10B981", "Green"), ("#F59E0B", "Orange"), ("#EF4444", "Red"),
        ("#8B5CF6", "Purple"), ("#EC4899", "Pink"), ("#06B6D4", "Cyan"), ("#84CC16", "Lime")
    ]

    init(host: Host? = nil, groupId: Int64? = nil, isEmbeddedInInspector: Bool = false,
         onCancel: (() -> Void)? = nil, onSave: @escaping (HostDraft) -> Void) {
        let h = host ?? {
            var fresh = Host.defaultValue()
            fresh.username = ""
            fresh.groupId = groupId
            return fresh
        }()
        self.isEditing = host != nil
        self.isEmbeddedInInspector = isEmbeddedInInspector
        self.onCancel = onCancel
        self.onSave = onSave
        self.original = h

        _label = State(initialValue: h.label)
        _hostname = State(initialValue: h.hostname)
        _port = State(initialValue: String(h.port))
        _groupId = State(initialValue: h.groupId)
        _identityId = State(initialValue: h.identityId)
        _username = State(initialValue: h.username)
        let keyChoice: KeyChoice = switch h.authType {
        case "agent": .agent
        case "privateKey": h.privateKeyId.map { KeyChoice.key($0) } ?? KeyChoice.noKey
        default: KeyChoice.noKey
        }
        _keyChoice = State(initialValue: keyChoice)
        _jumpHostId = State(initialValue: h.jumpHostId)
        _agentForwarding = State(initialValue: h.agentForwarding)
        _x11Forwarding = State(initialValue: h.x11Forwarding)
        _startupSnippetId = State(initialValue: h.startupSnippetId)
        _terminalTheme = State(initialValue: h.terminalTheme ?? "")
        // Empty = automatic: the colour derived from the host's name.
        _color = State(initialValue: h.color ?? "")
        _notes = State(initialValue: h.notes ?? "")
    }

    private var selectedGroup: HostGroup? {
        groups.first { $0.id == groupId }
    }

    private var selectedIdentity: Identity? {
        identities.first { $0.id == identityId }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the form, not in it: it stays in view while the fields scroll.
            previewHeader
            form
            buttonBar
        }
        .frame(width: isEmbeddedInInspector ? nil : 560, height: isEmbeddedInInspector ? nil : 640)
        .frame(maxWidth: isEmbeddedInInspector ? .infinity : nil, maxHeight: isEmbeddedInInspector ? .infinity : nil)
        .task {
            await loadChoices()
            choicesLoaded = true
        }
        // Captured so that body depends on it: otherwise the first sheet is built with the value
        // from before the button set it (an empty "add" form instead of the rule being edited).
        .sheet(isPresented: $showingPortForwardForm) { [editingPortForward] in
            PortForwardFormView(portForward: editingPortForward, hostId: original.id ?? 0) { saved in
                if let index = portForwards.firstIndex(where: { $0.id != nil && $0.id == saved.id }) {
                    portForwards[index] = saved
                } else if let editing = editingPortForward,
                          let index = portForwards.firstIndex(where: { $0.id == nil && $0.localPort == editing.localPort }) {
                    portForwards[index] = saved
                } else {
                    portForwards.append(saved)
                }
            }
        }
    }

    private var form: some View {
        Form {
            generalSection
            credentialsSection
            connectionSection
            organizeSection
            portForwardingSection
            terminalSection
            notesSection
        }
        .formStyle(.grouped)
        // Why Save is disabled, right above the buttons; it floats over the scrolling form.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if savedPasswordHandsOverToGroup != nil && isValid {
                DSMessage("Enter the password again, or forget the saved password", style: .warning)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.bottom, DS.Space.md)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if showsValidationMessage {
                DSMessage("Check the address, port and username", style: .warning)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.bottom, DS.Space.md)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.standard, value: showsValidationMessage)
        .animation(DS.Motion.standard, value: savedPasswordHandsOverToGroup?.id)
    }

    private func cancel() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    /// Cancel and the one primary action, under the form (the same place as in Quick Connect).
    private var buttonBar: some View {
        HStack(spacing: DS.Space.sm) {
            Spacer(minLength: 0)
            Button("Cancel") { cancel() }
                .keyboardShortcut(.cancelAction)
                .dsButtonStyle(.glass)
            Button {
                save()
            } label: {
                if isEditing {
                    Text("Save")
                } else {
                    Text("Add")
                }
            }
            .keyboardShortcut(.defaultAction)
            .dsButtonStyle(.prominent)
            .disabled(!isValid || savedPasswordHandsOverToGroup != nil)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.top, DS.Space.md)
        .padding(.bottom, DS.Space.xl)
    }

    // MARK: - Sections

    /// What the sheet is for, on one line: the host's tile as the fields have it, the title, and
    /// whether it is connected. The name and the address are the first two fields right below.
    /// The way to the host is drawn when it leads through a jump host (its own, or its group's).
    private var previewHeader: some View {
        let preview = previewHost
        let status = appViewModel?.avatarStatus(forHostId: original.id) ?? .none
        let hops = previewHops(for: preview, status: status)
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.md) {
                DSHostAvatar(preview, size: DS.Tile.row, status: status)
                Text(isEditing ? LocalizedStringKey("Edit Host") : LocalizedStringKey("New Host"))
                    .font(isEmbeddedInInspector ? .system(size: 16, weight: .bold) : DS.Font.pageTitle)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: DS.Space.sm)
                if status == .live, let sessions = appViewModel?.liveSessionCount(forHostId: original.id) {
                    DSStatusPill(verbatim: String(localized: "Connected · \(sessions) sessions"))
                }
                if isEmbeddedInInspector {
                    DSRowButton("arrow.right.to.line", help: "Close Inspector (Esc)", action: cancel)
                }
            }
            if DSRouteDiagram.addsSomething(hopCount: hops.count) {
                DSGroup {
                    DSRouteDiagram(hops: hops, activity: status == .live ? .flowing : .idle)
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.sm)
                        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                }
                .transition(.opacity)
            }
        }
        .animation(DS.Motion.standard, value: hops.count)
        .padding(.horizontal, DS.Space.xl)
        .padding(.top, isEmbeddedInInspector ? DS.Space.md : DS.Space.xl)
        .padding(.bottom, DS.Space.xs)
    }

    private var generalSection: some View {
        Section {
            TextField("Label", text: $label,
                      prompt: hostname.isEmpty ? Text("My Server") : Text(verbatim: hostname))
            LabeledContent("Address") {
                TextField("Address", text: $hostname, prompt: Text("192.168.1.100 or example.com"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
            }
            LabeledContent("Port") {
                TextField("Port", text: $port, prompt: Text(verbatim: "22"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
            }
            // Who signs in belongs to where: with an identity the name is the identity's.
            if let identity = selectedIdentity {
                LabeledContent("Username") {
                    Text(verbatim: identity.username)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Username") {
                    TextField("Username", text: $username, prompt: Text(verbatim: usernamePlaceholder))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                }
            }
        }
    }

    private var organizeSection: some View {
        Section {
            Picker("Group", selection: $groupId) {
                Text("No Group").tag(nil as Int64?)
                ForEach(groups) { group in
                    Text(verbatim: group.name).tag(group.id as Int64?)
                }
            }
            tagEditor
        } header: {
            Text("Organize")
        }
    }

    private var credentialsSection: some View {
        Section {
            Picker("Identity", selection: $identityId) {
                Text("None — enter credentials below").tag(nil as Int64?)
                ForEach(identities) { identity in
                    Text(verbatim: "\(identity.name) (\(identity.username))").tag(identity.id as Int64?)
                }
            }

            if selectedIdentity == nil {
                let showsSaved = keepsSavedPassword && !editForgetsSavedPassword
                LabeledContent("Password") {
                    ASCIISecureField(showsSaved ? "Saved — type to replace" : "Optional — asked when connecting",
                                     text: $password, isBezeled: false)
                        // The field only reads its placeholder when it is created.
                        .id(showsSaved)
                        .accessibilityLabel(Text("Password"))
                }
                Picker("SSH Key", selection: $keyChoice) {
                    Text("None").tag(KeyChoice.noKey)
                    Text("System SSH agent / ~/.ssh keys").tag(KeyChoice.agent)
                    if !sshKeys.isEmpty {
                        Divider()
                    }
                    ForEach(sshKeys) { key in
                        if let id = key.id {
                            Text(verbatim: "\(key.name) (\(key.type))").tag(KeyChoice.key(id))
                        }
                    }
                }
            }
            // While the edit forgets it anyway there is nothing to choose — except when the
            // group's identity would take over: then forgetting it is the choice Save waits for.
            if hasSavedPassword && !typesNewPassword
                && (!editForgetsSavedPassword || savedPasswordHandsOverToGroup != nil) {
                Toggle("Forget the saved password", isOn: $clearSavedPassword)
            }
        } header: {
            Text("Credentials")
        } footer: {
            credentialsHints
        }
    }

    @ViewBuilder
    private var credentialsHints: some View {
        if let identity = selectedIdentity {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if editForgetsSavedPassword {
                    Text("Changing the address, port, username, identity or SSH key forgets the saved password.")
                } else if keepsSavedPassword {
                    Text("The saved password is used only for this host. Forget it to use the identity's password.")
                } else {
                    Text("Username and credentials come from the identity “\(identity.name)”.")
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if inheritedUsername != nil || hasNoKeys || editForgetsSavedPassword {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if let group = savedPasswordHandsOverToGroup {
                    Text(verbatim: groupHandoverText(group))
                } else if editForgetsSavedPassword {
                    Text("Changing the address, port, username, identity or SSH key forgets the saved password.")
                }
                if let group = selectedGroup, let groupUser = inheritedUsername {
                    Text("Inherited from group “\(group.name)”: \(groupUser)")
                }
                if hasNoKeys {
                    Text("Generate or import keys in Keychain.")
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What happens to the saved password when the group's identity would take over.
    private func groupHandoverText(_ group: HostGroup) -> String {
        let identity = identities.first { $0.id == group.identityId }
        return String(localized: "The saved password no longer applies, and this host would sign in with the identity “\(identity?.name ?? "")” of the group “\(group.name)” (as \(identity?.username ?? "")). Enter the password again, or forget the saved password.")
    }

    private var connectionSection: some View {
        Section {
            Picker("Jump Host", selection: $jumpHostId) {
                Text(verbatim: groupJumpDescription).tag(nil as Int64?)
                ForEach(otherHosts) { host in
                    Text(verbatim: host.label.isEmpty ? host.hostname : host.label).tag(host.id as Int64?)
                }
            }
            Toggle("Agent forwarding", isOn: $agentForwarding)
                .help("Forward your SSH keys to this host so you can hop further from it")
            Toggle("X11 forwarding", isOn: $x11Forwarding)
                .help("Requires XQuartz")
        } header: {
            Text("Connection")
        } footer: {
            Text("Connect through another host first (ProxyJump). Jump hosts can be chained.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var portForwardingSection: some View {
        Section {
            ForEach(Array(portForwards.enumerated()), id: \.offset) { index, rule in
                portForwardRow(rule, at: index)
            }
            Button {
                editingPortForward = nil
                showingPortForwardForm = true
            } label: {
                Label("Add Rule…", systemImage: "plus")
            }
        } header: {
            Text("Port Forwarding")
        } footer: {
            Group {
                if portForwards.isEmpty {
                    Text("No port forwarding rules. Enabled rules start when you connect.")
                } else {
                    Text("Enabled rules start when you connect.")
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func portForwardRow(_ rule: PortForward, at index: Int) -> some View {
        HStack(spacing: DS.Space.xs) {
            // Bounds-checked: the row can outlive its index for a moment while a rule is removed.
            Toggle(isOn: Binding(
                get: { portForwards.indices.contains(index) && portForwards[index].enabled },
                set: { if portForwards.indices.contains(index) { portForwards[index].enabled = $0 } }
            )) {
                Text(verbatim: rule.sshForward.displayDescription)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .toggleStyle(.checkbox)
            .help("Start automatically when connecting")

            Spacer(minLength: DS.Space.sm)

            DSRowButton("pencil", help: "Edit") {
                editPortForward(rule)
            }
            DSRowButton("trash", help: "Delete", role: .destructive) {
                removePortForward(at: index)
            }
        }
        .contextMenu {
            Button {
                editPortForward(rule)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                removePortForward(at: index)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var terminalSection: some View {
        Section {
            Picker("Startup Snippet", selection: $startupSnippetId) {
                Text("None").tag(nil as Int64?)
                ForEach(snippets) { snippet in
                    Text(verbatim: snippet.name).tag(snippet.id as Int64?)
                }
            }
            Picker("Theme", selection: $terminalTheme) {
                Text("Default").tag("")
                ForEach(TerminalTheme.builtIn) { theme in
                    Text(verbatim: theme.name).tag(theme.id)
                }
            }
            LabeledContent("Color") {
                HStack(spacing: DS.Space.sm) {
                    automaticSwatch
                    ForEach(colorPresets, id: \.hex) { preset in
                        colorSwatch(hex: preset.hex, name: preset.name)
                    }
                }
            }
        } header: {
            Text("Terminal")
        }
    }

    private func colorSwatch(hex: String, name: LocalizedStringKey) -> some View {
        let isSelected = color == hex
        return Button {
            color = hex
        } label: {
            Circle()
                .fill(DS.Palette.tint(hex: hex) ?? .accentColor)
                .frame(width: 20, height: 20)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// No chosen colour: the tile takes the colour derived from the host's name.
    private var automaticSwatch: some View {
        let isSelected = color.isEmpty
        return Button {
            color = ""
        } label: {
            Circle()
                .fill(automaticTint)
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: isSelected ? "checkmark" : "wand.and.stars")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Automatic")
        .accessibilityLabel(Text("Automatic"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var notesSection: some View {
        Section {
            TextEditor(text: $notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(height: 72)
                .accessibilityLabel(Text("Notes"))
        } header: {
            Text("Notes")
        }
    }

    // MARK: - Tags

    @ViewBuilder
    private var tagEditor: some View {
        LabeledContent("Tags") {
            HStack(spacing: DS.Space.sm) {
                TextField("Tags", text: $newTag, prompt: Text("Add a tag and press Return"))
                    .labelsHidden()
                    .onSubmit(addTag)
                let suggestions = knownTags.filter { !tags.contains($0) }
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { tag in
                            Button {
                                withAnimation(DS.Motion.standard) { tags.append(tag) }
                            } label: {
                                Text(verbatim: tag)
                            }
                        }
                    } label: {
                        Label("Existing tags", systemImage: "tag")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Existing tags")
                }
            }
        }
        if !tags.isEmpty {
            FlowLayout(spacing: DS.Space.sm) {
                ForEach(tags, id: \.self) { tag in
                    tagChip(tag)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tagChip(_ tag: String) -> some View {
        let tint = DS.Palette.tint(hex: TagRepository.color(for: tag)) ?? .accentColor
        return HStack(spacing: DS.Space.xs) {
            Text(verbatim: tag)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Button {
                withAnimation(DS.Motion.standard) { tags.removeAll { $0 == tag } }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel(Text("Remove tag \(tag)"))
        }
        .padding(.leading, DS.Space.sm)
        .padding(.trailing, DS.Space.xs + DS.Space.xxs)
        .padding(.vertical, 3)
        .background(tint.opacity(0.2), in: Capsule())
    }

    // MARK: - Helpers

    private var usernamePlaceholder: String {
        if let groupUser = selectedGroup?.username, !groupUser.isEmpty { return groupUser }
        return "root"
    }

    /// The group's default username, while this host does not set its own.
    private var inheritedUsername: String? {
        guard username.isEmpty, let groupUser = selectedGroup?.username, !groupUser.isEmpty else { return nil }
        return groupUser
    }

    private var keepsSavedPassword: Bool {
        hasSavedPassword && !clearSavedPassword
    }

    /// A password typed here replaces the saved one (only without an identity: with one, the
    /// field is not shown).
    private var typesNewPassword: Bool {
        selectedIdentity == nil && !password.isEmpty
    }

    /// The saved password belongs to the login the host had when the form opened. This edit
    /// changes that login (address, port, account, identity, key or agent), so Save forgets it:
    /// a password typed for one account is not sent to another (`HostRepository.save`).
    private var editForgetsSavedPassword: Bool {
        guard keepsSavedPassword, !typesNewPassword, original.id != nil, choicesLoaded else { return false }
        return passwordContext(of: original) != passwordContext(of: draftHost())
    }

    /// Forgetting it would make the host sign in with its group's identity — another account,
    /// which nobody chose here. Save waits until a password is typed or "Forget" is chosen.
    private var savedPasswordHandsOverToGroup: HostGroup? {
        guard editForgetsSavedPassword else { return nil }
        let draft = draftHost()
        guard draft.identityId == nil, let group = groups.first(where: { $0.id == draft.groupId }),
              SSHPasswordContext.identityId(for: draft, group: group, hasSavedPassword: false) != nil else {
            return nil
        }
        return group
    }

    /// The login SSH would use for `host` while it has a saved password, as the repository
    /// compares it.
    private func passwordContext(of host: Host) -> SSHPasswordContext {
        SSHPasswordContext.resolve(host: host, group: groups.first { $0.id == host.groupId },
                                   hasSavedPassword: true) { id in identities.first { $0.id == id } }
    }

    private var hasNoKeys: Bool {
        choicesLoaded && sshKeys.isEmpty
    }

    /// What the tile shows when no colour is chosen: the colour of the host's system.
    private var automaticTint: Color {
        var plain = original
        plain.color = nil
        return plain.tint
    }

    /// The host as the fields have it so far, for the preview (never saved).
    private var previewHost: Host {
        var preview = original
        let address = hostname.trimmingCharacters(in: .whitespaces)
        let name = label.trimmingCharacters(in: .whitespaces)
        preview.hostname = address
        preview.label = !name.isEmpty ? name : (address.isEmpty ? String(localized: "New Host") : address)
        preview.color = color.isEmpty ? nil : color
        preview.groupId = groupId
        preview.jumpHostId = jumpHostId
        return preview
    }

    /// This Mac, the jump hosts the fields lead through, the host.
    private func previewHops(for preview: Host, status: DSHostAvatar.Status) -> [DSRouteDiagram.Hop] {
        var hops = preview.routeHops(hosts: otherHosts + [preview], groups: groups)
        if !hops.isEmpty {
            hops[hops.count - 1].status = status
        }
        return hops
    }

    private var groupJumpDescription: String {
        if let jumpId = selectedGroup?.jumpHostId,
           let jump = otherHosts.first(where: { $0.id == jumpId }) {
            return String(localized: "Group default (\(jump.label))")
        }
        return String(localized: "None — connect directly")
    }

    private var isValid: Bool {
        guard SSHConnectionSpec.isSafeValue(hostname),
              let portNumber = Int(port), (1...65535).contains(portNumber) else { return false }
        if selectedIdentity == nil && !username.isEmpty && !SSHConnectionSpec.isSafeValue(username) {
            return false
        }
        return true
    }

    private var showsValidationMessage: Bool {
        !isValid && !hostname.isEmpty
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tag.isEmpty && !tags.contains(tag) {
            tags.append(tag)
        }
        newTag = ""
    }

    private func editPortForward(_ rule: PortForward) {
        editingPortForward = rule
        showingPortForwardForm = true
    }

    private func removePortForward(at index: Int) {
        guard portForwards.indices.contains(index) else { return }
        _ = withAnimation(DS.Motion.standard) {
            portForwards.remove(at: index)
        }
    }

    private func loadChoices() async {
        async let keys = try? SSHKeyRepository.shared.fetchAll()
        async let loadedIdentities = try? IdentityRepository.shared.fetchAll()
        async let loadedGroups = try? GroupRepository.shared.fetchAll()
        async let hosts = try? HostRepository.shared.fetchAll()
        async let loadedSnippets = try? SnippetRepository.shared.fetchAll()
        async let allTags = try? TagRepository.shared.fetchAll()
        sshKeys = await keys ?? []
        identities = await loadedIdentities ?? []
        groups = await loadedGroups ?? []
        otherHosts = (await hosts ?? []).filter { $0.id != original.id }
        snippets = await loadedSnippets ?? []
        knownTags = (await allTags ?? []).map(\.name)

        if let hostId = original.id {
            portForwards = (try? await PortForwardRepository.shared.fetchForHost(hostId)) ?? []
            tags = ((try? await TagRepository.shared.tags(forHost: hostId)) ?? []).map(\.name)
            hasSavedPassword = ((try? await SecureStoreService.shared.getHostPassword(hostId: hostId)) ?? nil)?.isEmpty == false
        }
    }

    /// The host as Save writes it (the password aside).
    private func draftHost() -> Host {
        var host = original
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        host.hostname = trimmedHost
        host.label = label.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedHost : label
        host.port = Int(port) ?? 22
        host.groupId = groupId
        host.identityId = identityId
        host.jumpHostId = jumpHostId
        host.agentForwarding = agentForwarding
        host.x11Forwarding = x11Forwarding
        host.startupSnippetId = startupSnippetId
        host.terminalTheme = terminalTheme.isEmpty ? nil : terminalTheme
        host.color = color.isEmpty ? nil : color
        host.notes = notes.isEmpty ? nil : notes

        if identityId != nil {
            host.username = ""
            host.authType = "password"
            host.privateKeyId = nil
        } else {
            host.username = username.trimmingCharacters(in: .whitespaces)
            switch keyChoice {
            case .noKey:
                host.authType = "password"
                host.privateKeyId = nil
            case .agent:
                host.authType = "agent"
                host.privateKeyId = nil
            case .key(let id):
                host.authType = "privateKey"
                host.privateKeyId = id
            }
        }
        return host
    }

    private func save() {
        addTag()
        let host = draftHost()
        var passwordChange: HostDraft.PasswordChange = clearSavedPassword ? .clear : .keep
        if typesNewPassword {
            passwordChange = .set(password)
        }
        onSave(HostDraft(host: host, portForwards: portForwards, tags: tags, passwordChange: passwordChange, dataGeneration: dataGeneration))
        cancel()
    }
}

/// Simple wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
