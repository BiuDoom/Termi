import Testing
import Foundation
@testable import Termi

// The logic behind the Port Forwards, Snippets and Batch Command pages: the hops of a rule's
// route, the ssh command line of a rule, snippet sections, host
// sections, results grouped by what they said.

private func makeHost(_ id: Int64, _ label: String, group: Int64? = nil, port: Int = 22,
                      username: String = "deploy") -> Termi.Host {
    var host = Termi.Host.defaultValue()
    host.id = id
    host.label = label
    host.hostname = "10.0.0.\(id)"
    host.port = port
    host.username = username
    host.groupId = group
    return host
}

private func makeRule(_ id: Int64, type: String, local: Int, remoteHost: String = "127.0.0.1", remote: Int = 0,
                      enabled: Bool = false) -> PortForward {
    PortForward(id: id, hostId: 1, type: type, localPort: local, remoteHost: remoteHost, remotePort: remote,
                enabled: enabled, createdAt: "")
}

private func makeSnippet(_ id: Int64, _ name: String, category: String? = nil, command: String = "true") -> Snippet {
    Snippet(id: id, name: name, command: command, description: nil, category: category, sortOrder: 0, createdAt: "")
}

private func makeResult(_ host: Termi.Host, output: String = "", error: String? = nil,
                        ms: Int = 100) -> BatchCommandService.HostResult {
    BatchCommandService.HostResult(host: host, output: output, error: error, exitCode: error == nil ? 0 : -1,
                                   durationMs: ms)
}

// MARK: - Port forwards

@Test func sshCommandOfARuleNamesTheForwardTheHostAndItsPort() {
    let host = makeHost(1, "web", port: 2222, username: "tester")
    #expect(PortForwardViewModel.sshCommand(for: makeRule(1, type: "local", local: 18080, remote: 8080), host: host)
            == "ssh -L 18080:127.0.0.1:8080 tester@10.0.0.1 -p 2222")
    #expect(PortForwardViewModel.sshCommand(for: makeRule(2, type: "dynamic", local: 1080), host: host)
            == "ssh -D 1080 tester@10.0.0.1 -p 2222")
    // Port 22 and an inherited (empty) user name are left out.
    let plain = makeHost(2, "db", username: "")
    #expect(PortForwardViewModel.sshCommand(for: makeRule(3, type: "remote", local: 9000, remoteHost: "::1", remote: 3000),
                                            host: plain)
            == "ssh -R 9000:[::1]:3000 10.0.0.2")
}

@Test func onlyTunnelsThatListenOnThisMacHaveALocalAddress() {
    #expect(PortForwardViewModel.localAddress(of: makeRule(1, type: "local", local: 18080, remote: 8080)) == "localhost:18080")
    #expect(PortForwardViewModel.localAddress(of: makeRule(2, type: "dynamic", local: 1080)) == "localhost:1080")
    #expect(PortForwardViewModel.localAddress(of: makeRule(3, type: "remote", local: 9000, remote: 3000)) == nil)
}

@Test @MainActor func routeOfARuleRunsFromTheListenerThroughTheHostToTheTarget() {
    let host = makeHost(1, "web")
    let local = PortForwardRowView.hops(for: makeRule(1, type: "local", local: 18080, remote: 8080), host: host,
                                        hostLabel: "web")
    #expect(local.map(\.title) == ["localhost:18080", "web", "127.0.0.1:8080"])
    #expect(local[1].hostId == 1)

    let remote = PortForwardRowView.hops(for: makeRule(2, type: "remote", local: 9000, remoteHost: "localhost", remote: 3000),
                                         host: host, hostLabel: "web")
    #expect(remote.map(\.title) == ["web:9000", "web", "localhost:3000"])

    // A rule whose host is gone still draws: the label stands in for the host.
    let dynamic = PortForwardRowView.hops(for: makeRule(3, type: "dynamic", local: 1080), host: nil, hostLabel: "Host #9")
    #expect(dynamic.count == 3)
    // That it is a SOCKS proxy is said by the rule's "Dynamic" chip, not in the listening end.
    #expect(dynamic[0].title == "localhost:1080")
    #expect(dynamic[1].title == "Host #9")
    #expect(dynamic[1].hostId == nil)
    // The three hops of a rule never share an id (they are the ids of a ForEach).
    #expect(Set(local.map(\.id)).count == 3)
    #expect(Set(remote.map(\.id)).count == 3)
}

