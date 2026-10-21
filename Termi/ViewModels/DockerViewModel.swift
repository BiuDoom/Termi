import SwiftUI
import os.log

/// ViewModel for Docker container management
@Observable
@MainActor
final class DockerViewModel {
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "DockerVM")
    private let dockerService = DockerService()
    private let hostRepo = HostRepository.shared

    var hosts: [Host] = []
    var selectedHost: Host?
    var containers: [DockerService.Container] = []
    var isLoading = false
    var showAll = true
    var error: String?
    /// True once the selected host has answered with its containers (the host list then shows
    /// their count, and an empty list means "no containers", not "not read yet").
    private(set) var hasLoaded = false

    // Logs
    var showingLogs = false
    var logOutput = ""
    var logContainerId = ""
    var isLoadingLogs = false
    var logError: String?
    /// Counts the requests for logs: an answer that is not the latest one's is dropped.
    @ObservationIgnored private var logRequest = 0

    func loadHosts() async {
        do {
            hosts = try await hostRepo.fetchAll()
        } catch {
            // The page left while its hosts were read (the read is cancelled with it): nothing
            // failed, and the model would keep showing the error when the page comes back.
            guard !Task.isCancelled else { return }
            self.error = Self.message(for: error)
            return
        }
        refreshSelectedHost()
    }

    /// The model outlives the page: the selected host may have been edited or deleted on the
    /// Hosts page since it was picked. Commands go where the saved host points now, not to the
    /// copy taken back then.
    func refreshSelectedHost() {
        guard let selected = selectedHost else { return }
        guard let current = hosts.first(where: { $0.connectionKey == selected.connectionKey }) else {
            selectedHost = nil
            containers = []
            hasLoaded = false
            error = nil
            isLoading = false
            showingLogs = false
            return
        }
        if current.isSameTarget(as: selected) {
            // Also when only the detected system changed: the containers are still this host's.
            selectedHost = current
        } else {
            // Another address, user or credentials: what is listed is not this host's any more.
            error = nil
            selectHost(current)
        }
    }

    func loadContainers() async {
        guard let host = selectedHost else { return }
        isLoading = true
        error = nil

        do {
            let listed = try await dockerService.listContainers(host: host, showAll: showAll)
            // Another host was picked while this one answered: its containers belong nowhere.
            guard isSelected(host) else { return }
            containers = listed
            hasLoaded = true
        } catch {
            guard isSelected(host) else { return }
            self.error = Self.message(for: error)
            containers = []
            hasLoaded = false
        }

        isLoading = false
    }

    /// False once another host was picked — or this one deleted, or saved with other settings —
    /// while it answered.
    private func isSelected(_ host: Host) -> Bool {
        selectedHost?.isSameTarget(as: host) == true
    }

    func startContainer(_ id: String) async {
        guard let host = selectedHost else { return }
        do {
            try await dockerService.startContainer(host: host, containerId: id)
            await loadContainers()
        } catch {
            self.error = Self.message(for: error)
        }
    }

    func stopContainer(_ id: String) async {
        guard let host = selectedHost else { return }
        do {
            try await dockerService.stopContainer(host: host, containerId: id)
            await loadContainers()
        } catch {
            self.error = Self.message(for: error)
        }
    }

    func restartContainer(_ id: String) async {
        guard let host = selectedHost else { return }
        do {
            try await dockerService.restartContainer(host: host, containerId: id)
            await loadContainers()
        } catch {
            self.error = Self.message(for: error)
        }
    }

    func removeContainer(_ id: String) async {
        guard let host = selectedHost else { return }
        do {
            try await dockerService.removeContainer(host: host, containerId: id, force: true)
            await loadContainers()
        } catch {
            self.error = Self.message(for: error)
        }
    }

    /// Why a Docker command failed. A command that failed without writing to stderr (`docker
    /// logs` sends it to stdout with the logs) has no reason to show: a whole sentence, not
    /// "Docker error:" with nothing after the colon.
    nonisolated static func message(for error: any Error) -> String {
        if let reason = emptyReasonMessage(error) { return reason }
        return error.localizedDescription
    }

    private nonisolated static func emptyReasonMessage(_ error: any Error) -> String? {
        guard case DockerService.DockerError.commandFailed(let reason) = error,
              reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(localized: "The Docker command failed and the host gave no reason.")
    }

    func showLogs(for containerId: String) async {
        guard let host = selectedHost else { return }
        logRequest += 1
        let request = logRequest
        logContainerId = containerId
        logOutput = ""
        logError = nil
        isLoadingLogs = true
        showingLogs = true

        do {
            let output = try await dockerService.containerLogs(host: host, containerId: containerId)
            // The sheet was closed and logs were asked for again while the host answered: the
            // sheet is the later request's, and neither this answer nor its failure belongs there.
            guard request == logRequest else { return }
            logOutput = output
        } catch {
            guard request == logRequest else { return }
            logError = Self.message(for: error)
        }
        isLoadingLogs = false
    }

    func selectHost(_ host: Host) {
        selectedHost = host
        containers = []
        hasLoaded = false
        Task { await loadContainers() }
    }

    #if DEBUG
    /// `-debugDockerSample <label>`: that host as if it had answered with these containers,
    /// without contacting it (the test hosts run no Docker).
    func debugShowSample(on host: Host) {
        selectedHost = host
        containers = [
            ("4f1c2a9be0d3", "nginx", "nginx:1.27-alpine", "Up 3 days",
             "0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp, 0.0.0.0:8443->8443/tcp"),
            ("9a7b61c2f004", "api", "ghcr.io/acme/api:2.4.1", "Up 3 days", "127.0.0.1:8080->8080/tcp"),
            ("c31d0e5a77b2", "redis", "redis:7.4-alpine", "Up 3 days", "6379/tcp"),
            ("0be4d2a19c6f", "migrate", "ghcr.io/acme/api:2.4.1", "Exited (0) 3 days ago", ""),
            ("e7f802b3d415", "certbot", "certbot/certbot:v2.11.0", "Exited (0) 12 hours ago", "")
        ].map { DockerService.Container(id: $0.0, name: $0.1, image: $0.2, status: $0.3, ports: $0.4, created: "") }
        hasLoaded = true
        isLoading = false
        error = nil
    }
    #endif
}

