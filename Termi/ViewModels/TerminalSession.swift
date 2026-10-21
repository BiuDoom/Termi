import AppKit
import Observation
import SwiftTerm
import os.log

/// What a terminal pane runs: a local shell, a saved host or an ad-hoc (Quick Connect) host.
struct TerminalPane: Identifiable, Equatable {
    let id: UUID
    var isSSH: Bool
    var hostId: Int64?
    /// Ad-hoc host for Quick Connect (not saved to the database).
    var adHocHost: Host?
    /// One-off password for Quick Connect.
    var adHocPassword: String?
    var title: String

    init(id: UUID = UUID(), title: String = "Local", isSSH: Bool = false, hostId: Int64? = nil,
         adHocHost: Host? = nil, adHocPassword: String? = nil) {
        self.id = id
        self.title = title
        self.isSSH = isSSH
        self.hostId = hostId
        self.adHocHost = adHocHost
        self.adHocPassword = adHocPassword
    }

    /// A new pane running the same thing (for split / duplicate).
    func duplicated() -> TerminalPane {
        TerminalPane(title: title, isSSH: isSSH, hostId: hostId, adHocHost: adHocHost, adHocPassword: adHocPassword)
    }
}

/// One terminal session (local shell or SSH shell) shown in a pane.
///
/// The session owns its terminal view, so it survives tab switches, splits and layout changes;
/// SwiftUI views only attach the view to the window. SSH sessions run as multiplexed sessions
/// on the host's shared master connection and reconnect automatically when it drops.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case idle
        /// Local shell running.
        case running
        case connecting
        case connected
        case reconnecting(attempt: Int, retryAt: Date)
        /// The shell ended; `message` explains why (nil = closed normally).
        case ended(message: String?)
        case failed(String)
    }

    let id: UUID
    let pane: TerminalPane
    private let dataGeneration = DataSnapshot.current
    private(set) var state: State = .idle {
        didSet {
            // The status bar and the inspector count from the moment the shell came up.
            if isLive {
                if connectedSince == nil { connectedSince = Date() }
            } else if connectedSince != nil {
                connectedSince = nil
            }
        }
    }
    /// Since when the shell has been up; nil while it is not.
    private(set) var connectedSince: Date?
    /// The terminal's grid, as last reported by the terminal view.
    private(set) var columns: Int?
    private(set) var rows: Int?
    /// The host's port-forwarding rules, for the status bar and the inspector.
    private(set) var portForwards: [PortForward] = []
    private(set) var host: Host?
    private(set) var title: String
    /// Title set by the remote/local program (OSC 0/2).
    private(set) var programTitle: String?
    /// True once the session has started an interactive shell or received terminal output.
    private(set) var hasTerminalOutput = false
    /// Bumped whenever the terminal view is replaced (after a reconnect).
    private(set) var viewGeneration = 0

    /// Hooks wired up by `AppViewModel`.
    @ObservationIgnored var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    @ObservationIgnored var onFocus: (() -> Void)?
    @ObservationIgnored var onRequestClose: (() -> Void)?
    @ObservationIgnored var menuBuilder: ((TerminalSession) -> NSMenu?)?

    @ObservationIgnored private var terminalView: BiuTerminalView?
    /// The wrapper the terminal view was last handed to. When a tab's pane layout changes
    /// shape, SwiftUI builds a pane's new wrapper while the old one is still in the window and
    /// still being updated: only the newest may hold the view (see `TerminalHostView`).
    @ObservationIgnored weak var viewHost: AnyObject?
    @ObservationIgnored private var terminalViewHasRunProcess = false
    @ObservationIgnored private var processEvents: TerminalProcessEvents?
    @ObservationIgnored private var lease: SSHConnectionManager.Lease?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var exitCheckTask: Task<Void, Never>?
    @ObservationIgnored private var preferences: TerminalPreferences
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isClosing = false
    @ObservationIgnored private var reconnectAttempts = 0
    /// When the current remote shell started (decides whether the session proved stable).
    @ObservationIgnored private var shellStartedAt: Date?
    @ObservationIgnored private var pendingStartupCommand: String?

    // Connection log + session transcript
    @ObservationIgnored private var connectionLogId: Int64?
    @ObservationIgnored private var connectedAt: Date?
    @ObservationIgnored private var captureHandle: FileHandle?
    @ObservationIgnored private var captureBytes = 0
    private static let maxCaptureBytes = 50 * 1024 * 1024
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "TerminalSession")

    init(pane: TerminalPane, preferences: TerminalPreferences) {
        self.id = pane.id
        self.pane = pane
        self.title = pane.title
        self.preferences = preferences
    }

    var isSSH: Bool { pane.isSSH }

    /// The state the interface shows: `state`, except in a debug build started with
    /// `-debugSessionState connecting|reconnecting|failed|ended` (state cards for screenshots).
    var displayState: State {
        #if DEBUG
        if pane.isSSH, let debugState = Self.debugState { return debugState }
        #endif
        return state
    }

    #if DEBUG
    private static let debugState: State? = {
        switch AppProfile.arguments.string(forKey: "debugSessionState") {
        case "connecting": return .connecting
        case "reconnecting": return .reconnecting(attempt: 6, retryAt: Date().addingTimeInterval(26))
        case "failed": return .failed("ssh: connect to host 10.0.20.2 port 22: Operation timed out")
        case "ended": return .ended(message: String(localized: "The session ended."))
        default: return nil
        }
    }()
    #endif

    /// "00:12:04": how long the shell has been up, with fixed-width fields.
    nonisolated static func elapsedText(seconds: Int) -> String {
        let total = max(0, seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// The name of the local shell ("zsh").
    nonisolated static var localShellName: String {
        ((ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") as NSString).lastPathComponent
    }

    var isLive: Bool {
        state == .connected || state == .running
    }

    // MARK: - Terminal view

    /// The terminal view, created on first use.
    func ensureTerminalView() -> BiuTerminalView {
        if let terminalView { return terminalView }
        return makeTerminalView()
    }

    private func makeTerminalView() -> BiuTerminalView {
        var options = TerminalOptions.default
        options.scrollback = preferences.scrollbackLines
        options.cursorStyle = preferences.swiftTermCursorStyle
        let view = BiuTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480),
                                   font: preferences.font, options: options)
        let events = TerminalProcessEvents(session: self)
        view.processDelegate = events
        processEvents = events
        view.onDataReceived = { [weak self] slice in self?.didReceive(slice) }
        view.onUserInput = { [weak self] bytes in self?.onUserInput?(bytes) }
        view.onFocus = { [weak self] in self?.onFocus?() }
        view.contextMenuProvider = { [weak self] in
            guard let self else { return nil }
            return self.menuBuilder?(self)
        }
        applyAppearance(to: view, forceFont: true)
        terminalView = view
        terminalViewHasRunProcess = false
        return view
    }

    func apply(preferences: TerminalPreferences) {
        self.preferences = preferences
        if let terminalView {
            applyAppearance(to: terminalView, forceFont: false)
        }
    }

    private func applyAppearance(to view: BiuTerminalView, forceFont: Bool) {
        let font = preferences.font
        if forceFont || view.font != font {
            view.font = font
            // SwiftTerm sizes the grid for a new font from the full width, but from the width
            // left of the scroller on every resize: without this the last columns sit under the
            // scroller until the window is resized.
            view.setFrameSize(view.frame.size)
        }
        let themeId = host?.terminalTheme.flatMap { $0.isEmpty ? nil : $0 } ?? preferences.colorTheme
        let theme = TerminalTheme.find(themeId)
        view.nativeBackgroundColor = theme.nsBackground
        view.nativeForegroundColor = theme.nsForeground
        view.caretColor = theme.nsCursor
        view.selectedTextBackgroundColor = theme.nsSelection
        let colors = theme.ansiColors.map { Self.swiftTermColor($0) }
        if colors.count == 16 {
            view.installColors(colors)
        }
        view.getTerminal().setCursorStyle(preferences.swiftTermCursorStyle)
        view.optionAsMetaKey = preferences.optionAsMeta
        view.bellStyle = preferences.bellStyle
        view.copyOnSelect = preferences.copyOnSelect
    }

    private static func swiftTermColor(_ hex: String) -> SwiftTerm.Color {
        let color = TerminalTheme.nsColor(hex: hex).usingColorSpace(.sRGB) ?? TerminalTheme.nsColor(hex: hex)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SwiftTerm.Color(red: UInt16(red * 65535), green: UInt16(green * 65535), blue: UInt16(blue * 65535))
    }

    // MARK: - Lifecycle

    /// Start the shell / connection the first time the pane is shown.
    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        #if DEBUG
        // A state card for a screenshot: the host is read for its tile, nothing connects.
        if Self.debugState != nil, pane.isSSH {
            Task { [weak self] in
                guard let self, let host = try? await self.resolveHost() else { return }
                self.host = host
                self.title = host.label.isEmpty ? host.hostname : host.label
            }
            return
        }
        #endif
        if pane.isSSH {
            connect()
        } else {
            startLocalShell()
        }
    }

    private func startLocalShell() {
        let view = ensureTerminalView()
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let home = env["HOME"] ?? NSHomeDirectory()
        var environment = [
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "TERM_PROGRAM=Termi",
            "LANG=\(env["LANG"] ?? "en_US.UTF-8")",
            "HOME=\(home)",
            "PATH=\(env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")",
            "USER=\(env["USER"] ?? NSUserName())",
            "SHELL=\(shell)",
        ]
        if let agent = env["SSH_AUTH_SOCK"] {
            environment.append("SSH_AUTH_SOCK=\(agent)")
        }
        // Leading dash → login shell.
        view.startProcess(executable: shell, args: [], environment: environment,
                          execName: "-\((shell as NSString).lastPathComponent)", currentDirectory: home)
        terminalViewHasRunProcess = true
        state = .running
        readGridSize(of: view)
    }

    /// Connect (or reconnect) an SSH session.
    func connect() {
        guard pane.isSSH, !isClosing else { return }
        connectTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        exitCheckTask?.cancel()
        exitCheckTask = nil
        state = .connecting
        connectTask = Task { [weak self] in
            guard let self else { return }
            await DataSnapshot.$expected.withValue(self.dataGeneration) {
                await self.performConnect()
            }
        }
    }

    /// User-requested reconnect (restarts even a live session).
    func reconnect() {
        guard pane.isSSH else { return }
        // While an auto-reconnect is waiting or already trying, only bring the next attempt
        // forward: keeping the attempt count means a failed try goes back to backing off
        // instead of giving up. Nothing runs in either state, so there is nothing to stop.
        switch state {
        case .connecting, .reconnecting:
            connect()
            return
        default:
            break
        }
        reconnectAttempts = 0
        // No exit callback follows a terminate (SwiftTerm stops watching the process), so do
        // the end-of-session bookkeeping here.
        terminalView?.terminateAndReap()
        stopCapture()
        finishConnectionLog()
        startupTask?.cancel()
        startupTask = nil
        releaseLease()
        connect()
    }

    /// Stop connecting / reconnecting.
    func cancelConnecting() {
        connectTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        state = .ended(message: String(localized: "Connection cancelled"))
    }

    /// Final shutdown when the pane closes.
    func close() {
        isClosing = true
        connectTask?.cancel()
        reconnectTask?.cancel()
        startupTask?.cancel()
        exitCheckTask?.cancel()
        terminalView?.terminateAndReap()
        releaseLease()
        stopCapture()
        finishConnectionLog()
        state = .ended(message: nil)
    }

    /// Network came back or the Mac woke up: retry a pending reconnect right away.
    func retryReconnectNow() {
        if case .reconnecting = state {
            connect()
        }
    }

    private func performConnect() async {
        do {
            let host = try await resolveHost()
            self.host = host
            title = host.label.isEmpty ? host.hostname : host.label
            if let terminalView {
                applyAppearance(to: terminalView, forceFont: false)
            }
            let lease = try await SSHService.shared.connect(to: host, password: pane.adHocPassword)
            guard !Task.isCancelled, !isClosing else {
                lease.release()
                return
            }
            releaseLease()
            self.lease = lease
            startRemoteShell(lease: lease, host: host)
        } catch {
            // A newer connect() or close() superseded this attempt.
            guard !isClosing, !Task.isCancelled else { return }
            // The user's own Cancel (in a password, passphrase or host key prompt) is not a
            // failure: the same quiet card as Cancel on the "Connecting" card, nothing to retry
            // or copy, and no further attempt.
            if Self.isUserCancel(error) {
                reconnectTask?.cancel()
                reconnectTask = nil
                state = .ended(message: String(localized: "Connection cancelled"))
                return
            }
            if reconnectAttempts > 0, Self.isRetryable(error) {
                scheduleReconnect()
                return
            }
            let message = error.localizedDescription
            NotificationService.shared.sendSSHFailed(host: title, error: message)
            if let host {
                Task { _ = try? await ConnectionLogRepository.shared.log(host: host, status: "failed", error: message) }
            }
            state = .failed(message)
            logger.error("SSH connect failed for \(self.title): \(message)")
        }
    }

    private func resolveHost() async throws -> Host {
        if let adHoc = pane.adHocHost { return adHoc }
        guard let hostId = pane.hostId, let host = try await HostRepository.shared.fetch(id: hostId) else {
            throw SSHError.invalidConfiguration(String(localized: "This host no longer exists."))
        }
        return host
    }

    /// Whether a connection attempt ended because the user cancelled one of its prompts.
    nonisolated static func isUserCancel(_ error: Error) -> Bool {
        error is CancellationError || (error as? SSHError) == .cancelled
    }

    private static func isRetryable(_ error: Error) -> Bool {
        // The vault key file cannot be read while the screen is locked (a reconnect right after
        // wake): keep retrying, it becomes readable once the Mac is unlocked.
        if (error as? CocoaError)?.code == .fileReadNoPermission { return true }
        switch error as? SSHError {
        case .connectionFailed, .disconnected: return true
        default: return false
        }
    }

    private func startRemoteShell(lease: SSHConnectionManager.Lease, host: Host) {
        // A SwiftTerm view whose process ended cannot host a new one — use a fresh view.
        let view: BiuTerminalView
        if let terminalView, !terminalViewHasRunProcess {
            view = terminalView
        } else {
            view = makeTerminalView()
            viewGeneration += 1
        }
        if let banner = lease.master.takeBanner() {
            view.feed(text: banner.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n")
        }
        if reconnectAttempts > 0 {
            view.feed(text: "\u{1B}[2m" + String(localized: "— Reconnected —") + "\u{1B}[0m\r\n")
        }

        let command = lease.master.interactiveCommand(forwardX11: host.x11Forwarding)
        view.startProcess(executable: command.executable, args: command.arguments,
                          environment: command.environment.map { "\($0.key)=\($0.value)" }, execName: nil)
        terminalViewHasRunProcess = true
        hasTerminalOutput = true
        state = .connected
        readGridSize(of: view)
        Task { [weak self] in await self?.reloadPortForwards() }
        // `reconnectAttempts` is not reset here: a shell that started has not proved anything
        // yet (see `stableShellUptime`).
        shellStartedAt = Date()

        NotificationService.shared.sendSSHConnected(host: title)
        startConnectionLog(host: host)
        let master = lease.master
        Task {
            await PortForwardManager.shared.applyAutoForwards(for: host, on: master)
        }
        if let snippetId = host.startupSnippetId {
            Task { [weak self] in
                guard let snippet = try? await SnippetRepository.shared.fetch(id: snippetId) else { return }
                self?.pendingStartupCommand = snippet.command
            }
        }
    }

    private func didReceive(_ slice: ArraySlice<UInt8>) {
        if !hasTerminalOutput { hasTerminalOutput = true }
        capture(slice)
        if pendingStartupCommand != nil, startupTask == nil, state == .connected {
            // Wait for the shell prompt to settle before typing the startup snippet.
            startupTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled, let command = self.pendingStartupCommand else { return }
                self.pendingStartupCommand = nil
                // Straight to this pane's process: sent as typed text it would be broadcast,
                // and every pane of the tab would run it once for each pane that connects.
                let text = command.hasSuffix("\n") ? command : command + "\r"
                self.sendToProcess(ArraySlice(Array(text.utf8)))
            }
        }
    }

    /// SwiftTerm 1.18 reports the raw `waitpid` status rather than the exit code (re-check when
    /// upgrading it). Decode it the way a shell does: the exit code, or 128 + the signal
    /// number when a signal killed the process.
    nonisolated static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    fileprivate func processDidTerminate(exitCode: Int32?, view: ObjectIdentifier) {
        guard view == terminalView.map(ObjectIdentifier.init) else { return }
        stopCapture()
        finishConnectionLog()
        startupTask?.cancel()
        startupTask = nil
        guard !isClosing else { return }

        guard pane.isSSH else {
            state = .ended(message: nil)
            onRequestClose?()
            return
        }
        guard state == .connected else { return }

        // Only a shell that proved stable starts the reconnect back-off over.
        let uptime = shellStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        reconnectAttempts = Self.attemptsCarriedOver(reconnectAttempts, shellUptime: uptime)

        switch Self.shellExit(exitCode: exitCode, masterAlive: lease?.master.isAlive ?? false) {
        case .finished:
            releaseLease()
            state = .ended(message: preferences.closeOnExit ? nil : String(localized: "The session ended."))
            if preferences.closeOnExit {
                onRequestClose?()
            }
        case .connectionLost:
            connectionLost()
        case .failed:
            shellFailed(exitCode: exitCode)
        case .ambiguous:
            // The lease is kept meanwhile, so the master is not closed for being idle.
            let master = lease?.master
            exitCheckTask = Task { [weak self] in
                let lost = await TerminalSession.masterDies(within: TerminalSession.masterExitGrace) {
                    master?.isAlive ?? false
                }
                // A reconnect or close() in the meantime cancelled this check.
                guard let self, !Task.isCancelled, !self.isClosing, self.state == .connected,
                      view == self.terminalView.map(ObjectIdentifier.init) else { return }
                if lost {
                    self.connectionLost()
                } else {
                    self.shellFailed(exitCode: exitCode)
                }
            }
        }
    }

    /// What the end of an SSH shell's process says about the session.
    enum ShellExit: Equatable {
        /// The remote shell exited with status 0.
        case finished
        /// The remote shell exited with another status; the connection itself is fine.
        case failed
        /// The host's master connection is gone.
        case connectionLost
        /// Exit 255 over a master that still looks alive: `masterDies` has to decide.
        case ambiguous
    }

    /// ssh exits with 255 when the connection drops, but its mux client also passes the remote
    /// shell's own status on (`exit` after a failed ssh on a jump host ends the shell with 255).
    /// So the status alone never means "connection lost" — the state of the master does.
    nonisolated static func shellExit(exitCode: Int32?, masterAlive: Bool) -> ShellExit {
        guard masterAlive else { return .connectionLost }
        switch exitCode {
        case 0: return .finished
        case 255: return .ambiguous
        default: return .failed
        }
    }

    /// How long the master is watched after an exit 255. A dropped connection ends the master
    /// and its clients together, but the client's exit can be reported first.
    nonisolated static var masterExitGrace: TimeInterval { 1 }

    /// True as soon as `isAlive` turns false; false when it still holds after `grace` seconds
    /// (or the task was cancelled).
    static func masterDies(within grace: TimeInterval, isAlive: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(grace)
        while isAlive() {
            if Date() >= deadline { return false }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return false
            }
        }
        return true
    }

    private func shellFailed(exitCode: Int32?) {
        releaseLease()
        state = .ended(message: String(localized: "The session ended (exit code \(exitCode ?? -1))."))
    }

    fileprivate func gridSizeChanged(columns: Int, rows: Int) {
        // The view reports every layout pass; observers are only told about a change.
        if self.columns != columns { self.columns = columns }
        if self.rows != rows { self.rows = rows }
    }

    private func readGridSize(of view: BiuTerminalView) {
        let terminal = view.getTerminal()
        gridSizeChanged(columns: terminal.cols, rows: terminal.rows)
    }

    /// Reads the host's forwarding rules again (after it connected, and when rules were saved).
    func reloadPortForwards() async {
        guard let hostId = host?.id else { return }
        #if DEBUG
        // -debugSampleForwards YES: two rules that are not in the database (their switches do
        // nothing), to see the inspector's section on a host that has none.
        if AppProfile.arguments.bool(forKey: "debugSampleForwards") {
            portForwards = [
                PortForward(id: nil, hostId: hostId, type: "local", localPort: 18080, remoteHost: "127.0.0.1",
                            remotePort: 8080, enabled: true, createdAt: ""),
                PortForward(id: nil, hostId: hostId, type: "dynamic", localPort: 1080, remoteHost: "",
                            remotePort: 0, enabled: false, createdAt: "")
            ]
            return
        }
        #endif
        if let rules = try? await PortForwardRepository.shared.fetchForHost(hostId) {
            portForwards = rules
        }
    }

    fileprivate func programTitleChanged(_ newTitle: String) {
        programTitle = newTitle.isEmpty ? nil : newTitle
        if !pane.isSSH, let programTitle {
            title = programTitle
        }
    }

    private func connectionLost() {
        releaseLease()
        NotificationService.shared.sendSSHDisconnected(host: title)
        if preferences.autoReconnect {
            scheduleReconnect()
        } else {
            state = .ended(message: String(localized: "The connection was lost."))
        }
    }

    /// Auto-reconnect waits 1, 2, 4 … seconds before the next attempt, 30 at most.
    nonisolated static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(30.0, pow(2.0, Double(attempt - 1)))
    }

    /// A shell counts as stable once it has stayed up this long; only then does the next
    /// connection loss start the back-off over. Long enough to see through a host that drops
    /// every session right after it starts (retried more and more slowly instead of once a
    /// second for ever), short enough that a link which gave a usable shell is reconnected at
    /// once when it drops again.
    nonisolated static var stableShellUptime: TimeInterval { 10 }

    /// The attempt count to go on from after a shell that was up for `shellUptime` seconds.
    nonisolated static func attemptsCarriedOver(_ attempts: Int, shellUptime: TimeInterval) -> Int {
        shellUptime >= stableShellUptime ? 0 : attempts
    }

    private func scheduleReconnect() {
        reconnectAttempts += 1
        let delay = Self.reconnectDelay(attempt: reconnectAttempts)
        state = .reconnecting(attempt: reconnectAttempts, retryAt: Date().addingTimeInterval(delay))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func releaseLease() {
        lease?.release()
        lease = nil
    }

    // MARK: - Input & actions

    /// Type text into the session (goes through the input hooks, so broadcast applies).
    func type(_ text: String) {
        guard isLive else { return }
        ensureTerminalView().send(txt: text)
    }

    /// Write bytes to the process only (used for broadcast targets).
    func sendToProcess(_ bytes: ArraySlice<UInt8>) {
        guard isLive else { return }
        terminalView?.sendToProcess(bytes)
    }

    func focus() {
        guard let terminalView, let window = terminalView.window else { return }
        window.makeFirstResponder(terminalView)
    }

    var isFocused: Bool {
        guard let terminalView, let window = terminalView.window else { return false }
        return window.firstResponder === terminalView
    }

    func showFind() { terminalView?.showFindBar() }
    func findNext() { terminalView?.findNext() }
    func findPrevious() { terminalView?.findPrevious() }
    func clearBuffer() { terminalView?.clearBuffer() }
    func copySelection() { terminalView?.copySelection() }
    func paste() { terminalView?.pasteClipboard() }
    var hasSelection: Bool { terminalView?.hasSelection ?? false }

    /// The live master connection (for opening SFTP next to this terminal).
    var connectionHost: Host? { host ?? pane.adHocHost }

    // MARK: - Connection log & transcript

    nonisolated static var sessionLogsDirectory: URL {
        SessionTranscripts.directory
    }

    nonisolated static func transcriptPath(for logId: Int64) -> String {
        SessionTranscripts.url(for: logId).path
    }

    private func startConnectionLog(host: Host) {
        connectedAt = Date()
        Task { [weak self] in
            guard let entry = try? await ConnectionLogRepository.shared.log(host: host, status: "connected"),
                  let logId = entry.id, let self else { return }
            guard self.state == .connected, self.connectedAt != nil else {
                // Already disconnected while the log entry was being written.
                try? await ConnectionLogRepository.shared.updateDisconnected(id: logId, durationMs: 0)
                return
            }
            self.connectionLogId = logId
            self.startCapture(logId: logId)
        }
    }

    private func finishConnectionLog() {
        guard let start = connectedAt else { return }
        connectedAt = nil
        if let logId = connectionLogId {
            let duration = Int(Date().timeIntervalSince(start) * 1000)
            let generation = dataGeneration
            Task {
                try? await DataSnapshot.$expected.withValue(generation) {
                    try await ConnectionLogRepository.shared.updateDisconnected(id: logId, durationMs: duration)
                }
            }
        }
        connectionLogId = nil
    }

    private func startCapture(logId: Int64) {
        let directory = Self.sessionLogsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(logId).log")
        captureBytes = 0
        // Record ids are kept above every transcript on disk, so nothing should be here. If
        // something is, it is another session's output: this session goes unrecorded rather
        // than writing over it.
        guard !FileManager.default.fileExists(atPath: url.path) else {
            captureHandle = nil
            return
        }
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        captureHandle = try? FileHandle(forWritingTo: url)
    }

    private func capture(_ slice: ArraySlice<UInt8>) {
        guard let captureHandle, captureBytes < Self.maxCaptureBytes else { return }
        captureBytes += slice.count
        do {
            try captureHandle.write(contentsOf: Data(slice))
        } catch {
            stopCapture()
        }
    }

    private func stopCapture() {
        try? captureHandle?.close()
        captureHandle = nil
        captureBytes = 0
    }
}

/// Receives SwiftTerm process callbacks and forwards them to the session on the main actor.
final class TerminalProcessEvents: LocalProcessTerminalViewDelegate, @unchecked Sendable {
    private weak var session: TerminalSession?

    init(session: TerminalSession) {
        self.session = session
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak self] in
            self?.session?.gridSizeChanged(columns: newCols, rows: newRows)
        }
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.session?.programTitleChanged(title)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let view = ObjectIdentifier(source)
        let code = exitCode.map { TerminalSession.exitCode(fromWaitStatus: $0) }
        Task { @MainActor [weak self] in
            self?.session?.processDidTerminate(exitCode: code, view: view)
        }
    }
}
