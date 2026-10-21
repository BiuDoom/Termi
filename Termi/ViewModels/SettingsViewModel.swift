import SwiftUI
import os.log

/// ViewModel for app settings including import/export
@Observable
@MainActor
final class SettingsViewModel {
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "SettingsVM")
    private let importExport = ImportExportService.shared
    private let syncService = SyncService.shared

    // Import/Export state
    var importResult: String?
    var exportResult: String?
    var isProcessing = false
    var error: String?

    // Sync
    var syncPassword = ""
    var showingSyncPassword = false
    var syncAction: SyncAction = .export
    private var isApplyingStoredSettings = false

    enum SyncAction {
        case export, `import`
    }

    // Backup overview (Settings › Backup): the backups the page lists and the database's size.
    private(set) var backupOverview = BackupOverview()
    /// The page reloads when it appears, when the app comes forward and after every action;
    /// only the reload that started last may publish what it read.
    private var backupOverviewGeneration = 0

    // MARK: - Language

    var appLanguage: String = AppProfile.defaults.string(forKey: "appLanguage") ?? "system" {
        didSet {
            AppProfile.defaults.set(appLanguage, forKey: "appLanguage")
            // Menus, alerts, notifications and String(localized:) use the bundle's language,
            // which is fixed at launch — override it in the app's own defaults for the next one.
            if appLanguage == "system" {
                AppProfile.defaults.removeObject(forKey: "AppleLanguages")
            } else {
                AppProfile.defaults.set([appLanguage], forKey: "AppleLanguages")
            }
        }
    }

    // MARK: - Terminal Settings

    var terminalFontSize: Double = 14 {
        didSet { saveSettingAsync(TerminalPreferences.Key.fontSize, value: String(Int(terminalFontSize)), notifyTerminals: true) }
    }

    var terminalTheme: String = {
        #if DEBUG
        if let debugAppearance = AppProfile.arguments.string(forKey: "debugAppearance") {
            return debugAppearance
        }
        #endif
        return "Dark"
    }() {
        didSet {
            saveSettingAsync("terminal_theme", value: terminalTheme)
            NotificationCenter.default.post(
                name: .terminalThemeChanged,
                object: nil,
                userInfo: ["theme": terminalTheme]
            )
        }
    }

    var terminalColorTheme: String = "defaultDark" {
        didSet { saveSettingAsync(TerminalPreferences.Key.colorTheme, value: terminalColorTheme, notifyTerminals: true) }
    }

    var cursorStyle: String = "blinkBlock" {
        didSet { saveSettingAsync(TerminalPreferences.Key.cursorStyle, value: cursorStyle, notifyTerminals: true) }
    }

    /// PostScript name of the terminal font ("" = system monospaced).
    var terminalFontName: String = "" {
        didSet { saveSettingAsync(TerminalPreferences.Key.fontName, value: terminalFontName, notifyTerminals: true) }
    }

    var optionAsMeta: Bool = true {
        didSet { saveSettingAsync(TerminalPreferences.Key.optionAsMeta, value: optionAsMeta ? "true" : "false", notifyTerminals: true) }
    }

    var copyOnSelect: Bool = false {
        didSet { saveSettingAsync(TerminalPreferences.Key.copyOnSelect, value: copyOnSelect ? "true" : "false", notifyTerminals: true) }
    }

    var bell: String = "visual" {
        didSet { saveSettingAsync(TerminalPreferences.Key.bell, value: bell, notifyTerminals: true) }
    }

    var scrollbackLines: Int = 10_000 {
        didSet { saveSettingAsync(TerminalPreferences.Key.scrollback, value: String(scrollbackLines), notifyTerminals: true) }
    }

    var closeOnExit: Bool = true {
        didSet { saveSettingAsync(TerminalPreferences.Key.closeOnExit, value: closeOnExit ? "true" : "false", notifyTerminals: true) }
    }

    // MARK: - Connection Settings

    var autoReconnect: Bool = true {
        didSet { saveSettingAsync(TerminalPreferences.Key.autoReconnect, value: autoReconnect ? "true" : "false", notifyTerminals: true) }
    }

    var connectionTimeout: Int = 10 {
        didSet { saveSettingAsync("connection_timeout", value: String(connectionTimeout)) }
    }

    /// Seconds between SSH keep-alive probes (a dead connection is noticed after 3 misses).
    var keepAliveInterval: Int = 15 {
        didSet { saveSettingAsync("keepalive_interval", value: String(keepAliveInterval)) }
    }

    /// Apply options from ~/.ssh/config (algorithms for old servers, etc.) to connections.
    var useSSHConfigOptions: Bool = true {
        didSet { saveSettingAsync("ssh_use_user_config", value: useSSHConfigOptions ? "true" : "false") }
    }

    /// Show confirmation dialog before closing an SSH tab (⌘W).
    /// Backed by the profile's preferences for synchronous access in windowShouldClose.
    var confirmSSHClose: Bool = true {
        didSet {
            AppProfile.defaults.set(!confirmSSHClose, forKey: "suppressSSHCloseConfirmation")
        }
    }

    // MARK: - Notification Settings

    var notificationsEnabled: Bool = true {
        didSet {
            saveSettingAsync(AppSetting.notificationsEnabled, value: notificationsEnabled ? "true" : "false")
            NotificationService.shared.isEnabled = notificationsEnabled
        }
    }

    var notificationsSSH: Bool = true {
        didSet {
            saveSettingAsync(AppSetting.notificationsSSH, value: notificationsSSH ? "true" : "false")
            NotificationService.shared.sshEnabled = notificationsSSH
        }
    }

    var notificationsSFTP: Bool = true {
        didSet {
            saveSettingAsync(AppSetting.notificationsSFTP, value: notificationsSFTP ? "true" : "false")
            NotificationService.shared.sftpEnabled = notificationsSFTP
        }
    }

    var notificationsBatch: Bool = true {
        didSet {
            saveSettingAsync(AppSetting.notificationsBatch, value: notificationsBatch ? "true" : "false")
            NotificationService.shared.batchEnabled = notificationsBatch
        }
    }

    // MARK: - Load Settings

    func loadSettings() async {
        do {
            let reader = try await DatabaseManager.shared.reader
            let settings = try await reader.read { db in
                try AppSetting.fetchAll(db)
            }
            let dict = Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0.value) })

            isApplyingStoredSettings = true
            defer { isApplyingStoredSettings = false }

            let preferences = TerminalPreferences(settings: dict)
            terminalFontSize = Double(preferences.fontSize)
            #if DEBUG
            if let debugAppearance = AppProfile.arguments.string(forKey: "debugAppearance") {
                terminalTheme = debugAppearance
            } else if let v = dict["terminal_theme"] {
                terminalTheme = v
            }
            #else
            if let v = dict["terminal_theme"] { terminalTheme = v }
            #endif
            terminalColorTheme = preferences.colorTheme
            cursorStyle = preferences.cursorStyle
            terminalFontName = preferences.fontName
            optionAsMeta = preferences.optionAsMeta
            copyOnSelect = preferences.copyOnSelect
            bell = preferences.bell
            scrollbackLines = preferences.scrollbackLines
            closeOnExit = preferences.closeOnExit
            autoReconnect = preferences.autoReconnect
            if let v = dict["connection_timeout"], let i = Int(v) { connectionTimeout = i }
            if let v = dict["keepalive_interval"], let i = Int(v) { keepAliveInterval = i }
            if let v = dict["ssh_use_user_config"] { useSSHConfigOptions = v != "false" }
            confirmSSHClose = !AppProfile.defaults.bool(forKey: "suppressSSHCloseConfirmation")

            // Notification preferences
            if let v = dict[AppSetting.notificationsEnabled] { notificationsEnabled = v != "false" }
            if let v = dict[AppSetting.notificationsSSH] { notificationsSSH = v != "false" }
            if let v = dict[AppSetting.notificationsSFTP] { notificationsSFTP = v != "false" }
            if let v = dict[AppSetting.notificationsBatch] { notificationsBatch = v != "false" }
        } catch {
            logger.error("Failed to load settings: \(error)")
        }
    }

    private func saveSettingAsync(_ key: String, value: String, notifyTerminals: Bool = false) {
        guard !isApplyingStoredSettings, !DataReplacementCoordinator.shared.isReplacing else { return }
        let generation = DataSnapshot.current
        Task {
            do {
                try await DataSnapshot.$expected.withValue(generation) {
                    let writer = try await DatabaseManager.shared.writer
                    try await DataSnapshot.write(writer) { db in
                        let setting = AppSetting(key: key, value: value)
                        try setting.insert(db, onConflict: .replace)
                    }
                }
                if notifyTerminals {
                    // Open terminals in every window reload their preferences.
                    NotificationCenter.default.post(name: .terminalPreferencesChanged, object: nil)
                }
            } catch {
                logger.error("Failed to save setting \(key): \(error)")
            }
        }
    }

    // MARK: - Async Task Helper

    /// Wraps the common pattern: set `isProcessing`, clear error, run async work, catch → error.
    private func performAsync(_ work: @escaping () async throws -> Void) {
        guard !DataReplacementCoordinator.shared.isReplacing else { return }
        let generation = DataSnapshot.current
        isProcessing = true
        error = nil
        Task {
            do {
                try await DataSnapshot.$expected.withValue(generation) {
                    try DataSnapshot.check(generation)
                    try await work()
                }
            } catch {
                self.error = error.localizedDescription
            }
            isProcessing = false
        }
    }

    // MARK: - CSV Export

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "termi-hosts.csv"
        panel.message = String(localized: "Export hosts as CSV")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        performAsync {
            try await self.importExport.exportHostsToFile(url: url)
            self.exportResult = String(localized: "Exported to \(url.lastPathComponent)")
        }
    }

    // MARK: - CSV Import

    func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = String(localized: "Select a CSV file to import")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        performAsync {
            let hosts = try await self.importExport.importHostsCSV(from: url)
            NotificationCenter.default.post(name: .dsDataChanged, object: nil)
            self.importResult = String(localized: "Imported \(hosts.count) hosts")
        }
    }

    // MARK: - SSH Config Import

    func importSSHConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        panel.message = String(localized: "Select an SSH config file")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        performAsync {
            let summary = try await self.importExport.importSSHConfig(from: url)
            NotificationCenter.default.post(name: .dsDataChanged, object: nil)
            self.importResult = summary.description
        }
    }

    // MARK: - Encrypted Sync Export

    func exportEncryptedSync() {
        syncAction = .export
        showingSyncPassword = true
    }

    func importEncryptedSync() {
        syncAction = .import
        showingSyncPassword = true
    }

    func performSyncAction() {
        guard !syncPassword.isEmpty else { return }
        showingSyncPassword = false
        let password = syncPassword

        performAsync {
            defer { self.syncPassword = "" }
            switch self.syncAction {
            case .export:
                let result = try await self.syncService.exportSync(password: password)
                var message = String(localized: "Exported to \(result.url.lastPathComponent)")
                if result.unreadableSecrets > 0 {
                    message += "\n" + String(localized: "\(result.unreadableSecrets) saved passwords or private keys could not be read and are not in the export.")
                }
                self.exportResult = message

            case .import:
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.json]
                panel.message = String(localized: "Select an encrypted export file")

                guard panel.runModal() == .OK, let url = panel.url else { return }

                let data = try await self.syncService.importSync(from: url, password: password)
                // Nothing has been written yet: the file is only read and decrypted.
                let folder = (try? await DatabaseManager.shared.databaseURL)?.deletingLastPathComponent()
                guard self.confirmReplacingAllData(with: data, databaseFolder: folder) else { return }
                let kept = try await self.syncService.applySyncData(data)
                await self.loadSettings()
                self.importResult = String(localized: "Imported \(data.hosts.count) hosts, \(data.sshKeys.count) keys and \(data.identities.count) identities")
                    + "\n" + self.keptDatabaseNote(kept)
            }
        }
    }

    /// The import replaces everything in the app: ask first, now that the file is open and what
    /// it would bring in is known.
    private func confirmReplacingAllData(with data: SyncService.SyncData, databaseFolder: URL?) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Replace all data with this export?")
        alert.informativeText = Self.importWarning(hosts: data.hosts.count, keys: data.sshKeys.count,
                                                   identities: data.identities.count, databaseFolder: databaseFolder)
        alert.alertStyle = .warning
        let replace = alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        // Return does nothing and Esc cancels: replacing everything takes a deliberate click.
        replace.hasDestructiveAction = true
        replace.keyEquivalent = ""
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// What the confirmation of an import says: what is replaced, by how much, and where the
    /// database it replaces stays — the same three things a restore says (`restoreWarning`).
    nonisolated static func importWarning(hosts: Int, keys: Int, identities: Int, databaseFolder: URL?) -> String {
        let kept: String
        if let databaseFolder {
            let path = (databaseFolder.path as NSString).abbreviatingWithTildeInPath
            kept = String(localized: "The current database is kept first, as termi.before-import-*.db in \(path).")
        } else {
            kept = String(localized: "The current database is kept first, as termi.before-import-*.db beside the database.")
        }
        return String(localized: "Everything in Termi — hosts, keys, identities, snippets, settings, saved passwords — will be replaced by the export (hosts: \(hosts), keys: \(keys), identities: \(identities)).")
            + " " + kept
            + " " + String(localized: "Open sessions will close and forms will be dismissed. Unsaved remote edits are kept in the Trash or their original local folder.")
    }

    /// Restore and import keep the database they replace: say where, or the copy is of no use.
    private func keptDatabaseNote(_ url: URL) -> String {
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        return String(localized: "The previous database was kept at \(path).")
    }

    // MARK: - Backup / Restore

    func createBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.database]
        panel.nameFieldStringValue = "termi-backup-\(dateString()).db"
        panel.message = String(localized: "Save a database backup")
        // The standard profile leaves the folder to the panel (it reopens where it was last
        // used); any other profile suggests its own folder, away from the owner's backups.
        let profile = AppProfile.current
        if profile.kind != .standard {
            try? FileManager.default.createDirectory(at: profile.backupDirectory, withIntermediateDirectories: true)
            panel.directoryURL = profile.backupDirectory
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        performAsync {
            try await self.importExport.createBackup(to: url)
            self.exportResult = String(localized: "Backup saved to \(url.lastPathComponent)")
            self.rememberBackup(at: url)
            await self.loadBackupOverview()
        }
    }

    func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.database]
        panel.message = String(localized: "Select a database backup to restore")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Choosing a file is not agreeing to lose the current data: the page no longer carries
        // a standing warning, so this is where it is said.
        guard confirmRestoring(named: url.lastPathComponent) else { return }
        restore(from: url)
    }

    /// Restores one of the listed files.
    func restoreBackup(_ file: BackupFile) {
        guard confirmRestoring(named: file.name) else { return }
        restore(from: file.url)
    }

    private func restore(from url: URL) {
        performAsync {
            do {
                let kept = try await self.importExport.restoreBackup(from: url)
                self.importResult = String(localized: "Restored from backup. Restart Termi to apply it.")
                    + "\n" + self.keptDatabaseNote(kept)
            } catch {
                // A listed file that went away since the page was read is one way to get here:
                // the list must not go on offering it.
                await self.loadBackupOverview()
                throw error
            }
            await self.loadBackupOverview()
        }
    }

    /// Every restore asks first, whichever button started it: what is replaced, where the
    /// database it replaces is kept, and that the app has to restart.
    private func confirmRestoring(named name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restore “\(name)”?")
        alert.informativeText = Self.restoreWarning(databaseFolder: backupOverview.databaseFolder)
        alert.alertStyle = .warning
        let restore = alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        // Return does nothing and Esc cancels: replacing everything takes a deliberate click.
        restore.hasDestructiveAction = true
        restore.keyEquivalent = ""
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// What the confirmation of a restore says. `databaseFolder` is where the replaced database
    /// stays; without it (not read yet) the sentence still says beside what.
    nonisolated static func restoreWarning(databaseFolder: URL?) -> String {
        let kept: String
        if let databaseFolder {
            let path = (databaseFolder.path as NSString).abbreviatingWithTildeInPath
            kept = String(localized: "The current database is kept first, as termi.before-restore-*.db in \(path).")
        } else {
            kept = String(localized: "The current database is kept first, as termi.before-restore-*.db beside the database.")
        }
        return String(localized: "Everything in Termi — hosts, keys, identities, snippets, settings, saved passwords — will be replaced by this backup.")
            + " " + kept + " " + String(localized: "Termi needs to restart after the restore.")
    }

    func revealInFinder(_ file: BackupFile) {
        // The row was read a moment ago; the file may have been moved since. Finder would
        // open nothing and say nothing.
        guard FileManager.default.fileExists(atPath: file.url.path) else {
            error = String(localized: "“\(file.name)” is no longer there.")
            Task { await loadBackupOverview() }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    /// Takes a backup whose disk is not connected off the list. Only the note is removed;
    /// no file is touched.
    func forgetBackup(_ file: BackupFile) {
        let noted = Self.storedBackupRecords(in: AppProfile.defaults).filter { $0.path == file.url.path }
        Self.forgetBackupRecords(noted, in: AppProfile.defaults)
        Task { await loadBackupOverview() }
    }

    // MARK: - Backup overview

    /// Backups go wherever the save panel says, so the app keeps its own note of where and
    /// when. The note is only a pointer: what the page says comes from checking it against
    /// the files (`BackupOverview.check`), every time the page is read.
    nonisolated static let backupRecordsKey = "backupRecords"

    private func rememberBackup(at url: URL) {
        let record = BackupRecord(path: url.path, date: Date(),
                                  volume: BackupFileProbe.live.volumeIdentifier(url.path))
        let defaults = AppProfile.defaults
        Self.storeBackupRecords(BackupOverview.recording(record, in: Self.storedBackupRecords(in: defaults)),
                                in: defaults)
    }

    nonisolated static func storedBackupRecords(in defaults: UserDefaults) -> [BackupRecord] {
        guard let data = defaults.data(forKey: backupRecordsKey) else { return [] }
        return (try? JSONDecoder().decode([BackupRecord].self, from: data)) ?? []
    }

    nonisolated static func storeBackupRecords(_ records: [BackupRecord], in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: backupRecordsKey)
        }
    }

    /// Takes these entries out of the stored note and saves it, if that changes anything.
    /// The note is read again here rather than replaced by an earlier reading: a backup made
    /// while the files were being checked stays.
    nonisolated static func forgetBackupRecords(_ dropped: [BackupRecord], in defaults: UserDefaults) {
        guard !dropped.isEmpty else { return }
        let stored = storedBackupRecords(in: defaults)
        let remaining = stored.filter { !dropped.contains($0) }
        guard remaining != stored else { return }
        storeBackupRecords(remaining, in: defaults)
    }

    /// Reads what the Backup page shows: the backups made from here, the databases a restore
    /// or an import kept, and the size of the database — all of it from the file system. The
    /// only thing written is the note itself, without the entries whose file is gone.
    func loadBackupOverview() async {
        #if DEBUG
        // -debugBackupSample YES: the page with a few backups, for screenshots (the test
        // profile has none). Nothing is written.
        if AppProfile.arguments.bool(forKey: "debugBackupSample") {
            backupOverview = .debugSample
            return
        }
        #endif

        backupOverviewGeneration += 1
        let generation = backupOverviewGeneration

        // Off the main actor: a noted backup may sit on a volume that answers slowly.
        let records = Self.storedBackupRecords(in: AppProfile.defaults)
        let databaseURL = try? await DatabaseManager.shared.databaseURL
        let listing = await Task.detached {
            SettingsViewModel.backupListing(records: records, databaseURL: databaseURL, probe: .live)
        }.value
        // A reload that started later has read newer facts (a backup just made): it publishes.
        guard generation == backupOverviewGeneration else { return }

        Self.forgetBackupRecords(listing.check.dropped, in: AppProfile.defaults)

        var overview = BackupOverview()
        overview.records = listing.check.kept
        overview.files = listing.files
        overview.databaseSize = listing.databaseSize
        overview.databaseFolder = databaseURL?.deletingLastPathComponent()
        backupOverview = overview
    }

    struct BackupListing: Sendable {
        let check: BackupRecordCheck
        let files: [BackupFile]
        let databaseSize: Int64?
    }

    /// The noted backups checked against the files, the databases kept beside the database,
    /// and the size of the database itself. Reads file attributes only.
    nonisolated static func backupListing(records: [BackupRecord], databaseURL: URL?,
                                          probe: BackupFileProbe) -> BackupListing {
        let fm = FileManager.default
        let check = BackupOverview.check(records, probe: probe)
        var files: [BackupFile] = check.kept.compactMap { record in
            let url = URL(fileURLWithPath: record.path)
            // No file to read a date or a size from right now: the row says why, with the
            // date the backup was made.
            if check.unreachable.contains(record) {
                return BackupFile(url: url, kind: .backup, date: record.date, size: 0,
                                  availability: .diskNotConnected)
            }
            if check.unreadable.contains(record) {
                return BackupFile(url: url, kind: .backup, date: record.date, size: 0,
                                  availability: .cannotBeRead)
            }
            return BackupFile(url: url, kind: .backup, fileManager: fm)
        }
        var databaseSize: Int64?
        if let dbURL = databaseURL {
            let folder = dbURL.deletingLastPathComponent()
            let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            let stem = dbURL.deletingPathExtension().lastPathComponent
            files += names
                .filter { BackupOverview.isKeptDatabase($0, stem: stem, pathExtension: dbURL.pathExtension) }
                .compactMap { BackupFile(url: folder.appendingPathComponent($0), kind: .keptDatabase, fileManager: fm) }

            // WAL mode: what has not been checkpointed yet is part of the database too.
            let sizes = [dbURL.path, dbURL.path + "-wal"].compactMap {
                (try? fm.attributesOfItem(atPath: $0))?[.size] as? Int64
            }
            databaseSize = sizes.isEmpty ? nil : sizes.reduce(0, +)
        }
        return BackupListing(check: check, files: BackupOverview.sorted(files), databaseSize: databaseSize)
    }

    // MARK: - Where things are

    /// A folder or file as the Settings pages write it: the path the app uses, letter for
    /// letter (not standardized — that would turn /private/tmp into /tmp), the home folder as "~".
    nonisolated static func displayPath(_ url: URL, home: String = NSHomeDirectory()) -> String {
        let path = url.path
        guard home.count > 1 else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }

    /// Where this profile's encrypted exports are written (Settings › Sync).
    nonisolated static func syncFolderText(for profile: AppProfile.Locations = AppProfile.current,
                                           home: String = NSHomeDirectory()) -> String {
        displayPath(profile.syncDirectory, home: home)
    }

    /// The key file a backup does not include (Settings › Backup).
    nonisolated static func vaultKeyText(for profile: AppProfile.Locations = AppProfile.current,
                                         home: String = NSHomeDirectory()) -> String {
        displayPath(profile.vaultKeyURL, home: home)
    }

    private func dateString() -> String {
        DisplayDateFormatter.backupFilename.string(from: Date())
    }
}

