import GRDB
import Foundation

struct ConnectionLog: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "connection_logs"

    var id: Int64?
    var hostId: Int64?
    var hostLabel: String
    var hostname: String
    var status: String
    var errorMessage: String?
    var durationMs: Int?
    var connectedAt: String
    var disconnectedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case hostId = "host_id"
        case hostLabel = "host_label"
        case hostname, status
        case errorMessage = "error_message"
        case durationMs = "duration_ms"
        case connectedAt = "connected_at"
        case disconnectedAt = "disconnected_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
