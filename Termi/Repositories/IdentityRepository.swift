import GRDB
import Foundation
import os.log

/// Repository for Identity CRUD operations
actor IdentityRepository {
    static let shared = IdentityRepository()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "IdentityRepo")

    func fetchAll() async throws -> [Identity] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try Identity.order(Column("name").asc).fetchAll(db)
        }
    }

    func fetch(id: Int64) async throws -> Identity? {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try Identity.fetchOne(db, key: id)
        }
    }

    @discardableResult
    func save(_ identity: Identity) async throws -> Identity {
        let writer = try await DatabaseManager.shared.writer
        return try await DataSnapshot.write(writer) { db in
            var i = identity
            if i.id == nil {
                i.createdAt = TimestampFormatter.now()
                // insertAndFetch backfills the generated id (a plain save() does not for these records)
                return try i.insertAndFetch(db)
            }
            // A host's saved password belongs to the account it was typed for: when the identity
            // now signs in as another user, or with another key or the agent, it goes. Changing
            // only the identity's name, notes or shared password keeps it.
            try SecureStoreService.dropHostPasswordsWhoseLoginChanges(hostIds: try Self.hostIds(using: i.id, db), in: db) {
                try i.save(db)
            }
            return i
        }
    }

    func delete(id: Int64) async throws {
        let writer = try await DatabaseManager.shared.writer
        _ = try await DataSnapshot.write(writer) { db in
            // The hosts that used it sign in some other way afterwards (the database sets their
            // identity to none): a password saved for the identity's account goes with it.
            try SecureStoreService.dropHostPasswordsWhoseLoginChanges(hostIds: try Self.hostIds(using: id, db), in: db) {
                try Identity.deleteOne(db, key: id)
            }
        }
        logger.info("Deleted identity \(id)")
    }

    /// The hosts that may sign in with this identity: their own, or their group's.
    private static func hostIds(using identityId: Int64?, _ db: Database) throws -> [Int64] {
        guard let identityId else { return [] }
        let groupIds = try HostGroup.filter(Column("identity_id") == identityId).fetchAll(db).compactMap(\.id)
        return try Host.filter(Column("identity_id") == identityId || groupIds.contains(Column("group_id")))
            .fetchAll(db).compactMap(\.id)
    }
}
