import GRDB
import Foundation

struct PortForward: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "port_forwards"

    var id: Int64?
    var hostId: Int64
    var type: String
    var localPort: Int
    var remoteHost: String
    var remotePort: Int
    var enabled: Bool
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case hostId = "host_id"
        case type
        case localPort = "local_port"
        case remoteHost = "remote_host"
        case remotePort = "remote_port"
        case enabled
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
