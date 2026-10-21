import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Shared async process execution utility.
///
/// Uses DispatchGroup to drain stdout/stderr pipes on background threads
/// *before* terminationHandler reads them — preventing the classic pipe-buffer-full
/// deadlock where a child process blocks writing to a full pipe and can never exit.
enum ProcessRunner {

    struct Result: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Run a process asynchronously, returning stdout, stderr, and exit code.
    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> Result {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: Result = try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                // Drain pipes on background threads BEFORE terminationHandler reads,
                // preventing pipe-buffer-full deadlock for large output (>64KB).
                let group = DispatchGroup()
                nonisolated(unsafe) var stdoutData = Data()
                nonisolated(unsafe) var stderrData = Data()

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                cancellation.prepare(process)
                do {
                    try process.run()
                    cancellation.launched()
                    // Assign terminationHandler only AFTER process.run() succeeds.
                    // Assigning it before run() means a throw from run() would cause
                    // both the catch block AND the terminationHandler to resume the
                    // continuation — a double-resume crash.
                    process.terminationHandler = { proc in
                        group.wait()
                        cancellation.finished()
                        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                        continuation.resume(returning: Result(
                            stdout: stdout,
                            stderr: stderr,
                            exitCode: proc.terminationStatus
                        ))
                    }
                } catch {
                    // Close write-ends so drain threads receive EOF and exit cleanly
                    try? outputPipe.fileHandleForWriting.close()
                    try? errorPipe.fileHandleForWriting.close()
                    cancellation.finished()
                    continuation.resume(throwing: error)
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Cancellation may arrive before Process.run, while it launches, or after the leader
    /// exits but a descendant still owns a pipe. Serialize launch ownership and stop the
    /// isolated process group so none of these cases leaves the caller waiting for EOF.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var didLaunch = false
        private var wasCancelled = false
        private var isStopping = false

        func prepare(_ process: Process) { lock.withLock { self.process = process } }

        func launched() {
            let target: Process? = lock.withLock {
                didLaunch = true
                guard wasCancelled, !isStopping else { return nil }
                isStopping = true
                return process
            }
            if let target { Self.stop(target) }
        }

        func cancel() {
            let target: Process? = lock.withLock {
                wasCancelled = true
                guard didLaunch, !isStopping else { return nil }
                isStopping = true
                return process
            }
            if let target { Self.stop(target) }
        }

        func finished() { lock.withLock { process = nil } }

        private static func stop(_ process: Process) {
            let pid = process.processIdentifier
            guard pid > 0 else { return }
            // Foundation launches Process in its own process group. Check ownership anyway:
            // never signal the application's group. A shell may have exited while its child
            // keeps stdout open, so check the group even if its leader no longer exists.
            let ownsGroup = pid != getpgrp() && (getpgid(pid) == pid || kill(-pid, 0) == 0)
            if ownsGroup { kill(-pid, SIGTERM) }
            else if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                if ownsGroup { kill(-pid, SIGKILL) }
                else if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}
