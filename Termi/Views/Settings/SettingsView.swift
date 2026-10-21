import SwiftUI
import Sparkle

/// The Settings window (⌘,): the standard macOS layout — one toolbar tab per area, each a
/// column of grouped rows. The window follows the height of the pane on screen.
struct SettingsView: View {
    @Environment(SecurityViewModel.self) private var securityVM
    @State private var viewModel = SettingsViewModel()
    @State private var showingMasterPasswordSetup = false
    @State private var monospacedFonts: [TerminalPreferences.FontChoice] = []
    /// Reopens on the pane that was showing last, like the system's own settings windows.
    @AppStorage("settingsSelectedTab", store: AppProfile.defaults) private var selectedTab = SettingsTab.general

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsPane(viewModel: viewModel, showingMasterPasswordSetup: $showingMasterPasswordSetup)
            }
            Tab("Terminal", systemImage: "terminal", value: SettingsTab.terminal) {
                TerminalSettingsPane(viewModel: viewModel, fonts: monospacedFonts)
            }
            Tab("Import / Export", systemImage: "square.and.arrow.up.on.square", value: SettingsTab.importExport) {
                ImportExportSettingsPane(viewModel: viewModel)
            }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath", value: SettingsTab.sync) {
                SyncSettingsPane(viewModel: viewModel)
            }
            Tab("Backup", systemImage: "externaldrive", value: SettingsTab.backup) {
                BackupSettingsPane(viewModel: viewModel)
            }
            Tab("Notifications", systemImage: "bell", value: SettingsTab.notifications) {
                NotificationSettingsPane(viewModel: viewModel)
            }
            Tab("About", systemImage: "info.circle", value: SettingsTab.about) {
                AboutSettingsPane()
            }
        }
        .preferredColorScheme(colorScheme(for: appearance))
        .sheet(isPresented: $viewModel.showingSyncPassword) {
            SyncPasswordSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingMasterPasswordSetup) {
            MasterPasswordSetupView(securityVM: securityVM)
        }
        .task {
            await viewModel.loadSettings()
            monospacedFonts = TerminalPreferences.availableMonospacedFonts()
        }
        // A result line belongs to the pane whose action produced it.
        .onChange(of: selectedTab) { _, _ in
            viewModel.clearResults()
        }
        // A restored backup brings its own master password, or none: the Security section
        // shows what the database holds now. (A host import reports here too; the check is
        // a single read.)
        .onChange(of: viewModel.importResult) { _, result in
            guard result != nil else { return }
            Task { await securityVM.checkMasterPassword() }
        }
    }

    private var appearance: String {
        #if DEBUG
        // -debugAppearance Light|Dark reaches this window too, without being stored.
        if let appearance = AppProfile.arguments.string(forKey: "debugAppearance") { return appearance }
        #endif
        return viewModel.terminalTheme
    }

    private func colorScheme(for theme: String) -> ColorScheme? {
        switch theme {
        case "Dark": return .dark
        case "Light": return .light
        default: return nil
        }
    }
}

private enum SettingsTab: String {
    case general, terminal, importExport, sync, backup, notifications, about
}

// MARK: - Pane layout

@MainActor
private enum SettingsLayout {
    static let width: CGFloat = 760

    /// Tallest a pane gets before it scrolls inside the window instead of growing it: a
    /// comfortable settings-window height, kept within the screen (less the window's title
    /// bar and tab strip).
    static var maxPaneHeight: CGFloat {
        let available = (NSScreen.main?.visibleFrame.height ?? 800) - 110
        return min(640, max(360, available))
    }
}

/// Gives a pane its own height up to `maxHeight`; a longer pane gets `maxHeight` and scrolls.
private struct PaneHeightLayout: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let pane = subviews.first else { return .zero }
        let natural = pane.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A pane of the Settings window: sections of grouped rows on the window's stage, fixed width,
/// as tall as its content — the window follows — up to `SettingsLayout.maxPaneHeight`, beyond
/// which it scrolls.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        PaneHeightLayout(maxHeight: SettingsLayout.maxPaneHeight) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    content
                }
                .padding(.horizontal, DS.Space.xxl)
                .padding(.top, DS.Space.sm)
                .padding(.bottom, DS.Space.xxl)
            }
        }
        .frame(width: SettingsLayout.width)
        .dsStageBackground()
        .modifier(SettingsDebugControlState())
    }
}

