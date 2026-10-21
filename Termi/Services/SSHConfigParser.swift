import Foundation

/// One concrete host from an OpenSSH client config, with `Host *` / pattern defaults applied
/// the way ssh applies them (first value wins; IdentityFile and forwards accumulate).
struct SSHConfigEntry: Equatable, Sendable {
    var alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFiles: [String] = []
    var proxyJump: String?
    var forwardAgent: Bool?
    var forwardX11: Bool?
    var localForwards: [SSHForward] = []
    var remoteForwards: [SSHForward] = []
    var dynamicForwards: [Int] = []

    /// HostName with `%h` expanded (defaults to the alias, like ssh).
    var resolvedHostName: String {
        guard let hostName else { return alias }
        return hostName.replacingOccurrences(of: "%h", with: alias).replacingOccurrences(of: "%%", with: "%")
    }
}

enum SSHConfigParser {
    private struct Block {
        var patterns: [String]
        /// Match blocks are not evaluated (they can run commands); their options are ignored.
        var isMatch: Bool
        var options: [(key: String, value: String)] = []
    }

    /// Parse config text. `readFile` resolves `Include` targets (already expanded to absolute paths).
    static func parse(_ text: String,
                      homeDirectory: String = NSHomeDirectory(),
                      localUser: String = NSUserName(),
                      readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> [SSHConfigEntry] {
        var blocks = [Block(patterns: ["*"], isMatch: false)]
        collect(text, into: &blocks, homeDirectory: homeDirectory, readFile: readFile, depth: 0)

        var aliases: [String] = []
        var seen = Set<String>()
        for block in blocks where !block.isMatch {
            for pattern in block.patterns
            where !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") {
                if seen.insert(pattern).inserted {
                    aliases.append(pattern)
                }
            }
        }

        return aliases.map { alias in
            var entry = SSHConfigEntry(alias: alias)
            var assigned = Set<String>()
            for block in blocks where !block.isMatch && matches(alias, patterns: block.patterns) {
                for (key, value) in block.options {
                    apply(key: key, value: value, to: &entry, assigned: &assigned,
                          homeDirectory: homeDirectory, localUser: localUser)
                }
            }
            return entry
        }
    }

    // MARK: - Tokenizing

