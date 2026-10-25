import Testing
import Foundation
import UniformTypeIdentifiers
@testable import Termi

// SFTP transfer behaviour that needs no SSH server: local-side checks, plus downloads from the
// system's sftp-server binary speaking the protocol over pipes (no network, no login).

/// A folder of its own in the temporary directory; the caller removes it.
private func sftpScratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("TermiTests-sftp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A client connected to a local sftp-server process started in `folder`; nil where the system
/// has no sftp-server.
private func sftpLocalClient(startingIn folder: URL, umask: String? = nil) async throws -> SFTPClient? {
    let server = "/usr/libexec/sftp-server"
    guard FileManager.default.isExecutableFile(atPath: server) else { return nil }
    let arguments = ["-d", folder.path] + (umask.map { ["-u", $0] } ?? [])
    let client = SFTPClient(executable: server, arguments: arguments, environment: [:])
    // Safety net: a server that stops answering fails the test instead of hanging the run.
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak client] in client?.close() }
    try await client.connect()
    return client
}

/// Stands in for the Trash: moves the file into `folder`, so that no test touches the real one.
private func scratchTrash(_ folder: URL) -> @Sendable (URL) throws -> URL {
    { url in
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let trashed = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: trashed)
        return trashed
    }
}

@Test func sftpCancelledUploadKeepsExistingRemoteFile() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("source")
    let destination = scratch.appendingPathComponent("destination")
    let original = Data("keep the original".utf8)
    try Data(repeating: 65, count: 4_000_000).write(to: source)
    try original.write(to: destination)
    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    let upload = Task {
        try await client.upload(source, to: destination.path) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    await #expect(throws: (any Error).self) { _ = try await upload.value }
    let after = try Data(contentsOf: destination)
    #expect(after == original)
    let names = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
    #expect(Set(names) == ["source", "destination"])
}

@Test func sftpUploadReplacesAtomicallyAndPreservesRemoteModeAndOwner() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("source")
    let destination = scratch.appendingPathComponent("destination")
    let payload = Data("new contents".utf8)
    try payload.write(to: source)
    try Data("old".utf8).write(to: destination)
    try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: destination.path)
    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    let before = try await client.lstat(destination.path)
    _ = try await client.upload(source, to: destination.path, permissions: 0o644)
    let after = try await client.lstat(destination.path)
    #expect(after.permissions == before.permissions)
    #expect(after.uid == before.uid)
    #expect(after.gid == before.gid)
    let uploaded = try Data(contentsOf: destination)
    #expect(uploaded == payload)
    let names = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
    #expect(Set(names) == ["source", "destination"])
}

@Test(arguments: ["077", "022"])
func sftpNewUploadRespectsTheServerCreationMask(umask: String) async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("source")
    let destination = scratch.appendingPathComponent("new-file")
    try Data("new content".utf8).write(to: source)
    guard let client = try await sftpLocalClient(startingIn: scratch, umask: umask) else { return }
    defer { client.close() }
    _ = try await client.upload(source, to: destination.path, permissions: 0o644)
    let attributes = try await client.lstat(destination.path)
    let actual = attributes.permissions.map { $0 & 0o7777 }
    let expected: UInt32 = umask == "077" ? 0o600 : 0o644
    #expect(actual == expected)
    let names = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
    #expect(Set(names) == ["source", "new-file"])
}

@Test func sftpPublicationFailureNeverClosesAnUploadHandleTwice() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("source")
    try Data("new".utf8).write(to: source)
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else { return }
    // A server that advertises posix-rename and denies the publishing rename. (The real
    // /usr/libexec/sftp-server no longer advertises an extension denied with -P, so against it
    // the client stops before staging anything and this scenario cannot be built.) The property
    // under test is the client's: after the denied rename the already-closed staging handle is
    // never CLOSED again.
    let script = scratch.appendingPathComponent("deny-rename-server.pl")
    try """
    use strict; use warnings;
    binmode(STDIN); binmode(STDOUT);
    my $log = shift @ARGV;
    sub note { my ($line) = @_; open(my $fh, '>>', $log); binmode($fh); print $fh $line . "\\n"; close($fh); }
    sub rd { my ($n) = @_; my $buf = '';
      while (length($buf) < $n) { my $r = sysread(STDIN, $buf, $n - length($buf), length($buf)); exit 0 unless $r; }
      return $buf; }
    sub str { my ($s) = @_; return pack('N', length($s)) . $s; }
    sub reply { my ($body) = @_; syswrite(STDOUT, pack('N', length($body)) . $body); }
    sub status { my ($id, $code) = @_; reply(pack('CNN', 101, $id, $code) . str('') . str('')); }
    sub take { my ($ref) = @_; my $len = unpack('N', substr($$ref, 0, 4));
      my $s = substr($$ref, 4, $len); $$ref = substr($$ref, 4 + $len); return $s; }
    sub attrs { return pack('NN', 0x4, 0100644); }
    while (1) {
      my $len = unpack('N', rd(4));
      my $p = rd($len);
      my $type = unpack('C', substr($p, 0, 1));
      if ($type == 1) { reply(pack('CN', 2, 3) . str('posix-rename@openssh.com') . str('1')); next; }
      my $id = unpack('N', substr($p, 1, 4));
      my $rest = substr($p, 5);
      if ($type == 7 || $type == 8 || $type == 17) { reply(pack('CN', 105, $id) . attrs()); }
      elsif ($type == 16) { my $path = take(\\$rest); reply(pack('CNN', 104, $id, 1) . str($path) . str($path) . attrs()); }
      elsif ($type == 3) { my $path = take(\\$rest); reply(pack('CN', 102, $id) . str('f:' . $path)); }
      elsif ($type == 6 || $type == 9 || $type == 10) { status($id, 0); }
      elsif ($type == 4) { my $h = take(\\$rest); note('CLOSE ' . $h); status($id, 0); }
      elsif ($type == 13) { my $path = take(\\$rest); note('REMOVE ' . $path); status($id, 0); }
      elsif ($type == 18 || $type == 200) { take(\\$rest) if $type == 200; note('RENAME DENIED'); status($id, 3); }
      elsif ($type == 5) { take(\\$rest); my ($hi, $lo) = unpack('NN', substr($rest, 0, 8));
        if ($hi == 0 && $lo == 0) { reply(pack('CN', 103, $id) . str('keep')); } else { status($id, 1); } }
      else { note('UNSUPPORTED ' . $type); status($id, 8); }
    }
    """.write(to: script, atomically: true, encoding: .utf8)
    let log = scratch.appendingPathComponent("requests.log")
    let client = SFTPClient(executable: "/usr/bin/perl", arguments: [script.path, log.path], environment: [:])
    // Safety net: a server that stops answering fails the test instead of hanging the run.
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak client] in client?.close() }
    try await client.connect()
    defer { client.close() }
    // The denial comes when the staged copy is published, after its handle was closed.
    // The match is outside `#expect`: Swift 6.0 crashes on an enum pattern against `any Error` there.
    await #expect {
        _ = try await client.upload(source, to: "/dest")
    } throws: { error in
        isSFTPPermissionDenied(error)
    }
    // This next OPEN reuses the closed numeric handle on OpenSSH. Only its own CLOSE is sent.
    let original = try await client.readFile("/dest")
    #expect(original == Data("keep".utf8))
    let lines = try String(contentsOf: log, encoding: .utf8)
        .components(separatedBy: .newlines).filter { !$0.isEmpty }
    let renameAt = try #require(lines.firstIndex { $0.contains("RENAME") })
    let closesBefore = lines[..<renameAt].filter { $0.contains("CLOSE") }
    let closesAfter = lines[(renameAt + 1)...].filter { $0.contains("CLOSE") }
    // The completed upload closed the staged handle once; the failed publication closed nothing;
    // the read of the original closed only its own handle.
    #expect(closesBefore.count == 1)
    #expect(closesAfter.count == 1)
    #expect(lines.contains { $0.contains("REMOVE /.termi-upload-") })
}

@Test func sftpUploadRefusesToReplaceOrFollowRemoteSymlink() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("source")
    let target = scratch.appendingPathComponent("target")
    let link = scratch.appendingPathComponent("link")
    try Data("new".utf8).write(to: source)
    try Data("keep".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    await #expect(throws: SFTPClient.Failure.self) { _ = try await client.upload(source, to: link.path) }
    let unchanged = try Data(contentsOf: target)
    #expect(unchanged == Data("keep".utf8))
    let attributes = try await client.lstat(link.path)
    #expect(attributes.fileType == .symlink)
}

@Test func sftpUploadWithoutAtomicRenameNeverTouchesTheOriginal() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("source")
    try Data("new".utf8).write(to: source)
    guard let (client, log) = try await sftpHostileClient(in: scratch, atomicRename: false) else { return }
    defer { client.close() }
    do {
        _ = try await client.upload(source, to: "/tree/ok.txt")
        Issue.record("replaced a file without atomic rename support")
    } catch let error as SFTPClient.Failure {
        #expect(error == .atomicReplacementBlocked(path: "/tree/ok.txt", reason: .noPosixRename))
    }
    #expect(sftpRequestLog(log).isEmpty)
    // With the user's consent the file itself is written: opened without truncating, checked,
    // truncated through the handle, written. Nothing is staged or renamed.
    let inPlace = SFTPClient.UploadDestination.existing(try await client.lstat("/tree/ok.txt"))
    _ = try await client.upload(source, to: "/tree/ok.txt", expectation: inPlace, strategy: .inPlace)
    #expect(sftpRequestLines(log) == ["OPEN /tree/ok.txt", "FSETSTAT size"])
}

@Test func sftpUploadConflictRequiresConsentAndSupportsSkipCancelReplace() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let local = scratch.appendingPathComponent("local")
    let remote = scratch.appendingPathComponent("remote")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    let source = local.appendingPathComponent("config")
    let destination = remote.appendingPathComponent("config")
    try Data("new".utf8).write(to: source)
    try Data("old".utf8).write(to: destination)
    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client)
    await #expect(throws: SFTPServiceError.self) {
        _ = try await session.upload(source, into: remote.path) { _ in }
    }
    let skipped = try await session.upload(source, into: remote.path, resolveConflict: { _ in .skip }) { _ in }
    // The user's choice is counted apart from what was left out.
    #expect(skipped.skipped.count == 0)
    #expect(skipped.kept.count == 1)
    #expect(skipped.kept.examples == [destination.path])
    #expect(skipped.bytes == 0)
    await #expect(throws: CancellationError.self) {
        _ = try await session.upload(source, into: remote.path, resolveConflict: { _ in .cancel }) { _ in }
    }
    let kept = try Data(contentsOf: destination)
    #expect(kept == Data("old".utf8))
    _ = try await session.upload(source, into: remote.path, resolveConflict: { _ in .replace }) { _ in }
    let replaced = try Data(contentsOf: destination)
    #expect(replaced == Data("new".utf8))
}

@Test func sftpUploadDoesNotReplaceAFileChangedWhileConfirmationWasOpen() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let local = scratch.appendingPathComponent("local")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let source = local.appendingPathComponent("config")
    let destination = scratch.appendingPathComponent("config")
    try Data("upload".utf8).write(to: source)
    try Data("old".utf8).write(to: destination)
    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client)
    await #expect(throws: SFTPClient.Failure.self) {
        _ = try await session.upload(source, into: scratch.path, resolveConflict: { _ in
            try Data("another writer changed this".utf8).write(to: destination)
            return .replace
        }) { _ in }
    }
    let kept = try Data(contentsOf: destination)
    #expect(kept == Data("another writer changed this".utf8))
}

@Test func sftpInterruptedUploadLeavesOriginalIntact() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("source")
    let destination = scratch.appendingPathComponent("destination")
    try Data(count: 4_000_000).write(to: source)
    try Data("keep".utf8).write(to: destination)
    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    await #expect(throws: (any Error).self) {
        _ = try await client.upload(source, to: destination.path) { _ in client.close() }
    }
    let kept = try Data(contentsOf: destination)
    #expect(kept == Data("keep".utf8))
}

@Test(arguments: ["replace", "skip", "cancel", "cancel-transfer"]) @MainActor
func sftpUploadConflictViewModelWaitsForTheExactDecision(choice: String) async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let local = scratch.appendingPathComponent("local")
    let remote = scratch.appendingPathComponent("remote")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    let source = local.appendingPathComponent("config")
    let destination = remote.appendingPathComponent("config")
    try Data("new".utf8).write(to: source)
    try Data("keep".utf8).write(to: destination)
    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    let model = SFTPViewModel()
    model.adopt(sftpTestSession(on: client))
    defer { model.disconnect() }
    model.upload([source], into: remote.path)
    for _ in 0..<300 where model.uploadConflict == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let conflict = try #require(model.uploadConflict)
    #expect(conflict.path == destination.path)
    #expect(model.hasActiveTransfers)
    let beforeDecision = try Data(contentsOf: destination)
    #expect(beforeDecision == Data("keep".utf8))
    // An action from an older alert has no authority over the current question.
    model.resolveUploadConflict(UUID(), decision: .replace)
    #expect(model.uploadConflict?.id == conflict.id)
    switch choice {
    case "replace": model.resolveUploadConflict(conflict.id, decision: .replace)
    case "skip": model.resolveUploadConflict(conflict.id, decision: .skip)
    case "cancel-transfer": model.cancelTransfer(conflict.transferID)
    default: model.resolveUploadConflict(conflict.id, decision: .cancel)
    }
    for _ in 0..<300 where model.hasActiveTransfers {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(!model.hasActiveTransfers)
    #expect(model.uploadConflict == nil)
    let afterDecision = try Data(contentsOf: destination)
    let expectedContent = Data((choice == "replace" ? "new" : "keep").utf8)
    #expect(afterDecision == expectedContent)
    let state = try #require(model.transfers.first?.state)
    if choice == "cancel" || choice == "cancel-transfer" {
        #expect(state == .cancelled)
    } else {
        #expect(state == .completed)
    }
    // A file the user chose to keep is not reported as left out.
    let transfer = try #require(model.transfers.first)
    let keptCount = choice == "skip" ? 1 : 0
    #expect(transfer.skipped.count == 0)
    #expect(transfer.kept.count == keptCount)
    #expect(!transfer.awaitingDecision)
}

@Test(arguments: [false, true]) @MainActor
func sftpRemoteEditResumesOnlyForTheSameResolvedEndpoint(changedEndpoint: Bool) async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let original = scratch.appendingPathComponent("config")
    try Data("original".utf8).write(to: original)
    guard let firstClient = try await sftpLocalClient(startingIn: scratch),
          let secondClient = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { firstClient.close(); secondClient.close() }
    var firstHost = Termi.Host.defaultValue()
    firstHost.id = 123
    firstHost.hostname = "original.example"
    let model = SFTPViewModel()
    model.editFolder = scratch.appendingPathComponent("edits")
    model.editorForTests = { _ in }
    model.moveToTrash = scratchTrash(scratch.appendingPathComponent("trash"))
    model.adopt(SFTPSession(host: firstHost, client: firstClient, homeDirectory: scratch.path))
    await model.edit(SFTPItem(entry: sftpFileEntry("config"), parentPath: scratch.path))
    let editing = try #require(model.editItems.first)
    model.disconnect(keepEdits: true)
    try Data("private original server data".utf8).write(to: editing.localURL)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)],
                                         ofItemAtPath: editing.localURL.path)
    var changed = firstHost
    if changedEndpoint { changed.hostname = "another.example" }
    model.adopt(SFTPSession(host: changed, client: secondClient, homeDirectory: scratch.path))
    await model.uploadIfChanged(editing.id)
    let unchanged = try Data(contentsOf: original)
    let expected = changedEndpoint ? "original" : "private original server data"
    #expect(unchanged == Data(expected.utf8))
    // The local change is recoverable even though its old server has gone.
    let retained = FileManager.default.fileExists(atPath: editing.localURL.path)
        || FileManager.default.fileExists(atPath: scratch.appendingPathComponent("trash/config").path)
    #expect(retained)
    model.disconnect()
}

