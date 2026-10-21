import SwiftUI
import os.log

/// ViewModel for port forward CRUD operations
@Observable
@MainActor
final class PortForwardViewModel {
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "PortFwdVM")
    private let repo = PortForwardRepository.shared
    private let dataGeneration: UUID

    init(dataGeneration: UUID = DataSnapshot.current) {
        self.dataGeneration = dataGeneration
    }

    var portForwards: [PortForward] = []
    var isLoading = false
    /// True once the first `loadAll()` is over (the page draws nothing before that).
    private(set) var hasLoaded = false
    var error: String?

    // MARK: - Load

    func loadForHost(_ hostId: Int64) async {
        isLoading = true
        defer { isLoading = false }
        do {
            portForwards = try await repo.fetchForHost(hostId)
            error = nil
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to load port forwards: \(error)")
        }
    }

    func loadAll() async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            let fetched = try await repo.fetchAll()
            // The first fill just appears; later changes (a rule added) animate.
            if hasLoaded { withAnimation(DS.Motion.standard) { portForwards = fetched } } else { portForwards = fetched }
            error = nil
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to load all port forwards: \(error)")
        }
    }

    // MARK: - CRUD

    func save(_ portForward: PortForward) async {
        do {
            try await DataSnapshot.$expected.withValue(dataGeneration) {
                try DataSnapshot.check(dataGeneration)
                let mutation = try PortForwardManager.shared.beginMutation(id: portForward.id)
                defer { PortForwardManager.shared.endMutation(mutation) }
                try await PortForwardManager.shared.prepareToSave(portForward)
                try await repo.save(portForward)
            }
            // The page lists every host's rules: reloading only this host would drop the others.
            await loadAll()
            NotificationCenter.default.post(name: .dsDataChanged, object: nil)
            logger.info("Port forward saved: \(portForward.type) :\(portForward.localPort)")
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to save port forward: \(error)")
        }
    }

    func delete(id: Int64) async {
        do {
            try await DataSnapshot.$expected.withValue(dataGeneration) {
                try DataSnapshot.check(dataGeneration)
                let mutation = try PortForwardManager.shared.beginMutation(id: id)
                defer { PortForwardManager.shared.endMutation(mutation) }
                if let rule = portForwards.first(where: { $0.id == id }) {
                    try await PortForwardManager.shared.stopForMutation(rule)
                }
                try await repo.delete(id: id)
            }
            withAnimation(DS.Motion.standard) { portForwards.removeAll { $0.id == id } }
            NotificationCenter.default.post(name: .dsDataChanged, object: nil)
            logger.info("Port forward deleted: \(id)")
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to delete port forward: \(error)")
        }
    }

    func toggleEnabled(id: Int64, enabled: Bool) async {
        do {
            try await DataSnapshot.$expected.withValue(dataGeneration) {
                try DataSnapshot.check(dataGeneration)
                let mutation = try PortForwardManager.shared.beginMutation(id: id)
                defer { PortForwardManager.shared.endMutation(mutation) }
                try await repo.toggleEnabled(id: id, enabled: enabled)
            }
            if let idx = portForwards.firstIndex(where: { $0.id == id }) {
                portForwards[idx].enabled = enabled
            }
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to toggle port forward: \(error)")
        }
    }

    // MARK: - Live state

    /// The rule's live state on the shared connections (nil = stopped).
    func status(of rule: PortForward) -> PortForwardManager.Status? {
        #if DEBUG
        if let sample = debugStatuses[rule.id ?? -1] { return sample }
        #endif
        return PortForwardManager.shared.status(of: rule)
    }

    func isRunning(_ rule: PortForward) -> Bool {
        switch status(of: rule) {
        case .active, .starting, .stopFailed: return true
        default: return false
        }
    }

    /// Rules whose last start failed: the one number the page says outside the rows.
    var failedCount: Int {
        Self.failedCount(in: portForwards.map { status(of: $0) })
    }

    #if DEBUG
    /// `-debugPortForwards running|empty`: sample states for screenshots (the rules of the test data
    /// belong to a host that asks for a password). Nothing is started.
    private(set) var debugStatuses: [Int64: PortForwardManager.Status] = [:]

    func applyDebugSample() {
        let mode = AppProfile.arguments.string(forKey: "debugPortForwards")
        // `-debugPortForwards empty`: the page without rules (nothing is deleted).
        if mode == "empty" { portForwards = [] }
        guard mode == "running" else { return }
        let ids = portForwards.compactMap(\.id)
        if let first = ids.first { debugStatuses[first] = .active }
        if ids.count > 1 {
            debugStatuses[ids[1]] = .failed("bind [127.0.0.1]:\(portForwards[1].localPort): Address already in use")
        }
    }
    #endif
}

// MARK: - Counts, addresses

extension PortForwardViewModel {
    nonisolated static func failedCount(in statuses: [PortForwardManager.Status?]) -> Int {
        statuses.filter { status in
            if case .failed = status { return true }
            if case .stopFailed = status { return true }
            return false
        }.count
    }

    /// The host a new rule is for when there is nothing to choose: the only one there is.
    nonisolated static func onlyHostId(in hosts: [Host]) -> Int64? {
        hosts.count == 1 ? hosts.first?.id : nil
    }

    /// Where the tunnel listens on this Mac; a remote forward listens on the host instead.
    nonisolated static func localAddress(of rule: PortForward) -> String? {
        rule.type == "remote" ? nil : "localhost:\(rule.localPort)"
    }

    /// The rule in words, the way its row draws it: where it listens → where it ends.
    nonisolated static func routeText(of rule: PortForward, hostLabel: String) -> String {
        let target = rule.remoteHost.contains(":") ? "[\(rule.remoteHost)]:\(rule.remotePort)"
            : "\(rule.remoteHost):\(rule.remotePort)"
        switch rule.type {
        case "remote": return "\(hostLabel):\(rule.localPort) → \(target)"
        case "dynamic": return "localhost:\(rule.localPort) → \(String(localized: "Any destination"))"
        default: return "localhost:\(rule.localPort) → \(target)"
        }
    }

    /// The same tunnel as an `ssh` command line, for the clipboard (never run by the app).
    nonisolated static func sshCommand(for rule: PortForward, host: Host) -> String {
        var parts = ["ssh"] + rule.sshForward.arguments
        parts.append(host.username.isEmpty ? host.hostname : "\(host.username)@\(host.hostname)")
        if host.port != 22 { parts += ["-p", String(host.port)] }
        return parts.joined(separator: " ")
    }
}
