import Foundation
import Observation
import os.log

/// The running rule keeps the exact parameters and connection that started it.
@MainActor
@Observable
final class PortForwardManager {
    static let shared = PortForwardManager()

    enum Status: Equatable {
        case starting
        case active
        case failed(String)
        case stopFailed(String)
    }

    private(set) var statuses: [Int64: Status] = [:]
    private struct Running {
        let rule: PortForward
        let master: SSHMasterConnection
        let lease: SSHConnectionManager.Lease?
    }
    @ObservationIgnored private var running: [Int64: Running] = [:]
    @ObservationIgnored private var starts: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var startTokens: [Int64: UUID] = [:]
    @ObservationIgnored private var stops: [Int64: Task<Void, Error>] = [:]
    @ObservationIgnored private var ruleRevisions: [Int64: UUID] = [:]
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var mutations: [UUID: Int64] = [:]
    private struct AutoStartPermit {
        let revision: UUID?
        let epoch: UUID
    }

    func status(of rule: PortForward) -> Status? { rule.id.flatMap { statuses[$0] } }

    func isRunning(_ rule: PortForward) -> Bool {
        switch status(of: rule) {
        case .active, .starting, .stopFailed: return true
        default: return false
        }
    }

    func start(_ rule: PortForward) async { await start(rule, on: nil) }

    private func start(_ rule: PortForward, on master: SSHMasterConnection?, permit: AutoStartPermit? = nil) async {
        guard !DataReplacementCoordinator.shared.isReplacing else { return }
        guard let id = rule.id, starts[id] == nil, stops[id] == nil, running[id] == nil else { return }
        guard !mutations.values.contains(id), (try? DataSnapshot.check(DataSnapshot.expected)) != nil else { return }
        if let permit {
            guard permit.epoch == epoch, permit.revision == ruleRevisions[id], master?.isAlive == true else { return }
        }
        let token = UUID()
        startTokens[id] = token
        statuses[id] = .starting
        let task = Task { await self.performStart(rule, on: master, token: token) }
        starts[id] = task
        await task.value
        starts[id] = nil
    }

    private func performStart(_ rule: PortForward, on existing: SSHMasterConnection?, token: UUID) async {
        guard let id = rule.id else { return }
        var lease: SSHConnectionManager.Lease?
        do {
            let master: SSHMasterConnection
            if let existing { master = existing }
            else {
                guard let host = try await HostRepository.shared.fetch(id: rule.hostId) else {
                    throw SSHError.invalidConfiguration(String(localized: "This host no longer exists."))
                }
                let acquired = try await SSHService.shared.connect(to: host)
                lease = acquired
                master = acquired.master
            }
            guard startTokens[id] == token, !Task.isCancelled else { lease?.release(); return }
            running[id] = Running(rule: rule, master: master, lease: lease)
            master.onClose { [weak self, weak master] in
                Task { @MainActor in
                    guard let self, let master, self.running[id]?.master === master else { return }
                    self.running.removeValue(forKey: id)?.lease?.release()
                    self.statuses[id] = nil
                }
            }
            try await master.addForward(rule.sshForward)
            // stop waits for this task, then cancels the snapshot even if the add completed late.
            guard startTokens[id] == token else { return }
            statuses[id] = .active
        } catch {
            // A failed add never installed this route, even if stop invalidated its token.
            running.removeValue(forKey: id)?.lease?.release()
            lease?.release()
            guard startTokens[id] == token else { return }
            statuses[id] = .failed(error.localizedDescription)
        }
    }

    /// The UI can retry a failed stop; mutations use the throwing form to retain the record.
    func stop(_ rule: PortForward) async { try? await stopForMutation(rule) }

    func stopForMutation(_ rule: PortForward) async throws {
        try DataSnapshot.check(DataSnapshot.expected)
        guard let id = rule.id else { return }
        invalidateAutoStart(id: id)
        if let stopping = stops[id] { try await stopping.value; return }
        startTokens[id] = nil
        let starting = starts[id]
        // Once submitted, await the add's definite result before deciding whether to cancel
        // a route. Killing the control process can leave installation ambiguous.
        if running[id] == nil { starting?.cancel() }
        let task = Task {
            await starting?.value
            if let active = self.running[id] {
                do {
                    if active.master.isAlive { try await active.master.cancelForward(active.rule.sshForward) }
                } catch {
                    if active.master.isAlive {
                        self.statuses[id] = .stopFailed(error.localizedDescription)
                        throw error
                    }
                }
                self.running.removeValue(forKey: id)?.lease?.release()
            }
            self.statuses[id] = nil
        }
        stops[id] = task
        defer { stops[id] = nil }
        try await task.value
    }

    /// Editing a running route stops the old route; the new route starts only on explicit request.
    func prepareToSave(_ rule: PortForward) async throws {
        try DataSnapshot.check(DataSnapshot.expected)
        guard let id = rule.id else { return }
        invalidateAutoStart(id: id)
        if let active = running[id], active.rule.hostId == rule.hostId,
           active.rule.sshForward == rule.sshForward { return }
        if running[id] != nil || starts[id] != nil { try await stopForMutation(rule) }
        else { statuses[id] = nil }
    }

    func toggle(_ rule: PortForward) async {
        if isRunning(rule) { await stop(rule) } else { await start(rule) }
    }

    func applyAutoForwards(for host: Host, on master: SSHMasterConnection) async {
        let revisions = ruleRevisions
        let requestEpoch = epoch
        guard let hostId = host.id,
              let rules = try? await PortForwardRepository.shared.fetchForHost(hostId) else { return }
        for rule in rules where rule.enabled {
            if let id = rule.id, let old = running[id], !old.master.isAlive {
                running.removeValue(forKey: id)?.lease?.release()
            }
            await start(rule, on: master, permit: AutoStartPermit(revision: rule.id.flatMap { revisions[$0] }, epoch: requestEpoch))
        }
    }

    /// Invalidates rules already fetched by a pending auto-start loop, including not-yet-started ones.
    func invalidateAutoStart(id: Int64) { ruleRevisions[id] = UUID() }

    /// Hold across the database write as well, so auto-start cannot read the old row between
    /// cancelling its route and committing the edit. Tokens survive nested/cancelled callers.
    func beginMutation(id: Int64?) throws -> UUID? {
        try DataSnapshot.check(DataSnapshot.expected)
        guard let id else { return nil }
        let token = UUID()
        mutations[token] = id
        invalidateAutoStart(id: id)
        return token
    }

    func endMutation(_ token: UUID?) {
        guard let token, let id = mutations.removeValue(forKey: token) else { return }
        invalidateAutoStart(id: id)
    }

    /// Data replacement ends every connection; prevent callbacks from resurrecting old rule ids.
    func reset() async {
        epoch = UUID()
        ruleRevisions.removeAll()
        mutations.removeAll()
        let pending = Array(starts.values)
        startTokens.removeAll()
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
        for task in Array(stops.values) { try? await task.value }
        stops.removeAll()
        for active in running.values { active.master.close(); active.lease?.release() }
        running.removeAll()
        starts.removeAll()
        statuses.removeAll()
    }
}

extension PortForward {
    var sshForward: SSHForward {
        let kind: SSHForward.Kind = switch type {
        case "remote": .remote
        case "dynamic": .dynamic
        default: .local
        }
        return SSHForward(kind: kind, bindPort: localPort, destinationHost: remoteHost, destinationPort: remotePort)
    }
}
