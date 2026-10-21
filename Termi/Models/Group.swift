import GRDB
import Foundation

struct HostGroup: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "groups"

    var id: Int64?
    var name: String
    var sortOrder: Int
    var createdAt: String
    /// Defaults inherited by member hosts that don't set their own (Termius-style group settings).
    var username: String? = nil
    var identityId: Int64? = nil
    var jumpHostId: Int64? = nil

    enum CodingKeys: String, CodingKey {
        case id, name
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case username
        case identityId = "identity_id"
        case jumpHostId = "jump_host_id"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
