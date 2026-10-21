import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import Termi

// Integration tests for the SSH engine (against a real sshd) live outside the app test target;
// these cover the pure logic that runs on every connection.

// MARK: - Prompt parsing

@Test func promptParserRecognisesOpenSSHPrompts() {
    #expect(SSHPromptParser.kind(of: "root@termi-h0's password: ") == .password(alias: "termi-h0"))
    #expect(SSHPromptParser.kind(of: "Enter passphrase for key '/tmp/x/k0': ") == .passphrase(keyPath: "/tmp/x/k0"))
    #expect(SSHPromptParser.kind(of: "Enter passphrase for /tmp/x/k0: ") == .passphrase(keyPath: "/tmp/x/k0"))
    #expect(SSHPromptParser.kind(of: "(root@termi-h1) Verification code: ")
            == .keyboardInteractive(alias: "termi-h1", prompt: "Verification code:"))
    #expect(SSHPromptParser.kind(of: "Allow use of key?", hint: "confirm") == .confirmation)
    let hostKey = """
    The authenticity of host 'termi-h0 (10.0.0.1)' can't be established.
    ED25519 key fingerprint is SHA256:abcDEF123+/xyz.
    Are you sure you want to continue connecting (yes/no/[fingerprint])?
    """
    #expect(SSHPromptParser.kind(of: hostKey)
            == .hostKey(alias: "termi-h0", keyType: "ED25519", fingerprint: "SHA256:abcDEF123+/xyz"))
}

@Test func promptParserReadsOpenSSH10Fingerprint() {
    // OpenSSH 10: a colon after "is" and no full stop at the end of the line.
    let hostKey = """
    The authenticity of host 'termi-h0 (10.0.0.1)' can't be established.
    ED25519 key fingerprint is: SHA256:abcDEF123+/xyz
    This key is not known by any other names.
    Are you sure you want to continue connecting (yes/no/[fingerprint])?
    """
    #expect(SSHPromptParser.kind(of: hostKey)
            == .hostKey(alias: "termi-h0", keyType: "ED25519", fingerprint: "SHA256:abcDEF123+/xyz"))
}

// MARK: - Connection spec & config rendering

private func hop(_ alias: String, host: String = "10.0.0.1", port: Int = 22, user: String = "root",
                 credentials: SSHCredentials = SSHCredentials()) -> SSHHop {
    SSHHop(alias: alias, displayName: alias, hostname: host, port: port, username: user, credentials: credentials)
}

@Test func configRendererBuildsJumpChain() {
    let key = SSHCredentials.PrivateKey(keyId: 7, name: "k", pem: "PEM", passphrase: nil)
    let spec = SSHConnectionSpec(hops: [
        hop("termi-h0", credentials: SSHCredentials(password: "x")),
        hop("termi-h1", host: "10.0.0.2", credentials: SSHCredentials(privateKey: key)),
    ], userConfigPath: "/Users/u/.ssh/config")
    let text = SSHConfigRenderer.render(spec, files: .init(knownHostsPath: "/k", controlPath: "/c",
                                                           identityFiles: ["termi-h1": "/key1"]))
    #expect(text.contains("Host termi-h0\n  HostName 10.0.0.1\n  Port 22"))
    #expect(text.contains("  ProxyJump termi-h0"))
    #expect(text.contains("  IdentityFile \"/key1\""))
    #expect(text.contains("  ControlPath \"/c\""))
    #expect(text.contains("  StrictHostKeyChecking ask"))
    #expect(!text.contains("Include "))
}

@Test func hopsBehindAJumpHostGetTimeForItsPrompts() throws {
    var spec = SSHConnectionSpec(hops: [hop("termi-h0"), hop("termi-h1", host: "10.0.0.2")], connectTimeout: 10)
    let files = SSHConfigRenderer.Files(knownHostsPath: "/k", controlPath: "/c")
    let blocks = SSHConfigRenderer.render(spec, files: files).components(separatedBy: "\nHost ")
    try #require(blocks.count == 3)
    // Only the first hop is a plain TCP connect; the next one's timeout keeps running while
    // the user answers the jump host's prompts.
    #expect(blocks[1].contains("  ConnectTimeout 10\n"))
    #expect(blocks[2].contains("  ConnectTimeout 120\n"))
    // A longer timeout chosen by the user is kept.
    spec.connectTimeout = 300
    #expect(!SSHConfigRenderer.render(spec, files: files).contains("ConnectTimeout 120"))
}

@Test func configRendererTurnsUseKeychainOff() {
    let spec = SSHConnectionSpec(hops: [hop("termi-h0")], userConfigPath: "/Users/u/.ssh/config")
    let text = SSHConfigRenderer.render(spec, files: .init(knownHostsPath: "/k", controlPath: "/c"))
    // Ahead of the included user config (the first value ssh reads wins)…
    #expect(text.contains("  UseKeychain no\n"))
    // …and without IgnoreUnknown, which would replace the user's own.
    #expect(!text.contains("IgnoreUnknown"))
}

@Test func knownHostsUseAliases() {
    var first = hop("termi-h0")
    first.knownHostKeys = ["ssh-ed25519 AAAAkey comment"]
    let text = SSHConfigRenderer.knownHosts(for: SSHConnectionSpec(hops: [first]))
    #expect(text == "termi-h0 ssh-ed25519 AAAAkey\n")
    let parsed = SSHConfigRenderer.parseKnownHosts(text + "termi-h1 ssh-rsa BBBB\n")
    #expect(parsed.count == 2)
    #expect(parsed[1].alias == "termi-h1" && parsed[1].key == "ssh-rsa BBBB")
}

