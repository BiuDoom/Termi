import GRDB
import Foundation
import os.log

/// Repository for host tags (many-to-many via host_tags)
actor TagRepository {
    static let shared = TagRepository()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "TagRepo")

    func fetchAll() async throws -> [Tag] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try Tag.order(Column("name").collating(.localizedCaseInsensitiveCompare).asc).fetchAll(db)
        }
    }

    /// hostId → tags, for every host that has at least one tag.
    func tagsByHost() async throws -> [Int64: [Tag]] {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            let tags = try Tag.fetchAll(db)
            let byId = Dictionary(uniqueKeysWithValues: tags.compactMap { tag in tag.id.map { ($0, tag) } })
            var result: [Int64: [Tag]] = [:]
            for link in try HostTag.fetchAll(db) {
                if let tag = byId[link.tagId] {
                    result[link.hostId, default: []].append(tag)
                }
            }
            for key in result.keys {
                result[key]?.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            return result
        }
    }

    func tags(forHost hostId: Int64) async throws -> [Tag] {
        try await tagsByHost()[hostId] ?? []
    }

    /// Replace the host's tags with `names`, creating tags that don't exist yet.
    func setTags(_ names: [String], forHost hostId: Int64) async throws {
        let cleaned = Array(Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        let writer = try await DatabaseManager.shared.writer
        try await DataSnapshot.write(writer) { db in
            try HostTag.filter(Column("host_id") == hostId).deleteAll(db)
            for name in cleaned {
                var tag = try Tag.filter(Column("name") == name).fetchOne(db)
                if tag == nil {
                    let created = Tag(name: name, color: Self.color(for: name), createdAt: TimestampFormatter.now())
                    // insertAndFetch backfills the generated id (see HostRepository.save).
                    tag = try created.insertAndFetch(db)
                }
                if let tagId = tag?.id {
                    try HostTag(hostId: hostId, tagId: tagId).insert(db, onConflict: .ignore)
                }
            }
            // Drop tags no host uses anymore.
            try db.execute(sql: "DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM host_tags)")
        }
    }

    func copyTags(from sourceHostId: Int64, to targetHostId: Int64) async throws {
        let names = try await tags(forHost: sourceHostId).map(\.name)
        try await setTags(names, forHost: targetHostId)
    }

    /// Stable pleasant color per tag name.
    static func color(for name: String) -> String {
        let palette = ["#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899", "#06B6D4", "#84CC16"]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}
