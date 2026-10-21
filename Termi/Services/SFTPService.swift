import Foundation
import os.log

/// An edit belongs to the resolved account and route, never a mutable database row id.
struct SFTPEndpoint: Sendable, Equatable {
    struct Hop: Sendable, Equatable {
        var hostname: String
        var port: Int
        var username: String
    }
    var hops: [Hop]

    init(spec: SSHConnectionSpec) {
        hops = spec.hops.map { Hop(hostname: $0.hostname, port: $0.port, username: $0.username) }
    }

    init(host: Host) {
        hops = [Hop(hostname: host.hostname, port: host.port, username: host.username)]
    }
}

enum SFTPUploadDecision: Sendable {
    case replace, skip, cancel
}

/// A file of the same name already on the server: what an upload asks about.
struct SFTPUploadQuestion: Sendable {
    /// Where on the server.
    var path: String
    /// What the server says about the file there.
    var existing: SFTPClient.Attributes
    /// The file on this Mac that would replace it.
    var local: URL
}

/// One SFTP session on a host, running over the host's shared SSH master connection —
/// opening SFTP next to a terminal tab needs no second login.
final class SFTPSession: @unchecked Sendable {
    let host: Host
    let homeDirectory: String
    let endpoint: SFTPEndpoint
    private let client: SFTPClient
    /// Nil only for a session the tests build on a client of their own.
    private let lease: SSHConnectionManager.Lease?
    /// Where a local file goes that a download replaces (the tests hand in a folder of theirs).
    private let trash: @Sendable (URL) throws -> URL
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "SFTP")

    /// Outside `open(host:)`, only the tests create a session: on a connected client, with no
    /// SSH connection behind it.
    init(host: Host, client: SFTPClient, lease: SSHConnectionManager.Lease? = nil, homeDirectory: String,
         endpoint: SFTPEndpoint? = nil,
         trash: @escaping @Sendable (URL) throws -> URL = SFTPClient.moveToTrash) {
        self.host = host
        self.client = client
        self.lease = lease
        self.trash = trash
        self.homeDirectory = homeDirectory
        self.endpoint = endpoint ?? lease.map { SFTPEndpoint(spec: $0.master.spec) } ?? SFTPEndpoint(host: host)
    }

    static func open(host: Host) async throws -> SFTPSession {
        let lease = try await SSHService.shared.connect(to: host)
        let client = SFTPClient(command: lease.master.sftpCommand())
        return try await open(host: host, client: client, lease: lease)
    }

    /// Establish a session on the supplied transport. Cancelling any part of startup (the
    /// version handshake or resolving the home directory) closes that transport immediately.
    static func open(host: Host, client: SFTPClient,
                     lease: SSHConnectionManager.Lease? = nil) async throws -> SFTPSession {
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await client.connect()
                try Task.checkCancellation()
                // realPath refuses an answer that is not an absolute path; the root is then
                // the one directory that certainly exists. Cancellation must not use it as
                // a fallback and return an already closed session.
                let home = (try? await client.realPath(".")) ?? "/"
                try Task.checkCancellation()
                return SFTPSession(host: host, client: client, lease: lease, homeDirectory: home)
            } onCancel: {
                client.close()
                lease?.release()
            }
        } catch {
            client.close()
            lease?.release()
            throw error
        }
    }

    var isOpen: Bool { client.isOpen && (lease?.master.isAlive ?? true) }

    func close() {
        client.close()
        lease?.release()
    }

    // MARK: - Browsing

    func list(_ path: String) async throws -> [SFTPItem] {
        var items: [SFTPItem] = []
        var listed = Set<SFTPItem.ID>()
        for entry in try await client.listDirectory(path) {
            // The client already drops names that are not file names; checked again where the
            // items are built, because local paths are composed from them.
            guard SFTPClient.isValidEntryName(entry.name) else { continue }
            var item = SFTPItem(entry: entry, parentPath: path)
            // A directory holds each name once. A server that lists one twice would give two
            // rows one identity, and whatever is done to one would be done twice.
            guard listed.insert(item.id).inserted else { continue }
            if entry.attributes.fileType == .symlink, item.isNameRepresentable,
               let target = try? await client.stat(item.path) {
                if target.fileType == .directory { item.isDirectory = true }
                // Opening the link opens what it leads to.
                item.linksToSpecialFile = SFTPItem.isSpecialFileMode(target.permissions)
            }
            items.append(item)
        }
        return items.sorted(by: SFTPItem.directoriesFirst)
    }

    func resolve(_ path: String) async throws -> String {
        try await client.realPath(path)
    }

    /// What the server says about `path` itself (a link is not followed).
    func attributes(of path: String) async throws -> SFTPClient.Attributes {
        try await client.lstat(path)
    }

    /// The children of a directory that is about to be walked as a whole (download, size).
    /// One name that is not valid UTF-8 stops the walk before anything in the directory is
    /// touched: its path cannot be sent, and leaving it out would report a partial copy as done.
    private func listForWalk(_ path: String) async throws -> [SFTPItem] {
        let children = try await list(path)
        guard children.allSatisfy(\.isNameRepresentable) else {
            throw SFTPClient.Failure.unrepresentableName(directory: path)
        }
        return children
    }

    // MARK: - Mutations

    func makeDirectory(_ path: String) async throws {
        try await client.makeDirectory(path)
    }

    func delete(_ path: String) async throws {
        try await client.removeRecursively(path)
    }

    /// Rename, never onto something else. The server has no Trash, and with posix-rename it
    /// replaces what is at the new path without a word — also an item the listing does not
    /// show (hidden, or created since it was read). So the new path is looked at first, and
    /// anything there refuses the rename, as Finder does.
    ///
    /// Except for a name that only changes case or how an accent is encoded: on a server whose
    /// file system ignores that, the "item there" is the file being renamed. Attributes cannot
    /// tell (SFTP reports no inode, and two files written in the same second with the same
    /// size answer alike), so the directory is asked: a server that tells the two names apart
    /// lists the new one when another file has it, and one that folds them lists only the old.
    func rename(_ path: String, to newPath: String) async throws {
        let existing: SFTPClient.Attributes?
        do {
            existing = try await client.lstat(newPath)
        } catch SFTPClient.Failure.status(let code, _) where code == SFTPClient.Failure.codeNoSuchFile {
            existing = nil
        }
        if let existing {
            let name = SFTPClient.name(of: path)
            let newName = SFTPClient.name(of: newPath)
            let directory = SFTPClient.parent(of: path)
            guard Self.isSameNameWhenFolded(name, newName),
                  SFTPPathKey(directory) == SFTPPathKey(SFTPClient.parent(of: newPath)),
                  Self.areOfOneFile(existing, try await client.lstat(path)),
                  try await lists(name, butNot: newName, in: directory) else {
                throw SFTPServiceError.nameTaken(newName)
            }
        }
        try await client.rename(path, to: newPath)
    }

    /// Whether two names are one name to a file system that ignores case and normalisation.
    static func isSameNameWhenFolded(_ a: String, _ b: String) -> Bool {
        localNameKey(a, caseSensitive: false) == localNameKey(b, caseSensitive: false)
    }

    /// Whether two LSTAT answers can be of one file. The access time is left out: it may move
    /// between the two requests.
    private static func areOfOneFile(_ a: SFTPClient.Attributes, _ b: SFTPClient.Attributes) -> Bool {
        var a = a, b = b
        a.accessTime = nil
        b.accessTime = nil
        return a == b
    }

    /// Whether `directory` lists `name` and nothing under exactly the bytes of `other`.
    private func lists(_ name: String, butNot other: String, in directory: String) async throws -> Bool {
        var found = false
        for entry in try await client.listDirectory(directory) {
            let bytes = entry.rawName ?? Data(entry.name.utf8)
            if bytes.elementsEqual(other.utf8) { return false }
            if bytes.elementsEqual(name.utf8) { found = true }
        }
        return found
    }

    func setPermissions(_ path: String, octal: String) async throws {
        guard octal.range(of: "^[0-7]{3,4}$", options: .regularExpression) != nil,
              let mode = UInt32(octal, radix: 8) else {
            throw SFTPServiceError.invalidPermissions(octal)
        }
        try await client.setPermissions(path, mode)
    }

    /// The permission bits of what `path` leads to, links followed — what `setPermissions`
    /// changes. Nil when the server does not report them.
    func targetPermissions(of path: String) async throws -> UInt32? {
        try await client.stat(path).permissions
    }

    func readFile(_ path: String, maxBytes: Int = 16 * 1024 * 1024) async throws -> Data {
        try await client.readFile(path, maxBytes: maxBytes)
    }

    // MARK: - Transfers

    /// Total bytes of a remote file or directory tree (for progress). Counts what `download`
    /// transfers: links to directories below the top level and special files are left out.
    func totalSize(of item: SFTPItem) async throws -> Int64 {
        try await totalSize(of: item, root: item.path, depth: 0)
    }

    private func totalSize(of item: SFTPItem, root: String, depth: Int) async throws -> Int64 {
        if item.isDirectory && item.isSymlink && depth > 0 { return 0 }
        if item.isSpecialFile { return 0 }
        guard item.isDirectory else { return item.size }
        guard depth < SFTPClient.maxTreeDepth else { throw SFTPClient.Failure.treeTooDeep(path: root) }
        var total: Int64 = 0
        for child in try await listForWalk(item.path) {
            try Task.checkCancellation()
            total = Self.saturatingSum(total, try await totalSize(of: child, root: root, depth: depth + 1))
        }
        return total
    }

    /// Adds two sizes the server reported. Each is at most Int64.max, two of them are more:
    /// the sum stops at the maximum instead of trapping.
    static func saturatingSum(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b < 0 ? .min : .max) : sum
    }

    /// Download a file or directory tree into `localDirectory`. Returns the local URL, what of
    /// the tree was left out (see `SFTPSkippedItems`) and the bytes written. `twins` is shared
    /// by the items of one selection downloaded into one folder (see `SFTPLocalTwins`).
    @discardableResult
    func download(_ item: SFTPItem, into localDirectory: URL, twins: SFTPLocalTwins = SFTPLocalTwins(),
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> (url: URL, skipped: SFTPSkippedItems, bytes: Int64) {
        // An item that did not come from a listing gets the same check before its name
        // becomes part of a local path.
        guard SFTPClient.isValidEntryName(item.name), item.isNameRepresentable else {
            throw SFTPClient.Failure.protocolViolation("suspect file name")
        }
        let destination = localDirectory.appendingPathComponent(item.name)
        let counter = TransferTally(progress)
        try await download(item, to: destination, counter: counter, twins: twins, root: item.path, depth: 0)
        return (destination, counter.skipped, counter.value)
    }

    private func download(_ item: SFTPItem, to destination: URL, counter: TransferTally, twins: SFTPLocalTwins,
                          root: String, depth: Int) async throws {
        try Task.checkCancellation()
        let isTopLevel = depth == 0
        // A link to a directory is followed only when it is the item being downloaded; inside
        // a tree it is skipped (it may form a cycle or point outside the tree).
        if item.isDirectory && item.isSymlink && !isTopLevel {
            counter.skip(item.path)
            return
        }
        // Never opened (see `SFTPItem.isSpecialFile`). Picked on its own that is an error;
        // inside a tree the rest is still downloaded.
        if item.isSpecialFile {
            guard !isTopLevel else { throw SFTPServiceError.notDownloadable(item.name) }
            counter.skip(item.path)
            return
        }
        if item.isDirectory {
            guard depth < SFTPClient.maxTreeDepth else { throw SFTPClient.Failure.treeTooDeep(path: root) }
            try Self.enterLocalFolder(destination, isTopLevel: isTopLevel)
            // Two selected folders that are one folder here would be merged into one.
            guard twins.claim(destination) else { throw SFTPServiceError.sameNameHere(item.name) }
            for child in try await listForWalk(item.path) {
                let childDestination = destination.appendingPathComponent(child.name)
                // Two remote names that are one name on this Mac ("Makefile" / "makefile",
                // "straße" / "STRASSE", an accent encoded two ways) would land on one file: the
                // second would move the first — just downloaded — to the Trash and take its
                // place. The first stays, later ones are left out.
                guard !twins.holds(childDestination) else {
                    counter.skip(child.path)
                    continue
                }
                do {
                    try await download(child, to: childDestination, counter: counter, twins: twins,
                                       root: root, depth: depth + 1)
                } catch SFTPClient.Failure.status(let code, _)
                            where child.isSymlink && code == SFTPClient.Failure.codeNoSuchFile {
                    // Dangling link: skip it instead of failing the whole folder.
                    counter.skip(child.path)
                }
            }
        } else {
            let base = counter.value
            let name = item.name
            let trash = self.trash
            try await client.download(item.path, to: destination, progress: { written in
                counter.set(base + Int64(written))
            }, trash: { existing in
                // Asked again when the file is about to be replaced: downloads of one selection
                // run side by side, and the twin may have been written since this one began.
                guard !twins.holds(existing) else { throw SFTPServiceError.sameNameHere(name) }
                return try trash(existing)
            })
            twins.claim(destination)
            // A link's own mode (0777 on Linux) says nothing about the file it points to.
            if let mode = item.mode, !item.isSymlink {
                try? FileManager.default.setAttributes([.posixPermissions: Int(mode & 0o777)],
                                                       ofItemAtPath: destination.path)
            }
        }
    }

    /// The local folder a remote folder's contents go into. The one the user's download makes
    /// or merges into may be reached through a link. Below it, the server chooses the names: a
    /// link standing where it lists a folder would lead the files (and the replacing of what
    /// has their names) out of the tree, so there only a real folder is entered. Judged with
    /// lstat(2), which does not follow links — creating a directory "succeeds" on one.
    static func enterLocalFolder(_ url: URL, isTopLevel: Bool) throws {
        guard !isTopLevel else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw SFTPServiceError.localItemInTheWay(url.path)
        }
    }

    /// Whether the volume `url` is on tells "a" from "A". Assumed not to (the default on a
    /// Mac) when it does not say.
    static func volumeIsCaseSensitive(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
    }

    /// What a file name is to a file system, for telling before anything is written whether
    /// two names are one name there. As a `String` it already compares by canonical
    /// equivalence, which is how APFS and HFS+ treat names on every volume; case is folded
    /// unless the volume keeps it. Folded the full way — "straße" and "STRASSE", "ſ" and "s"
    /// are one name to APFS, which lower-casing alone does not see — and rather too far than
    /// not far enough: the dotless "ı" counts as "i" here, which APFS keeps apart.
    static func localNameKey(_ name: String, caseSensitive: Bool) -> String {
        caseSensitive ? name : name.lowercased().uppercased().lowercased()
    }

    /// Asked when an existing file cannot be replaced atomically (why): true overwrites it in
    /// place, false cancels. Without it the upload fails with `atomicReplacementBlocked`.
    typealias UnsafeReplaceDecision = @Sendable (String, SFTPClient.AtomicBlockReason) async throws -> Bool

    /// Upload a local file or folder into `remoteDirectory`. Returns the remote path, what of a
    /// folder was left out (see `SFTPSkippedItems`), the files already on the server the user
    /// chose to keep, and the bytes sent.
    @discardableResult
    func upload(_ localURL: URL, into remoteDirectory: String,
                resolveConflict: @escaping @Sendable (SFTPUploadQuestion) async throws -> SFTPUploadDecision = {
                    throw SFTPServiceError.nameTaken(SFTPClient.name(of: $0.path))
                },
                resolveUnsafeReplace: UnsafeReplaceDecision? = nil,
                progress: @escaping @Sendable (Int64) -> Void) async throws
        -> (path: String, skipped: SFTPSkippedItems, kept: SFTPSkippedItems, bytes: Int64) {
        let destination = SFTPClient.join(remoteDirectory, try Self.uploadName(of: localURL))
        let counter = TransferTally(progress)
        try await upload(localURL, to: destination, counter: counter, root: nil, resolveConflict: resolveConflict,
                         resolveUnsafeReplace: resolveUnsafeReplace)
        return (destination, counter.skipped, counter.kept, counter.value)
    }

    /// Upload a local file to exactly this remote path with atomic replacement. For writing back
    /// a file that was read from there: the path is the one the server listed, byte for byte,
    /// and is not rebuilt from the local file's name — the file system hands non-ASCII names
    /// back decomposed, which on the server is the name of another file.
    func upload(_ localURL: URL, toPath remotePath: String,
                resolveUnsafeReplace: UnsafeReplaceDecision? = nil,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
        // Opening a file for remote editing explicitly opts into uploading its saves to this
        // exact path. Ordinary uploads always use the separate conflict decision above.
        try await upload(localURL, to: remotePath, counter: TransferTally(progress), root: nil,
                         resolveConflict: { _ in .replace }, resolveUnsafeReplace: resolveUnsafeReplace)
    }

    /// The name a local file or folder gets on the server: the last component of its URL, when
    /// that is the name of one directory entry. A volume ("/") or a URL ending in ".." or "."
    /// has none — joined to the remote directory it would be that directory itself or its
    /// parent, and the upload would merge into it.
    static func uploadName(of localURL: URL) throws -> String {
        let name = localURL.lastPathComponent
        guard SFTPClient.isValidEntryName(name) else {
            throw SFTPServiceError.notUploadable(localURL.path)
        }
        return name
    }

    /// `root` is nil for the item the user picked, and inside a folder the path components of
    /// that folder (the picked one, links resolved).
    private func upload(_ localURL: URL, to destination: String, counter: TransferTally,
                        root: [String]?,
                        resolveConflict: @escaping @Sendable (SFTPUploadQuestion) async throws -> SFTPUploadDecision,
                        resolveUnsafeReplace: UnsafeReplaceDecision?) async throws {
        try Task.checkCancellation()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        let values = try localURL.resourceValues(forKeys: keys)
        if let root {
            // Inside a folder, what is not a file or a folder of that folder is left out instead
            // of failing the whole upload: links to folders and dangling links (as downloads
            // do), links that lead out of the folder — the user picked the folder, not whatever
            // a link in it points at — and pipes, devices and sockets, which block when opened.
            let isUploadable = values.isSymbolicLink == true
                ? Self.linkLeadsToFile(localURL, inside: root)
                : values.isDirectory == true || values.isRegularFile == true
            guard isUploadable else {
                counter.skip(localURL.path)
                return
            }
        }
        if values.isDirectory == true && values.isSymbolicLink != true {
            do {
                try await client.makeDirectory(destination)
            } catch let failure as SFTPClient.Failure {
                // Merging into a folder that is already there is the one failure that is none.
                // Anything else (no permission, a file of that name) is the transfer's error,
                // not something for each file below to stumble over.
                guard case .status = failure else { throw failure }
                // The folder the user's upload makes or merges into may be reached through a
                // link. Below it only a real folder is entered (LSTAT does not follow links): a
                // link standing there would lead the files, and the replacing of what has their
                // names, to wherever it points.
                let existing: SFTPClient.Attributes?
                if root == nil {
                    existing = try? await client.stat(destination)
                } else {
                    existing = try? await client.lstat(destination)
                }
                guard let existing else { throw failure }
                if existing.fileType != .directory {
                    guard root != nil else { throw failure }
                    throw SFTPServiceError.remoteItemInTheWay(destination)
                }
            }
            let below = root ?? localURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let children = try FileManager.default.contentsOfDirectory(
                at: localURL, includingPropertiesForKeys: Array(keys))
            for child in children {
                try await upload(child, to: SFTPClient.join(destination, try Self.uploadName(of: child)),
                                 counter: counter, root: below, resolveConflict: resolveConflict,
                                 resolveUnsafeReplace: resolveUnsafeReplace)
            }
        } else {
            let existing = try await client.uploadAttributes(at: destination)
            if let existing {
                guard !existing.isKnownNonRegular else {
                    // Inside a folder, a link, folder or special file standing on the server where
                    // a file goes is left out — neither replaced nor followed — as local links
                    // are. The item the user picked (and an edit's save) still says why it failed.
                    guard root == nil else {
                        counter.skip(destination)
                        return
                    }
                    throw SFTPClient.Failure.unsafeUploadTarget(destination)
                }
                switch try await resolveConflict(SFTPUploadQuestion(path: destination, existing: existing, local: localURL)) {
                case .replace: break
                case .skip:
                    // The user's choice, not something left out: counted apart.
                    counter.keep(destination)
                    return
                case .cancel: throw CancellationError()
                }
            }
            let permissions = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.posixPermissions])
                .flatMap { ($0 as? NSNumber)?.uint32Value }
            let base = counter.value
            let expectation = existing.map(SFTPClient.UploadDestination.existing) ?? .absent
            do {
                try await client.upload(localURL, to: destination, permissions: permissions,
                                        expectation: expectation) { sent in
                    counter.set(base + Int64(sent))
                }
            } catch let failure as SFTPClient.Failure {
                // Nothing was changed yet. Where the atomic way is blocked the user may agree to
                // overwrite the file in place (an interrupted upload then cuts it short).
                guard case .atomicReplacementBlocked(_, let reason) = failure, existing != nil,
                      let resolveUnsafeReplace else { throw failure }
                guard try await resolveUnsafeReplace(destination, reason) else { throw CancellationError() }
                counter.set(base)
                try await client.upload(localURL, to: destination, permissions: permissions,
                                        expectation: expectation, strategy: .inPlace) { sent in
                    counter.set(base + Int64(sent))
                }
            }
        }
    }

    /// Whether a link inside a folder being uploaded leads to a regular file inside that folder
    /// (`root`: the folder's path components, links resolved). Compared component by component:
    /// "/a/bc" is not inside "/a/b".
    static func linkLeadsToFile(_ link: URL, inside root: [String]) -> Bool {
        let target = link.resolvingSymlinksInPath().standardizedFileURL
        let components = target.pathComponents
        guard components.count > root.count, components.starts(with: root) else { return false }
        return (try? target.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// Size of a local file or folder tree (for upload progress).
    static func localSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isDirectory == true && values.isSymbolicLink != true {
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
            var total: Int64 = 0
            while let child = enumerator?.nextObject() as? URL {
                if let childValues = try? child.resourceValues(forKeys: Set(keys)), childValues.isDirectory != true {
                    total += Int64(childValues.fileSize ?? 0)
                }
            }
            return total
        }
        return Int64(values.fileSize ?? 0)
    }
}

