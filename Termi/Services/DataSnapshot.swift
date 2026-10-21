import Foundation
import GRDB
import Observation

/// A form or asynchronous write belongs to the data snapshot from which it was opened.
/// Check on the database queue too: an actor hop can outlive an import's UI invalidation.
enum DataSnapshot {
    private final class Version: @unchecked Sendable {
        let lock = NSLock()
        var value = UUID()
    }
    private static let version = Version()
    @TaskLocal static var expected: UUID?
    static var current: UUID { version.lock.withLock { version.value } }

    static func invalidate() { version.lock.withLock { version.value = UUID() } }

    static func check(_ generation: UUID?) throws {
        if let generation, generation != current { throw StaleSnapshot() }
    }

    static func write<T: Sendable>(_ writer: any DatabaseWriter,
                                   _ updates: @escaping @Sendable (Database) throws -> T) async throws -> T {
        let generation = expected ?? current
        return try await writer.write { db in
            try check(generation)
            return try updates(db)
        }
    }

    struct StaleSnapshot: LocalizedError {
        var errorDescription: String? {
            String(localized: "The data was replaced. Reopen this item before making changes.")
        }
    }
}

/// Invalidates every window before the import writes, not after a stale confirmation can act.
@MainActor
final class DataReplacementCoordinator {
    static let shared = DataReplacementCoordinator()
    private final class Window {
        weak var model: AppViewModel?
        init(_ model: AppViewModel) { self.model = model }
    }
    private var windows: [Window] = []
    private(set) var isReplacing = false

    func register(_ model: AppViewModel) {
        windows.removeAll { $0.model == nil }
        windows.append(Window(model))
        if isReplacing { model.prepareForDataReplacement() }
    }

    func begin() async throws {
        try DataSnapshot.check(DataSnapshot.expected)
        guard !isReplacing else { throw DataSnapshot.StaleSnapshot() }
        isReplacing = true
        DataSnapshot.invalidate()
        for window in windows { window.model?.prepareForDataReplacement() }
        await SSHService.shared.shutdown()
        await PortForwardManager.shared.reset()
    }

    func finish() async {
        // A new window can register while another window awaits its database reload.
        var finished = Set<ObjectIdentifier>()
        while let model = windows.compactMap(\.model).first(where: {
            !finished.contains(ObjectIdentifier($0))
        }) {
            finished.insert(ObjectIdentifier(model))
            await model.finishDataReplacement()
        }
        isReplacing = false
        NotificationCenter.default.post(name: .dsDataChanged, object: nil)
        NotificationCenter.default.post(name: .terminalPreferencesChanged, object: nil)
    }
}
