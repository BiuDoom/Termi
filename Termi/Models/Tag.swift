import GRDB
import Foundation

struct Tag: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tags"

    var id: Int64?
    var name: String
    var color: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct HostTag: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "host_tags"

    var hostId: Int64
    var tagId: Int64

    enum CodingKeys: String, CodingKey {
        case hostId = "host_id"
        case tagId = "tag_id"
    }
}