/// What a transfer that finished did not copy, on purpose: links it does not follow, pipes,
/// devices and sockets, and remote names that are one name on this Mac. Shown with the
/// transfer's result, so that "done" does not claim more than was done.
struct SFTPSkippedItems: Sendable, Equatable {
    private(set) var count = 0
    /// The paths of the first few, to name them.
    private(set) var examples: [String] = []
    static let maxExamples = 5

    mutating func add(_ path: String) {
        count += 1
        if examples.count < Self.maxExamples { examples.append(path) }
    }
}

/// What the downloads of one selection have put into local folders, told by what the file
/// system says each item is (volume and inode) rather than by its name: which names are one
/// name is for the volume to say — APFS folds "straße" and "STRASSE", "ς" and "σ" — and no
/// rule applied to the names is sure to say the same.
final class SFTPLocalTwins: @unchecked Sendable {
    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private let lock = NSLock()
    private var written = Set<Identity>()

    init() {}

    private static func identity(at url: URL) -> Identity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    /// Whether what is at `url` was put there by these downloads.
    func holds(_ url: URL) -> Bool {
        guard let identity = Self.identity(at: url) else { return false }
        return lock.withLock { written.contains(identity) }
    }

    /// Notes what is at `url` as put there by these downloads. False when it already was.
    @discardableResult
    func claim(_ url: URL) -> Bool {
        guard let identity = Self.identity(at: url) else { return true }
        return lock.withLock { written.insert(identity).inserted }
    }
}