/// `-debugActive YES` draws the panes as in a key window (accent switches, the blue primary
/// button): screenshots are taken while the screen is locked, where no window becomes key.
/// Debug builds only.
private struct SettingsDebugControlState: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if AppProfile.arguments.bool(forKey: "debugActive") {
            content.environment(\.controlActiveState, .key)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// A titled group of rows, with explanation lines and messages underneath.
private struct SettingsSection<Trailing: View, Content: View, Footer: View>: View {
    private let title: LocalizedStringKey
    private let trailing: Trailing
    private let content: Content
    private let footer: Footer

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader(title) { trailing }
            DSGroup { content }
            footer
                .font(DS.Font.caption)
                .padding(.horizontal, DS.Space.xs)
                .padding(.top, DS.Space.sm)
        }
    }
}

extension SettingsSection where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(title, content: content, footer: footer) { EmptyView() }
    }
}

extension SettingsSection where Trailing == EmptyView, Footer == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, footer: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// The name of a setting and, under it, what it does.
private struct SettingsRowLabel: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var isEmphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .fontWeight(isEmphasized ? .semibold : .regular)
            if let subtitle {
                Text(subtitle)
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    // An explanation may take a second line; nothing else in a row wraps.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Name ………… control": the control at the trailing edge.
private struct SettingsRow<Control: View>: View {
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    private let isEmphasized: Bool
    private let control: Control

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, isEmphasized: Bool = false,
         @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.isEmphasized = isEmphasized
        self.control = control()
    }

    var body: some View {
        DSRow {
            SettingsRowLabel(title: title, subtitle: subtitle, isEmphasized: isEmphasized)
            Spacer(minLength: DS.Space.md)
            control
        }
    }
}

/// A switch with its name (and explanation) as the label, so the whole row is one control.
private struct SettingsToggleRow: View {
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    @Binding private var isOn: Bool

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        DSRow {
            Toggle(isOn: $isOn) {
                SettingsRowLabel(title: title, subtitle: subtitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
        }
    }
}

private extension SettingsViewModel {
    var hasStatus: Bool {
        isProcessing || error != nil || importResult != nil || exportResult != nil
    }

    func clearResults() {
        error = nil
        importResult = nil
        exportResult = nil
    }

    /// Starts an import / export / backup action with a clean slate, so that the result line
    /// under the buttons is the outcome of this action only.
    func start(_ action: () -> Void) {
        clearResults()
        action()
    }
}

/// Progress and outcome of the import / export / sync / backup actions, shown under the
/// section that started them.
private struct SettingsStatusView: View {
    let viewModel: SettingsViewModel

    var body: some View {
        if viewModel.isProcessing {
            ProgressView()
                .controlSize(.small)
        }
        if let error = viewModel.error {
            DSMessage(verbatim: error)
        }
        if let result = viewModel.importResult {
            DSMessage(verbatim: result, style: .info)
        }
        if let result = viewModel.exportResult {
            DSMessage(verbatim: result, style: .info)
        }
    }
}

/// Section footer: explanation lines and messages, leading-aligned across the section.
private struct SettingsFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel
    @Binding var showingMasterPasswordSetup: Bool
    @Environment(SecurityViewModel.self) private var securityVM
    @State private var showingRemoveConfirm = false
    /// Read where it is written: the close confirmation's "Don't ask again" sets the same key.
    @AppStorage("suppressSSHCloseConfirmation", store: AppProfile.defaults) private var suppressCloseConfirmation = false
    /// Read by `HostSystemProbe` each time a host connects.
    @AppStorage(HostSystemProbe.settingKey, store: AppProfile.defaults) private var detectHostSystem = true

