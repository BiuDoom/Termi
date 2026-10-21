import GRDB
import Foundation
import os.log

/// Repository for PortForward CRUD operations
actor PortForwardRepository {
    static let shared = PortForwardRepository()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "PortFwdRepo")

    func fetchAll() async throws -> [PortForward] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try PortForward.order(Column("created_at").desc).fetchAll(db)
        }
    }

    func fetchForHost(_ hostId: Int64) async throws -> [PortForward] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try PortForward
                .filter(Column("host_id") == hostId)
                .order(Column("local_port").asc)
                .fetchAll(db)
        }
    }

    @discardableResult
    func save(_ forward: PortForward) async throws -> PortForward {
        let writer = try await DatabaseManager.shared.writer
        return try await DataSnapshot.write(writer) { db in
            var f = forward
            if f.id == nil {
                f.createdAt = TimestampFormatter.now()
                // insertAndFetch backfills the generated id (a plain save() does not for these records)
                return try f.insertAndFetch(db)
            }
            try f.save(db)
            return f
        }
    }

    func delete(id: Int64) async throws {
        let writer = try await DatabaseManager.shared.writer
        _ = try await DataSnapshot.write(writer) { db in
            try PortForward.deleteOne(db, key: id)
        }
        logger.info("Deleted port forward \(id)")
    }

    func toggleEnabled(id: Int64, enabled: Bool) async throws {
        let writer = try await DatabaseManager.shared.writer
        try await DataSnapshot.write(writer) { db in
            try db.execute(
                sql: "UPDATE port_forwards SET enabled = ? WHERE id = ?",
                arguments: [enabled, id]
            )
        }
    }
}
