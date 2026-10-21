import Foundation

/// What a host runs, as read from it after connecting: stored on the host and shown on its tile.
struct HostSystem: Equatable, Sendable {
    /// Normalised id: one of `HostSystem.ids`.
    var id: String
    /// As the system names itself ("Ubuntu 24.04.1 LTS").
    var name: String
    /// Machine architecture as `uname -m` prints it ("aarch64"); nil when it was not read.
    var arch: String?

    /// Every id a host can be stored with. "linux" stands for any Linux that has no id of its own.
    static let ids: [String] = [
        "ubuntu", "debian", "centos", "rhel", "rocky", "almalinux", "fedora", "opensuse", "sles",
        "arch", "alpine", "kylin", "openeuler", "uos", "deepin", "amzn", "ol", "kali", "linuxmint",
        "manjaro", "gentoo", "nixos", "raspbian", "openwrt", "proxmox", "truenas", "synology",
        "freebsd", "openbsd", "netbsd", "darwin", "windows", "linux"
    ]

    /// Spellings of `ID=` in /etc/os-release that mean one of `ids`.
    private static let aliases: [String: String] = [
        "redhat": "rhel", "redhatenterpriseserver": "rhel",
        "opensuse-leap": "opensuse", "opensuse-tumbleweed": "opensuse", "opensuse-microos": "opensuse",
        "opensuse-leap-micro": "opensuse", "opensuse-slowroll": "opensuse",
        "sled": "sles", "sles_sap": "sles", "sle-micro": "sles", "sle_hpc": "sles", "suse": "sles",
        "archlinux": "arch", "archarm": "arch",
        "neokylin": "kylin", "uniontech": "uos",
        "amazon": "amzn", "oracle": "ol", "oraclelinux": "ol",
        "manjaro-arm": "manjaro", "mint": "linuxmint",
        "immortalwrt": "openwrt", "lede": "openwrt",
        "pve": "proxmox", "truenas-scale": "truenas", "dsm": "synology",
        "macos": "darwin"
    ]

    /// The stored id for an `ID=` value of /etc/os-release ("openEuler" → "openeuler",
    /// "opensuse-leap" → "opensuse"); "linux" for a distribution the app has no id for.
    static func normalizedID(_ raw: String) -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ids.contains(id) { return id }
        return aliases[id] ?? "linux"
    }

    // MARK: - Parsing

    /// The line the probe prints between the os-release file and the `uname` answer.
    static let separator = "---"

    /// Reads the answer to `cat /etc/os-release; echo ---; uname -sm`. Nil when neither part
    /// says what the host is (Windows without a POSIX shell, an appliance, a shell that prints
    /// something else).
    static func parse(probeOutput: String) -> HostSystem? {
        let lines = probeOutput
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Without the separator the command did not run as written: whatever came back (a
        // banner, an error text) is not an answer.
        guard let split = lines.lastIndex(of: separator) else { return nil }
        let release = osRelease(lines[..<split])
        let kernel = unameFields(lines[(split + 1)...])

        // A file without ID (it is optional) is named by the first word of NAME.
        let firstWordOfName = (release["NAME"] ?? "").split(separator: " ").first.map { String($0) }
        if let rawID = release["ID"] ?? firstWordOfName, !rawID.isEmpty {
            let id = normalizedID(rawID)
            return HostSystem(id: id, name: displayName(from: release) ?? fallbackName(for: id),
                              arch: kernel?.machine)
        }
        guard let kernel else { return nil }
        let system = kernel.system.lowercased()
        let id: String
        switch system {
        case "linux": id = "linux"
        case "darwin": id = "darwin"
        case "freebsd", "openbsd", "netbsd": id = system
        default:
            // A POSIX layer on Windows names itself after the kernel it sits on.
            guard ["mingw", "msys", "cygwin"].contains(where: { system.hasPrefix($0) }) else { return nil }
            id = "windows"
        }
        return HostSystem(id: id, name: fallbackName(for: id), arch: kernel.machine)
    }

    /// Reads the answer of Windows' `ver` ("Microsoft Windows [Version 10.0.20348.2402]"; the
    /// word in the brackets is localised).
    static func parse(windowsVersion output: String) -> HostSystem? {
        // By `isNewline`: "\r\n" is one Character, equal to neither "\r" nor "\n".
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Microsoft Windows") else { continue }
            let version = line.split(whereSeparator: { !$0.isNumber && $0 != "." })
                .first(where: { $0.contains(".") })
            return HostSystem(id: "windows", name: version.map { "Windows \($0)" } ?? "Windows", arch: nil)
        }
        return nil
    }

    /// The `KEY=value` lines of an os-release file: quotes removed, comments and anything that
    /// is not an assignment skipped.
    static func osRelease<Lines: Sequence>(_ lines: Lines) -> [String: String] where Lines.Element == String {
        var values: [String: String] = [:]
        for line in lines {
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }) else {
                continue
            }
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return values
    }

    /// "Linux aarch64" → ("Linux", "aarch64"). The last line that looks like it counts: a shell
    /// may print something of its own first.
    private static func unameFields<Lines: Sequence>(_ lines: Lines) -> (system: String, machine: String?)?
    where Lines.Element == String {
        var found: (system: String, machine: String?)?
        for line in lines {
            let words = line.split(separator: " ")
            guard (1...2).contains(words.count) else { continue }
            found = (String(words[0]), words.count == 2 ? String(words[1]) : nil)
        }
        return found
    }

    private static func displayName(from release: [String: String]) -> String? {
        if let pretty = release["PRETTY_NAME"], !pretty.isEmpty { return pretty }
        guard let name = release["NAME"], !name.isEmpty else { return nil }
        if let version = release["VERSION_ID"], !version.isEmpty { return "\(name) \(version)" }
        return name
    }

    private static func fallbackName(for id: String) -> String {
        switch id {
        case "darwin": return "macOS"
        case "freebsd": return "FreeBSD"
        case "openbsd": return "OpenBSD"
        case "netbsd": return "NetBSD"
        case "windows": return "Windows"
        default: return "Linux"
        }
    }
}

extension Host {
    /// Columns that belong to the system probe, not to the host's form: a save of the host
    /// leaves them alone (see `HostRepository.save` and `setSystem`).
    static let systemColumns: Set<String> = ["os_id", "os_name", "os_arch", "os_detected_at"]

    /// What was read from the host after it connected; nil until then.
    var system: HostSystem? {
        guard let osId, !osId.isEmpty else { return nil }
        return HostSystem(id: osId, name: osName ?? "", arch: osArch)
    }

    /// "Ubuntu 24.04.1 LTS · aarch64" for the host's detail; nil while the system is not known.
    var systemDescription: String? {
        guard let system else { return nil }
        let parts = [system.name, system.arch ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var systemDetectedDate: Date? {
        osDetectedAt.flatMap { TimestampFormatter.date(from: $0) }
    }
}