@Test func specValidationRejectsInjection() {
    #expect(throws: SSHError.self) {
        try SSHConnectionSpec(hops: [hop("termi-h0", host: "evil\n  ProxyCommand x")]).validate()
    }
    #expect(throws: SSHError.self) {
        try SSHConnectionSpec(hops: [hop("termi-h0", host: "-oProxyCommand=x")]).validate()
    }
    #expect(throws: SSHError.self) {
        try SSHConnectionSpec(hops: [hop("termi-h0", user: "u\"x")]).validate()
    }
    #expect(throws: Never.self) {
        try SSHConnectionSpec(hops: [hop("termi-h0", host: "fe80::1"), hop("termi-h1")]).validate()
    }
}

@Test func specFingerprintChangesWithConnectionParameters() {
    let base = SSHConnectionSpec(hops: [hop("termi-h0")])
    var changedUser = base
    changedUser.hops[0].username = "admin"
    var changedPassword = base
    changedPassword.hops[0].credentials.password = "secret"
    #expect(base.fingerprint != changedUser.fingerprint)
    // Secrets are not part of the identity of a connection.
    #expect(base.fingerprint == changedPassword.fingerprint)
}

@Test func failureClassification() {
    let spec = SSHConnectionSpec(hops: [hop("termi-h0")])
    #expect(SSHMasterConnection.classifyFailure(
        stderr: "ssh: connect to host 10.0.0.1 port 22: Connection refused\n",
        rejectedHostKeyAlias: nil, spec: spec) == .connectionFailed(host: "termi-h0", detail: "Connection refused"))
    #expect(SSHMasterConnection.classifyFailure(stderr: "", rejectedHostKeyAlias: "termi-h0", spec: spec)
            == .hostKeyRejected(host: "termi-h0"))
}

@Test func forwardArguments() {
    #expect(SSHForward(kind: .local, bindPort: 8080, destinationHost: "::1", destinationPort: 80).arguments
            == ["-L", "8080:[::1]:80"])
    #expect(SSHForward(kind: .dynamic, bindPort: 1080).arguments == ["-D", "1080"])
}

// MARK: - Master connection & leases (a shell script stands in for ssh — no network)

/// Collects what `@Sendable` callbacks report.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) {
        lock.withLock { items.append(item) }
    }

    var values: [String] {
        lock.withLock { items }
    }
}

