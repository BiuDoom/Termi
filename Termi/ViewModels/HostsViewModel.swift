import SwiftUI
import os.log

/// Everything the host form edits, saved in one go.
struct HostDraft {
    enum PasswordChange {
        case keep
        case set(String)
        case clear
    }

    var host: Host
    var portForwards: [PortForward]
    var tags: [String]
    var passwordChange: PasswordChange
    var dataGeneration: UUID = DataSnapshot.current
}

/// ViewModel for the hosts page: the hosts as cards (or rows), and the record of the selected one
/// in a panel that is there only while the user asked for it.
@Observable
@MainActor
final class HostsViewModel {
    private static let logger = Logger(subsystem: "dev.termi.Termi", category: "HostsVM")
    private let dataGeneration = DataSnapshot.current
    private var snapshotInvalidated = false
    private let hostRepo = HostRepository.shared
    private let groupRepo = GroupRepository.shared

    enum SortOrder: String, CaseIterable, Identifiable {
        case name, recent
        var id: String { rawValue }
    }

    /// How the page lays the hosts out. Cards are what a user starts with; the rows are the
    /// alternative behind the toolbar's switch.
    enum Layout: String, CaseIterable, Identifiable {
        case grid, list
        var id: String { rawValue }

        /// Not "hostsViewMode": that key is stored as "list" for everyone who used the page
        /// when the list (with a record always beside it) was the default. Under a new key
        /// every user starts on the cards.
        static let preferenceKey = "hostsLayout"
        static let standard = Layout.grid

        /// The layout a stored value stands for; the cards for none or one this version does not know.
        static func stored(_ raw: String?) -> Layout {
            raw.flatMap(Layout.init(rawValue:)) ?? standard
        }
    }

    // State
    var hosts: [Host] = [] {
        // The model outlives the page: a host deleted since cannot stay selected. Nothing takes
        // its place — a card looks selected only when the user (or a "reveal") selected it.
        didSet {
            if selectedHostId != nil, !hosts.contains(where: { $0.id == selectedHostId }) {
                selectedHostId = nil
            }
        }
    }
    /// The host whose card is outlined: the one the keys act on and, while the details are
    /// shown, the one whose record the panel holds. Nil until something is selected.
    var selectedHostId: Int64? {
        // The panel is about a host: without one it is closed, not waiting for the next
        // selection (a later click on a card would open a panel nobody asked for).
        didSet {
            if selectedHostId == nil { showsDetails = false }
            // "Picked by hand" is about the selection it made: once the selection is another
            // host or none (a filter hid it, an arrow key moved on), a later selection of the
            // same host by the page itself must not read as the user's choice to ⌫.
            if selectedHostId != pickedHostId { pickedHostId = nil }
        }
    }
    /// The host the user chose by hand (a click on its row or card). The page also selects by
    /// itself — a host that was just added, one another page links to — and ⌫ must not ask to
    /// delete a host nobody chose.
    private(set) var pickedHostId: Int64?

    /// The record panel is open. Lives with the window (the page leaves it while a terminal is
    /// looked at) and is not stored: every launch starts with the cards alone.
    private(set) var showsDetails = false

    /// The host whose record the panel shows; nil while the panel is closed.
    var detailsHostId: Int64? {
        showsDetails ? selectedHostId : nil
    }

    /// The card's button, its menu and its accessibility action: the record of that host —
    /// or, when the panel already shows it, the panel away again.
    func toggleDetails(for id: Int64?) {
        guard let id, hosts.contains(where: { $0.id == id }) else { return }
        if showsDetails && selectedHostId == id {
            showsDetails = false
        } else {
            pick(id)
            showsDetails = true
        }
    }

    /// ⌘I: the record of the selected host, or away with it. Nothing without a selection.
    func toggleDetails() {
        showsDetails = Self.detailsShown(afterTogglingFrom: showsDetails, selected: selectedHostId)
    }

