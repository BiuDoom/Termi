import AppKit
import os.log
import Sparkle

/// Singleton Sparkle updater — accessible from anywhere without going through NSApp.delegate
@MainActor
enum SparkleUpdater {
    /// Only the standard profile updates the app: a QA or test run must not replace the
    /// application it was started from, nor ask the update server on the owner's behalf.
    static let isAvailable = AppProfile.current.kind == .standard

    static let controller = SPUStandardUpdaterController(
        startingUpdater: isAvailable,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    static var updater: SPUUpdater { controller.updater }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "AppDelegate")

    /// SwiftUI installs its own NSApplication delegate and forwards to this object, so
    /// `NSApp.delegate as? AppDelegate` is nil — reach the instance through this reference.
    private(set) static weak var shared: AppDelegate?

    /// Window → its close guard (weak keys: an entry goes away with its window).
    private var closeGuards = NSMapTable<NSWindow, WindowCloseGuard>.weakToStrongObjects()

    /// The state of every open window.
    private var windowViewModels: [AppViewModel] {
        (closeGuards.objectEnumerator()?.allObjects ?? []).compactMap { ($0 as? WindowCloseGuard)?.viewModel }
    }

    /// What the launch clean-up has to tell about a previous run's remote edits, until there is
    /// a window to show it in.
    private var pendingNotice: SFTPNotice?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    /// Called by WindowRegistrar when a new window enters the view hierarchy.
    func register(window: NSWindow, viewModel: AppViewModel) {
        guard closeGuards.object(forKey: window) == nil else { return }
        let closeGuard = WindowCloseGuard(forwardingTo: window.delegate, viewModel: viewModel)
        closeGuards.setObject(closeGuard, forKey: window)
        window.delegate = closeGuard
        logger.debug("Registered window: \(window.windowNumber)")
        deliverPendingNotice(to: viewModel)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DebugActiveAppearance.installIfRequested()
        #endif
        let launchedAt = Date()
        logger.info("Termi launched")

        // Sessions have their own tab bar: the system's window tabs would add a second, unrelated
        // set of "Show Tab Bar" / "Merge All Windows" commands to the menus.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Snippets and batch commands are shell text: "smart" quotes, dashes and text
        // replacement would silently change the command (-- → —, " → ”).
        // (AppKit's own keys: `.standard` on purpose. In a separate profile that is the
        // profile's preferences too — see AppProfile.redirectStandardDefaults.)
        for key in ["NSAutomaticQuoteSubstitutionEnabled", "NSAutomaticDashSubstitutionEnabled",
                    "NSAutomaticTextReplacementEnabled", "NSAutomaticSpellingCorrectionEnabled"] {
            UserDefaults.standard.set(false, forKey: key)
        }

        // Request notification permission for SSH/SFTP/batch alerts
        NotificationService.shared.requestPermission()

        // Remove residual SSH temp files and orphaned connections from any previous crash.
        // Remote files such a run was editing (SFTP) may hold changes its server never received:
        // they go to the Trash, and the SFTP page says so.
        DispatchQueue.global(qos: .utility).async {
            let recovered = RemoteEditFolder.sweepStale()
            SSHService.cleanupResidualTempFiles()
            guard !recovered.isEmpty else { return }
            Task { @MainActor in AppDelegate.shared?.announceRecoveredEdits(recovered) }
        }

        // Reconnect dropped sessions as soon as the network comes back / the Mac wakes
        NetworkMonitor.shared.start()

        // Initialize database — failure is critical; broadcast via NotificationCenter
        Task { @MainActor in
            do {
                try await DatabaseManager.shared.initialize()
                logger.info("Database initialized successfully")

                // History rows a previous run left "connected": it quit with sessions open.
                _ = try? await ConnectionLogRepository.shared.closeUnfinished(startedBefore: launchedAt)

                // Prune connection logs older than 90 days — with the session output they
                // recorded (the repository removes exactly those records' transcripts).
                _ = try? await ConnectionLogRepository.shared.deleteOlderThan(days: 90)

                // The age limit for the transcripts themselves. By age only, never "no record
                // refers to it": after a restore the database kept for rolling back still does.
                pruneSessionLogs(olderThanDays: 90)

                // Load notification preferences from DB
                await NotificationService.shared.loadPreferences()

                // Read the vault key now, while the Mac is unlocked: its file has complete file
                // protection and cannot be read while the screen is locked, which is exactly when
                // a session reconnects after wake and needs a saved password or key.
                try? await SecureStoreService.shared.ensureUnlocked()
            } catch {
                let msg = "\(error)"
                logger.error("Database initialization failed: \(msg, privacy: .public)")
                NotificationCenter.default.post(
                    name: .databaseInitFailed,
                    object: nil,
                    userInfo: ["message": msg]
                )
            }
        }
    }