    var body: some View {
        SettingsPage {
            SettingsSection("Appearance") {
                SettingsRow("App Appearance") {
                    Picker("App Appearance", selection: $viewModel.terminalTheme) {
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                        Text("System").tag("System")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                SettingsRow("Language") {
                    Picker("Language", selection: $viewModel.appLanguage) {
                        Text("Follow System").tag("system")
                        Divider()
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "简体中文").tag("zh-Hans")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } footer: {
                SettingsFooter {
                    Text("Menus, system dialogs, dates and some messages switch language the next time Termi starts.")
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection("Connection") {
                SettingsToggleRow("Reconnect automatically when the connection drops", isOn: $viewModel.autoReconnect)
                SecondsStepperRow(title: "Connection Timeout", value: $viewModel.connectionTimeout, range: 5...60)
                SecondsStepperRow(title: "Keep-alive Interval", value: $viewModel.keepAliveInterval, range: 5...120)
                SettingsToggleRow("Apply options from ~/.ssh/config",
                                  subtitle: "Lets hosts use settings such as legacy algorithms from your own SSH config; hosts that use the system SSH agent also take its IdentityAgent and IdentityFile.",
                                  isOn: $viewModel.useSSHConfigOptions)
                SettingsToggleRow("Confirm before closing SSH session", isOn: Binding(
                    get: { !suppressCloseConfirmation },
                    set: { suppressCloseConfirmation = !$0 }
                ))
                SettingsToggleRow("Read a host's system after it connects",
                                  subtitle: "Runs one read-only command, once per host, to show its distribution on the host's tile.",
                                  isOn: $detectHostSystem)
            }

            securitySection
        }
        .alert("Remove Master Password", isPresented: $showingRemoveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await securityVM.removeMasterPassword() }
            }
        } message: {
            Text("Saved passwords and SSH keys are kept. They will be protected only by the key file on this Mac, and Termi can no longer be locked.")
        }
    }

    private var securitySection: some View {
        SettingsSection("Security") {
            SettingsRow("Master Password", subtitle: securityVM.hasMasterPassword
                        ? "Saved passwords and SSH keys are encrypted with the master password."
                        : "Saved passwords and SSH keys are encrypted with a key file on this Mac. Set a master password to protect them and to lock Termi.") {
                if securityVM.hasMasterPassword {
                    HStack(spacing: DS.Space.sm) {
                        Button("Lock Now") {
                            securityVM.lock()
                        }
                        .help("Lock the app immediately")

                        // What removing costs is spelled out in the confirmation.
                        Button("Remove…", role: .destructive) {
                            showingRemoveConfirm = true
                        }
                        .help("Remove Master Password")
                    }
                    .dsButtonStyle(.glass, size: .small)
                } else {
                    Button("Set Up…") {
                        showingMasterPasswordSetup = true
                    }
                    .dsButtonStyle(.glass, size: .small)
                    .help("Set Master Password")
                }
            }
        } footer: {
            if let error = securityVM.error {
                SettingsFooter {
                    DSMessage(verbatim: error)
                }
            }
        }
    }
}

/// "Connection Timeout        10s ⌃⌄" — the value, then the stepper, at the trailing edge.
private struct SecondsStepperRow: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        SettingsRow(title) {
            HStack(spacing: DS.Space.sm) {
                Text("\(value)s")
                    .monospacedDigit()
                    .accessibilityHidden(true)
                Stepper(title, value: $value, in: range, step: 5)
                    .labelsHidden()
                    .accessibilityValue(Text("\(value)s"))
            }
        }
    }
}

// MARK: - Terminal

private struct TerminalSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel
    let fonts: [TerminalPreferences.FontChoice]

    private static let scrollbackChoices = [1_000, 10_000, 50_000, 100_000]

    /// The chosen font as the picker names it.
    private var fontTitle: String {
        if viewModel.terminalFontName.isEmpty { return String(localized: "System Monospaced") }
        return fonts.first { $0.name == viewModel.terminalFontName }?.displayName ?? viewModel.terminalFontName
    }

    private var wholeFontSize: Binding<Double> {
        Binding(get: { viewModel.terminalFontSize }, set: { newValue in
            // Every assignment is saved and sent to the open terminals: only real changes.
            let whole = newValue.rounded()
            if whole != viewModel.terminalFontSize { viewModel.terminalFontSize = whole }
        })
    }

