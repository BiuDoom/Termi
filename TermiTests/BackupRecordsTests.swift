import Foundation
import Testing
@testable import Termi

/// Settings › Backup: the stored note of backups is checked against the files, and the paths
/// the Settings pages show are the ones this profile uses.
@Suite("Backup records are checked against the files")
struct BackupRecordsTests {
    /// 2026-10-05 12:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_791_201_600)

    private static func date(daysAgo: Double) -> Date {
        now.addingTimeInterval(-daysAgo * 86_400)
    }

    /// A folder of this test's own under the temporary directory.
    private static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupRecordsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func write(_ name: String, in folder: URL, bytes: Int = 16) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    /// A Mac whose only disk is the startup disk "BOOT": `paths` are what exists on it.
    private static func startupDiskOnly(_ paths: Set<String>) -> BackupFileProbe {
        BackupFileProbe(exists: { paths.contains($0) }, volumeIdentifier: { _ in "BOOT" })
    }

    // MARK: Existing and missing files

    @Test("A record counts while its file exists")
    func existingFileIsKept() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.write("a.db", in: folder)
        let record = BackupRecord(path: file.path, date: Self.date(daysAgo: 1),
                                  volume: BackupFileProbe.live.volumeIdentifier(file.path))

        let check = BackupOverview.check([record], probe: .live)
        #expect(check.kept == [record])
        #expect(check.unreachable.isEmpty)
        #expect(check.dropped.isEmpty)
    }

    @Test("A record whose file was deleted from a folder that is still there is dropped")
    func deletedFileIsDropped() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = try Self.write("kept.db", in: folder)
        let volume = BackupFileProbe.live.volumeIdentifier(kept.path)
        #expect(volume != nil)
        let present = BackupRecord(path: kept.path, date: Self.date(daysAgo: 3), volume: volume)
        let deleted = BackupRecord(path: folder.appendingPathComponent("deleted.db").path,
                                   date: Self.date(daysAgo: 1), volume: volume)

        let check = BackupOverview.check([deleted, present], probe: .live)
        #expect(check.kept == [present])
        #expect(check.dropped == [deleted])
        #expect(check.unreachable.isEmpty)
    }

    @Test("A record whose whole folder was deleted from a connected disk is dropped")
    func deletedFolderOnTheSameVolumeIsDropped() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let volume = BackupFileProbe.live.volumeIdentifier(folder.path)
        let record = BackupRecord(path: folder.appendingPathComponent("gone/deeper/a.db").path,
                                  date: Self.now, volume: volume)

        #expect(BackupOverview.state(of: record, probe: .live) == BackupOverview.RecordState.missing)
    }

    @Test("A file that exists is kept whatever its path looks like: spaces, non-ASCII, a tilde, a link")
    func oddPathsAreKept() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let odd = folder.appendingPathComponent("My Backups ~ 备份 é", isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let file = try Self.write("termi 备份 ~1.db", in: odd)
        let link = folder.appendingPathComponent("link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let volume = BackupFileProbe.live.volumeIdentifier(file.path)
        let records = [
            BackupRecord(path: file.path, date: Self.date(daysAgo: 1), volume: volume),
            BackupRecord(path: link.path, date: Self.date(daysAgo: 2), volume: volume),
            BackupRecord(path: file.path, date: Self.date(daysAgo: 3))
        ]

        let check = BackupOverview.check(records, probe: .live)
        #expect(check.kept == records)
        #expect(check.dropped.isEmpty)
        #expect(check.unreachable.isEmpty)
        #expect(check.unreadable.isEmpty)

        // A link is listed under its own name with the size of the file it leads to.
        let listed = try #require(BackupFile(url: link, kind: .backup, fileManager: .default))
        let linkedSize: Int64 = listed.size
        #expect(linkedSize == 16)
        #expect(listed.name == "link.db")
    }

    @Test("A folder that took the file's place is not the backup")
    func folderInPlaceOfTheFileIsDropped() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("a.db", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let record = BackupRecord(path: path.path, date: Self.now,
                                  volume: BackupFileProbe.live.volumeIdentifier(folder.path))

        #expect(BackupOverview.state(of: record, probe: .live) == BackupOverview.RecordState.missing)
    }

    // MARK: No answer is not "deleted"

    @Test("A backup in a folder the app may not look into is kept, and marked")
    func noAnswerIsNotDeleted() {
        // The file system says neither yes nor "no such file" (a privacy refusal for
        // Documents, a folder without search permission): the folder above is there, on the
        // same disk — which would otherwise read as "deleted".
        let probe = BackupFileProbe(exists: { ["/", "/Users", "/Users/me", "/Users/me/Documents"].contains($0) },
                                    volumeIdentifier: { _ in "BOOT" },
                                    cannotTell: { $0.hasPrefix("/Users/me/Documents/") })
        let withVolume = BackupRecord(path: "/Users/me/Documents/Termi/a.db", date: Self.now, volume: "BOOT")
        let legacy = BackupRecord(path: "/Users/me/Documents/Termi/b.db", date: Self.date(daysAgo: 1))

        let check = BackupOverview.check([withVolume, legacy], probe: probe)
        #expect(check.kept == [withVolume, legacy])
        #expect(check.unreadable == [withVolume, legacy])
        #expect(check.unreachable.isEmpty)
        #expect(check.dropped.isEmpty)
    }

    @Test("Really: a file inside a folder without search permission is not dropped")
    func unsearchableFolderKeepsItsRecord() throws {
        let folder = try Self.makeFolder()
        let locked = folder.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let file = try Self.write("a.db", in: locked)
        let volume = BackupFileProbe.live.volumeIdentifier(file.path)
        let record = BackupRecord(path: file.path, date: Self.now, volume: volume)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: folder)
        }

        let listing = SettingsViewModel.backupListing(records: [record], databaseURL: nil, probe: .live)
        #expect(listing.check.kept == [record])
        #expect(listing.check.unreadable == [record])
        #expect(listing.check.dropped.isEmpty)
        #expect(listing.files.map(\.availability) == [BackupFile.Availability.cannotBeRead])
        #expect(listing.files.first?.isReachable == false)

        // With the folder open again the same record is an ordinary row.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        let after = SettingsViewModel.backupListing(records: [record], databaseURL: nil, probe: .live)
        #expect(after.check.unreadable.isEmpty)
        #expect(after.files.map(\.availability) == [BackupFile.Availability.here])
    }

    // MARK: A disk that is not connected

    @Test("A backup on a disk that is not connected is kept, and marked")
    func unmountedVolumeIsNotDropped() {
        // /Volumes/Stick is not there: its parent folder is on the startup disk.
        let probe = Self.startupDiskOnly(["/", "/Volumes"])
        let record = BackupRecord(path: "/Volumes/Stick/Backups/a.db", date: Self.now, volume: "STICK")

        let check = BackupOverview.check([record], probe: probe)
        #expect(check.kept == [record])
        #expect(check.unreachable == [record])
        #expect(check.dropped.isEmpty)
    }

    @Test("An empty mount point left on the startup disk is not the disk")
    func leftoverMountPointIsNotTheDisk() {
        let probe = Self.startupDiskOnly(["/", "/Users", "/Users/me", "/Users/me/nas"])
        let record = BackupRecord(path: "/Users/me/nas/Backups/a.db", date: Self.now, volume: "mount:/Users/me/nas")

        #expect(BackupOverview.state(of: record, probe: probe) == BackupOverview.RecordState.unreachable)
    }

    @Test("With the disk connected, a deleted backup on it is dropped")
    func deletedOnAConnectedExternalDiskIsDropped() {
        let paths: Set<String> = ["/", "/Volumes", "/Volumes/Stick", "/Volumes/Stick/Backups"]
        let probe = BackupFileProbe(exists: { paths.contains($0) },
                                    volumeIdentifier: { $0.hasPrefix("/Volumes/Stick") ? "STICK" : "BOOT" })
        let record = BackupRecord(path: "/Volumes/Stick/Backups/a.db", date: Self.now, volume: "STICK")

        #expect(BackupOverview.state(of: record, probe: probe) == BackupOverview.RecordState.missing)
    }

    @Test("A note from before volumes were kept: only a missing /Volumes entry reads as not connected")
    func recordsWithoutAVolume() {
        let probe = Self.startupDiskOnly(["/", "/Volumes", "/Volumes/Here", "/Users", "/Users/me"])
        let gone = BackupRecord(path: "/Volumes/Gone/Backups/a.db", date: Self.now)
        let here = BackupRecord(path: "/Volumes/Here/a.db", date: Self.now)
        let home = BackupRecord(path: "/Users/me/Documents/Termi/a.db", date: Self.now)
        let temporary = BackupRecord(path: "/private/tmp/removed-long-ago/a.db", date: Self.now)

        let check = BackupOverview.check([gone, here, home, temporary], probe: probe)
        #expect(check.kept == [gone])
        #expect(check.unreachable == [gone])
        #expect(check.dropped == [here, home, temporary])
    }

    // MARK: The stored note

    @Test("The pruned note is saved; a backup noted meanwhile stays")
    func pruningIsSaved() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A preferences "domain" that is an absolute path is a property list at that path.
        let defaults = try #require(UserDefaults(suiteName: folder.appendingPathComponent("Preferences").path))

        let file = try Self.write("a.db", in: folder)
        let volume = BackupFileProbe.live.volumeIdentifier(file.path)
        let present = BackupRecord(path: file.path, date: Self.date(daysAgo: 2), volume: volume)
        let deleted = BackupRecord(path: folder.appendingPathComponent("b.db").path,
                                   date: Self.date(daysAgo: 1), volume: volume)
        let legacy = BackupRecord(path: folder.appendingPathComponent("was-here/c.db").path,
                                  date: Self.date(daysAgo: 5))
        SettingsViewModel.storeBackupRecords([deleted, present, legacy], in: defaults)
        #expect(SettingsViewModel.storedBackupRecords(in: defaults) == [deleted, present, legacy])

        let check = BackupOverview.check(SettingsViewModel.storedBackupRecords(in: defaults), probe: .live)
        #expect(check.dropped == [deleted, legacy])

        // A backup made while the files were being checked.
        let meanwhile = BackupRecord(path: folder.appendingPathComponent("d.db").path, date: Self.now, volume: volume)
        SettingsViewModel.storeBackupRecords([meanwhile, deleted, present, legacy], in: defaults)

        SettingsViewModel.forgetBackupRecords(check.dropped, in: defaults)
        #expect(SettingsViewModel.storedBackupRecords(in: defaults) == [meanwhile, present])
    }

    @Test("An old note without volumes still decodes")
    func oldNotesDecode() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = try #require(UserDefaults(suiteName: folder.appendingPathComponent("Preferences").path))
        let old = Data(#"[{"path":"/x/a.db","date":812894400}]"#.utf8)
        defaults.set(old, forKey: SettingsViewModel.backupRecordsKey)

        let records = SettingsViewModel.storedBackupRecords(in: defaults)
        #expect(records == [BackupRecord(path: "/x/a.db", date: Date(timeIntervalSinceReferenceDate: 812_894_400))])
        #expect(records.first?.volume == nil)
    }

    // MARK: What the page derives

    @Test("The last backup ignores a newer record whose file is gone")
    func lastBackupIgnoresDroppedRecords() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.write("old.db", in: folder)
        let volume = BackupFileProbe.live.volumeIdentifier(file.path)
        let old = BackupRecord(path: file.path, date: Self.date(daysAgo: 9), volume: volume)
        let newerButDeleted = BackupRecord(path: folder.appendingPathComponent("new.db").path,
                                           date: Self.date(daysAgo: 0.5), volume: volume)

        var overview = BackupOverview()
        overview.records = BackupOverview.check([newerButDeleted, old], probe: .live).kept
        #expect(overview.lastBackupDate == old.date)

        // Nothing left: the page says "Never backed up", whatever the note said.
        try FileManager.default.removeItem(at: file)
        overview.records = BackupOverview.check([newerButDeleted, old], probe: .live).kept
        #expect(overview.lastBackupDate == nil)
    }

    @Test("The list has the files that exist, with their real size, and the unreachable one marked")
    func listingComesFromTheFiles() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.write("a.db", in: folder, bytes: 4_096)
        let volume = BackupFileProbe.live.volumeIdentifier(file.path)
        let present = BackupRecord(path: file.path, date: Self.date(daysAgo: 2), volume: volume)
        let deleted = BackupRecord(path: folder.appendingPathComponent("b.db").path,
                                   date: Self.date(daysAgo: 1), volume: volume)
        let elsewhere = BackupRecord(path: folder.appendingPathComponent("not-mounted/c.db").path,
                                     date: Self.date(daysAgo: 4), volume: "a-volume-that-is-not-connected")

        let listing = SettingsViewModel.backupListing(records: [deleted, present, elsewhere],
                                                      databaseURL: nil, probe: .live)
        #expect(listing.check.kept == [present, elsewhere])
        #expect(listing.check.dropped == [deleted])
        #expect(listing.databaseSize == nil)

        let names = listing.files.map(\.name).sorted()
        #expect(names == ["a.db", "c.db"])
        let listed = try #require(listing.files.first { $0.name == "a.db" })
        let listedSize: Int64 = listed.size
        #expect(listedSize == 4_096)
        #expect(listed.isReachable)
        let unreachable = try #require(listing.files.first { $0.name == "c.db" })
        #expect(!unreachable.isReachable)
        #expect(unreachable.date == elsewhere.date)

        // An unreachable backup always says where it is; it is never "the usual folder".
        var overview = BackupOverview()
        overview.files = listing.files
        #expect(overview.unusualFolder(of: unreachable)?.lastPathComponent == "not-mounted")
        #expect(overview.unusualFolder(of: listed) == nil)
    }

    @Test("The databases a restore kept are listed from the folder, not from memory")
    func keptDatabasesComeFromTheFolder() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try Self.write("termi.db", in: folder, bytes: 1_000)
        _ = try Self.write("termi.db-wal", in: folder, bytes: 24)
        let kept = try Self.write("termi.before-restore-20260928-101502.db", in: folder, bytes: 512)

        let listing = SettingsViewModel.backupListing(records: [], databaseURL: database, probe: .live)
        #expect(listing.files.map(\.name) == [kept.lastPathComponent])
        let expectedSize: Int64 = 1_024
        #expect(listing.databaseSize == expectedSize)

        try FileManager.default.removeItem(at: kept)
        let after = SettingsViewModel.backupListing(records: [], databaseURL: database, probe: .live)
        #expect(after.files.isEmpty)
    }

    // MARK: Paths the Settings pages show

    @Test("A path is shown as it is, with the home folder as ~")
    func displayPaths() {
        let home = "/Users/me"
        #expect(SettingsViewModel.displayPath(URL(fileURLWithPath: "/Users/me/.termi/sync"), home: home) == "~/.termi/sync")
        #expect(SettingsViewModel.displayPath(URL(fileURLWithPath: "/Users/me"), home: home) == "~")
        // Another user's folder that merely starts with the same letters.
        #expect(SettingsViewModel.displayPath(URL(fileURLWithPath: "/Users/meow/sync"), home: home) == "/Users/meow/sync")
        #expect(SettingsViewModel.displayPath(URL(fileURLWithPath: "/Volumes/QA/profile/sync"), home: home) == "/Volumes/QA/profile/sync")
    }

    @Test("Sync and the key file are shown where this profile keeps them")
    func settingsShowTheProfilesFolders() throws {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        let standardFolder = home.appendingPathComponent("Library/Application Support/Termi", isDirectory: true)
        let temporary = URL(fileURLWithPath: "/Volumes/QA/tmp", isDirectory: true)

        let standard = try AppProfile.resolve(environment: [:], defaultDirectory: standardFolder, homeDirectory: home,
                                              temporaryDirectory: temporary, processIdentifier: 1).get()
        #expect(SettingsViewModel.syncFolderText(for: standard, home: home.path) == "~/.termi/sync")
        #expect(SettingsViewModel.vaultKeyText(for: standard, home: home.path)
                == "~/Library/Application Support/Termi/.vault-key")

        let isolated = try AppProfile.resolve(environment: [AppProfile.overrideVariable: "/Volumes/QA/profile"],
                                              defaultDirectory: standardFolder, homeDirectory: home,
                                              temporaryDirectory: temporary, processIdentifier: 1).get()
        #expect(SettingsViewModel.syncFolderText(for: isolated, home: home.path) == "/Volumes/QA/profile/sync")
        #expect(SettingsViewModel.vaultKeyText(for: isolated, home: home.path) == "/Volumes/QA/profile/.vault-key")

        // This run (a hosted test run has its own folder): the text is that folder's.
        #expect(SettingsViewModel.syncFolderText()
                == SettingsViewModel.displayPath(AppProfile.current.syncDirectory))
    }
}
