import Testing
import Foundation
@testable import Termi

// MARK: - PortForward Model Tests

@Test func portForwardDefaultValues() {
    let pf = PortForward(
        hostId: 1,
        type: "local",
        localPort: 8080,
        remoteHost: "127.0.0.1",
        remotePort: 80,
        enabled: true,
        createdAt: ""
    )
    #expect(pf.id == nil)
    #expect(pf.hostId == 1)
    #expect(pf.type == "local")
    #expect(pf.localPort == 8080)
    #expect(pf.remoteHost == "127.0.0.1")
    #expect(pf.remotePort == 80)
    #expect(pf.enabled == true)
}

@Test func portForwardTypes() {
    let types = ["local", "remote", "dynamic"]
    for t in types {
        let pf = PortForward(
            hostId: 1,
            type: t,
            localPort: 9090,
            remoteHost: "localhost",
            remotePort: 3306,
            enabled: true,
            createdAt: ""
        )
        #expect(pf.type == t)
    }
}

// MARK: - SSH Argument Generation Tests

@Test func sshArgsLocalForward() {
    let pf = PortForward(
        hostId: 1,
        type: "local",
        localPort: 8080,
        remoteHost: "127.0.0.1",
        remotePort: 80,
        enabled: true,
        createdAt: ""
    )
    let args = sshPortForwardArgs(for: [pf])
    #expect(args == ["-L", "8080:127.0.0.1:80"])
}

@Test func sshArgsRemoteForward() {
    let pf = PortForward(
        hostId: 1,
        type: "remote",
        localPort: 3000,
        remoteHost: "10.0.0.1",
        remotePort: 3000,
        enabled: true,
        createdAt: ""
    )
    let args = sshPortForwardArgs(for: [pf])
    #expect(args == ["-R", "3000:10.0.0.1:3000"])
}

@Test func sshArgsDynamicForward() {
    let pf = PortForward(
        hostId: 1,
        type: "dynamic",
        localPort: 1080,
        remoteHost: "127.0.0.1",
        remotePort: 0,
        enabled: true,
        createdAt: ""
    )
    let args = sshPortForwardArgs(for: [pf])
    #expect(args == ["-D", "1080"])
}

@Test func sshArgsDisabledForwardSkipped() {
    let pf = PortForward(
        hostId: 1,
        type: "local",
        localPort: 8080,
        remoteHost: "127.0.0.1",
        remotePort: 80,
        enabled: false,
        createdAt: ""
    )
    let args = sshPortForwardArgs(for: [pf])
    #expect(args.isEmpty)
}

@Test func sshArgsMultipleForwards() {
    let forwards = [
        PortForward(hostId: 1, type: "local", localPort: 8080, remoteHost: "127.0.0.1", remotePort: 80, enabled: true, createdAt: ""),
        PortForward(hostId: 1, type: "remote", localPort: 3306, remoteHost: "db.internal", remotePort: 3306, enabled: true, createdAt: ""),
        PortForward(hostId: 1, type: "dynamic", localPort: 1080, remoteHost: "127.0.0.1", remotePort: 0, enabled: true, createdAt: ""),
        PortForward(hostId: 1, type: "local", localPort: 9999, remoteHost: "127.0.0.1", remotePort: 9999, enabled: false, createdAt: ""),
    ]
    let args = sshPortForwardArgs(for: forwards)
    #expect(args == [
        "-L", "8080:127.0.0.1:80",
        "-R", "3306:db.internal:3306",
        "-D", "1080",
    ])
}

@Test func sshArgsX11Forwarding() {
    let args = sshX11Args(enabled: true)
    #expect(args == ["-X"])

    let argsDisabled = sshX11Args(enabled: false)
    #expect(argsDisabled.isEmpty)
}

// MARK: - PortForwardManager

// Deleting a rule always stops it first, running or not: that must not need a connection.
@Test @MainActor func stoppingARuleThatIsNotRunningIsHarmless() async {
    let manager = PortForwardManager()
    var rule = PortForward(hostId: 1, type: "local", localPort: 8080, remoteHost: "127.0.0.1", remotePort: 80, enabled: true, createdAt: "")
    rule.id = 42

    await manager.stop(rule)

    #expect(manager.status(of: rule) == nil)
    #expect(manager.isRunning(rule) == false)
}

// MARK: - Helpers (the arguments the SSH engine passes to `ssh -O forward`)

private func sshPortForwardArgs(for forwards: [PortForward]) -> [String] {
    forwards.filter(\.enabled).flatMap(\.sshForward.arguments)
}

private func sshX11Args(enabled: Bool) -> [String] {
    enabled ? ["-X"] : []
}

