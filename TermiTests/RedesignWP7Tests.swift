import Foundation
import Testing
@testable import Termi

/// The logic behind Settings › Backup: what counts as a backup, which is the last one, how the
/// files are listed.
@Suite("Backup overview")
struct BackupOverviewTests {
    /// 2026-10-05 12:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_791_201_600)

    private static func record(_ path: String, daysAgo: Double) -> BackupRecord {
        BackupRecord(path: path, date: now.addingTimeInterval(-daysAgo * 86_400))
    }

    @Test("The last backup is the newest note; none without one")
    func lastBackup() {
        var overview = BackupOverview()
        #expect(overview.lastBackupDate == nil)
        overview.records = [Self.record("/b.db", daysAgo: 6), Self.record("/a.db", daysAgo: 0.1),
                            Self.record("/e.db", daysAgo: 40)]
        #expect(overview.lastBackupDate == overview.records[1].date)
    }

    @Test("Saving over a backup replaces its entry; newest first")
    func recording() {
        let old = [Self.record("/a.db", daysAgo: 3), Self.record("/b.db", daysAgo: 5)]
        let result = BackupOverview.recording(Self.record("/b.db", daysAgo: 0), in: old)
        #expect(result.map(\.path) == ["/b.db", "/a.db"])
        #expect(result[0].date == Self.now)
    }

    @Test("The note keeps at most recordLimit entries, dropping the oldest")
    func recordingLimit() {
        let old = (1...BackupOverview.recordLimit).map { Self.record("/\($0).db", daysAgo: Double($0)) }
        let result = BackupOverview.recording(Self.record("/new.db", daysAgo: 0), in: old)
        #expect(result.count == BackupOverview.recordLimit)
        #expect(result.first?.path == "/new.db")
        #expect(!result.contains { $0.path == "/\(BackupOverview.recordLimit).db" })
    }

    @Test("Only termi.before-….db beside the database is a kept database")
    func keptDatabase() {
        #expect(BackupOverview.isKeptDatabase("termi.before-restore-20260928-101502.db", stem: "termi", pathExtension: "db"))
        #expect(BackupOverview.isKeptDatabase("termi.before-import-20260928-101502-2.db", stem: "termi", pathExtension: "db"))
        #expect(!BackupOverview.isKeptDatabase("termi.db", stem: "termi", pathExtension: "db"))
        #expect(!BackupOverview.isKeptDatabase("termi.db-wal", stem: "termi", pathExtension: "db"))
        #expect(!BackupOverview.isKeptDatabase("termi.before-restore-20260928-101502.db-wal", stem: "termi", pathExtension: "db"))
        #expect(!BackupOverview.isKeptDatabase("other.before-restore-1.db", stem: "termi", pathExtension: "db"))
    }

    @Test("Files are listed newest first, each once")
    func sortedFiles() {
        let a = BackupFile(url: URL(fileURLWithPath: "/x/a.db"), kind: .backup, date: Self.now, size: 10)
        let b = BackupFile(url: URL(fileURLWithPath: "/x/b.db"), kind: .keptDatabase,
                           date: Self.now.addingTimeInterval(-60), size: 20)
        let sorted = BackupOverview.sorted([b, a, b])
        #expect(sorted.map(\.name) == ["a.db", "b.db"])
    }
}