// MARK: - Backup overview

/// A backup made from Settings: where it was saved and when.
struct BackupRecord: Codable, Equatable, Sendable {
    let path: String
    let date: Date
    /// The volume the file was written to (`BackupFileProbe.volumeIdentifier`). It tells a
    /// deleted backup from one whose disk is not connected. Nil in notes written before this
    /// was kept.
    let volume: String?

    init(path: String, date: Date, volume: String? = nil) {
        self.path = path
        self.date = date
        self.volume = volume
    }
}

/// The questions the check of a noted backup asks the file system. A value, so that a disk
/// that is not connected can be described in a test.
struct BackupFileProbe: Sendable {
    /// Whether something is at this path.
    var exists: @Sendable (String) -> Bool
    /// What identifies the volume holding this (existing) path: its UUID, or its mount point
    /// for a volume without one (some network shares).
    var volumeIdentifier: @Sendable (String) -> String?
    /// Whether a folder is at this path: a folder where the backup file was is not the backup.
    var isFolder: @Sendable (String) -> Bool = { _ in false }
    /// Whether the file system would not say if this path is there — no permission to look
    /// into its folder (also a privacy refusal for Documents / Desktop / Downloads), an I/O
    /// error — as opposed to answering "no such file". `exists` is false in both cases, and
    /// only the second one is a deleted backup.
    var cannotTell: @Sendable (String) -> Bool = { _ in false }

