#if DEBUG
import Foundation
import Testing
@testable import Termi

// -debugSeedHosts: the hosts of a test profile come from a file. What is tested here is what
// decides before anything is written — in which kind of profile the seed may run at all, and
// what a hosts description says. (The writing itself goes through the repositories and the
// vault, which have their own tests.)

private let seedBase = URL(fileURLWithPath: "/opt/qa/.test-env", isDirectory: true)

private func seedPlan(_ json: String) -> DebugSeed.Plan? {
    try? DebugSeed.parse(Data(json.utf8), relativeTo: seedBase)
}

/// The error a description is refused with. Matched here, not inside `#expect` (Swift 6.0).
private func seedRefusal(_ json: String) -> DebugSeed.SeedError? {
    do {
        _ = try DebugSeed.parse(Data(json.utf8), relativeTo: seedBase)
        return nil
    } catch let error as DebugSeed.SeedError {
        return error
    } catch {
        return .malformed("unexpected: \(error)")
    }
}

private func seedIsMalformed(_ json: String) -> Bool {
    guard let refusal = seedRefusal(json) else { return false }
    if case .malformed = refusal { return true }
    return false
}

private func seedHost(_ label: String, auth: String = #"{ "type": "agent" }"#, extra: String = "") -> String {
    #"{ "label": "\#(label)", "address": "127.0.0.1", "port": 2222, "user": "tester", "auth": \#(auth)\#(extra) }"#
}

private func seedFile(_ hosts: String...) -> String {
    #"{ "hosts": [\#(hosts.joined(separator: ","))] }"#
}

// MARK: - Where the seed may run

@Test func debugSeedIsRefusedInTheStandardProfile() {
    let decision = DebugSeed.decision(kind: .standard, argument: "/opt/qa/.test-env/seed-hosts.json")
    let expected = DebugSeed.Decision.refused(
        "-debugSeedHosts is refused in the standard profile: test hosts never go into real data. "
            + "Start the app with TERMI_PROFILE_DIR=<absolute folder>."
    )
    #expect(decision == expected)
}

@Test func debugSeedRunsInAnIsolatedProfileAndInATestRun() {
    let path = "/opt/qa/.test-env/seed-hosts.json"
    #expect(DebugSeed.decision(kind: .isolated, argument: path) == .seed(path: path))
    #expect(DebugSeed.decision(kind: .tests, argument: path) == .seed(path: path))
}

@Test func debugSeedDoesNothingWithoutTheArgumentInEveryKindOfProfile() {
    for kind in [AppProfile.Kind.standard, .isolated, .tests] {
        #expect(DebugSeed.decision(kind: kind, argument: nil) == .notRequested)
        #expect(DebugSeed.decision(kind: kind, argument: "") == .notRequested)
    }
}

// MARK: - The hosts description

