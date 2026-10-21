import Testing
import Foundation
import GRDB
@testable import Termi

private func csvDatabase() throws -> DatabaseQueue {
    let database = try DatabaseQueue()
    try Migrations.migrator.migrate(database)
    return database
}

@Test func csvExportImportPreservesMultilineQuotedAndWhitespaceFields() async throws {
    let database = try csvDatabase()
    var original = Termi.Host.defaultValue()
    original.label = "  web, \"primary\"  "
    original.hostname = "original.example"
    original.username = ""
    original.notes = " first line\r\nextra,wrong.example,22,root,password,,unexpected\nlast \"quote\"\rend "
    original.groupId = 7
    let group = HostGroup(id: 7, name: " Production ", sortOrder: 0, createdAt: "")
    let content = ImportExportService.hostsCSV(hosts: [original], groups: [group])
    let imported = try await ImportExportService.importHostsCSV(content, into: database)
    #expect(imported.count == 1)
    let saved = try #require(imported.first)
    #expect(saved.label == original.label)
    #expect(saved.hostname == original.hostname)
    #expect(saved.username == original.username)
    #expect(saved.notes == original.notes)
    let savedGroup = try await database.read { db in try HostGroup.fetchOne(db, key: saved.groupId) }
    #expect(savedGroup?.name == group.name)
}

@Test func csvImportsBOMCRLFHeadersAndSkipsEmptyPhysicalRecords() async throws {
    let database = try csvDatabase()
    let content = "\u{FEFF}name,host,port,user,description\r\n\r\nweb,web.example,2222,deploy,\"one\r\ntwo\"\r\n"
    let hosts = try await ImportExportService.importHostsCSV(content, into: database)
    #expect(hosts.count == 1)
    #expect(hosts.first?.port == 2222)
    #expect(hosts.first?.notes == "one\r\ntwo")
}

@Test func csvReusesExistingGroupAndCreatesMissingGroupOnlyOnce() async throws {
    let database = try csvDatabase()
    let existing = try await database.write { db in
        try HostGroup(name: "Production", sortOrder: 2, createdAt: "", username: "deploy").insertAndFetch(db)
    }
    let content = "label,hostname,username,group\na,a.example,,Production\nb,b.example,root,New\nc,c.example,root,New\nd,d.example,root,\n"
    let hosts = try await ImportExportService.importHostsCSV(content, into: database)
    #expect(hosts.count == 4)
    #expect(hosts[0].groupId == existing.id)
    #expect(hosts[0].username.isEmpty)
    #expect(hosts[1].groupId != nil)
    #expect(hosts[1].groupId == hosts[2].groupId)
    #expect(hosts[3].groupId == nil)
    let groups = try await database.read { db in try HostGroup.fetchAll(db) }
    #expect(groups.count == 2)
    #expect(groups.first(where: { $0.id == existing.id })?.username == "deploy")
}

@Test func csvRejectsAmbiguousExistingGroupsWithoutSavingEarlierRecords() async throws {
    let database = try csvDatabase()
    try await database.write { db in
        try HostGroup(name: "Same", sortOrder: 0, createdAt: "", username: "root").insert(db)
        try HostGroup(name: "Same", sortOrder: 1, createdAt: "", username: "deploy").insert(db)
    }
    let content = "hostname,group\nfirst.example,New\nsecond.example,Same\n"
    await #expect(throws: ImportExportService.ImportError.self) {
        try await ImportExportService.importHostsCSV(content, into: database)
    }
    let counts = try await database.read { db in (try Termi.Host.fetchCount(db), try HostGroup.fetchCount(db)) }
    #expect(counts.0 == 0)
    #expect(counts.1 == 2)
}

@Test(arguments: [
    "second,second.example,22,root,password,\"unfinished",
    "second,second.example,22,root,password,\"notes\"oops",
    "second,second.example,22,root,password,note\"quote",
    "second,second.example,22,root,password",
    "second,second.example,99999,root,password,notes",
    "second,second.example,not-a-port,root,password,notes",
    "second,bad host,22,root,password,notes",
    "second,second.example,22,root,unknown,notes"
])
func csvInvalidLaterRecordLeavesNoPartialImport(_ record: String) async throws {
    let database = try csvDatabase()
    let content = "label,hostname,port,username,auth_type,notes\nfirst,first.example,22,root,password,good\n" + record + "\n"
    await #expect(throws: ImportExportService.ImportError.self) {
        try await ImportExportService.importHostsCSV(content, into: database)
    }
    let count = try await database.read { db in try Termi.Host.fetchCount(db) }
    #expect(count == 0)
}

