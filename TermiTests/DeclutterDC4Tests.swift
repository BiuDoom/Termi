import Foundation
import Testing
@testable import Termi

// The conditions behind the decluttered Port Forwards, Snippets and Backup screens: what is
// left out because another element on the screen already says it.

private func makeHost(_ id: Int64, _ label: String) -> Termi.Host {
    var host = Termi.Host.defaultValue()
    host.id = id
    host.label = label
    host.hostname = "10.0.0.\(id)"
    return host
}

private func makeRule(_ id: Int64, type: String, local: Int, remoteHost: String = "127.0.0.1", remote: Int = 0) -> PortForward {
    PortForward(id: id, hostId: 1, type: type, localPort: local, remoteHost: remoteHost, remotePort: remote,
                enabled: false, createdAt: "")
}

private func makeBackup(_ path: String, kind: BackupFile.Kind = .backup, secondsAgo: TimeInterval) -> BackupFile {
    BackupFile(url: URL(fileURLWithPath: path), kind: kind, date: Date(timeIntervalSince1970: 1_791_201_600 - secondsAgo),
               size: 10)
}

// MARK: - Port forwards

@Test @MainActor func aRuleUnderItsHostsHeaderDoesNotNameTheHostAgain() {
    let host = makeHost(1, "web")
    let local = PortForwardRowView.hops(for: makeRule(1, type: "local", local: 18080, remote: 8080), host: host,
                                        hostLabel: "web", underHostHeader: true)
    #expect(local.map(\.title) == ["localhost:18080", "127.0.0.1:8080"])

    // A remote forward listens on the host: that end is the rule, not a repeat of the header.
    let remote = PortForwardRowView.hops(for: makeRule(2, type: "remote", local: 9000, remoteHost: "localhost", remote: 3000),
                                         host: host, hostLabel: "web", underHostHeader: true)
    #expect(remote.map(\.title) == ["web:9000", "localhost:3000"])

    // Listening and target may read the same: their ids (those of a ForEach) still differ.
    let mirror = PortForwardRowView.hops(for: makeRule(3, type: "local", local: 3000, remoteHost: "localhost", remote: 3000),
                                         host: host, hostLabel: "web", underHostHeader: true)
    #expect(mirror.map(\.title) == ["localhost:3000", "localhost:3000"])
    let mirrorIds = Set(mirror.map(\.id)).count
    #expect(mirrorIds == 2)
}

@Test @MainActor func aRuleWhoseHostIsGoneKeepsTheMiddleHop() {
    let orphan = PortForwardRowView.hops(for: makeRule(1, type: "dynamic", local: 1080), host: nil, hostLabel: "Host #9",
                                         underHostHeader: true)
    #expect(orphan.map(\.title).count == 3)
    #expect(orphan[1].title == "Host #9")
}

@Test func onlyFailedStartsAreCounted() {
    let statuses: [PortForwardManager.Status?] = [.active, nil, .starting, .failed("bind: Address already in use"),
                                                  .failed("denied")]
    #expect(PortForwardViewModel.failedCount(in: statuses) == 2)
    #expect(PortForwardViewModel.failedCount(in: [.active, nil]) == 0)
    #expect(PortForwardViewModel.failedCount(in: []) == 0)
}

@Test func aNewRuleSkipsTheHostPickerOnlyWithASingleHost() {
    #expect(PortForwardViewModel.onlyHostId(in: [makeHost(7, "web")]) == 7)
    #expect(PortForwardViewModel.onlyHostId(in: [makeHost(7, "web"), makeHost(8, "db")]) == nil)
    #expect(PortForwardViewModel.onlyHostId(in: []) == nil)
}

// MARK: - Snippets

@Test func aSectionHeaderCountsOnlyWhatItsFilterDoesNotSay() {
    // The category's filter chip shows 2: the header does not repeat it.
    #expect(SnippetsViewModel.headerCount(shown: 2, filterCount: 2) == nil)
    // A search left one of the two.
    #expect(SnippetsViewModel.headerCount(shown: 1, filterCount: 2) == 1)
    // "Uncategorized" has no filter of its own.
    #expect(SnippetsViewModel.headerCount(shown: 3, filterCount: nil) == 3)
}

@Test func runInListsSessionsOnlyWhenThereIsAChoice() {
    #expect(!SnippetsViewModel.showsRunTargets(sessionCount: 0))
    #expect(!SnippetsViewModel.showsRunTargets(sessionCount: 1))
    #expect(SnippetsViewModel.showsRunTargets(sessionCount: 2))
}

// MARK: - Backup

@Test func aBackupRowNamesItsFolderOnlyOutsideTheUsualOne() {
    var overview = BackupOverview()
    let newest = makeBackup("/Users/me/Documents/Termi/a.db", secondsAgo: 0)
    let same = makeBackup("/Users/me/Documents/Termi/b.db", secondsAgo: 60)
    let elsewhere = makeBackup("/Volumes/Stick/c.db", secondsAgo: 120)
    let kept = makeBackup("/Users/me/Library/Application Support/Termi/termi.before-restore-1.db", kind: .keptDatabase,
                          secondsAgo: 30)
    overview.files = BackupOverview.sorted([same, kept, elsewhere, newest])

    #expect(overview.unusualFolder(of: newest) == nil)
    #expect(overview.unusualFolder(of: same) == nil)
    #expect(overview.unusualFolder(of: elsewhere)?.path == "/Volumes/Stick")
    // A kept database is beside the database by definition: its tag says what it is.
    #expect(overview.unusualFolder(of: kept) == nil)
}

@Test func theRestoreConfirmationSaysWhatIsReplacedAndWhereTheOldDatabaseStays() {
    let folder = URL(fileURLWithPath: "/Users/Shared/Termi")
    let text = SettingsViewModel.restoreWarning(databaseFolder: folder)
    #expect(text.contains("/Users/Shared/Termi"))
    #expect(text.contains("termi.before-restore-"))
    // Without the folder the sentence is still whole.
    let unknown = SettingsViewModel.restoreWarning(databaseFolder: nil)
    #expect(unknown.contains("termi.before-restore-"))
    #expect(unknown != text)
}