    static let live = BackupFileProbe(
        exists: { FileManager.default.fileExists(atPath: $0) },
        volumeIdentifier: { path in
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
            if let uuid = values?.volumeUUIDString { return uuid }
            return values?.volume.map { "mount:" + $0.path }
        },
        isFolder: { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        },
        cannotTell: { path in
            var info = stat()
            guard stat(path, &info) != 0 else { return false }
            let code = errno
            // "Not there" is said in exactly these two ways (the second: a file where a folder
            // of the path used to be). Everything else is no answer.
            return code != ENOENT && code != ENOTDIR
        }
    )
}

/// The stored note after it was checked against the files.
struct BackupRecordCheck: Equatable, Sendable {
    /// Still counts: the file is there, its disk is not connected, or nothing can be said.
    var kept: [BackupRecord] = []
    /// The part of `kept` whose disk is not connected.
    var unreachable: [BackupRecord] = []
    /// The part of `kept` the file system would not answer for (`BackupFileProbe.cannotTell`).
    var unreadable: [BackupRecord] = []
    /// The file is gone from a place that is there: deleted or moved.
    var dropped: [BackupRecord] = []
}

/// A file the Backup page lists: a backup, or the database a restore / an import replaced.
struct BackupFile: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case backup
        /// `termi.before-….db` beside the database.
        case keptDatabase
    }

    let url: URL
    let kind: Kind
    let date: Date
    let size: Int64

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    enum Availability: Equatable, Sendable {
        /// The file is there.
        case here
        /// A noted backup on a disk that is not connected.
        case diskNotConnected
        /// A noted backup the file system would not answer for (no permission to look).
        case cannotBeRead
    }

    let availability: Availability

    /// False for a noted backup that is not in reach: there is no file to show, restore or
    /// measure right now, and `date` is when the backup was made.
    var isReachable: Bool { availability == .here }

    init(url: URL, kind: Kind, date: Date, size: Int64, availability: Availability = .here) {
        self.url = url
        self.kind = kind
        self.date = date
        self.size = size
        self.availability = availability
    }

    /// Nil when the file is not there (any more): moved or deleted backups drop off the list.
    init?(url: URL, kind: Kind, fileManager: FileManager) {
        // Through a link to the file itself: a link's own attributes are the link's (its size
        // is the length of the path it holds), not the backup's.
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
              let date = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int64 else { return nil }
        self.init(url: url, kind: kind, date: date, size: size)
    }
}