    var body: some View {
        SettingsPage {
            // What the settings below add up to, in the terminal's own colours and type.
            TerminalPreview(theme: TerminalTheme.find(viewModel.terminalColorTheme),
                            fontName: viewModel.terminalFontName,
                            fontSize: viewModel.terminalFontSize,
                            cursorStyle: viewModel.cursorStyle,
                            fontTitle: fontTitle)

            VStack(alignment: .leading, spacing: 0) {
                DSSectionHeader("Terminal Theme")
                TerminalThemeGrid(selectedThemeId: $viewModel.terminalColorTheme)
            }

            SettingsSection("Text") {
                SettingsRow("Font") {
                    Picker("Font", selection: $viewModel.terminalFontName) {
                        Text("System Monospaced").tag("")
                        Divider()
                        ForEach(fonts) { font in
                            Text(verbatim: font.displayName).tag(font.name)
                        }
                        // A stored font that is not installed (any more) still needs its entry.
                        if !viewModel.terminalFontName.isEmpty,
                           !fonts.contains(where: { $0.name == viewModel.terminalFontName }) {
                            Text(verbatim: viewModel.terminalFontName).tag(viewModel.terminalFontName)
                        }
                    }
                    .labelsHidden()
                    // As wide as its longest entry, like the menus below: the same whichever
                    // font is chosen.
                    .fixedSize()
                }

                SettingsRow("Font Size") {
                    HStack(spacing: DS.Space.sm) {
                        // No `step:` — it would draw fifteen tick marks under the track. The
                        // binding rounds to whole points instead.
                        Slider(value: wholeFontSize, in: 10...24) {
                            Text("Font Size")
                        } minimumValueLabel: {
                            Image(systemName: "textformat.size.smaller")
                        } maximumValueLabel: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .labelsHidden()
                        .frame(width: 240)
                        .accessibilityValue(Text("\(Int(viewModel.terminalFontSize))pt"))

                        Text("\(Int(viewModel.terminalFontSize))pt")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .foregroundStyle(.secondary)
                }

                SettingsRow("Cursor Style") {
                    Picker("Cursor Style", selection: $viewModel.cursorStyle) {
                        Text("Block (Blinking)").tag("blinkBlock")
                        Text("Block (Steady)").tag("steadyBlock")
                        Divider()
                        Text("Underline (Blinking)").tag("blinkUnderline")
                        Text("Underline (Steady)").tag("steadyUnderline")
                        Divider()
                        Text("Bar (Blinking)").tag("blinkBar")
                        Text("Bar (Steady)").tag("steadyBar")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsSection("Behavior") {
                SettingsRow("Bell") {
                    Picker("Bell", selection: $viewModel.bell) {
                        Text("Flash").tag("visual")
                        Text("Sound").tag("sound")
                        Text("Off").tag("none")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                SettingsRow("Scrollback", subtitle: "Applies to new terminal sessions.") {
                    Picker("Scrollback", selection: $viewModel.scrollbackLines) {
                        Text("1,000 lines").tag(1_000)
                        Text("10,000 lines").tag(10_000)
                        Text("50,000 lines").tag(50_000)
                        Text("100,000 lines").tag(100_000)
                        // A stored value outside the list (set elsewhere) still needs its entry.
                        if !Self.scrollbackChoices.contains(viewModel.scrollbackLines) {
                            Text("\(viewModel.scrollbackLines) lines").tag(viewModel.scrollbackLines)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                SettingsToggleRow("Use Option as Meta key",
                                  subtitle: "Needed for Alt-shortcuts in Emacs, readline, tmux… Turn off to type special characters with Option.",
                                  isOn: $viewModel.optionAsMeta)
                SettingsToggleRow("Copy text on selection", isOn: $viewModel.copyOnSelect)
                SettingsToggleRow("Close the tab when the shell exits", isOn: $viewModel.closeOnExit)
            }
        }
    }
}

/// A few lines of a session in the chosen theme, font, size and cursor: it changes as the
/// settings under it do.
private struct TerminalPreview: View {
    let theme: TerminalTheme
    let fontName: String
    let fontSize: Double
    let cursorStyle: String
    /// Spoken with the preview; on screen the font and its size are the two controls below.
    let fontTitle: String

    private static let height: CGFloat = 100

    private var font: Font {
        let size = CGFloat(fontSize)
        let nsFont = (fontName.isEmpty ? nil : NSFont(name: fontName, size: size))
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return Font(nsFont as CTFont)
    }

    private var foreground: Color { Color(nsColor: theme.nsForeground) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        // The whole listing while it fits; at large sizes the command and the prompt alone.
        ViewThatFits {
            lines(showsListing: true)
            lines(showsListing: false)
        }
        .font(font)
        .foregroundStyle(foreground)
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.card)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.height, alignment: .topLeading)
        .background(Color(nsColor: theme.nsBackground), in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DS.Palette.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview"))
        .accessibilityValue(Text(verbatim: "\(TerminalThemeCard.displayName(of: theme)), \(fontTitle), \(Int(fontSize)) pt"))
    }

    private func lines(showsListing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                prompt
                Text(verbatim: "ls -la releases")
            }
            if showsListing {
                HStack(spacing: 0) {
                    Text(verbatim: "drwxr-xr-x  5 deploy deploy 4096 Oct  4 21:57 ")
                    Text(verbatim: "current").foregroundStyle(ansi(4))
                }
                Text(verbatim: "-rw-r--r--  1 deploy deploy  220 Sep 28 10:15 .profile")
            }
            HStack(alignment: .bottom, spacing: 0) {
                prompt
                cursor
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var prompt: some View {
        HStack(spacing: 0) {
            Text(verbatim: "deploy@web-01").foregroundStyle(ansi(2))
            Text(verbatim: ":")
            Text(verbatim: "~").foregroundStyle(ansi(4))
            Text(verbatim: "$ ")
        }
    }

    /// Block, underline or bar, one character cell in size.
    private var cursor: some View {
        let cell = CGSize(width: CGFloat(fontSize) * 0.6, height: CGFloat(fontSize) * 1.15)
        let size: CGSize
        if cursorStyle.hasSuffix("Underline") {
            size = CGSize(width: cell.width, height: 2)
        } else if cursorStyle.hasSuffix("Bar") {
            size = CGSize(width: 2, height: cell.height)
        } else {
            size = cell
        }
        return Rectangle()
            .fill(Color(nsColor: theme.nsCursor))
            .frame(width: size.width, height: size.height)
            .frame(width: cell.width, height: cell.height, alignment: .bottomLeading)
    }

    private func ansi(_ index: Int) -> Color {
        guard theme.ansiColors.indices.contains(index) else { return foreground }
        return Color(nsColor: TerminalTheme.nsColor(hex: theme.ansiColors[index]))
    }
}

// MARK: - Import / Export

private struct ImportExportSettingsPane: View {
    let viewModel: SettingsViewModel

    var body: some View {
        SettingsPage {
            SettingsSection("Hosts") {
                // The buttons say what each row does; their tooltips say the rest.
                SettingsRow("CSV") {
                    HStack(spacing: DS.Space.sm) {
                        Button("Import CSV…") {
                            viewModel.start { viewModel.importCSV() }
                        }
                        .help("Import hosts from a CSV file")

                        Button("Export CSV…") {
                            viewModel.start { viewModel.exportCSV() }
                        }
                        .help("Export all hosts to a CSV file")
                    }
                    .dsButtonStyle(.glass, size: .small)
                    .disabled(viewModel.isProcessing)
                }

                SettingsRow("SSH Config") {
                    Button("Import SSH Config…") {
                        viewModel.start { viewModel.importSSHConfig() }
                    }
                    .dsButtonStyle(.glass, size: .small)
                    .help("Import from ~/.ssh/config")
                    .disabled(viewModel.isProcessing)
                }
            } footer: {
                if viewModel.hasStatus {
                    SettingsFooter {
                        SettingsStatusView(viewModel: viewModel)
                    }
                }
            }
        }
    }
}

// MARK: - Sync

private struct SyncSettingsPane: View {
    let viewModel: SettingsViewModel

    var body: some View {
        SettingsPage {
            SettingsSection("Encrypted Export / Import") {
                // The titles say what happens; the buttons only start it.
                SettingsRow("Export as one encrypted file", subtitle: "All hosts, keys, snippets and settings.") {
                    Button("Export…") {
                        viewModel.start { viewModel.exportEncryptedSync() }
                    }
                    .dsButtonStyle(.glass, size: .small)
                    .disabled(viewModel.isProcessing)
                }
                SettingsRow("Replace all data with an encrypted file",
                            subtitle: "A file exported from Termi on this or another Mac.") {
                    Button("Import…") {
                        viewModel.start { viewModel.importEncryptedSync() }
                    }
                    .dsButtonStyle(.glass, size: .small)
                    .disabled(viewModel.isProcessing)
                }
            } footer: {
                SettingsFooter {
                    Text("Files are encrypted with AES-256-GCM.")
                        .foregroundStyle(.secondary)
                    // The folder this profile really writes to, not a fixed text.
                    Text("Sync files are stored locally in \(SettingsViewModel.syncFolderText()).")
                        .foregroundStyle(.secondary)
                    SettingsStatusView(viewModel: viewModel)
                }
            }
        }
    }
}

// MARK: - Backup

private struct BackupSettingsPane: View {
    let viewModel: SettingsViewModel

    private var overview: BackupOverview { viewModel.backupOverview }

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 0) {
                DSGroup {
                    DSRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Back Up Now")
                                .fontWeight(.semibold)
                            backUpSubtitle
                                .font(DS.Font.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: DS.Space.md)
                        Button("Create Backup…", systemImage: "plus") {
                            viewModel.start { viewModel.createBackup() }
                        }
                        .dsButtonStyle(.prominent)
                        .disabled(viewModel.isProcessing)
                    }
                }
                // The outcome of a backup or a restore, whichever button started it.
                if viewModel.hasStatus {
                    SettingsFooter {
                        SettingsStatusView(viewModel: viewModel)
                    }
                    .font(DS.Font.caption)
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.top, DS.Space.sm)
                }
            }

            filesSection

            // What a backup is not good for, before someone relies on it for a new Mac.
            // The key file's path is this profile's, read from where the app keeps it.
            Text("A backup does not include the key file on this Mac (\(SettingsViewModel.vaultKeyText())): without a master password, its saved passwords and SSH keys cannot be decrypted on another Mac. To move data between Macs, use the encrypted export in Sync.")
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.xs)
        }
        .task { await viewModel.loadBackupOverview() }
        // A backup deleted or moved in Finder while this page is open: the list, "Last
        // backup" and the sizes are read again when the app comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await viewModel.loadBackupOverview() }
        }
    }

    /// What a backup is, with how large it will be (the database's size, WAL included).
    private var backUpSubtitle: Text {
        if let size = overview.databaseSize {
            return Text("A full copy of the database (\(BackupText.size(size))): hosts, keys, snippets and settings.")
        }
        return Text("A full copy of the database: hosts, keys, snippets and settings.")
    }

    // MARK: Files

    private var filesSection: some View {
        SettingsSection("Backup Files") {
            ForEach(overview.files) { file in
                BackupFileRow(file: file, isNewest: file.id == overview.files.first?.id,
                              unusualFolder: overview.unusualFolder(of: file),
                              isDisabled: viewModel.isProcessing) {
                    viewModel.revealInFinder(file)
                } onRestore: {
                    viewModel.start { viewModel.restoreBackup(file) }
                } onForget: {
                    viewModel.forgetBackup(file)
                }
            }
            // Always there, with or without listed backups. What a restore does is said here
            // and again, with the folder, in the confirmation every restore asks for.
            SettingsRow("Restore from Another File",
                        subtitle: "Checked first, then all data is replaced; the current database is kept as termi.before-*.db. Restart Termi afterwards.",
                        isEmphasized: true) {
                Button("Choose File…") {
                    viewModel.start { viewModel.restoreBackup() }
                }
                .dsButtonStyle(.glass)
                .disabled(viewModel.isProcessing)
            }
        } footer: {
            EmptyView()
        } trailing: {
            if let last = overview.lastBackupDate {
                if let ago = BackupText.relative(last) {
                    Text("Last backup \(ago)")
                } else {
                    Text("Backed up just now")
                }
            } else {
                Text("Never backed up")
            }
        }
    }
}

/// One listed backup: when it was made over its file name, how large, then "show" and
/// "restore". Where it is: the tooltip — and in words only for a backup outside the usual folder.
/// A backup whose disk is not connected, or whose folder may not be looked into, says so and
/// where it is; it has no size to show and nothing to restore until it is in reach again,
/// only a way off the list.
private struct BackupFileRow: View {
    let file: BackupFile
    let isNewest: Bool
    let unusualFolder: URL?
    let isDisabled: Bool
    let onReveal: () -> Void
    let onRestore: () -> Void
    let onForget: () -> Void

    private var secondLine: String {
        guard let unusualFolder else { return file.name }
        return file.name + " · " + (unusualFolder.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        DSRow {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isNewest ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(.secondary))
                .frame(width: DS.Tile.row, height: DS.Tile.row)
                .background(isNewest ? DS.Palette.accent.opacity(0.16) : DS.Palette.chip,
                            in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Space.sm) {
                    Text(verbatim: BackupText.dayAndTime(file.date))
                        .font(DS.Font.rowTitle.monospacedDigit())
                    if file.kind == .keptDatabase {
                        // Kept by a restore or by an encrypted import alike.
                        DSChip("Replaced database")
                            .fixedSize()
                    }
                    if file.availability == .diskNotConnected {
                        DSChip("Disk not connected")
                            .fixedSize()
                    }
                    if file.availability == .cannotBeRead {
                        // No permission to look into its folder: not the same as "deleted".
                        DSChip("Cannot be read")
                            .fixedSize()
                    }
                }
                Text(verbatim: secondLine)
                    .font(DS.Font.mono)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            .help(Text(verbatim: file.url.path))

            Spacer(minLength: DS.Space.sm)

            if file.isReachable {
                // One column down the list.
                Text(verbatim: BackupText.size(file.size))
                    .font(DS.Font.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                DSGlassIconButton("folder", help: "Reveal in Finder", size: .small, action: onReveal)
                Button("Restore…", action: onRestore)
                    .dsButtonStyle(.glass, size: .small)
                    .disabled(isDisabled)
            } else {
                Button("Remove from List", action: onForget)
                    .dsButtonStyle(.glass, size: .small)
                    .help("Removes this entry only. No file is touched.")
                    .disabled(isDisabled)
            }
        }
    }
}

/// How the Backup pane writes dates and sizes.
@MainActor
private enum BackupText {
    /// "Today 19:42", "28 Sep 2026 10:15".
    private static let dayAndTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

    /// "28 Sep 10:15": a date of this year does not repeat the year on every row.
    private static let thisYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd jm")
        return formatter
    }()

    static func dayAndTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let isNamedDay = calendar.isDateInToday(date) || calendar.isDateInYesterday(date) || calendar.isDateInTomorrow(date)
        if !isNamedDay && calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return thisYearFormatter.string(from: date)
        }
        return dayAndTimeFormatter.string(from: date)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "2 hours ago"; nil within the last minute (the formatter would count seconds).
    static func relative(_ date: Date, now: Date = Date()) -> String? {
        guard now.timeIntervalSince(date) >= 60 else { return nil }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}

// MARK: - Notifications

private struct NotificationSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        SettingsPage {
            SettingsSection("System Notifications") {
                SettingsToggleRow("Enable Notifications",
                                  subtitle: "Termi sends system notifications when events occur while the app is in the background.",
                                  isOn: $viewModel.notificationsEnabled)
            }

            SettingsSection("Event Types") {
                Group {
                    SettingsToggleRow("SSH Connection", subtitle: "When a session connects, disconnects or fails.",
                                      isOn: $viewModel.notificationsSSH)
                    SettingsToggleRow("SFTP Transfer", subtitle: "When a transfer takes longer than 3 seconds.",
                                      isOn: $viewModel.notificationsSFTP)
                    SettingsToggleRow("Batch Command", subtitle: "When every host has finished.",
                                      isOn: $viewModel.notificationsBatch)
                }
                .disabled(!viewModel.notificationsEnabled)
            }
        }
    }
}