@MainActor private final class SFTPConnectionGate {
    var waiting: [String: CheckedContinuation<SFTPSession, Error>] = [:]

    func open(_ host: Termi.Host) async throws -> SFTPSession {
        // Intentionally ignores cancellation, like a transport callback already in flight.
        try await withCheckedThrowingContinuation { waiting[host.hostname] = $0 }
    }

    func waitFor(_ hostname: String) async throws {
        for _ in 0..<300 {
            if waiting[hostname] != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }
}

@Test(arguments: [false, true]) @MainActor
func sftpLateConnectionCannotReplaceOrClearTheCurrentHost(lateFailure: Bool) async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let a = try await sftpLocalClient(startingIn: scratch),
          let b = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { a.close(); b.close() }
    var hostA = Termi.Host.defaultValue()
    hostA.id = 101
    hostA.hostname = "a.example"
    var hostB = hostA
    hostB.id = 102
    hostB.hostname = "b.example"
    let gate = SFTPConnectionGate()
    let model = SFTPViewModel(openSession: { try await gate.open($0) })
    let first = Task { await model.connect(to: hostA) }
    try await gate.waitFor(hostA.hostname)
    let second = Task { await model.connect(to: hostB) }
    try await gate.waitFor(hostB.hostname)
    gate.waiting.removeValue(forKey: hostB.hostname)?.resume(returning:
        SFTPSession(host: hostB, client: b, homeDirectory: scratch.path))
    await second.value
    #expect(model.isConnected)
    if lateFailure {
        gate.waiting.removeValue(forKey: hostA.hostname)?.resume(
            throwing: SFTPClient.Failure.status(code: SFTPClient.Failure.codePermissionDenied, message: ""))
    } else {
        gate.waiting.removeValue(forKey: hostA.hostname)?.resume(returning:
            SFTPSession(host: hostA, client: a, homeDirectory: scratch.path))
    }
    await first.value
    #expect(model.selectedHost?.hostname == hostB.hostname)
    #expect(model.isConnected)
    #expect(!model.isConnecting)
    #expect(model.connectionError == nil)
    #expect(model.failedHost == nil)
    #expect(b.isOpen)
    if !lateFailure { #expect(!a.isOpen) }
    model.disconnect()
}

@Test @MainActor func sftpDisconnectInvalidatesAConnectionStillOpening() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    var host = Termi.Host.defaultValue()
    host.hostname = "pending.example"
    let gate = SFTPConnectionGate()
    let model = SFTPViewModel(openSession: { try await gate.open($0) })
    let pending = Task { await model.connect(to: host) }
    try await gate.waitFor(host.hostname)
    model.disconnect()
    gate.waiting.removeValue(forKey: host.hostname)?.resume(returning:
        SFTPSession(host: host, client: client, homeDirectory: scratch.path))
    await pending.value
    #expect(model.selectedHost == nil)
    #expect(!model.isConnected)
    #expect(!model.isConnecting)
    #expect(!client.isOpen)
}

