import GRDB
import Foundation
import os.log

/// Repository for Known Hosts CRUD operations
actor KnownHostRepository {
    static let shared = KnownHostRepository()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "KnownHostRepo")

    func fetchAll() async throws -> [KnownHost] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try KnownHost.order(Column("hostname").asc, Column("port").asc).fetchAll(db)
        }
    }

    /// Fetch a known host by hostname and port (any key type)
    func fetch(hostname: String, port: Int) async throws -> KnownHost? {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try KnownHost
                .filter(Column("hostname") == hostname)
                .filter(Column("port") == port)
                .fetchOne(db)
        }
    }

    /// All trusted keys (any key type) for a host.
    func fetchAll(hostname: String, port: Int) async throws -> [KnownHost] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try KnownHost
                .filter(Column("hostname") == hostname)
                .filter(Column("port") == port)
                .fetchAll(db)
        }
    }

    /// Store a key the user trusted, replacing an older key of the same type for that host.
    @discardableResult
    func trust(hostname: String, port: Int, publicKey: String, fingerprint: String) async throws -> KnownHost {
        let keyType = publicKey.split(separator: " ").first.map(String.init) ?? "unknown"
        let writer = try await DatabaseManager.shared.writer
        return try await DataSnapshot.write(writer) { db in
            try KnownHost
                .filter(Column("hostname") == hostname)
                .filter(Column("port") == port)
                .filter(Column("key_type") == keyType)
                .deleteAll(db)
            let host = KnownHost(hostname: hostname, port: port, keyType: keyType, publicKey: publicKey,
                                 fingerprint: fingerprint, addedAt: TimestampFormatter.now())
            return try host.insertAndFetch(db)
        }
    }

    func find(hostname: String, port: Int, keyType: String) async throws -> KnownHost? {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try KnownHost
                .filter(Column("hostname") == hostname)
                .filter(Column("port") == port)
                .filter(Column("key_type") == keyType)
                .fetchOne(db)
        }
    }

    /// Verify a host key against known hosts. Returns .trusted, .unknown, or .changed
    func verify(hostname: String, port: Int, keyType: String, fingerprint: String) async throws -> VerifyResult {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            let existing = try KnownHost
                .filter(Column("hostname") == hostname)
                .filter(Column("port") == port)
                .filter(Column("key_type") == keyType)
                .fetchOne(db)

            guard let known = existing else {
                return .unknown
            }

            if known.fingerprint == fingerprint {
                return .trusted
            } else {
                return .changed(oldFingerprint: known.fingerprint)
            }
        }
    }

    @discardableResult
    func save(_ host: KnownHost) async throws -> KnownHost {
        let writer = try await DatabaseManager.shared.writer
        return try await DataSnapshot.write(writer) { db in
            var h = host
            if h.id == nil {
                h.addedAt = TimestampFormatter.now()
            }
            try h.save(db)
            return h
        }
    }

    func delete(id: Int64) async throws {
        let writer = try await DatabaseManager.shared.writer
        _ = try await DataSnapshot.write(writer) { db in
            try KnownHost.deleteOne(db, key: id)
        }
        logger.info("Deleted known host \(id)")
    }

    func deleteAll() async throws {
        let writer = try await DatabaseManager.shared.writer
        _ = try await DataSnapshot.write(writer) { db in
            try KnownHost.deleteAll(db)
        }
        logger.info("Deleted all known hosts")
    }

    enum VerifyResult: Sendable {
        case trusted
        case unknown
        case changed(oldFingerprint: String)
    }
}
