import Foundation
import os.log
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The saved terminal output of the sessions: one file per history record, named by the
/// record's id, in the profile's `SessionLogs` folder.
///
/// A transcript lives exactly as long as its history record: whoever deletes records hands
/// their ids to `remove(ids:in:)` once the database has let them go. Nothing here looks for
/// transcripts "no record refers to" — after Settings › Backup › Restore the previous database
/// is kept for rolling back, and its records refer to transcripts the restored database does
/// not know. Only an explicit deletion (and the age limit at launch) removes a transcript.
enum SessionTranscripts {
    private static let logger = Logger(subsystem: "dev.termi.Termi", category: "SessionTranscripts")

    /// Where this run keeps them.
    static var directory: URL {
        AppProfile.current.sessionLogsDirectory
    }

    static func url(for logId: Int64, in directory: URL = SessionTranscripts.directory) -> URL {
        directory.appendingPathComponent("\(logId).log")
    }

    /// The highest record number a transcript on disk carries, nil without any. A new history
    /// record must be numbered above it: after Settings › Backup › Restore (or an import) the
    /// database's own counter can lie behind transcripts that are kept for rolling back, and a
    /// record that reused such a number would show — and, when deleted, remove — the output of
    /// another session.
    static func highestId(in directory: URL = SessionTranscripts.directory) -> Int64? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap(recordId(ofFileNamed:)).max()
    }

    /// "<id>.log" and nothing else: no partial files, no other extensions, no signs.
    static func recordId(ofFileNamed name: String) -> Int64? {
        guard name.hasSuffix(".log") else { return nil }
        let stem = name.dropLast(4)
        guard !stem.isEmpty, stem.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(stem)
    }

    /// Creates `<id>.log` so that only this user can read it, from the first moment it exists.
    ///
    /// Returns nil when that name is already taken (a regular file or a symlink). The existing
    /// entry is left as it is: `FileManager.createFile` would follow a symlink and truncate
    /// whatever it names, and it creates a new file with the process umask (usually 0644)
    /// before any later chmod. A transcript is the session's output, including whatever was
    /// typed at the prompt.
    ///
    /// The directory is tightened to 0700 before the file is created. A symlink at the
    /// directory path is refused, so this never chmods the directory a link points at.
    static func createExclusive(for logId: Int64, in directory: URL = SessionTranscripts.directory) throws -> URL? {
        try prepareOwnerOnlyDirectory(directory)
        let url = url(for: logId, in: directory)
        do {
            try SSHRuntime.createPrivateFile(Data(), at: url, permissions: 0o600)
        } catch SSHRuntime.PrivateFileError.alreadyExists {
            return nil
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            unlink(url.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let mode = UInt32(info.st_mode) & 0o777
        // A filesystem that ignores fchmod would leave the umask mode. Do not keep that file:
        // the next write would put the session into it.
        guard info.st_mode & S_IFMT == S_IFREG, mode & 0o077 == 0 else {
            unlink(url.path)
            throw POSIXError(.EPERM)
        }
        return url
    }

    /// `directory` is a real directory and not group- or world-writable, or this throws.
    ///
    /// `mkdir` applies the umask, so a directory asked for as 0700 is often created 0755.
    /// `fchmod` on the directory fd sets 0700 before a transcript is created in it.
    /// `O_NOFOLLOW` refuses a symlink. Group/world write must actually be gone: a directory
    /// that stayed 0777 could be given a symlink in place of the transcript.
    private static func prepareOwnerOnlyDirectory(_ url: URL) throws {
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.EPERM) }
        } else {
            let error = errno
            guard error == ENOENT else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = close(fd) }
        guard fchmod(fd, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let mode = UInt32(info.st_mode) & 0o777
        guard info.st_mode & S_IFMT == S_IFDIR, mode & 0o022 == 0 else {
            throw POSIXError(.EPERM)
        }
    }

    /// Removes the transcripts of these history records and returns the ids whose transcript
    /// could NOT be removed. A record without a transcript (a failed connection never had one)
    /// is not a failure. A file that stays is logged, never fatal: the records are gone already
    /// and the caller has nothing to roll back.
    @discardableResult
    static func remove(ids: [Int64], in directory: URL = SessionTranscripts.directory) -> [Int64] {
        let fileManager = FileManager.default
        var kept: [Int64] = []
        var removed = 0
        for id in ids {
            let file = url(for: id, in: directory)
            do {
                try fileManager.removeItem(at: file)
                removed += 1
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                // `removeItem` reports a missing file in more than one way; what matters is
                // whether the output is still there.
                guard fileManager.fileExists(atPath: file.path) else { continue }
                kept.append(id)
                logger.error("Could not remove the transcript of history record \(id): \(error.localizedDescription, privacy: .public)")
            }
        }
        if removed > 0 {
            logger.info("Removed \(removed) session transcript(s)")
        }
        return kept
    }
}
