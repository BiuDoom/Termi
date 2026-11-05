import GRDB
import Foundation
import os.log
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

actor DatabaseManager {
    static let shared = DatabaseManager()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "Database")
    private var dbPool: DatabasePool?

    private var databasePath: String {
        get throws {
            let profile = AppProfile.current
            try FileManager.default.createDirectory(at: profile.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // Attributes are ignored when the folder already exists. The standard profile used to
            // be created with the default mode (0755), which lets every account on this Mac list it.
            _ = chmod(profile.directory.path, 0o700)
            return profile.databaseURL.path
        }
    }

    /// Database file URL for backup/restore
    var databaseURL: URL {
        get throws {
            URL(fileURLWithPath: try databasePath)
        }
    }

    var reader: DatabaseReader {
        get throws {
            if dbPool == nil {
                try initialize()
            }
            guard let pool = dbPool else { throw DatabaseError.notInitialized }
            return pool
        }
    }

    var writer: DatabaseWriter {
        get throws {
            if dbPool == nil {
                try initialize()
            }
            guard let pool = dbPool else { throw DatabaseError.notInitialized }
            return pool
        }
    }

    func initialize() throws {
        guard dbPool == nil else { return }

        let path = try databasePath
        logger.info("Database path: \(path)")

        var config = Configuration()
        #if DEBUG
        let log = self.logger
        config.prepareDatabase { db in
            db.trace { log.debug("\($0.description)") }
        }
        #endif
        config.journalMode = .wal
        config.busyMode = .timeout(5)

        dbPool = try DatabasePool(path: path, configuration: config)

        guard let pool = dbPool else { return }
        try Migrations.run(pool)
        // SQLite creates the file (and the wal) with the process umask, usually 0644.
        Self.restrictDatabaseFiles(at: path)
        logger.info("Database migrations complete")
    }

    /// Close the database pool (for backup/restore operations)
    func close() {
        dbPool = nil
        logger.info("Database pool closed")
    }

    /// Re-initialize the database after close (e.g. after restoring a backup)
    func reinitialize() throws {
        close()
        try initialize()
        logger.info("Database re-initialized")
    }

    // MARK: - Backup / Restore

    /// Write a complete copy of the database to `url`.
    func backup(to url: URL) async throws {
        // Replacing the file the pool has open would send every later change to a deleted file.
        guard !Self.isSameFile(url.path, try databasePath) else { throw DatabaseError.fileIsLiveDatabase }
        try await Self.backup(try writer, to: url)
    }

    /// Copy the current database to a sibling of the live file, before something replaces all of
    /// its contents. Returns where the copy is.
    func backupBeside(tag: String) async throws -> URL {
        let url = URL(fileURLWithPath: Self.siblingPath(of: try databasePath, tag: tag))
        try await Self.backup(try writer, to: url)
        return url
    }

    /// The pool runs in WAL mode, so the main file alone misses every change that has not been
    /// checkpointed: VACUUM INTO writes one consistent file that includes them. The database is
    /// a parameter so that tests can pass a scratch one.
    static func backup(_ database: any DatabaseWriter, to url: URL) async throws {
        let fm = FileManager.default
        // VACUUM INTO creates its file with the process umask (usually 0644) before it returns.
        // That file, and the journal SQLite keeps beside it, are created inside a 0700 directory
        // and made 0600 before the directory is left. Publishing does not use `replaceItemAt`:
        // by default that call keeps the permissions of the file already at the destination, so
        // a world-readable backup stayed world-readable until a later `chmod`, and `chmod`
        // follows a symlink. `rename` puts this 0600 inode under the destination name and
        // replaces a symlink there instead of writing through it.
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)", isDirectory: true)
        let partial = staging.appendingPathComponent("backup.db")
        let partialName = partial.lastPathComponent
        var directory: OwnerOnlyDirectory?
        do {
            let created = try makeOwnerOnlyDirectory(at: staging)
            directory = created
            guard created.stillAtItsPath() else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            }
            try await database.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [partial.path])
            }
            guard created.stillAtItsPath() else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            }
            // Verification can create a wal beside the copy and can change nothing about the
            // inode except, on a fussy volume, the mode. Secure again afterwards. Both the
            // check and the publish then use the file in this directory, not a name that was
            // swapped for a symlink.
            _ = try secureRegularFile(named: partialName, in: created, mode: 0o600)
            do {
                try checkDatabaseFile(at: partial)
            } catch {
                throw DatabaseError.backupNotVerified(underlying: error)
            }
            let secured = try secureRegularFile(named: partialName, in: created, mode: 0o600)
            try publishOwnerOnlyFile(named: partialName, from: created, inode: secured, to: url)
        } catch {
            // Only the directory this call created. A name that was already there (mkdir failed)
            // is left alone: `removeItem` on a symlink would still remove the link.
            if directory != nil {
                try? fm.removeItem(at: staging)
            }
            throw error
        }
        try? fm.removeItem(at: staging)
    }

    /// A directory this process just created, held open so later checks and the publish see
    /// that directory and not a symlink swapped in at the same path.
    ///
    /// The caller keeps the object until the file written inside it has been renamed out.
    /// Releasing it closes the directory fd.
    final class OwnerOnlyDirectory: @unchecked Sendable {
        let url: URL
        fileprivate let fd: Int32

        fileprivate init(url: URL, fd: Int32) {
            self.url = url
            self.fd = fd
        }

        deinit {
            // Not `DatabaseManager.closeFileDescriptor`: a nested type's deinit is not
            // isolated to the actor, and the C close is the same call.
            #if canImport(Darwin)
            _ = Darwin.close(fd)
            #else
            _ = Glibc.close(fd)
            #endif
        }

        /// The path still names this directory, it is still owned by this user, and it is
        /// still mode 0700. A symlink put at the path does not count.
        func stillAtItsPath() -> Bool {
            var held = stat()
            guard fstat(fd, &held) == 0 else { return false }
            let mode = UInt32(held.st_mode) & 0o777
            guard held.st_mode & S_IFMT == S_IFDIR, held.st_uid == getuid(), mode == 0o700 else {
                return false
            }
            var linked = stat()
            guard lstat(url.path, &linked) == 0 else { return false }
            return linked.st_dev == held.st_dev && linked.st_ino == held.st_ino
        }
    }

    /// Create `url` as a directory only this user can list or add to.
    ///
    /// `FileManager.createDirectory` asks `mkdir` for 0777 and applies the requested mode
    /// afterwards, so the directory exists as 0755 (or 0777, when the umask is 0) before
    /// `chmod`, and that `chmod` follows a symlink. A backup folder other accounts can list
    /// is writable by them in that gap when the umask allows it, and a name planted there is
    /// where VACUUM INTO is about to write. `mkdir(0700)` is masked by umask and so is never
    /// wider than 0700. `fchmod` on the directory fd sets 0700 exactly. `O_NOFOLLOW` refuses
    /// a symlink. A name already inside the new directory is refused and the directory is removed.
    @discardableResult
    static func makeOwnerOnlyDirectory(at url: URL) throws -> OwnerOnlyDirectory {
        if mkdir(url.path, 0o700) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: url)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        do {
            try secureNewDirectory(fd, at: url)
        } catch {
            closeFileDescriptor(fd)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return OwnerOnlyDirectory(url: url, fd: fd)
    }

    /// `fd` is the directory `mkdir` just created. Set 0700 on that fd and refuse anything
    /// that is not an empty directory this user owns, still named by `url`.
    private static func secureNewDirectory(_ fd: Int32, at url: URL) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        guard fchmod(fd, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var secured = stat()
        guard fstat(fd, &secured) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let mode = UInt32(secured.st_mode) & 0o777
        guard secured.st_mode & S_IFMT == S_IFDIR, mode == 0o700 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        guard inodeAt(url, is: secured) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        guard names.isEmpty else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))
        }
        guard inodeAt(url, is: secured) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
    }

    /// `lstat` of `url` is the same inode as `inode`. A symlink is a different inode.
    private static func inodeAt(_ url: URL, is inode: stat) -> Bool {
        var linked = stat()
        guard lstat(url.path, &linked) == 0 else { return false }
        return linked.st_dev == inode.st_dev && linked.st_ino == inode.st_ino
    }

    /// `mode` on the regular file at `url`, from this fd, before the file is renamed anywhere
    /// other users can open. A symlink is refused rather than followed.
    private static func secureRegularFile(at url: URL, mode: mode_t) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { closeFileDescriptor(fd) }
        _ = try secureOpenRegularFile(fd, mode: mode)
    }

    /// `mode` on `name` inside `directory`, opened from the directory fd so a symlink swapped
    /// in at the directory path is not followed. Returns the secured inode.
    private static func secureRegularFile(named name: String, in directory: OwnerOnlyDirectory,
                                         mode: mode_t) throws -> stat {
        guard directory.stillAtItsPath() else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        let fd = name.withCString { openat(directory.fd, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { closeFileDescriptor(fd) }
        let secured = try secureOpenRegularFile(fd, mode: mode)
        guard directory.stillAtItsPath() else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        return secured
    }

    /// `fchmod` `fd` to `mode` and require that it is a regular file this user owns.
    private static func secureOpenRegularFile(_ fd: Int32, mode: mode_t) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        guard fchmod(fd, mode) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var secured = stat()
        guard fstat(fd, &secured) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let actual = UInt32(secured.st_mode) & 0o777
        let expected = UInt32(mode) & 0o777
        guard actual == expected else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        return secured
    }

    /// Put the file `name` in `directory` at `destination`.
    ///
    /// `renameat` keeps the inode, so the 0600 mode is the mode other accounts can see the
    /// moment the name exists. It replaces a symlink at `destination` rather than writing
    /// through it. `replaceItemAt` keeps the destination's old permissions unless asked not to.
    private static func publishOwnerOnlyFile(named name: String, from directory: OwnerOnlyDirectory,
                                             inode: stat, to destination: URL) throws {
        let leaf = destination.lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/") else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        guard directory.stillAtItsPath() else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        let parent = destination.deletingLastPathComponent()
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { closeFileDescriptor(parentFD) }
        let renamed = name.withCString { source in
            leaf.withCString { target in
                renameat(directory.fd, source, parentFD, target)
            }
        }
        guard renamed == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var published = stat()
        guard lstat(destination.path, &published) == 0,
              published.st_dev == inode.st_dev,
              published.st_ino == inode.st_ino,
              published.st_mode & S_IFMT == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        if UInt32(published.st_mode) & 0o777 != 0o600 {
            let fd = open(destination.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { closeFileDescriptor(fd) }
            _ = try secureOpenRegularFile(fd, mode: 0o600)
        }
    }

    /// Copy the regular file at `source` to a new file at `destination`.
    ///
    /// The new file is created `O_EXCL` and `O_NOFOLLOW`, and `fchmod` makes it 0600 before
    /// any byte is copied, so the process umask cannot widen it and a symlink at `destination`
    /// is left untouched. `copyItem` creates the destination with the umask and only then
    /// copies permissions. A symlink at `source` is read (the file the user chose); the
    /// destination is not.
    static func copyOwnerOnlyRegularFile(from source: URL, to destination: URL) throws {
        let inFD = open(source.path, O_RDONLY | O_CLOEXEC)
        guard inFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { closeFileDescriptor(inFD) }
        var info = stat()
        guard fstat(inFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }

        let outFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var removePartial = true
        defer {
            if removePartial { unlink(destination.path) }
            closeFileDescriptor(outFD)
        }
        guard fchmod(outFD, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let read = buffer.withUnsafeMutableBytes { raw -> (Int, Int32) in
                guard let base = raw.baseAddress else { return (0, 0) }
                let n = readBytes(inFD, base, raw.count)
                return (n, n < 0 ? errno : 0)
            }
            if read.0 == 0 { break }
            if read.0 < 0 {
                if read.1 == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(read.1))
            }
            var written = 0
            while written < read.0 {
                let wrote = buffer.withUnsafeBytes { raw -> (Int, Int32) in
                    guard let base = raw.baseAddress else { return (-1, EIO) }
                    let n = writeBytes(outFD, base.advanced(by: written), read.0 - written)
                    return (n, n < 0 ? errno : 0)
                }
                if wrote.0 < 0 {
                    if wrote.1 == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(wrote.1))
                }
                if wrote.0 == 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                written += wrote.0
            }
        }
        _ = try secureOpenRegularFile(outFD, mode: 0o600)
        removePartial = false
    }

    private static func readBytes(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, buffer, count)
        #else
        Glibc.read(fd, buffer, count)
        #endif
    }

    private static func writeBytes(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buffer, count)
        #else
        Glibc.write(fd, buffer, count)
        #endif
    }

    /// `DatabaseManager.close()` shuts the pool. An unqualified `close(fd)` is that method,
    /// with the descriptor read as the actor, so the C function is named explicitly.
    private static func closeFileDescriptor(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }

    /// Open the database file at `url` on its own and check that it is one of this app's and
    /// that SQLite can read all of it. A write-ahead log next to it is folded into the file, so
    /// that the file is complete by itself afterwards.
    static func checkDatabaseFile(at url: URL) throws {
        do {
            let queue = try DatabaseQueue(path: url.path)
            defer { try? queue.close() }
            try queue.writeWithoutTransaction { db in
                guard try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"],
                      try db.tableExists("grdb_migrations"),
                      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations").contains("v1_core"),
                      try db.tableExists("hosts"),
                      try db.tableExists("vault"),
                      try db.tableExists("crypto_config") else {
                    throw DatabaseError.notABackup(underlying: nil)
                }
                try db.checkpoint(.truncate)
            }
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError.notABackup(underlying: error)
        }
    }

    /// Bring the backup at `source` in as a file next to the database at `path` and check it
    /// there, before the live database is touched. Returns the staged file; throws — leaving
    /// nothing behind — when `source` is not a usable backup.
    static func stageBackup(from source: URL, forDatabaseAt path: String) throws -> URL {
        guard !isSameFile(source.path, path) else { throw DatabaseError.fileIsLiveDatabase }

        let staged = URL(fileURLWithPath: path + ".restore-\(UUID().uuidString)")
        let logSuffixes = ["-wal", "-shm"]
        var createdMain = false
        do {
            // `copyItem` creates the destination with the process umask and copies every page
            // before it copies the mode. The profile folder used to be 0755, so that window
            // was the whole database. A symlink already at the staged name is left untouched.
            try copyOwnerOnlyRegularFile(from: source, to: staged)
            createdMain = true
            // A backup made by copying the app's folder has its latest changes in the -wal file.
            // A symlink at that name is not a log SQLite wrote; following it would copy whatever
            // it points at into the profile.
            let walSource = URL(fileURLWithPath: source.path + "-wal")
            var walInfo = stat()
            if lstat(walSource.path, &walInfo) == 0 {
                guard walInfo.st_mode & S_IFMT == S_IFREG else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
                }
                try copyOwnerOnlyRegularFile(from: walSource, to: URL(fileURLWithPath: staged.path + "-wal"))
            } else {
                let error = errno
                guard error == ENOENT else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
                }
            }
            try checkDatabaseFile(at: staged)
            // The check folds the wal in and may leave a new log beside the copy, created with
            // the umask. Tighten those before this returns; they are removed just below.
            for suffix in logSuffixes {
                let side = URL(fileURLWithPath: staged.path + suffix)
                var info = stat()
                if lstat(side.path, &info) == 0 {
                    guard info.st_mode & S_IFMT == S_IFREG else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
                    }
                    try secureRegularFile(at: side, mode: 0o600)
                }
            }
        } catch {
            // Only the copy made above; the chosen file is not touched. A staged name this call
            // did not create (the copy refused a symlink) is not removed.
            if createdMain {
                for suffix in [""] + logSuffixes {
                    try? FileManager.default.removeItem(atPath: staged.path + suffix)
                }
            }
            throw error
        }
        // Empty after the checkpoint in checkDatabaseFile, if SQLite left them at all.
        for suffix in logSuffixes {
            try? FileManager.default.removeItem(atPath: staged.path + suffix)
        }
        return staged
    }

    /// Replace the database with `staged` (see `stageBackup`) and reopen it. Nothing else can
    /// open the database in between: this method does not suspend. Returns where the previous
    /// database was kept.
    func replaceDatabase(with staged: URL) throws -> URL {
        let path = try databasePath
        if let pool = dbPool {
            // Fold the write-ahead log into the main file, then really close: dropping the
            // reference alone keeps the files open for as long as anything else holds the pool.
            _ = try? pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
            try pool.close()
            dbPool = nil
        }

        let kept = Self.siblingPath(of: path, tag: "before-restore")
        do {
            try Self.swapDatabaseFile(at: path, with: staged, keptAs: kept) {
                do {
                    try initialize()
                } catch {
                    // initialize() keeps a pool whose migration failed: close it before its
                    // files are taken away again.
                    try? dbPool?.close()
                    dbPool = nil
                    throw error
                }
            }
        } catch {
            logger.error("Restore failed: \(error). The previous database is at \(path) or \(kept)")
            // The previous database is back in place: reopen it.
            try? initialize()
            throw error
        }
        logger.info("Database replaced; the previous one is kept at \(kept)")
        return URL(fileURLWithPath: kept)
    }

    /// Put `staged` in place of the database file at `path`, then call `reopen`.
    ///
    /// The previous database is never deleted: it is kept as `kept` (with its -wal / -shm, so
    /// that it stays complete and the new file is never read together with an old log), and it
    /// takes its place back when `reopen` throws. There is a database at `path` at every moment.
    static func swapDatabaseFile(at path: String, with staged: URL, keptAs kept: String,
                                 reopen: () throws -> Void) throws {
        let fm = FileManager.default
        let logSuffixes = ["-wal", "-shm"]
        let hadDatabase = fm.fileExists(atPath: path)
        var movedLogs: [String] = []
        var installed = false
        do {
            for suffix in logSuffixes where fm.fileExists(atPath: path + suffix) {
                try fm.moveItem(atPath: path + suffix, toPath: kept + suffix)
                movedLogs.append(suffix)
            }
            // A second name for the previous database, then one atomic rename that gives the
            // first name to the new one.
            if hadDatabase {
                try fm.linkItem(atPath: path, toPath: kept)
            }
            guard rename(staged.path, path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            installed = true
            try reopen()
        } catch {
            if installed {
                // What is at `path` now is the copy of the backup (and the log files opening it
                // created); the previous database is safe under its second name.
                for suffix in logSuffixes { try? fm.removeItem(atPath: path + suffix) }
                if hadDatabase {
                    // If even this fails, the previous database stays complete as `kept`: its
                    // log files must not be put next to the other file.
                    guard rename(kept, path) == 0 else { throw error }
                } else {
                    try? fm.removeItem(atPath: path)
                }
            } else if hadDatabase, fm.fileExists(atPath: path) {
                // Still only a second name for the file at `path`: drop the name, not the data.
                try? fm.removeItem(atPath: kept)
            }
            for suffix in movedLogs { try? fm.moveItem(atPath: kept + suffix, toPath: path + suffix) }
            throw error
        }
    }

    /// Owner-read/write on the database and its wal/shm. The profile folder is tightened to 0700
    /// where the path is chosen (`databasePath`); this covers the files SQLite itself creates.
    static func restrictDatabaseFiles(at path: String) {
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            _ = chmod(path + suffix, 0o600)
        }
    }

    /// "…/termi.db" → "…/termi.<tag>-<yyyyMMdd-HHmmss>.db": still a .db file, so that
    /// Restore from Backup can open it.
    static func siblingPath(of path: String, tag: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().path
        var candidate = "\(stem).\(tag)-\(formatter.string(from: Date())).\(url.pathExtension)"
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = "\(stem).\(tag)-\(formatter.string(from: Date()))-\(counter).\(url.pathExtension)"
            counter += 1
        }
        return candidate
    }

    private static func isSameFile(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: lhs).resolvingSymlinksInPath().standardizedFileURL
        let right = URL(fileURLWithPath: rhs).resolvingSymlinksInPath().standardizedFileURL
        if left.path == right.path { return true }
        // Another spelling (case, hard link) of the same file.
        guard let leftID = try? left.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let rightID = try? right.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return false
        }
        return leftID.isEqual(rightID)
    }

    enum DatabaseError: Error, LocalizedError {
        case notInitialized
        case pathUnavailable
        case notABackup(underlying: (any Error)?)
        case fileIsLiveDatabase
        case backupNotVerified(underlying: any Error)

        var errorDescription: String? {
            switch self {
            case .notInitialized: "Database not initialized"
            case .pathUnavailable: "Application Support directory unavailable"
            case .notABackup:
                String(localized: "The selected file is not a Termi database backup, or it is damaged.")
            case .fileIsLiveDatabase:
                String(localized: "The selected file is the database Termi is using right now. Choose another file.")
            case .backupNotVerified:
                String(localized: "The backup could not be read back after it was written, so it was not saved. Try again or choose another location.")
            }
        }
    }
}
