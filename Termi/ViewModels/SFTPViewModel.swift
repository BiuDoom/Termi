import SwiftUI
import UniformTypeIdentifiers
import os.log

/// A file transfer shown in the SFTP transfer queue.
struct TransferItem: Identifiable, Equatable {
    enum Direction: Equatable {
        case upload, download
    }

    enum State: Equatable {
        case running
        case completed
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let name: String
    let direction: Direction
    var totalBytes: Int64
    var transferredBytes: Int64 = 0
    var state: State = .running
    /// Reset when a queued transfer gets its slot, so waiting does not count as transfer time.
    var startedAt = Date()
    var finishedAt: Date?
    /// What a completed transfer left out (links, special files, names that collide locally).
    var skipped = SFTPSkippedItems()
    /// Files already on the server the user chose to keep instead of replacing them.
    var kept = SFTPSkippedItems()
    /// A question about this transfer is open (a file of the same name, a file that cannot be
    /// replaced safely): it waits for the user, not for the network.
    var awaitingDecision = false
    /// The folder it goes into, as shown in the transfer bar ("~/Projects", "/home/deploy").
    var destination = ""

    var fraction: Double {
        guard totalBytes > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    /// Bytes per second over the whole transfer.
    var speed: Double {
        let elapsed = (finishedAt ?? Date()).timeIntervalSince(startedAt)
        return elapsed > 0.2 ? Double(transferredBytes) / elapsed : 0
    }

    /// Seconds to go at the speed so far; nil when that cannot be told (no speed yet, no total).
    var secondsLeft: Double? {
        guard state == .running, totalBytes > transferredBytes else { return nil }
        let speed = self.speed
        return speed > 0 ? Double(totalBytes - transferredBytes) / speed : nil
    }
}

/// The transfer queue in four numbers, for the head of the transfer bar.
struct TransferSummary: Equatable {
    var running = 0
    var finished = 0
    /// Share of the bytes of the running transfers that is through; nil while nothing runs or
    /// no size is known yet.
    var fraction: Double?
    /// Bytes per second of the running transfers together.
    var speed: Double = 0

    init(_ transfers: [TransferItem]) {
        var total: Int64 = 0
        var done: Int64 = 0
        for transfer in transfers {
            guard transfer.state == .running else {
                finished += 1
                continue
            }
            running += 1
            speed += transfer.speed
            total += transfer.totalBytes
            done += min(transfer.transferredBytes, transfer.totalBytes)
        }
        if running > 0, total > 0 {
            fraction = min(1, Double(done) / Double(total))
        }
    }
}

/// One step of the path shown in a file panel's path bar.
struct SFTPBreadcrumb: Equatable {
    let title: String
    /// The folder this step opens.
    let path: String
}

/// A panel's path as steps. A path below `home` starts at home (the house, then the folders
/// below it); any other starts at the root.
struct SFTPBreadcrumbs: Equatable {
    var startsAtHome = false
    /// Where the leading icon goes: home or "/".
    var rootPath = "/"
    var steps: [SFTPBreadcrumb] = []

    init(path: String, home: String?) {
        var rest = path
        var base = ""
        if let home, home != "/", !home.isEmpty, let below = SFTPPathKey.remainder(of: path, below: home) {
            startsAtHome = true
            rootPath = home
            base = home
            rest = below
        }
        // By bytes: a combining character after a "/" would hide that "/" from `split` on
        // characters, and the step would open another folder.
        var current = base
        for component in rest.utf8.split(separator: UInt8(ascii: "/")) {
            let name = String(decoding: component, as: UTF8.self)
            current += "/" + name
            steps.append(SFTPBreadcrumb(title: name, path: current))
        }
    }
}

/// What a panel's footer says about its rows: how many, how much, and the same of the selection.
struct SFTPListingSummary: Equatable {
    var count = 0
    var bytes: Int64 = 0
    var selectedCount = 0
    var selectedBytes: Int64 = 0

    /// Folders count as items but not towards the size (their own size says nothing).
    init(items: [SFTPItem], selection: Set<SFTPItem.ID>) {
        for item in items {
            count += 1
            let size = item.isDirectory ? 0 : item.size
            bytes += size
            if selection.contains(item.id) {
                selectedCount += 1
                selectedBytes += size
            }
        }
    }
}

extension SFTPItem {
    /// When a file was changed, for the file list: today's with the time ("Today 21:40"),
    /// older ones as a day ("Sep 30"), from another year with the year. `compact` is for a
    /// narrow panel: the time alone today, the day otherwise.
    static func modifiedText(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = .current, compact: Bool = false) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                    timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            if compact { return date.formatted(time) }
            // Every row of a listing asks: the user's own formatter is built once.
            let relative = locale == Locale.current && calendar == Calendar.current
                ? todayFormatter : relativeDayFormatter(locale: locale, calendar: calendar)
            return relative.string(from: date) + " " + date.formatted(time)
        }
        var day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
            day = day.year(compact ? .twoDigits : .defaultDigits)
        }
        return date.formatted(day)
    }

    /// The word for a day next to today ("Today", "今天"), in the user's locale and calendar
    /// (left at the formatter's defaults, which follow the system's settings).
    private static let todayFormatter = relativeDayFormatter(locale: nil, calendar: nil)

    private static func relativeDayFormatter(locale: Locale?, calendar: Calendar?) -> DateFormatter {
        let formatter = DateFormatter()
        if let locale { formatter.locale = locale }
        if let calendar {
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
        }
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }

    /// "rwxr-xr-x": the permission string without its leading type character.
    var permissionBits: String {
        permissions.count == 10 ? String(permissions.dropFirst()) : permissions
    }
}

/// A remote file opened in a local editor; saving it uploads it back.
struct RemoteEditItem: Identifiable, Equatable {
    let id = UUID()
    /// Where saves are uploaded to: the path the file was listed under, byte for byte. It
    /// follows the file when it (or a folder above it) is renamed on the server.
    var remotePath: String
    let localURL: URL
    /// The folder made for this copy alone, which goes when the edit ends. Remembered rather
    /// than taken from `localURL` when needed: that URL ends in a name the server chose.
    let folder: URL?
    var lastUploadedModification: Date?
    var status: String = ""
    /// The local copy is being uploaded right now.
    var isUploading = false
    /// The last upload failed: the server does not have the save it was for.
    var uploadFailed = false
    /// Where the server cannot replace the file atomically, whether the user agreed to have the
    /// saves overwrite it in place (asked once per edit; nil until then).
    var allowsInPlaceReplace: Bool?
    /// Why the last save could not replace the file atomically.
    var blockedReason: SFTPClient.AtomicBlockReason?
    /// The folder the file was opened from, when that is not where it is (a link was opened:
    /// the saves go to the file it points to).
    var listedFolder: String?

    /// Without `folder`, it is the one the copy lies in — unless the copy's path has a ".."
    /// in it, when that would be some other folder and none is cleaned up.
    init(remotePath: String, localURL: URL, folder: URL? = nil, lastUploadedModification: Date? = nil,
         status: String = "", isUploading: Bool = false, uploadFailed: Bool = false) {
        self.remotePath = remotePath
        self.localURL = localURL
        self.folder = folder
            ?? (localURL.pathComponents.contains("..") ? nil : localURL.deletingLastPathComponent())
        self.lastUploadedModification = lastUploadedModification
        self.status = status
        self.isUploading = isUploading
        self.uploadFailed = uploadFailed
    }

    /// The file's name and its folder on the server, to tell two edits of the same name apart.
    var remoteName: String { SFTPClient.name(of: remotePath) }
    var remoteFolder: String { SFTPClient.parent(of: remotePath) }

    /// Where `path` is after `old` was renamed to `new` on the server: `new` for the item
    /// itself, the same place below `new` for what was below `old`, nil for everything else.
    static func rebased(_ path: String, from old: String, to new: String) -> String? {
        SFTPPathKey.remainder(of: path, below: old).map { new + $0 }
    }