/// What Settings › Backup shows: the backups it knows of and the size of the database.
struct BackupOverview: Equatable, Sendable {
    /// The noted backups that passed the check against the files (`check`), never the stored
    /// note as it was: what is derived from them — "Last backup" — is about backups that exist.
    var records: [BackupRecord] = []
    var files: [BackupFile] = []
    var databaseSize: Int64?
    /// Where the database is — and where a restore keeps the one it replaces.
    var databaseFolder: URL?

    /// The note is a convenience, not a log: old entries fall off.
    static let recordLimit = 30

    var lastBackupDate: Date? { records.map(\.date).max() }

    /// Where a row's file is, when that needs saying: a backup outside the folder of the
    /// newest one (where the save panel opens next time). The kept databases are always beside
    /// the database — their tag says what they are.
    func unusualFolder(of file: BackupFile) -> URL? {
        guard file.kind == .backup else { return nil }
        let folder = file.url.deletingLastPathComponent()
        // A backup that is not in reach always says where it is: that is the disk to connect,
        // or the folder to look into.
        guard file.isReachable else { return folder }
        guard let usual = files.first(where: { $0.kind == .backup && $0.isReachable }) else { return nil }
        return folder.standardizedFileURL == usual.url.deletingLastPathComponent().standardizedFileURL ? nil : folder
    }

