import Testing
import Foundation
@testable import Termi

// Search-to-connect on the Hosts page: what typing "user@host[:port]" finds and connects to.
// These only set the view model's in-memory state; nothing is loaded from the database.

private func savedHost(id: Int64, label: String, hostname: String, username: String = "root",
                       port: Int = 22) -> Termi.Host {
    var host = Host.defaultValue()
    host.id = id
    host.label = label
    host.hostname = hostname
    host.username = username
    host.port = port
    return host
}

/// A hosts page with two saved hosts (root@10.0.0.5 and admin@gw.example.com:2222) and `search` typed.
@MainActor
private func hostsViewModel(search: String) -> HostsViewModel {
    let viewModel = HostsViewModel()
    viewModel.hosts = [
        savedHost(id: 1, label: "Builder", hostname: "10.0.0.5"),
        savedHost(id: 2, label: "Gateway", hostname: "gw.example.com", username: "admin", port: 2222),
    ]
    viewModel.searchText = search
    return viewModel
}

// MARK: - Unsaved hosts

@Test func quickConnectHostTriesKeysBeforeThePassword() {
    // Like plain ssh: agent + default keys, not password-only (which fails on key-only servers).
    let withUser = QuickConnectParser.parse("root@10.0.0.9")
    let withPort = QuickConnectParser.parse("10.0.0.9:2222")
    #expect(withUser?.authType == "agent")
    #expect(withPort?.authType == "agent")
}

@Test @MainActor func quickConnectCandidateForAnUnsavedAddress() {
    let candidate = hostsViewModel(search: "deploy@10.0.0.9:2222").quickConnectCandidate
    #expect(candidate != nil)
    #expect(candidate?.id == nil)
    #expect(candidate?.username == "deploy")
    #expect(candidate?.hostname == "10.0.0.9")
    #expect(candidate?.port == 2222)
}

@Test @MainActor func quickConnectCandidateIgnoresPlainSearchText() {
    let candidate = hostsViewModel(search: "builder").quickConnectCandidate
    #expect(candidate == nil)
}

// MARK: - Saved hosts

@Test @MainActor func quickConnectCandidateIsTheSavedHost() {
    // user@host of a saved host used to be a dead end: no card and no quick connect.
    let byUserAtHost = hostsViewModel(search: "root@10.0.0.5").quickConnectCandidate
    #expect(byUserAtHost?.id == 1)

    let byUserAtHostAndPort = hostsViewModel(search: "admin@GW.example.com:2222").quickConnectCandidate
    #expect(byUserAtHostAndPort?.id == 2)

    // Without a user, the address alone identifies the saved host.
    let byAddress = hostsViewModel(search: "gw.example.com:2222").quickConnectCandidate
    #expect(byAddress?.id == 2)
}

@Test @MainActor func quickConnectCandidateWithAnotherUserOrPortIsUnsaved() {
    let otherUser = hostsViewModel(search: "deploy@10.0.0.5").quickConnectCandidate
    #expect(otherUser != nil)
    #expect(otherUser?.id == nil)
    #expect(otherUser?.username == "deploy")

    let otherPort = hostsViewModel(search: "root@10.0.0.5:2222").quickConnectCandidate
    #expect(otherPort != nil)
    #expect(otherPort?.id == nil)
    #expect(otherPort?.port == 2222)
}

@Test @MainActor func hostSearchMatchesUserAtHostAndHostWithPort() {
    let byUserAtHost = hostsViewModel(search: "root@10.0.0.5").filteredGroupedHosts.flatMap(\.hosts)
    #expect(byUserAtHost.map(\.label) == ["Builder"])

    let byHostAndPort = hostsViewModel(search: "gw.example.com:2222").filteredGroupedHosts.flatMap(\.hosts)
    #expect(byHostAndPort.map(\.label) == ["Gateway"])

    let otherUser = hostsViewModel(search: "deploy@10.0.0.5").filteredGroupedHosts.flatMap(\.hosts)
    #expect(otherUser.isEmpty)
}