    /// Whether the local copy holds changes the server has not received: a save that is still
    /// to be uploaded (no connection, or not noticed yet), is being uploaded, or whose upload
    /// failed. Such a copy is never deleted. `modified` is the copy's modification date now;
    /// nil means the file is gone, so there is nothing to keep.
    func hasChangesNotOnServer(modified: Date?) -> Bool {
        guard let modified else { return false }
        return isUploading || uploadFailed || modified != lastUploadedModification
    }
}

/// What the SFTP page has to say about something it did not do the obvious way — a local copy it
/// moved to the Trash instead of deleting, a host it did not switch to — until it is closed.
struct SFTPNotice: Equatable {
    var text: String
    /// The files it is about, for "Reveal in Finder".
    var files: [URL] = []
}

/// Where the local copies of remote files being edited live: one folder per app instance in the
/// temporary directory (`Termi-Edit-<pid>`, like the SSH runtime's `bmt-<pid>`), so that a
/// second instance, the app hosting the unit tests or the next launch never touches the files a
/// running instance is editing.
enum RemoteEditFolder {
    static let prefix = "Termi-Edit-"

    /// The folder of the app instance with this process id (by default this one).
    static func url(forProcess pid: Int32 = getpid(),
                    in parent: URL = FileManager.default.temporaryDirectory) -> URL {
        parent.appendingPathComponent("\(prefix)\(pid)", isDirectory: true)
    }

    /// Empties an instance folder nobody keeps track of any more (its instance is quitting or
    /// gone). Nothing says whether the server has the changes of the copies in it, so none is
    /// deleted: each goes to the Trash, and a folder is removed only once it is empty. Returns
    /// where the files are in the Trash.
    @discardableResult
    static func sweep(_ folder: URL, trash: (URL) throws -> URL = SFTPClient.moveToTrash) -> [URL] {
        let fm = FileManager.default
        var trashed: [URL] = []
        func moveAside(_ url: URL) {
            if let location = try? trash(url) { trashed.append(location) }
        }
        let keys: [URLResourceKey] = [.isDirectoryKey]
        for entry in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [] {
            // One folder per edited file; anything else in here is treated like a copy.
            guard (try? entry.resourceValues(forKeys: Set(keys)))?.isDirectory == true else {
                moveAside(entry)
                continue
            }
            for copy in (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [] {
                moveAside(copy)
            }
            // rmdir(2) only removes an empty folder: a copy the Trash did not take stays.
            _ = rmdir(entry.path)
        }
        _ = rmdir(folder.path)
        return trashed
    }

    /// Launch clean-up: sweeps the folders of instances that are no longer running (a crash or
    /// a kill skipped their clean-up on quit). The folder of a running instance is not touched,
    /// and neither is the shared `Termi-Edit` folder of earlier builds — there is no telling
    /// whether such a build is still running. Returns where the files are in the Trash.
    @discardableResult
    static func sweepStale(in parent: URL = FileManager.default.temporaryDirectory,
                           isAlive: (Int32) -> Bool = SSHRuntime.isProcessAlive,
                           trash: (URL) throws -> URL = SFTPClient.moveToTrash) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        var trashed: [URL] = []
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            guard let pid = Int32(entry.lastPathComponent.dropFirst(prefix.count)),
                  pid > 0, pid != getpid(), !isAlive(pid) else { continue }
            trashed += sweep(entry, trash: trash)
        }
        return trashed
    }
}

/// One pending question about an upload, for one file. One is shown at a time.
struct SFTPUploadConflict: Identifiable {
    enum Kind {
        /// A file of that name is on the server already (what the server says about it, and
        /// the file on this Mac that would replace it): replace, skip, or cancel the upload?
        case nameTaken(existing: SFTPClient.Attributes, local: URL)
        /// It cannot be replaced atomically (why): overwrite it in place, or cancel?
        case unsafeReplace(SFTPClient.AtomicBlockReason)
    }

    let id: UUID
    /// The transfer it belongs to (for an edit's save, the edit).
    let transferID: UUID
    let path: String
    var kind: Kind
    /// The upload it belongs to (one drop, one "Upload…"); nil for an edit's save.
    var batchID: UUID?
    /// That upload has other files, so "do the same for the others" means something.
    var offersApplyToAll = false
}

