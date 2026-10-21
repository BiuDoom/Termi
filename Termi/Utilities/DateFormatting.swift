import Foundation

enum TimestampFormatter {
    /// Returns the current date as an ISO 8601 string.
    /// Creates a new formatter per call — ISO8601DateFormatter is not thread-safe,
    /// and TimestampFormatter.now() is called from actors/background threads.
    static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// Parses an ISO 8601 string into a Date. Creates a new formatter per call for thread safety.
    static func date(from isoString: String) -> Date? {
        ISO8601DateFormatter().date(from: isoString)
    }

    /// Formats a Date as an ISO 8601 string. Creates a new formatter per call for thread safety.
    static func string(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// Display formatters are only used in SwiftUI views on the MainActor.
/// Marking the container @MainActor makes shared static DateFormatter instances safe —
/// DateFormatter is not thread-safe and must not be accessed concurrently.
@MainActor
enum DisplayDateFormatter {
    static let mediumDateShortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let shortDateMediumTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    static let backupFilename: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static let fileListTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd HH:mm"
        return formatter
    }()
}