// MARK: - What the page shows of a container

extension DockerService.Container {
    /// Created, exited or dead: not running and not on its way.
    enum Phase: Equatable, Sendable {
        case running, transitional, stopped
    }

    /// Paused and restarting containers are neither up nor down.
    var phase: Phase {
        let value = status.lowercased()
        if value.contains("paused") || value.contains("restarting") { return .transitional }
        return isRunning ? .running : .stopped
    }

    /// The published ports as short labels, duplicates removed, in the order Docker lists them:
    /// "0.0.0.0:80->80/tcp, [::]:80->80/tcp" → ["80→80"]; "127.0.0.1:8080->8080/tcp" keeps its
    /// address (it says the port is not public); "6379/tcp" → ["6379"].
    var portLabels: [String] {
        Self.portLabels(from: ports)
    }

    static func portLabels(from ports: String) -> [String] {
        var labels: [String] = []
        for raw in ports.split(separator: ",") {
            var entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            for suffix in ["/tcp", "/udp", "/sctp"] where entry.hasSuffix(suffix) {
                // UDP and SCTP stay named: TCP is what a port is unless it says otherwise.
                entry = String(entry.dropLast(suffix.count)) + (suffix == "/tcp" ? "" : suffix)
            }
            for wildcard in ["0.0.0.0:", "[::]:", ":::"] where entry.hasPrefix(wildcard) {
                entry = String(entry.dropFirst(wildcard.count))
                break
            }
            entry = entry.replacingOccurrences(of: "->", with: "→")
            if !labels.contains(entry) { labels.append(entry) }
        }
        return labels
    }
}

/// What a list of containers adds up to (the three cards above the table).
struct DockerSummary: Equatable {
    let running: [String]
    let stopped: [String]
    let total: Int
    let images: Int

    init(_ containers: [DockerService.Container]) {
        running = containers.filter { $0.phase != .stopped }.map(\.name)
        stopped = containers.filter { $0.phase == .stopped }.map(\.name)
        total = containers.count
        images = Set(containers.map(\.image)).count
    }

    /// "3 running · 2 stopped · 4 images" under the host's name. With "Running" chosen the
    /// host was not asked for the others: the stopped ones are unknown, not zero, and left out.
    func headline(includesStopped: Bool) -> String {
        var parts = [String(localized: "\(running.count) containers running")]
        if includesStopped { parts.append(String(localized: "\(stopped.count) containers stopped")) }
        parts.append(String(localized: "\(images) images"))
        return parts.joined(separator: " · ")
    }

    /// "nginx · api · redis", and "+2" for those that would not fit on the line.
    static func names(_ names: [String], limit: Int = 3) -> String? {
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(limit).joined(separator: " · ")
        return names.count > limit ? "\(shown) +\(names.count - limit)" : shown
    }
}
