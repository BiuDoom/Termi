import AppKit
import Network

/// Tells interested parties when connectivity comes back (network change or wake from sleep),
/// so dropped SSH sessions can reconnect immediately instead of waiting for their backoff timer.
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private var handlers: [UUID: @MainActor () -> Void] = [:]
    private var started = false
    private var wakeObserver: NSObjectProtocol?

    func start() {
        guard !started else { return }
        started = true
        // @Sendable: NWPathMonitor calls this on its own queue. Without it the closure would
        // inherit this class's MainActor isolation and Swift 6's runtime check would trap.
        monitor.pathUpdateHandler = { @Sendable path in
            let online = path.status == .satisfied
            Task { @MainActor in
                NetworkMonitor.shared.update(online: online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.termi.Termi.network"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // Give Wi-Fi a moment to re-associate.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                NetworkMonitor.shared.notify()
            }
        }
    }

    /// Register a handler for "connectivity is back". Returns a token for `remove`.
    @discardableResult
    func onConnectivityRestored(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func remove(_ id: UUID) {
        handlers[id] = nil
    }

    private func update(online: Bool) {
        let cameBack = online && !isOnline
        isOnline = online
        if cameBack {
            notify()
        }
    }

    private func notify() {
        for handler in handlers.values {
            handler()
        }
    }
}