    private static func collect(_ text: String, into blocks: inout [Block], homeDirectory: String,
                                readFile: (String) -> String?, depth: Int) {
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let words = tokenize(String(rawLine))
            guard let first = words.first else { continue }
            let key = first.lowercased()
            let arguments = Array(words.dropFirst())

            switch key {
            case "host":
                blocks.append(Block(patterns: arguments, isMatch: false))
            case "match":
                blocks.append(Block(patterns: [], isMatch: true))
            case "include":
                guard depth < 8 else { continue }
                for argument in arguments {
                    for path in expandInclude(argument, homeDirectory: homeDirectory) {
                        if let included = readFile(path) {
                            collect(included, into: &blocks, homeDirectory: homeDirectory,
                                    readFile: readFile, depth: depth + 1)
                        }
                    }
                }
            default:
                guard !arguments.isEmpty else { continue }
                blocks[blocks.count - 1].options.append((key, arguments.joined(separator: " ")))
            }
        }
    }

    /// Split a config line into words: `Key Value`, `Key=Value`, double quotes, `#` comments.
    static func tokenize(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for character in line {
            if inQuotes {
                if character == "\"" {
                    inQuotes = false
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "#" && !hasToken && current.isEmpty {
                break
            }
            if character == "\"" {
                inQuotes = true
                hasToken = true
            } else if character == " " || character == "\t" || (character == "=" && words.isEmpty) {
                if !current.isEmpty || hasToken {
                    words.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if !current.isEmpty || hasToken {
            words.append(current)
        }
        // "Key = Value" / "Key =Value": drop the separator.
        if words.count >= 2, words[1].hasPrefix("=") {
            words[1].removeFirst()
            if words[1].isEmpty {
                words.remove(at: 1)
            }
        }
        return words
    }

    private static func expandInclude(_ argument: String, homeDirectory: String) -> [String] {
        var path = argument
        if path.hasPrefix("~/") {
            path = homeDirectory + String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            path = homeDirectory + "/.ssh/" + path
        }
        guard path.contains("*") || path.contains("?") else { return [path] }

        // Glob in the last path component only (the common "config.d/*" case).
        let directory = (path as NSString).deletingLastPathComponent
        let pattern = (path as NSString).lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { wildcardMatch(pattern, $0) }.sorted().map { directory + "/" + $0 }
    }

    // MARK: - Matching

    private static func matches(_ alias: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if wildcardMatch(String(pattern.dropFirst()), alias) { return false }
            } else if wildcardMatch(pattern, alias) {
                matched = true
            }
        }
        return matched
    }

    /// ssh_config wildcard match: `*` any run of characters, `?` one character (case-insensitive).
    static func wildcardMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())
        var pi = 0, ti = 0
        var starIndex = -1, starMatch = 0
        while ti < t.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) {
                pi += 1
                ti += 1
            } else if pi < p.count && p[pi] == "*" {
                starIndex = pi
                starMatch = ti
                pi += 1
            } else if starIndex >= 0 {
                pi = starIndex + 1
                starMatch += 1
                ti = starMatch
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: - Options

    private static func apply(key: String, value: String, to entry: inout SSHConfigEntry,
                              assigned: inout Set<String>, homeDirectory: String, localUser: String) {
        // Accumulating options.
        switch key {
        case "identityfile":
            if value.lowercased() != "none" {
                entry.identityFiles.append(expandPath(value, homeDirectory: homeDirectory,
                                                      alias: entry.alias, user: entry.user ?? localUser))
            }
            return
        case "localforward":
            if let forward = parseForward(value, kind: .local) { entry.localForwards.append(forward) }
            return
        case "remoteforward":
            if let forward = parseForward(value, kind: .remote) { entry.remoteForwards.append(forward) }
            return
        case "dynamicforward":
            if let port = Int(value.split(separator: ":").last ?? "") { entry.dynamicForwards.append(port) }
            return
        default:
            break
        }

        // First obtained value wins.
        guard assigned.insert(key).inserted else { return }
        switch key {
        case "hostname": entry.hostName = value
        case "user": entry.user = value
        case "port": entry.port = Int(value)
        case "proxyjump": entry.proxyJump = value.lowercased() == "none" ? nil : value
        case "forwardagent": entry.forwardAgent = value.lowercased() == "yes"
        case "forwardx11": entry.forwardX11 = value.lowercased() == "yes"
        default: break
        }
    }

    private static func expandPath(_ value: String, homeDirectory: String, alias: String, user: String) -> String {
        var path = value
        if path.hasPrefix("~/") {
            path = homeDirectory + String(path.dropFirst(1))
        } else if path == "~" {
            path = homeDirectory
        }
        path = path.replacingOccurrences(of: "%d", with: homeDirectory)
            .replacingOccurrences(of: "%u", with: user)
            .replacingOccurrences(of: "%r", with: user)
            .replacingOccurrences(of: "%h", with: alias)
            .replacingOccurrences(of: "%%", with: "%")
        if !path.hasPrefix("/") {
            path = homeDirectory + "/" + path
        }
        return path
    }

    /// "[bind_address:]port host:hostport" (also "port host hostport" is not valid; keep it simple).
    private static func parseForward(_ value: String, kind: SSHForward.Kind) -> SSHForward? {
        let parts = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2,
              let bindPort = Int(parts[0].split(separator: ":").last ?? "") else { return nil }
        let destination = parts[1]
        guard let colon = destination.lastIndex(of: ":"),
              let destinationPort = Int(destination[destination.index(after: colon)...]) else { return nil }
        var host = String(destination[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return SSHForward(kind: kind, bindPort: bindPort, destinationHost: host, destinationPort: destinationPort)
    }

    /// Split a ProxyJump value into hops: "user@host:port,other" → [(user, host, port)].
    static func proxyJumpHops(_ value: String) -> [(user: String?, host: String, port: Int?)] {
        value.split(separator: ",").compactMap { rawHop in
            var hop = String(rawHop).trimmingCharacters(in: .whitespaces)
            if hop.hasPrefix("ssh://") { hop.removeFirst(6) }
            var user: String?
            if let at = hop.lastIndex(of: "@") {
                user = String(hop[..<at])
                hop = String(hop[hop.index(after: at)...])
            }
            var port: Int?
            if hop.hasPrefix("["), let close = hop.firstIndex(of: "]") {
                let host = String(hop[hop.index(after: hop.startIndex)..<close])
                let rest = hop[hop.index(after: close)...]
                if rest.hasPrefix(":") { port = Int(rest.dropFirst()) }
                return host.isEmpty ? nil : (user, host, port)
            }
            if hop.filter({ $0 == ":" }).count == 1, let colon = hop.lastIndex(of: ":") {
                port = Int(hop[hop.index(after: colon)...])
                hop = String(hop[..<colon])
            }
            return hop.isEmpty ? nil : (user, hop, port)
        }
    }
}