@Test(arguments: ["handshake", "home"])
func sftpCancelledSessionStartupClosesAStalledTransport(stage: String) async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let marker = scratch.appendingPathComponent("waiting")
    // A real child process reads INIT; optionally answers VERSION and waits for REALPATH.
    // It never answers the blocked request. Cancellation has to close the pipe to unblock it.
    let server = #"""
    use strict; use warnings; binmode(STDIN); binmode(STDOUT);
    my ($marker, $stage) = @ARGV;
    read(STDIN, my $init, 9) == 9 or exit 1;
    if ($stage eq 'home') {
      syswrite(STDOUT, pack('NCN', 5, 2, 3));
      read(STDIN, my $header, 4) == 4 or exit 1;
      read(STDIN, my $request, unpack('N', $header));
    }
    open(my $fh, '>', $marker) or die $!; print $fh 'waiting'; close($fh);
    while (read(STDIN, my $more, 1024)) { }
    """#
    let client = SFTPClient(executable: "/usr/bin/perl", arguments: ["-e", server, marker.path, stage], environment: [:])
    defer { client.close() }
    // Safety net turns a cancellation regression into a failure rather than a hung suite.
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { client.close() }
    let opening = Task { try await SFTPSession.open(host: Termi.Host.defaultValue(), client: client) }
    for _ in 0..<300 where !FileManager.default.fileExists(atPath: marker.path) {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
    let cancelledAt = ContinuousClock.now
    opening.cancel()
    await #expect(throws: (any Error).self) { _ = try await opening.value }
    let elapsed = cancelledAt.duration(to: .now)
    #expect(elapsed < .seconds(2))
    #expect(!client.isOpen)
}

@Test func sftpEditEndpointUsesTheResolvedUserAndEveryJump() {
    let jump = SSHHop(alias: "jump", displayName: "Jump", hostname: "bastion", username: "gateway")
    let destination = SSHHop(alias: "target", displayName: "Target", hostname: "server", username: "deploy")
    let original = SFTPEndpoint(spec: SSHConnectionSpec(hops: [jump, destination]))
    var otherUser = destination
    otherUser.username = "root"
    let changedUser = SFTPEndpoint(spec: SSHConnectionSpec(hops: [jump, otherUser]))
    #expect(original != changedUser)
    var otherJump = jump
    otherJump.hostname = "another-bastion"
    let changedJump = SFTPEndpoint(spec: SSHConnectionSpec(hops: [otherJump, destination]))
    #expect(original != changedJump)
    var relabelled = destination
    relabelled.displayName = "A new label"
    relabelled.hostId = 999
    let sameEndpoint = SFTPEndpoint(spec: SSHConnectionSpec(hops: [jump, relabelled]))
    #expect(original == sameEndpoint)
}

// MARK: - Downloads never destroy what is already there

@Test func sftpDownloadRefusesToReplaceLocalFolder() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let folder = scratch.appendingPathComponent("current", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let keep = folder.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: keep)

    // Never started and already closed: every request fails at once, so nothing can hang.
    let client = SFTPClient(executable: "/usr/bin/false", arguments: [], environment: [:])
    client.close()

    await #expect(throws: CocoaError.self) {
        _ = try await client.download("/srv/current", to: folder)
    }
    #expect(FileManager.default.fileExists(atPath: keep.path))
}

@Test func sftpFailedDownloadKeepsExistingLocalFile() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    // On the "server" report.pdf is a folder: OPEN succeeds and READ fails, which is a transfer
    // that dies after it started.
    let remote = scratch.appendingPathComponent("remote", isDirectory: true)
        .appendingPathComponent("report.pdf", isDirectory: true)
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let existing = local.appendingPathComponent("report.pdf")
    try Data("old".utf8).write(to: existing)

    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }

    await #expect(throws: (any Error).self) {
        _ = try await client.download(remote.path, to: existing)
    }
    let kept = try Data(contentsOf: existing)
    #expect(kept == Data("old".utf8))
    // No temporary ".part" file is left behind either.
    let names = try FileManager.default.contentsOfDirectory(atPath: local.path)
    #expect(names == ["report.pdf"])
}

@Test func sftpCancelledDownloadKeepsExistingLocalFile() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    // Over a hundred 32 KB chunks, so the transfer is still running after the first one.
    let payload = Data(count: 4_000_000)
    let source = scratch.appendingPathComponent("big.bin")
    try payload.write(to: source)
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let destination = local.appendingPathComponent("big.bin")
    try Data("old".utf8).write(to: destination)

    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }

    // The progress callback runs on the downloading task, so cancelling from it is a cancel in
    // mid-transfer that does not depend on timing.
    let transfer = Task {
        try await client.download(source.path, to: destination) { _ in
            withUnsafeCurrentTask { (current: UnsafeCurrentTask?) -> Void in
                current?.cancel()
            }
        }
    }
    await #expect(throws: (any Error).self) {
        _ = try await transfer.value
    }
    let kept = try Data(contentsOf: destination)
    #expect(kept == Data("old".utf8))
    let names = try FileManager.default.contentsOfDirectory(atPath: local.path)
    #expect(names == ["big.bin"])

    // Cleaning up after the cancel (which sends CLOSE from the cancelled task) leaves the
    // session usable.
    let trash = scratch.appendingPathComponent("trash", isDirectory: true)
    let received = try await client.download(source.path, to: destination, trash: scratchTrash(trash))
    #expect(received == UInt64(payload.count))
}

@Test func sftpDownloadReplacesExistingLocalFile() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    // Several 32 KB chunks, so the pipelined reads are exercised too.
    let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
    let source = scratch.appendingPathComponent("data.bin")
    try payload.write(to: source)
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let destination = local.appendingPathComponent("data.bin")
    try Data("old".utf8).write(to: destination)

    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }

    let trash = scratch.appendingPathComponent("trash", isDirectory: true)
    let received = try await client.download(source.path, to: destination, trash: scratchTrash(trash))
    #expect(received == UInt64(payload.count))
    let downloaded = try Data(contentsOf: destination)
    #expect(downloaded == payload)
    let names = try FileManager.default.contentsOfDirectory(atPath: local.path)
    #expect(names == ["data.bin"])
    // The file that was there is not overwritten: it is in the Trash and can be put back.
    let replaced = try Data(contentsOf: trash.appendingPathComponent("data.bin"))
    #expect(replaced == Data("old".utf8))
}

@Test func sftpDownloadKeepsExistingLocalFileTheTrashDoesNotTake() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("data.bin")
    try Data("new".utf8).write(to: source)
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let destination = local.appendingPathComponent("data.bin")
    try Data("old".utf8).write(to: destination)

    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }

    // The Trash refuses the file: the download fails rather than overwrite it.
    await #expect(throws: CocoaError.self) {
        _ = try await client.download(source.path, to: destination, trash: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
    }
    let kept = try Data(contentsOf: destination)
    #expect(kept == Data("old".utf8))
    let names = try FileManager.default.contentsOfDirectory(atPath: local.path)
    #expect(names == ["data.bin"])
}

@Test func sftpDownloadReplacesInPlaceOnAVolumeWithoutATrash() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("data.bin")
    try Data("new".utf8).write(to: source)
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let destination = local.appendingPathComponent("data.bin")
    try Data("old".utf8).write(to: destination)

    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }

    // Network shares have no Trash: Finder could only delete there too, so the file is replaced.
    _ = try await client.download(source.path, to: destination, trash: { _ in
        throw CocoaError(.featureUnsupported)
    })
    let replaced = try Data(contentsOf: destination)
    #expect(replaced == Data("new".utf8))
    let names = try FileManager.default.contentsOfDirectory(atPath: local.path)
    #expect(names == ["data.bin"])
}

@Test func sftpDownloadHandlesFileNameNearTheLengthLimit() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    // The name itself fits in 255 bytes; the name plus a temporary-file suffix would not.
    let name = String(repeating: "a", count: 250)
    let payload = Data("long".utf8)
    let source = scratch.appendingPathComponent(name)
    try payload.write(to: source)
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let destination = local.appendingPathComponent(name)

    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }

    try await client.download(source.path, to: destination)
    let downloaded = try Data(contentsOf: destination)
    #expect(downloaded == payload)
    let names = try FileManager.default.contentsOfDirectory(atPath: local.path)
    #expect(names == [name])
}

// MARK: - Remote editing

@Test func sftpEditTreatsExecutablesAndScriptsAsRunnable() throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    func file(_ name: String, mode: Int) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }
    let executable = try file("deploy", mode: 0o755)
    let script = try file("backup.sh", mode: 0o644)
    let text = try file("notes.txt", mode: 0o644)
    let extensionless = try file("config", mode: 0o644)

    // Terminal would execute these if they were opened with their default app.
    #expect(SFTPViewModel.isRunnable(executable))
    #expect(SFTPViewModel.isRunnable(script))
    // Ordinary documents keep their default app.
    #expect(!SFTPViewModel.isRunnable(text))
    #expect(!SFTPViewModel.isRunnable(extensionless))

    // A Terminal settings file runs its startup command when Terminal opens it. Checked only
    // where the system knows that type (Terminal.app declares it).
    if UTType("com.apple.terminal.settings") != nil {
        let settings = try file("profile.terminal", mode: 0o644)
        #expect(SFTPViewModel.isRunnable(settings))
    }
}

/// A local copy of a remote file being edited, in a folder of its own (stopping an edit removes
/// the folder that holds the copy).
private func editCopy(_ name: String, in scratch: URL) throws -> URL {
    let folder = scratch.appendingPathComponent("edit-" + name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent(name)
    try Data(name.utf8).write(to: copy)
    return copy
}

private func modificationDate(of url: URL) throws -> Date? {
    try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}

@Test func sftpEditCopyWithChangesNotOnServerIsRecognised() {
    let saved = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let copy = URL(fileURLWithPath: "/tmp/nginx.conf")
    var item = RemoteEditItem(remotePath: "/etc/nginx/nginx.conf", localURL: copy, lastUploadedModification: saved)

    // What the server has is what is on disk: the copy can be deleted.
    #expect(!item.hasChangesNotOnServer(modified: saved))
    // Saved again since the last upload (no connection, or the save was not noticed yet).
    #expect(item.hasChangesNotOnServer(modified: saved.addingTimeInterval(5)))
    // The upload truncated the remote file and is not through yet.
    item.isUploading = true
    #expect(item.hasChangesNotOnServer(modified: saved))
    // The upload failed (permission denied, disk full…): the server never got that save.
    item.isUploading = false
    item.uploadFailed = true
    #expect(item.hasChangesNotOnServer(modified: saved))
    // The file is gone: nothing is left to keep.
    #expect(!item.hasChangesNotOnServer(modified: nil))
}

@Test @MainActor func sftpDisconnectKeepsEditCopiesOnlyWhenAsked() throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let copy = try editCopy("nginx.conf", in: scratch)
    let trash = scratch.appendingPathComponent("trash", isDirectory: true)

    let viewModel = SFTPViewModel()
    viewModel.moveToTrash = scratchTrash(trash)
    viewModel.editItems = [RemoteEditItem(remotePath: "/etc/nginx/nginx.conf", localURL: copy,
                                          lastUploadedModification: try modificationDate(of: copy))]

    // Reconnecting to the same host: the copy may hold changes that were never uploaded.
    viewModel.disconnect(keepEdits: true)
    #expect(viewModel.editItems.count == 1)
    #expect(FileManager.default.fileExists(atPath: copy.path))

    // The Disconnect button, another host, closing the window: the server has everything in
    // this copy, so it is deleted.
    #expect(viewModel.unsyncedEditCount == 0)
    #expect(SFTPViewModel.closeWarnings(for: [viewModel]).isEmpty)
    viewModel.disconnect()
    #expect(viewModel.editItems.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
    #expect(!FileManager.default.fileExists(atPath: trash.path))
    #expect(viewModel.notice == nil)
}

@Test @MainActor func sftpDisconnectMovesEditCopiesWithChangesNotOnServerToTrash() throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let uploaded = try editCopy("uploaded.conf", in: scratch)
    let savedOffline = try editCopy("saved-offline.conf", in: scratch)
    let uploading = try editCopy("uploading.conf", in: scratch)
    let failed = try editCopy("failed.conf", in: scratch)
    let trash = scratch.appendingPathComponent("trash", isDirectory: true)

    let viewModel = SFTPViewModel()
    viewModel.moveToTrash = scratchTrash(trash)
    viewModel.editItems = [
        RemoteEditItem(remotePath: "/etc/uploaded.conf", localURL: uploaded,
                       lastUploadedModification: try modificationDate(of: uploaded)),
        // Saved after the last upload, while the connection was down.
        RemoteEditItem(remotePath: "/etc/saved-offline.conf", localURL: savedOffline,
                       lastUploadedModification: try modificationDate(of: savedOffline)?.addingTimeInterval(-60)),
        RemoteEditItem(remotePath: "/etc/uploading.conf", localURL: uploading,
                       lastUploadedModification: try modificationDate(of: uploading), isUploading: true),
        RemoteEditItem(remotePath: "/etc/failed.conf", localURL: failed,
                       lastUploadedModification: try modificationDate(of: failed), uploadFailed: true)
    ]

    #expect(viewModel.unsyncedEditCount == 3)
    // An upload in flight keeps Disconnect unavailable, and closing the window or quitting asks.
    #expect(viewModel.hasActiveTransfers)
    #expect(SFTPViewModel.closeWarnings(for: [viewModel]).count == 1)

    viewModel.disconnect()
    #expect(viewModel.editItems.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: uploaded.path))
    #expect(!FileManager.default.fileExists(atPath: trash.appendingPathComponent("uploaded.conf").path))
    for name in ["saved-offline.conf", "uploading.conf", "failed.conf"] {
        let kept = try Data(contentsOf: trash.appendingPathComponent(name))
        #expect(kept == Data(name.utf8))
        #expect(viewModel.notice?.text.contains(name) == true)
    }
    #expect(viewModel.notice?.text.contains("uploaded.conf") == false)
    // "Reveal in Finder" leads to where the copies are now.
    let revealed = Set(viewModel.notice?.files.map(\.path) ?? [])
    let expected = Set(["saved-offline.conf", "uploading.conf", "failed.conf"].map {
        trash.appendingPathComponent($0).path
    })
    #expect(revealed == expected)
}

@Test @MainActor func sftpStopEditingKeepsCopyTheTrashDoesNotTake() throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let copy = try editCopy("nginx.conf", in: scratch)

    let viewModel = SFTPViewModel()
    viewModel.moveToTrash = { _ in throw CocoaError(.featureUnsupported) }
    let item = RemoteEditItem(remotePath: "/etc/nginx/nginx.conf", localURL: copy, uploadFailed: true)
    viewModel.editItems = [item]

    viewModel.stopEditing(item.id)
    #expect(viewModel.editItems.isEmpty)
    // Never deleted: it stays where it is, and the page says where that is.
    let kept = try Data(contentsOf: copy)
    #expect(kept == Data("nginx.conf".utf8))
    #expect(viewModel.notice?.text.contains(copy.path) == true)
    #expect(viewModel.notice?.files == [copy])
}

@Test @MainActor func sftpCloseWarningsCountTransfersAndEditsOfAllWindows() throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let copy = try editCopy("nginx.conf", in: scratch)

    let idle = SFTPViewModel()
    let busy = SFTPViewModel()
    busy.transfers = [
        TransferItem(name: "running.iso", direction: .upload, totalBytes: 10),
        TransferItem(name: "done.iso", direction: .download, totalBytes: 10, state: .completed)
    ]
    let editing = SFTPViewModel()
    editing.editItems = [RemoteEditItem(remotePath: "/etc/nginx/nginx.conf", localURL: copy, uploadFailed: true)]

    #expect(SFTPViewModel.closeWarnings(for: [idle]).isEmpty)
    #expect(SFTPViewModel.closeWarnings(for: [busy]).count == 1)
    #expect(SFTPViewModel.closeWarnings(for: [editing]).count == 1)
    #expect(SFTPViewModel.closeWarnings(for: [idle, busy, editing]).count == 2)
    #expect(busy.hasActiveTransfers)
    #expect(!editing.hasActiveTransfers)
}

@Test @MainActor func sftpNoticeCollectsLinesAndFilesWithoutRepeating() {
    let viewModel = SFTPViewModel()
    let trashed = URL(fileURLWithPath: "/tmp/trash/nginx.conf")

    viewModel.addNotice("moved to the Trash: nginx.conf", files: [trashed])
    viewModel.addNotice("transfers are still running")
    // Asked for again (Open SFTP pressed twice while a transfer runs): not said twice.
    viewModel.addNotice("transfers are still running")

    let expected = SFTPNotice(text: "moved to the Trash: nginx.conf\ntransfers are still running", files: [trashed])
    #expect(viewModel.notice == expected)
}

// MARK: - Folder of the local copies

@Test func remoteEditFolderIsPerAppInstance() {
    let parent = URL(fileURLWithPath: "/tmp/somewhere", isDirectory: true)
    #expect(RemoteEditFolder.url(in: parent).lastPathComponent == "Termi-Edit-\(getpid())")
    #expect(RemoteEditFolder.url(forProcess: 400_001, in: parent).lastPathComponent == "Termi-Edit-400001")
    #expect(RemoteEditFolder.url(in: parent).deletingLastPathComponent().path == parent.path)
}

@Test func remoteEditLaunchCleanupOnlyTouchesInstancesThatAreGone() throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let parent = scratch.appendingPathComponent("tmp", isDirectory: true)
    let trash = scratch.appendingPathComponent("trash", isDirectory: true)
    func copy(_ name: String, inFolder folderName: String) throws -> URL {
        let folder = parent.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("1a2b3c4d", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }
    let dead = try copy("dead.conf", inFolder: "Termi-Edit-400001")
    let running = try copy("running.conf", inFolder: "Termi-Edit-400002")
    let own = try copy("own.conf", inFolder: "Termi-Edit-\(getpid())")
    // The shared folder of earlier builds, and names that only look alike.
    let legacy = try copy("legacy.conf", inFolder: "Termi-Edit")
    let other = try copy("other.conf", inFolder: "Termi-Edit-backup")

    let trashed = RemoteEditFolder.sweepStale(in: parent, isAlive: { $0 != 400_001 }, trash: scratchTrash(trash))

    // The instance that is gone: its copy may hold changes its server never received, so it
    // is in the Trash — not deleted — and the emptied folder is removed.
    #expect(trashed == [trash.appendingPathComponent("dead.conf")])
    let recovered = try Data(contentsOf: trash.appendingPathComponent("dead.conf"))
    #expect(recovered == Data("dead.conf".utf8))
    #expect(!FileManager.default.fileExists(atPath: dead.path))
    #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("Termi-Edit-400001").path))
    // Everything else is left alone.
    for url in [running, own, legacy, other] {
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

@Test func remoteEditCleanupKeepsCopyTheTrashDoesNotTake() throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let folder = RemoteEditFolder.url(forProcess: 400_001, in: scratch)
    let copyFolder = folder.appendingPathComponent("1a2b3c4d", isDirectory: true)
    try FileManager.default.createDirectory(at: copyFolder, withIntermediateDirectories: true)
    let copy = copyFolder.appendingPathComponent("nginx.conf")
    try Data("edited".utf8).write(to: copy)
    // An edit that was stopped left its folder empty.
    let emptied = folder.appendingPathComponent("5e6f7a8b", isDirectory: true)
    try FileManager.default.createDirectory(at: emptied, withIntermediateDirectories: true)

    let trashed = RemoteEditFolder.sweep(folder, trash: { _ in throw CocoaError(.featureUnsupported) })

    #expect(trashed.isEmpty)
    let kept = try Data(contentsOf: copy)
    #expect(kept == Data("edited".utf8))
    #expect(!FileManager.default.fileExists(atPath: emptied.path))

    // Once the Trash takes it, nothing of the instance is left behind.
    let trash = scratch.appendingPathComponent("trash", isDirectory: true)
    #expect(RemoteEditFolder.sweep(folder, trash: scratchTrash(trash)) == [trash.appendingPathComponent("nginx.conf")])
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("nginx.conf").path))
}

// MARK: - Entry names sent by the server

@Test func sftpEntryNameIsAFileName() {
    for name in ["a", "a.txt", ".hidden", "a b", "a\\b", "a:b", "...", "ü", "~"] {
        #expect(SFTPClient.isValidEntryName(name), "\(name.debugDescription)")
    }
    for name in ["", ".", "..", "a/b", "/a", "a/", "../x", "sub/../../x", "a\0b"] {
        #expect(!SFTPClient.isValidEntryName(name), "\(name.debugDescription)")
    }
    // "/" followed by a combining mark, a variation selector or a joiner is one character that
    // is not "/" — and still a path separator to the server and the file system.
    for name in ["../\u{301}x", "../\u{FE0F}x", "a/\u{200D}b", "/\u{301}", "a\u{600}/b", "x\u{301}/y"] {
        #expect(!SFTPClient.isValidEntryName(name), "\(name.debugDescription)")
    }
    // Names that only look like "." and ".." to a character-wise comparison are file names.
    for name in ["e\u{301}", ".\u{301}", "..\u{301}"] {
        #expect(SFTPClient.isValidEntryName(name), "\(name.debugDescription)")
    }
}

@Test func sftpPathsAreSplitAndJoinedByBytes() {
    // (path, its parent). A name that starts with a combining mark, and a folder whose name
    // ends in a character that joins with what follows, keep their "/" all the same.
    let cases = [
        ("/", "/"), ("/a", "/"), ("/a/b", "/a"), ("/a/b/", "/a"), ("a", "."),
        ("/srv/share/\u{301}notes.txt", "/srv/share"),
        ("/srv/share\u{600}/notes.txt", "/srv/share\u{600}"),
        ("/\u{301}x", "/")
    ]
    for (path, parent) in cases {
        #expect(Array(SFTPClient.parent(of: path).utf8) == Array(parent.utf8), "\(path.debugDescription)")
    }
    #expect(Array(SFTPClient.join("/srv/share", "\u{301}n").utf8) == Array("/srv/share/\u{301}n".utf8))
    #expect(Array(SFTPClient.join("/srv/x\u{600}/", "n").utf8) == Array("/srv/x\u{600}/n".utf8))
    #expect(SFTPClient.join("/", "n") == "/n")
    // Never normalised: the precomposed and the decomposed "é" stay what they are.
    #expect(Array(SFTPClient.parent(of: "/d\u{E9}/x").utf8) == Array("/d\u{E9}".utf8))
    #expect(Array(SFTPClient.parent(of: "/de\u{301}/x").utf8) == Array("/de\u{301}".utf8))
}

private func sftpFileEntry(_ name: String) -> SFTPClient.DirectoryEntry {
    SFTPClient.DirectoryEntry(name: name, longName: "", attributes: SFTPClient.Attributes(permissions: 0o100644))
}

@Test func sftpItemIdentityIsByteExact() {
    // The same "é", precomposed and decomposed: equal as Swift strings, two files on a server.
    let precomposed = SFTPItem(entry: sftpFileEntry("caf\u{E9}"), parentPath: "/d")
    let decomposed = SFTPItem(entry: sftpFileEntry("cafe\u{301}"), parentPath: "/d")
    #expect(precomposed.path == decomposed.path)

    #expect(precomposed.id != decomposed.id)
    #expect(precomposed != decomposed)
    #expect(Set([precomposed.id, decomposed.id]).count == 2)
    #expect(Set([precomposed, decomposed]).count == 2)
    #expect(precomposed.id == SFTPItem(entry: sftpFileEntry("caf\u{E9}"), parentPath: "/d").id)

    // A name that is not valid UTF-8 is not the file whose name is its display text.
    var undecodable = sftpFileEntry("caf\u{FFFD}")
    undecodable.rawName = Data([0x63, 0x61, 0x66, 0xE9])
    let shown = SFTPItem(entry: undecodable, parentPath: "/d")
    let literal = SFTPItem(entry: sftpFileEntry("caf\u{FFFD}"), parentPath: "/d")
    #expect(!shown.isNameRepresentable)
    #expect(literal.isNameRepresentable)
    #expect(shown.id != literal.id)
}

@Test @MainActor func sftpSelectionActsOnTheExactNameOnly() {
    let precomposed = SFTPItem(entry: sftpFileEntry("caf\u{E9}"), parentPath: "/d")
    let decomposed = SFTPItem(entry: sftpFileEntry("cafe\u{301}"), parentPath: "/d")
    var undecodable = sftpFileEntry("caf\u{FFFD}")
    undecodable.rawName = Data([0x63, 0x61, 0x66, 0xE9])
    let shown = SFTPItem(entry: undecodable, parentPath: "/d")

    let viewModel = SFTPViewModel()
    viewModel.remoteItems = [precomposed, decomposed, shown]
    viewModel.selectedRemoteItems = [decomposed.id]
    #expect(viewModel.selectedRemote.map { Array($0.path.utf8) } == [Array(decomposed.path.utf8)])
    // Nothing is done with a name that cannot be sent back, selected or not.
    viewModel.selectedRemoteItems = [shown.id]
    #expect(viewModel.selectedRemote.isEmpty)
}

@Test func sftpEditFollowsARenameOnTheServer() {
    // The file itself, something below a renamed folder, and names that only begin alike.
    #expect(RemoteEditItem.rebased("/a/x", from: "/a/x", to: "/a/y") == "/a/y")
    #expect(RemoteEditItem.rebased("/a/x/f.conf", from: "/a/x", to: "/a/y") == "/a/y/f.conf")
    #expect(RemoteEditItem.rebased("/a/xy", from: "/a/x", to: "/a/y") == nil)
    #expect(RemoteEditItem.rebased("/a/x\u{301}", from: "/a/x", to: "/a/y") == nil)
    #expect(RemoteEditItem.rebased("/b/x", from: "/a/x", to: "/a/y") == nil)
    // What follows the renamed folder is kept byte for byte.
    let moved = RemoteEditItem.rebased("/a/x/caf\u{E9}", from: "/a/x", to: "/a/y")
    #expect(moved.map { Array($0.utf8) } == Array("/a/y/caf\u{E9}".utf8))
}

/// An SFTP v3 "server" whose directory /tree lists, next to a file and a folder, names no file
/// can have: with path separators, empty, "." / "..", with a NUL. /odd lists names that differ
/// only in their bytes, twice the same name, and names with a separator hidden in a character;
/// /keep lists a name that is not valid UTF-8. REALPATH answers what `%real` says for a path,
/// fails below /rp/fail and echoes any other path. Requests that change something (REMOVE,
/// RMDIR, MKDIR, OPEN, RENAME) are written to the file given as its argument. The content of a
/// file below /slow is held back ("HELD <path>" in that file) until the next request arrives.
///
/// For the bounds and the transfers: /loop and /stall never end their listing (one entry, or
/// none, per answer); every directory below /deep holds a directory "a"; /huge lists two files
/// of the largest size there is; /special lists pipes, devices and a socket; /twins lists one
/// name encoded two ways. LSTAT / STAT find a directory at every listed path, nothing at the
/// paths in `%absent` and a file anywhere else. MKDIR fails below /denied (no permission) and
/// where a directory is listed (it exists). A file below /proc reports size 0 and is 32772
/// bytes long.
///
/// For the panels: the listing of /late is held back until another directory has been listed
/// and closed, so that it arrives after the answer to a later request. /links lists two links:
/// STAT (which follows links) finds a file of mode 600 behind "current" and nothing behind
/// "dangling".
///
/// For names that are one name somewhere: /folded lists "straße.txt" and "STRASSE.txt", /case
/// lists "notes" and "NOTES" (LSTAT answers the same for both) next to "solo.txt". /pipes
/// lists a link behind which STAT finds a pipe. /merge is a directory in which "site" is a
/// link (LSTAT) to a directory (STAT). /pair lists two files and a pipe.
///
/// For owners: a file below /owned belongs to uid / gid 1001 (LSTAT), a file the client creates
/// there to 501 / 20 (FSTAT), and FSETSTAT refuses to change an owner there. FSETSTAT is logged
/// ("FSETSTAT owner|mode|size") except for the client's staged copies elsewhere.
private let hostileSFTPServer = #"""
use strict; use warnings;
binmode(STDIN); binmode(STDOUT);
my $log = shift @ARGV;
my $atomic = 1;
my %dirs = (
  '/tree' => [ ['ok.txt', 0100644], ['../../victim', 0100644], ['a/b', 0100644], ['', 0100644],
               ['.', 040755], ['..', 040755], ["nul\0name", 0100644], ['sub/../../victim2', 040755],
               ['sub', 040755] ],
  '/tree/sub' => [ ['inner.txt', 0100644], ['../outside', 0100644] ],
  '/odd' => [ ['good.txt', 0100644], ["caf\xE9", 0100644], ["caf\xEF\xBF\xBD", 0100644],
              ["e\xCC\x81", 0100644], ["\xC3\xA9", 0100644], ["\xC3\xA9", 0100644],
              ["../\xCC\x81x", 0100644], ["a/\xE2\x80\x8Db", 0100644] ],
  '/keep' => [ ['fine.txt', 0100644], ["bad\xFF.txt", 0100644], ['sub', 040755] ],
  '/keep/sub' => [ ['inner.txt', 0100644] ],
  '/loop' => [ ['again', 0100644] ],
  '/stall' => [ ],
  '/huge' => [ ['one', 0100644, 1], ['two', 0100644, 1] ],
  '/special' => [ ['data.txt', 0100644], ['pipe', 010644], ['tty', 020620], ['disk', 060660], ['sock', 0140755] ],
  '/twins' => [ ["caf\xC3\xA9", 0100644], ["cafe\xCC\x81", 0100644], ['plain.txt', 0100644] ],
  '/late' => [ ['late.txt', 0100644] ],
  '/links' => [ ['current', 0120777], ['dangling', 0120777] ],
  '/folded' => [ ["stra\xC3\x9Fe.txt", 0100644], ['STRASSE.txt', 0100644] ],
  '/case' => [ ['notes', 0100644], ['NOTES', 0100644], ['solo.txt', 0100644] ],
  '/pipes' => [ ['data.txt', 0100644], ['fifo-link', 0120777] ],
  '/merge' => [ ['site', 0120777] ],
  '/merge/site' => [ ],
  '/pair' => [ ['a.txt', 0100644], ['b.txt', 0100644], ['pipe', 010644] ],
);
my %absent = ('/etc/site' => 1, '/tree/free.txt' => 1, '/links/dangling' => 1);
my %target = ('/links/current' => 0100600, '/pipes/fifo-link' => 010644);
my %link = ('/merge/site' => 1);
my ($held, $late_open, $overtaken, $slow) = (undef, 0, 0, undef);
sub entries { my ($path) = @_;
  return $dirs{$path} if exists $dirs{$path};
  return [ ['a', 040755] ] if $path =~ m{^/deep(/a)*$};
  return undef; }
