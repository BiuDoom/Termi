import Foundation
import os.log

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
