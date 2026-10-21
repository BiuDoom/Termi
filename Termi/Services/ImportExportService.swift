import Foundation
import GRDB
import os.log

/// Import/Export for CSV, SSH Config, and encrypted vault
actor ImportExportService {
    static let shared = ImportExportService()

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "ImportExport")
    private let hostRepo = HostRepository.shared
    private let groupRepo = GroupRepository.shared

    // MARK: - CSV Export

    /// Export hosts to CSV format
    func exportHostsCSV() async throws -> String {
        let hosts = try await hostRepo.fetchAll()
        let groups = try await groupRepo.fetchAll()
        return Self.hostsCSV(hosts: hosts, groups: groups)
    }

    nonisolated static func hostsCSV(hosts: [Host], groups: [HostGroup]) -> String {
        let groupMap = Dictionary(uniqueKeysWithValues: groups.compactMap { g in
            g.id.map { ($0, g.name) }
        })

        var csv = "label,hostname,port,username,auth_type,group,notes,ssh_config_alias\n"

        for host in hosts {
            let groupName = host.groupId.flatMap { groupMap[$0] } ?? ""
            let fields = [
                escapeCSV(host.label),
                escapeCSV(host.hostname),
                "\(host.port)",
                escapeCSV(host.username),
                escapeCSV(host.authType),
                escapeCSV(groupName),
                escapeCSV(host.notes ?? ""),
                escapeCSV(host.sshConfigAlias ?? ""),
            ]
            csv += fields.joined(separator: ",") + "\n"
        }

        return csv
    }

    /// Save CSV to file
    func exportHostsToFile(url: URL) async throws {
        let csv = try await exportHostsCSV()
        try csv.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Exported \(csv.components(separatedBy: "\\n").count - 2) hosts to CSV")
    }

    // MARK: - CSV Import

    /// Parse and validate the whole file before writing. Groups and hosts are one transaction:
    /// a rejected record or database error must never leave a partially imported inventory.
    func importHostsCSV(from url: URL) async throws -> [Host] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let writer = try await DatabaseManager.shared.writer
        let imported = try await Self.importHostsCSV(content, into: writer)
        logger.info("Imported \(imported.count) hosts from CSV")
        return imported
    }

    nonisolated static func importHostsCSV(_ content: String, into writer: any DatabaseWriter) async throws -> [Host] {
        let records = try parseCSV(content)
        guard records.count > 1 else { throw ImportError.emptyFile }
        let header = records[0].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        guard Set(header).count == header.count,
              let hostnameIdx = header.firstIndex(of: "hostname") ?? header.firstIndex(of: "host") else {
            throw ImportError.invalidFormat
        }
        let labelIdx = header.firstIndex(of: "label") ?? header.firstIndex(of: "name")
        let portIdx = header.firstIndex(of: "port")
        let usernameIdx = header.firstIndex(of: "username") ?? header.firstIndex(of: "user")
        let authIdx = header.firstIndex(of: "auth_type") ?? header.firstIndex(of: "auth")
        let groupIdx = header.firstIndex(of: "group")
        let aliasIdx = header.firstIndex(of: "ssh_config_alias")
        let notesIdx = header.firstIndex(of: "notes") ?? header.firstIndex(of: "description")

        let pending: [(host: Host, groupName: String)] = try records.dropFirst().map { fields in
            guard fields.count == header.count else { throw ImportError.invalidFormat }
            let hostname = fields[hostnameIdx]
            let configAlias = aliasIdx.map { fields[$0] } ?? ""
            let portText = portIdx.map { fields[$0] } ?? ""
            let port = portText.isEmpty ? 22 : Int(portText)
            let username = usernameIdx.map { fields[$0] } ?? "root"
            let auth = authIdx.map { fields[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? "password"
            guard SSHConnectionSpec.isSafeValue(hostname),
                  configAlias.isEmpty || SSHConnectionSpec.isSafeValue(configAlias),
                  username.isEmpty || SSHConnectionSpec.isSafeValue(username),
                  let port, (1...65535).contains(port),
                  ["password", "privateKey", "agent"].contains(auth) else {
                throw ImportError.invalidFormat
            }
            var host = Host.defaultValue()
            let label = labelIdx.map { fields[$0] } ?? ""
            host.label = label.isEmpty ? hostname : label
            host.hostname = hostname
            host.sshConfigAlias = configAlias.isEmpty ? nil : configAlias
            host.port = port
            host.username = username
            host.authType = auth
            host.notes = notesIdx.map { fields[$0] }
            return (host, groupIdx.map { fields[$0] } ?? "")
        }

        return try await DataSnapshot.write(writer) { db in
            var groupsByName = Dictionary(grouping: try HostGroup.fetchAll(db), by: \.name)
            var imported: [Host] = []
            for record in pending {
                var host = record.host
                if !record.groupName.isEmpty {
                    let matches = groupsByName[record.groupName] ?? []
                    // A name-only CSV cannot tell two identically named groups apart. Guessing
                    // could silently apply another group's credentials or jump host.
                    guard matches.count < 2 else { throw ImportError.ambiguousGroup(record.groupName) }
                    if let group = matches.first {
                        host.groupId = group.id
                    } else {
                        let group = try HostGroup(name: record.groupName, sortOrder: 0,
                                                  createdAt: TimestampFormatter.now()).insertAndFetch(db)
                        groupsByName[record.groupName] = [group]
                        host.groupId = group.id
                    }
                }
                imported.append(try HostRepository.save(host, db))
            }
            return imported
        }
    }

    // MARK: - SSH Config Import

    struct SSHConfigImportSummary: Sendable, CustomStringConvertible {
        var imported = 0
        var skipped = 0
        var keysImported = 0

        var description: String {
            String(localized: "Imported \(imported) hosts from SSH config (\(skipped) already existed, \(keysImported) keys added to Keychain).")
        }
    }

    /// Import hosts from an OpenSSH client config (default `~/.ssh/config`).
    ///
    /// `Host *` defaults, `Include`, IdentityFile keys (added to the encrypted vault),
    /// forwards and ProxyJump chains are carried over; hosts that already exist are skipped.
    func importSSHConfig(from url: URL? = nil) async throws -> SSHConfigImportSummary {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configURL = url ?? URL(fileURLWithPath: home + "/.ssh/config")
        let content = try String(contentsOf: configURL, encoding: .utf8)
        let entries = SSHConfigParser.parse(content, homeDirectory: home)

        var knownHosts = try await hostRepo.fetchAll()
        let existingKeys = try await SSHKeyRepository.shared.fetchAll()
        var aliasToHostId: [String: Int64] = [:]
        var keyCache: [String: Int64] = [:]
        var pendingJumps: [(hostId: Int64, proxyJump: String)] = []
        var summary = SSHConfigImportSummary()

        for entry in entries {
            let hostname = entry.resolvedHostName
            let port = entry.port ?? 22
            let user = entry.user ?? NSUserName()
            guard SSHConnectionSpec.isSafeValue(hostname), SSHConnectionSpec.isSafeValue(user),
                  SSHConnectionSpec.isSafeValue(entry.alias),
                  (1...65535).contains(port) else {
                summary.skipped += 1
                continue
            }
            if let match = knownHosts.first(where: {
                $0.hostname.caseInsensitiveCompare(hostname) == .orderedSame && $0.port == port
                    && ($0.username == user || $0.username.isEmpty)
            }), let id = match.id {
                if match.sshConfigAlias == nil,
                   let refreshed = try await rememberSSHConfigAlias(entry.alias, for: match),
                   let index = knownHosts.firstIndex(where: { $0.id == id }) {
                    knownHosts[index] = refreshed
                }
                aliasToHostId[entry.alias] = id
                summary.skipped += 1
                continue
            }

            var host = Host.defaultValue()
            host.label = entry.alias
            host.sshConfigAlias = entry.alias
            host.hostname = hostname
            host.port = port
            host.username = user
            host.agentForwarding = entry.forwardAgent ?? false
            host.x11Forwarding = entry.forwardX11 ?? false
            // Like plain ssh: agent + default keys, unless an IdentityFile can be imported.
            host.authType = "agent"
            for path in entry.identityFiles where FileManager.default.isReadableFile(atPath: path) {
                if let keyId = try? await importKey(at: path, cache: &keyCache, existing: existingKeys,
                                                    summary: &summary) {
                    host.authType = "privateKey"
                    host.privateKeyId = keyId
                    break
                }
            }

            let saved = try await hostRepo.save(host)
            guard let hostId = saved.id else { continue }
            knownHosts.append(saved)
            aliasToHostId[entry.alias] = hostId
            summary.imported += 1

            let now = TimestampFormatter.now()
            for forward in entry.localForwards + entry.remoteForwards {
                try await PortForwardRepository.shared.save(PortForward(
                    hostId: hostId, type: forward.kind.rawValue, localPort: forward.bindPort,
                    remoteHost: forward.destinationHost, remotePort: forward.destinationPort,
                    enabled: true, createdAt: now))
            }
            for dynamicPort in entry.dynamicForwards {
                try await PortForwardRepository.shared.save(PortForward(
                    hostId: hostId, type: "dynamic", localPort: dynamicPort,
                    remoteHost: "", remotePort: 0, enabled: true, createdAt: now))
            }
            if let jump = entry.proxyJump {
                pendingJumps.append((hostId, jump))
            }
        }

        // ProxyJump "a,b" → host → b → a chain via jump host references.
        for (hostId, jump) in pendingJumps {
            var previous: Int64?
            for hop in SSHConfigParser.proxyJumpHops(jump) {
                let hopId: Int64
                if hop.user == nil, hop.port == nil, let aliasId = aliasToHostId[hop.host] {
                    hopId = aliasId
                } else if let match = knownHosts.first(where: {
                    $0.hostname.caseInsensitiveCompare(hop.host) == .orderedSame && $0.port == (hop.port ?? 22)
                        && (hop.user == nil || $0.username == hop.user)
                }), let id = match.id {
                    hopId = id
                } else {
                    guard SSHConnectionSpec.isSafeValue(hop.host) else { break }
                    var jumpHost = Host.defaultValue()
                    let configured = entries.first { $0.alias == hop.host }
                    jumpHost.label = hop.host
                    jumpHost.sshConfigAlias = hop.host
                    jumpHost.hostname = configured?.resolvedHostName ?? hop.host
                    jumpHost.port = hop.port ?? configured?.port ?? 22
                    jumpHost.username = hop.user ?? configured?.user ?? NSUserName()
                    guard SSHConnectionSpec.isSafeValue(jumpHost.hostname),
                          SSHConnectionSpec.isSafeValue(jumpHost.username),
                          (1...65535).contains(jumpHost.port) else { break }
                    jumpHost.authType = "agent"
                    let saved = try await hostRepo.save(jumpHost)
                    guard let id = saved.id else { break }
                    knownHosts.append(saved)
                    summary.imported += 1
                    hopId = id
                }
                if let previous, var hopHost = knownHosts.first(where: { $0.id == hopId }),
                   hopHost.jumpHostId == nil, hopId != previous {
                    hopHost.jumpHostId = previous
                    try await hostRepo.save(hopHost)
                    if let index = knownHosts.firstIndex(where: { $0.id == hopId }) {
                        knownHosts[index] = hopHost
                    }
                }
                previous = hopId
            }
            if let last = previous, last != hostId, var target = knownHosts.first(where: { $0.id == hostId }) {
                target.jumpHostId = last
                try await hostRepo.save(target)
            }
        }

        logger.info("SSH config import: \(summary.imported) imported, \(summary.skipped) skipped")
        return summary
    }

    /// Explicitly importing the user's config can recover aliases for older imported hosts.
    /// Only fill the missing alias: a stale copy must not overwrite another window's edits.
    private func rememberSSHConfigAlias(_ alias: String, for host: Host) async throws -> Host? {
        guard let id = host.id else { return nil }
        let writer = try await DatabaseManager.shared.writer
        return try await DataSnapshot.write(writer) { db in
            try db.execute(sql: """
                UPDATE hosts SET ssh_config_alias = ?
                WHERE id = ? AND hostname = ? AND port = ? AND username = ? AND ssh_config_alias IS NULL
                """, arguments: [alias, id, host.hostname, host.port, host.username])
            return try Host.fetchOne(db, key: id)
        }
    }

    private func importKey(at path: String, cache: inout [String: Int64], existing: [SSHKey],
                           summary: inout SSHConfigImportSummary) async throws -> Int64? {
        if let id = cache[path] { return id }
        let privateText = try String(contentsOfFile: path, encoding: .utf8)
        guard privateText.contains("PRIVATE KEY") else { return nil }
        let publicText = (try? String(contentsOfFile: path + ".pub", encoding: .utf8)) ?? ""
        let key = try await SSHKeyGenerator.shared.importKeyFromText(privateKeyText: privateText,
                                                                     publicKeyText: publicText)

        let keyBody = key.publicKey.split(separator: " ").prefix(2).joined(separator: " ")
        if !keyBody.isEmpty, let match = existing.first(where: {
            $0.publicKey.split(separator: " ").prefix(2).joined(separator: " ") == keyBody
        }), let id = match.id {
            cache[path] = id
            return id
        }

        let encrypted = try await SecureStoreService.shared.encryptStoredValue(key.privateKey)
        let saved = try await SSHKeyRepository.shared.save(SSHKey(
            name: URL(fileURLWithPath: path).lastPathComponent,
            type: key.type,
            publicKey: key.publicKey,
            privateKeyEncrypted: encrypted,
            fingerprint: key.fingerprint,
            createdAt: ""
        ))
        guard let id = saved.id else { return nil }
        summary.keysImported += 1
        cache[path] = id
        return id
    }

    // MARK: - Backup / Restore

    /// Create a full database backup
    func createBackup(to url: URL) async throws {
        try await DatabaseManager.shared.backup(to: url)
        logger.info("Created backup at \(url.path)")
    }

    /// Restore from a backup file. Returns where the database it replaced was kept.
    @discardableResult
    func restoreBackup(from url: URL) async throws -> URL {
        let db = DatabaseManager.shared
        let dbURL = try await db.databaseURL

        // Copy and check first: a file that is not a usable backup must not cost the current
        // database.
        let staged: URL
        do {
            staged = try DatabaseManager.stageBackup(from: url, forDatabaseAt: dbURL.path)
        } catch {
            logger.error("Backup at \(url.path) was not restored: \(error)")
            throw error
        }

        let kept: URL
        do {
            kept = try await db.replaceDatabase(with: staged)
        } catch {
            // The staged copy, unless it was already taken out again with the failed swap.
            try? FileManager.default.removeItem(at: staged)
            throw error
        }

        // The key in memory belongs to the replaced database's master password (or to none).
        await SecureStoreService.shared.lockVault()
        logger.info("Restored backup from \(url.path); previous database kept at \(kept.path)")
        return kept
    }

    // MARK: - Private Helpers

    nonisolated private static func escapeCSV(_ value: String) -> String {
        if value.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            || value != value.trimmingCharacters(in: .whitespaces) {
            var escaped = "\""
            for scalar in value.unicodeScalars {
                if scalar == "\"" { escaped.append("\"") }
                escaped.unicodeScalars.append(scalar)
            }
            return escaped + "\""
        }
        return value
    }

    /// CSV records span physical lines inside quoted fields. Iterate Unicode scalars so CRLF
    /// is recognized as a line ending outside quotes and preserved byte-for-byte inside them.
    nonisolated private static func parseCSV(_ content: String) throws -> [[String]] {
        let scalars = Array(content.unicodeScalars)
        var index = scalars.first == "\u{FEFF}" ? 1 : 0
        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var quoted = false
        var closedQuote = false
        var hasRecord = false

        func finishField() {
            fields.append(quoted ? field : field.trimmingCharacters(in: .whitespaces))
            field = ""
            quoted = false
            closedQuote = false
        }
        func finishRecord() {
            if hasRecord {
                finishField()
                records.append(fields)
            }
            fields = []
            field = ""
            quoted = false
            closedQuote = false
            hasRecord = false
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                        closedQuote = true
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
            } else if scalar == "," {
                hasRecord = true
                finishField()
            } else if scalar == "\n" || scalar == "\r" {
                finishRecord()
                if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
            } else if closedQuote {
                guard scalar == " " || scalar == "\t" else { throw ImportError.invalidFormat }
            } else if scalar == "\"" {
                guard field.isEmpty else { throw ImportError.invalidFormat }
                inQuotes = true
                quoted = true
                hasRecord = true
            } else {
                field.unicodeScalars.append(scalar)
                if scalar != " " && scalar != "\t" { hasRecord = true }
            }
            index += 1
        }
        guard !inQuotes else { throw ImportError.invalidFormat }
        finishRecord()
        return records
    }

    // MARK: - Error

    enum ImportError: Error, LocalizedError {
        case emptyFile
        case invalidFormat
        case fileNotFound
        case ambiguousGroup(String)

        var errorDescription: String? {
            switch self {
            case .emptyFile: String(localized: "File is empty")
            case .invalidFormat: String(localized: "Invalid file format")
            case .fileNotFound: String(localized: "File not found")
            case .ambiguousGroup(let name): String(localized: "More than one group is named \(name). Rename the groups before importing this CSV.")
            }
        }
    }
}
