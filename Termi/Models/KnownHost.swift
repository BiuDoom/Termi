import GRDB
import Foundation

struct KnownHost: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "known_hosts"

    var id: Int64?
    var hostname: String
    var port: Int
    var keyType: String
    var publicKey: String
    var fingerprint: String
    var addedAt: String

    enum CodingKeys: String, CodingKey {
        case id, hostname, port
        case keyType = "key_type"
        case publicKey = "public_key"
        case fingerprint
        case addedAt = "added_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