my %real = ('.' => '/home', '/rp/empty' => '', '/rp/rel' => 'docs', '/rp/up' => '../x', '/rp/bad' => "/caf\xE9");
sub note { my ($line) = @_; open(my $fh, '>>', $log); binmode($fh); print $fh $line . "\n"; close($fh); }
my %sent;
sub rd { my ($n) = @_; my $buf = '';
  while (length($buf) < $n) { my $r = sysread(STDIN, $buf, $n - length($buf), length($buf)); exit 0 unless $r; }
  return $buf; }
sub str { my ($s) = @_; return pack('N', length($s)) . $s; }
sub reply { my ($body) = @_; syswrite(STDOUT, pack('N', length($body)) . $body); }
sub status { my ($id, $code) = @_; reply(pack('CNN', 101, $id, $code) . str('') . str('')); }
sub attrs { my ($mode, $huge) = @_;
  return pack('NNNN', 0x5, 0xFFFFFFFF, 0xFFFFFFFF, $mode) if $huge;
  return pack('NN', 0x4, $mode); }
sub take { my ($ref) = @_; my $len = unpack('N', substr($$ref, 0, 4));
  my $s = substr($$ref, 4, $len); $$ref = substr($$ref, 4 + $len); return $s; }
while (1) {
  my $len = unpack('N', rd(4));
  my $p = rd($len);
  my $type = unpack('C', substr($p, 0, 1));
  if ($type == 1) { reply(pack('CN', 2, 3) . ($atomic ? str('posix-rename@openssh.com') . str('1') : '')); next; }
  my $id = unpack('N', substr($p, 1, 4));
  my $rest = substr($p, 5);
  if (defined $slow) { reply($slow); undef $slow; }
  if ($type == 11) {
    my $path = take(\$rest);
    $late_open = 1 if $path eq '/late';
    if (defined entries($path)) { reply(pack('CN', 102, $id) . str($path)); } else { status($id, 2); }
  } elsif ($type == 12) {
    my $h = take(\$rest);
    my $endless = ($h eq '/loop' || $h eq '/stall');
    if (!$endless && $sent{$h}++) { status($id, 1); }
    else {
      my @e = @{entries($h)};
      my $body = pack('CNN', 104, $id, scalar(@e));
      for my $e (@e) { $body .= str($e->[0]) . str($e->[0]) . attrs($e->[1], $e->[2]); }
      if ($h eq '/late' && !$overtaken) { $held = $body; } else { reply($body); }
    }
  } elsif ($type == 4) {
    my $h = take(\$rest); delete $sent{$h}; status($id, 0);
    if ($h eq '/late') { $late_open = 0; $overtaken = 0; }
    elsif (defined $held) { reply($held); undef $held; }
    elsif ($late_open) { $overtaken = 1; }
  } elsif ($type == 7 || $type == 17) {
    my $path = take(\$rest);
    if ($absent{$path} || ($path =~ m{^/up/} && $path !~ m{/\.termi-upload-}) || $path eq '/tree/sub/f.txt') { status($id, 2); }
    elsif ($type == 7 && $link{$path}) { reply(pack('CN', 105, $id) . attrs(0120777)); }
    elsif ($path =~ m{^/owned/} && $path !~ m{/\.termi-upload-}) { reply(pack('CN', 105, $id) . pack('NNNN', 0x6, 1001, 1001, 0100644)); }
    elsif ($type == 17 && $target{$path}) { reply(pack('CN', 105, $id) . attrs($target{$path})); }
    else { reply(pack('CN', 105, $id) . attrs(defined entries($path) ? 040755 : 0100644)); }
  } elsif ($type == 13 || $type == 15) {
    my $path = take(\$rest);
    note(($type == 13 ? 'REMOVE ' : 'RMDIR ') . $path) unless $path =~ m{/\.termi-upload-mode-};
    status($id, 0);
  } elsif ($type == 16) {
    my $path = take(\$rest);
    if ($path =~ m{^/rp/fail}) { status($id, 2); }
    else {
      my $answer = exists $real{$path} ? $real{$path} : $path;
      reply(pack('CNN', 104, $id, 1) . str($answer) . str($answer) . attrs(040755));
    }
  } elsif ($type == 3) {
    my $path = take(\$rest);
    note('OPEN ' . $path) unless $path =~ m{/\.termi-upload-};
    reply(pack('CN', 102, $id) . str('f:' . $path));
  } elsif ($type == 8) {
    my $h = take(\$rest);
    if ($h =~ m{^f:/owned/\.termi-upload-}) { reply(pack('CN', 105, $id) . pack('NNNNNN', 0x7, 0, 0, 501, 20, 0100644)); }
    elsif ($h =~ m{^f:/owned/}) { reply(pack('CN', 105, $id) . pack('NNNNNN', 0x7, 0, 0, 1001, 1001, 0100644)); }
    else { reply(pack('CN', 105, $id) . pack('NNNN', 0x5, 0, ($h =~ m{^f:/proc/} ? 0 : 7), 0100644)); }
  } elsif ($type == 10) {
    my $h = take(\$rest);
    my $flags = unpack('N', substr($rest, 0, 4));
    note('FSETSTAT ' . ($flags & 0x2 ? 'owner' : $flags & 0x4 ? 'mode' : $flags & 0x1 ? 'size' : 'other'))
      unless $h =~ m{/\.termi-upload-} && !($h =~ m{^f:/owned/});
    status($id, ($h =~ m{^f:/owned/} && ($flags & 0x2)) ? 3 : 0);
  } elsif ($type == 5) {
    my $h = take(\$rest);
    my ($high, $low) = unpack('NN', substr($rest, 0, 8));
    if ($h =~ m{^f:/proc/}) {
      if ($high == 0 && $low == 0) { reply(pack('CN', 103, $id) . str('x' x 32768)); }
      elsif ($high == 0 && $low == 32768) { reply(pack('CN', 103, $id) . str('tail')); }
      else { status($id, 1); }
    } elsif ($high == 0 && $low == 0) {
      my $data = pack('CN', 103, $id) . str('content');
      if ($h =~ m{^f:/slow/}) { $slow = $data; note('HELD ' . substr($h, 2)); } else { reply($data); }
    } else { status($id, 1); }
  } elsif ($type == 6 || $type == 9) {
    status($id, 0);
  } elsif ($type == 14) {
    my $path = take(\$rest);
    note('MKDIR ' . $path);
    status($id, $path =~ m{^/denied/} ? 3 : defined entries($path) ? 4 : 0);
  } elsif ($type == 18 || $type == 200) {
    take(\$rest) if $type == 200;
    my $from = take(\$rest); my $to = take(\$rest);
    # Existing assertions describe the file published; temporary stages are tested against
    # the real sftp-server above. Keep byte-exact destination checks here.
    note($from =~ m{/\.termi-upload-} ? 'OPEN ' . $to : 'RENAME ' . $from . ' -> ' . $to);
    status($id, 0);
  } else { status($id, 8); }
}
"""#

/// A client connected to `hostileSFTPServer`, and the file its requests are logged to.
/// Nil when the system has no Perl to run it with.
private func sftpHostileClient(in scratch: URL, atomicRename: Bool = true) async throws -> (client: SFTPClient, log: URL)? {
    let perl = "/usr/bin/perl"
    guard FileManager.default.isExecutableFile(atPath: perl) else { return nil }
    let script = scratch.appendingPathComponent("server.pl")
    let source = atomicRename ? hostileSFTPServer : hostileSFTPServer.replacingOccurrences(of: "my $atomic = 1;", with: "my $atomic = 0;")
    try source.write(to: script, atomically: true, encoding: .utf8)
    let log = scratch.appendingPathComponent("requests.log")
    let client = SFTPClient(executable: perl, arguments: [script.path, log.path], environment: [:])
    // Safety net: a server that stops answering fails the test instead of hanging the run.
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak client] in client?.close() }
    try await client.connect()
    return (client, log)
}

@Test func sftpListingDropsNamesThatAreNotFileNames() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }

    let names = try await client.listDirectory("/tree").map(\.name)
    #expect(names == ["ok.txt", "sub"])
}

@Test func sftpRecursiveDeleteStaysInsideItsTree() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }

    try await client.removeRecursively("/tree")

    // Only what is in the tree: nothing is asked to be removed through "..", "a/b" or "".
    let requests = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(requests == ["REMOVE /tree/ok.txt", "REMOVE /tree/sub/inner.txt", "RMDIR /tree/sub", "RMDIR /tree"])
}

// MARK: - Names by their bytes

/// A session on a client of the tests: what the SFTP page works with, with no SSH behind it.
private func sftpTestSession(on client: SFTPClient, home: String = "/home",
                             trash: @escaping @Sendable (URL) throws -> URL = SFTPClient.moveToTrash) -> SFTPSession {
    var host = Termi.Host.defaultValue()
    host.id = 1
    return SFTPSession(host: host, client: client, homeDirectory: home, trash: trash)
}

/// What the scripted server was asked to change, as the bytes it received.
private func sftpRequestLog(_ log: URL) -> Data {
    (try? Data(contentsOf: log)) ?? Data()
}

@Test func sftpListingMarksNamesThatAreNotUTF8() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }

    // The two names with a separator hidden in a character are gone; the rest is listed as
    // sent, including the name that is not UTF-8 — marked, with its bytes kept.
    let entries = try await client.listDirectory("/odd")
    let names = entries.map { Array($0.name.utf8) }
    let expected = ["good.txt", "caf\u{FFFD}", "caf\u{FFFD}", "e\u{301}", "\u{E9}", "\u{E9}"].map { Array($0.utf8) }
    #expect(names == expected)
    #expect(entries.map(\.isNameRepresentable) == [true, false, true, true, true, true])
    #expect(entries.count > 1 && entries[1].rawName == Data([0x63, 0x61, 0x66, 0xE9]))

    // As rows: every one its own identity, the name listed twice only once.
    let items = try await sftpTestSession(on: client).list("/odd")
    #expect(items.count == 5)
    #expect(Set(items.map(\.id)).count == 5)
    #expect(items.filter { !$0.isNameRepresentable }.count == 1)
}

@Test func sftpRecursiveDeleteLeavesAFolderWithANameItCannotSend() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }

    let expected = SFTPClient.Failure.unrepresentableName(directory: "/keep")
    do {
        try await client.removeRecursively("/keep")
        Issue.record("the folder holds a name that cannot be sent back")
    } catch let failure as SFTPClient.Failure {
        #expect(failure == expected)
    }
    // Not one request: neither for the name as displayed (another file) nor for its siblings.
    #expect(sftpRequestLog(log).isEmpty)
}

@Test func sftpFolderDownloadStopsAtANameItCannotSend() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client)
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let folder = SFTPItem(entry: SFTPClient.DirectoryEntry(
        name: "keep", longName: "", attributes: SFTPClient.Attributes(permissions: 0o040755)), parentPath: "/")

    let expected = SFTPClient.Failure.unrepresentableName(directory: "/keep")
    do {
        _ = try await session.totalSize(of: folder)
        Issue.record("the size of a folder that cannot be read in full is not known")
    } catch let failure as SFTPClient.Failure {
        #expect(failure == expected)
    }
    do {
        _ = try await session.download(folder, into: local) { _ in }
        Issue.record("a partial copy must not be reported as a download")
    } catch let failure as SFTPClient.Failure {
        #expect(failure == expected)
    }
    // No file was asked for, and none was written.
    #expect(sftpRequestLog(log).isEmpty)
    let written = (try? FileManager.default.contentsOfDirectory(atPath: local.appendingPathComponent("keep").path)) ?? []
    #expect(written.isEmpty)
}

@Test func sftpRealPathAcceptsOnlyAnAbsolutePath() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }

    let home = try await client.realPath(".")
    #expect(home == "/home")
    let echoed = try await client.realPath("/srv/data")
    #expect(echoed == "/srv/data")
    // Empty, relative, leading out of the directory, not UTF-8.
    for path in ["/rp/empty", "/rp/rel", "/rp/up", "/rp/bad"] {
        await #expect(throws: SFTPClient.Failure.self, "\(path)") {
            _ = try await client.realPath(path)
        }
    }
}

@Test @MainActor func sftpNavigationStaysWhenThePathCannotBeResolved() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let viewModel = SFTPViewModel()
    viewModel.adopt(sftpTestSession(on: client))
    #expect(viewModel.remotePath == "/home")

    // The server cannot resolve it, or answers with something that is not a path: the typed
    // text does not become the current directory.
    for typed in ["/rp/fail/backup", "/rp/rel", "/rp/empty"] {
        viewModel.remoteActionError = nil
        await viewModel.navigateRemote(to: typed)
        #expect(viewModel.remotePath == "/home", "\(typed)")
        // Said in an alert: the rows of the folder that is open stay in the panel.
        #expect(viewModel.remoteActionError != nil, "\(typed)")
        #expect(viewModel.remoteError == nil, "\(typed)")
        #expect(!viewModel.canGoBack, "\(typed)")
    }

    await viewModel.navigateRemote(to: "/tree")
    #expect(viewModel.remotePath == "/tree")
    #expect(viewModel.remoteItems.map(\.name) == ["sub", "ok.txt"])
}

// MARK: - Uploads

@Test func sftpUploadNeedsAFileName() async throws {
    let name = try SFTPSession.uploadName(of: URL(fileURLWithPath: "/tmp/site/index.html"))
    #expect(name == "index.html")
    // A volume, and URLs that end in "." or "..": joined to the remote folder they would be
    // that folder itself or its parent.
    for path in ["/", "/tmp/site/..", "/tmp/site/."] {
        #expect(throws: SFTPServiceError.self, "\(path)") {
            _ = try SFTPSession.uploadName(of: URL(fileURLWithPath: path))
        }
    }

    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client)
    let inside = scratch.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: scratch.appendingPathComponent("secret.txt"))

    // scratch/site/.. is the scratch folder: its files must not land in /home's parent.
    await #expect(throws: SFTPServiceError.self) {
        _ = try await session.upload(inside.appendingPathComponent(".."), into: "/home") { _ in }
    }
    #expect(sftpRequestLog(log).isEmpty)
}

private func sftpTransferFailed(_ transfer: TransferItem) -> Bool {
    if case .failed = transfer.state { return true }
    return false
}

/// A denied SFTP status. Matched here, not inside `#expect` (Swift 6.0).
private func isSFTPPermissionDenied(_ error: any Error) -> Bool {
    guard case SFTPClient.Failure.status(let code, _) = error else { return false }
    return code == SFTPClient.Failure.codePermissionDenied
}

@Test @MainActor func sftpUploadOfAVolumeIsRefusedBeforeAnythingIsRead() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let viewModel = SFTPViewModel()
    viewModel.adopt(sftpTestSession(on: client))

    viewModel.upload([URL(fileURLWithPath: "/")], into: "/home")

    // Refused at once: no transfer runs, nothing was sized or sent.
    #expect(viewModel.transfers.count == 1)
    #expect(viewModel.transfers.allSatisfy { sftpTransferFailed($0) })
    #expect(!viewModel.hasActiveTransfers)
    #expect(sftpRequestLog(log).isEmpty)
}

// MARK: - Remote editing: the exact path

@Test @MainActor func sftpEditSavesToTheExactRemotePath() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    // The server has the name precomposed; the file system hands the copy's name back
    // decomposed, which on the server would be another file.
    let remotePath = "/d/caf\u{E9}.conf"
    let copy = try editCopy("caf\u{E9}.conf", in: scratch)
    let viewModel = SFTPViewModel()
    viewModel.adopt(sftpTestSession(on: client))
    let item = RemoteEditItem(remotePath: remotePath, localURL: copy,
                              lastUploadedModification: try modificationDate(of: copy)?.addingTimeInterval(-60))
    viewModel.editItems = [item]

    await viewModel.uploadIfChanged(item.id)

    #expect(sftpRequestLog(log) == Data("OPEN \(remotePath)\n".utf8))
    #expect(viewModel.editItems.first?.uploadFailed == false)
    #expect(viewModel.unsyncedEditCount == 0)
}

@Test @MainActor func sftpEditMovesWithARenamedFolderAndEndsWithADeletedFile() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let trash = scratch.appendingPathComponent("trash", isDirectory: true)
    let viewModel = SFTPViewModel()
    viewModel.moveToTrash = scratchTrash(trash)
    viewModel.adopt(sftpTestSession(on: client))

    let inFolder = try editCopy("app.conf", in: scratch)
    let synced = try editCopy("synced.conf", in: scratch)
    let unsynced = try editCopy("unsynced.conf", in: scratch)
    let other = try editCopy("other.conf", in: scratch)
    viewModel.editItems = [
        RemoteEditItem(remotePath: "/etc/app/conf.d/app.conf", localURL: inFolder,
                       lastUploadedModification: try modificationDate(of: inFolder)),
        RemoteEditItem(remotePath: "/data/synced.conf", localURL: synced,
                       lastUploadedModification: try modificationDate(of: synced)),
        RemoteEditItem(remotePath: "/data/unsynced.conf", localURL: unsynced,
                       lastUploadedModification: try modificationDate(of: unsynced), uploadFailed: true),
        RemoteEditItem(remotePath: "/data/synced.conf.bak", localURL: other,
                       lastUploadedModification: try modificationDate(of: other))
    ]

    // Renaming a folder above a file being edited: its saves go to where the file is now.
    viewModel.renameTarget = SFTPItem(entry: SFTPClient.DirectoryEntry(
        name: "app", longName: "", attributes: SFTPClient.Attributes(permissions: 0o040755)), parentPath: "/etc")
    viewModel.renameValue = "site"
    await viewModel.renameRemoteItem()
    #expect(viewModel.editItems.map(\.remotePath)
        == ["/etc/site/conf.d/app.conf", "/data/synced.conf", "/data/unsynced.conf", "/data/synced.conf.bak"])

    // Deleting files being edited ends those edits; a later save cannot bring them back.
    await viewModel.deleteRemoteItems([
        SFTPItem(entry: sftpFileEntry("synced.conf"), parentPath: "/data"),
        SFTPItem(entry: sftpFileEntry("unsynced.conf"), parentPath: "/data")
    ])
    #expect(viewModel.editItems.map(\.remotePath) == ["/etc/site/conf.d/app.conf", "/data/synced.conf.bak"])
    // The copy the server had in full is deleted; the one it never received is in the Trash.
    #expect(!FileManager.default.fileExists(atPath: synced.path))
    #expect(!FileManager.default.fileExists(atPath: trash.appendingPathComponent("synced.conf").path))
    let recovered = try Data(contentsOf: trash.appendingPathComponent("unsynced.conf"))
    #expect(recovered == Data("unsynced.conf".utf8))
    #expect(FileManager.default.fileExists(atPath: other.path))
    #expect(FileManager.default.fileExists(atPath: inFolder.path))

    let requests = String(decoding: sftpRequestLog(log), as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(requests == ["RENAME /etc/app -> /etc/site", "REMOVE /data/synced.conf", "REMOVE /data/unsynced.conf"])
}

// MARK: - Remote editing: what is removed when an edit ends

@Test @MainActor func sftpStopEditingTrashesWhatElseIsInTheCopysFolder() throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let copy = try editCopy("nginx.conf", in: scratch)
    // Saved under another name from the editor, next to the copy: the server has none of it.
    let savedAs = copy.deletingLastPathComponent().appendingPathComponent("nginx-new.conf")
    try Data("new".utf8).write(to: savedAs)
    let trash = scratch.appendingPathComponent("trash", isDirectory: true)

    let viewModel = SFTPViewModel()
    viewModel.moveToTrash = scratchTrash(trash)
    let item = RemoteEditItem(remotePath: "/etc/nginx/nginx.conf", localURL: copy,
                              lastUploadedModification: try modificationDate(of: copy))
    viewModel.editItems = [item]

    viewModel.stopEditing(item.id)

    let kept = try Data(contentsOf: trash.appendingPathComponent("nginx-new.conf"))
    #expect(kept == Data("new".utf8))
    // The copy itself is on the server in full: deleted, not trashed. Its folder is gone.
    #expect(!FileManager.default.fileExists(atPath: trash.appendingPathComponent("nginx.conf").path))
    #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
    #expect(viewModel.notice?.text.contains("nginx-new.conf") == true)
}

@Test @MainActor func sftpStopEditingOnlyTouchesTheFolderMadeForTheCopy() throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    // Another file being edited, in the folder next door.
    let neighbour = try editCopy("neighbour.conf", in: scratch)
    let folder = scratch.appendingPathComponent("edit-own", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // A copy that ended up outside its folder, as a name with a hidden ".." would put it.
    let stray = folder.appendingPathComponent("..").appendingPathComponent("stray.conf")
    try Data("stray".utf8).write(to: stray)
    let trash = scratch.appendingPathComponent("trash", isDirectory: true)

    let viewModel = SFTPViewModel()
    viewModel.moveToTrash = scratchTrash(trash)
    let item = RemoteEditItem(remotePath: "/etc/stray.conf", localURL: stray, folder: folder,
                              lastUploadedModification: try modificationDate(of: stray))
    viewModel.editItems = [item]
    // Without the folder it was made in, a path like this names none to clean up.
    #expect(RemoteEditItem(remotePath: "/etc/stray.conf", localURL: stray).folder == nil)

    viewModel.stopEditing(item.id)

    // Only the folder made for this copy went — not the one its path leads through.
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    let untouched = try Data(contentsOf: neighbour)
    #expect(untouched == Data("neighbour.conf".utf8))
    #expect(!FileManager.default.fileExists(atPath: trash.path))
}

@Test @MainActor func sftpEditDownloadFinishingAfterTheSessionChangedIsNotRegistered() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let viewModel = SFTPViewModel()
    viewModel.moveToTrash = scratchTrash(scratch.appendingPathComponent("trash", isDirectory: true))
    // A folder of the test's for the copy and no editor: should the copy be registered after
    // all, the test fails without opening an app or leaving a file outside its folder.
    let copies = scratch.appendingPathComponent("edit", isDirectory: true)
    viewModel.editFolder = copies
    viewModel.editorForTests = { _ in }
    viewModel.adopt(sftpTestSession(on: client))
    let file = SFTPItem(entry: sftpFileEntry("held.conf"), parentPath: "/slow")

    // The server keeps the file's content until its next request. Once it says it holds it,
    // the download is under way on the session the page had.
    let editing = Task { @MainActor in await viewModel.edit(file) }
    for _ in 0..<600 where !sftpRequestLines(log).contains("HELD /slow/held.conf") {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    // Meanwhile the page gets another session; the next request lets the download finish.
    viewModel.adopt(sftpTestSession(on: client))
    _ = try await client.realPath("/")
    await editing.value

    // Not an edit of the new session (its saves would go to the same path on another host),
    // and the copy, which the server it came from has in full, is not left behind.
    #expect(viewModel.editItems.isEmpty)
    #expect(viewModel.remoteError == nil)
    let left = (try? FileManager.default.subpathsOfDirectory(atPath: copies.path)) ?? []
    #expect(left.filter { $0.hasSuffix("held.conf") } == [])
}

// MARK: - Bounds on what a server describes

private func sftpFolderItem(_ name: String, in parent: String = "/") -> SFTPItem {
    SFTPItem(entry: SFTPClient.DirectoryEntry(
        name: name, longName: "", attributes: SFTPClient.Attributes(permissions: 0o040755)), parentPath: parent)
}

private func sftpRequestLines(_ log: URL) -> [String] {
    String(decoding: sftpRequestLog(log), as: UTF8.self).split(separator: "\n").map(String.init)
}

@Test func sftpListingThatNeverEndsIsAnError() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }

    // One more entry with every answer and never an end: an error at the bound, not a listing
    // cut off there (which a delete or a download would take for the whole directory).
    let tooLarge = SFTPClient.Failure.listingTooLarge(directory: "/loop", limit: 50)
    do {
        _ = try await client.listDirectory("/loop", maxEntries: 50)
        Issue.record("a listing without end was returned")
    } catch let failure as SFTPClient.Failure {
        #expect(failure == tooLarge)
    }
    // Answers that list nothing and never end either.
    let stalled = SFTPClient.Failure.listingTooLarge(directory: "/stall", limit: SFTPClient.maxDirectoryEntries)
    do {
        _ = try await client.listDirectory("/stall")
        Issue.record("a listing without end was returned")
    } catch let failure as SFTPClient.Failure {
        #expect(failure == stalled)
    }
    // The session is still usable, and a real listing is not affected by its bound.
    let names = try await client.listDirectory("/tree", maxEntries: 9).map(\.name)
    #expect(names == ["ok.txt", "sub"])
}

@Test func sftpTreeWithoutBottomIsAnError() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client)

    // Every directory below /deep holds another one.
    let expected = SFTPClient.Failure.treeTooDeep(path: "/deep")
    do {
        try await client.removeRecursively("/deep")
        Issue.record("a tree without bottom was walked to its end")
    } catch let failure as SFTPClient.Failure {
        #expect(failure == expected)
    }
    do {
        _ = try await session.totalSize(of: sftpFolderItem("deep"))
        Issue.record("a tree without bottom has no size")
    } catch let failure as SFTPClient.Failure {
        #expect(failure == expected)
    }
    // Nothing was removed on the way down.
    #expect(sftpRequestLog(log).isEmpty)
}

@Test func sftpSizesAreSummedWithoutOverflow() async throws {
    #expect(SFTPSession.saturatingSum(1, 2) == 3)
    #expect(SFTPSession.saturatingSum(Int64.max, Int64.max) == Int64.max)
    #expect(SFTPSession.saturatingSum(Int64.max - 1, 5) == Int64.max)

    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    // Two files that each report the largest size there is.
    let total = try await sftpTestSession(on: client).totalSize(of: sftpFolderItem("huge"))
    #expect(total == Int64.max)
}

// MARK: - What a folder download leaves out

@Test func sftpSpecialFilesAreNotDownloaded() async throws {
    // Told by the type bits. No permissions at all says nothing about the type.
    let pipe = SFTPItem(entry: SFTPClient.DirectoryEntry(
        name: "pipe", longName: "", attributes: SFTPClient.Attributes(permissions: 0o010644)), parentPath: "/special")
    let unknown = SFTPItem(entry: SFTPClient.DirectoryEntry(
        name: "data.txt", longName: "", attributes: SFTPClient.Attributes()), parentPath: "/special")
    #expect(pipe.isSpecialFile)
    #expect(!unknown.isSpecialFile)
    #expect(!SFTPItem(entry: sftpFileEntry("a"), parentPath: "/").isSpecialFile)
    #expect(!sftpFolderItem("special").isSpecialFile)

    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client, trash: scratchTrash(scratch.appendingPathComponent("trash")))
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

    // Picked on its own: refused, and never opened.
    let refused = SFTPServiceError.notDownloadable("pipe")
    do {
        _ = try await session.download(pipe, into: local) { _ in }
        Issue.record("a pipe was downloaded")
    } catch let error as SFTPServiceError {
        #expect(error == refused)
    }
    #expect(sftpRequestLog(log).isEmpty)

    // In a folder: the file next to them is downloaded, they are left out and counted.
    let result = try await session.download(sftpFolderItem("special"), into: local) { _ in }
    #expect(sftpRequestLines(log) == ["OPEN /special/data.txt"])
    #expect(result.skipped.count == 4)
    #expect(Set(result.skipped.examples) == ["/special/pipe", "/special/tty", "/special/disk", "/special/sock"])
    let names = try FileManager.default.contentsOfDirectory(atPath: local.appendingPathComponent("special").path)
    #expect(names == ["data.txt"])
}

@Test func sftpLinkToASpecialFileIsNotOpened() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client, trash: scratchTrash(scratch.appendingPathComponent("trash")))
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

    // The row is a link (its own mode says nothing); behind it the server finds a pipe.
    let listed = try await session.list("/pipes").first { $0.name == "fifo-link" }
    let link = try #require(listed)
    #expect(link.isSymlink)
    #expect(link.isSpecialFile)

    // Opening the link would open the pipe: refused on its own, left out of a folder.
    let refused = SFTPServiceError.notDownloadable("fifo-link")
    do {
        _ = try await session.download(link, into: local) { _ in }
        Issue.record("a link to a pipe was opened")
    } catch let error as SFTPServiceError {
        #expect(error == refused)
    }
    #expect(sftpRequestLog(log).isEmpty)
    let result = try await session.download(sftpFolderItem("pipes"), into: local) { _ in }
    #expect(sftpRequestLines(log) == ["OPEN /pipes/data.txt"])
    #expect(result.skipped.examples == ["/pipes/fifo-link"])
}

@Test @MainActor func sftpTransferResultSaysWhatWasSkipped() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let viewModel = SFTPViewModel()
    viewModel.localPath = local.path
    viewModel.adopt(sftpTestSession(on: client, trash: scratchTrash(scratch.appendingPathComponent("trash"))))

    viewModel.download([sftpFolderItem("special")], into: local)
    // The transfer runs in a task of the view model; the safety net of the client ends it at
    // the latest.
    for _ in 0..<300 where viewModel.hasActiveTransfers {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    #expect(viewModel.transfers.count == 1)
    #expect(viewModel.transfers.first?.state == .completed)
    #expect(viewModel.transfers.first?.skipped.count == 4)
}

@Test @MainActor func sftpTransferWithSkippedItemsShowsAllBytesItTransferred() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let viewModel = SFTPViewModel()
    viewModel.localPath = local.path
    viewModel.adopt(sftpTestSession(on: client, trash: scratchTrash(scratch.appendingPathComponent("trash"))))

    // Two files of 7 bytes and a pipe. Progress is reported at most every 100 ms, so the
    // second file's bytes are not among the reports that arrive before the transfer is done.
    viewModel.download([sftpFolderItem("pair")], into: local)
    for _ in 0..<300 where viewModel.hasActiveTransfers {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    #expect(viewModel.transfers.first?.state == .completed)
    #expect(viewModel.transfers.first?.skipped.count == 1)
    #expect(viewModel.transfers.first?.transferredBytes == 14)
}

@Test @MainActor func sftpTwoSelectedItemsThatAreOneNameHereAreNotBothDownloaded() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let trash = scratch.appendingPathComponent("trash", isDirectory: true)
    // One name on the usual volume of a Mac; two where the volume tells case apart.
    let folds = !SFTPSession.volumeIsCaseSensitive(at: local)
    let viewModel = SFTPViewModel()
    viewModel.localPath = local.path
    viewModel.adopt(sftpTestSession(on: client, trash: scratchTrash(trash)))

    let items = ["Makefile", "makefile"].map { SFTPItem(entry: sftpFileEntry($0), parentPath: "/src") }
    viewModel.download(items, into: local)
    for _ in 0..<300 where viewModel.hasActiveTransfers {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    // The second is refused with a reason, before anything is asked of the server: it would
    // have moved the first one's file to the Trash and taken its place.
    #expect(viewModel.transfers.count == 2)
    let failed = viewModel.transfers.filter { sftpTransferFailed($0) }.map(\.name)
    #expect(failed == (folds ? ["makefile"] : []))
    #expect(sftpRequestLines(log).count == (folds ? 1 : 2))
    #expect(!FileManager.default.fileExists(atPath: trash.path))
}

@Test func sftpDownloadLetsTheFileSystemSayWhichNamesAreOne() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    // Whether this volume takes "straße" and "STRASSE" for one name (APFS does, unless it is
    // case-sensitive) — which lower-casing the two does not show.
    let probe = scratch.appendingPathComponent("probe", isDirectory: true)
    try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
    try Data().write(to: probe.appendingPathComponent("stra\u{DF}e.txt"))
    let folds = FileManager.default.fileExists(atPath: probe.appendingPathComponent("STRASSE.txt").path)

    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let trash = scratch.appendingPathComponent("trash", isDirectory: true)
    let session = sftpTestSession(on: client, trash: scratchTrash(trash))
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

    // In a folder: the first stays, the second is left out and counted.
    let result = try await session.download(sftpFolderItem("folded"), into: local) { _ in }
    #expect(result.skipped.count == (folds ? 1 : 0))
    #expect(!FileManager.default.fileExists(atPath: trash.path))
    let names = try FileManager.default.contentsOfDirectory(atPath: local.appendingPathComponent("folded").path)
    #expect(names.count == (folds ? 1 : 2))

    // Picked side by side, as two downloads of one selection: the second is refused.
    let flat = scratch.appendingPathComponent("flat", isDirectory: true)
    try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
    let first = SFTPItem(entry: sftpFileEntry("stra\u{DF}e.txt"), parentPath: "/folded")
    let second = SFTPItem(entry: sftpFileEntry("STRASSE.txt"), parentPath: "/folded")
    let twins = SFTPLocalTwins()
    _ = try await session.download(first, into: flat, twins: twins) { _ in }
    if folds {
        let refused = SFTPServiceError.sameNameHere("STRASSE.txt")
        do {
            _ = try await session.download(second, into: flat, twins: twins) { _ in }
            Issue.record("the twin took the place of the file just downloaded")
        } catch let error as SFTPServiceError {
            #expect(error == refused)
        }
    }
    #expect(!FileManager.default.fileExists(atPath: trash.path))

    // A download of its own replaces what is there, as ever: the old file goes to the Trash.
    _ = try await session.download(second, into: flat) { _ in }
    #expect(FileManager.default.fileExists(atPath: trash.path) == folds)
}

@Test func sftpFolderDownloadKeepsTheFirstOfTwoNamesThatAreOneHere() async throws {
    // Case is folded where the volume does not keep it; how an accent is encoded never counts.
    #expect(SFTPSession.localNameKey("stra\u{DF}e", caseSensitive: false) == SFTPSession.localNameKey("STRASSE", caseSensitive: false))
    #expect(SFTPSession.localNameKey("\u{1E9E}", caseSensitive: false) == SFTPSession.localNameKey("\u{DF}", caseSensitive: false))
    #expect(SFTPSession.localNameKey("Makefile", caseSensitive: false) == SFTPSession.localNameKey("makefile", caseSensitive: false))
    #expect(SFTPSession.localNameKey("Makefile", caseSensitive: true) != SFTPSession.localNameKey("makefile", caseSensitive: true))
    #expect(SFTPSession.localNameKey("caf\u{E9}", caseSensitive: true) == SFTPSession.localNameKey("cafe\u{301}", caseSensitive: true))

    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let trash = scratch.appendingPathComponent("trash", isDirectory: true)
    let session = sftpTestSession(on: client, trash: scratchTrash(trash))
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

    // /twins lists "café" precomposed and decomposed: two files there, one name here.
    let result = try await session.download(sftpFolderItem("twins"), into: local) { _ in }

    #expect(result.skipped.count == 1)
    // One of the two was asked for, and the file it became was not moved to the Trash by the other.
    #expect(sftpRequestLines(log).count == 2)
    #expect(sftpRequestLines(log).contains("OPEN /twins/plain.txt"))
    #expect(!FileManager.default.fileExists(atPath: trash.path))
    let names = try FileManager.default.contentsOfDirectory(atPath: local.appendingPathComponent("twins").path)
    #expect(names.count == 2)
}

@Test func sftpFolderDownloadDoesNotWriteThroughALocalLink() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client, trash: scratchTrash(scratch.appendingPathComponent("trash")))
    // From an earlier download: local/tree, in which "sub" is a link to a folder elsewhere.
    let outside = scratch.appendingPathComponent("outside", isDirectory: true)
    let tree = scratch.appendingPathComponent("local", isDirectory: true).appendingPathComponent("tree", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    let link = tree.appendingPathComponent("sub")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    // The server lists "sub" as a folder with a file in it.
    let inTheWay = SFTPServiceError.localItemInTheWay(link.path)
    do {
        _ = try await session.download(sftpFolderItem("tree"), into: tree.deletingLastPathComponent()) { _ in }
        Issue.record("the download went through the link")
    } catch let error as SFTPServiceError {
        #expect(error == inTheWay)
    }
    let leaked = try FileManager.default.contentsOfDirectory(atPath: outside.path)
    #expect(leaked.isEmpty)

    // A real folder there is merged into, and one that is missing is made.
    let merged = scratch.appendingPathComponent("merged", isDirectory: true)
    try FileManager.default.createDirectory(at: merged.appendingPathComponent("tree/sub"), withIntermediateDirectories: true)
    for parent in [merged, scratch.appendingPathComponent("fresh", isDirectory: true)] {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = try await session.download(sftpFolderItem("tree"), into: parent) { _ in }
        let inner = try Data(contentsOf: parent.appendingPathComponent("tree/sub/inner.txt"))
        #expect(inner == Data("content".utf8))
    }
}

@Test func sftpDownloadReadsToTheEndOfAFileThatReportsNoSize() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let destination = scratch.appendingPathComponent("status")

    // As in /proc: FSTAT says 0 bytes, reading yields a full block and then some.
    let received = try await client.download("/proc/status", to: destination)

    #expect(received == 32772)
    let downloaded = try Data(contentsOf: destination)
    #expect(downloaded == Data(repeating: UInt8(ascii: "x"), count: 32768) + Data("tail".utf8))
}

// MARK: - Rename never replaces

@Test func sftpRenameRefusesANameThatIsTaken() async throws {
    #expect(SFTPSession.isSameNameWhenFolded("readme", "README"))
    #expect(SFTPSession.isSameNameWhenFolded("stra\u{DF}e", "STRASSE"))
    #expect(SFTPSession.isSameNameWhenFolded("caf\u{E9}", "cafe\u{301}"))
    #expect(!SFTPSession.isSameNameWhenFolded("readme", "readme2"))
    #expect(SFTPClient.name(of: "/tree/ok.txt") == "ok.txt")
    #expect(SFTPClient.name(of: "/tree/sub/") == "sub")
    #expect(Array(SFTPClient.name(of: "/d/\u{301}x").utf8) == Array("\u{301}x".utf8))

    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client)

    // Something is at the new path (the folder "sub"): refused, and no rename is sent — the
    // server would replace it.
    let taken = SFTPServiceError.nameTaken("sub")
    do {
        try await session.rename("/tree/ok.txt", to: "/tree/sub")
        Issue.record("renamed onto another item")
    } catch let error as SFTPServiceError {
        #expect(error == taken)
    }
    // Only the case differs, but the two names are different items (a file and a folder).
    let takenByFolder = SFTPServiceError.nameTaken("Sub")
    do {
        try await session.rename("/tree/sub", to: "/tree/Sub")
        Issue.record("renamed onto another item")
    } catch let error as SFTPServiceError {
        #expect(error == takenByFolder)
    }
    // Only the case differs and both names answer alike (same size, owner, mode, time), but
    // the directory lists both: two files, and the other one is not replaced.
    let takenByTwin = SFTPServiceError.nameTaken("NOTES")
    do {
        try await session.rename("/case/notes", to: "/case/NOTES")
        Issue.record("renamed onto another file")
    } catch let error as SFTPServiceError {
        #expect(error == takenByTwin)
    }
    #expect(sftpRequestLog(log).isEmpty)

    // A free name; and a change of case where both names are the same file to the server.
    try await session.rename("/tree/ok.txt", to: "/tree/free.txt")
    try await session.rename("/tree/ok.txt", to: "/tree/OK.txt")
    #expect(sftpRequestLines(log) == ["RENAME /tree/ok.txt -> /tree/free.txt", "RENAME /tree/ok.txt -> /tree/OK.txt"])
}

@Test @MainActor func sftpRenameOntoATakenNameSaysSoAndChangesNothing() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let viewModel = SFTPViewModel()
    viewModel.adopt(sftpTestSession(on: client))

    // ".env" is not shown while hidden files are off, and is there all the same.
    viewModel.renameTarget = SFTPItem(entry: sftpFileEntry("env.new"), parentPath: "/tree")
    viewModel.renameValue = ".env"
    await viewModel.renameRemoteItem()

    #expect(viewModel.remoteActionError == SFTPServiceError.nameTaken(".env").localizedDescription)
    #expect(viewModel.remoteError == nil)
    #expect(sftpRequestLog(log).isEmpty)
}

// MARK: - What a folder upload leaves out

@Test func sftpFolderUploadFollowsOnlyLinksThatStayInside() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client)
    let fm = FileManager.default
    let folder = scratch.appendingPathComponent("site", isDirectory: true)
    try fm.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try Data("secret".utf8).write(to: scratch.appendingPathComponent("secret.txt"))
    try Data("real".utf8).write(to: folder.appendingPathComponent("real.txt"))
    try fm.createSymbolicLink(atPath: folder.appendingPathComponent("inside.txt").path, withDestinationPath: "real.txt")
    try fm.createSymbolicLink(atPath: folder.appendingPathComponent("outside.txt").path, withDestinationPath: "../secret.txt")
    try fm.createSymbolicLink(atPath: folder.appendingPathComponent("assets-link").path, withDestinationPath: "assets")
    try fm.createSymbolicLink(atPath: folder.appendingPathComponent("dangling").path, withDestinationPath: "nowhere")

    let result = try await session.upload(folder, into: "/up") { _ in }

    // The link to a file of the folder is uploaded as that file. The one that leads out of the
    // folder is not: the user picked the folder, not what a link in it points at.
    let requests = Set(sftpRequestLines(log))
    #expect(requests == ["MKDIR /up/site", "MKDIR /up/site/assets", "OPEN /up/site/real.txt", "OPEN /up/site/inside.txt"])
    #expect(result.skipped.count == 3)
    #expect(Set(result.skipped.examples.map { URL(fileURLWithPath: $0).lastPathComponent })
        == ["outside.txt", "assets-link", "dangling"])

    // Picked by the user itself, a link is uploaded as what it points at.
    try await session.upload(folder.appendingPathComponent("outside.txt"), into: "/up") { _ in }
    #expect(sftpRequestLines(log).last == "OPEN /up/outside.txt")
}

@Test func sftpFolderUploadMergesOnlyIntoAFolderThatIsThere() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client)
    // A local folder "sub" with one file; the server has a folder /tree/sub and none below /denied.
    let folder = scratch.appendingPathComponent("sub", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: folder.appendingPathComponent("f.txt"))

    // MKDIR fails for want of permission, and no folder is there: that is the upload's error,
    // and no file is sent after it.
    let denied = SFTPClient.Failure.status(code: SFTPClient.Failure.codePermissionDenied, message: "")
    do {
        _ = try await session.upload(folder, into: "/denied") { _ in }
        Issue.record("the upload went on without its folder")
    } catch let failure as SFTPClient.Failure {
        #expect(failure == denied)
    }
    #expect(sftpRequestLines(log) == ["MKDIR /denied/sub"])

    // MKDIR fails because the folder exists: merged into.
    _ = try await session.upload(folder, into: "/tree") { _ in }
    #expect(sftpRequestLines(log) == ["MKDIR /denied/sub", "MKDIR /tree/sub", "OPEN /tree/sub/f.txt"])
}

@Test func sftpFolderUploadDoesNotWriteThroughARemoteLink() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client)
    // A local folder "merge" holding a folder "site" with one file. On the server /merge is a
    // folder, and "site" in it is a link to a folder somewhere else.
    let folder = scratch.appendingPathComponent("merge", isDirectory: true)
    let site = folder.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: site.appendingPathComponent("index.html"))

    let inTheWay = SFTPServiceError.remoteItemInTheWay("/merge/site")
    do {
        _ = try await session.upload(folder, into: "/") { _ in }
        Issue.record("the upload went through the link")
    } catch let error as SFTPServiceError {
        #expect(error == inTheWay)
    }
    // /merge itself is merged into; nothing is written to where the link leads.
    #expect(sftpRequestLines(log) == ["MKDIR /merge", "MKDIR /merge/site"])
}

// MARK: - The panels act on what they show

@Test @MainActor func sftpLateListingNeverPutsItsRowsUnderAnotherPath() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let viewModel = SFTPViewModel()
    viewModel.adopt(sftpTestSession(on: client))
    // Nothing is listed yet.
    #expect(!viewModel.remoteListingIsCurrent)

    await viewModel.navigateRemote(to: "/tree")
    #expect(viewModel.remoteListingIsCurrent)
    let rows = viewModel.remoteItems
    #expect(rows.map(\.name) == ["sub", "ok.txt"])
    #expect(viewModel.remotePanelShows(rows))
    let folder = try #require(rows.first)

    // The server holds the listing of /late back until the next directory has been listed.
    let entering = Task { @MainActor in await viewModel.navigateRemote(to: "/late") }
    for _ in 0..<100 where viewModel.remotePath != "/late" {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try await Task.sleep(nanoseconds: 300_000_000)

    // The path bar names /late, the rows are still those of /tree: nothing is done with them,
    // and nothing is put into "the current folder".
    #expect(viewModel.remotePath == "/late")
    #expect(viewModel.remoteItems.map(\.name) == ["sub", "ok.txt"])
    #expect(!viewModel.remoteListingIsCurrent)
    #expect(!viewModel.remotePanelShows(rows))
    viewModel.beginDelete(rows)
    #expect(!viewModel.showingDeleteConfirm)
    viewModel.beginRename(folder)
    #expect(!viewModel.showingRename)
    await viewModel.beginPermissions(folder)
    #expect(!viewModel.showingChmod)
    viewModel.beginNewFolder()
    #expect(!viewModel.showingNewFolder)
    #expect(!viewModel.downloadToLocalFolder(rows))
    #expect(!viewModel.uploadToRemoteFolder([scratch.appendingPathComponent("server.pl")]))
    await viewModel.openRemote(folder)
    #expect(viewModel.remotePath == "/late")
    #expect(viewModel.transfers.isEmpty)

    // Back before the listing came. /tree is listed again, and only then does the server
    // answer for /late: that answer is not shown under /tree.
    await viewModel.navigateRemoteBack()
    await entering.value
    #expect(viewModel.remotePath == "/tree")
    #expect(viewModel.remoteItems.map(\.name) == ["sub", "ok.txt"])
    #expect(viewModel.remoteListingIsCurrent)
    #expect(!viewModel.remoteLoading)
    #expect(sftpRequestLog(log).isEmpty)
}

@Test @MainActor func sftpSelectionHoldsOnlyRowsThatAreShown() {
    let hidden = SFTPItem(entry: sftpFileEntry(".env"), parentPath: "/d")
    let plain = SFTPItem(entry: sftpFileEntry("a.txt"), parentPath: "/d")
    let viewModel = SFTPViewModel()

    viewModel.showHiddenRemote = true
    viewModel.remoteItems = [hidden, plain]
    viewModel.selectedRemoteItems = [hidden.id, plain.id]
    #expect(viewModel.selectedRemote.count == 2)
    // Hidden files are switched off: what is no longer shown is no longer selected.
    viewModel.showHiddenRemote = false
    #expect(viewModel.selectedRemoteItems == Set([plain.id]))
    #expect(viewModel.selectedRemote.map(\.name) == ["a.txt"])
    // Whatever the set holds, the items acted on are rows that are shown.
    viewModel.selectedRemoteItems = [hidden.id, plain.id]
    #expect(viewModel.selectedRemote.map(\.name) == ["a.txt"])

    // The local panel alike: a hidden file must not be uploaded or trashed unseen.
    viewModel.showHiddenLocal = true
    viewModel.localItems = [hidden, plain]
    viewModel.selectedLocalItems = [hidden.id, plain.id]
    #expect(viewModel.selectedLocal.count == 2)
    viewModel.showHiddenLocal = false
    #expect(viewModel.selectedLocalItems == Set([plain.id]))
    #expect(viewModel.selectedLocal.map(\.name) == ["a.txt"])
}

@Test @MainActor func sftpDeleteConfirmationNamesWhatIsDeleted() {
    let file = SFTPItem(entry: sftpFileEntry("notes.txt"), parentPath: "/d")
    let one = SFTPViewModel.deleteConfirmation(for: [file])
    #expect(one.contains("notes.txt"))
    // A folder goes with its contents, and the question says so.
    let asFolder = SFTPViewModel.deleteConfirmation(for: [sftpFolderItem("build", in: "/d")])
    let asFile = SFTPViewModel.deleteConfirmation(for: [SFTPItem(entry: sftpFileEntry("build"), parentPath: "/d")])
    #expect(asFolder.contains("build"))
    #expect(asFolder != asFile)

    // Several: how many, and the first of them by name.
    let files = (1...5).map { SFTPItem(entry: sftpFileEntry("f\($0).log"), parentPath: "/d") }
    let several = SFTPViewModel.deleteConfirmation(for: files)
    #expect(several.contains("5"))
    #expect(several.contains("f1.log") && several.contains("f2.log") && several.contains("f3.log"))
    #expect(!several.contains("f4.log") && !several.contains("f5.log"))
}

@Test @MainActor func sftpDragOutOfTheRemotePanelIsAFileOnlyToItsOwnPage() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let trash = scratchTrash(scratch.appendingPathComponent("trash", isDirectory: true))

    // Two windows, both showing a directory /tree — in the app, of two different hosts.
    let source = SFTPViewModel()
    source.localPath = local.path
    source.adopt(sftpTestSession(on: client, trash: trash))
    await source.navigateRemote(to: "/tree")
    let other = SFTPViewModel()
    other.localPath = local.path
    other.adopt(sftpTestSession(on: client, trash: trash))
    await other.navigateRemote(to: "/tree")
    let listed = source.remoteItems.first { $0.name == "ok.txt" }
    let file = try #require(listed)

    // What the drag carries is the same for a row while it is shown, is not what a dragged
    // terminal tab carries (a UUID), and holds nothing the server chose.
    let payload = source.remoteDragPayload(for: file)
    #expect(payload == source.remoteDragPayload(for: file))
    #expect(UUID(uuidString: payload) == nil)
    #expect(!payload.contains("ok.txt") && !payload.contains("tree"))

    // Dropped on the other window it is no file, although that window lists the same path;
    // and a path as text, from anywhere, is none to either.
    #expect(!other.downloadDragged([payload]))
    let asText = ["termi-remote:/tree/ok.txt", "/tree/ok.txt", SFTPViewModel.remoteDragPrefix + "/tree/ok.txt"]
    #expect(!other.downloadDragged(asText))
    #expect(!source.downloadDragged(asText))
    #expect(other.transfers.isEmpty)
    #expect(source.transfers.isEmpty)

    // Dropped on its own window, it is downloaded.
    #expect(source.downloadDragged([payload]))
    for _ in 0..<300 where source.hasActiveTransfers {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(source.transfers.map(\.name) == ["ok.txt"])
    #expect(source.transfers.first?.state == .completed)
    let downloaded = try Data(contentsOf: local.appendingPathComponent("ok.txt"))
    #expect(downloaded == Data("content".utf8))

    // Once the rows were listed anew, a drag from before stands for nothing.
    await source.loadRemoteDirectory()
    #expect(!source.downloadDragged([payload]))
    #expect(source.transfers.count == 1)
}

@Test @MainActor func sftpPermissionsOfALinkAreThoseOfItsTarget() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, _) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let viewModel = SFTPViewModel()
    viewModel.adopt(sftpTestSession(on: client))
    await viewModel.navigateRemote(to: "/links")
    let listedCurrent = viewModel.remoteItems.first { $0.name == "current" }
    let listedDangling = viewModel.remoteItems.first { $0.name == "dangling" }
    let current = try #require(listedCurrent)
    let dangling = try #require(listedDangling)
    // The row is the link, and a link's own mode says "everyone may do everything".
    #expect(current.isSymlink)
    #expect(current.octalPermissions == "777")

    // Changing permissions acts on the target: its mode is what the field offers.
    await viewModel.beginPermissions(current)
    #expect(viewModel.showingChmod)
    #expect(viewModel.chmodTarget == current)
    #expect(viewModel.chmodValue == "600")

    // A link that leads nowhere has no permissions to change: no field, and a reason.
    viewModel.showingChmod = false
    viewModel.chmodTarget = nil
    await viewModel.beginPermissions(dangling)
    #expect(!viewModel.showingChmod)
    #expect(viewModel.chmodTarget == nil)
    #expect(viewModel.remoteActionError != nil)
}

@Test @MainActor func sftpNewFolderNameIsTrimmedAndPermissionsAreOfferedAsTheyAreAccepted() async throws {
    // "44" or "0" would be refused by Apply (three or four octal digits).
    #expect(SFTPItem.octalString(ofMode: 0o100044) == "044")
    #expect(SFTPItem.octalString(ofMode: 0o100000) == "000")
    #expect(SFTPItem.octalString(ofMode: 0o100644) == "644")
    #expect(SFTPItem.octalString(ofMode: 0o104755) == "4755")

    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let viewModel = SFTPViewModel()
    viewModel.adopt(sftpTestSession(on: client))
    await viewModel.navigateRemote(to: "/tree")

    // A pasted name with a space and a line break at its end, as Rename takes it.
    viewModel.beginNewFolder()
    #expect(viewModel.showingNewFolder)
    viewModel.newFolderName = "  logs \n"
    await viewModel.createRemoteFolder()
    #expect(sftpRequestLines(log) == ["MKDIR /tree/logs"])
    #expect(viewModel.remoteError == nil)
    #expect(viewModel.remoteActionError == nil)
}

@Test func sftpDownloadedFilesCarryTheQuarantineMark() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("fix.command")
    try Data("#!/bin/sh\necho hi\n".utf8).write(to: source)
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let destination = local.appendingPathComponent("fix.command")

    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    try await client.download(source.path, to: destination,
                              trash: scratchTrash(scratch.appendingPathComponent("trash", isDirectory: true)))

    // Marked like any downloaded file, so that opening it goes through the system's checks.
    let properties = try destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
    let type = properties?["LSQuarantineType"] as? String
    let agent = properties?["LSQuarantineAgentName"] as? String
    #expect(type == "LSQuarantineTypeOtherDownload")
    #expect(agent == "Termi")
    // The mark changes nothing about the file itself.
    let downloaded = try Data(contentsOf: destination)
    #expect(downloaded == Data("#!/bin/sh\necho hi\n".utf8))
    let untouched = try source.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
    #expect(untouched == nil)
}

@Test func sftpEditsOfTheSameNameAreToldApartByTheirFolder() {
    let live = RemoteEditItem(remotePath: "/etc/nginx/nginx.conf",
                              localURL: URL(fileURLWithPath: "/tmp/edit-a/nginx.conf"))
    let staging = RemoteEditItem(remotePath: "/srv/staging/nginx.conf",
                                 localURL: URL(fileURLWithPath: "/tmp/edit-b/nginx.conf"))
    #expect(live.remoteName == "nginx.conf")
    #expect(staging.remoteName == "nginx.conf")
    #expect(live.remoteFolder == "/etc/nginx")
    #expect(staging.remoteFolder == "/srv/staging")
}

// MARK: - 2026-10-11 review follow-up: uploads on any v3 server, consent where atomic is blocked

/// Sits between the client and the system's sftp-server and removes the permissions from every
/// ATTRS and NAME answer — every attribute is optional in SFTP v3, and some servers send none.
/// Arguments: the folder the server starts in.
private let permissionStrippingRelay = #"""
use strict; use warnings; use IPC::Open2;
binmode(STDIN); binmode(STDOUT);
my $pid = open2(my $from, my $to, '/usr/libexec/sftp-server', '-d', $ARGV[0], '-u', '022');
binmode($from); binmode($to);
sub wr { my ($fh, $data) = @_; my $off = 0;
  while ($off < length($data)) { my $w = syswrite($fh, $data, length($data) - $off, $off); exit 0 unless defined $w; $off += $w; } }
