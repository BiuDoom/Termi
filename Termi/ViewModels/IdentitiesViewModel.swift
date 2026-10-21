import SwiftUI
import os.log

/// ViewModel for identity profile management
@Observable
@MainActor
final class IdentitiesViewModel {
    private let dataGeneration: UUID

    init(dataGeneration: UUID = DataSnapshot.current) {
        self.dataGeneration = dataGeneration
    }

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "IdentitiesVM")
    private let identityRepo = IdentityRepository.shared
    private let keyRepo = SSHKeyRepository.shared

    // Data
    var identities: [Identity] = []
    var availableKeys: [SSHKey] = []
    var isLoading = false
    /// The first read is done: until then the page draws neither rows nor an empty state.
    private(set) var hasLoaded = false

    // UI State
    var showingForm = false
    var editingIdentity: Identity?
    /// The identity that was just added or edited: the page selects it.
    var savedIdentityId: Int64?
    var showingDeleteConfirm = false
    var identityToDelete: Identity?
    var searchText = ""
    var error: String?

    var filteredIdentities: [Identity] {
        guard !searchText.isEmpty else { return identities }
        let query = searchText.lowercased()
        return identities.filter {
            $0.name.lowercased().contains(query) ||
            $0.username.lowercased().contains(query) ||
            $0.authType.lowercased().contains(query)
        }
    }

    // MARK: - Load

    func loadIdentities() async {
        isLoading = true
        error = nil
        defer { isLoading = false; hasLoaded = true }

        #if DEBUG
        if Self.isDebugSample {
            availableKeys = (try? await keyRepo.fetchAll()) ?? []
            identities = Self.debugSampleIdentities(keys: availableKeys)
            return
        }
        #endif

        do {
            identities = try await identityRepo.fetchAll()
            availableKeys = try await keyRepo.fetchAll()
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to load identities: \(error)")
        }
    }

    // MARK: - Actions

    func addNew() {
        editingIdentity = nil
        showingForm = true
    }

    func edit(_ identity: Identity) {
        editingIdentity = identity
        showingForm = true
    }

    /// False when the identity could not be saved (`error` says why).
    @discardableResult
    func save(_ identity: Identity) async -> Bool {
        return await DataSnapshot.$expected.withValue(dataGeneration) { await saveCurrent(identity) }
    }

    private func saveCurrent(_ identity: Identity) async -> Bool {
        #if DEBUG
        // Sample identities are not records: nothing of them reaches the database.
        if Self.isDebugSample { return true }
        #endif
        do {
            try DataSnapshot.check(dataGeneration)
            let saved = try await identityRepo.save(identity)
            await loadIdentities()
            savedIdentityId = saved.id
            NotificationCenter.default.post(name: .dsDataChanged, object: nil)
            logger.info("Saved identity: \(identity.name)")
            return true
        } catch {
            self.error = String(localized: "Failed to save identity: \(error.localizedDescription)")
            logger.error("Failed to save identity: \(error)")
            return false
        }
    }

    func deleteIdentity(_ identity: Identity) async {
        await DataSnapshot.$expected.withValue(dataGeneration) { await deleteCurrentIdentity(identity) }
    }

    private func deleteCurrentIdentity(_ identity: Identity) async {
        guard let id = identity.id else { return }
        #if DEBUG
        if Self.isDebugSample { return }
        #endif
        do {
            try DataSnapshot.check(dataGeneration)
            try await identityRepo.delete(id: id)
            await loadIdentities()
            NotificationCenter.default.post(name: .dsDataChanged, object: nil)
        } catch {
            self.error = String(localized: "Failed to delete identity: \(error.localizedDescription)")
            logger.error("Failed to delete identity: \(error)")
        }
    }

    /// Get SSH key name for display
    func keyName(for keyId: Int64?) -> String? {
        key(for: keyId)?.name
    }

    func key(for keyId: Int64?) -> SSHKey? {
        guard let keyId else { return nil }
        return availableKeys.first { $0.id == keyId }
    }

    // MARK: - Use

    /// The connections of the last `count` days to any of `hosts`, oldest day first.
    nonisolated static func activeDays(of hosts: [Host], in logs: [ConnectionLog], count: Int = 14,
                                       now: Date = Date(), calendar: Calendar = .current) -> [Bool] {
        let ids = Set(hosts.compactMap(\.id))
        let own = logs.filter { log in log.hostId.map { ids.contains($0) } ?? false }
        return DSDayStrip.days(from: DSActivityChart.days(from: own, count: count, now: now, calendar: calendar))
    }

    /// The host that was connected to last, with the time.
    nonisolated static func lastUsed(among hosts: [Host]) -> (host: Host, date: Date)? {
        var latest: (host: Host, date: Date)?
        for host in hosts {
            guard let date = host.lastConnectedAt.flatMap({ TimestampFormatter.date(from: $0) }) else { continue }
            if let current = latest, current.date >= date { continue }
            latest = (host, date)
        }
        return latest
    }

    // MARK: - Hosts and groups as this page sees them

    /// The window's hosts — in a debug build with `-debugVaultSample YES`, some of them given
    /// the sample identities (in memory only).
    func scoped(_ hosts: [Host]) -> [Host] {
        #if DEBUG
        if Self.isDebugSample { return Self.debugSampleHosts(hosts) }
        #endif
        return hosts
    }

    func scoped(_ groups: [HostGroup]) -> [HostGroup] {
        #if DEBUG
        if Self.isDebugSample { return groups + [Self.debugSampleGroup] }
        #endif
        return groups
    }

    #if DEBUG
    /// `-debugVaultSample YES`: the test data has no identities, so the page shows two sample
    /// ones (never written to the database) to make its populated state reachable in screenshots.
    /// Static: nothing for the `@Observable` macro to look at inside the `#if`.
    private static let isDebugSample = AppProfile.arguments.bool(forKey: "debugVaultSample")

    private static let debugSampleGroup = HostGroup(id: -1, name: "staging", sortOrder: 0,
                                                    createdAt: "2026-10-03T05:00:00Z", identityId: -1)

    private static func debugSampleIdentities(keys: [SSHKey]) -> [Identity] {
        let key = keys.first { $0.name == "test-pass" } ?? keys.first
        return [
            Identity(id: -1, name: "ops", username: "root", authType: "privateKey", passwordEncrypted: "sample",
                     privateKeyId: key?.id, createdAt: "2026-10-03T05:00:00Z"),
            Identity(id: -2, name: "dba", username: "postgres", authType: "password", passwordEncrypted: "sample",
                     privateKeyId: nil, createdAt: "2026-10-03T05:00:00Z")
        ]
    }

    private static func debugSampleHosts(_ hosts: [Host]) -> [Host] {
        hosts.map { host in
            var host = host
            switch host.label {
            case "test-agent", "test-a":
                host.identityId = -1
            case "jump":
                // Takes the identity from its group.
                host.privateKeyId = nil
                host.groupId = -1
            case "test-pw":
                host.identityId = -2
            default:
                break
            }
            return host
        }
    }
    #endif
}
