import GRDB
import Foundation

struct SSHKey: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ssh_keys"

    var id: Int64?
    var name: String
    var type: String
    var publicKey: String
    var privateKeyEncrypted: String
    var passphraseEncrypted: String?
    var fingerprint: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case publicKey = "public_key"
        case privateKeyEncrypted = "private_key_encrypted"
        case passphraseEncrypted = "passphrase_encrypted"
        case fingerprint
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