my $copier = fork();
if ($copier == 0) {
  close($from);
  while (1) { my $buf; my $r = sysread(STDIN, $buf, 65536); last unless $r; wr($to, $buf); }
  close($to); exit 0;
}
close($to);
sub rd { my ($n) = @_; my $buf = '';
  while (length($buf) < $n) { my $r = sysread($from, $buf, $n - length($buf), length($buf)); exit 0 unless $r; }
  return $buf; }
sub strip { my ($ref) = @_;
  my $flags = unpack('N', substr($$ref, 0, 4)); my $pos = 4; my $out = '';
  if ($flags & 0x1) { $out .= substr($$ref, $pos, 8); $pos += 8; }
  if ($flags & 0x2) { $out .= substr($$ref, $pos, 8); $pos += 8; }
  if ($flags & 0x4) { $pos += 4; }
  if ($flags & 0x8) { $out .= substr($$ref, $pos, 8); $pos += 8; }
  if ($flags & 0x80000000) {
    my $count = unpack('N', substr($$ref, $pos, 4)); $out .= substr($$ref, $pos, 4); $pos += 4;
    for (1 .. 2 * $count) { my $l = unpack('N', substr($$ref, $pos, 4)); $out .= substr($$ref, $pos, 4 + $l); $pos += 4 + $l; }
  }
  $$ref = substr($$ref, $pos);
  return pack('N', $flags & 0x7FFFFFFB | ($flags & 0x80000000)) . $out; }