    func hideDetails() {
        showsDetails = false
    }

    /// Another page's "Show in Hosts": that host selected, its record open, its card scrolled
    /// to — never toggled away, and not picked by hand. Whatever narrowed the page goes, or the
    /// host could be filtered out and the link would lead nowhere. Works before the first read
    /// (the page may not have been opened yet): a host the read does not bring is deselected then.
    func showRecord(of id: Int64) {
        searchText = ""
        selectedTag = nil
        showsOnlineOnly = false
        selectedHostId = id
        showsDetails = true
        revealedHostId = id
        revealCount += 1
    }

    /// The card the page scrolls to when it comes into the window: the one whose record is
    /// open, else the selected one — it may have been chosen while the page was away.
    var hostToBringIntoView: Int64? {
        detailsHostId ?? selectedHostId
    }

    nonisolated static func detailsShown(afterTogglingFrom shown: Bool, selected: Int64?) -> Bool {
        selected == nil ? false : !shown
    }

    /// The one button of a card or row (the way to the record) is there while the pointer is
    /// on it and while it is the selected one — nowhere else, so that the page stays quiet.
    nonisolated static func showsDetailsButton(isHovered: Bool, isSelected: Bool) -> Bool {
        isHovered || isSelected
    }

    /// Select a host because the user chose it.
    func pick(_ id: Int64?) {
        selectedHostId = id
        pickedHostId = id
    }

    /// The host ⌫ asks to delete: the selected one, when the list has the keyboard (its arrows
    /// chose it) or the user picked it by hand. Nil for a selection the page made by itself.
    nonisolated static func deleteTarget(selected: Int64?, picked: Int64?, listHasFocus: Bool) -> Int64? {
        guard let selected else { return nil }
        return listHasFocus || selected == picked ? selected : nil
    }

    /// The filter bar is worth its row while there is something to filter by — a tag, a host
    /// with a live session — or a filter is on (the lit chip is how to switch it off).
    nonisolated static func showsFilterBar(hostCount: Int, hasTags: Bool, hasOnline: Bool, isFiltering: Bool) -> Bool {
        hostCount > 0 && (hasTags || hasOnline || isFiltering)
    }

    /// How many cards of at least `minimum` points stand in a row of `width` points.
    nonisolated static func gridColumns(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard minimum + spacing > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }

    /// The card an arrow key leads to in the grid. `sections` are the groups in display order,
    /// each laid out in rows of `columns`. ← → walk the cards in reading order; ↑ ↓ keep the
    /// column, into the neighbouring group at its edge (a shorter row gives its last card).
    /// Nil at the ends; the first card when nothing is selected.
    nonisolated static func gridNeighbour(of selection: Int64?, in sections: [[Int64]], columns: Int,
                                          direction: MoveCommandDirection) -> Int64? {
        let columns = max(1, columns)
        // Every row of the grid, across the groups.
        let rows: [[Int64]] = sections.flatMap { section in
            stride(from: 0, to: section.count, by: columns).map { Array(section[$0..<min($0 + columns, section.count)]) }
        }
        guard let first = rows.first?.first else { return nil }
        guard let selection,
              let row = rows.firstIndex(where: { $0.contains(selection) }),
              let column = rows[row].firstIndex(of: selection) else { return first }
        switch direction {
        case .left:
            if column > 0 { return rows[row][column - 1] }
            return row > 0 ? rows[row - 1].last : nil
        case .right:
            if column < rows[row].count - 1 { return rows[row][column + 1] }
            return row < rows.count - 1 ? rows[row + 1].first : nil
        case .up:
            guard row > 0 else { return nil }
            return rows[row - 1][min(column, rows[row - 1].count - 1)]
        case .down:
            guard row < rows.count - 1 else { return nil }
            return rows[row + 1][min(column, rows[row + 1].count - 1)]
        @unknown default:
            return nil
        }
    }