/// Thread-safe running byte total, and what was left out, shared by the files of one transfer.
private final class TransferTally: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    private var skippedItems = SFTPSkippedItems()
    private let report: @Sendable (Int64) -> Void

    init(_ report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    var value: Int64 { lock.withLock { total } }

    func set(_ value: Int64) {
        lock.withLock { total = value }
        report(value)
    }

    var skipped: SFTPSkippedItems { lock.withLock { skippedItems } }

    func skip(_ path: String) {
        lock.withLock { skippedItems.add(path) }
    }

    /// Files already on the server the user chose to keep ("Skip" when asked about replacing).
    private var keptItems = SFTPSkippedItems()

    var kept: SFTPSkippedItems { lock.withLock { keptItems } }

    func keep(_ path: String) {
        lock.withLock { keptItems.add(path) }
    }
}

enum SFTPServiceError: Error, LocalizedError, Equatable {
    case invalidPermissions(String)
    /// A local path whose last component is not a file name (a volume, "..", ".").
    case notUploadable(String)
    /// A remote pipe, device or socket picked for download (its name).
    case notDownloadable(String)
    /// A rename to a name something else in the directory has.
    case nameTaken(String)
    /// A local link or file standing where a folder download needs a folder (its path).
    case localItemInTheWay(String)
    /// A remote link or file standing where a folder upload needs a folder (its path).
    case remoteItemInTheWay(String)
    /// A remote item whose name is, on this Mac, the name of another item of the same download.
    case sameNameHere(String)

    var errorDescription: String? {
        switch self {
        case .invalidPermissions(let value):
            String(localized: "Invalid permissions “\(value)” (expected octal such as 755)")
        case .notUploadable(let path):
            String(localized: "“\(path)” cannot be uploaded: it is a whole volume or not a file name. Open it and choose what is inside instead.")
        case .notDownloadable(let name):
            String(localized: "“\(name)” is a pipe, a device or a socket, not a file. It cannot be downloaded.")
        case .nameTaken(let name):
            String(localized: "The name “\(name)” is already taken. Choose a different name.")
        case .localItemInTheWay(let path):
            String(localized: "“\(path)” on this Mac is a link or a file, not a folder. The download stopped rather than write through it.")
        case .remoteItemInTheWay(let path):
            String(localized: "“\(path)” on the server is a link or a file, not a folder. The upload stopped rather than write through it.")
        case .sameNameHere(let name):
            String(localized: "“\(name)” was not downloaded: on this Mac its name is the name of another item of this download (they differ only in case or in how an accent is written). Download it into another folder.")
        }
    }
}

// MARK: - String Extension

extension String {
    /// Escape string for use in shell commands
    var shellEscaped: String {
        "'" + self.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