    private func announceRecoveredEdits(_ files: [URL]) {
        let names = files.map(\.lastPathComponent).joined(separator: ", ")
        let text = String(localized: "Termi did not quit normally last time. The remote files it was editing were moved to the Trash: \(names)")
        pendingNotice = SFTPNotice(text: text, files: files)
        if let viewModel = windowViewModels.first {
            deliverPendingNotice(to: viewModel)
        }
    }

    /// Hands the launch clean-up's notice to a window: its SFTP page keeps it until it is
    /// closed, and a toast points there from whatever page is showing.
    private func deliverPendingNotice(to viewModel: AppViewModel) {
        guard let notice = pendingNotice else { return }
        pendingNotice = nil
        viewModel.sftp.addNotice(notice.text, files: notice.files)
        viewModel.addToast(.warning, String(localized: "Files from the last session were moved to the Trash. See the SFTP page."))
    }

    /// Quitting disconnects the SSH sessions, cancels the SFTP transfers and ends the remote
    /// editing of every window (nothing else gets to ask: windows are not asked to close on
    /// ⌘Q), so it asks first when that would lose something — the same question closing a
    /// window asks, for all windows at once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var warnings = SFTPViewModel.closeWarnings(for: windowViewModels.map(\.sftp))
        let live = windowViewModels.reduce(0) { $0 + $1.liveSSHSessionCount }
        // "Don't ask again" covers SSH sessions only: what SFTP would lose always asks.
        let asksForSessions = live > 0 && !AppProfile.defaults.bool(forKey: "suppressSSHCloseConfirmation")
        guard asksForSessions || !warnings.isEmpty else { return .terminateNow }
        if live > 0 {
            warnings.insert(String(localized: "\(live) SSH session(s) will be disconnected."), at: 0)
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Termi?")
        alert.informativeText = warnings.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Termi terminating")
        // Remote files downloaded for editing (SFTP): ending the editing in every window deletes
        // the copies whose changes are on the server and moves the others to the Trash. Whatever
        // is still in this instance's folder after that is not deleted either.
        for viewModel in windowViewModels { viewModel.sftp.disconnect() }
        RemoteEditFolder.sweep(RemoteEditFolder.url())
        // Close every SSH master connection (and the private ssh-agent) before exiting.
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await SSHService.shared.shutdown()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Session Log Cleanup

    private func pruneSessionLogs(olderThanDays days: Int) {
        let logsDir = AppProfile.current.sessionLogsDirectory
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(
                at: logsDir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
            ) else { return }
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            for file in files where file.pathExtension == "log" {
                guard let attrs = try? file.resourceValues(forKeys: [.creationDateKey]),
                      let created = attrs.creationDate, created < cutoff else { continue }
                try? fm.removeItem(at: file)
            }
        }
    }

}

/// Stands in front of the window delegate SwiftUI installed: answers `windowShouldClose` and
/// forwards every other delegate message, so SwiftUI keeps managing the window.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private weak var forwardee: (any NSWindowDelegate)?
    fileprivate weak var viewModel: AppViewModel?

    init(forwardingTo forwardee: (any NSWindowDelegate)?, viewModel: AppViewModel) {
        self.forwardee = forwardee
        self.viewModel = viewModel
        super.init()
    }

    /// Closing a window ends its sessions (asking first when live SSH sessions would drop).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let viewModel, !viewModel.confirmCloseWindow() {
            return false
        }
        return forwardee?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forwardee?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        forwardee
    }
}
