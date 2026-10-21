import SwiftUI

/// Add / edit group, including the defaults its hosts inherit (Termius-style group settings).
struct GroupFormView: View {
    @Environment(\.dismiss) private var dismiss

    let group: HostGroup?
    var isEmbeddedInInspector: Bool = false
    var onCancel: (() -> Void)? = nil
    let onSave: (HostGroup) -> Void

    @State private var name: String
    @State private var username: String
    @State private var identityId: Int64?
    @State private var jumpHostId: Int64?
    @State private var identities: [Identity] = []
    @State private var hosts: [Host] = []
    @FocusState private var isNameFocused: Bool

    init(group: HostGroup? = nil, isEmbeddedInInspector: Bool = false,
         onCancel: (() -> Void)? = nil, onSave: @escaping (HostGroup) -> Void) {
        self.group = group
        self.isEmbeddedInInspector = isEmbeddedInInspector
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: group?.name ?? "")
        _username = State(initialValue: group?.username ?? "")
        _identityId = State(initialValue: group?.identityId)
        _jumpHostId = State(initialValue: group?.jumpHostId)
    }

    private var isUsernameValid: Bool {
        username.isEmpty || SSHConnectionSpec.isSafeValue(username)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && isUsernameValid
    }

    var body: some View {
        Group {
            if isEmbeddedInInspector {
                DSInspectorPanel(
                    group == nil ? "New Group" : "Edit Group",
                    onClose: cancel
                ) {
                    formSections
                } footer: {
                    HStack(spacing: DS.Space.sm) {
                        Spacer(minLength: 0)
                        Button("Cancel") { cancel() }
                            .keyboardShortcut(.cancelAction)
                            .dsButtonStyle(.glass)
                        Button(group == nil ? "Add" : "Save") { save() }
                            .keyboardShortcut(.defaultAction)
                            .dsButtonStyle(.prominent)
                            .disabled(!isValid)
                    }
                }
            } else {
                Form {
                    formSections
                }
                .formStyle(.grouped)
                .frame(width: 460)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { cancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            save()
                        } label: {
                            if group == nil {
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
        .onAppear { isNameFocused = true }
        .task {
            identities = (try? await IdentityRepository.shared.fetchAll()) ?? []
            hosts = (try? await HostRepository.shared.fetchAll()) ?? []
        }
    }

    @ViewBuilder
    private var formSections: some View {
        if isEmbeddedInInspector {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                DSGroup {
                    DSRow {
                        DSKeyLabel("Name")
                        TextField("Name", text: $name, prompt: Text("Production"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .focused($isNameFocused)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    DSSectionHeader("Defaults for hosts in this group")
                    DSGroup {
                        DSRow {
                            DSKeyLabel("Username")
                            TextField("Username", text: $username, prompt: Text("None"))
                                .labelsHidden()
                                .font(.body.monospaced())
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                        }
                        DSRow {
                            DSKeyLabel("Identity")
                            Spacer(minLength: 0)
                            Picker("Identity", selection: $identityId) {
                                Text("None").tag(nil as Int64?)
                                ForEach(identities) { identity in
                                    Text(verbatim: "\(identity.name) (\(identity.username))").tag(identity.id as Int64?)
                                }
                            }
                            .labelsHidden()
                        }
                        DSRow {
                            DSKeyLabel("Jump Host")
                            Spacer(minLength: 0)
                            Picker("Jump Host", selection: $jumpHostId) {
                                Text("None").tag(nil as Int64?)
                                ForEach(hosts) { host in
                                    Text(verbatim: host.label.isEmpty ? host.hostname : host.label).tag(host.id as Int64?)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    Text("Hosts use these values when they don't set their own.")
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, DS.Space.xs)
                    if !isUsernameValid {
                        DSMessage("Check the username", style: .warning)
                            .padding(.top, DS.Space.xs)
                    }
                }
            }
        } else {
            Section {
                TextField("Name", text: $name, prompt: Text("Production"))
                    .focused($isNameFocused)
            } header: {
                DSSheetTitle(group == nil ? LocalizedStringKey("New Group") : LocalizedStringKey("Edit Group"))
            }

            Section {
                LabeledContent("Username") {
                    TextField("Username", text: $username, prompt: Text("None"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                }
                Picker("Identity", selection: $identityId) {
                    Text("None").tag(nil as Int64?)
                    ForEach(identities) { identity in
                        Text(verbatim: "\(identity.name) (\(identity.username))").tag(identity.id as Int64?)
                    }
                }
                Picker("Jump Host", selection: $jumpHostId) {
                    Text("None").tag(nil as Int64?)
                    ForEach(hosts) { host in
                        Text(verbatim: host.label.isEmpty ? host.hostname : host.label).tag(host.id as Int64?)
                    }
                }
            } header: {
                Text("Defaults for hosts in this group")
            } footer: {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Text("Hosts use these values when they don't set their own.")
                        .foregroundStyle(.secondary)
                    if !isUsernameValid {
                        DSMessage("Check the username", style: .warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func cancel() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    private func save() {
        var g = group ?? HostGroup(name: "", sortOrder: 0, createdAt: TimestampFormatter.now())
        g.name = name.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        g.username = trimmedUser.isEmpty ? nil : trimmedUser
        g.identityId = identityId
        g.jumpHostId = jumpHostId
        onSave(g)
        cancel()
    }
}