/// "Connects" at once — creates the control socket path named in the config — and stays alive.
private let connectingSSH = #"""
for arg in "$@"; do [ "$arg" = "-O" ] && exit 0; done
control=$(sed -n 's/^  ControlPath "\(.*\)"$/\1/p' "$2" | head -n 1)
: > "$control"
exec sleep 30
"""#

/// Records a new host key, as ssh does once the user accepted it, then fails to log in.
private let rejectingSSH = #"""
known=$(sed -n 's/^  UserKnownHostsFile "\(.*\)"$/\1/p' "$2" | head -n 1)
echo "termi-h0 ssh-ed25519 AAAAnew" >> "$known"
echo "root@termi-h0: Permission denied (publickey,password)." >&2
exit 255
"""#

/// Records a new host key, then waits — like ssh sitting at a password prompt.
private let waitingSSH = #"""
known=$(sed -n 's/^  UserKnownHostsFile "\(.*\)"$/\1/p' "$2" | head -n 1)
echo "termi-h0 ssh-ed25519 AAAAnew" >> "$known"
exec sleep 30
"""#

/// Creates the control socket, records its pid, and stays up — a master nobody closed.
private let lingeringSSH = #"""
for arg in "$@"; do [ "$arg" = "-O" ] && exit 0; done
control=$(sed -n 's/^  ControlPath "\(.*\)"$/\1/p' "$2" | head -n 1)
: > "$control"
echo $$ > "$(dirname "$control")/pid"
exec sleep 60
"""#

/// A runtime in a temporary directory of its own whose "ssh" is the given shell script.
private func stubRuntime(ssh script: String) throws -> (runtime: SSHRuntime, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TermiTests-" + SSHRuntime.randomHex(bytes: 3), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let ssh = root.appendingPathComponent("ssh")
    try ("#!/bin/sh\n" + script + "\n").write(to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    let runtime = SSHRuntime(askpassExecutable: "/usr/bin/false", sshPath: ssh.path, parentDirectory: root)
    return (runtime, root)
}

@Test func hostKeyAcceptedBeforeAFailedLoginIsKept() async throws {
    let (runtime, root) = try stubRuntime(ssh: rejectingSSH)
    defer {
        runtime.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    let trusted = Recorder()
    let callbacks = SSHMasterConnection.Callbacks(
        prompt: { _ in SSHPromptResponse.cancel },
        trustHostKey: { trustedHop, key in trusted.add("\(trustedHop.alias) \(key)") }
    )
    let master = try SSHMasterConnection(spec: SSHConnectionSpec(hops: [hop("termi-h0")]),
                                         runtime: runtime, callbacks: callbacks)
    await #expect(throws: SSHError.self) {
        try await master.connect()
    }
    // ssh has exited and its directory is gone, yet the key it recorded reaches Known Hosts.
    #expect(trusted.values == ["termi-h0 ssh-ed25519 AAAAnew"])
}

@Test func hostKeyAcceptedBeforeACancelledConnectIsKept() async throws {
    let (runtime, root) = try stubRuntime(ssh: waitingSSH)
    defer {
        runtime.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    let trusted = Recorder()
    let callbacks = SSHMasterConnection.Callbacks(
        prompt: { _ in SSHPromptResponse.cancel },
        trustHostKey: { trustedHop, key in
            trusted.add("\(trustedHop.alias) \(key) cancelled=\(Task.isCancelled)")
        }
    )
    let master = try SSHMasterConnection(spec: SSHConnectionSpec(hops: [hop("termi-h0")]),
                                         runtime: runtime, callbacks: callbacks)
    let connecting = Task { try await master.connect() }
    // Wait for "ssh" to record the key, then cancel the attempt (the tab is closed, say).
    var polls = 0
    while (try? String(contentsOfFile: master.knownHostsPath, encoding: .utf8))?.isEmpty != false, polls < 250 {
        try await Task.sleep(nanoseconds: 20_000_000)
        polls += 1
    }
    connecting.cancel()
    await #expect(throws: SSHError.self) {
        try await connecting.value
    }
    // Saved from a task that is not cancelled: the database refuses writes from one that is.
    #expect(trusted.values == ["termi-h0 ssh-ed25519 AAAAnew cancelled=false"])
}

@Test func closingAConnectedMasterReportsItAtOnce() async throws {
    let (runtime, root) = try stubRuntime(ssh: connectingSSH)
    defer {
        runtime.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    let callbacks = SSHMasterConnection.Callbacks(prompt: { _ in SSHPromptResponse.cancel })
    let master = try SSHMasterConnection(spec: SSHConnectionSpec(hops: [hop("termi-h0")]),
                                         runtime: runtime, callbacks: callbacks)
    try await master.connect()
    #expect(master.isAlive)
    let closed = Recorder()
    master.onClose { closed.add("closed") }
    master.close()
    // Not left to the process exit: by then nothing may be holding the master any more.
    #expect(closed.values == ["closed"])
    #expect(!master.isAlive)
}

@Test func staleLeaseDoesNotReleaseTheReplacementMaster() async throws {
    let (runtime, root) = try stubRuntime(ssh: connectingSSH)
    defer {
        runtime.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    let manager = SSHConnectionManager(runtime: runtime, idleTimeoutSeconds: 0.1)
    let spec = SSHConnectionSpec(hops: [hop("termi-h0")])
    let callbacks = SSHMasterConnection.Callbacks(prompt: { _ in SSHPromptResponse.cancel })

    let old = try await manager.acquire(key: "host-1", spec: spec, callbacks: callbacks)
    // The connection drops while something (an SFTP panel, say) still holds its lease…
    old.master.close()
    // …and a reconnect brings up a new master under the same key.
    let current = try await manager.acquire(key: "host-1", spec: spec, callbacks: callbacks)
    #expect(current.master !== old.master)

    old.release()
    try await Task.sleep(nanoseconds: 500_000_000)
    // The old lease must not have made the new master look idle (idle timeout: 0.1 s).
    #expect(current.master.isAlive)

    current.release()
    await manager.shutdown()
}

/// Answer the password prompt of a saved host with `answers` in turn, connect, and return
/// what was then saved to the vault.
private func savedPasswords(answering answers: [SSHPromptResponse]) async throws -> [String] {
    let (runtime, root) = try stubRuntime(ssh: connectingSSH)
    defer {
        runtime.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    let asked = Recorder()
    let saved = Recorder()
    let callbacks = SSHMasterConnection.Callbacks(
        prompt: { _ in
            asked.add("prompt")
            return answers[asked.values.count - 1]
        },
        savePassword: { _, password in saved.add(password) }
    )
    var target = hop("termi-h0")
    target.hostId = 1
    let master = try SSHMasterConnection(spec: SSHConnectionSpec(hops: [target]),
                                         runtime: runtime, callbacks: callbacks)
    for _ in answers {
        _ = await master.answer(AskpassRequest(token: "", prompt: "root@termi-h0's password: ", hint: nil))
    }
    try await master.connect()
    master.close()
    return saved.values
}

@Test func onlyTheLatestPasswordAnswerIsSaved() async throws {
    let kept = try await savedPasswords(answering: [.text("right", save: true)])
    #expect(kept == ["right"])
    // Wrong password with "Save to vault" ticked, then the right one without it.
    let dropped = try await savedPasswords(answering: [.text("wrong", save: true), .text("right", save: false)])
    #expect(dropped.isEmpty)
}

// MARK: - ~/.ssh/config import

@Test func sshConfigParserAppliesDefaultsAndPatterns() {
    let config = """
    Host bastion
        HostName bastion.example.com
        User jump
        IdentityFile ~/.ssh/id_bastion
    Host web-* !web-staging
        User deploy
        ProxyJump bastion
    Host web-1
        HostName %h.internal
        LocalForward 8080 localhost:80
    Host *
        User fallback
    """
    let entries = SSHConfigParser.parse(config, homeDirectory: "/Users/u", localUser: "me", readFile: { _ in nil })
    #expect(entries.map(\.alias) == ["bastion", "web-1"])
    #expect(entries[0].user == "jump")
    #expect(entries[0].identityFiles == ["/Users/u/.ssh/id_bastion"])
    #expect(entries[1].resolvedHostName == "web-1.internal")
    #expect(entries[1].user == "deploy")
    #expect(entries[1].proxyJump == "bastion")
    #expect(entries[1].localForwards.first?.bindPort == 8080)
}

@Test func proxyJumpHopsParsing() {
    let hops = SSHConfigParser.proxyJumpHops("alice@gw:2222,inner")
    #expect(hops.count == 2)
    #expect(hops[0].user == "alice" && hops[0].host == "gw" && hops[0].port == 2222)
    #expect(hops[1].host == "inner" && hops[1].user == nil)
}

// MARK: - Quick connect & snippets

@Test func quickConnectParser() {
    let host = QuickConnectParser.parse("deploy@web.example.com:2222")
    #expect(host?.username == "deploy")
    #expect(host?.hostname == "web.example.com")
    #expect(host?.port == 2222)
    #expect(QuickConnectParser.parse("root@[fe80::1]:22")?.hostname == "fe80::1")
    #expect(QuickConnectParser.parse("bad host") == nil)
    #expect(QuickConnectParser.parse("root@-oProxyCommand=x") == nil)
}

@Test func snippetTemplates() {
    let command = "tail -n {{lines}} {{ file }}"
    #expect(SnippetTemplate.placeholders(in: command) == ["lines", "file"])
    #expect(SnippetTemplate.render(command, values: ["lines": "50", "file": "/var/log/syslog"])
            == "tail -n 50 /var/log/syslog")
}

// MARK: - Panes

@Test func paneLayoutInsertAndRemove() {
    let a = UUID(), b = UUID(), c = UUID()
    var layout = PaneLayout.pane(a)
    layout = layout.inserting(b, nextTo: a, axis: .horizontal)
    #expect(layout == .split(.horizontal, [.pane(a), .pane(b)]))
    // Same axis: becomes a sibling instead of nesting.
    layout = layout.inserting(c, nextTo: a, axis: .horizontal)
    #expect(layout == .split(.horizontal, [.pane(a), .pane(c), .pane(b)]))
    #expect(layout.paneIds == [a, c, b])
    #expect(layout.removing(c)?.removing(b) == .pane(a))
    #expect(PaneLayout.pane(a).removing(a) == nil)
}

@Test @MainActor func splitAndClosePanes() {
    let vm = AppViewModel()
    vm.addSSHTab(title: "web", hostId: 7)
    vm.splitFocusedPane(.horizontal)
    vm.splitFocusedPane(.vertical)

    #expect(vm.tabs.count == 1)
    #expect(vm.tabs[0].panes.count == 3)
    #expect(vm.tabs[0].panes.allSatisfy { $0.hostId == 7 && $0.isSSH })
    let focused = vm.tabs[0].focusedPaneId
    #expect(vm.tabs[0].panes.last?.id == focused)

    vm.closePane(focused)
    #expect(vm.tabs[0].panes.count == 2)
    #expect(vm.tabs[0].layout.paneIds.count == 2)

    vm.closeFocusedPane()
    vm.closeFocusedPane()
    #expect(vm.tabs.isEmpty)
}

// A password that was rejected once used to head the first terminal of the session.
@Test func bannerLeavesOutTheRetryNotices() {
    let stderr = """
    Permission denied, please try again.
    Warning: Permanently added '[127.0.0.1]:2222' (ED25519) to the list of known hosts.
    Authorized use only.
    Permission denied, please try again.
    """
    #expect(SSHMasterConnection.bannerText(stderr) == "Authorized use only.")
    #expect(SSHMasterConnection.bannerText("Permission denied, please try again.\n") == "")
    // The failure path still sees the notice: it is how a wrong password is told from a refusal.
    #expect(SSHMasterConnection.informationalOutput(stderr).contains(SSHMasterConnection.retryNotice))
}

// "Could not connect to x: Connection refused" in a Chinese sentence: the reasons ssh gives for a
// connection that could not be made are said in the interface language; diagnostics stay as they are.
@Test func connectionFailureGivesItsReasonInTheInterfaceLanguage() {
    func text(_ detail: String) -> String {
        SSHError.connectionFailed(host: "web", detail: detail).errorDescription ?? ""
    }
    let refused = String(localized: "Connection refused")
    #expect(text("Connection refused") == String(localized: "Could not connect to \("web"): \(refused)"))
    let unresolved = String(localized: "The host name could not be resolved")
    #expect(text("Could not resolve hostname nowhere.invalid: nodename nor servname provided") ==
        String(localized: "Could not connect to \("web"): \(unresolved)"))
    #expect(text("kex_exchange_identification: read: Connection reset by peer").hasSuffix("Connection reset by peer"))
    #expect(text("") == String(localized: "Could not connect to \("web")."))
}

@Test @MainActor func promptTextNamesTheOriginOnceAndTranslatesTheRetryNotice() {
    #expect(AuthPromptPresenter.informativeText(origin: "web (root@10.0.0.5)", details: nil) == "web (root@10.0.0.5)")
    #expect(AuthPromptPresenter.informativeText(origin: nil, details: nil) == "")

    let retry = AuthPromptPresenter.informativeText(origin: nil, details: "Permission denied, please try again.")
    #expect(retry == String(localized: "That was not accepted. Try again."))

    // What the server wrote is shown as it came, under the origin.
    let banner = AuthPromptPresenter.informativeText(origin: "root@10.0.0.5", details: "Enter the code from your token.")
    #expect(banner == "root@10.0.0.5\n\nEnter the code from your token.")
}

@Test func paneLayoutNeighbourIsTheSiblingThatTakesOver() {
    let left = UUID(), top = UUID(), bottom = UUID()
    // left | (top / bottom)
    let nested = PaneLayout.split(.horizontal, [.pane(left), .split(.vertical, [.pane(top), .pane(bottom)])])
    #expect(nested.neighbor(of: bottom) == top)
    #expect(nested.neighbor(of: top) == bottom)
    #expect(nested.neighbor(of: left) == top)

    let a = UUID(), b = UUID(), c = UUID()
    let row = PaneLayout.split(.horizontal, [.pane(a), .pane(b), .pane(c)])
    #expect(row.neighbor(of: a) == b)
    #expect(row.neighbor(of: b) == c)
    #expect(row.neighbor(of: c) == b)
    // (a / b) | c: closing b leaves its space to a, not to the pane across the other split.
    let stacked = PaneLayout.split(.horizontal, [.split(.vertical, [.pane(a), .pane(b)]), .pane(c)])
    #expect(stacked.neighbor(of: b) == a)
    #expect(stacked.neighbor(of: c) == b)

    #expect(PaneLayout.pane(a).neighbor(of: a) == nil)
    #expect(row.neighbor(of: UUID()) == nil)
}

// Closing the bottom-right pane used to send the keyboard to the first pane of the tab.
@Test @MainActor func closingAPaneFocusesItsNeighbour() throws {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    let left = vm.tabs[0].focusedPaneId
    vm.splitFocusedPane(.horizontal)
    let top = vm.tabs[0].focusedPaneId
    vm.splitFocusedPane(.vertical)
    let bottom = vm.tabs[0].focusedPaneId
    #expect(vm.tabs[0].layout == .split(.horizontal, [.pane(left), .split(.vertical, [.pane(top), .pane(bottom)])]))

    vm.closePane(bottom)
    #expect(vm.tabs[0].focusedPaneId == top)

    // Closing a pane that is not focused leaves the focus where it is.
    vm.closePane(left)
    #expect(vm.tabs[0].focusedPaneId == top)
    #expect(vm.tabs[0].layout == .pane(top))
}

// The view of a closed pane is evaluated once more on its way out; asking for its session
// then used to create a new one that nothing ever closed.
@Test @MainActor func aClosedPaneGetsNoNewSession() throws {
    let vm = AppViewModel()
    vm.addLocalTerminalTab()
    vm.splitFocusedPane(.horizontal)
    let closed = try #require(vm.tabs[0].panes.last)
    let kept = try #require(vm.tabs[0].panes.first)
    #expect(vm.session(for: closed) != nil)

    vm.closePane(closed.id)
    #expect(vm.session(for: closed) == nil)
    #expect(vm.existingSession(for: closed.id) == nil)
    #expect(vm.session(for: kept) != nil)
}

@Test @MainActor func broadcastToggleRequiresTab() {
    let vm = AppViewModel()
    vm.toggleBroadcast()  // no tab: no crash
    vm.addLocalTerminalTab()
    vm.splitFocusedPane(.horizontal)
    vm.toggleBroadcast()
    #expect(vm.activeTab?.broadcastInput == true)
}

@Test @MainActor func duplicateTabCopiesFocusedPane() {
    let vm = AppViewModel()
    vm.addSSHTab(title: "db", hostId: 3)
    let original = vm.tabs[0].id
    vm.duplicateTab(original)
    #expect(vm.tabs.count == 2)
    #expect(vm.tabs[1].hostId == 3)
    #expect(vm.tabs[1].title == "db")
    #expect(vm.activeTabId == vm.tabs[1].id)
}

// MARK: - 2026-10-11 review regressions

@Test func realHostConfigOptionsSurviveInternalAliasesWithoutImportingAuthOrCommands() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Termi-SSH-Config-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let included = root.appendingPathComponent("algorithms")
    try """
    Host legacy.example
        Ciphers aes256-ctr
        User unsafe-user
        IdentityFile /tmp/unsafe-key
        StrictHostKeyChecking no
        LocalForward 18765 localhost:22
    Host *.example !excluded.example
        MACs hmac-sha2-256
    Host bastion.example
        Ciphers aes128-ctr
    """.write(to: included, atomically: true, encoding: .utf8)
    let userConfig = root.appendingPathComponent("user-config")
    try "Include \"\(included.path)\"\n".write(to: userConfig, atomically: true, encoding: .utf8)
    let spec = SSHConnectionSpec(hops: [hop("termi-h0", host: "bastion.example"),
                                         hop("termi-h1", host: "legacy.example", user: "deploy")],
                                 userConfigPath: userConfig.path)
    let resolved = try await SSHConfigRenderer.resolvingUserOptions(in: spec)
    #expect(resolved.hops[0].userOptions["ciphers"] == "aes128-ctr")
    #expect(resolved.hops[1].userOptions["ciphers"] == "aes256-ctr")
    #expect(resolved.hops[1].userOptions["macs"] == "hmac-sha2-256")
    #expect(resolved.hops[1].userOptions["identityfile"] == nil)
    #expect(resolved.hops[1].userOptions["localforward"] == nil)
    let generated = root.appendingPathComponent("generated")
    let text = SSHConfigRenderer.render(resolved, files: .init(knownHostsPath: "/k", controlPath: "/c"))
    try text.write(to: generated, atomically: true, encoding: .utf8)
    let result = try await ProcessRunner.run("/usr/bin/ssh", arguments: ["-G", "-F", generated.path, "termi-h1"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("ciphers aes256-ctr\n"))
    #expect(result.stdout.contains("user deploy\n"))
    #expect(result.stdout.contains("proxyjump termi-h0\n"))
    #expect(result.stdout.contains("stricthostkeychecking ask\n"))
    #expect(!result.stdout.contains("unsafe-key"))
    #expect(!result.stdout.contains("18765"))
    var changed = resolved
    changed.hops[1].userOptions["ciphers"] = "aes128-ctr"
    #expect(changed.fingerprint != resolved.fingerprint)
}

@Test func cancellingEverySharedWaiterStopsConnectionAndReturnsPromptly() async throws {
    let (runtime, root) = try stubRuntime(ssh: waitingSSH)
    defer { runtime.shutdown(); try? FileManager.default.removeItem(at: root) }
    let manager = SSHConnectionManager(runtime: runtime)
    let spec = SSHConnectionSpec(hops: [hop("termi-h0")])
    let callbacks = SSHMasterConnection.Callbacks(prompt: { _ in .cancel })
    let finished = Recorder()
    let first = Task {
        do { let lease = try await manager.acquire(key: "cancel-both", spec: spec, callbacks: callbacks); lease.release() }
        catch { finished.add("first") }
    }
    let second = Task {
        do { let lease = try await manager.acquire(key: "cancel-both", spec: spec, callbacks: callbacks); lease.release() }
        catch { finished.add("second") }
    }
    try await Task.sleep(nanoseconds: 200_000_000)
    first.cancel()
    second.cancel()
    for _ in 0..<100 where finished.values.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
    let countBeforeShutdown = finished.values.count
    // Always clean up before awaiting the callers, including when this regression fails.
    await manager.shutdown()
    await first.value
    await second.value
    #expect(countBeforeShutdown == 2)
}

@Test func cancellingOneSharedWaiterReturnsWithoutCancellingTheOther() async throws {
    let delayedSSH = #"""
    for arg in "$@"; do [ "$arg" = "-O" ] && exit 0; done
    control=$(sed -n 's/^  ControlPath "\(.*\)"$/\1/p' "$2" | head -n 1)
    : > "$0.started"
    while [ ! -f "$0.ready" ]; do sleep 0.02; done
    : > "$control"
    exec sleep 30
    """#
    let (runtime, root) = try stubRuntime(ssh: delayedSSH)
    defer { runtime.shutdown(); try? FileManager.default.removeItem(at: root) }
    let manager = SSHConnectionManager(runtime: runtime)
    let spec = SSHConnectionSpec(hops: [hop("termi-h0")])
    let callbacks = SSHMasterConnection.Callbacks(prompt: { _ in .cancel })
    let finished = Recorder()
    let first = Task {
        do { let lease = try await manager.acquire(key: "cancel-one", spec: spec, callbacks: callbacks); lease.release() }
        catch { finished.add("cancelled") }
    }
    let second = Task { try await manager.acquire(key: "cancel-one", spec: spec, callbacks: callbacks) }
    let started = root.appendingPathComponent("ssh.started")
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: started.path) {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    first.cancel()
    for _ in 0..<100 where finished.values.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
    let cancelledWhileOtherStillConnecting = !finished.values.isEmpty
    try Data().write(to: root.appendingPathComponent("ssh.ready"))
    let lease = try await second.value
    #expect(cancelledWhileOtherStillConnecting)
    #expect(lease.master.isAlive)
    await first.value
    lease.release()
    await manager.shutdown()
}

@Test func explicitAgentSkipsGroupIdentityAndSavedPasswordOverridesOnlyItsHost() async throws {
    let identityPassword = try await SecureStoreService.shared.encryptStoredValue("identity-old")
    let identity = try await IdentityRepository.shared.save(Identity(name: "ssh-review-\(UUID())", username: "root",
        authType: "password", passwordEncrypted: identityPassword, createdAt: ""))
    let identityId = try #require(identity.id)
    let group = try await GroupRepository.shared.save(HostGroup(name: "ssh-review-\(UUID())", sortOrder: 0,
        createdAt: "", username: "fallback", identityId: identityId))
    let groupId = try #require(group.id)
    var host = Host.defaultValue()
    host.hostname = "fixture.invalid"
    host.username = "deploy"
    host.authType = "agent"
    host.groupId = groupId
    host = try await HostRepository.shared.save(host)
    let hostId = try #require(host.id)
    let service = SSHService()
    let agent = try await service.hop(for: host, alias: "termi-h0", passwordOverride: nil, isTarget: true)
    #expect(agent.username == "deploy")
    #expect(agent.credentials.useSystemAgent)
    #expect(agent.credentials.password == nil)
    #expect(agent.credentials.privateKey == nil)

    host.authType = "password"
    let inherited = try await service.hop(for: host, alias: "termi-h0", passwordOverride: nil, isTarget: true)
    #expect(inherited.username == "root")
    #expect(inherited.credentials.password == "identity-old")
    #expect(inherited.hostId == nil)
    host.identityId = identityId
    let before = try await service.hop(for: host, alias: "termi-h0", passwordOverride: nil, isTarget: true)
    #expect(before.hostId == hostId)
    // This is the real callback used by a successful prompt, then a fresh credential resolution.
    await SSHService.callbacks.savePassword(hostId, "host-new")
    let after = try await service.hop(for: host, alias: "termi-h0", passwordOverride: nil, isTarget: true)
    #expect(after.credentials.password == "host-new")
    #expect(after.username == "root")
    let oneOff = try await service.hop(for: host, alias: "termi-h0", passwordOverride: "one-off", isTarget: true)
    #expect(oneOff.credentials.password == "one-off")
    var sibling = host
    sibling.id = nil
    let sharedIdentityOnAnotherHost = try await service.hop(for: sibling, alias: "termi-h0", passwordOverride: nil, isTarget: true)
    #expect(sharedIdentityOnAnotherHost.credentials.password == "identity-old")
    let unchangedIdentity = try await IdentityRepository.shared.fetch(id: identityId)
    #expect(unchangedIdentity?.passwordEncrypted == identityPassword)

    try await SecureStoreService.shared.deleteHostPassword(hostId: hostId)
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
    try await GroupRepository.shared.delete(id: groupId)
    try await IdentityRepository.shared.delete(id: identityId)
}

@Test func importedConfigAliasSurvivesRenamingWhileEndpointStaysFixed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Termi-SSH-Alias-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config")
    try """
    Host legacy
        HostName 10.0.0.8
        Ciphers aes256-ctr
        User ignored-user
        Port 9922
    """.write(to: config, atomically: true, encoding: .utf8)
    var target = hop("termi-h0", host: "10.0.0.8", port: 2222, user: "deploy")
    target.displayName = "Renamed by user"
    target.userConfigAlias = "legacy"
    let resolved = try await SSHConfigRenderer.resolvingUserOptions(in: SSHConnectionSpec(hops: [target], userConfigPath: config.path))
    #expect(resolved.target.userOptions["ciphers"] == "aes256-ctr")
    let generated = root.appendingPathComponent("generated")
    try SSHConfigRenderer.render(resolved, files: .init(knownHostsPath: "/k", controlPath: "/c"))
        .write(to: generated, atomically: true, encoding: .utf8)
    let result = try await ProcessRunner.run("/usr/bin/ssh", arguments: ["-G", "-F", generated.path, "termi-h0"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("ciphers aes256-ctr\n"))
    #expect(result.stdout.contains("hostname 10.0.0.8\n"))
    #expect(result.stdout.contains("user deploy\n"))
    #expect(result.stdout.contains("port 2222\n"))
}

@Test @MainActor func switchingIdentityClearsOldHostOverrideAndKeepsLaterPromptOverrideScoped() async throws {
    let identityPassword = try await SecureStoreService.shared.encryptStoredValue("identity-B")
    let identity = try await IdentityRepository.shared.save(Identity(name: "new-login-\(UUID())", username: "user-B",
        authType: "password", passwordEncrypted: identityPassword, createdAt: ""))
    let identityId = try #require(identity.id)
    var host = Host.defaultValue()
    host.hostname = "password-context.invalid"
    host.username = "user-A"
    host = try await HostRepository.shared.save(host)
    let hostId = try #require(host.id)
    try await SecureStoreService.shared.setHostPassword("host-A", hostId: hostId)
    host.identityId = identityId
    host.username = ""
    let result = await HostsViewModel.store(HostDraft(host: host, portForwards: [], tags: [], passwordChange: .keep))
    #expect(result.failure == nil)
    let oldOverride = try await SecureStoreService.shared.getHostPassword(hostId: hostId)
    #expect(oldOverride == nil)
    let resolved = try await SSHService().hop(for: host, alias: "termi-h0", passwordOverride: nil, isTarget: true)
    #expect(resolved.username == "user-B")
    #expect(resolved.credentials.password == "identity-B")

    try await SecureStoreService.shared.setHostPassword("prompt-B-new", hostId: hostId)
    host.label = "A harmless rename"
    host.notes = "Harmless notes"
    _ = try await HostRepository.shared.save(host)
    let retained = try await SecureStoreService.shared.getHostPassword(hostId: hostId)
    #expect(retained == "prompt-B-new")
    // The clear control remains meaningful while an explicit identity is selected.
    let cleared = await HostsViewModel.store(HostDraft(host: host, portForwards: [], tags: [], passwordChange: .clear))
    #expect(cleared.failure == nil)
    let removed = try await SecureStoreService.shared.getHostPassword(hostId: hostId)
    #expect(removed == nil)
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
    try await IdentityRepository.shared.delete(id: identityId)
}

@Test func changingHostEndpointOrUsernameDiscardsPreviousPassword() async throws {
    var host = Host.defaultValue()
    host.hostname = "initial.invalid"
    host = try await HostRepository.shared.save(host)
    let hostId = try #require(host.id)
    for field in ["hostname", "port", "username"] {
        try await SecureStoreService.shared.setHostPassword("old-context", hostId: hostId)
        switch field {
        case "hostname": host.hostname = "next.invalid"
        case "port": host.port = 2222
        default: host.username = "next-user"
        }
        host = try await HostRepository.shared.save(host)
        let previousPassword = try await SecureStoreService.shared.getHostPassword(hostId: hostId)
        #expect(previousPassword == nil)
    }
    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
}

// MARK: - Saved passwords belong to the login they were typed for (review 2026-10-11)

// An identity edited in place moves the login of every host that signs in with it: a saved host
// password typed for the old account must not answer for the new one. Its name and its own
// shared secret are not logins: the override survives them.
@Test func editingTheIdentityInPlaceForgetsOrKeepsHostOverrides() async throws {
    let identityPassword = try await SecureStoreService.shared.encryptStoredValue("identity-old")
    var identity = Identity(name: "in-place-\(UUID())", username: "deploy", authType: "password",
                            passwordEncrypted: identityPassword, createdAt: "")
    identity = try await IdentityRepository.shared.save(identity)
    let identityId = try #require(identity.id)
    var host = Host.defaultValue()
    host.hostname = "identity-edit.invalid"
    host.identityId = identityId
    host = try await HostRepository.shared.save(host)
    let hostId = try #require(host.id)

    try await SecureStoreService.shared.setHostPassword("override", hostId: hostId)
    identity.username = "root"
    _ = try await IdentityRepository.shared.save(identity)
    let afterAccountChange = try await SecureStoreService.shared.getHostPassword(hostId: hostId)
    #expect(afterAccountChange == nil)

    try await SecureStoreService.shared.setHostPassword("override", hostId: hostId)
    identity.passwordEncrypted = try await SecureStoreService.shared.encryptStoredValue("identity-new")
    _ = try await IdentityRepository.shared.save(identity)
    // Only the identity's shared secret changed; the override is this host's own and stays.
    let afterSharedSecretChange = try await SecureStoreService.shared.getHostPassword(hostId: hostId)
    #expect(afterSharedSecretChange == "override")

    identity.name = "renamed in place"
    _ = try await IdentityRepository.shared.save(identity)
    let afterRename = try await SecureStoreService.shared.getHostPassword(hostId: hostId)
    #expect(afterRename == "override")

    // The system agent is another credential; the password does not follow it.
    identity.authType = "agent"
    _ = try await IdentityRepository.shared.save(identity)
    let afterAgentSwitch = try await SecureStoreService.shared.getHostPassword(hostId: hostId)
    #expect(afterAgentSwitch == nil)

    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
    try await IdentityRepository.shared.delete(id: identityId)
}

// Notes, labels, and moves between groups that bring no identity change no login. The form
// normalizes the typed username away while the identity still signs in as the same account. The
// saved password belongs to that login and survives all of it.
@Test func harmlessEditsKeepTheSavedHostPassword() async throws {
    let identityPassword = try await SecureStoreService.shared.encryptStoredValue("identity-pw")
    let identity = try await IdentityRepository.shared.save(Identity(name: "harmless-\(UUID())", username: "deploy",
        authType: "password", passwordEncrypted: identityPassword, createdAt: ""))
    let identityId = try #require(identity.id)
    var host = Host.defaultValue()
    host.hostname = "harmless.invalid"
    host.identityId = identityId
    host = try await HostRepository.shared.save(host)
    let hostId = try #require(host.id)
    try await SecureStoreService.shared.setHostPassword("override", hostId: hostId)

    host.notes = "just a note"
    host.label = "A harmless rename"
    _ = try await HostRepository.shared.save(host)
    #expect(try await SecureStoreService.shared.getHostPassword(hostId: hostId) == "override")

    host.username = "  "
    _ = try await HostRepository.shared.save(host)
    #expect(try await SecureStoreService.shared.getHostPassword(hostId: hostId) == "override")

    let plainA = try await GroupRepository.shared.save(HostGroup(name: "harmless-a-\(UUID())", sortOrder: 0, createdAt: ""))
    let plainB = try await GroupRepository.shared.save(HostGroup(name: "harmless-b-\(UUID())", sortOrder: 1, createdAt: ""))
    host.groupId = try #require(plainA.id)
    _ = try await HostRepository.shared.save(host)
    host.groupId = try #require(plainB.id)
    _ = try await HostRepository.shared.save(host)
    #expect(try await SecureStoreService.shared.getHostPassword(hostId: hostId) == "override")

    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
    if let a = plainA.id { try await GroupRepository.shared.delete(id: a) }
    if let b = plainB.id { try await GroupRepository.shared.delete(id: b) }
    try await IdentityRepository.shared.delete(id: identityId)
}

// Saving with .keep refuses a change that would hand the host to its group's identity — another
// account nobody chose here. Forgetting the password is the decision the save waits for.
@Test @MainActor func keepingThePasswordRefusesAGroupIdentityTakeover() async throws {
    let identity = try await IdentityRepository.shared.save(Identity(name: "takeover-\(UUID())", username: "group-login",
        authType: "password", createdAt: ""))
    let identityId = try #require(identity.id)
    let group = try await GroupRepository.shared.save(HostGroup(name: "takeover-\(UUID())", sortOrder: 0, createdAt: "",
        username: "group-login", identityId: identityId))
    let groupId = try #require(group.id)
    var host = Host.defaultValue()
    host.hostname = "takeover.invalid"
    host.username = "own-login"
    host = try await HostRepository.shared.save(host)
    let hostId = try #require(host.id)
    try await SecureStoreService.shared.setHostPassword("own-password", hostId: hostId)

    // The edit clears the host's own account while the group brings an identity: without the
    // saved password the group's identity would take the login over.
    host.username = ""
    host.groupId = groupId
    let refused = await HostsViewModel.store(HostDraft(host: host, portForwards: [], tags: [], passwordChange: .keep))
    #expect(refused.failure != nil)
    #expect(try await SecureStoreService.shared.getHostPassword(hostId: hostId) == "own-password")

    let decided = await HostsViewModel.store(HostDraft(host: host, portForwards: [], tags: [], passwordChange: .clear))
    #expect(decided.failure == nil)
    #expect(try await SecureStoreService.shared.getHostPassword(hostId: hostId) == nil)

    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
    try await GroupRepository.shared.delete(id: groupId)
    try await IdentityRepository.shared.delete(id: identityId)
}

// A password answer that comes back after the login changed (the prompt was open while the host
// was edited) is refused: it must not land under the account it was not typed for.
@Test func aPromptAnswerForTheOldLoginIsRefusedAfterTheLoginChanged() async throws {
    var host = Host.defaultValue()
    host.hostname = "late-answer.invalid"
    host.username = "deploy"
    host = try await HostRepository.shared.save(host)
    let hostId = try #require(host.id)
    // What the connection's prompt captured.
    let captured = SSHPasswordContext(hostname: host.hostname, port: host.port, username: "deploy",
                                      identityId: nil, usesSystemAgent: false, privateKeyId: nil)

    try await SecureStoreService.shared.setHostPassword("answer", hostId: hostId, expectedContext: captured)
    #expect(try await SecureStoreService.shared.getHostPassword(hostId: hostId) == "answer")

    host.username = "root"
    host = try await HostRepository.shared.save(host) // the change drops the password with the old login
    await #expect {
        try await SecureStoreService.shared.setHostPassword("late", hostId: hostId, expectedContext: captured)
    } throws: { $0 is CancellationError }
    #expect(try await SecureStoreService.shared.getHostPassword(hostId: hostId) == nil)

    var current = captured
    current.username = "root"
    try await SecureStoreService.shared.setHostPassword("fresh", hostId: hostId, expectedContext: current)
    #expect(try await SecureStoreService.shared.getHostPassword(hostId: hostId) == "fresh")

    try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: hostId)
}

@Test func droppingAMasterStopsItsSSH() async throws {
    let (runtime, root) = try stubRuntime(ssh: lingeringSSH)
    defer {
        runtime.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    var leaked: Int32 = 0
    defer { if leaked > 0, SSHRuntime.isProcessAlive(leaked) { kill(leaked, SIGKILL) } }

    let callbacks = SSHMasterConnection.Callbacks(prompt: { _ in SSHPromptResponse.cancel })
    var master: SSHMasterConnection? = try SSHMasterConnection(
        spec: SSHConnectionSpec(hops: [hop("termi-h0")]), runtime: runtime, callbacks: callbacks)
    try await master?.connect()
    let directory = try #require(master).directory
    let pidURL = directory.appendingPathComponent("pid")
    var polls = 0
    while !FileManager.default.fileExists(atPath: pidURL.path), polls < 50 {
        try await Task.sleep(nanoseconds: 20_000_000)
        polls += 1
    }
    let text = try String(contentsOf: pidURL, encoding: .utf8)
    let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    leaked = pid
    #expect(SSHRuntime.isProcessAlive(pid))
    master = nil
    polls = 0
    while SSHRuntime.isProcessAlive(pid), polls < 40 {
        try await Task.sleep(nanoseconds: 50_000_000)
        polls += 1
    }
    #expect(!SSHRuntime.isProcessAlive(pid))
}

@Test func staleControlSocketCleanupDoesNotWaitOnAHungSSH() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-Stale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    var dead: Int32 = 200_000
    while dead < 2_000_000, SSHRuntime.isProcessAlive(dead) { dead += 1 }
    let runtimeDir = parent.appendingPathComponent("bmt-\(dead)")
    let connection = runtimeDir.appendingPathComponent("c1")
    try FileManager.default.createDirectory(at: connection, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: connection.appendingPathComponent("s").path, contents: Data())

    let pidFile = parent.appendingPathComponent("child.pid")
    let ssh = parent.appendingPathComponent("ssh")
    // The shebang has to be the first bytes of the file. `exec` keeps this pid, so the signal
    // hits the sleep itself and does not leave a grandchild behind.
    try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 30\n"
        .write(to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)

    let started = Date()
    SSHRuntime.cleanupStaleDirectories(in: parent, sshPath: ssh.path, exitTimeout: 0.3)
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(!FileManager.default.fileExists(atPath: runtimeDir.path))
    let text = try String(contentsOf: pidFile, encoding: .utf8)
    let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { if SSHRuntime.isProcessAlive(pid) { kill(pid, SIGKILL) } }
    #expect(!SSHRuntime.isProcessAlive(pid))
}
