import GRDB
import Foundation

struct Snippet: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "snippets"

    var id: Int64?
    var name: String
    var command: String
    var description: String?
    var category: String?
    var sortOrder: Int
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, command, description, category
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