// MARK: - Snippets

@Test func snippetSectionsAreCategoriesInOrderThenTheRest() {
    let snippets = [
        makeSnippet(1, "plain"),
        makeSnippet(2, "tail", category: "logs"),
        makeSnippet(3, "df", category: "System"),
        makeSnippet(4, "journal", category: "logs"),
        makeSnippet(5, "blank", category: "")
    ]
    let sections = SnippetsViewModel.sections(of: snippets)
    #expect(sections.map(\.title) == ["logs", "System", nil])
    #expect(sections[0].snippets.compactMap(\.id) == [2, 4])
    #expect(sections[2].snippets.compactMap(\.id) == [1, 5])
    #expect(SnippetsViewModel.sections(of: []).isEmpty)
}

@Test func firstLineOfACommandSkipsBlankLines() {
    #expect(SnippetsViewModel.firstLine(of: "\n  cd /srv  \nmake deploy") == "cd /srv")
    #expect(SnippetsViewModel.firstLine(of: "") == "")
}

// MARK: - Batch command

@Test func batchHostSectionsFollowTheGroupsThenTheUngrouped() {
    let hosts = [makeHost(1, "a"), makeHost(2, "b", group: 7), makeHost(3, "c", group: 8), makeHost(4, "d", group: 99)]
    let now = TimestampFormatter.now()
    let groups = [HostGroup(id: 8, name: "staging", sortOrder: 1, createdAt: now),
                  HostGroup(id: 7, name: "prod", sortOrder: 0, createdAt: now),
                  HostGroup(id: 9, name: "empty", sortOrder: 2, createdAt: now)]
    let sections = BatchCommandViewModel.hostSections(hosts: hosts, groups: groups)
    // Empty groups are left out; a host of a group that no longer exists is ungrouped.
    #expect(sections.map(\.title) == ["prod", "staging", nil])
    #expect(sections[2].hosts.compactMap(\.id) == [1, 4])

    let flat = BatchCommandViewModel.hostSections(hosts: [makeHost(1, "a"), makeHost(2, "b")], groups: [])
    #expect(flat.count == 1)
    #expect(flat[0].title == nil)
    #expect(BatchCommandViewModel.hostSections(hosts: [], groups: groups).isEmpty)
}

@Test func batchOutputGroupsPutTheLargestFirstAndKeepErrorsApart() {
    let a = makeHost(1, "a"), b = makeHost(2, "b"), c = makeHost(3, "c"), d = makeHost(4, "d")
    let results = [
        makeResult(a, output: "Linux 5.15\n"),
        makeResult(b, output: "Linux 6.8\n"),
        makeResult(c, output: "\nLinux 6.8"),
        // An error with the text of an output is still an error.
        makeResult(d, error: "Linux 6.8")
    ]
    let groups = BatchCommandViewModel.outputGroups(of: results)
    #expect(groups.count == 3)
    #expect(groups[0].text == "Linux 6.8")
    #expect(groups[0].hosts.compactMap(\.id) == [2, 3])
    #expect(!groups[0].isFailure)
    // Same size: in the order they first appeared.
    #expect(groups[1].hosts.compactMap(\.id) == [1])
    #expect(groups[2].isFailure)
    #expect(Set(groups.map(\.id)).count == 3)
}

@Test func batchResultsListFailuresFirst() {
    let a = makeHost(1, "a"), b = makeHost(2, "b"), c = makeHost(3, "c")
    let ordered = BatchCommandViewModel.ordered([makeResult(a, output: "ok"), makeResult(b, error: "denied"),
                                                 makeResult(c, output: "ok")])
    #expect(ordered.compactMap(\.host.id) == [2, 1, 3])
}

@Test func batchSummaryCountsWhatAnsweredAndWhatIsStillOut() {
    let a = makeHost(1, "a"), b = makeHost(2, "b")
    let running = BatchCommandViewModel.Summary(results: [makeResult(a, output: "ok", ms: 212), makeResult(b, error: "x", ms: 812)],
                                                expected: 4)
    #expect(running.total == 4)
    #expect(running.succeeded == 1)
    #expect(running.failed == 1)
    #expect(running.pending == 2)
    #expect(running.slowestMs == 812)

    // Nothing has answered yet: no "slowest", not 0.
    let started = BatchCommandViewModel.Summary(results: [], expected: 3)
    #expect(started.pending == 3)
    #expect(started.slowestMs == nil)
}