/// A real SSHMasterConnection with an ssh command fixture: records forward/cancel arguments.
private func forwardingFixture() throws -> (SSHMasterConnection, SSHRuntime, URL) {
    // Short: the askpass socket lives inside it, and a Unix socket path has room for 104 bytes only.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TermiTests-" + SSHRuntime.randomHex(bytes: 3), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("ssh")
    let script = #"""
#!/bin/sh
root=$(dirname "$0")
for arg in "$@"; do
  if [ "$arg" = "-O" ]; then
    printf '%s\n' "$*" >> "$root/commands"
    for value in "$@"; do
      if [ "$value" = "forward" ]; then
        count=0
        while [ -f "$root/hold-forward" ] && [ "$count" -lt 500 ]; do sleep 0.01; count=$((count + 1)); done
        [ -f "$root/reject-forward" ] && exit 1
        : > "$root/installed"
      fi
      if [ "$value" = "cancel" ] && [ -f "$root/require-installed" ]; then
        [ -f "$root/installed" ] || exit 1
      fi
    done
    if [ -f "$root/reject-cancel" ]; then
      for value in "$@"; do [ "$value" = "cancel" ] && exit 1; done
    fi
    exit 0
  fi
done
control=$(sed -n 's/^  ControlPath "\(.*\)"$/\1/p' "$2" | head -n 1)
: > "$control"
exec sleep 30
"""#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let runtime = SSHRuntime(askpassExecutable: "/usr/bin/false", sshPath: executable.path, parentDirectory: root)
    let spec = SSHConnectionSpec(hops: [.init(alias: "termi-h0", displayName: "fixture", hostname: "fixture.invalid", username: "tester")])
    let master = try SSHMasterConnection(spec: spec, runtime: runtime, callbacks: .init(prompt: { _ in .cancel }))
    return (master, runtime, root)
}

@Test @MainActor func stoppingEditedForwardCancelsOriginalParameters() async throws {
    let (master, runtime, root) = try forwardingFixture()
    defer { master.close(); runtime.shutdown(); try? FileManager.default.removeItem(at: root) }
    try await master.connect()
    var host = Host.defaultValue()
    host.label = "forward-\(UUID())"
    host.hostname = "fixture.invalid"
    let saved = try await HostRepository.shared.save(host)
    let hostId = try #require(saved.id)
    let original = try await PortForwardRepository.shared.save(PortForward(hostId: hostId, type: "local", localPort: 18080, remoteHost: "127.0.0.1", remotePort: 80, enabled: true, createdAt: ""))
    let manager = PortForwardManager()
    await manager.applyAutoForwards(for: saved, on: master)
    var edited = original
    edited.localPort = 18081
    await manager.stop(edited)
    let commands = try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8)
    let cancelled = commands.split(separator: "\n").filter { $0.contains("-O cancel") }
    #expect(cancelled.count == 1)
    #expect(cancelled.first?.contains("18080:127.0.0.1:80") == true)
    #expect(!manager.isRunning(edited))
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
}

@Test @MainActor func failedForwardCancellationKeepsRunningStateAndCanRetry() async throws {
    let (master, runtime, root) = try forwardingFixture()
    defer { master.close(); runtime.shutdown(); try? FileManager.default.removeItem(at: root) }
    try await master.connect()
    var host = Host.defaultValue()
    host.label = "forward-retry-\(UUID())"
    host.hostname = "fixture.invalid"
    let saved = try await HostRepository.shared.save(host)
    let hostId = try #require(saved.id)
    let original = try await PortForwardRepository.shared.save(PortForward(hostId: hostId, type: "local", localPort: 18082, remoteHost: "127.0.0.1", remotePort: 80, enabled: true, createdAt: ""))
    let manager = PortForwardManager()
    await manager.applyAutoForwards(for: saved, on: master)
    let rejection = root.appendingPathComponent("reject-cancel")
    try Data().write(to: rejection)
    await #expect(throws: (any Error).self) { try await manager.stopForMutation(original) }
    #expect(manager.isRunning(original))
    try FileManager.default.removeItem(at: rejection)
    try await manager.stopForMutation(original)
    #expect(manager.status(of: original) == nil)
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
}

@Test @MainActor func hostFormDeletionStopsItsAutoForward() async throws {
    let (master, runtime, root) = try forwardingFixture()
    defer { master.close(); runtime.shutdown(); try? FileManager.default.removeItem(at: root) }
    try await master.connect()
    var host = Host.defaultValue()
    host.label = "forward-form-\(UUID())"
    host.hostname = "fixture.invalid"
    let saved = try await HostRepository.shared.save(host)
    let hostId = try #require(saved.id)
    let original = try await PortForwardRepository.shared.save(PortForward(hostId: hostId, type: "local", localPort: 18083, remoteHost: "127.0.0.1", remotePort: 80, enabled: true, createdAt: ""))
    await PortForwardManager.shared.applyAutoForwards(for: saved, on: master)
    let result = await HostsViewModel.store(HostDraft(host: saved, portForwards: [], tags: [], passwordChange: .keep))
    #expect(result.failure == nil)
    #expect(!PortForwardManager.shared.isRunning(original))
    let remaining = try await PortForwardRepository.shared.fetchForHost(hostId)
    #expect(remaining.isEmpty)
    let commands = try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8)
    #expect(commands.contains("-O cancel"))
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
}

private func waitForForwardCommand(in root: URL) async throws {
    for _ in 0..<300 {
        if (try? String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8))?.contains("-O forward") == true { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The forwarding fixture never received an add request")
}

@Test @MainActor func queuedAutoForwardCannotReviveAMutatedRule() async throws {
    let (master, runtime, root) = try forwardingFixture()
    defer { master.close(); runtime.shutdown(); try? FileManager.default.removeItem(at: root) }
    try await master.connect()
    var host = Host.defaultValue()
    host.hostname = "auto-revision-\(UUID()).invalid"
    let saved = try await HostRepository.shared.save(host)
    let hostId = try #require(saved.id)
    let first = try await PortForwardRepository.shared.save(PortForward(hostId: hostId, type: "local", localPort: 18100, remoteHost: "127.0.0.1", remotePort: 80, enabled: true, createdAt: ""))
    let second = try await PortForwardRepository.shared.save(PortForward(hostId: hostId, type: "local", localPort: 18101, remoteHost: "127.0.0.1", remotePort: 80, enabled: true, createdAt: ""))
    let secondId = try #require(second.id)
    let manager = PortForwardManager()
    let hold = root.appendingPathComponent("hold-forward")
    try Data().write(to: hold)
    let starting = Task { await manager.applyAutoForwards(for: saved, on: master) }
    try await waitForForwardCommand(in: root)
    let mutation = try manager.beginMutation(id: secondId)
    try await manager.stopForMutation(second)
    try await PortForwardRepository.shared.delete(id: secondId)
    manager.endMutation(mutation)
    try FileManager.default.removeItem(at: hold)
    await starting.value
    let commands = try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8)
    #expect(!commands.contains("18101:127.0.0.1:80"))
    #expect(!manager.isRunning(second))
    await manager.stop(first)
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
}

@Test(arguments: [false, true]) @MainActor func stoppingPendingForwardWaitsForInstallationResult(addFails: Bool) async throws {
    let (master, runtime, root) = try forwardingFixture()
    defer { master.close(); runtime.shutdown(); try? FileManager.default.removeItem(at: root) }
    try await master.connect()
    var host = Host.defaultValue()
    host.hostname = "pending-forward-\(UUID()).invalid"
    let saved = try await HostRepository.shared.save(host)
    let hostId = try #require(saved.id)
    let rule = try await PortForwardRepository.shared.save(PortForward(hostId: hostId, type: "local", localPort: 18102, remoteHost: "127.0.0.1", remotePort: 80, enabled: true, createdAt: ""))
    let manager = PortForwardManager()
    let hold = root.appendingPathComponent("hold-forward")
    try Data().write(to: hold)
    try Data().write(to: root.appendingPathComponent("require-installed"))
    if addFails { try Data().write(to: root.appendingPathComponent("reject-forward")) }
    let starting = Task { await manager.applyAutoForwards(for: saved, on: master) }
    try await waitForForwardCommand(in: root)
    let stopping = Task { try await manager.stopForMutation(rule) }
    await Task.yield()
    try FileManager.default.removeItem(at: hold)
    try await stopping.value
    await starting.value
    let commands = try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8)
    #expect(commands.contains("-O cancel") == !addFails)
    #expect(manager.status(of: rule) == nil)
    #expect(!manager.isRunning(rule))
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
}

@Test @MainActor func autoForwardDoesNotReadAnUncommittedRuleEdit() async throws {
    let (master, runtime, root) = try forwardingFixture()
    defer { master.close(); runtime.shutdown(); try? FileManager.default.removeItem(at: root) }
    try await master.connect()
    var host = Host.defaultValue()
    host.hostname = "forward-mutation-\(UUID()).invalid"
    let saved = try await HostRepository.shared.save(host)
    let hostId = try #require(saved.id)
    let rule = try await PortForwardRepository.shared.save(PortForward(hostId: hostId, type: "local", localPort: 18103, remoteHost: "127.0.0.1", remotePort: 80, enabled: true, createdAt: ""))
    let manager = PortForwardManager()
    let token = try manager.beginMutation(id: rule.id)
    await manager.applyAutoForwards(for: saved, on: master)
    #expect(!manager.isRunning(rule))
    var updated = rule
    updated.localPort = 18104
    try await PortForwardRepository.shared.save(updated)
    manager.endMutation(token)
    await manager.applyAutoForwards(for: saved, on: master)
    let commands = try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8)
    #expect(!commands.contains("18103:127.0.0.1:80"))
    #expect(commands.contains("18104:127.0.0.1:80"))
    await manager.stop(updated)
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
}