    /// The selection once the page shows only `visible` (a filter or a search narrowed it): the
    /// record, Return and ⌫ are about a host the page shows, so a hidden selection is given up.
    /// Nothing is selected in its place: that would outline a card the user never chose.
    nonisolated static func selection(_ selected: Int64?, keptWithin visible: [Int64]) -> Int64? {
        guard let selected, visible.contains(selected) else { return nil }
        return selected
    }

    /// The page moved the selection, not the user: it is not a host picked by hand.
    func keepSelection(within visible: [Int64]) {
        let kept = Self.selection(selectedHostId, keptWithin: visible)
        if kept != selectedHostId { selectedHostId = kept }
    }
    var allGroups: [HostGroup] = []
    var tagsByHost: [Int64: [Tag]] = [:]
    var allTagNames: [String] = []
    var searchText = ""
    var selectedTag: String?
    /// Only hosts with a live session. Lives here like the tag filter: the page goes while a
    /// terminal is looked at.
    var showsOnlineOnly = false
    var sortOrder: SortOrder = SortOrder(rawValue: AppProfile.defaults.string(forKey: "hostSortOrder") ?? "") ?? .name {
        didSet { AppProfile.defaults.set(sortOrder.rawValue, forKey: "hostSortOrder") }
    }
    var isLoading = false
    /// The first read is done: until then the page draws neither hosts nor an empty state.
    private(set) var hasLoaded = false
    var error: String?

    // What the detail of a host shows besides the host itself.
    private(set) var logsByHost: [Int64: [ConnectionLog]] = [:]
    private(set) var forwardsByHost: [Int64: [PortForward]] = [:]
    /// Hosts with a password in the vault (the password itself is not kept).
    private(set) var savedPasswordHostIds: Set<Int64> = []
    private(set) var knownHosts: [KnownHost] = []
    private(set) var keys: [SSHKey] = []
    private(set) var identities: [Identity] = []
    private(set) var snippets: [Snippet] = []
    /// Counts the reads of the hosts: the detail reloads its own data with each.
    private(set) var revision = 0

    // Sheet state
    var showingAddHost = false
    var newHostGroupId: Int64?
    var editingHost: Host?
    var showingAddGroup = false
    var editingGroup: HostGroup?
    var showingDeleteConfirm = false
    var hostToDelete: Host?
    var groupToDelete: HostGroup?

    /// The page left the window (a terminal or the lock screen took its place) while the model
    /// stays: a sheet or alert left open would come back with the page.
    func dismissSheets() {
        showingAddHost = false
        editingHost = nil
        showingAddGroup = false
        editingGroup = nil
        showingDeleteConfirm = false
        hostToDelete = nil
        groupToDelete = nil
    }

    // MARK: - Derived

    var totalHostCount: Int { hosts.count }

    var selectedHost: Host? {
        guard let id = selectedHostId else { return nil }
        return hosts.first { $0.id == id }
    }

    func hostCount(forTag tag: String) -> Int {
        tagsByHost.values.filter { tags in tags.contains { $0.name == tag } }.count
    }

    /// `filteredGroupedHosts`, narrowed to the hosts with a live session while that filter is on.
    func visibleGroups(onlineHostIds: Set<Int64>) -> [(group: HostGroup?, hosts: [Host])] {
        let groups = filteredGroupedHosts
        guard showsOnlineOnly else { return groups }
        return Self.keepingOnline(groups, onlineHostIds: onlineHostIds)
    }

    /// Groups left without a host go: an empty group among "online" hosts says nothing.
    nonisolated static func keepingOnline(_ groups: [(group: HostGroup?, hosts: [Host])],
                                          onlineHostIds: Set<Int64>) -> [(group: HostGroup?, hosts: [Host])] {
        groups.compactMap { item in
            let online = item.hosts.filter { host in host.id.map { onlineHostIds.contains($0) } ?? false }
            let kept: (group: HostGroup?, hosts: [Host])? = online.isEmpty ? nil : (group: item.group, hosts: online)
            return kept
        }
    }

