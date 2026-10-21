import SwiftUI

/// Quick connect dialog: type `user@host:port`, connect. Nothing is saved. What the address left
/// out (the user, the port) is shown as it will be filled in; a complete address is not repeated.
struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var appViewModel

    @State private var connectionString = ""
    @State private var password = ""
    @State private var parseError: String?
    @State private var recent: [ConnectionLog] = []
    @FocusState private var addressFocused: Bool
    @State private var didConnect = false

    private var trimmedInput: String {
        connectionString.trimmingCharacters(in: .whitespaces)
    }

    private var parsed: Host? {
        QuickConnectParser.parse(connectionString)
    }

    /// The saved host at the typed address: it connects as itself, with its own credentials.
    private var savedHost: Host? {
        guard !trimmedInput.isEmpty else { return nil }
        return HostsViewModel.savedHost(matching: trimmedInput, in: appViewModel.hostsPage.hosts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Quick Connect")
                .font(DS.Font.pageTitle)
                .accessibilityAddTraits(.isHeader)

            addressField
            if showsParseLine {
                parseLine
                    .transition(.opacity)
            }

            if let savedHost {
                VStack(alignment: .leading, spacing: 0) {
                    DSSectionHeader("Uses the saved host")
                    DSGroup {
                        DSHostRow(savedHost, status: appViewModel.avatarStatus(forHostId: savedHost.id)) {
                            DSRelativeTime(savedHost.lastConnectedDate)
                        }
                        .padding(.horizontal, DS.Space.md)
                        .frame(height: DS.Height.listRow)
                    }
                }
            } else {
                DSGroup {
                    DSKeyValueRow("Password") {
                        ASCIISecureField("Optional — asked when connecting", text: $password, isBezeled: false) { connect() }
                            .accessibilityLabel(Text("Password"))
                    }
                }
            }

            if let error = parseError {
                DSMessage(verbatim: error)
            }

            if !recent.isEmpty {
                recentSection
            }

            HStack(spacing: DS.Space.sm) {
                // Not true while the address is a saved host's.
                if savedHost == nil {
                    Text("Not saved as a host")
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.sm)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .dsButtonStyle(.glass)
                Button {
                    connect()
                } label: {
                    Label("Connect", systemImage: "bolt.fill")
                }
                .keyboardShortcut(.defaultAction)
                .dsButtonStyle(.prominent)
                .disabled(trimmedInput.isEmpty)
            }
            .padding(.top, DS.Space.xs)
        }
        .padding(DS.Space.xl)
        .frame(width: 480)
        .animation(DS.Motion.standard, value: showsParseLine)
        .task {
            await appViewModel.ensureHostsLoaded()
            recent = await appViewModel.hostsPage.recentQuickConnections()
        }
        .onAppear {
            addressFocused = true
            #if DEBUG
            // -debugQuickConnectText user@host:port: the dialog with an address typed, for screenshots.
            if let text = AppProfile.arguments.string(forKey: "debugQuickConnectText"), connectionString.isEmpty {
                connectionString = text
            }
            #endif
        }
    }

    /// The one field of the dialog, large: the address as it would be typed after `ssh`.
    private var addressField: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return HStack(spacing: DS.Space.card) {
            Image(systemName: "terminal")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Address", text: $connectionString, prompt: Text(verbatim: "user@hostname:port"))
                .textFieldStyle(.plain)
                .font(.system(size: 20, design: .monospaced))
                .autocorrectionDisabled()
                .focused($addressFocused)
                .onSubmit { connect() }
                .onChange(of: connectionString) { _, _ in
                    parseError = nil
                }
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(height: 52)
        .background(DS.Palette.card, in: shape)
        .overlay(shape.strokeBorder(addressFocused ? AnyShapeStyle(DS.Palette.accent.opacity(0.7)) : AnyShapeStyle(DS.Palette.hairline),
                                    lineWidth: addressFocused ? 1.5 : 1))
        .background(shape.stroke(DS.Palette.accent.opacity(addressFocused ? 0.28 : 0), lineWidth: 7))
    }

    /// What the address left out and the connection will use; nil for a complete address, for a
    /// saved host (its row below says who signs in where) and for one that does not parse.
    private var filledDefaults: (user: Bool, port: Bool)? {
        guard savedHost == nil, let filled = QuickConnectParser.defaults(filledIn: connectionString),
              filled.user || filled.port else { return nil }
        return filled
    }

    /// The line under the field is there for what the field does not say: a default that was
    /// filled in, or that the text is not an address. Empty and complete input need neither.
    private var showsParseLine: Bool {
        filledDefaults != nil || (parsed == nil && !trimmedInput.isEmpty)
    }

    @ViewBuilder
    private var parseLine: some View {
        if let parsed, let filled = filledDefaults {
            HStack(spacing: DS.Space.sm) {
                if filled.user {
                    part("User", parsed.username)
                }
                if filled.port {
                    part("Port", String(parsed.port))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.xs)
        } else {
            Text("Format: user@host[:port]")
                .font(.system(size: 12))
                .foregroundStyle(DS.Palette.warning.mix(with: .primary, by: 0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.xs)
        }
    }

    /// A value the address did not carry: its name, then the value as it will be used.
    private func part(_ caption: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(caption)
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 9)
                .frame(height: DS.Height.chip)
                .background(DS.Palette.cardRaised, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(DS.Palette.hairline))
        }
        .accessibilityElement(children: .combine)
    }

    /// Addresses connected to this way before; a click fills the field.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Recent") {
                Text("Click to fill in")
            }
            DSGroup {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, log in
                    Button {
                        connectionString = log.hostLabel
                        addressFocused = true
                    } label: {
                        DSRow(isCompact: true) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(DS.Palette.cardRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .accessibilityHidden(true)
                            Text(verbatim: log.hostLabel)
                                .font(DS.Font.mono)
                                .truncationMode(.middle)
                            Spacer(minLength: DS.Space.sm)
                            DSRelativeTime(log.dsStartedAt)
                                .font(DS.Font.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .background(log.hostLabel == trimmedInput ? Color.primary.opacity(0.06) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func connect() {
        // Return in the field and the default button can both answer one key press: one
        // dialog opens one session.
        guard !didConnect else { return }
        guard let host = parsed else {
            parseError = String(localized: "Invalid format. Use user@hostname or user@hostname:port")
            return
        }
        if let savedHost {
            appViewModel.connect(to: savedHost)
        } else {
            appViewModel.addQuickConnectTab(host: host, password: password.isEmpty ? nil : password)
        }
        didConnect = true
        appViewModel.selectedSidebar = .terminal
        dismiss()
    }
}