@Test func aSnippetGoesIntoAnEmptyEditorOrOnANewLine() {
    #expect(BatchCommandViewModel.inserting("uptime", into: "  \n") == "uptime")
    #expect(BatchCommandViewModel.inserting("uptime", into: "cd /srv\n") == "cd /srv\nuptime")
}

@Test func aFailureOrASingleAnswerOpensByItself() {
    #expect(BatchResultRow.opensByDefault(failed: true, resultCount: 5))
    #expect(BatchResultRow.opensByDefault(failed: false, resultCount: 1))
    #expect(!BatchResultRow.opensByDefault(failed: false, resultCount: 5))
}

@Test func batchFirstLineAndTrimDropTheBlankLinesAroundAnOutput() {
    #expect(BatchCommandViewModel.trimmed("\n  up 3 days \n\n") == "up 3 days")
    #expect(BatchCommandViewModel.firstLine(of: "\n\nup 3 days\nload 0.1\n") == "up 3 days")
    #expect(BatchCommandViewModel.firstLine(of: " \n") == "")
}

@Test func batchOutputGroupsTreatOutputsThatDifferOnlyInSurroundingBlankLinesAsTheSame() {
    let a = makeHost(1, "a"), b = makeHost(2, "b")
    let groups = BatchCommandViewModel.outputGroups(of: [makeResult(a, output: "ok\n"), makeResult(b, output: "ok")])
    #expect(groups.count == 1)
    #expect(groups[0].hosts.compactMap(\.id) == [1, 2])
    #expect(BatchCommandViewModel.outputGroups(of: []).isEmpty)
}

@Test func batchSummaryNeverCountsLessThanWhatAnswered() {
    let a = makeHost(1, "a"), b = makeHost(2, "b")
    // More answers than expected hosts (the ticks changed): the total follows the answers.
    let summary = BatchCommandViewModel.Summary(results: [makeResult(a, output: "ok"), makeResult(b, output: "ok")],
                                                expected: 1)
    #expect(summary.total == 2)
    #expect(summary.pending == 0)
    #expect(summary.succeeded == 2)
    #expect(summary.failed == 0)
}

@Test @MainActor func clearingBatchResultsForgetsTheRun() {
    let viewModel = BatchCommandViewModel()
    viewModel.results = [makeResult(makeHost(1, "a"), output: "ok")]
    #expect(viewModel.summary.total == 1)
    // Nothing is running: no host is waited for.
    #expect(viewModel.pendingHosts.isEmpty)
    viewModel.clearResults()
    #expect(viewModel.results.isEmpty)
    #expect(viewModel.summary.total == 0)
    #expect(viewModel.lastRunAt == nil)
}

@Test @MainActor func routeOfARuleBracketsAnIPv6Target() {
    let hops = PortForwardRowView.hops(for: makeRule(1, type: "local", local: 8080, remoteHost: "::1", remote: 80),
                                       host: nil, hostLabel: "db")
    #expect(hops.map(\.title) == ["localhost:8080", "db", "[::1]:80"])
}

@Test @MainActor func snippetFiltersCountAndSectionWhatIsShown() {
    let viewModel = SnippetsViewModel()
    viewModel.snippets = [makeSnippet(1, "tail", category: "logs", command: "tail -f {{file}}"),
                          makeSnippet(2, "df", category: "system", command: "df -h"),
                          makeSnippet(3, "journal", category: "logs", command: "journalctl -f")]
    #expect(viewModel.count(inCategory: "logs") == 2)
    #expect(viewModel.count(inCategory: "none") == 0)
    viewModel.selectedCategory = "logs"
    #expect(viewModel.sections.map(\.title) == ["logs"])
    // The search narrows within the category; a category's count does not follow the search.
    viewModel.searchText = "JOURNAL"
    #expect(viewModel.sections.flatMap(\.snippets).compactMap(\.id) == [3])
    #expect(viewModel.count(inCategory: "logs") == 2)
}
