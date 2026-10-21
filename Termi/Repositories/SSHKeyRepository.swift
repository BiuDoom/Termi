import GRDB
import Foundation
import os.log

/// Repository for SSH Key CRUD operations
actor SSHKeyRepository {
    static let shared = SSHKeyRepository()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "SSHKeyRepo")

    func fetchAll() async throws -> [SSHKey] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try SSHKey.order(Column("name").asc).fetchAll(db)
        }
    }

    func fetch(id: Int64) async throws -> SSHKey? {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try SSHKey.fetchOne(db, key: id)
        }
    }

    @discardableResult
    func save(_ key: SSHKey) async throws -> SSHKey {
        let writer = try await DatabaseManager.shared.writer
        return try await DataSnapshot.write(writer) { db in
            var k = key
            if k.id == nil {
                k.createdAt = TimestampFormatter.now()
                // insertAndFetch backfills the generated id (a plain save() does not for these records)
                return try k.insertAndFetch(db)
            }
            try k.save(db)
            return k
        }
    }

    func delete(id: Int64) async throws {
        let writer = try await DatabaseManager.shared.writer
        _ = try await DataSnapshot.write(writer) { db in
            try SSHKey.deleteOne(db, key: id)
        }
        logger.info("Deleted SSH key \(id)")
    }
}
