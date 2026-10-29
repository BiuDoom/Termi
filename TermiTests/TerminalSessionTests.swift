import Testing
import AppKit
@testable import Termi

// MARK: - Exit status decoding

@Test func waitStatusOfNormalExitDecodesToExitCode() {
    // exit(N) is reported by waitpid as N << 8.
    #expect(TerminalSession.exitCode(fromWaitStatus: 0) == 0)
    #expect(TerminalSession.exitCode(fromWaitStatus: 256) == 1)
    #expect(TerminalSession.exitCode(fromWaitStatus: 512) == 2)
    #expect(TerminalSession.exitCode(fromWaitStatus: 768) == 3)
    #expect(TerminalSession.exitCode(fromWaitStatus: 32512) == 127)
}

@Test func waitStatusOfSSHConnectionErrorDecodesTo255() {
    // ssh exits with 255 when the connection drops; the session relies on seeing exactly 255.
    #expect(TerminalSession.exitCode(fromWaitStatus: 65280) == 255)
}

@Test func waitStatusOfSignalDecodesLikeAShell() {
    // Killed by a signal: the low 7 bits hold the signal number, 0x80 is the core-dump flag.
    let hangup: Int32 = SIGHUP
    let killed: Int32 = SIGKILL
    let terminated: Int32 = SIGTERM
    let segfaultWithCore: Int32 = SIGSEGV | 0x80
    #expect(TerminalSession.exitCode(fromWaitStatus: hangup) == 129)
    #expect(TerminalSession.exitCode(fromWaitStatus: killed) == 137)
    #expect(TerminalSession.exitCode(fromWaitStatus: terminated) == 143)
    #expect(TerminalSession.exitCode(fromWaitStatus: segfaultWithCore) == 139)
}

// MARK: - History row vs the shell that opened it

@Test func aConnectionLogStaysWithTheShellThatOpenedIt() {
    let sameShell = TerminalSession.keepsConnectionLog(
        generation: 4, activeGeneration: 4, isConnected: true, shellStillOpen: true)
    #expect(sameShell)

    // Reconnect started the next shell before the previous insert returned.
    let reconnected = TerminalSession.keepsConnectionLog(
        generation: 4, activeGeneration: 6, isConnected: true, shellStillOpen: true)
    #expect(reconnected == false)

    // The shell ended, but the exit-255 check has not changed the state off `.connected` yet.
    let endedWhileStillShownConnected = TerminalSession.keepsConnectionLog(
        generation: 4, activeGeneration: 4, isConnected: true, shellStillOpen: false)
    #expect(endedWhileStillShownConnected == false)

    let notConnected = TerminalSession.keepsConnectionLog(
        generation: 4, activeGeneration: 4, isConnected: false, shellStillOpen: true)
    #expect(notConnected == false)
}

// MARK: - Exit status 255: the remote shell's own, or a lost connection

@Test func exit255OverALiveMasterIsNotAConnectionLossByItself() {
    // `exit` after a failed ssh on a jump host: the mux client passes the shell's 255 on while
    // the connection is fine. Only the master says whether the connection is gone.
    #expect(TerminalSession.shellExit(exitCode: 255, masterAlive: true) == .ambiguous)
    #expect(TerminalSession.shellExit(exitCode: 255, masterAlive: false) == .connectionLost)
}

@Test func shellExitFollowsTheMasterForEveryOtherStatus() {
    #expect(TerminalSession.shellExit(exitCode: 0, masterAlive: true) == .finished)
    #expect(TerminalSession.shellExit(exitCode: 1, masterAlive: true) == .failed)
    #expect(TerminalSession.shellExit(exitCode: 130, masterAlive: true) == .failed)
    #expect(TerminalSession.shellExit(exitCode: nil, masterAlive: true) == .failed)
    #expect(TerminalSession.shellExit(exitCode: 0, masterAlive: false) == .connectionLost)
    #expect(TerminalSession.shellExit(exitCode: 1, masterAlive: false) == .connectionLost)
    #expect(TerminalSession.shellExit(exitCode: nil, masterAlive: false) == .connectionLost)
}

