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

    /// One SSH command. Sections are separated with `;`, not `&&`: `&&` and `||` share
    /// precedence and associate left, so a probe that fails (no `top`, no `/proc`) used to skip
    /// every section after it. A pipeline's status is the last command's, so `top | head || fallback`
    /// never ran the fallback — `head` exits 0 on empty input — and `top | head` itself makes a
    /// successful `top` exit from SIGPIPE, which would then launch the other `top` as well.
    /// CPU falls back only when the first probe printed nothing.
    nonisolated static let statsCommand = """
    echo "===HOSTNAME==="; hostname
    echo "===UPTIME==="; uptime
    echo "===LOADAVG==="; cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null
    echo "===MEM==="; free -b 2>/dev/null || vm_stat
    echo "===DISK==="; df -B1 / 2>/dev/null || df -k /
    echo "===CPU==="; cpu=$(top -bn1 2>/dev/null | head -10); if [ -z "$cpu" ]; then cpu=$(top -l1 2>/dev/null | head -10); fi; printf '%s\\n' "$cpu"
    echo "===NET==="; if [ -r /proc/net/dev ]; then tail -n +3 /proc/net/dev; else netstat -ib 2>/dev/null | head -20; fi
    """

    /// Gather all server stats in one SSH call
    func fetchStats(host: Host) async throws -> ServerStats {
        let output = try await executeSSH(host: host, command: Self.statsCommand)
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
                // Linux `/proc/loadavg` is "1.50 0.80 0.30 …". macOS `sysctl -n vm.loadavg` is "{ 1.50 0.80 0.30 }".
                let cleaned = value.replacingOccurrences(of: "{", with: " ")
                    .replacingOccurrences(of: "}", with: " ")
                    .replacingOccurrences(of: ",", with: " ")
                let parts = cleaned.components(separatedBy: " ").filter { !$0.isEmpty }
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
        // macOS `vm_stat` has no Mem: line. A zero total from `free` is not a real reading.
        if stats.memTotal == 0 {
            parseVMStat(raw, stats: &stats)
        }
    }

    /// `vm_stat`: page counts, with a trailing period on each number. Used is active + wired +
    /// compressed (what Activity Monitor counts); inactive and speculative stay in the total as cache.
    private func parseVMStat(_ raw: String, stats: inout ServerStats) {
        guard let pageMatch = raw.range(of: #"page size of (\d+)"#, options: .regularExpression) else { return }
        let pageDigits = raw[pageMatch].filter(\.isNumber)
        let pageSize = Int64(pageDigits) ?? 0
        guard pageSize > 0 else { return }

        var pages: [String: Int64] = [:]
        for line in raw.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard label.hasPrefix("pages ") else { continue }
            let name = String(label.dropFirst("pages ".count))
            let digits = line[colon...].filter(\.isNumber)
            guard let count = Int64(digits) else { continue }
            pages[name] = count
        }
        let free = pages["free"] ?? 0
        let active = pages["active"] ?? 0
        let inactive = pages["inactive"] ?? 0
        let speculative = pages["speculative"] ?? 0
        let wired = pages["wired down"] ?? 0
        let compressor = pages["occupied by compressor"] ?? 0
        let totalPages = free + active + inactive + speculative + wired + compressor
        guard totalPages > 0 else { return }
        stats.memTotal = Self.scale(totalPages, by: pageSize)
        stats.memUsed = Self.scale(active + wired + compressor, by: pageSize)
        if stats.memTotal > 0 {
            stats.memPercent = Double(stats.memUsed) / Double(stats.memTotal) * 100
        }
    }

    func parseDisk(_ raw: String, stats: inout ServerStats) {
        let lines = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let header = lines.first else { return }
        // `df -B1` reports bytes (`1B-blocks`). The macOS fallback `df -k` reports 1024-byte blocks.
        let blockBytes = Self.diskBlockBytes(in: header)
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: " ").filter { !$0.isEmpty }
            let total: Int64
            let used: Int64
            if let first = parts.first, first.allSatisfy(\.isNumber),
               let totalBlocks = Int64(first), let usedBlocks = Int64(parts[safe: 1] ?? "") {
                // The filesystem name was too long and df wrapped the numbers onto this line.
                total = totalBlocks
                used = usedBlocks
            } else if parts.count >= 3, let totalBlocks = Int64(parts[1]), let usedBlocks = Int64(parts[2]) {
                total = totalBlocks
                used = usedBlocks
            } else {
                continue
            }
            guard total > 0 else { continue }
            stats.diskTotal = Self.scale(total, by: blockBytes)
            stats.diskUsed = Self.scale(used, by: blockBytes)
            if stats.diskTotal > 0 {
                stats.diskPercent = Double(stats.diskUsed) / Double(stats.diskTotal) * 100
            }
            return
        }
    }

    /// Block size named by a `df` header. Unknown headers are treated as bytes (`df -B1`).
    private static func diskBlockBytes(in header: String) -> Int64 {
        let lower = header.lowercased()
        if lower.contains("1024-blocks") || lower.contains("1k-blocks") { return 1024 }
        if lower.contains("512-blocks") { return 512 }
        return 1
    }

    private static func scale(_ value: Int64, by multiplier: Int64) -> Int64 {
        guard multiplier > 0, value > 0 else { return 0 }
        if value > Int64.max / multiplier { return Int64.max }
        return value * multiplier
    }

    func parseCPU(_ raw: String, stats: inout ServerStats) {
        // Linux top: look for %Cpu(s) line. macOS `top -l1` writes "86.67% idle" — the percent
        // sign sits where the Linux line has a space, so the old pattern never matched it.
        let lines = raw.components(separatedBy: "\n")
        for line in lines {
            if line.contains("Cpu") || line.contains("CPU") {
                if let idleMatch = line.range(of: #"(\d+\.?\d*)%?\s*(id|idle)"#, options: .regularExpression) {
                    let matched = line[idleMatch]
                    let idleStr = matched.prefix { $0.isNumber || $0 == "." }
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