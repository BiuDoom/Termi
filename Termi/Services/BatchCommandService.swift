import Foundation
import os.log

/// Executes commands on multiple hosts in parallel.
actor BatchCommandService {
    private let logger = Logger(subsystem: "dev.termi.Termi", category: "BatchCommand")
    private let runCommand: @Sendable (String, Host) async throws -> ProcessRunner.Result

    init(runCommand: @escaping @Sendable (String, Host) async throws -> ProcessRunner.Result = { command, host in
        try await SSHService.shared.run(command, on: host)
    }) {
        self.runCommand = runCommand
    }

    struct HostResult: Identifiable, Sendable {
        let id = UUID()
        let host: Host
        let output: String
        let stderr: String
        /// Connection/transport failure. A completed command's failure is its real exitCode.
        let error: String?
        let exitCode: Int32
        let durationMs: Int

        init(host: Host, output: String, stderr: String = "", error: String?, exitCode: Int32, durationMs: Int) {
            self.host = host
            self.output = output
            self.stderr = stderr
            self.error = error
            self.exitCode = exitCode
            self.durationMs = durationMs
        }

        var isFailure: Bool { error != nil || exitCode != 0 }

        /// Display/copy both streams without suggesting they arrived in any interleaved order.
        /// Keep stdout alone unchanged for commands that have no diagnostics.
        var transcript: String {
            var sections: [String] = []
            if !output.isEmpty {
                sections.append(stderr.isEmpty ? output : String(localized: "Standard Output") + ":\n" + output)
            }
            if !stderr.isEmpty { sections.append(String(localized: "Standard Error") + ":\n" + stderr) }
            if let error { sections.append(error) }
            if error == nil, exitCode != 0 { sections.append(String(localized: "Exit code \(Int(exitCode))")) }
            return sections.joined(separator: "\n")
        }
    }

    /// Await result delivery as well as the command, so the final summary includes every host.
    func execute(
        command: String,
        hosts: [Host],
        onResult: @Sendable @escaping (HostResult) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask { [runCommand] in
                    let start = Date()
                    let result: HostResult
                    do {
                        let commandResult = try await runCommand(command, host)
                        result = HostResult(host: host, output: commandResult.stdout, stderr: commandResult.stderr,
                                            error: nil, exitCode: commandResult.exitCode,
                                            durationMs: Int(Date().timeIntervalSince(start) * 1000))
                    } catch {
                        result = HostResult(host: host, output: "", error: error.localizedDescription, exitCode: -1,
                                            durationMs: Int(Date().timeIntervalSince(start) * 1000))
                    }
                    await onResult(result)
                }
            }
        }
        logger.info("Batch command completed on \(hosts.count) hosts")
    }
}
