import SwiftUI

/// Sheet or Inspector panel for adding/editing a single port forwarding rule
struct PortForwardFormView: View {
    @Environment(\.dismiss) private var dismiss

    let portForward: PortForward?
    let hostId: Int64
    var availableHosts: [Host] = []
    var isEmbeddedInInspector: Bool = false
    var onCancel: (() -> Void)? = nil
    let onSave: (PortForward) -> Void

    @State private var selectedHostId: Int64?
    @State private var type: String
    @State private var localPort: String
    @State private var remoteHost: String
    @State private var remotePort: String
    @State private var enabled: Bool

    init(
        portForward: PortForward? = nil,
        hostId: Int64,
        availableHosts: [Host] = [],
        suggestedHostId: Int64? = nil,
        isEmbeddedInInspector: Bool = false,
        onCancel: (() -> Void)? = nil,
        onSave: @escaping (PortForward) -> Void
    ) {
        self.portForward = portForward
        self.hostId = hostId
        self.availableHosts = availableHosts
        self.isEmbeddedInInspector = isEmbeddedInInspector
        self.onCancel = onCancel
        self.onSave = onSave

        let pf = portForward
        let initialHostId: Int64? = if let pf {
            pf.hostId
        } else if hostId > 0 {
            hostId
        } else {
            suggestedHostId ?? availableHosts.first?.id
        }
        _selectedHostId = State(initialValue: initialHostId)
        _type = State(initialValue: pf?.type ?? "local")
        _localPort = State(initialValue: pf.map { String($0.localPort) } ?? "")
        _remoteHost = State(initialValue: pf?.remoteHost ?? "127.0.0.1")
        _remotePort = State(initialValue: pf.map { String($0.remotePort) } ?? "")
        _enabled = State(initialValue: pf?.enabled ?? true)
    }

    private var effectiveHostId: Int64 {
        if let pf = portForward { return pf.hostId }
        if hostId > 0 { return hostId }
        return selectedHostId ?? 0
    }

    private var needsHostPicker: Bool {
        portForward == nil && hostId <= 0 && !availableHosts.isEmpty
    }

    private var isValid: Bool {
        guard effectiveHostId > 0 else { return false }
        guard let lp = Int(localPort), (1...65535).contains(lp) else { return false }
        if type != "dynamic" {
            guard !remoteHost.isEmpty,
                  let rp = Int(remotePort), (1...65535).contains(rp) else { return false }
        }
        return true
    }

    var body: some View {
        if isEmbeddedInInspector {
            DSInspectorPanel(
                portForward == nil ? "Add Port Forward" : "Edit Port Forward",
                onClose: closeForm
            ) {
                formBody
            } footer: {
                HStack {
                    Button("Cancel") { closeForm() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(portForward == nil ? "Add" : "Save") {
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
                            if portForward == nil {
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
                if needsHostPicker {
                    Picker("Host", selection: $selectedHostId) {
                        ForEach(availableHosts) { host in
                            Text(verbatim: "\(host.displayName) (\(host.addressDescription))")
                                .tag(host.id as Int64?)
                        }
                    }
                }

                Picker("Type", selection: $type) {
                    Text("Local (-L)").tag("local")
                    Text("Remote (-R)").tag("remote")
                    Text("Dynamic (-D)").tag("dynamic")
                }
                .pickerStyle(.segmented)

                // The listening side: this Mac for -L and -D, the host for -R.
                LabeledContent(listenPortLabel) {
                    TextField(listenPortLabel, text: $localPort, prompt: Text(verbatim: "8080"))
                        .labelsHidden()
                        .font(.body.monospaced())
                }

                if type != "dynamic" {
                    LabeledContent("Destination Host") {
                        TextField("Destination Host", text: $remoteHost, prompt: Text(verbatim: "127.0.0.1"))
                            .labelsHidden()
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Destination Port") {
                        TextField("Destination Port", text: $remotePort, prompt: Text(verbatim: "80"))
                            .labelsHidden()
                            .font(.body.monospaced())
                    }
                }

                Toggle("Start automatically when connecting", isOn: $enabled)
            } header: {
                if !isEmbeddedInInspector {
                    DSSheetTitle(portForward == nil ? LocalizedStringKey("Add Port Forward") : LocalizedStringKey("Edit Port Forward"))
                }
            } footer: {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(explanation)
                    // Preview of the SSH flag
                    Text(verbatim: previewFlag)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var listenPortLabel: LocalizedStringKey {
        type == "remote" ? "Remote Port" : "Local Port"
    }

    /// What the chosen kind of forward does, in one sentence.
    private var explanation: LocalizedStringKey {
        switch type {
        case "remote": "Connections to this port on the host are forwarded through your Mac to the destination."
        case "dynamic": "Opens a SOCKS proxy on this port of your Mac; traffic goes out through the host."
        default: "Connections to this port on your Mac are forwarded through the host to the destination."
        }
    }

    private var previewFlag: String {
        let lp = localPort.isEmpty ? "?" : localPort
        switch type {
        case "local":
            return "-L \(lp):\(remoteHost):\(remotePort.isEmpty ? "?" : remotePort)"
        case "remote":
            return "-R \(lp):\(remoteHost):\(remotePort.isEmpty ? "?" : remotePort)"
        case "dynamic":
            return "-D \(lp)"
        default:
            return ""
        }
    }

    private func closeForm() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    private func save() {
        let targetHostId = effectiveHostId
        var pf = portForward ?? PortForward(
            hostId: targetHostId,
            type: type,
            localPort: 0,
            remoteHost: "127.0.0.1",
            remotePort: 0,
            enabled: true,
            createdAt: ""
        )
        pf.type = type
        pf.localPort = Int(localPort) ?? 0
        pf.remoteHost = type == "dynamic" ? "127.0.0.1" : remoteHost
        pf.remotePort = type == "dynamic" ? 0 : (Int(remotePort) ?? 0)
        pf.enabled = enabled
        if pf.hostId == 0 { pf.hostId = targetHostId }

        onSave(pf)
        closeForm()
    }
}
