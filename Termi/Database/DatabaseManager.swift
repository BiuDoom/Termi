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
        // VACUUM INTO only writes a new file, and it creates that file with the process umask
        // (usually 0644) before returning. chmod afterwards is already too late. The copy, and
        // the journal SQLite keeps beside it, are created inside a 0700 directory next to the
        // destination and the copy is made 0600 before that directory is left. A file already at
        // the destination (the save panel asked) is replaced only by a complete backup.
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)", isDirectory: true)
        let partial = staging.appendingPathComponent("backup.db")
        do {
            try makeOwnerOnlyDirectory(at: staging)
            try await database.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [partial.path])
            }
            try secureRegularFile(at: partial, mode: 0o600)
            // A backup that would not restore is reported now, not when it is needed.
            // Verification can create a wal or journal beside the copy; those stay in the
            // private directory and are removed with it.
            do {
                try checkDatabaseFile(at: partial)
            } catch {
                throw DatabaseError.backupNotVerified(underlying: error)
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: url)
            }
            // rename keeps the mode set above. Tighten again in case the replace copied.
            _ = chmod(url.path, 0o600)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        try? fm.removeItem(at: staging)
    }

    /// Create `url` as a directory only this user can list or add to.
    ///
    /// The mode passed to `mkdir` is masked by umask, so a directory asked for as 0700 is often
    /// created 0755. `fchmod` on the directory fd sets 0700 before anything is written into it.
    /// `O_NOFOLLOW` refuses a symlink; anything planted in the brief moment the directory was
    /// group-writable (umask 002) makes this throw instead of being used.
    static func makeOwnerOnlyDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { closeFileDescriptor(fd) }
        guard fchmod(fd, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let mode = UInt32(info.st_mode) & 0o777
        guard info.st_mode & S_IFMT == S_IFDIR, mode == 0o700 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        guard names.isEmpty else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))
        }
    }

    /// `mode` on the regular file at `url`, from this fd, before the file is renamed anywhere
    /// other users can open. A symlink is refused rather than followed.
    private static func secureRegularFile(at url: URL, mode: mode_t) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { closeFileDescriptor(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
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
        let fm = FileManager.default
        guard !isSameFile(source.path, path) else { throw DatabaseError.fileIsLiveDatabase }

        let staged = URL(fileURLWithPath: path + ".restore-\(UUID().uuidString)")
        let logSuffixes = ["-wal", "-shm"]
        do {
            try fm.copyItem(at: source, to: staged)
            // A backup made by copying the app's folder has its latest changes in the -wal file.
            if fm.fileExists(atPath: source.path + "-wal") {
                try fm.copyItem(atPath: source.path + "-wal", toPath: staged.path + "-wal")
            }
            // A read-only backup must not become a read-only database.
            for suffix in [""] + logSuffixes where fm.fileExists(atPath: staged.path + suffix) {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path + suffix)
            }
            try checkDatabaseFile(at: staged)
        } catch {
            // Only the copy made above; the chosen file is not touched.
            for suffix in [""] + logSuffixes { try? fm.removeItem(atPath: staged.path + suffix) }
            throw error
        }
        // Empty after the checkpoint in checkDatabaseFile, if SQLite left them at all.
        for suffix in logSuffixes { try? fm.removeItem(atPath: staged.path + suffix) }
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
