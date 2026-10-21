import GRDB
import Foundation

struct Identity: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "identities"

    var id: Int64?
    var name: String
    var username: String
    var authType: String
    var passwordEncrypted: String?
    var privateKeyId: Int64?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, username
        case authType = "auth_type"
        case passwordEncrypted = "password_encrypted"
        case privateKeyId = "private_key_id"
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