    func logs(for hostId: Int64?) -> [ConnectionLog] {
        hostId.flatMap { logsByHost[$0] } ?? []
    }

    func forwards(for hostId: Int64?) -> [PortForward] {
        hostId.flatMap { forwardsByHost[$0] } ?? []
    }

    /// Hosts after search + tag filter, sorted, grouped (ungrouped first).
    var filteredGroupedHosts: [(group: HostGroup?, hosts: [Host])] {
        var visible = hosts
        if let tag = selectedTag {
            visible = visible.filter { host in
                host.id.flatMap { tagsByHost[$0] }?.contains { $0.name == tag } ?? false
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            visible = visible.filter { host in
                host.label.lowercased().contains(query)
                    || host.hostname.lowercased().contains(query)
                    || host.username.lowercased().contains(query)
                    // "user@host" / "host:port", as the search field invites to type
                    || host.addressDescription.lowercased().contains(query)
                    || (host.notes?.lowercased().contains(query) ?? false)
                    || (host.id.flatMap { tagsByHost[$0] }?.contains { $0.name.lowercased().contains(query) } ?? false)
            }
        }
        visible.sort(by: sortComparator)

        var result: [(group: HostGroup?, hosts: [Host])] = []
        let ungrouped = visible.filter { host in host.groupId == nil || !allGroups.contains(where: { g in g.id == host.groupId }) }
        if !ungrouped.isEmpty {
            result.append((nil, ungrouped))
        }
        for group in allGroups {
            let members = visible.filter { $0.groupId == group.id }
            // Show empty groups only when not filtering, so they can still be edited.
            if !members.isEmpty || (query.isEmpty && selectedTag == nil) {
                result.append((group, members))
            }
        }
        return result
    }

    private var sortComparator: (Host, Host) -> Bool {
        switch sortOrder {
        case .name:
            return { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        case .recent:
            return { a, b in
                let lhs = a.lastConnectedAt ?? ""
                let rhs = b.lastConnectedAt ?? ""
                if lhs != rhs { return lhs > rhs }
                return a.label.localizedStandardCompare(b.label) == .orderedAscending
            }
        }
    }

    /// Search text that looks like "user@host[:port]" → the saved host at that address,
    /// or an unsaved host to quick connect to.
    var quickConnectCandidate: Host? {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard text.contains("@") || text.contains("."), !text.contains(" "),
              let parsed = QuickConnectParser.parse(text) else { return nil }
        return Self.savedHost(matching: text, in: hosts) ?? parsed
    }

    /// The saved host at the address typed as "user@host[:port]", if there is one.
    nonisolated static func savedHost(matching input: String, in hosts: [Host]) -> Host? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard let parsed = QuickConnectParser.parse(text) else { return nil }
        // A typed user must match too: "deploy@host" is not the saved "root@host".
        let userTyped = text.contains("@") && !text.hasPrefix("@")
        return hosts.first {
            $0.hostname.caseInsensitiveCompare(parsed.hostname) == .orderedSame && $0.port == parsed.port
                && (!userTyped || $0.username == parsed.username)
        }
    }

    /// The latest connections that were not to a saved host, one per address (Quick Connect
    /// offers them again). `logs` newest first.
    nonisolated static func recentAdHoc(from logs: [ConnectionLog], limit: Int = 5) -> [ConnectionLog] {
        var seen = Set<String>()
        var result: [ConnectionLog] = []
        for log in logs where log.hostId == nil && !log.hostLabel.isEmpty {
            guard seen.insert(log.hostLabel).inserted else { continue }
            result.append(log)
            if result.count == limit { break }
        }
        return result
    }

    func recentQuickConnections() async -> [ConnectionLog] {
        Self.recentAdHoc(from: (try? await ConnectionLogRepository.shared.fetchAll()) ?? [])
    }

    func tags(for host: Host) -> [Tag] {
        host.id.flatMap { tagsByHost[$0] } ?? []
    }

    // MARK: - Load

    func loadHosts() async {
        isLoading = true
        // A read cut short by the page leaving does not count: the model stays, and the page
        // would come back to an empty state until the next read is through.
        defer { isLoading = false; if !Task.isCancelled { hasLoaded = true } }

        do {
            hosts = try await hostRepo.fetchAll()
            allGroups = try await groupRepo.fetchAll()
            let tags = try? await TagRepository.shared.tagsByHost()
            // The page left while its tags were read (the read is cancelled with it): the model
            // stays, so its tags and tag filter are kept instead of being emptied.
            guard !Task.isCancelled else { return }
            tagsByHost = tags ?? [:]
            allTagNames = Array(Set(tagsByHost.values.flatMap { $0.map(\.name) }))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if let tag = selectedTag, !allTagNames.contains(tag) {
                selectedTag = nil
            }
            error = nil
            revision += 1
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            Self.logger.error("Failed to load hosts: \(error.localizedDescription)")
        }
    }

    /// What the record of one host shows: its connections, its forwarding rules, whether the
    /// vault holds its password.
    func loadDetail(for hostId: Int64) async {
        let logs = try? await ConnectionLogRepository.shared.fetchForHost(hostId)
        let forwards = try? await PortForwardRepository.shared.fetchForHost(hostId)
        let password = try? await SecureStoreService.shared.getHostPassword(hostId: hostId)
        // The selection moved on (the read is cancelled with it): what is there stays.
        guard !Task.isCancelled else { return }
        if let logs { logsByHost[hostId] = logs }
        if let forwards { forwardsByHost[hostId] = forwards }
        if password?.isEmpty == false {
            savedPasswordHostIds.insert(hostId)
        } else {
            savedPasswordHostIds.remove(hostId)
        }
    }

    /// The records a host points to (its key, identity, startup snippet, host key).
    func loadReferences() async {
        let knownHosts = try? await KnownHostRepository.shared.fetchAll()
        let keys = try? await SSHKeyRepository.shared.fetchAll()
        let identities = try? await IdentityRepository.shared.fetchAll()
        let snippets = try? await SnippetRepository.shared.fetchAll()
        guard !Task.isCancelled else { return }
        self.knownHosts = knownHosts ?? []
        self.keys = keys ?? []
        self.identities = identities ?? []
        self.snippets = snippets ?? []
    }

    /// Other pages count hosts and groups (the sidebar, "used by these hosts").
    private func announceChange() {
        NotificationCenter.default.post(name: .dsDataChanged, object: nil)
    }

    func invalidateSnapshot() {
        snapshotInvalidated = true
        dismissSheets()
        hosts = []
        selectedHostId = nil
    }

    // MARK: - Host CRUD

    func save(_ draft: HostDraft) async {
        let isNew = draft.host.id == nil
        let result = await Self.store(draft)
        await loadHosts()
        // After the reload, which clears `error`.
        if let failure = result.failure {
            error = failure
        }
        // A host that was just added is the one the user is working on — also when a later
        // step (its password, its tags) failed: the record shows what was saved.
        if isNew, let id = result.id { reveal(id) }
    }

    /// The host the list is asked to bring into view, and how often it was asked (the same
    /// host can be asked for twice).
    private(set) var revealedHostId: Int64?
    private(set) var revealCount = 0

    /// Select a host that was just added and ask the list to scroll to it. The page made this
    /// selection, not a click: ⌫ still asks only about a host the user picked (`pickedHostId`).
    func reveal(_ id: Int64) {
        guard hosts.contains(where: { $0.id == id }) else { return }
        selectedHostId = id
        revealedHostId = id
        revealCount += 1
    }

    /// Save a host with its vault password, port forwarding rules and tags. Returns why it
    /// could not be saved, nil when it was.
    @discardableResult
    static func save(_ draft: HostDraft) async -> String? {
        await store(draft).failure
    }

    /// `save`, with the id the host has in the database once its row is written. Every other
    /// page and window hears of it (`.dsDataChanged`) — also when a later step failed: rules
    /// may already have been stopped and deleted, or the row changed.
    static func store(_ draft: HostDraft) async -> (id: Int64?, failure: String?) {
        let result = await DataSnapshot.$expected.withValue(draft.dataGeneration) { await storeCurrent(draft) }
        NotificationCenter.default.post(name: .dsDataChanged, object: nil)
        return result
    }

    private static func storeCurrent(_ draft: HostDraft) async -> (id: Int64?, failure: String?) {
        var savedId: Int64?
        do {
            try DataSnapshot.check(draft.dataGeneration)
            var hostToSave = draft.host
            hostToSave.passwordEncrypted = nil
            // The password goes in the row's transaction: a changed login drops the old one and
            // a new one is written with it, so neither account ever holds the other's secret.
            let password: HostRepository.SavedPassword
            switch draft.passwordChange {
            case .keep:
                password = .keep
            case .set(let text):
                password = .replace(encrypted: try await SecureStoreService.shared.encryptStoredValue(text))
            case .clear:
                password = .forget
            }
            let saved = try await HostRepository.shared.save(hostToSave, password: password)
            guard let hostId = saved.id else { return (nil, nil) }
            savedId = hostId

            let existing = try await PortForwardRepository.shared.fetchForHost(hostId)
            let incomingIds = Set(draft.portForwards.compactMap(\.id))
            for rule in existing where !incomingIds.contains(rule.id ?? -1) {
                if let id = rule.id {
                    let mutation = try PortForwardManager.shared.beginMutation(id: id)
                    defer { PortForwardManager.shared.endMutation(mutation) }
                    try await PortForwardManager.shared.stopForMutation(rule)
                    try await PortForwardRepository.shared.delete(id: id)
                }
            }
            for var rule in draft.portForwards {
                rule.hostId = hostId
                let mutation = try PortForwardManager.shared.beginMutation(id: rule.id)
                defer { PortForwardManager.shared.endMutation(mutation) }
                try await PortForwardManager.shared.prepareToSave(rule)
                try await PortForwardRepository.shared.save(rule)
            }

            try await TagRepository.shared.setTags(draft.tags, forHost: hostId)
            logger.info("Host saved: \(saved.label)")
            return (hostId, nil)
        } catch {
            logger.error("Failed to save host: \(error.localizedDescription)")
            return (savedId, error.localizedDescription)
        }
    }

    /// Retrieve the stored password for a host from the encrypted vault
    func getHostPassword(_ hostId: Int64) async -> String? {
        try? await SecureStoreService.shared.getHostPassword(hostId: hostId)
    }

    func deleteHost(_ host: Host) async {
        await DataSnapshot.$expected.withValue(dataGeneration) { await deleteCurrentHost(host) }
    }

    private func deleteCurrentHost(_ host: Host) async {
        guard let id = host.id else { return }
        do {
            guard !snapshotInvalidated else { throw DataSnapshot.StaleSnapshot() }
            try DataSnapshot.check(dataGeneration)
            await SSHService.shared.disconnect(host)
            // With its history (the database cascades it) goes what that history recorded:
            // the saved session output. The confirmation says so.
            try await ConnectionLogRepository.shared.deleteHostWithHistory(hostId: id)
            try? await SecureStoreService.shared.deleteHostPassword(hostId: id)
            logsByHost[id] = nil
            forwardsByHost[id] = nil
            savedPasswordHostIds.remove(id)
            await loadHosts()
            announceChange()
            Self.logger.info("Host deleted: \(host.label)")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func duplicateHost(_ host: Host) async {
        await DataSnapshot.$expected.withValue(dataGeneration) {
            await duplicateCurrentHost(host)
        }
    }

    private func duplicateCurrentHost(_ host: Host) async {
        guard let sourceId = host.id else { return }
        do {
            guard !snapshotInvalidated else { throw DataSnapshot.StaleSnapshot() }
            try DataSnapshot.check(dataGeneration)
            guard let newHost = try await hostRepo.duplicate(id: sourceId),
                  let newId = newHost.id else { return }

            if let password = try? await SecureStoreService.shared.getHostPassword(hostId: sourceId) {
                try? await SecureStoreService.shared.setHostPassword(password, hostId: newId)
            }
            try? await TagRepository.shared.copyTags(from: sourceId, to: newId)
            for var rule in (try? await PortForwardRepository.shared.fetchForHost(sourceId)) ?? [] {
                rule.id = nil
                rule.hostId = newId
                _ = try? await PortForwardRepository.shared.save(rule)
            }
            await loadHosts()
            announceChange()
            // The copy is what the user goes on with (it gets another name or address).
            reveal(newId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Group CRUD

    func saveGroup(_ group: HostGroup) async {
        do {
            try await DataSnapshot.$expected.withValue(dataGeneration) {
                guard !snapshotInvalidated else { throw DataSnapshot.StaleSnapshot() }
                try await groupRepo.save(group)
            }
            await loadHosts()
            announceChange()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteGroup(_ group: HostGroup) async {
        guard let id = group.id else { return }
        do {
            try await DataSnapshot.$expected.withValue(dataGeneration) {
                guard !snapshotInvalidated else { throw DataSnapshot.StaleSnapshot() }
                try await groupRepo.delete(id: id)
            }
            await loadHosts()
            announceChange()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Parses "user@host", "host:port", "user@[::1]:2222" for Quick Connect.
enum QuickConnectParser {
    static func parse(_ input: String) -> Host? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var username = ""
        var rest = trimmed
        if let at = trimmed.lastIndex(of: "@") {
            username = String(trimmed[..<at])
            rest = String(trimmed[trimmed.index(after: at)...])
        }
        guard let (hostname, port) = parseHostPort(rest),
              SSHConnectionSpec.isSafeValue(hostname),
              username.isEmpty || SSHConnectionSpec.isSafeValue(username),
              (1...65535).contains(port) else { return nil }

        var host = Host.defaultValue()
        host.hostname = hostname
        host.port = port
        host.username = username.isEmpty ? NSUserName() : username
        // Like plain ssh: agent + default keys first, the password is only the fallback.
        host.authType = "agent"
        host.label = host.addressDescription
        return host
    }

    /// What a typed address left out, and `parse` filled in: the user (this Mac's), the port (22).
    /// Nil when the address does not parse.
    static func defaults(filledIn input: String) -> (user: Bool, port: Bool)? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let host = parse(trimmed) else { return nil }
        let rest = trimmed.lastIndex(of: "@").map { String(trimmed[trimmed.index(after: $0)...]) } ?? trimmed
        let typedUser = trimmed.lastIndex(of: "@").map { !trimmed[..<$0].isEmpty } ?? false
        // The port was typed when the address is longer than the host name (and its brackets).
        let bare = rest.hasPrefix("[") ? "[\(host.hostname)]" : host.hostname
        return (!typedUser, rest == bare)
    }

    private static func parseHostPort(_ input: String) -> (String, Int)? {
        if input.hasPrefix("[") {
            guard let close = input.firstIndex(of: "]") else { return nil }
            let hostname = String(input[input.index(after: input.startIndex)..<close])
            let after = input[input.index(after: close)...]
            let port = after.hasPrefix(":") ? Int(after.dropFirst()) : 22
            guard !hostname.isEmpty, let port else { return nil }
            return (hostname, port)
        }
        // Bare IPv6 (several colons): no port.
        if input.filter({ $0 == ":" }).count > 1 {
            return (input, 22)
        }
        let parts = input.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        if parts.count == 2 {
            guard let port = Int(parts[1]) else { return nil }
            return (String(first), port)
        }
        return (String(first), 22)
    }
}