// MARK: - About

private struct AboutSettingsPane: View {
    /// Mirrors the updater's setting (Sparkle's updater is not observable).
    @State private var automaticUpdates = false

    private var updater: SPUUpdater { SparkleUpdater.updater }

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Termi"
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var versionLine: String {
        "\(version) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// The header in one sentence: the app's name, what it is, its version line.
    nonisolated static func spokenSummary(name: String, tagline: String, versionLine: String) -> String {
        "\(name), \(tagline) \(versionLine)"
    }

    var body: some View {
        SettingsPage {
            HStack(spacing: DS.Space.lg) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(verbatim: appName)
                        .font(DS.Font.detailTitle)
                    Text("A native macOS SSH terminal client.")
                        .font(DS.Font.body)
                        .foregroundStyle(.secondary)
                    Text(verbatim: versionLine)
                        .font(DS.Font.mono)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, DS.Space.xxs)
                }
                // Not `.combine`: the selectable version line is left out of a combined label.
                .accessibilityElement(children: .ignore)
                // All in the label: a plain group's value does not reach assistive technologies.
                .accessibilityLabel(Text(verbatim: Self.spokenSummary(
                    name: appName, tagline: String(localized: "A native macOS SSH terminal client."),
                    versionLine: versionLine)))
            }
            .padding(.horizontal, DS.Space.xs)