    /// The note with one more backup: newest first, one entry per file (saving over a backup
    /// replaces its entry), at most `recordLimit`.
    static func recording(_ record: BackupRecord, in records: [BackupRecord]) -> [BackupRecord] {
        var result = records.filter { $0.path != record.path }
        result.append(record)
        result.sort { $0.date > $1.date }
        return Array(result.prefix(recordLimit))
    }

    /// Checks the note against the files. A record counts while its file exists. A record
    /// whose file is gone is dropped when the place it was in is still there (the file was
    /// deleted or moved) and kept when that place itself is not reachable: a disk that is not
    /// connected has not lost its backup. Kept too when the file system gives no answer:
    /// "may not look" is not "deleted".
    static func check(_ records: [BackupRecord], probe: BackupFileProbe) -> BackupRecordCheck {
        var result = BackupRecordCheck()
        for record in records {
            switch state(of: record, probe: probe) {
            case .present:
                result.kept.append(record)
            case .unreachable:
                result.kept.append(record)
                result.unreachable.append(record)
            case .unreadable:
                result.kept.append(record)
                result.unreadable.append(record)
            case .missing:
                result.dropped.append(record)
            }
        }
        return result
    }

    enum RecordState: Equatable, Sendable {
        case present, missing, unreachable, unreadable
    }

