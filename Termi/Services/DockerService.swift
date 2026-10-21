import Foundation
import os.log

/// Docker container management via remote SSH
actor DockerService {
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "Docker")
    private let sshService = SSHService.shared

    /// Validates a Docker container ID/name to prevent command injection.
    /// Accepts hex IDs and container names (alphanumeric, dashes, underscores, dots, slashes).
    nonisolated(unsafe) private static let validContainerIdPattern = /^[a-zA-Z0-9][a-zA-Z0-9_.\-\/]*$/

    private func validated(_ containerId: String) throws -> String {
        guard containerId.wholeMatch(of: Self.validContainerIdPattern) != nil else {
            throw DockerError.invalidContainerId(containerId)
        }
        return containerId
    }

    struct Container: Identifiable, Sendable {
        let id: String
        let name: String
        let image: String
        let status: String
        let ports: String
        let created: String

        var isRunning: Bool {
            status.lowercased().contains("up")
        }

        var stateIcon: String {
            if isRunning { return "play.circle.fill" }
            if status.lowercased().contains("exited") { return "stop.circle.fill" }
            return "pause.circle.fill"
        }
    }

    /// List all containers
    func listContainers(host: Host, showAll: Bool = true) async throws -> [Container] {
        let output = try await executeSSH(
            host: host,
            command: showAll
                ? "docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}|{{.CreatedAt}}'"
                : "docker ps --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}|{{.CreatedAt}}'"
        )

        return output
            .split(separator: "\n")
            .map(String.init)
            .compactMap { line -> Container? in
                let parts = line.components(separatedBy: "|")
                guard parts.count >= 4 else { return nil }
                return Container(
                    id: parts[0],
                    name: parts[safe: 1] ?? "",
                    image: parts[safe: 2] ?? "",
                    status: parts[safe: 3] ?? "",
                    ports: parts[safe: 4] ?? "",
                    created: parts[safe: 5] ?? ""
                )
            }
    }

    /// Start a container
    func startContainer(host: Host, containerId: String) async throws {
        let safe = try validated(containerId)
        _ = try await executeSSH(host: host, command: "docker start \(safe)")
        logger.info("Started container \(safe)")
    }

    /// Stop a container
    func stopContainer(host: Host, containerId: String) async throws {
        let safe = try validated(containerId)
        _ = try await executeSSH(host: host, command: "docker stop \(safe)")
        logger.info("Stopped container \(safe)")
    }

    /// Restart a container
    func restartContainer(host: Host, containerId: String) async throws {
        let safe = try validated(containerId)
        _ = try await executeSSH(host: host, command: "docker restart \(safe)")
        logger.info("Restarted container \(safe)")
    }

    /// Remove a container
    func removeContainer(host: Host, containerId: String, force: Bool = false) async throws {
        let safe = try validated(containerId)
        let flag = force ? "-f" : ""
        _ = try await executeSSH(host: host, command: "docker rm \(flag) \(safe)")
        logger.info("Removed container \(safe)")
    }

    /// Get container logs
    func containerLogs(host: Host, containerId: String, lines: Int = 100) async throws -> String {
        let safe = try validated(containerId)
        return try await executeSSH(
            host: host,
            command: "docker logs --tail \(lines) \(safe) 2>&1"
        )
    }

    /// Get container inspect info
    func inspectContainer(host: Host, containerId: String) async throws -> String {
        let safe = try validated(containerId)
        return try await executeSSH(host: host, command: "docker inspect \(safe)")
    }

    private func executeSSH(host: Host, command: String) async throws -> String {
        // Runs over the host's shared master connection (no re-authentication).
        let result = try await sshService.run(command, on: host)
        guard result.exitCode == 0 else {
            throw DockerError.commandFailed(Self.failureReason(stdout: result.stdout, stderr: result.stderr))
        }
        return result.stdout
    }

    /// Why a command failed: what it wrote to stderr, or — for one run with "2>&1" (logs),
    /// whose stderr is empty by construction — what it wrote to stdout.
    static func failureReason(stdout: String, stderr: String) -> String {
        let reason = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : reason
    }

    enum DockerError: Error, LocalizedError {
        case commandFailed(String)
        case invalidContainerId(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let msg): String(localized: "Docker error: \(msg)")
            case .invalidContainerId(let id): String(localized: "Invalid container ID: \(id)")
            }
        }
    }
}
