import GRDB
import Foundation
import os.log

/// Repository for Snippet CRUD operations
actor SnippetRepository {
    static let shared = SnippetRepository()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "SnippetRepo")

    func fetchAll() async throws -> [Snippet] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try Snippet.order(Column("sort_order").asc, Column("name").asc).fetchAll(db)
        }
    }

    func fetch(id: Int64) async throws -> Snippet? {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try Snippet.fetchOne(db, key: id)
        }
    }

    func fetchByCategory(_ category: String) async throws -> [Snippet] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try Snippet
                .filter(Column("category") == category)
                .order(Column("sort_order").asc)
                .fetchAll(db)
        }
    }

    func search(_ query: String) async throws -> [Snippet] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            // Escape LIKE wildcards in user input to prevent injection.
            // "%" and "_" are LIKE metacharacters; "\" is the escape character.
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            return try Snippet
                .filter(
                    Column("name").like(pattern, escape: "\\") ||
                    Column("command").like(pattern, escape: "\\") ||
                    Column("description").like(pattern, escape: "\\")
                )
                .order(Column("name").asc)
                .fetchAll(db)
        }
    }

    func categories() async throws -> [String] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT category FROM snippets
                WHERE category IS NOT NULL AND category != ''
                ORDER BY category
            """)
            return rows.compactMap { $0["category"] as? String }
        }
    }

    @discardableResult
    func save(_ snippet: Snippet) async throws -> Snippet {
        let writer = try await DatabaseManager.shared.writer
        return try await DataSnapshot.write(writer) { db in
            var s = snippet
            if s.id == nil {
                s.createdAt = TimestampFormatter.now()
                // insertAndFetch backfills the generated id (a plain save() does not for these records)
                return try s.insertAndFetch(db)
            }
            try s.save(db)
            return s
        }
    }

    func delete(id: Int64) async throws {
        let writer = try await DatabaseManager.shared.writer
        _ = try await DataSnapshot.write(writer) { db in
            try Snippet.deleteOne(db, key: id)
        }
        logger.info("Deleted snippet \(id)")
    }
}
