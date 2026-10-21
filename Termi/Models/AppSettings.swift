import GRDB
import Foundation

struct AppSetting: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "settings"

    var key: String
    var value: String

    /// Tell GRDB that "key" is the primary key for upsert via save()
    static let persistenceConflictPolicy = PersistenceConflictPolicy(
        insert: .replace,
        update: .replace
    )

    enum CodingKeys: String, CodingKey {
        case key, value
    }
}

struct VaultEntry: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "vault"

    var id: Int64?
    var key: String
    var valueEncrypted: String
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, key
        case valueEncrypted = "value_encrypted"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Notification Setting Keys

extension AppSetting {
    static let notificationsEnabled = "notifications_enabled"
    static let notificationsSSH = "notifications_ssh"
    static let notificationsSFTP = "notifications_sftp"
    static let notificationsBatch = "notifications_batch"
}

struct CryptoConfig: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "crypto_config"

    var key: String
    var value: String
}
