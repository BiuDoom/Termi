import Foundation
import os.log

/// Server monitoring — CPU, memory, disk, network stats via SSH
actor MonitorService {
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "Monitor")
    private let sshService = SSHService.shared

    struct ServerStats: Sendable {
        var cpuUsage: Double = 0
        var memTotal: Int64 = 0
        var memUsed: Int64 = 0
        var memPercent: Double = 0
        var diskTotal: Int64 = 0
        var diskUsed: Int64 = 0
        var diskPercent: Double = 0
        var loadAvg1: Double = 0
        var loadAvg5: Double = 0
        var loadAvg15: Double = 0
        var uptime: String = ""
        var hostname: String = ""
        var processes: Int = 0
        var networkRx: Int64 = 0
        var networkTx: Int64 = 0
    }

    /// Gather all server stats in one SSH call
    func fetchStats(host: Host) async throws -> ServerStats {
        let command = """
        echo "===HOSTNAME===" && hostname && \
        echo "===UPTIME===" && uptime && \
        echo "===LOADAVG===" && cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null && \
        echo "===MEM===" && free -b 2>/dev/null || vm_stat 2>/dev/null && \
        echo "===DISK===" && df -B1 / 2>/dev/null || df -k / && \
        echo "===CPU===" && top -bn1 2>/dev/null | head -5 || top -l1 2>/dev/null | head -10 && \
        echo "===NET===" && cat /proc/net/dev 2>/dev/null | tail -n+3 || netstat -ib 2>/dev/null | head -5
        """

        let output = try await executeSSH(host: host, command: command)
        return parseStats(output)
    }

    func parseStats(_ output: String) -> ServerStats {
        var stats = ServerStats()
        let sections = output.components(separatedBy: "===")

        for i in stride(from: 1, to: sections.count - 1, by: 2) {
            let key = sections[safe: i + 0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let value = sections[safe: i + 1]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            switch key {
            case "HOSTNAME":
                stats.hostname = value.components(separatedBy: "\n").first ?? ""

            case "UPTIME":
                stats.uptime = value.components(separatedBy: "\n").first ?? ""

            case "LOADAVG":
                let parts = value.components(separatedBy: " ").filter { !$0.isEmpty }
                stats.loadAvg1 = Double(parts[safe: 0] ?? "") ?? 0
                stats.loadAvg5 = Double(parts[safe: 1] ?? "") ?? 0
                stats.loadAvg15 = Double(parts[safe: 2] ?? "") ?? 0

            case "MEM":
                parseMemory(value, stats: &stats)

            case "DISK":
                parseDisk(value, stats: &stats)

            case "CPU":
                parseCPU(value, stats: &stats)

            case "NET":
                parseNetwork(value, stats: &stats)

            default:
                break
            }
        }

        return stats
    }

    func parseMemory(_ raw: String, stats: inout ServerStats) {
        // Linux: free -b output
        let lines = raw.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("Mem:") {
                let parts = line.components(separatedBy: " ").filter { !$0.isEmpty }
                stats.memTotal = Int64(parts[safe: 1] ?? "") ?? 0
                stats.memUsed = Int64(parts[safe: 2] ?? "") ?? 0
                if stats.memTotal > 0 {
                    stats.memPercent = Double(stats.memUsed) / Double(stats.memTotal) * 100
                }
            }
        }
    }

    func parseDisk(_ raw: String, stats: inout ServerStats) {
        let lines = raw.components(separatedBy: "\n")
        // Skip header, parse first data line (root filesystem)
        if lines.count >= 2 {
            let parts = lines[1].components(separatedBy: " ").filter { !$0.isEmpty }
            stats.diskTotal = Int64(parts[safe: 1] ?? "") ?? 0
            stats.diskUsed = Int64(parts[safe: 2] ?? "") ?? 0
            if stats.diskTotal > 0 {
                stats.diskPercent = Double(stats.diskUsed) / Double(stats.diskTotal) * 100
            }
        }
    }

    func parseCPU(_ raw: String, stats: inout ServerStats) {
        // Linux top: look for %Cpu(s) line
        let lines = raw.components(separatedBy: "\n")
        for line in lines {
            if line.contains("Cpu") || line.contains("CPU") {
                // Extract idle percentage, calculate usage
                if let idleMatch = line.range(of: #"(\d+\.?\d*)\s*(id|idle)"#, options: .regularExpression) {
                    let idleStr = line[idleMatch].components(separatedBy: " ").first ?? "0"
                    let idle = Double(idleStr) ?? 0
                    stats.cpuUsage = 100 - idle
                }
            }
            if line.contains("Tasks") || line.contains("Processes") {
                if let match = line.range(of: #"(\d+)\s+total"#, options: .regularExpression) {
                    let numStr = line[match].components(separatedBy: " ").first ?? "0"
                    stats.processes = Int(numStr) ?? 0
                }
            }
        }
    }

    func parseNetwork(_ raw: String, stats: inout ServerStats) {
        // Linux /proc/net/dev — sum all interfaces
        let lines = raw.components(separatedBy: "\n")
        for line in lines {
            let parts = line.components(separatedBy: ":").last?
                .components(separatedBy: " ").filter { !$0.isEmpty } ?? []
            if parts.count >= 9 {
                stats.networkRx += Int64(parts[safe: 0] ?? "") ?? 0
                stats.networkTx += Int64(parts[safe: 8] ?? "") ?? 0
            }
        }
    }

    private func executeSSH(host: Host, command: String) async throws -> String {
        // Runs over the host's shared master connection (no re-authentication).
        let result = try await sshService.run(command, on: host)
        guard result.exitCode == 0 else {
            throw MonitorError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    enum MonitorError: Error, LocalizedError {
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let msg): String(localized: "Monitoring failed: \(msg)")
            }
        }
    }
}