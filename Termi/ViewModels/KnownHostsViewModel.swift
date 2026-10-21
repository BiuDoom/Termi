import SwiftUI
import os.log

/// The addresses that presented one host key: the same machine reached under several names.
struct KnownHostGroup: Identifiable, Equatable {
    let fingerprint: String
    /// Oldest first.
    let entries: [KnownHost]

    var id: String { fingerprint }

    static func == (lhs: KnownHostGroup, rhs: KnownHostGroup) -> Bool {
        lhs.fingerprint == rhs.fingerprint && lhs.entries.map(\.id) == rhs.entries.map(\.id)
    }
}

/// ViewModel for Known Hosts management
@Observable
@MainActor
final class KnownHostsViewModel {
    private let dataGeneration: UUID

    init(dataGeneration: UUID = DataSnapshot.current) {
        self.dataGeneration = dataGeneration
    }

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "KnownHostsVM")
    private let repo = KnownHostRepository.shared

    var hosts: [KnownHost] = []
    var isLoading = false
    /// The first read has finished: until then the page shows nothing rather than "no known hosts".
    private(set) var hasLoaded = false
    var error: String?
    var searchText = ""

    // Delete confirmation
    var showingDeleteConfirm = false
    var hostToDelete: KnownHost?
    var showingDeleteAllConfirm = false
    /// The entries the "remove entries without a saved host" confirmation listed: exactly
    /// these are removed, whatever changed in between.
    var orphansToDelete: [KnownHost] = []
    var showingDeleteOrphansConfirm = false

    var filteredHosts: [KnownHost] {
        if searchText.isEmpty { return hosts }
        let query = searchText.lowercased()
        return hosts.filter {
            // "host:port" is how an entry is shown and told from its neighbours, so it is searchable too.
            "\($0.hostname):\($0.port)".lowercased().contains(query) ||
            $0.fingerprint.lowercased().contains(query) ||
            $0.keyType.lowercased().contains(query)
        }
    }

    /// The filtered entries, one group per host key.
    var groups: [KnownHostGroup] {
        Self.groups(of: filteredHosts)
    }

    // MARK: - Pure helpers

    /// A group is headed (image, key type, "3 addresses") only when it has several addresses:
    /// over a single row the header would repeat the row.
    nonisolated static func showsGroupHeader(for group: KnownHostGroup) -> Bool {
        group.entries.count > 1
    }

    /// When the key of `entry` was first trusted, if that was under another address at
    /// another time; nil when the entry's own date already says it.
    nonisolated static func earlierFirstTrust(of entry: KnownHost, in group: KnownHostGroup) -> String? {
        guard let first = group.entries.first, first.id != entry.id, first.addedAt != entry.addedAt else { return nil }
        return first.addedAt
    }

    /// One group per fingerprint; groups by their first trust, entries oldest first (the id
    /// breaks ties, so the order is stable).
    nonisolated static func groups(of hosts: [KnownHost]) -> [KnownHostGroup] {
        func isOlder(_ lhs: KnownHost, _ rhs: KnownHost) -> Bool {
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
            return (lhs.id ?? .max) < (rhs.id ?? .max)
        }
        return Dictionary(grouping: hosts, by: \.fingerprint)
            .map { KnownHostGroup(fingerprint: $0.key, entries: $0.value.sorted(by: isOlder)) }
            .sorted { lhs, rhs in
                guard let left = lhs.entries.first, let right = rhs.entries.first else { return false }
                return isOlder(left, right)
            }
    }

    /// The saved hosts this entry was trusted for: same address and port (several hosts can
    /// share one address with different users).
    nonisolated static func savedHosts(for entry: KnownHost, in hosts: [Host]) -> [Host] {
        hosts.filter { $0.hostname.caseInsensitiveCompare(entry.hostname) == .orderedSame && $0.port == entry.port }
    }

    /// Entries no saved host points at any more.
    nonisolated static func orphans(_ entries: [KnownHost], hosts: [Host]) -> [KnownHost] {
        entries.filter { savedHosts(for: $0, in: hosts).isEmpty }
    }

    /// "ssh-ed25519" → "ED25519", "ecdsa-sha2-nistp256" → "ECDSA".
    nonisolated static func shortKeyType(_ keyType: String) -> String {
        let lower = keyType.lowercased()
        if lower.hasPrefix("ecdsa") { return "ECDSA" }
        return lower.replacingOccurrences(of: "ssh-", with: "").uppercased()
    }

    /// The first characters of a fingerprint, without its "SHA256:" — enough to tell groups apart.
    nonisolated static func shortFingerprint(_ fingerprint: String, length: Int = 12) -> String {
        let body = fingerprint.range(of: ":").map { fingerprint[$0.upperBound...] } ?? fingerprint[...]
        return body.count > length ? String(body.prefix(length)) + "…" : String(body)
    }

    // MARK: - Load / delete

    func loadHosts() async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            hosts = try await repo.fetchAll()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Reads the entries again because something changed elsewhere (a host key trusted on a
    /// first connection). A message that is showing stays: `loadHosts` would clear it, and the
    /// change notification of a removal that failed half-way would erase its own error.
    func refresh() async {
        guard hasLoaded, let fetched = try? await repo.fetchAll() else { return }
        hosts = fetched
    }

    /// Opens the confirmation for the entries no saved host points at. The saved hosts are
    /// read now, from the database: a host added in another window since this window listed
    /// its hosts must not make its address look abandoned.
    func askToDeleteOrphans() async {
        do {
            let saved = try await HostRepository.shared.fetchAll()
            let listed = Self.orphans(hosts, hosts: saved)
            guard !listed.isEmpty else { return }
            orphansToDelete = listed
            showingDeleteOrphansConfirm = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteHost(_ host: KnownHost) async {
        await DataSnapshot.$expected.withValue(dataGeneration) { await deleteCurrentHost(host) }
    }

    private func deleteCurrentHost(_ host: KnownHost) async {
        guard let id = host.id else { return }
        do {
            try DataSnapshot.check(dataGeneration)
            try await repo.delete(id: id)
            await loadHosts()
            notifyDataChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Removes exactly the listed entries, one by one by id; stops at the first failure.
    func deleteHosts(_ entries: [KnownHost]) async {
        await DataSnapshot.$expected.withValue(dataGeneration) { await deleteCurrentHosts(entries) }
    }

    private func deleteCurrentHosts(_ entries: [KnownHost]) async {
        do {
            try DataSnapshot.check(dataGeneration)
            for id in entries.compactMap(\.id) {
                try await repo.delete(id: id)
            }
            await loadHosts()
            logger.info("Removed \(entries.count) known hosts without a saved host")
        } catch {
            await loadHosts()
            self.error = error.localizedDescription
        }
        notifyDataChanged()
    }

    func deleteAllHosts() async {
        await DataSnapshot.$expected.withValue(dataGeneration) { await deleteAllCurrentHosts() }
    }

    private func deleteAllCurrentHosts() async {
        do {
            try DataSnapshot.check(dataGeneration)
            try await repo.deleteAll()
            await loadHosts()
            notifyDataChanged()
            logger.info("All known hosts deleted")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The sidebar counts follow.
    private func notifyDataChanged() {
        NotificationCenter.default.post(name: .dsDataChanged, object: nil)
    }
}
