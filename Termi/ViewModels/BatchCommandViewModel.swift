import SwiftUI
import os.log

/// ViewModel for batch command execution on multiple hosts
@Observable
@MainActor
final class BatchCommandViewModel {
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "BatchCommandVM")
    private let batchService = BatchCommandService()
    private let hostRepo = HostRepository.shared

    // Host selection
    var allHosts: [Host] = [] {
        // The model outlives the page: forget the ticks of hosts deleted since.
        didSet { selectedHostIds.formIntersection(allHosts.compactMap(\.id)) }
    }
    var selectedHostIds: Set<Int64> = []

    // Command
    var command: String = ""
    var commandHistory: [String] = []

    // Results
    var results: [BatchCommandService.HostResult] = []
    var isExecuting = false
    var error: String?
    /// The hosts of the last run (the ticks may have changed since) and when it started.
    private(set) var runHosts: [Host] = []
    private(set) var lastRunAt: Date?

    /// Saved snippets, offered next to the editor.
    private(set) var snippets: [Snippet] = []

    var selectedHosts: [Host] {
        allHosts.filter { selectedHostIds.contains($0.id ?? -1) }
    }

    func loadHosts() async {
        do {
            allHosts = try await hostRepo.fetchAll()
        } catch {
            // The page left while its hosts were read (the read is cancelled with it): nothing
            // failed, and the model would keep showing the error when the page comes back.
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func execute() async {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard !selectedHosts.isEmpty else {
            error = String(localized: "No hosts selected")
            return
        }

        isExecuting = true
        results = []
        error = nil
        runHosts = selectedHosts
        lastRunAt = Date()

        // Save to history
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if !commandHistory.contains(trimmed) {
            commandHistory.insert(trimmed, at: 0)
            if commandHistory.count > 50 { commandHistory.removeLast() }
        }

        await batchService.execute(
            command: trimmed,
            hosts: selectedHosts
        ) { [weak self] result in
            await self?.appendResult(result)
        }

        isExecuting = false
        logger.info("Batch execution completed: \(self.results.count) results")

        // Notify user of batch completion
        let successCount = results.filter { !$0.isFailure }.count
        NotificationService.shared.sendBatchComplete(
            hostCount: results.count,
            successCount: successCount
        )
    }

    private func appendResult(_ result: BatchCommandService.HostResult) {
        results.append(result)
    }

    func selectAllHosts() {
        selectedHostIds = Set(allHosts.compactMap(\.id))
    }

    func deselectAllHosts() {
        selectedHostIds.removeAll()
    }

    func clearResults() {
        results.removeAll()
        runHosts = []
        lastRunAt = nil
    }

    /// The snippets for the editor's menu; without them the menu is just disabled.
    func loadSnippets() async {
        snippets = (try? await SnippetRepository.shared.fetchAll()) ?? []
    }

    /// A snippet goes into an empty editor, or on a new line after what is there.
    func insert(_ snippet: Snippet) {
        command = Self.inserting(snippet.command, into: command)
    }

    // MARK: - What the page shows

    var summary: Summary {
        Summary(results: results, expected: runHosts.count)
    }

    /// Hosts of the running command that have not answered yet.
    var pendingHosts: [Host] {
        guard isExecuting else { return [] }
        let answered = Set(results.map(\.host.connectionKey))
        return runHosts.filter { !answered.contains($0.connectionKey) }
    }

    #if DEBUG
    /// `-debugBatchSample host|output` (debug builds): results for screenshots without
    /// connecting anywhere — one host that refused the login, the others answering.
    func loadDebugSample(sameOutput: Bool) {
        let hosts = Array(allHosts.filter { $0.label != "orb" }.prefix(4))
        guard hosts.count > 1 else { return }
        selectedHostIds = Set(hosts.compactMap(\.id))
        command = sameOutput ? "uname -sr" : "uptime"
        runHosts = hosts
        lastRunAt = Date()
        commandHistory = [command, "df -h /", "systemctl is-active nginx"]
        let uptimes = ["22:04:11 up 41 days,  3:12,  2 users,  load average: 0.42, 0.31, 0.27",
                       "22:04:11 up 128 days, 19:40,  1 user,  load average: 0.03, 0.05, 0.01",
                       "22:04:11 up 41 days,  3:09,  0 users,  load average: 0.18, 0.22, 0.20"]
        let durations = [212, 268, 344]
        results = hosts.enumerated().map { index, host in
            if index == hosts.count - 1 {
                return BatchCommandService.HostResult(host: host, output: "",
                                                      error: "\(host.addressDescription): Permission denied (publickey).",
                                                      exitCode: -1, durationMs: 812)
            }
            let output = sameOutput ? (index < 2 ? "Linux 6.8.0-45-generic" : "Linux 5.15.0-122-generic") : uptimes[index % 3]
            return BatchCommandService.HostResult(host: host, output: output + "\n", error: nil, exitCode: 0,
                                                  durationMs: durations[index % 3])
        }
    }
    #endif
}

// MARK: - Sections, groups, numbers

extension BatchCommandViewModel {
    /// The hosts of one group in the leading column; `title` is nil for hosts without a group.
    struct HostSection: Identifiable {
        let id: String
        let title: String?
        let hosts: [Host]
    }

    /// Hosts by group, groups in their own order, hosts without a (known) group last. One
    /// untitled section when no host is in a group.
    nonisolated static func hostSections(hosts: [Host], groups: [HostGroup]) -> [HostSection] {
        let ordered = groups.sorted {
            $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var sections: [HostSection] = []
        var grouped = Set<String>()
        for group in ordered {
            guard let id = group.id else { continue }
            let members = hosts.filter { $0.groupId == id }
            guard !members.isEmpty else { continue }
            members.forEach { grouped.insert($0.connectionKey) }
            sections.append(HostSection(id: "group-\(id)", title: group.name, hosts: members))
        }
        let rest = hosts.filter { !grouped.contains($0.connectionKey) }
        if !rest.isEmpty {
            sections.append(HostSection(id: "ungrouped", title: nil, hosts: rest))
        }
        return sections
    }

    /// Hosts that answered with the same text.
    struct OutputGroup: Identifiable {
        let id: String
        let text: String
        let isFailure: Bool
        let hosts: [Host]
    }

    /// Results by what they said (an error and an output never share a group), the largest
    /// group first; groups of the same size stay in the order they first appeared.
    nonisolated static func outputGroups(of results: [BatchCommandService.HostResult]) -> [OutputGroup] {
        var order: [String] = []
        var groups: [String: OutputGroup] = [:]
        for result in results {
            let isFailure = result.isFailure
            let text = trimmed(result.transcript)
            // Include channel boundaries and status: identical stdout does not make different
            // warnings, failures, or exit codes the same result. Length-prefix to avoid collisions.
            let parts = [isFailure ? "failure" : "success", String(result.exitCode),
                         trimmed(result.output), trimmed(result.stderr), result.error ?? ""]
            let key = parts.map { "\($0.utf8.count):\($0)" }.joined()
            if let existing = groups[key] {
                groups[key] = OutputGroup(id: key, text: text, isFailure: isFailure, hosts: existing.hosts + [result.host])
            } else {
                order.append(key)
                groups[key] = OutputGroup(id: key, text: text, isFailure: isFailure, hosts: [result.host])
            }
        }
        return order.enumerated()
            .compactMap { index, key in groups[key].map { (index, $0) } }
            .sorted { $0.1.hosts.count != $1.1.hosts.count ? $0.1.hosts.count > $1.1.hosts.count : $0.0 < $1.0 }
            .map(\.1)
    }

    /// Failed first (they are what needs reading), each kind in the order it arrived.
    nonisolated static func ordered(_ results: [BatchCommandService.HostResult]) -> [BatchCommandService.HostResult] {
        results.filter(\.isFailure) + results.filter { !$0.isFailure }
    }

    /// The complete copyable transcript, in the same order as the results list.
    nonisolated static func transcript(of results: [BatchCommandService.HostResult]) -> String {
        ordered(results).map { result in
            "# \(result.host.displayName) (\(result.host.addressDescription))\n" + result.transcript
        }.joined(separator: "\n\n")
    }

    /// Text without the blank lines a remote shell surrounds it with.
    nonisolated static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first non-empty line of an output.
    nonisolated static func firstLine(of text: String) -> String {
        trimmed(text).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    nonisolated static func inserting(_ snippet: String, into command: String) -> String {
        let current = trimmed(command)
        return current.isEmpty ? snippet : current + "\n" + snippet
    }

    /// The numbers of a run.
    struct Summary: Equatable {
        let total: Int
        let succeeded: Int
        let failed: Int
        let pending: Int
        /// Nil until a host has answered.
        let slowestMs: Int?

        init(results: [BatchCommandService.HostResult], expected: Int) {
            succeeded = results.filter { !$0.isFailure }.count
            failed = results.count - succeeded
            total = max(expected, results.count)
            pending = total - results.count
            slowestMs = results.map(\.durationMs).max()
        }
    }
}