            SettingsSection("Updates") {
                SettingsToggleRow("Automatic Updates", isOn: Binding(
                    get: { automaticUpdates },
                    set: { newValue in
                        automaticUpdates = newValue
                        updater.automaticallyChecksForUpdates = newValue
                    }
                ))
                SettingsRow("Check for Updates") {
                    Button("Check Now") {
                        updater.checkForUpdates()
                    }
                    .dsButtonStyle(.glass, size: .small)
                }
            }
            // Updates belong to the standard profile: the updater is not started in any other.
            .disabled(!SparkleUpdater.isAvailable)
        }
        .onAppear {
            guard SparkleUpdater.isAvailable else { return }
            automaticUpdates = updater.automaticallyChecksForUpdates
        }
    }
}

// MARK: - Sync Password Sheet

/// Asks for the password of an encrypted export / import (a sheet rather than an alert, so the
/// field can force ASCII input).
private struct SyncPasswordSheet: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var focusField = true

    private var isExport: Bool { viewModel.syncAction == .export }

    var body: some View {
        Form {
            Section {
                LabeledContent("Password") {
                    ASCIISecureField("Encryption password", text: $viewModel.syncPassword, requestFocus: $focusField, isBezeled: false) {
                        performAction()
                    }
                }
            } header: {
                DSSheetTitle("Sync Password")
            } footer: {
                SettingsFooter {
                    Text(isExport
                         ? LocalizedStringKey("Enter a password to encrypt the sync data.")
                         : LocalizedStringKey("Enter the password used to encrypt the sync file."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    viewModel.syncPassword = ""
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isExport ? LocalizedStringKey("Export") : LocalizedStringKey("Import")) {
                    performAction()
                }
                .disabled(viewModel.syncPassword.isEmpty)
            }
        }
    }

    private func performAction() {
        guard !viewModel.syncPassword.isEmpty else { return }
        dismiss()
        viewModel.performSyncAction()
    }
}

// MARK: - Terminal Theme Grid

/// The terminal colour themes as a grid of selectable previews.
struct TerminalThemeGrid: View {
    @Binding var selectedThemeId: String

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: DS.Space.md)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: DS.Space.md) {
            ForEach(TerminalTheme.builtIn) { theme in
                let isSelected = theme.id == selectedThemeId
                Button {
                    selectedThemeId = theme.id
                } label: {
                    TerminalThemeCard(theme: theme, isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Terminal theme: \(TerminalThemeCard.displayName(of: theme))"))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        // Room for the selection ring of the cards at the edges.
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

/// One theme: a miniature terminal in the theme's colours (three lines + the eight ANSI
/// colours) with its name underneath; the selected one carries the accent ring and its name in
/// bold (nothing lies over the miniature).
struct TerminalThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            preview
            Text(LocalizedStringKey(theme.name))
                .font(DS.Font.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .animation(DS.Motion.quick, value: isSelected)
    }

    /// Theme names are a fixed built-in set, looked up in the string catalog.
    static func displayName(of theme: TerminalTheme) -> String {
        String(localized: String.LocalizationValue(theme.name))
    }

    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.sidebarRow, style: .continuous)
        let foreground = Color(nsColor: theme.nsForeground)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(verbatim: "$ ").foregroundStyle(ansiColor(2))
                Text(verbatim: "ssh web-01")
            }
            Text(verbatim: "~/releases").foregroundStyle(ansiColor(4))
            Text(verbatim: "-rw-r--r-- .env")

            Spacer(minLength: 0)

            HStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { index in
                    let swatch = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    swatch
                        .fill(ansiColor(index))
                        // ANSI black is the background in most dark themes (white in light ones): the
                        // outline keeps all eight swatches visible.
                        .overlay { swatch.strokeBorder(foreground.opacity(0.25), lineWidth: 0.5) }
                        .frame(width: 8, height: 8)
                }
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(foreground)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 66)
        .background(Color(nsColor: theme.nsBackground), in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DS.Palette.separator, lineWidth: 1))
        // Selection ring around the preview, with a gap — as in System Settings › Appearance.
        .padding(3)
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.sidebarRow + 3, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        }
        .accessibilityHidden(true)
    }

    private func ansiColor(_ index: Int) -> Color {
        guard theme.ansiColors.indices.contains(index) else { return .clear }
        return Color(nsColor: TerminalTheme.nsColor(hex: theme.ansiColors[index]))
    }
}
