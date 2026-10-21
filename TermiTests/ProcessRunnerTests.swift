import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import Termi

@Test func processRunnerEchoSuccess() async throws {
    let result = try await ProcessRunner.run(
        "/bin/echo",
        arguments: ["hello world"]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("hello world"))
    #expect(result.stderr.isEmpty)
}

@Test func processRunnerFalseFailure() async throws {
    let result = try await ProcessRunner.run(
        "/usr/bin/false",
        arguments: []
    )
    #expect(result.exitCode != 0)
}

@Test func processRunnerStderrCapture() async throws {
    // Use sh -c to write to stderr
    let result = try await ProcessRunner.run(
        "/bin/sh",
        arguments: ["-c", "echo error_msg >&2; exit 1"]
    )
    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("error_msg"))
}

@Test func processRunnerEnvironmentPassing() async throws {
    let result = try await ProcessRunner.run(
        "/bin/sh",
        arguments: ["-c", "echo $TERMI_TEST_VAR"],
        environment: ["TERMI_TEST_VAR": "test_value_123"]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("test_value_123"))
}

@Test func processRunnerInvalidExecutableThrows() async {
    await #expect(throws: (any Error).self) {
        _ = try await ProcessRunner.run(
            "/nonexistent/binary",
            arguments: []
        )
    }
}

private final class ProcessCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private var wasCancelled = false
    func finish(cancelled: Bool) { lock.withLock { didFinish = true; wasCancelled = cancelled } }
    var result: (finished: Bool, cancelled: Bool) { lock.withLock { (didFinish, wasCancelled) } }
}

@Test func processRunnerCancellationStopsChildrenAndDrainsTheirPipes() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Termi-Cancel-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let parentFile = folder.appendingPathComponent("parent")
    let childFile = folder.appendingPathComponent("child")
    let recorder = ProcessCancellationRecorder()
    let task = Task {
        do {
            _ = try await ProcessRunner.run("/bin/sh", arguments: ["-c",
                "echo $$ > \"$1\"; trap '' TERM; /bin/sleep 30 & child=$!; echo $child > \"$2\"; wait",
                "cancel-test", parentFile.path, childFile.path])
            recorder.finish(cancelled: false)
        } catch { recorder.finish(cancelled: error is CancellationError) }
    }
    defer { task.cancel() }
    for _ in 0..<150 where !FileManager.default.fileExists(atPath: childFile.path) {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    let parentText = try String(contentsOf: parentFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let childText = try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(Int32(parentText))
    let child = try #require(Int32(childText))
    task.cancel()
    for _ in 0..<100 where !recorder.result.finished { try await Task.sleep(nanoseconds: 20_000_000) }
    // A stubborn parent and its child both ignore TERM; the escalation must stop both.
    let resultBeforeCleanup = recorder.result
    let parentAlive = kill(pid, 0) == 0
    let childAlive = kill(child, 0) == 0
    kill(-pid, SIGKILL) // Unconditional fixture cleanup even when testing the old implementation.
    await task.value
    #expect(resultBeforeCleanup.finished)
    #expect(resultBeforeCleanup.cancelled)
    #expect(!parentAlive)
    #expect(!childAlive)
}

@Test func processRunnerAlreadyCancelledTaskDoesNotLaunch() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("Termi-NotLaunched-\(UUID())")
    defer { try? FileManager.default.removeItem(at: marker) }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await ProcessRunner.run("/bin/sh", arguments: ["-c", "touch \"$1\"", "cancel-test", marker.path])
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}