/// ViewModel for the SFTP browser. Owned by the window's AppViewModel so the session and
/// transfers survive navigating to other pages.
@Observable
@MainActor
final class SFTPViewModel {
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "SFTPVM")

    // Connection
    var hosts: [Host] = []
    /// True once the first `loadHosts()` is over (the page draws no empty state before that).
    private(set) var hostsLoaded = false
    var hostsError: String?
    var selectedHost: Host?
    var isConnecting = false
    var connectionError: String?
    /// The host `connectionError` is about, to try it again (it need not be a saved host).
    private(set) var failedHost: Host?
    @ObservationIgnored private var session: SFTPSession?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var connectionTask: Task<SFTPSession, Error>?
    @ObservationIgnored private let openSession: @MainActor (Host) async throws -> SFTPSession
    var isConnected = false

    // Remote browser
    var remotePath = "/"
    var remoteItems: [SFTPItem] = []
    /// The directory `remoteItems` was listed from. While a folder loads, the rows of the one
    /// before stay (no empty panel on every navigation) under a path bar that already names
    /// the new one — see `remoteListingIsCurrent`.
    private(set) var listedRemotePath: String?
    /// Counts the loads: only the answer to the latest one is shown.
    @ObservationIgnored private var remoteLoadToken = 0
    var remoteLoading = false
    var remoteError: String?
    /// Why something asked of the remote panel was not done (a name that is taken, a refused
    /// rename or delete, a path that does not resolve). Shown as an alert: the rows are still
    /// the folder's and stay where they are, unlike `remoteError`, which stands in their place
    /// when the folder itself could not be listed.
    var remoteActionError: String?
    var showHiddenRemote = false {
        didSet { pruneSelections() }
    }
    var selectedRemoteItems: Set<SFTPItem.ID> = []
    private var remoteHistory: [String] = []
    /// What a drag out of the remote panel carries, per row, and the row it stands for. The
    /// text is random: it names no path, so nothing a server chose is dropped into another
    /// app, and only this page — not another window's, on another host — can turn it back
    /// into a file. Forgotten when the rows change.
    @ObservationIgnored private var remoteDragPayloads: [SFTPItem.ID: String] = [:]
    @ObservationIgnored private var remoteDragRows: [String: SFTPItem.ID] = [:]

    // Local browser
    var localPath: String
    var localItems: [SFTPItem] = []
    var showHiddenLocal = false {
        didSet { pruneSelections() }
    }
    var selectedLocalItems: Set<SFTPItem.ID> = []
    @ObservationIgnored private var localLoadTask: Task<Void, Never>?

    // Transfers & remote editing
    var transfers: [TransferItem] = []
    @ObservationIgnored private var transferTasks: [UUID: Task<Void, Never>] = [:]
    /// Transfers running at once; the rest wait. Each one holds a local file descriptor, and a
    /// GUI process may only have 256 open.
    private static let maxConcurrentTransfers = 4
    @ObservationIgnored private var activeTransferCount = 0
    private(set) var uploadConflict: SFTPUploadConflict?
    @ObservationIgnored private var conflictContinuation: CheckedContinuation<SFTPUploadDecision, Error>?
    /// "Do the same for the other files of this upload": the answer per upload (one drop, one
    /// "Upload…"), for files of the same name and for files to overwrite in place. Forgotten
    /// when that upload's last transfer ends, and on disconnect. Cancel is never remembered.
    @ObservationIgnored private var rememberedUploadDecisions: [UUID: SFTPUploadDecision] = [:]
    @ObservationIgnored private var rememberedInPlaceDecisions: [UUID: SFTPUploadDecision] = [:]
    @ObservationIgnored private var transferBatches: [UUID: UUID] = [:]
    @ObservationIgnored private var unfinishedInBatch: [UUID: Int] = [:]
    var editItems: [RemoteEditItem] = []
    @ObservationIgnored private var editWatchers: [UUID: Task<Void, Never>] = [:]
    /// Resolved server/account/jump route the files came from, independent of database ids.
    @ObservationIgnored private var editEndpoint: SFTPEndpoint?
    /// Shown at the bottom of the page until it is closed: above all where the local copies went
    /// whose changes never reached the server.
    var notice: SFTPNotice?
    /// Moves a local copy to the Trash (replaced in tests).
    @ObservationIgnored var moveToTrash: (URL) throws -> URL = SFTPClient.moveToTrash
    /// Where the local copies of files being edited go (the tests hand in a folder of theirs).
    @ObservationIgnored var editFolder = RemoteEditFolder.url()
    /// Opens a local copy in place of its editor. Nil outside the tests, which must not
    /// launch another app.
    @ObservationIgnored var editorForTests: ((URL) -> Void)?

    // Dialogs
    var showingNewFolder = false
    var newFolderName = ""
    /// The directory "New Folder" was chosen in: where the folder is made, also when another
    /// directory has been opened by the time the name is confirmed.
    @ObservationIgnored private var newFolderParent: String?
    var showingChmod = false
    var chmodTarget: SFTPItem?
    var chmodValue = "755"
    var showingRename = false
    var renameTarget: SFTPItem?
    var renameValue = ""
    var showingDeleteConfirm = false
    var deleteTargets: [SFTPItem] = []

    init(openSession: @escaping @MainActor (Host) async throws -> SFTPSession = { try await SFTPSession.open(host: $0) }) {
        self.openSession = openSession
        localPath = FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// "user@example-host": the account the local panel's files belong to, written like the
    /// remote panel's address.
    static let localAccount = accountText(user: NSUserName(), hostName: kernelHostName())

    /// The name the kernel has. (`ProcessInfo.hostName` asks the resolver, and can keep the
    /// main thread waiting for seconds on a network without an answer.)
    private nonisolated static func kernelHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The Mac's name without its ".local" (or any other domain).
    nonisolated static func accountText(user: String, hostName: String) -> String {
        let name = hostName.split(separator: ".").first.map(String.init) ?? ""
        return name.isEmpty ? user : user + "@" + name
    }

    /// The toolbar's switch, and the only one: hidden files in both panels at once.
    var showsHiddenFiles: Bool {
        get { showHiddenLocal && showHiddenRemote }
        set {
            showHiddenLocal = newValue
            showHiddenRemote = newValue
        }
    }

    /// Takes a failed connection attempt off the page.
    func dismissConnectionError() {
        connectionError = nil
        failedHost = nil
    }

    var visibleRemoteItems: [SFTPItem] {
        showHiddenRemote ? remoteItems : remoteItems.filter { !$0.name.hasPrefix(".") }
    }

    /// The selected remote items, among the rows that are shown. One whose name could not be
    /// sent back to the server as it is (`SFTPItem.isNameRepresentable`) is never among them:
    /// nothing can be done with it.
    var selectedRemote: [SFTPItem] {
        visibleRemoteItems.filter { selectedRemoteItems.contains($0.id) && $0.isNameRepresentable }
    }

    var visibleLocalItems: [SFTPItem] {
        showHiddenLocal ? localItems : localItems.filter { !$0.name.hasPrefix(".") }
    }

    /// The selected local items, among the rows that are shown.
    var selectedLocal: [SFTPItem] {
        visibleLocalItems.filter { selectedLocalItems.contains($0.id) }
    }

    /// A selection only ever holds rows that are shown, in both panels: Delete, Download and
    /// Upload act on the selection, and must not reach a file the user does not see (a hidden
    /// one still selected after "Show Hidden Files" was switched off, one gone after a reload).
    private func pruneSelections() {
        let remote = Self.selection(selectedRemoteItems, among: visibleRemoteItems)
        if remote != selectedRemoteItems { selectedRemoteItems = remote }
        let local = Self.selection(selectedLocalItems, among: visibleLocalItems)
        if local != selectedLocalItems { selectedLocalItems = local }
    }

    static func selection(_ selection: Set<SFTPItem.ID>, among rows: [SFTPItem]) -> Set<SFTPItem.ID> {
        guard !selection.isEmpty else { return selection }
        return selection.intersection(rows.map(\.id))
    }

    /// Whether the rows of the remote panel are the contents of `remotePath`. They are not
    /// while a folder that was just opened is still loading (the rows are the previous
    /// folder's) and while an error is shown in their place. Nothing is done to the server
    /// then: the path bar and the rows would each say something else about where it happens.
    var remoteListingIsCurrent: Bool {
        guard let listedRemotePath, remoteError == nil else { return false }
        return SFTPPathKey(listedRemotePath) == SFTPPathKey(remotePath)
    }

    /// Whether every one of `items` is a row the remote panel shows right now.
    func remotePanelShows(_ items: [SFTPItem]) -> Bool {
        guard remoteListingIsCurrent, !items.isEmpty else { return false }
        let shown = Set(visibleRemoteItems.map(\.id))
        return items.allSatisfy { shown.contains($0.id) && $0.isNameRepresentable }
    }

    /// A transfer in the queue is unfinished, or an edited file is being uploaded back.
    var hasActiveTransfers: Bool {
        transfers.contains { $0.state == .running } || editItems.contains { $0.isUploading }
    }

    /// Remote files being edited whose local copy has changes the server has not received.
    var unsyncedEditCount: Int {
        editItems.filter { $0.hasChangesNotOnServer(modified: Self.modificationDate(of: $0.localURL)) }.count
    }

    /// What closing these SFTP pages would cost, one line each, for the confirmation asked before
    /// a window closes or the app quits. Empty when nothing would be lost.
    static func closeWarnings(for pages: [SFTPViewModel]) -> [String] {
        // An edited file being uploaded back counts as an edit the server does not have.
        let transfers = pages.flatMap(\.transfers).filter { $0.state == .running }.count
        let unsynced = pages.reduce(0) { $0 + $1.unsyncedEditCount }
        var warnings: [String] = []
        if transfers > 0 {
            warnings.append(String(localized: "\(transfers) file transfer(s) will be cancelled."))
        }
        if unsynced > 0 {
            warnings.append(String(localized: "\(unsynced) remote file(s) being edited have changes that are not on the server. Their local copies will be moved to the Trash."))
        }
        return warnings
    }

    // MARK: - Hosts & connection

    func loadHosts() async {
        do {
            hosts = try await HostRepository.shared.fetchAll()
            hostsError = nil
            // The system of the host being browsed may have been read since: its tile follows.
            if let selected = selectedHost, selected.id != nil,
               let saved = hosts.first(where: { $0.id == selected.id && $0.connectionKey == selected.connectionKey }) {
                selectedHost?.osId = saved.osId
                selectedHost?.osName = saved.osName
                selectedHost?.osArch = saved.osArch
                selectedHost?.osDetectedAt = saved.osDetectedAt
            }
        } catch {
            guard !Task.isCancelled else { return }
            hostsError = error.localizedDescription
        }
        hostsLoaded = true
    }

    func connect(to host: Host) async {
        // The same host with the same connection: a newer copy of it (last connected, the
        // system read from it) is no reason to start over and lose the folder and history.
        if isConnected, let current = selectedHost, current.connectsLike(host),
           session?.isOpen == true {
            selectedHost = host
            return
        }
        // Another host while this one is transferring: switching would cancel that. (The toolbar
        // does not offer it then; "Open SFTP" in a terminal gets here all the same.)
        if session?.isOpen == true, hasActiveTransfers {
            addNotice(String(localized: "Transfers are still running here. Wait for them to finish before opening another host."))
            return
        }
        // Keep copies until the new connection's *resolved* account and route are known.
        // A saved host id can now refer to a different server or inherited username.
        disconnect(keepEdits: true)
        let generation = connectionGeneration
        selectedHost = host
        isConnecting = true
        connectionError = nil
        failedHost = nil
        let opening = Task { try await openSession(host) }
        connectionTask = opening
        defer {
            if connectionGeneration == generation {
                isConnecting = false
                connectionTask = nil
            }
        }

        do {
            let opened = try await withTaskCancellationHandler {
                try await opening.value
            } onCancel: { opening.cancel() }
            guard connectionGeneration == generation, !Task.isCancelled else {
                opened.close()
                return
            }
            adopt(opened)
            await loadRemoteDirectory()
            logger.info("SFTP connected to \(host.hostname)")
        } catch {
            guard connectionGeneration == generation else { return }
            guard !(error is CancellationError), !Task.isCancelled else {
                selectedHost = nil
                return
            }
            connectionError = error.localizedDescription
            selectedHost = nil
            failedHost = host
            logger.warning("SFTP connection to \(host.hostname) failed: \(error.localizedDescription)")
        }
    }

    /// Makes `session` the page's session, at its home directory. (The tests hand in a session
    /// that has no SSH connection behind it.)
    func adopt(_ session: SFTPSession) {
        if let editEndpoint, editEndpoint != session.endpoint {
            stopAllEditing()
        }
        self.session = session
        selectedHost = session.host
        isConnected = true
        remoteHistory = []
        remotePath = session.homeDirectory
        forgetRemoteListing()
    }

    /// The rows shown are no longer those of this page's session and directory; a listing
    /// still on its way is for a session that is gone.
    private func forgetRemoteListing() {
        remoteLoadToken += 1
        remoteLoading = false
        listedRemotePath = nil
        remoteDragPayloads = [:]
        remoteDragRows = [:]
    }

    func disconnect(keepEdits: Bool = false) {
        connectionGeneration = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        isConnecting = false
        for task in transferTasks.values { task.cancel() }
        if let conflict = uploadConflict { resolveUploadConflict(conflict.id, decision: .cancel) }
        transferTasks.removeAll()
        rememberedUploadDecisions = [:]
        rememberedInPlaceDecisions = [:]
        if !keepEdits { stopAllEditing() }
        session?.close()
        session = nil
        isConnected = false
        selectedHost = nil
        remoteItems = []
        remotePath = "/"
        remoteHistory = []
        selectedRemoteItems = []
        forgetRemoteListing()
    }

    private func requireSession() -> SFTPSession? {
        guard let session else { return nil }
        guard session.isOpen else {
            remoteError = String(localized: "The connection was closed. Reconnect to continue.")
            isConnected = false
            return nil
        }
        return session
    }

    // MARK: - Remote navigation

    func loadRemoteDirectory() async {
        guard let session = requireSession() else { return }
        let path = remotePath
        remoteLoadToken += 1
        let token = remoteLoadToken
        remoteLoading = true
        remoteError = nil
        do {
            let items = try await session.list(path)
            // Another load was started meanwhile (the user went on, or back): its answer is
            // the one to show. This one arriving late must not put its rows under that path.
            guard token == remoteLoadToken else { return }
            remoteItems = items
            listedRemotePath = path
            remoteDragPayloads = [:]
            remoteDragRows = [:]
            pruneSelections()
        } catch {
            guard token == remoteLoadToken else { return }
            remoteError = error.localizedDescription
            logger.error("Failed to list remote directory: \(error.localizedDescription)")
        }
        remoteLoading = false
    }

    func navigateRemote(to path: String) async {
        guard let session = requireSession() else { return }
        // Only what the server resolved becomes the current directory. Adopting the typed text
        // when it cannot be resolved ("docs", "~/x", a typo) would make every later request a
        // path relative to wherever the server happens to be.
        let target: String
        do {
            target = try await session.resolve(path)
        } catch {
            remoteActionError = error.localizedDescription
            return
        }
        guard SFTPPathKey(target) != SFTPPathKey(remotePath) else { return }
        let previousPath = remotePath
        let previousError = remoteError
        remoteHistory.append(remotePath)
        remotePath = target
        selectedRemoteItems = []
        await loadRemoteDirectory()
        // A folder that cannot be listed (a typo in the path bar: OpenSSH resolves names that
        // do not exist; a folder without read permission) is refused like any other action:
        // said in an alert, with the panel back where it was and its rows still the ones of
        // that folder. Staying there replaced the file list with the error and left the way
        // back to the user.
        if let refusal = remoteError, session.isOpen, remotePath == target,
           remoteHistory.last == previousPath {
            remoteHistory.removeLast()
            remotePath = previousPath
            remoteError = previousError
            remoteActionError = refusal
        }
    }

    /// Opens a row of the remote panel: a folder is entered, a file edited.
    func openRemote(_ item: SFTPItem) async {
        guard remotePanelShows([item]) else { return }
        if item.isDirectory {
            await navigateRemote(to: item.path)
        } else {
            await edit(item)
        }
    }

    func navigateRemoteUp() async {
        await navigateRemote(to: SFTPClient.parent(of: remotePath))
    }

    func navigateRemoteBack() async {
        guard let previous = remoteHistory.popLast() else { return }
        remotePath = previous
        selectedRemoteItems = []
        await loadRemoteDirectory()
    }

    var canGoBack: Bool { !remoteHistory.isEmpty }

    func navigateRemoteHome() async {
        guard let home = session?.homeDirectory else { return }
        await navigateRemote(to: home)
    }

    // MARK: - Local navigation

    /// Reads the local folder off the main actor: a protected folder (Desktop, Documents,
    /// Downloads, a network volume) can block until the user answers the system's access prompt.
    func loadLocalDirectory() {
        let path = localPath
        localLoadTask?.cancel()
        localLoadTask = Task { [weak self] in
            let items = await Task.detached(priority: .userInitiated) {
                SFTPViewModel.listLocalDirectory(path)
            }.value
            guard let self, !Task.isCancelled, self.localPath == path else { return }
            self.localItems = items
            self.pruneSelections()
        }
    }

    nonisolated static func listLocalDirectory(_ path: String) -> [SFTPItem] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])) ?? []
        return contents.compactMap { SFTPItem(localURL: $0) }.sorted(by: SFTPItem.directoriesFirst)
    }

    func navigateLocal(to item: SFTPItem) {
        if item.isDirectory {
            localPath = item.path
            selectedLocalItems = []
            loadLocalDirectory()
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        }
    }

    func navigateLocal(toPath path: String) {
        var isDirectory: ObjCBool = false
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        localPath = expanded
        selectedLocalItems = []
        loadLocalDirectory()
    }

    func navigateLocalUp() {
        localPath = (localPath as NSString).deletingLastPathComponent
        selectedLocalItems = []
        loadLocalDirectory()
    }

    // MARK: - Transfers

    func downloadSelected() {
        downloadToLocalFolder(selectedRemote)
    }

    func uploadSelected() {
        uploadToRemoteFolder(selectedLocal.map { URL(fileURLWithPath: $0.path) })
    }

    /// Downloads rows of the remote panel into the folder the local panel shows. Refused
    /// (false) unless every one of them is shown right now.
    @discardableResult
    func downloadToLocalFolder(_ items: [SFTPItem]) -> Bool {
        guard remotePanelShows(items) else { return false }
        download(items, into: URL(fileURLWithPath: localPath))
        return true
    }

    /// Uploads into the directory the remote panel shows. Refused (false) while its rows are
    /// not that directory's: the files would land somewhere the user is not looking at.
    @discardableResult
    func uploadToRemoteFolder(_ urls: [URL]) -> Bool {
        guard remoteListingIsCurrent, !urls.isEmpty else { return false }
        upload(urls, into: remotePath)
        return true
    }

    /// What a drag of this row out of the remote panel carries (see `remoteDragPayloads`).
    func remoteDragPayload(for item: SFTPItem) -> String {
        if let payload = remoteDragPayloads[item.id] { return payload }
        // Prefixed: a bare UUID is what a dragged terminal tab carries.
        let payload = Self.remoteDragPrefix + UUID().uuidString
        remoteDragPayloads[item.id] = payload
        remoteDragRows[payload] = item.id
        return payload
    }

    static let remoteDragPrefix = "termi-remote-row:"

    /// A drop on the local panel: downloads the rows these payloads stand for. Text this page
    /// did not hand out — a row of another window, anything another app dragged — is no row.
    @discardableResult
    func downloadDragged(_ payloads: [String]) -> Bool {
        let rows = Set(payloads.compactMap { remoteDragRows[$0] })
        return downloadToLocalFolder(visibleRemoteItems.filter { rows.contains($0.id) })
    }

    /// Download remote items (files or folders) into a local directory.
    func download(_ items: [SFTPItem], into directory: URL) {
        guard let session = requireSession() else { return }
        // Two of the items can be one name in this folder ("Makefile" / "makefile", an accent
        // encoded two ways). Each is a transfer of its own, and the later one would move the
        // earlier one's file to the Trash and take its place, or two folders would be merged.
        // The later one is refused here, by its name; `twins` has the file system's word on
        // it for the names this rule does not see.
        let caseSensitive = SFTPSession.volumeIsCaseSensitive(at: directory)
        var names = Set<String>()
        let twins = SFTPLocalTwins()
        for item in items where item.isNameRepresentable {
            guard names.insert(SFTPSession.localNameKey(item.name, caseSensitive: caseSensitive)).inserted else {
                var refused = TransferItem(name: item.name, direction: .download, totalBytes: 0)
                refused.state = .failed(SFTPServiceError.sameNameHere(item.name).localizedDescription)
                refused.finishedAt = Date()
                transfers.append(refused)
                continue
            }
            var transfer = TransferItem(name: item.name, direction: .download, totalBytes: item.isDirectory ? 0 : item.size)
            transfer.destination = (directory.path as NSString).abbreviatingWithTildeInPath
            let id = transfer.id
            transfers.append(transfer)
            let reporter = ProgressThrottle { [weak self] bytes in
                Task { @MainActor in self?.updateTransfer(id, bytes: bytes) }
            }
            transferTasks[id] = Task { [weak self] in
                do {
                    try await self?.acquireTransferSlot(for: id)
                    defer { self?.activeTransferCount -= 1 }
                    if item.isDirectory {
                        let total = try await session.totalSize(of: item)
                        await MainActor.run { self?.setTotal(id, total) }
                    }
                    let result = try await session.download(item, into: directory, twins: twins) {
                        reporter.report($0)
                    }
                    self?.finishTransfer(id, state: .completed, skipped: result.skipped, bytes: result.bytes)
                    self?.loadLocalDirectory()
                } catch is CancellationError {
                    self?.finishTransfer(id, state: .cancelled)
                } catch {
                    self?.finishTransfer(id, state: Task.isCancelled ? .cancelled : .failed(error.localizedDescription))
                }
            }
        }
    }

    /// Upload local files or folders into a remote directory.
    func upload(_ urls: [URL], into remoteDirectory: String) {
        guard let session = requireSession() else { return }
        // One upload: what is answered for "the other files of this upload" holds for all of
        // these, folders included — not for a later upload.
        let batch = UUID()
        let offersApplyToAll = urls.count > 1
            || urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        for url in urls {
            do {
                _ = try SFTPSession.uploadName(of: url)
            } catch {
                // Refused here, before its size is taken: for a volume that reads the whole disk.
                var refused = TransferItem(name: url.path, direction: .upload, totalBytes: 0)
                refused.state = .failed(error.localizedDescription)
                refused.finishedAt = Date()
                transfers.append(refused)
                continue
            }
            var transfer = TransferItem(name: url.lastPathComponent, direction: .upload,
                                        totalBytes: SFTPSession.localSize(of: url))
            transfer.destination = remoteDirectory
            let id = transfer.id
            transfers.append(transfer)
            transferBatches[id] = batch
            unfinishedInBatch[batch, default: 0] += 1
            let reporter = ProgressThrottle { [weak self] bytes in
                Task { @MainActor in self?.updateTransfer(id, bytes: bytes) }
            }
            transferTasks[id] = Task { [weak self] in
                do {
                    try await self?.acquireTransferSlot(for: id)
                    defer { self?.activeTransferCount -= 1 }
                    let result = try await session.upload(url, into: remoteDirectory, resolveConflict: { [weak self] question in
                        guard let self else { throw CancellationError() }
                        return try await self.requestUploadDecision(question, transferID: id, batchID: batch,
                                                                    offersApplyToAll: offersApplyToAll)
                    }, resolveUnsafeReplace: { [weak self] path, reason in
                        guard let self else { throw CancellationError() }
                        return try await self.requestInPlaceDecision(path: path, reason: reason, transferID: id,
                                                                     batchID: batch, offersApplyToAll: offersApplyToAll)
                    }) { reporter.report($0) }
                    self?.finishTransfer(id, state: .completed, skipped: result.skipped, kept: result.kept,
                                         bytes: result.bytes)
                    if let self, SFTPPathKey(self.remotePath) == SFTPPathKey(remoteDirectory) {
                        await self.loadRemoteDirectory()
                    }
                } catch is CancellationError {
                    self?.finishTransfer(id, state: .cancelled)
                } catch {
                    self?.finishTransfer(id, state: Task.isCancelled ? .cancelled : .failed(error.localizedDescription))
                }
            }
        }
    }

    func cancelTransfer(_ id: UUID) {
        transferTasks[id]?.cancel()
        if let conflict = uploadConflict, conflict.transferID == id {
            resolveUploadConflict(conflict.id, decision: .cancel)
        }
    }

    /// A file of the same name is on the server: replace it, skip it or cancel the upload. The
    /// answer is this file's — unless the user chose to do the same for the other files of
    /// this upload (`rememberedUploadDecisions`).
    private func requestUploadDecision(_ question: SFTPUploadQuestion, transferID: UUID, batchID: UUID,
                                       offersApplyToAll: Bool) async throws -> SFTPUploadDecision {
        try await ask(SFTPUploadConflict(id: UUID(), transferID: transferID, path: question.path,
                                         kind: .nameTaken(existing: question.existing, local: question.local),
                                         batchID: batchID, offersApplyToAll: offersApplyToAll)) { [weak self] in
            self?.rememberedUploadDecisions[batchID]
        }
    }

    /// The file cannot be replaced atomically: overwrite it in place? (True to go on.)
    private func requestInPlaceDecision(path: String, reason: SFTPClient.AtomicBlockReason, transferID: UUID,
                                        batchID: UUID, offersApplyToAll: Bool) async throws -> Bool {
        let decision = try await ask(SFTPUploadConflict(id: UUID(), transferID: transferID, path: path,
                                                        kind: .unsafeReplace(reason), batchID: batchID,
                                                        offersApplyToAll: offersApplyToAll)) { [weak self] in
            self?.rememberedInPlaceDecisions[batchID]
        }
        return decision == .replace
    }

    /// At most one question is shown. Other uploads remain cancellable while waiting their
    /// turn. An answer given for the whole upload is looked up before and after the wait: one
    /// given meanwhile, to another file of the same upload, holds for this one too.
    private func ask(_ question: SFTPUploadConflict,
                     remembered: @escaping () -> SFTPUploadDecision?) async throws -> SFTPUploadDecision {
        if let answer = remembered() { return answer }
        setAwaitingDecision(question.transferID, true)
        defer { setAwaitingDecision(question.transferID, false) }
        while uploadConflict != nil { try await Task.sleep(nanoseconds: 100_000_000) }
        try Task.checkCancellation()
        if let answer = remembered() { return answer }
        let id = question.id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                conflictContinuation = continuation
                uploadConflict = question
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveUploadConflict(id, decision: .cancel) }
        }
    }

    private func setAwaitingDecision(_ transferID: UUID, _ awaiting: Bool) {
        guard let index = transfers.firstIndex(where: { $0.id == transferID }) else { return }
        transfers[index].awaitingDecision = awaiting
    }

    /// `applyToAll`: the same answer for the other files of this upload (Replace or Skip, or
    /// overwriting in place; never Cancel, which ends the upload anyway).
    func resolveUploadConflict(_ id: UUID, decision: SFTPUploadDecision, applyToAll: Bool = false) {
        guard let question = uploadConflict, question.id == id else { return }
        if applyToAll, decision != .cancel, let batch = question.batchID {
            switch question.kind {
            case .nameTaken: rememberedUploadDecisions[batch] = decision
            case .unsafeReplace: rememberedInPlaceDecisions[batch] = decision
            }
        }
        let continuation = conflictContinuation
        conflictContinuation = nil
        uploadConflict = nil
        continuation?.resume(returning: decision)
    }

    /// Waits until fewer than `maxConcurrentTransfers` are running. Throws when the transfer is
    /// cancelled while it waits.
    private func acquireTransferSlot(for id: UUID) async throws {
        while activeTransferCount >= Self.maxConcurrentTransfers {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        activeTransferCount += 1
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].startedAt = Date()
        }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running }
    }

    private func setTotal(_ id: UUID, _ total: Int64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].totalBytes = total
    }

    private func updateTransfer(_ id: UUID, bytes: Int64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].state == .running else { return }
        transfers[index].transferredBytes = bytes
    }

    /// `bytes` is what a completed transfer says it transferred. Progress reports are thinned
    /// out and arrive later than this call, so the last of them cannot be waited for.
    private func finishTransfer(_ id: UUID, state: TransferItem.State, skipped: SFTPSkippedItems = SFTPSkippedItems(),
                                kept: SFTPSkippedItems = SFTPSkippedItems(), bytes: Int64? = nil) {
        transferTasks[id] = nil
        if let batch = transferBatches.removeValue(forKey: id) {
            let left = (unfinishedInBatch[batch] ?? 1) - 1
            if left > 0 {
                unfinishedInBatch[batch] = left
            } else {
                unfinishedInBatch[batch] = nil
                rememberedUploadDecisions[batch] = nil
                rememberedInPlaceDecisions[batch] = nil
            }
        }
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = state
        transfers[index].finishedAt = Date()
        transfers[index].skipped = skipped
        transfers[index].kept = kept
        transfers[index].awaitingDecision = false
        if let bytes { transfers[index].transferredBytes = bytes }
        // The total counted what was then left out or kept: the bytes shown stay those transferred.
        if state == .completed, transfers[index].totalBytes > 0, skipped.count == 0, kept.count == 0 {
            transfers[index].transferredBytes = transfers[index].totalBytes
        }
        let transfer = transfers[index]
        // Nothing sent because every file was kept: nothing was uploaded to tell about.
        let sentNothing = kept.count > 0 && transfer.transferredBytes == 0
        if state == .completed, !sentNothing, Date().timeIntervalSince(transfer.startedAt) > 3 {
            NotificationService.shared.sendTransferComplete(
                fileName: transfer.name,
                direction: transfer.direction == .upload ? String(localized: "Uploaded") : String(localized: "Downloaded"))
        }
    }

    // MARK: - Remote file operations

    // The panel's commands start here. Each is refused while the rows are not those of the
    // directory in the path bar (`remoteListingIsCurrent`), or for an item that is not shown.

    func beginNewFolder() {
        guard remoteListingIsCurrent else { return }
        newFolderName = ""
        newFolderParent = remotePath
        showingNewFolder = true
    }

    func beginRename(_ item: SFTPItem) {
        guard remotePanelShows([item]) else { return }
        renameTarget = item
        renameValue = item.name
        showingRename = true
    }

    /// "Permissions…". The server changes the permissions of what a link points to, never of
    /// the link itself, so for a link the value offered is the target's — the link's own
    /// (777) applied unchanged would open the target to everyone. A target that cannot be
    /// read (a dangling link, no access) has no permissions to offer or to change.
    func beginPermissions(_ item: SFTPItem) async {
        guard remotePanelShows([item]), let session = requireSession() else { return }
        var mode = item.mode
        if item.isSymlink {
            do {
                mode = try await session.targetPermissions(of: item.path)
            } catch {
                remoteActionError = String(localized: "The permissions of “\(item.name)” cannot be changed: it is a link, and what it points to cannot be read (\(error.localizedDescription)).")
                return
            }
            // The panel may have gone elsewhere while the server was asked.
            guard remotePanelShows([item]) else { return }
        }
        chmodTarget = item
        chmodValue = mode.map { SFTPItem.octalString(ofMode: $0) } ?? "644"
        showingChmod = true
    }

    func beginDelete(_ items: [SFTPItem]) {
        guard remotePanelShows(items) else { return }
        deleteTargets = items
        showingDeleteConfirm = true
    }

    /// What the delete confirmation asks: it names what goes — the item, or how many and the
    /// first of them.
    static func deleteConfirmation(for items: [SFTPItem]) -> String {
        if items.count == 1, let item = items.first {
            return item.isDirectory && !item.isSymlink
                ? String(localized: "Delete the folder “\(item.name)” and everything in it on the server? This cannot be undone.")
                : String(localized: "Delete “\(item.name)” on the server? This cannot be undone.")
        }
        let shown = items.prefix(deleteConfirmationNames)
        var names = shown.map { "“\($0.name)”" }.joined(separator: ", ")
        if items.count > shown.count { names += "…" }
        return String(localized: "Delete \(items.count) items on the server (\(names))? Folders are deleted with their contents. This cannot be undone.")
    }

    private static let deleteConfirmationNames = 3

    func createRemoteFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = requireSession(), !name.isEmpty else { return }
        // One folder in this directory: "a/b" or ".." would address another place.
        guard SFTPClient.isValidEntryName(name) else {
            remoteActionError = String(localized: "A name cannot contain “/” or be “.” or “..”.")
            return
        }
        let path = SFTPClient.join(newFolderParent ?? remotePath, name)
        do {
            try await session.makeDirectory(path)
            newFolderName = ""
            await loadRemoteDirectory()
        } catch {
            remoteActionError = error.localizedDescription
        }
    }

    func deleteRemoteItems(_ items: [SFTPItem]) async {
        guard let session = requireSession() else { return }
        var failure: String?
        for item in items where item.isNameRepresentable {
            do {
                try await session.delete(item.path)
                // The file a copy was being edited for is gone: a later save must not bring it
                // back under the old name. What the copy holds that the server never received
                // goes to the Trash, as whenever an edit ends.
                stopEditing(editItems.filter { SFTPPathKey.remainder(of: $0.remotePath, below: item.path) != nil }
                    .map(\.id))
            } catch {
                failure = "\(item.name): \(error.localizedDescription)"
            }
        }
        await loadRemoteDirectory()
        if let failure { remoteActionError = failure }
    }

    func renameRemoteItem() async {
        guard let session = requireSession(), let item = renameTarget, item.isNameRepresentable else { return }
        let newName = renameValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bytewise: changing only how an accent is encoded is a rename to the server.
        guard !newName.isEmpty, SFTPPathKey(newName) != SFTPPathKey(item.name) else { return }
        guard SFTPClient.isValidEntryName(newName) else {
            remoteActionError = String(localized: "A name cannot contain “/” or be “.” or “..”.")
            return
        }
        do {
            let newPath = SFTPClient.join(SFTPClient.parent(of: item.path), newName)
            try await session.rename(item.path, to: newPath)
            // Files being edited move along: saved to the old path, they would re-create the
            // old name next to the renamed file.
            for index in editItems.indices {
                if let moved = RemoteEditItem.rebased(editItems[index].remotePath, from: item.path, to: newPath) {
                    editItems[index].remotePath = moved
                }
            }
            await loadRemoteDirectory()
        } catch {
            remoteActionError = error.localizedDescription
        }
    }

    func chmodRemoteItem() async {
        guard let session = requireSession(), let item = chmodTarget, item.isNameRepresentable else { return }
        do {
            try await session.setPermissions(item.path, octal: chmodValue)
            await loadRemoteDirectory()
        } catch {
            remoteActionError = error.localizedDescription
        }
    }

    func copyRemotePath(_ item: SFTPItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }

    // MARK: - Local file operations

    func deleteLocalItems(_ items: [SFTPItem]) {
        for item in items {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
        }
        loadLocalDirectory()
    }

    func revealLocal(_ item: SFTPItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    // MARK: - Remote editing

    /// Download a remote file to a private temp folder, open it in the default app and upload it
    /// back whenever it is saved.
    func edit(_ item: SFTPItem) async {
        guard !item.isDirectory, item.isNameRepresentable, let session = requireSession() else { return }
        // A link to a file is edited as the file it points to: the saves replace that file and
        // the link stays a link (replacing the link itself is refused, and would turn it into a
        // copy). Resolved once, now: if the link is pointed elsewhere later, the saves still go
        // to the file that was opened.
        var source = item
        var editPath = item.path
        if item.isSymlink {
            do {
                let target = try await session.resolve(item.path)
                guard !(try await session.attributes(of: target)).isKnownNonRegular else {
                    throw SFTPClient.Failure.unsafeUploadTarget(target)
                }
                editPath = target
                source.path = target
                source.isSymlink = false
            } catch {
                remoteActionError = String(localized: "“\(item.name)” is a link, and the file it points to cannot be read, so it cannot be edited (\(error.localizedDescription)).")
                return
            }
        }
        if let existing = currentEdit(ofRemotePath: editPath) {
            openForEditing(existing.localURL)
            return
        }
        let folder = editFolder
            .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let localURL = try await session.download(source, into: folder) { _ in }.url
            let modified = Self.modificationDate(of: localURL)
            var editItem = RemoteEditItem(remotePath: editPath, localURL: localURL, folder: folder,
                                          lastUploadedModification: modified,
                                          status: item.isSymlink
                                            ? String(localized: "Editing — saves go to \(editPath)")
                                            : String(localized: "Editing — changes upload when you save"))
            if item.isSymlink { editItem.listedFolder = SFTPClient.parent(of: item.path) }
            // While the file was downloading, the page went to another host or lost its
            // session: registered now, the copy's saves would be uploaded to the same path on
            // whatever host the page is connected to next. Or the same file was opened twice.
            guard self.session === session, currentEdit(ofRemotePath: editPath) == nil else {
                discardLocalCopies(of: [editItem])
                if let existing = currentEdit(ofRemotePath: editPath) { openForEditing(existing.localURL) }
                return
            }
            editItems.append(editItem)
            editEndpoint = session.endpoint
            startWatching(editItem.id)
            openForEditing(localURL)
        } catch {
            // Nothing was downloaded into it; rmdir(2) only removes an empty folder.
            _ = rmdir(folder.path)
            remoteActionError = error.localizedDescription
        }
    }

    /// The edit of the file at exactly this remote path (compared by its bytes: a name that
    /// differs only in how an accent is encoded is another file).
    private func currentEdit(ofRemotePath path: String) -> RemoteEditItem? {
        editItems.first { SFTPPathKey($0.remotePath) == SFTPPathKey(path) }
    }

    /// Open the local copy of a remote file for editing. A file its default app would run
    /// instead (Terminal executes unix executables and scripts), or that no app claims, goes
    /// to the plain-text editor.
    func openForEditing(_ url: URL) {
        if let editorForTests {
            editorForTests(url)
            return
        }
        let workspace = NSWorkspace.shared
        if !Self.isRunnable(url), workspace.urlForApplication(toOpen: url) != nil, workspace.open(url) { return }
        let editor = workspace.urlForApplication(toOpen: UTType.plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        // No completion handler: it would be called on a background queue.
        workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration(),
                       completionHandler: nil)
    }

    /// Whether the file is an executable or a script by content type (an extensionless file
    /// with an execute bit counts as a unix executable). Terminal's own documents (.terminal
    /// settings, .term sessions) count too: they carry a command Terminal runs on opening them.
    nonisolated static func isRunnable(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return type.conforms(to: .executable) || type.conforms(to: .script)
            || type.identifier.hasPrefix("com.apple.terminal.")
    }

    func stopEditing(_ id: UUID) {
        stopEditing([id])
    }

    private func stopAllEditing() {
        stopEditing(editItems.map(\.id))
    }

    /// Ends the editing of these files and removes their local copies. A copy with changes the
    /// server has not received is the only place those changes exist: it is moved to the Trash
    /// instead (and stays where it is when even that fails), and the page says so.
    private func stopEditing(_ ids: [UUID]) {
        var ended: [RemoteEditItem] = []
        for id in ids {
            editWatchers[id]?.cancel()
            editWatchers[id] = nil
            // A question still open about this edit's save has nobody to answer it for.
            if let question = uploadConflict, question.transferID == id {
                resolveUploadConflict(question.id, decision: .cancel)
            }
            guard let index = editItems.firstIndex(where: { $0.id == id }) else { continue }
            ended.append(editItems.remove(at: index))
        }
        discardLocalCopies(of: ended)
        if editItems.isEmpty { editEndpoint = nil }
    }

    /// Removes what these edits left on this Mac. Only a copy the server has in full is
    /// deleted, and only that one file; everything else goes to the Trash.
    private func discardLocalCopies(of items: [RemoteEditItem]) {
        var trashed: [URL] = []
        var kept: [URL] = []
        for item in items {
            let modified = Self.modificationDate(of: item.localURL)
            if item.hasChangesNotOnServer(modified: modified) {
                do {
                    trashed.append(try moveToTrash(item.localURL))
                } catch {
                    kept.append(item.localURL)
                    logger.error("Could not move an edited file to the Trash: \(error.localizedDescription)")
                    continue
                }
            } else if modified != nil {
                // unlink(2) removes a file and never a folder, whatever the path turns out to be.
                _ = unlink(item.localURL.path)
            }
            guard let folder = item.folder else { continue }
            // What else is in the copy's folder was put there from its editor (saved under
            // another name, duplicated, the copy renamed): the server has none of it, so it
            // is not deleted.
            let leftovers = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for leftover in leftovers {
                do {
                    trashed.append(try moveToTrash(leftover))
                } catch {
                    kept.append(leftover)
                }
            }
            // Only an empty folder goes.
            _ = rmdir(folder.path)
        }
        if !trashed.isEmpty {
            let names = trashed.map(\.lastPathComponent).joined(separator: ", ")
            addNotice(String(localized: "Not uploaded to the server, moved to the Trash: \(names)"), files: trashed)
        }
        if !kept.isEmpty {
            let paths = kept.map(\.path).joined(separator: ", ")
            addNotice(String(localized: "Not uploaded to the server and could not be moved to the Trash, still at: \(paths)"),
                      files: kept)
        }
    }

    /// Adds a line to the page's notice (see `notice`); saying the same thing twice adds nothing.
    func addNotice(_ text: String, files: [URL] = []) {
        var lines = notice?.text.components(separatedBy: "\n") ?? []
        if !lines.contains(text) { lines.append(text) }
        notice = SFTPNotice(text: lines.joined(separator: "\n"), files: (notice?.files ?? []) + files)
    }

    /// "Reveal in Finder" of the notice: the Trash (or the folder the files are still in) opens
    /// with them selected. Finder does the looking, so nothing here has to read the Trash.
    func revealNoticeFiles() {
        guard let files = notice?.files, !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    private func startWatching(_ id: UUID) {
        editWatchers[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // The view model is gone: stop instead of polling forever.
                guard let self else { return }
                await self.uploadIfChanged(id)
            }
        }
    }

    /// Uploads the copy when it was saved since its last upload. (The watcher calls this every
    /// second; the tests call it directly.)
    func uploadIfChanged(_ id: UUID) async {
        guard let index = editItems.firstIndex(where: { $0.id == id }) else { return }
        let item = editItems[index]
        guard let modified = Self.modificationDate(of: item.localURL),
              modified != item.lastUploadedModification else { return }
        // No session either while a reconnect is under way or after it failed. A session to
        // another host is none for these files: the same path there is another file.
        guard let session, session.isOpen, editEndpoint == nil || session.endpoint == editEndpoint else {
            // Leave lastUploadedModification alone so the change uploads after a reconnect.
            let status = String(localized: "Connection closed — changes upload after you reconnect")
            if item.status != status { editItems[index].status = status }
            return
        }
        editItems[index].lastUploadedModification = modified
        editItems[index].status = String(localized: "Uploading…")
        // Until atomic replacement succeeds, this local copy holds the new changes.
        editItems[index].isUploading = true
        do {
            // To the path remembered for the file, not to one rebuilt from the copy's name: the
            // file system returns "é" decomposed, and that is another file on the server.
            try await session.upload(item.localURL, toPath: item.remotePath, resolveUnsafeReplace: { [weak self] path, reason in
                guard let self else { throw CancellationError() }
                return try await self.allowsInPlaceSave(of: id, path: path, reason: reason)
            }) { _ in }
            finishEditUpload(id, failed: false)
            setEditStatus(id, String(localized: "Saved to server at \(Date().formatted(date: .omitted, time: .standard))"))
            if SFTPPathKey(SFTPClient.parent(of: item.remotePath)) == SFTPPathKey(remotePath)
                || item.listedFolder.map({ SFTPPathKey($0) == SFTPPathKey(remotePath) }) == true {
                await loadRemoteDirectory()
            }
        } catch is CancellationError {
            // The file cannot be replaced safely and overwriting it in place was declined: the
            // copy keeps the change, the row says why and what else can be done.
            finishEditUpload(id, failed: true)
            let reason = editItems.first(where: { $0.id == id })?.blockedReason?.explanation ?? ""
            setEditStatus(id, String(localized: "Not saved to the server: “\(item.remoteName)” cannot be replaced safely (\(reason)). Save a copy to a folder you can write to."))
        } catch {
            finishEditUpload(id, failed: true)
            setEditStatus(id, String(localized: "Upload failed: \(error.localizedDescription)"))
            // The connection dropped mid-upload: forget the attempt so it is retried after a
            // reconnect. Other failures (e.g. permission denied) would only fail again.
            if !session.isOpen, let index = editItems.firstIndex(where: { $0.id == id }) {
                editItems[index].lastUploadedModification = item.lastUploadedModification
            }
        }
    }

    /// Whether this edit's saves may overwrite the file in place where it cannot be replaced
    /// atomically: asked once per edit, then remembered.
    private func allowsInPlaceSave(of id: UUID, path: String, reason: SFTPClient.AtomicBlockReason) async throws -> Bool {
        guard let index = editItems.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        editItems[index].blockedReason = reason
        if let allowed = editItems[index].allowsInPlaceReplace { return allowed }
        let decision = try await ask(SFTPUploadConflict(id: UUID(), transferID: id, path: path,
                                                        kind: .unsafeReplace(reason))) { nil }
        // "Don't Overwrite" (skip) is an answer and is remembered; a question closed because the
        // edit or the connection ended (cancel) is not.
        guard decision != .cancel else { return false }
        let allowed = decision == .replace
        if let index = editItems.firstIndex(where: { $0.id == id }) {
            editItems[index].allowsInPlaceReplace = allowed
        }
        return allowed
    }

    private func setEditStatus(_ id: UUID, _ status: String) {
        guard let index = editItems.firstIndex(where: { $0.id == id }) else { return }
        editItems[index].status = status
    }

    private func finishEditUpload(_ id: UUID, failed: Bool) {
        guard let index = editItems.firstIndex(where: { $0.id == id }) else { return }
        editItems[index].isUploading = false
        editItems[index].uploadFailed = failed
    }

    /// Read from the disk every time: whether a copy may be deleted must not rest on a value the
    /// URL still has cached from before the last save.
    private static func modificationDate(of url: URL) -> Date? {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

#if DEBUG
extension SFTPViewModel {
    /// Debug builds only — states that cannot be reached without the mouse, for screenshots:
    /// `-debugSFTPHost <label>` opens a saved host (and then a folder on each side), `-debugSFTPState connecting|failed` shows
    /// the connection card.
    func applyDebugLaunchArguments() async {
        let defaults = AppProfile.arguments
        let sample = hosts.first { $0.label == "test-a" } ?? hosts.first
        switch defaults.string(forKey: "debugSFTPState") {
        case "connecting":
            selectedHost = sample
            isConnecting = true
        case "failed":
            connectionError = "ssh: connect to host 127.0.0.1 port 2222: Connection refused"
            failedHost = sample
        default:
            break
        }
        if let label = defaults.string(forKey: "debugSFTPHost"), !isConnected,
           let host = hosts.first(where: { $0.label == label }) {
            await connect(to: host)
            // -debugSFTPPath <remote folder>, -debugSFTPLocalPath <folder on this Mac>
            if let path = defaults.string(forKey: "debugSFTPPath") { await navigateRemote(to: path) }
            if let path = defaults.string(forKey: "debugSFTPLocalPath") { navigateLocal(toPath: path) }
            applyDebugSamples()
        }
    }

    /// `-debugSFTPSelect <name>` selects a remote row, `-debugSFTPTransfers YES` fills the
    /// transfer bar with one running and one finished transfer (nothing is transferred).
    func applyDebugSamples() {
        let defaults = AppProfile.arguments
        if let name = defaults.string(forKey: "debugSFTPSelect"),
           let item = visibleRemoteItems.first(where: { $0.name == name }) {
            selectedRemoteItems = [item.id]
        }
        if defaults.bool(forKey: "debugSFTPTransfers"), transfers.isEmpty {
            var running = TransferItem(name: "big.bin", direction: .download, totalBytes: 209_700_000)
            running.transferredBytes = 130_200_000
            running.startedAt = Date().addingTimeInterval(-10.5)
            running.destination = (localPath as NSString).abbreviatingWithTildeInPath
            var finished = TransferItem(name: "notes.txt", direction: .upload, totalBytes: 3_400)
            finished.transferredBytes = 3_400
            finished.state = .completed
            finished.finishedAt = Date()
            finished.destination = remotePath
            transfers = [finished, running]
        }
    }
}
#endif

/// Limits progress callbacks (one per 32 KB chunk) to ~10 UI updates per second.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport = Date.distantPast
    private let deliver: @Sendable (Int64) -> Void

    init(_ deliver: @escaping @Sendable (Int64) -> Void) {
        self.deliver = deliver
    }

    func report(_ bytes: Int64) {
        let shouldDeliver: Bool = lock.withLock {
            guard Date().timeIntervalSince(lastReport) >= 0.1 else { return false }
            lastReport = Date()
            return true
        }
        if shouldDeliver { deliver(bytes) }
    }
}
