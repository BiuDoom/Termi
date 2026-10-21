import Testing
import Foundation
@testable import Termi

private actor BatchResultCollector {
    var values: [BatchCommandService.HostResult] = []
    func append(_ result: BatchCommandService.HostResult) { values.append(result) }
}

@Test(arguments: [Int32(0), Int32(7)])
func batchKeepsBothShellStreamsAndActualExitStatus(_ exitCode: Int32) async throws {
    let service = BatchCommandService(runCommand: { command, _ in
        try await ProcessRunner.run("/bin/sh", arguments: ["-c", command])
    })
    let collector = BatchResultCollector()
    await service.execute(command: "printf 'diagnostic stdout\\n'; printf 'diagnostic stderr\\n' >&2; exit \(exitCode)",
                          hosts: [Termi.Host.defaultValue()]) { result in
        await collector.append(result)
    }
    let results = await collector.values
    let result = try #require(results.first)
    #expect(results.count == 1)
    #expect(result.output == "diagnostic stdout\n")
    #expect(result.stderr == "diagnostic stderr\n")
    #expect(result.exitCode == exitCode)
    #expect(result.error == nil)
    #expect(result.isFailure == (exitCode != 0))
    #expect(result.transcript.contains("diagnostic stdout"))
    #expect(result.transcript.contains("diagnostic stderr"))
}

@Test func batchTransportErrorIsSeparateFromRemoteExitCode() async throws {
    let service = BatchCommandService(runCommand: { _, _ in throw URLError(.cannotConnectToHost) })
    let collector = BatchResultCollector()
    await service.execute(command: "true", hosts: [Termi.Host.defaultValue()]) { result in
        await collector.append(result)
    }
    let results = await collector.values
    let result = try #require(results.first)
    #expect(result.error != nil)
    #expect(result.isFailure)
    #expect(result.exitCode == -1)
    #expect(result.output.isEmpty)
    #expect(result.stderr.isEmpty)
}

@Test func batchGroupsAndSummaryIncludeExitCodeAndBothStreams() {
    let host = Termi.Host.defaultValue()
    let ok = BatchCommandService.HostResult(host: host, output: "same", stderr: "warning", error: nil,
                                            exitCode: 0, durationMs: 1)
    let failed = BatchCommandService.HostResult(host: host, output: "same", stderr: "warning", error: nil,
                                                exitCode: 7, durationMs: 1)
    let otherFailure = BatchCommandService.HostResult(host: host, output: "same", stderr: "warning", error: nil,
                                                      exitCode: 8, durationMs: 1)
    let otherStderr = BatchCommandService.HostResult(host: host, output: "same", stderr: "other", error: nil,
                                                     exitCode: 7, durationMs: 1)
    let results = [ok, failed, otherFailure, otherStderr]
    let groups = BatchCommandViewModel.outputGroups(of: results)
    #expect(groups.count == 4)
    #expect(groups[0].text.contains("same"))
    #expect(groups[0].text.contains("warning"))
    #expect(groups[1].isFailure)
    let ordered = BatchCommandViewModel.ordered(results)
    #expect(ordered.first?.exitCode == 7)
    #expect(ordered.last?.exitCode == 0)
    let summary = BatchCommandViewModel.Summary(results: results, expected: 4)
    #expect(summary.succeeded == 1)
    #expect(summary.failed == 3)
    let transcript = BatchCommandViewModel.transcript(of: results)
    #expect(transcript.contains("same"))
    #expect(transcript.contains("warning"))
    #expect(transcript.contains("7"))
    #expect(transcript.contains("8"))
}