@Test func csvDatabaseFailureRollsBackHostsAndNewGroups() async throws {
    let database = try csvDatabase()
    try await database.write { db in
        try db.execute(sql: """
            CREATE TRIGGER refuse_csv_host BEFORE INSERT ON hosts
            WHEN NEW.hostname = 'reject.example'
            BEGIN SELECT RAISE(ABORT, 'fixture refused host'); END
            """)
    }
    let content = "hostname,group\nfirst.example,New\nreject.example,New\n"
    await #expect(throws: (any Error).self) {
        try await ImportExportService.importHostsCSV(content, into: database)
    }
    let counts = try await database.read { db in (try Termi.Host.fetchCount(db), try HostGroup.fetchCount(db)) }
    #expect(counts.0 == 0)
    #expect(counts.1 == 0)
}

@Test(arguments: ["one\r\ntwo", "one\rtwo", "comma,\u{0301}accent", "quote\"\u{0301}accent"])
func csvExportQuotesScalarDelimitersEvenInsideAGrapheme(_ notes: String) async throws {
    let database = try csvDatabase()
    var host = Termi.Host.defaultValue()
    host.hostname = "unicode.example"
    host.notes = notes
    let csv = ImportExportService.hostsCSV(hosts: [host], groups: [])
    let imported = try await ImportExportService.importHostsCSV(csv, into: database)
    #expect(imported.count == 1)
    #expect(imported.first?.notes == notes)
}

@Test func csvPreservesConfigAliasIndependentlyOfRenamedLabel() async throws {
    let database = try csvDatabase()
    var host = Termi.Host.defaultValue()
    host.hostname = "real.example"
    host.label = "Renamed display name"
    host.sshConfigAlias = "legacy-alias"
    let csv = ImportExportService.hostsCSV(hosts: [host], groups: [])
    let imported = try await ImportExportService.importHostsCSV(csv, into: database)
    #expect(imported.first?.sshConfigAlias == "legacy-alias")
    #expect(imported.first?.label == host.label)
    let legacy = try await ImportExportService.importHostsCSV("hostname\nlegacy.example\n", into: database)
    #expect(legacy.first?.sshConfigAlias == nil)
}

@Test func sshConfigImportKeepsAliasesWhenHostLabelsChangeAndRecoversOldImports() async throws {
    let tag = UUID().uuidString.lowercased()
    let alias = "alias-\(tag)"
    let jumpAlias = "jump-\(tag)"
    let hostname = "host-\(tag).invalid"
    let jumpHostname = "jump-\(tag).invalid"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-import-\(tag)")
    defer { try? FileManager.default.removeItem(at: url) }
    try """
        Host \(alias)
          HostName \(hostname)
          User deploy
          ProxyJump \(jumpAlias)
        Host \(jumpAlias)
          HostName \(jumpHostname)
          User jumpuser
        """.write(to: url, atomically: true, encoding: .utf8)
    _ = try await ImportExportService.shared.importSSHConfig(from: url)
    let repo = HostRepository.shared
    let hosts = try await repo.fetchAll()
    var host = try #require(hosts.first { $0.hostname == hostname })
    let jump = try #require(hosts.first { $0.hostname == jumpHostname })
    let hostId = try #require(host.id)
    let jumpId = try #require(jump.id)
    #expect(host.sshConfigAlias == alias)
    #expect(jump.sshConfigAlias == jumpAlias)
    #expect(host.jumpHostId == jumpId)
    host.label = "Renamed label"
    host.sshConfigAlias = nil // A host imported before aliases were retained.
    _ = try await repo.save(host)
    _ = try await ImportExportService.shared.importSSHConfig(from: url)
    let restored = try await repo.fetch(id: hostId)
    #expect(restored?.label == "Renamed label")
    #expect(restored?.sshConfigAlias == alias)
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: jumpId)
}