    static func state(of record: BackupRecord, probe: BackupFileProbe) -> RecordState {
        if probe.exists(record.path) {
            // A folder that took the file's place is not the backup: the file is gone.
            return probe.isFolder(record.path) ? .missing : .present
        }
        // Asked before anything is concluded from "not there": a folder the app may not look
        // into answers the same for a file that is in it.
        if probe.cannotTell(record.path) { return .unreadable }

        // The deepest folder of the path that is there now: the place the file would be in.
        var ancestor = (record.path as NSString).deletingLastPathComponent
        while ancestor != "/", !ancestor.isEmpty, !probe.exists(ancestor) {
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }

        if let volume = record.volume {
            // Same volume as when the backup was written: the disk is here and the file is
            // not. Another volume (the mount point is gone, or is an empty folder on the
            // startup disk), or one that cannot be identified: not reachable — kept.
            return probe.volumeIdentifier(ancestor) == volume ? .missing : .unreachable
        }
        // A note from before volumes were kept: only the usual mount folder can tell.
        let parts = (record.path as NSString).pathComponents
        if parts.count > 3, parts[1] == "Volumes", !probe.exists("/Volumes/" + parts[2]) {
            return .unreachable
        }
        return .missing
    }

    /// `termi.before-restore-20260928-101502.db` and its like beside `termi.db`.
    static func isKeptDatabase(_ filename: String, stem: String, pathExtension: String) -> Bool {
        filename.hasPrefix(stem + ".before-") && filename.hasSuffix("." + pathExtension)
    }