while (1) {
  my $len = unpack('N', rd(4)); my $p = rd($len);
  my $type = unpack('C', $p);
  if ($type == 105) { my $rest = substr($p, 5); $p = substr($p, 0, 5) . strip(\$rest) . $rest; }
  elsif ($type == 104) {
    my $count = unpack('N', substr($p, 5, 4)); my $rest = substr($p, 9); my $body = substr($p, 0, 9);
    for (1 .. $count) {
      for (1 .. 2) { my $l = unpack('N', substr($rest, 0, 4)); $body .= substr($rest, 0, 4 + $l); $rest = substr($rest, 4 + $l); }
      $body .= strip(\$rest);
    }
    $p = $body . $rest;
  }
  wr(\*STDOUT, pack('N', length($p)) . $p);
}
"""#

/// A client of the system's sftp-server started in `folder` with these extra options (e.g.
/// "-P setstat,fsetstat"); nil where the system has none.
private func sftpServerClient(in folder: URL, options: String) async throws -> SFTPClient? {
    guard FileManager.default.isExecutableFile(atPath: "/usr/libexec/sftp-server") else { return nil }
    // Positional arguments keep the fixture path out of shell code.
    let client = SFTPClient(executable: "/bin/sh", arguments: ["-c",
        "exec /usr/libexec/sftp-server -d \"$1\" -u 022 \(options)", "sftp-test", folder.path], environment: [:])
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak client] in client?.close() }
    try await client.connect()
    return client
}

private func posixMode(of url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Test(arguments: ["-P remove,rmdir", "-P setstat,fsetstat"])
func sftpNewUploadNeedsNothingButOpenWriteAndClose(options: String) async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("source")
    try Data("new content".utf8).write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
    guard let client = try await sftpServerClient(in: scratch, options: options) else { return }
    defer { client.close() }
    let destination = scratch.appendingPathComponent("drop-off.txt")
    _ = try await client.upload(source, to: destination.path, permissions: 0o644)
    let uploaded = try Data(contentsOf: destination)
    #expect(uploaded == Data("new content".utf8))
    // Nothing is left behind: no probe file, no staged copy.
    let names = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
    #expect(Set(names) == ["source", "drop-off.txt"])
}

@Test func sftpReplaceOfAnOrdinaryFileNeedsNoSetstat() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("source")
    let destination = scratch.appendingPathComponent("config")
    try Data("new".utf8).write(to: source)
    try Data("old".utf8).write(to: destination)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
    guard let client = try await sftpServerClient(in: scratch, options: "-P setstat,fsetstat") else { return }
    defer { client.close() }
    let before = try await client.lstat(destination.path)
    _ = try await client.upload(source, to: destination.path, expectation: .existing(before))
    let replaced = try Data(contentsOf: destination)
    #expect(replaced == Data("new".utf8))
    let mode = try posixMode(of: destination)
    #expect(mode == 0o644)
    let names = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
    #expect(Set(names) == ["source", "config"])
}

@Test func sftpUploadWorksWithAServerThatReportsNoPermissions() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"),
          FileManager.default.isExecutableFile(atPath: "/usr/libexec/sftp-server") else { return }
    let remote = scratch.appendingPathComponent("remote", isDirectory: true)
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let relay = scratch.appendingPathComponent("relay.pl")
    try permissionStrippingRelay.write(to: relay, atomically: true, encoding: .utf8)
    let client = SFTPClient(executable: "/usr/bin/perl", arguments: [relay.path, remote.path], environment: [:])
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak client] in client?.close() }
    try await client.connect()
    defer { client.close() }
    let source = local.appendingPathComponent("app.conf")
    try Data("new contents".utf8).write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)

    let session = sftpTestSession(on: client)
    // A new file: no permissions to read back are needed.
    _ = try await session.upload(source, into: remote.path) { _ in }
    let created = remote.appendingPathComponent("app.conf")
    let createdContent = try Data(contentsOf: created)
    #expect(createdContent == Data("new contents".utf8))
    let reported = try await client.lstat(created.path)
    #expect(reported.permissions == nil)
    #expect(!reported.isKnownNonRegular)

    // A file of that name, of a type the server does not say: asked about, and replaced.
    try Data("old".utf8).write(to: created)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: created.path)
    try Data("newer contents".utf8).write(to: source)
    _ = try await session.upload(source, into: remote.path, resolveConflict: { _ in .replace }) { _ in }
    let replaced = try Data(contentsOf: created)
    #expect(replaced == Data("newer contents".utf8))
    let mode = try posixMode(of: created)
    #expect(mode == 0o644)
    let names = try FileManager.default.contentsOfDirectory(atPath: remote.path)
    #expect(names == ["app.conf"])
}

@Test func sftpReplaceThatCannotKeepTheOwnerChangesNothingUntilConsent() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("source")
    try Data("new".utf8).write(to: source)
    guard let (client, log) = try await sftpHostileClient(in: scratch) else { return }
    defer { client.close() }
    let target = "/owned/app.env"
    let blocked = SFTPClient.Failure.atomicReplacementBlocked(path: target, reason: .cannotPreserveOwner(uid: 1001, gid: 1001))
    do {
        _ = try await client.upload(source, to: target)
        Issue.record("published a copy that does not have the original's owner")
    } catch let failure as SFTPClient.Failure {
        #expect(failure == blocked)
    }
    // The refused change was asked of the open copy, which then went; the original was never
    // opened, renamed onto or removed.
    let lines = sftpRequestLines(log)
    #expect(lines.count == 2)
    #expect(lines.first == "FSETSTAT owner")
    #expect(lines.last?.hasPrefix("REMOVE /owned/.termi-upload-") == true)
    #expect(blocked.errorDescription?.contains("1001") == true)

    // With consent: the file itself, which keeps its owner.
    let current = try await client.lstat(target)
    _ = try await client.upload(source, to: target, expectation: .existing(current), strategy: .inPlace)
    let after = sftpRequestLines(log)
    #expect(Array(after.suffix(2)) == ["OPEN /owned/app.env", "FSETSTAT size"])
}

@Test func sftpReplaceInAFolderThatCannotBeWrittenAsksThenOverwritesInPlace() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let fm = FileManager.default
    let local = scratch.appendingPathComponent("local", isDirectory: true)
    let locked = scratch.appendingPathComponent("locked", isDirectory: true)
    try fm.createDirectory(at: local, withIntermediateDirectories: true)
    try fm.createDirectory(at: locked, withIntermediateDirectories: true)
    let source = local.appendingPathComponent("app.conf")
    let target = locked.appendingPathComponent("app.conf")
    try Data("new contents".utf8).write(to: source)
    try Data("old".utf8).write(to: target)
    try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    // Runs before the scratch folder is removed (defers run in reverse).
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let before = try fm.attributesOfItem(atPath: target.path)
    guard let client = try await sftpLocalClient(startingIn: scratch, umask: "022") else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client)

    // Nobody to ask: the reason, and the original as it was.
    do {
        _ = try await session.upload(source, into: locked.path, resolveConflict: { _ in .replace }) { _ in }
        Issue.record("replaced a file whose folder cannot be written")
    } catch let failure as SFTPClient.Failure {
        #expect(failure == .atomicReplacementBlocked(path: target.path, reason: .cannotCreateStage))
    }
    // Asked, and declined: cancelled, still the original.
    await #expect(throws: CancellationError.self) {
        _ = try await session.upload(source, into: locked.path, resolveConflict: { _ in .replace },
                                     resolveUnsafeReplace: { _, _ in false }) { _ in }
    }
    let unchanged = try Data(contentsOf: target)
    #expect(unchanged == Data("old".utf8))

    // Agreed: written into the file itself — same inode, owner and mode.
    _ = try await session.upload(source, into: locked.path, resolveConflict: { _ in .replace },
                                 resolveUnsafeReplace: { _, reason in reason == .cannotCreateStage }) { _ in }
    let replaced = try Data(contentsOf: target)
    #expect(replaced == Data("new contents".utf8))
    let after = try fm.attributesOfItem(atPath: target.path)
    let inodeBefore = before[.systemFileNumber] as? NSNumber
    let inodeAfter = after[.systemFileNumber] as? NSNumber
    #expect(inodeBefore == inodeAfter)
    let ownerBefore = before[.ownerAccountID] as? NSNumber
    let ownerAfter = after[.ownerAccountID] as? NSNumber
    #expect(ownerBefore == ownerAfter)
    let mode = try posixMode(of: target)
    #expect(mode == 0o640)
    let names = try fm.contentsOfDirectory(atPath: locked.path)
    #expect(names == ["app.conf"])
}

@Test func sftpStagedCopySwappedForALinkChangesNothingItPointsAt() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let fm = FileManager.default
    let source = scratch.appendingPathComponent("source")
    let destination = scratch.appendingPathComponent("app.env")
    let sentinel = scratch.appendingPathComponent("sentinel")
    try Data("new".utf8).write(to: source)
    try Data("keep".utf8).write(to: destination)
    try Data("sentinel".utf8).write(to: sentinel)
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel.path)
    // umask 077: the staged copy is made 600 and must be given 644 — on its handle.
    guard let client = try await sftpLocalClient(startingIn: scratch, umask: "077") else { return }
    defer { client.close() }
    let sentinelPath = sentinel.path
    // Someone who may write the folder swaps the staged copy for a link the moment it is closed.
    client.afterStageClose = { stage in
        try? FileManager.default.moveItem(atPath: stage, toPath: stage + ".moved")
        try? FileManager.default.createSymbolicLink(atPath: stage, withDestinationPath: sentinelPath)
    }
    let before = try await client.lstat(destination.path)
    do {
        _ = try await client.upload(source, to: destination.path, expectation: .existing(before))
        Issue.record("published what took the staged copy's place")
    } catch let failure as SFTPClient.Failure {
        #expect(failure == .stagingFileReplaced(destination.path))
    }
    let sentinelMode = try posixMode(of: sentinel)
    #expect(sentinelMode == 0o600)
    let sentinelContent = try Data(contentsOf: sentinel)
    #expect(sentinelContent == Data("sentinel".utf8))
    let kept = try Data(contentsOf: destination)
    #expect(kept == Data("keep".utf8))
    // Only the link went; the copy that was moved aside got its mode through the handle.
    let names = try fm.contentsOfDirectory(atPath: scratch.path)
    let links = names.filter { $0.hasPrefix(".termi-upload-") && $0.hasSuffix(".part") }
    #expect(links.isEmpty)
    let moved = try #require(names.first { $0.hasSuffix(".part.moved") })
    let movedMode = try posixMode(of: scratch.appendingPathComponent(moved))
    #expect(movedMode == 0o644)
}

@Test func sftpFolderUploadLeavesOutARemoteLinkStandingWhereAFileGoes() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let fm = FileManager.default
    let localSite = scratch.appendingPathComponent("local/site", isDirectory: true)
    let remoteParent = scratch.appendingPathComponent("remote", isDirectory: true)
    let remoteSite = remoteParent.appendingPathComponent("site", isDirectory: true)
    try fm.createDirectory(at: localSite, withIntermediateDirectories: true)
    try fm.createDirectory(at: remoteSite, withIntermediateDirectories: true)
    for name in ["a.txt", "config.php", "b.txt"] {
        try Data(name.utf8).write(to: localSite.appendingPathComponent(name))
    }
    let shared = scratch.appendingPathComponent("shared.php")
    try Data("keep".utf8).write(to: shared)
    let remoteConfig = remoteSite.appendingPathComponent("config.php")
    try fm.createSymbolicLink(at: remoteConfig, withDestinationURL: shared)
    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    let session = sftpTestSession(on: client)

    let result = try await session.upload(localSite, into: remoteParent.path,
                                          resolveConflict: { _ in .replace }) { _ in }
    #expect(result.skipped.count == 1)
    #expect(result.skipped.examples == [remoteConfig.path])
    let a = try Data(contentsOf: remoteSite.appendingPathComponent("a.txt"))
    let b = try Data(contentsOf: remoteSite.appendingPathComponent("b.txt"))
    #expect(a == Data("a.txt".utf8))
    #expect(b == Data("b.txt".utf8))
    let sharedContent = try Data(contentsOf: shared)
    #expect(sharedContent == Data("keep".utf8))
    let link = try await client.lstat(remoteConfig.path)
    #expect(link.fileType == .symlink)
}

@Test @MainActor func sftpEditOfALinkSavesToTheFileItPointsAt() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let fm = FileManager.default
    let remote = scratch.appendingPathComponent("remote", isDirectory: true)
    try fm.createDirectory(at: remote, withIntermediateDirectories: true)
    let target = remote.appendingPathComponent("default.conf")
    let link = remote.appendingPathComponent("default")
    let dangling = remote.appendingPathComponent("gone")
    try Data("keep".utf8).write(to: target)
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: "nowhere.conf")
    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    let model = SFTPViewModel()
    model.editFolder = scratch.appendingPathComponent("edits")
    model.editorForTests = { _ in }
    model.moveToTrash = scratchTrash(scratch.appendingPathComponent("trash"))
    let session = sftpTestSession(on: client)
    model.adopt(session)
    defer { model.disconnect() }
    let rows = try await session.list(remote.path)
    let linkRow = try #require(rows.first { $0.name == "default" })
    #expect(linkRow.isSymlink)

    await model.edit(linkRow)
    let editing = try #require(model.editItems.first)
    try Data("new".utf8).write(to: editing.localURL)
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: editing.localURL.path)
    await model.uploadIfChanged(editing.id)
    let saved = try Data(contentsOf: target)
    #expect(saved == Data("new".utf8))
    #expect(model.editItems.first?.uploadFailed == false)
    let stillLink = try await client.lstat(link.path)
    #expect(stillLink.fileType == .symlink)
    let pointsTo = try fm.destinationOfSymbolicLink(atPath: link.path)
    #expect(pointsTo == target.path)

    // A link that leads nowhere is not opened.
    model.stopEditing(editing.id)
    let danglingRow = try #require(rows.first { $0.name == "gone" })
    await model.edit(danglingRow)
    #expect(model.editItems.isEmpty)
    #expect(model.remoteActionError != nil)
}

@Test @MainActor func sftpEditAsksOnceBeforeOverwritingInPlace() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let fm = FileManager.default
    let locked = scratch.appendingPathComponent("locked", isDirectory: true)
    try fm.createDirectory(at: locked, withIntermediateDirectories: true)
    let target = locked.appendingPathComponent("app.conf")
    try Data("old".utf8).write(to: target)
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    let model = SFTPViewModel()
    model.editFolder = scratch.appendingPathComponent("edits")
    model.editorForTests = { _ in }
    model.moveToTrash = scratchTrash(scratch.appendingPathComponent("trash"))
    model.adopt(sftpTestSession(on: client))
    defer { model.disconnect() }
    await model.edit(SFTPItem(entry: sftpFileEntry("app.conf"), parentPath: locked.path))
    let editing = try #require(model.editItems.first)

    try Data("first".utf8).write(to: editing.localURL)
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: editing.localURL.path)
    let firstSave = Task { @MainActor in await model.uploadIfChanged(editing.id) }
    for _ in 0..<300 where model.uploadConflict == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let question = try #require(model.uploadConflict)
    let asksAboutInPlace: Bool
    if case .unsafeReplace(.cannotCreateStage) = question.kind { asksAboutInPlace = true } else { asksAboutInPlace = false }
    #expect(asksAboutInPlace)
    #expect(question.transferID == editing.id)
    model.resolveUploadConflict(question.id, decision: .replace)
    await firstSave.value
    let first = try Data(contentsOf: target)
    #expect(first == Data("first".utf8))

    // The answer holds for this edit's next saves.
    try Data("second".utf8).write(to: editing.localURL)
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(4)], ofItemAtPath: editing.localURL.path)
    await model.uploadIfChanged(editing.id)
    #expect(model.uploadConflict == nil)
    let second = try Data(contentsOf: target)
    #expect(second == Data("second".utf8))
}

@Test @MainActor func sftpOneAnswerForEveryFileOfAnUpload() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let fm = FileManager.default
    let localSite = scratch.appendingPathComponent("local/site", isDirectory: true)
    let remote = scratch.appendingPathComponent("remote", isDirectory: true)
    let remoteSite = remote.appendingPathComponent("site", isDirectory: true)
    try fm.createDirectory(at: localSite, withIntermediateDirectories: true)
    try fm.createDirectory(at: remoteSite, withIntermediateDirectories: true)
    for name in ["a", "b", "c"] {
        try Data("new \(name)".utf8).write(to: localSite.appendingPathComponent(name))
        try Data("old \(name)".utf8).write(to: remoteSite.appendingPathComponent(name))
    }
    let extra = scratch.appendingPathComponent("local/extra")
    try Data("new extra".utf8).write(to: extra)
    try Data("old extra".utf8).write(to: remote.appendingPathComponent("extra"))
    guard let client = try await sftpLocalClient(startingIn: scratch) else { return }
    defer { client.close() }
    let model = SFTPViewModel()
    model.adopt(sftpTestSession(on: client))
    defer { model.disconnect() }

    model.upload([localSite, extra], into: remote.path)
    var asked: [UUID] = []
    for _ in 0..<600 where model.hasActiveTransfers {
        if let question = model.uploadConflict, !asked.contains(question.id) {
            asked.append(question.id)
            #expect(question.offersApplyToAll)
            // Skip, for every file of this upload.
            model.resolveUploadConflict(question.id, decision: .skip, applyToAll: true)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(asked.count == 1)
    let keptTotal = model.transfers.map(\.kept.count).reduce(0, +)
    let skippedTotal = model.transfers.map(\.skipped.count).reduce(0, +)
    #expect(keptTotal == 4)
    #expect(skippedTotal == 0)
    for name in ["a", "b", "c"] {
        let content = try Data(contentsOf: remoteSite.appendingPathComponent(name))
        #expect(content == Data("old \(name)".utf8))
    }

    // Another upload asks again; Cancel is never remembered.
    model.upload([extra], into: remote.path)
    for _ in 0..<300 where model.uploadConflict == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let again = try #require(model.uploadConflict)
    #expect(!again.offersApplyToAll)
    model.resolveUploadConflict(again.id, decision: .cancel, applyToAll: true)
    for _ in 0..<300 where model.hasActiveTransfers {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    model.upload([extra], into: remote.path)
    for _ in 0..<300 where model.uploadConflict == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let third = try #require(model.uploadConflict)
    model.resolveUploadConflict(third.id, decision: .cancel)
}

@MainActor private final class SFTPSessionCounter {
    var opened = 0
}

@Test @MainActor func sftpReopeningTheSameHostKeepsTheSessionAndFolder() async throws {
    let scratch = try sftpScratchFolder()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let sub = scratch.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    guard FileManager.default.isExecutableFile(atPath: "/usr/libexec/sftp-server") else { return }
    let counter = SFTPSessionCounter()
    let sessions = SFTPSessionBox()
    let root = scratch.path
    let model = SFTPViewModel(openSession: { host in
        counter.opened += 1
        guard let client = try await sftpLocalClient(startingIn: URL(fileURLWithPath: root)) else {
            throw CancellationError()
        }
        let session = SFTPSession(host: host, client: client, homeDirectory: root)
        sessions.keep(session)
        return session
    })
    defer { model.disconnect() }
    var host = Termi.Host.defaultValue()
    host.id = 41
    host.hostname = "a.example"
    await model.connect(to: host)
    #expect(counter.opened == 1)
    // The current folder is what the server resolved, not the text that was typed: here the
    // /var → /private/var mapping of the temporary directory.
    let opened = try #require(sessions.first)
    let expected = try await opened.resolve(sub.path)
    await model.navigateRemote(to: sub.path)
    #expect(model.remotePath == expected)

    // The same host read again: connected since, its system detected.
    var newer = host
    newer.lastConnectedAt = TimestampFormatter.now()
    newer.osId = "debian"
    newer.osDetectedAt = TimestampFormatter.now()
    await model.connect(to: newer)
    #expect(counter.opened == 1)
    #expect(model.remotePath == expected)
    #expect(model.notice == nil)
    #expect(model.selectedHost?.osId == "debian")

    // Another address is another connection.
    var moved = newer
    moved.hostname = "b.example"
    await model.connect(to: moved)
    #expect(counter.opened == 2)
}

@MainActor private final class SFTPSessionBox {
    private(set) var kept: [SFTPSession] = []
    func keep(_ session: SFTPSession) { kept.append(session) }
    var first: SFTPSession? { kept.first }
}