@Test func debugSeedReadsEveryKindOfHost() {
    let plan = seedPlan(seedFile(
        seedHost("agent"),
        seedHost("password", auth: #"{ "type": "password", "passwordFile": "/opt/qa/.test-env/tester_password" }"#),
        seedHost("asks", auth: #"{ "type": "password" }"#),
        seedHost("key", auth: #"{ "type": "key", "keyName": "plain", "keyFile": "/opt/qa/.test-env/id_plain" }"#),
        seedHost("locked-key", auth: #"{ "type": "key", "keyFile": "/k/id", "passphraseFile": "/k/passphrase" }"#),
        seedHost("inner", extra: #", "jump": "agent", "startupSnippet": { "name": "where", "command": "hostname" }, "hostKeyFile": "hostkeys/inner.pub""#)
    ))
    let auths = plan?.hosts.map(\.auth)
    let expected: [DebugSeed.Auth] = [
        .agent,
        .password(file: "/opt/qa/.test-env/tester_password"),
        .password(file: nil),
        .key(name: "plain", file: "/opt/qa/.test-env/id_plain", passphraseFile: nil),
        // A key without a name of its own is named after its host.
        .key(name: "locked-key", file: "/k/id", passphraseFile: "/k/passphrase"),
        .agent
    ]
    #expect(auths == expected)
    let first = plan?.hosts.first
    #expect(first?.label == "agent")
    #expect(first?.address == "127.0.0.1")
    #expect(first?.port == 2222)
    #expect(first?.user == "tester")
    #expect(first?.jump == nil)
    #expect(first?.startupSnippet == nil)
    #expect(first?.hostKeyFile == nil)
    let last = plan?.hosts.last
    #expect(last?.jump == "agent")
    #expect(last?.startupSnippet == DebugSeed.SnippetEntry(name: "where", command: "hostname"))
    #expect(last?.hostKeyFile == "/opt/qa/.test-env/hostkeys/inner.pub")
}

@Test func debugSeedPortAndUserHaveTheFormsDefaults() {
    let plan = seedPlan(#"{ "hosts": [ { "label": "bare", "address": "example.test", "auth": { "type": "agent" } } ] }"#)
    #expect(plan?.hosts.first?.port == 22)
    // Empty = inherited from the group or the identity, as in the host form.
    #expect(plan?.hosts.first?.user == "")
}

@Test func debugSeedRelativePathsAreNextToTheFile() {
    let plan = seedPlan(seedFile(
        seedHost("a", auth: #"{ "type": "password", "passwordFile": "tester_password" }"#),
        seedHost("b", auth: #"{ "type": "key", "keyFile": "keys/../id_plain", "passphraseFile": "key_passphrase" }"#)
    ))
    let auths = plan?.hosts.map(\.auth)
    let expected: [DebugSeed.Auth] = [
        .password(file: "/opt/qa/.test-env/tester_password"),
        .key(name: "b", file: "/opt/qa/.test-env/id_plain", passphraseFile: "/opt/qa/.test-env/key_passphrase")
    ]
    #expect(auths == expected)
}

@Test func debugSeedAJumpHostMayBeListedAfterTheHostThatUsesIt() {
    let plan = seedPlan(seedFile(seedHost("inner", extra: #", "jump": "jump""#), seedHost("jump")))
    let jumps: [String?]? = plan?.hosts.map(\.jump)
    let expected: [String?] = ["jump", nil]
    #expect(jumps == expected)
}

@Test func debugSeedRefusesWhatWouldStopItHalfWay() {
    #expect(seedRefusal(seedFile(seedHost("a"), seedHost("a"))) == .duplicateLabel("a"))
    #expect(seedRefusal(seedFile(seedHost("  "))) == .emptyField(host: "127.0.0.1", field: "label"))
    #expect(seedRefusal(#"{ "hosts": [ { "label": "a", "address": " ", "auth": { "type": "agent" } } ] }"#)
        == .emptyField(host: "a", field: "address"))
    #expect(seedRefusal(#"{ "hosts": [ { "label": "a", "address": "h", "port": 70000, "auth": { "type": "agent" } } ] }"#)
        == .invalidPort(host: "a", port: 70000))
    #expect(seedRefusal(#"{ "hosts": [ { "label": "a", "address": "h", "port": 0, "auth": { "type": "agent" } } ] }"#)
        == .invalidPort(host: "a", port: 0))
    #expect(seedRefusal(seedFile(seedHost("a", auth: #"{ "type": "keychain" }"#))) == .unknownAuth(host: "a", type: "keychain"))
    #expect(seedRefusal(seedFile(seedHost("a", auth: #"{ "type": "key" }"#))) == .emptyField(host: "a", field: "auth.keyFile"))
    #expect(seedRefusal(seedFile(seedHost("a", extra: #", "startupSnippet": { "name": "n", "command": "" }"#)))
        == .emptyField(host: "a", field: "startupSnippet.command"))
}

@Test func debugSeedRefusesAJumpHostThatIsMissingOrLeadsBack() {
    #expect(seedRefusal(seedFile(seedHost("a", extra: #", "jump": "nobody""#))) == .unknownJump(host: "a", jump: "nobody"))
    #expect(seedRefusal(seedFile(seedHost("a", extra: #", "jump": "a""#))) == .jumpLoop(host: "a"))
    let loop = seedFile(seedHost("a", extra: #", "jump": "b""#), seedHost("b", extra: #", "jump": "c""#),
                        seedHost("c", extra: #", "jump": "a""#))
    #expect(seedRefusal(loop) == .jumpLoop(host: "a"))
    // A chain that ends is not a loop.
    let chain = seedFile(seedHost("a", extra: #", "jump": "b""#), seedHost("b", extra: #", "jump": "c""#), seedHost("c"))
    #expect(seedRefusal(chain) == nil)
}

@Test func debugSeedSaysWhatIsWrongWithAFileThatIsNotADescription() {
    #expect(seedIsMalformed("not json"))
    #expect(seedIsMalformed("{}"))
    #expect(seedIsMalformed(#"{ "hosts": [ { "label": "a", "address": "h" } ] }"#))
    #expect(seedRefusal("{}") == .malformed("\"hosts\" is missing at the top level"))
    #expect(seedRefusal(#"{ "hosts": [ { "label": "a", "address": "h", "port": "22", "auth": { "type": "agent" } } ] }"#)
        == .malformed("wrong kind of value at hosts.[0].port"))
    #expect(seedRefusal(seedFile()) == nil)
}

@Test func debugSeedASecretFileLosesOnlyItsFinalLineBreak() {
    #expect(DebugSeed.secret(fromFileContents: "s3cret") == "s3cret")
    #expect(DebugSeed.secret(fromFileContents: "s3cret\n") == "s3cret")
    #expect(DebugSeed.secret(fromFileContents: "s3cret\r\n") == "s3cret")
    #expect(DebugSeed.secret(fromFileContents: " two words \n\n") == " two words \n")
    #expect(DebugSeed.secret(fromFileContents: "") == "")
}

@Test func debugSeedTheRepositoryTemplateIsAValidDescription() throws {
    // TestEnvironment/seed-hosts.template.json, with the placeholder test-env.sh replaces.
    let template = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestEnvironment/seed-hosts.template.json")
    // Where the test bundle runs without the sources next to it there is nothing to check.
    guard let text = try? String(contentsOf: template, encoding: .utf8) else { return }
    let plan = seedPlan(text.replacingOccurrences(of: "@TEST_ENV@", with: "/opt/qa/.test-env"))
    let labels = plan?.hosts.map(\.label)
    #expect(labels == ["test-a", "test-pass", "test-pw", "test-agent", "test-kbd", "jump", "inner"])
    #expect(plan?.hosts.last?.jump == "jump")
}
#endif