    /// Newest first; a file that is both noted and kept is listed once.
    static func sorted(_ files: [BackupFile]) -> [BackupFile] {
        var seen = Set<String>()
        return files
            .sorted { $0.date == $1.date ? $0.name < $1.name : $0.date > $1.date }
            .filter { seen.insert($0.id).inserted }
    }

    #if DEBUG
    /// Sample data for `-debugBackupSample YES`. The files do not exist.
    static var debugSample: BackupOverview {
        let now = Date()
        let folder = AppProfile.current.backupDirectory
        // Where this run's database really is: the restore confirmation names this folder.
        let databaseFolder = AppProfile.current.directory
        let recent = now.addingTimeInterval(-2 * 3600)
        let older = now.addingTimeInterval(-6 * 86_400 - 9 * 3600)
        var overview = BackupOverview()
        overview.records = [
            BackupRecord(path: folder.appendingPathComponent("termi-backup-20261004-194200.db").path, date: recent),
            BackupRecord(path: folder.appendingPathComponent("termi-backup-20260928-101500.db").path, date: older)
        ]
        overview.files = [
            BackupFile(url: folder.appendingPathComponent("termi-backup-20261004-194200.db"), kind: .backup,
                       date: recent, size: 1_258_291),
            BackupFile(url: folder.appendingPathComponent("termi-backup-20260928-101500.db"), kind: .backup,
                       date: older, size: 1_240_000),
            BackupFile(url: databaseFolder.appendingPathComponent("termi.before-restore-20260928-101502.db"),
                       kind: .keptDatabase, date: older.addingTimeInterval(2), size: 1_153_434)
        ]
        overview.databaseSize = 1_258_291
        overview.databaseFolder = databaseFolder
        return overview
    }
    #endif
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the user changes the app appearance (Dark / Light / System) in Settings.
    /// `userInfo["theme"]` contains the new `String` value.
    static let terminalThemeChanged = Notification.Name("dev.termi.Termi.terminalThemeChanged")

    /// Posted by AppDelegate when database initialization fails.
    /// `userInfo["message"]` contains the error description `String`.
    static let databaseInitFailed = Notification.Name("dev.termi.Termi.databaseInitFailed")
}