/// Stands in for ssh: "connects" at once (creates the control socket path the test left in the
/// file `control` next to it) and stays up until a file `drop` appears there; then it exits
/// the way ssh does when its connection drops.
private let droppableSSH = #"""
for arg in "$@"; do [ "$arg" = "-O" ] && exit 0; done
here=$(dirname "$0")
: > "$(cat "$here/control")"
n=0
while [ ! -e "$here/drop" ] && [ "$n" -lt 600 ]; do sleep 0.05; n=$((n + 1)); done
exit 255
"""#

/// A connected master run by `droppableSSH`, in a temporary directory of its own.
private func stubMaster() async throws -> (master: SSHMasterConnection, runtime: SSHRuntime, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TermiTests-" + SSHRuntime.randomHex(bytes: 3), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let ssh = root.appendingPathComponent("ssh")
    try ("#!/bin/sh\n" + droppableSSH + "\n").write(to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    let runtime = SSHRuntime(askpassExecutable: "/usr/bin/false", sshPath: ssh.path, parentDirectory: root)
    let hop = SSHHop(alias: "termi-h0", displayName: "termi-h0", hostname: "10.0.0.1", username: "root")
    let callbacks = SSHMasterConnection.Callbacks(prompt: { _ in SSHPromptResponse.cancel })
    let master = try SSHMasterConnection(spec: SSHConnectionSpec(hops: [hop]),
                                         runtime: runtime, callbacks: callbacks)
    try master.controlPath.write(to: root.appendingPathComponent("control"), atomically: true, encoding: .utf8)
    try await master.connect()
    return (master, runtime, root)
}

@Test @MainActor func exit255IsAConnectionLossOnceTheMasterIsSeenExiting() async throws {
    let (master, runtime, root) = try await stubMaster()
    defer {
        master.close()
        runtime.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    // The client's exit is reported while the master still looks alive…
    #expect(TerminalSession.shellExit(exitCode: 255, masterAlive: master.isAlive) == .ambiguous)
    // …and the master, gone with the connection, is noticed a moment later.
    FileManager.default.createFile(atPath: root.appendingPathComponent("drop").path, contents: nil)
    let lost = await TerminalSession.masterDies(within: 5) { master.isAlive }
    #expect(lost)
    #expect(TerminalSession.shellExit(exitCode: 255, masterAlive: master.isAlive) == .connectionLost)
}

@Test @MainActor func exit255IsTheShellsOwnStatusWhileTheMasterStaysAlive() async throws {
    let (master, runtime, root) = try await stubMaster()
    defer {
        master.close()
        runtime.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    let lost = await TerminalSession.masterDies(within: 0.3) { master.isAlive }
    #expect(!lost)
    #expect(master.isAlive)

    // A master closed on purpose (Disconnect) is reported at once.
    master.close()
    let closed = await TerminalSession.masterDies(within: 0.3) { master.isAlive }
    #expect(closed)
    #expect(TerminalSession.shellExit(exitCode: 255, masterAlive: master.isAlive) == .connectionLost)
}

@Test @MainActor func watchingTheMasterStopsWhenTheCheckIsCancelled() async {
    // A reconnect or closing the pane cancels the check: it must not sit out the grace period,
    // nor report a loss.
    let started = Date()
    let check = Task { @MainActor in
        await TerminalSession.masterDies(within: 30) { true }
    }
    check.cancel()
    let lost = await check.value
    #expect(!lost)
    #expect(Date().timeIntervalSince(started) < 5)
}

// MARK: - Reconnect back-off

@Test func reconnectDelayDoublesUpToHalfAMinute() {
    let delays = (1...8).map { TerminalSession.reconnectDelay(attempt: $0) }
    #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30])
}

@Test func backOffGrowsWhileEveryNewShellDiesAtOnce() {
    // Models what the session does per round: `processDidTerminate` carries the count over
    // (shell gone within a second), `scheduleReconnect` adds one. This checks the arithmetic
    // only — that `startRemoteShell` no longer resets the count is not covered by a unit test
    // (it needs an injectable SSHService / connection log).
    var attempts = 0
    var delays: [TimeInterval] = []
    for _ in 0..<6 {
        attempts = TerminalSession.attemptsCarriedOver(attempts, shellUptime: 0.5) + 1
        delays.append(TerminalSession.reconnectDelay(attempt: attempts))
    }
    #expect(delays == [1, 2, 4, 8, 16, 30])
}

@Test func backOffStartsOverOnlyAfterAStableSession() {
    let stable = TerminalSession.stableShellUptime
    #expect(TerminalSession.attemptsCarriedOver(5, shellUptime: 0) == 5)
    #expect(TerminalSession.attemptsCarriedOver(5, shellUptime: stable - 0.1) == 5)
    #expect(TerminalSession.attemptsCarriedOver(5, shellUptime: stable) == 0)
    #expect(TerminalSession.attemptsCarriedOver(5, shellUptime: 3600) == 0)
    // A stable session lost again: back to the shortest delay.
    let next = TerminalSession.attemptsCarriedOver(5, shellUptime: 3600) + 1
    #expect(TerminalSession.reconnectDelay(attempt: next) == 1)
}

// MARK: - Terminating the child process

/// True once the process is gone *and* reaped (a zombie still answers `kill(pid, 0)`).
private func processIsGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}

@Test @MainActor func terminateAndReapStopsAnInteractiveShell() async throws {
    let view = BiuTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
    // -f: no startup files, so nothing in the home directory is read or written.
    view.startProcess(executable: "/bin/zsh", args: ["-f", "-i"],
                      environment: ["TERM=xterm-256color", "HOME=/var/empty", "PATH=/usr/bin:/bin"],
                      execName: nil, currentDirectory: "/")
    let pid: pid_t = view.process.shellPid
    let started: Bool = view.process.running
    // Stop here if the shell did not start: pid 0 would address the test runner's own group.
    try #require(pid > 0)
    try #require(started)

    // Let zsh start up: an interactive zsh ignores SIGTERM, which is the case under test.
    try await Task.sleep(nanoseconds: 500_000_000)
    let aliveBefore = !processIsGone(pid)
    #expect(aliveBefore)

    view.terminateAndReap()
    let stillRunning: Bool = view.process.running
    #expect(!stillRunning)

    var gone = false
    for _ in 0..<50 {
        if processIsGone(pid) {
            gone = true
            break
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(gone)
    if !gone {
        kill(pid, SIGKILL)
    }
}

@Test @MainActor func terminateAndReapIgnoresAViewWithoutProcess() {
    let view = BiuTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
    view.terminateAndReap()
    let running: Bool = view.process.running
    #expect(!running)
}
