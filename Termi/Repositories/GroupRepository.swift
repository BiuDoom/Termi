import GRDB
import Foundation
import os.log

/// Repository for HostGroup CRUD operations
actor GroupRepository {
    static let shared = GroupRepository()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "GroupRepo")

    func fetchAll() async throws -> [HostGroup] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try HostGroup.order(Column("sort_order").asc, Column("name").asc).fetchAll(db)
        }
    }

    func fetch(id: Int64) async throws -> HostGroup? {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try HostGroup.fetchOne(db, key: id)
        }
    }

    @discardableResult
    func save(_ group: HostGroup) async throws -> HostGroup {
        let writer = try await DatabaseManager.shared.writer
        return try await DataSnapshot.write(writer) { db in
            var g = group
            if g.id == nil {
                g.createdAt = TimestampFormatter.now()
                // insertAndFetch backfills the generated id (a plain save() does not for these records)
                return try g.insertAndFetch(db)
            }
            // The group's username is the login of its hosts that set none: a password saved for
            // that account does not go to the next one.
            try SecureStoreService.dropHostPasswordsWhoseLoginChanges(hostIds: try Self.hostIds(in: g.id, db), in: db) {
                try g.save(db)
            }
            return g
        }
    }

    func delete(id: Int64) async throws {
        let writer = try await DatabaseManager.shared.writer
        try await DataSnapshot.write(writer) { db in
            try SecureStoreService.dropHostPasswordsWhoseLoginChanges(hostIds: try Self.hostIds(in: id, db), in: db) {
                // Move hosts to ungrouped before deleting
                try db.execute(
                    sql: "UPDATE hosts SET group_id = NULL WHERE group_id = ?",
                    arguments: [id]
                )
                try HostGroup.deleteOne(db, key: id)
            }
        }
        logger.info("Deleted group \(id)")
    }

    private static func hostIds(in groupId: Int64?, _ db: Database) throws -> [Int64] {
        guard let groupId else { return [] }
        return try Host.filter(Column("group_id") == groupId).fetchAll(db).compactMap(\.id)
    }

    func hostCount(groupId: Int64) async throws -> Int {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try Host.filter(Column("group_id") == groupId).fetchCount(db)
        }
    }
}
