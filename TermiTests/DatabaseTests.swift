import Testing
import Foundation
import GRDB
@testable import Termi

@Test func hostModelCreation() async throws {
    let host = Termi.Host.defaultValue()
    #expect(host.label == "")
    #expect(host.hostname == "")
    #expect(host.port == 22)
    #expect(host.username == "root")
    #expect(host.authType == "password")
}

@Test func terminalTabCreation() async throws {
    let tab = TerminalTab(title: "Test")
    #expect(tab.title == "Test")
    #expect(tab.isSSH == false)
    #expect(tab.hostId == nil)
}


@Test func sshConfigAliasMigrationAndOlderSnapshotDecoding() throws {
    let database = try DatabaseQueue()
    try Migrations.migrator.migrate(database, upTo: "v8_host_system")
    try database.write { db in
        try db.execute(sql: "INSERT INTO hosts (label, hostname, username) VALUES ('legacy', '10.0.0.8', 'deploy')")
    }
    try Migrations.migrator.migrate(database)
    let host = try database.write { db -> Termi.Host in
        var imported = try Termi.Host.fetchOne(db)!
        #expect(imported.sshConfigAlias == nil)
        imported.sshConfigAlias = "legacy"
        imported.label = "Renamed display name"
        return try HostRepository.save(imported, db)
    }
    #expect(host.sshConfigAlias == "legacy")
    let encoded = try JSONEncoder().encode(host)
    let decoded = try JSONDecoder().decode(Termi.Host.self, from: encoded)
    #expect(decoded.sshConfigAlias == "legacy")
    #expect(decoded.label == "Renamed display name")
    var oldJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    oldJSON.removeValue(forKey: "ssh_config_alias")
    let oldDecoded = try JSONDecoder().decode(Termi.Host.self, from: JSONSerialization.data(withJSONObject: oldJSON))
    #expect(oldDecoded.sshConfigAlias == nil)
    let snapshotJSON = try JSONSerialization.data(withJSONObject: ["hosts": [try JSONSerialization.jsonObject(with: encoded)]])
    let snapshot = try JSONDecoder().decode(SyncService.SyncData.self, from: snapshotJSON)
    #expect(snapshot.hosts.first?.sshConfigAlias == "legacy")
}
