import Foundation

/// Shares one authenticated master connection per host between everything that talks to it
/// (terminal tabs, split panes, SFTP, port forwards, monitoring…), Termius-style.
///
/// - Concurrent requests for the same host wait for a single connection attempt.
/// - Each user holds a `Lease`; when the last lease is released the master is closed after
///   a short grace period (so reconnecting / duplicating a tab doesn't re-authenticate).
/// - Editing a host changes its spec fingerprint, so new sessions get a fresh master.
actor SSHConnectionManager {
    /// Keeps a master connection alive while held. Call `release()` when done
    /// (it is also released automatically when the lease is deallocated).
    final class Lease: @unchecked Sendable {
        let master: SSHMasterConnection
        let key: String
        private let entryKey: String
        private let manager: SSHConnectionManager
        private let lock = NSLock()
        private var released = false

        fileprivate init(master: SSHMasterConnection, key: String, entryKey: String, manager: SSHConnectionManager) {
            self.master = master
            self.key = key
            self.entryKey = entryKey
            self.manager = manager
        }

        func release() {
            let first: Bool = lock.withLock {
                defer { released = true }
                return !released
            }
            guard first else { return }
            let manager = self.manager
            let entryKey = self.entryKey
            let master = self.master
            Task { await manager.releaseLease(entryKey: entryKey, master: master) }
        }

        deinit {
            release()
        }
    }

    private struct Entry {
        var key: String
        var master: SSHMasterConnection?
        let generation = UUID()
        var connecting: Task<Void, Never>?
        var leases = 0
        var waiters: Set<UUID> = []
        var continuations: [UUID: CheckedContinuation<SSHMasterConnection, Error>] = [:]
        var idleClose: Task<Void, Never>?
    }

    let runtime: SSHRuntime
    private var entries: [String: Entry] = [:]
    private let idleTimeout: UInt64

    init(runtime: SSHRuntime, idleTimeoutSeconds: Double = 20) {
        self.runtime = runtime
        self.idleTimeout = UInt64(idleTimeoutSeconds * 1_000_000_000)
    }

    /// Get (or open) the master connection for `key` (e.g. "host-42").
    func acquire(key: String, spec: SSHConnectionSpec,
                 callbacks: SSHMasterConnection.Callbacks) async throws -> Lease {
        try Task.checkCancellation()
        let entryKey = key + "#" + spec.fingerprint

        if let master = entries[entryKey]?.master {
            if master.isAlive {
                entries[entryKey]?.leases += 1
                entries[entryKey]?.idleClose?.cancel()
                entries[entryKey]?.idleClose = nil
                return Lease(master: master, key: key, entryKey: entryKey, manager: self)
            }
            entries[entryKey] = nil
        }

        if entries[entryKey] == nil {
            entries[entryKey] = Entry(key: key)
            let generation = entries[entryKey]!.generation
            let runtime = self.runtime
            entries[entryKey]?.connecting = Task {
                let result: Result<SSHMasterConnection, Error>
                do {
                    try Task.checkCancellation()
                    let master = try SSHMasterConnection(spec: spec, runtime: runtime, callbacks: callbacks)
                    try await master.connect()
                    result = .success(master)
                } catch {
                    result = .failure(error)
                }
                self.connectionFinished(entryKey: entryKey, generation: generation, result: result)
            }
        }
        let generation = entries[entryKey]!.generation
        let waiter = UUID()
        entries[entryKey]?.waiters.insert(waiter)
        let master: SSHMasterConnection
        do {
            master = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    entries[entryKey]?.continuations[waiter] = continuation
                }
            } onCancel: {
                Task { await self.waiterCancelled(entryKey: entryKey, generation: generation, waiter: waiter) }
            }
        } catch {
            removeWaiter(entryKey: entryKey, generation: generation, waiter: waiter)
            throw error
        }

        guard entries[entryKey]?.generation == generation, entries[entryKey]?.master === master else {
            throw CancellationError()
        }
        entries[entryKey]?.waiters.remove(waiter)
        if Task.isCancelled {
            scheduleIdleCloseIfUnused(entryKey)
            throw CancellationError()
        }
        entries[entryKey]?.leases += 1
        entries[entryKey]?.idleClose?.cancel()
        entries[entryKey]?.idleClose = nil
        return Lease(master: master, key: key, entryKey: entryKey, manager: self)
    }

    private func connectionFinished(entryKey: String, generation: UUID,
                                    result: Result<SSHMasterConnection, Error>) {
        guard entries[entryKey]?.generation == generation else {
            if case .success(let master) = result { master.close() }
            return
        }
        let continuations = entries[entryKey]!.continuations.values
        entries[entryKey]?.continuations = [:]
        entries[entryKey]?.connecting = nil
        switch result {
        case .success(let master):
            entries[entryKey]?.master = master
            master.onClose { [weak self] in
                Task { await self?.masterClosed(entryKey: entryKey) }
            }
            for continuation in continuations { continuation.resume(returning: master) }
            scheduleIdleCloseIfUnused(entryKey)
        case .failure(let error):
            entries[entryKey] = nil
            for continuation in continuations { continuation.resume(throwing: error) }
        }
    }

    /// Whether a live master exists for `key`.
    func isConnected(key: String) -> Bool {
        entries.values.contains { $0.key == key && $0.master?.isAlive == true }
    }

    /// Keys (e.g. "host-42") with a live master connection.
    func connectedKeys() -> Set<String> {
        Set(entries.values.filter { $0.master?.isAlive == true }.map(\.key))
    }

    /// Close every master for `key` immediately — all its sessions end.
    func disconnect(key: String) {
        for (entryKey, entry) in entries where entry.key == key {
            entry.idleClose?.cancel()
            entry.connecting?.cancel()
            entry.master?.close()
            for continuation in entry.continuations.values { continuation.resume(throwing: CancellationError()) }
            entries[entryKey] = nil
        }
    }

    /// Close everything (app termination / vault lock).
    func shutdown() {
        for entry in entries.values {
            entry.idleClose?.cancel()
            entry.connecting?.cancel()
            entry.master?.close()
            for continuation in entry.continuations.values { continuation.resume(throwing: CancellationError()) }
        }
        entries.removeAll()
    }

    // MARK: - Internals

    fileprivate func releaseLease(entryKey: String, master: SSHMasterConnection) {
        // A lease on a master that has since been replaced (reconnect under the same key)
        // must not be counted against the new one.
        guard entries[entryKey]?.master === master else { return }
        entries[entryKey]?.leases -= 1
        scheduleIdleCloseIfUnused(entryKey)
    }

    private func scheduleIdleCloseIfUnused(_ entryKey: String) {
        guard let entry = entries[entryKey], entry.leases <= 0, entry.waiters.isEmpty,
              entry.master != nil, entry.idleClose == nil else { return }
        let timeout = idleTimeout
        entries[entryKey]?.idleClose = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            await self?.closeIfIdle(entryKey)
        }
    }

    private func closeIfIdle(_ entryKey: String) {
        guard let entry = entries[entryKey], entry.leases <= 0, entry.waiters.isEmpty else { return }
        entry.master?.close()
        entries[entryKey] = nil
    }

    private func waiterCancelled(entryKey: String, generation: UUID, waiter: UUID) {
        guard entries[entryKey]?.generation == generation else { return }
        let continuation = entries[entryKey]?.continuations.removeValue(forKey: waiter)
        removeWaiter(entryKey: entryKey, generation: generation, waiter: waiter)
        continuation?.resume(throwing: CancellationError())
    }

    private func removeWaiter(entryKey: String, generation: UUID, waiter: UUID) {
        guard entries[entryKey]?.generation == generation else { return }
        entries[entryKey]?.waiters.remove(waiter)
        guard let entry = entries[entryKey], entry.waiters.isEmpty, entry.leases <= 0 else { return }
        if let task = entry.connecting {
            task.cancel()
            entries[entryKey] = nil
        } else {
            scheduleIdleCloseIfUnused(entryKey)
        }
    }

    private func masterClosed(entryKey: String) {
        // Only drop the entry if it still holds a dead master (a reconnect may have replaced it).
        guard let master = entries[entryKey]?.master, !master.isAlive else { return }
        entries[entryKey]?.idleClose?.cancel()
        entries[entryKey] = nil
    }
}
