import Foundation
import GRDB
import SwiftUI
import Testing
@testable import Termi

// What a host runs: reading the probe's answer, the stored id, the tile lookup, and the columns
// that hold it (migration, targeted update, a save of the host that must leave them alone).

/// The probe's answer for an os-release file and a `uname -sm` line.
private func answer(_ release: String, _ uname: String = "Linux x86_64") -> String {
    release + "\n---\n" + uname + "\n"
}

// MARK: - Parser

@Test func parsesUbuntu() {
    let system = HostSystem.parse(probeOutput: answer("""
        PRETTY_NAME="Ubuntu 24.04.1 LTS"
        NAME="Ubuntu"
        VERSION_ID="24.04"
        VERSION="24.04.1 LTS (Noble Numbat)"
        VERSION_CODENAME=noble
        ID=ubuntu
        ID_LIKE=debian
        HOME_URL="https://www.ubuntu.com/"
        UBUNTU_CODENAME=noble
        LOGO=ubuntu-logo
        """, "Linux aarch64"))
    #expect(system == HostSystem(id: "ubuntu", name: "Ubuntu 24.04.1 LTS", arch: "aarch64"))
}

@Test func parsesDebian() {
    let system = HostSystem.parse(probeOutput: answer("""
        PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
        NAME="Debian GNU/Linux"
        VERSION_ID="12"
        VERSION="12 (bookworm)"
        VERSION_CODENAME=bookworm
        ID=debian
        """))
    #expect(system == HostSystem(id: "debian", name: "Debian GNU/Linux 12 (bookworm)", arch: "x86_64"))
}

@Test func parsesTheRedHatFamily() {
    let rocky = HostSystem.parse(probeOutput: answer("""
        NAME="Rocky Linux"
        VERSION="9.4 (Blue Onyx)"
        ID="rocky"
        ID_LIKE="rhel centos fedora"
        PLATFORM_ID="platform:el9"
        PRETTY_NAME="Rocky Linux 9.4 (Blue Onyx)"
        """))
    #expect(rocky == HostSystem(id: "rocky", name: "Rocky Linux 9.4 (Blue Onyx)", arch: "x86_64"))

    let centos = HostSystem.parse(probeOutput: answer("""
        NAME="CentOS Linux"
        VERSION="7 (Core)"
        ID="centos"
        ID_LIKE="rhel fedora"
        VERSION_ID="7"
        PRETTY_NAME="CentOS Linux 7 (Core)"
        ANSI_COLOR="0;31"
        """))
    #expect(centos == HostSystem(id: "centos", name: "CentOS Linux 7 (Core)", arch: "x86_64"))

    let alma = HostSystem.parse(probeOutput: answer("""
        NAME="AlmaLinux"
        VERSION="9.3 (Shamrock Pampas Cat)"
        ID="almalinux"
        ID_LIKE="rhel centos fedora"
        VERSION_ID="9.3"
        PRETTY_NAME="AlmaLinux 9.3 (Shamrock Pampas Cat)"
        """))
    #expect(alma?.id == "almalinux")
    #expect(alma?.name == "AlmaLinux 9.3 (Shamrock Pampas Cat)")
}

@Test func parsesDistributionsWithoutAMarkOfTheirOwn() {
    let kylin = HostSystem.parse(probeOutput: answer("""
        NAME="Kylin Linux Advanced Server"
        VERSION="V10 (Halberd)"
        ID="kylin"
        VERSION_ID="V10"
        PRETTY_NAME="Kylin Linux Advanced Server V10 (Halberd)"
        ANSI_COLOR="0;31"
        """))
    #expect(kylin == HostSystem(id: "kylin", name: "Kylin Linux Advanced Server V10 (Halberd)", arch: "x86_64"))

    let euler = HostSystem.parse(probeOutput: answer("""
        NAME="openEuler"
        VERSION="22.03 (LTS-SP3)"
        ID="openEuler"
        VERSION_ID="22.03"
        PRETTY_NAME="openEuler 22.03 (LTS-SP3)"
        ANSI_COLOR="0;31"
        """, "Linux aarch64"))
    #expect(euler == HostSystem(id: "openeuler", name: "openEuler 22.03 (LTS-SP3)", arch: "aarch64"))

    // A distribution the app has no id for is a Linux; it keeps its own name.
    let anolis = HostSystem.parse(probeOutput: answer("""
        NAME="Anolis OS"
        ID="anolis"
        ID_LIKE="rhel fedora centos"
        VERSION_ID="8.9"
        PRETTY_NAME="Anolis OS 8.9"
        """))
    #expect(anolis == HostSystem(id: "linux", name: "Anolis OS 8.9", arch: "x86_64"))
}

@Test func parsesAlpineArchAndAmazon() {
    let alpine = HostSystem.parse(probeOutput: answer("""
        NAME="Alpine Linux"
        ID=alpine
        VERSION_ID=3.19.1
        PRETTY_NAME="Alpine Linux v3.19"
        HOME_URL="https://alpinelinux.org/"
        """))
    #expect(alpine == HostSystem(id: "alpine", name: "Alpine Linux v3.19", arch: "x86_64"))

    // Arch is a rolling release: no VERSION_ID.
    let arch = HostSystem.parse(probeOutput: answer("""
        NAME="Arch Linux"
        PRETTY_NAME="Arch Linux"
        ID=arch
        BUILD_ID=rolling
        """))
    #expect(arch == HostSystem(id: "arch", name: "Arch Linux", arch: "x86_64"))

    let amazon = HostSystem.parse(probeOutput: answer("""
        NAME="Amazon Linux"
        VERSION="2023"
        ID="amzn"
        ID_LIKE="fedora"
        VERSION_ID="2023"
        PRETTY_NAME="Amazon Linux 2023.4.20240319"
        """, "Linux aarch64"))
    #expect(amazon == HostSystem(id: "amzn", name: "Amazon Linux 2023.4.20240319", arch: "aarch64"))
}

@Test func parsesAFileWithQuotesCommentsAndBlankLines() {
    let text = "# This file describes the system\r\n\r\n  NAME='Debian GNU/Linux'  \r\nVERSION_ID=\"11\"\r\n\r\n"
        + "ID=debian\r\nnot an assignment\r\nlower=ignored\r\n=nokey\r\nBUG_REPORT_URL=\"https://bugs.debian.org/?a=b\"\r\n"
    let values = HostSystem.osRelease(text.replacingOccurrences(of: "\r", with: "")
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    #expect(values == ["NAME": "Debian GNU/Linux", "VERSION_ID": "11", "ID": "debian",
                       "BUG_REPORT_URL": "https://bugs.debian.org/?a=b"])

    // Without PRETTY_NAME the name is NAME and VERSION_ID.
    let system = HostSystem.parse(probeOutput: text + "---\r\nLinux armv7l\r\n")
    #expect(system == HostSystem(id: "debian", name: "Debian GNU/Linux 11", arch: "armv7l"))
}

@Test func parsesSystemsWithoutAnOsReleaseFile() {
    #expect(HostSystem.parse(probeOutput: "---\nDarwin arm64\n")
            == HostSystem(id: "darwin", name: "macOS", arch: "arm64"))
    #expect(HostSystem.parse(probeOutput: "---\nFreeBSD amd64\n")
            == HostSystem(id: "freebsd", name: "FreeBSD", arch: "amd64"))
    #expect(HostSystem.parse(probeOutput: "---\nOpenBSD amd64\n")?.id == "openbsd")
    #expect(HostSystem.parse(probeOutput: "\n---\nLinux mips\n")
            == HostSystem(id: "linux", name: "Linux", arch: "mips"))
    #expect(HostSystem.parse(probeOutput: "---\nMINGW64_NT-10.0-20348 x86_64\n")?.id == "windows")
    // A shell that greets before the answer: the last line counts.
    #expect(HostSystem.parse(probeOutput: "Welcome\n---\nhello\nLinux riscv64\n")?.arch == "riscv64")
}

@Test func parsesTheWindowsVersionLine() {
    #expect(HostSystem.parse(windowsVersion: "\r\nMicrosoft Windows [Version 10.0.20348.2402]\r\n")
            == HostSystem(id: "windows", name: "Windows 10.0.20348.2402", arch: nil))
    #expect(HostSystem.parse(windowsVersion: "Microsoft Windows [版本 6.3.9600]")?.name == "Windows 6.3.9600")
    #expect(HostSystem.parse(windowsVersion: "Microsoft Windows") == HostSystem(id: "windows", name: "Windows", arch: nil))
    #expect(HostSystem.parse(windowsVersion: "sh: cmd: command not found") == nil)
    #expect(HostSystem.parse(windowsVersion: "") == nil)
}

@Test func garbageIsNotASystem() {
    #expect(HostSystem.parse(probeOutput: "") == nil)
    #expect(HostSystem.parse(probeOutput: "---\n") == nil)
    #expect(HostSystem.parse(probeOutput: "---\n\n") == nil)
    // No separator: the command did not run as written.
    #expect(HostSystem.parse(probeOutput: "ID=ubuntu\nLinux x86_64\n") == nil)
    #expect(HostSystem.parse(probeOutput: "'sh' is not recognized as an internal or external command,\n") == nil)
    #expect(HostSystem.parse(probeOutput: "---\nThis account is currently not available.\n") == nil)
    #expect(HostSystem.parse(probeOutput: "---\nSunOS sun4v\n") == nil)
    #expect(HostSystem.parse(probeOutput: "\u{1B}[0m\u{0}\u{7}---x\nrandom bytes here and there\n") == nil)
}

// MARK: - Ids and lookup

@Test func idsAreNormalised() {
    #expect(HostSystem.normalizedID("ubuntu") == "ubuntu")
    #expect(HostSystem.normalizedID(" openEuler ") == "openeuler")
    #expect(HostSystem.normalizedID("opensuse-leap") == "opensuse")
    #expect(HostSystem.normalizedID("opensuse-tumbleweed") == "opensuse")
    #expect(HostSystem.normalizedID("sles_sap") == "sles")
    #expect(HostSystem.normalizedID("RHEL") == "rhel")
    #expect(HostSystem.normalizedID("archarm") == "arch")
    #expect(HostSystem.normalizedID("uniontech") == "uos")
    #expect(HostSystem.normalizedID("amzn") == "amzn")
    #expect(HostSystem.normalizedID("immortalwrt") == "openwrt")
    #expect(HostSystem.normalizedID("pop") == "linux")
    #expect(HostSystem.normalizedID("") == "linux")
    for id in HostSystem.ids {
        #expect(HostSystem.normalizedID(id) == id)
    }
}

@Test func everyIdHasATile() {
    #expect(Set(HostSystem.ids).count == HostSystem.ids.count)
    for id in HostSystem.ids {
        let system = DSOperatingSystem.resolve(id)
        #expect(system.id == id)
        #expect(!system.name.isEmpty)
        #expect(system != .unknown)
    }
    #expect(DSOperatingSystem.resolve("ubuntu").mark == .asset("OS/ubuntu"))
    #expect(DSOperatingSystem.resolve("rhel").mark == .asset("OS/redhat"))
    #expect(DSOperatingSystem.resolve("darwin").mark == .asset("OS/apple"))
    #expect(DSOperatingSystem.resolve("windows").mark == .asset("OS/windows"))
    // No mark of their own: the Linux mark on the Linux tile.
    for id in ["kylin", "openeuler", "uos", "synology", "linux"] {
        #expect(DSOperatingSystem.resolve(id).mark == .asset("OS/linux"))
        #expect(DSOperatingSystem.resolve(id).color == DSOperatingSystem.linux.color)
    }
    #expect(DSOperatingSystem.resolve(nil) == .unknown)
    #expect(DSOperatingSystem.resolve("plan9") == .unknown)
}

@Test @MainActor func everyMarkIsInTheAssetCatalog() {
    for id in HostSystem.ids {
        guard case .asset(let name) = DSOperatingSystem.resolve(id).mark else {
            Issue.record("\(id) has no mark")
            continue
        }
        if NSImage(named: name) == nil {
            Issue.record("\(name) is missing from the asset catalog")
        }
    }
}

@Test func hostTileShowsTheDetectedSystem() {
    var host = Termi.Host.defaultValue()
    #expect(host.system == nil)
    #expect(host.systemDescription == nil)
    #expect(host.operatingSystem == .unknown)

    host.osId = "ubuntu"
    host.osName = "Ubuntu 24.04.1 LTS"
    host.osArch = "aarch64"
    #expect(host.systemDescription == "Ubuntu 24.04.1 LTS · aarch64")
    #expect(host.tileContent == .asset("OS/ubuntu"))
    #expect(host.tint == DSOperatingSystem.resolve("ubuntu").color)

    // A colour chosen for the host still wins; the mark stays.
    host.color = "#3b82f6"
    #expect(host.tint == Color.blue)
    #expect(host.tileContent == .asset("OS/ubuntu"))

    host.osArch = nil
    #expect(host.systemDescription == "Ubuntu 24.04.1 LTS")
}

@Test func oldExportsDecodeWithoutASystem() throws {
    let old = #"{"label":"web","hostname":"web.example","port":22,"username":"root","auth_type":"agent"}"#
    let host = try JSONDecoder().decode(Termi.Host.self, from: Data(old.utf8))
    #expect(host.osId == nil && host.osName == nil && host.osArch == nil && host.osDetectedAt == nil)

    var detected = host
    detected.osId = "debian"
    detected.osName = "Debian GNU/Linux 12 (bookworm)"
    detected.osArch = "x86_64"
    detected.osDetectedAt = "2026-10-05T00:00:00Z"
    let again = try JSONDecoder().decode(Termi.Host.self, from: JSONEncoder().encode(detected))
    #expect(again.system == HostSystem(id: "debian", name: "Debian GNU/Linux 12 (bookworm)", arch: "x86_64"))
    #expect(again.osDetectedAt == "2026-10-05T00:00:00Z")
}

@Test func aStoredSystemIsReadAgainAfterAWeek() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(HostSystemProbe.isDue(detectedAt: nil, now: now))
    #expect(!HostSystemProbe.isDue(detectedAt: now.addingTimeInterval(-3600), now: now))
    #expect(!HostSystemProbe.isDue(detectedAt: now.addingTimeInterval(-6 * 86_400), now: now))
    #expect(HostSystemProbe.isDue(detectedAt: now.addingTimeInterval(-7 * 86_400), now: now))
    #expect(HostSystemProbe.isDue(detectedAt: now.addingTimeInterval(3600), now: now))
}

// MARK: - Database

private func makePool() throws -> (pool: DatabasePool, folder: URL) {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (try DatabasePool(path: folder.appendingPathComponent("scratch.db").path), folder)
}

/// Close before deleting: SQLite reports files that are unlinked while still open.
private func discard(_ scratch: (pool: DatabasePool, folder: URL)) {
    try? scratch.pool.close()
    try? FileManager.default.removeItem(at: scratch.folder)
}

@Test func migrationAddsTheSystemColumnsAndKeepsHosts() async throws {
    let scratch = try makePool()
    defer { discard(scratch) }

    // A database as the previous version left it, with a host in it.
    try Migrations.migrator.migrate(scratch.pool, upTo: "v7_key_types")
    let columnsBefore = try await scratch.pool.read { db in try db.columns(in: "hosts").map(\.name) }
    #expect(!columnsBefore.contains("os_id"))
    try await scratch.pool.write { db in
        try db.execute(sql: """
            INSERT INTO hosts (label, hostname, port, username, auth_type, color, notes, agent_forwarding,
                               terminal_theme, last_connected_at)
            VALUES ('builder', '192.168.55.42', 2222, 'ops', 'agent', '#EF4444', 'packaging', 1,
                    'nord', '2026-10-01T08:00:00Z')
            """)
    }

    try Migrations.run(scratch.pool)

    let host = try await scratch.pool.read { db in try Termi.Host.fetchOne(db) }
    let upgraded = try #require(host)
    #expect(upgraded.label == "builder")
    #expect(upgraded.hostname == "192.168.55.42")
    #expect(upgraded.port == 2222)
    #expect(upgraded.username == "ops")
    #expect(upgraded.authType == "agent")
    #expect(upgraded.color == "#EF4444")
    #expect(upgraded.notes == "packaging")
    #expect(upgraded.agentForwarding)
    #expect(upgraded.terminalTheme == "nord")
    #expect(upgraded.lastConnectedAt == "2026-10-01T08:00:00Z")
    #expect(upgraded.system == nil)
    #expect(upgraded.osDetectedAt == nil)
    let columns = try await scratch.pool.read { db in try db.columns(in: "hosts").map(\.name) }
    #expect(Termi.Host.systemColumns.isSubset(of: Set(columns)))
}

@Test func storingTheSystemTouchesNothingElse() async throws {
    let scratch = try makePool()
    defer { discard(scratch) }
    try Migrations.run(scratch.pool)

    let ubuntu = HostSystem(id: "ubuntu", name: "Ubuntu 24.04.1 LTS", arch: "aarch64")
    let (before, after, other) = try await scratch.pool.write { db -> (Termi.Host, Termi.Host?, Termi.Host?) in
        var host = Termi.Host.defaultValue()
        host.label = "web"
        host.hostname = "web.example"
        host.notes = "front"
        host.color = "#10B981"
        host.lastConnectedAt = "2026-10-01T08:00:00Z"
        let saved = try HostRepository.save(host, db)
        var second = Termi.Host.defaultValue()
        second.label = "db"
        second.hostname = "db.example"
        let neighbour = try HostRepository.save(second, db)

        try HostRepository.writeSystem(ubuntu, detectedAt: "2026-10-05T00:00:00Z", id: saved.id ?? -1, db)
        return (saved, try Termi.Host.fetchOne(db, key: saved.id), try Termi.Host.fetchOne(db, key: neighbour.id))
    }

    var expected = before
    expected.osId = "ubuntu"
    expected.osName = "Ubuntu 24.04.1 LTS"
    expected.osArch = "aarch64"
    expected.osDetectedAt = "2026-10-05T00:00:00Z"
    #expect(after == expected)
    #expect(other?.system == nil)
}

@Test func savingAHostKeepsTheSystemItDidNotRead() async throws {
    let scratch = try makePool()
    defer { discard(scratch) }
    try Migrations.run(scratch.pool)

    let rocky = HostSystem(id: "rocky", name: "Rocky Linux 9.4 (Blue Onyx)", arch: "x86_64")
    let (edited, moved) = try await scratch.pool.write { db -> (Termi.Host, Termi.Host) in
        var host = Termi.Host.defaultValue()
        host.label = "web"
        host.hostname = "web.example"
        // The form's copy: read before the system was stored.
        var stale = try HostRepository.save(host, db)
        try HostRepository.writeSystem(rocky, detectedAt: "2026-10-05T00:00:00Z", id: stale.id ?? -1, db)

        stale.label = "web-01"
        stale.notes = "renamed"
        let edited = try HostRepository.save(stale, db)

        // Pointed at another machine: what was read no longer describes it.
        var other = edited
        other.hostname = "other.example"
        return (edited, try HostRepository.save(other, db))
    }

    #expect(edited.label == "web-01")
    #expect(edited.notes == "renamed")
    #expect(edited.system == rocky)
    #expect(edited.osDetectedAt == "2026-10-05T00:00:00Z")
    #expect(moved.hostname == "other.example")
    #expect(moved.system == nil)
    #expect(moved.osDetectedAt == nil)
}

@Test func aSystemReadFromTheOldAddressIsNotStoredAfterTheHostMoved() async throws {
    let scratch = try makePool()
    defer { discard(scratch) }
    try Migrations.run(scratch.pool)

    let debian = HostSystem(id: "debian", name: "Debian GNU/Linux 12 (bookworm)", arch: "x86_64")
    let (refused, moved, stored, kept) = try await scratch.pool.write { db -> (Bool, Termi.Host?, Bool, Termi.Host?) in
        var host = Termi.Host.defaultValue()
        host.label = "web"
        host.hostname = "web.example"
        host.port = 22
        var saved = try HostRepository.save(host, db)
        let id = saved.id ?? -1
        // The probe connected to web.example:22; the host is edited before the answer arrives.
        saved.hostname = "other.example"
        saved = try HostRepository.save(saved, db)
        let refused = try HostRepository.writeSystem(debian, detectedAt: "2026-10-05T00:00:00Z", id: id,
                                                     at: ("web.example", 22), db)
        let moved = try Termi.Host.fetchOne(db, key: id)
        // Read from the address the host has now: stored.
        let stored = try HostRepository.writeSystem(debian, detectedAt: "2026-10-05T00:00:00Z", id: id,
                                                    at: ("other.example", 22), db)
        return (refused, moved, stored, try Termi.Host.fetchOne(db, key: id))
    }

    #expect(!refused)
    #expect(moved?.system == nil)
    #expect(stored)
    #expect(kept?.system == debian)
}

@Test func theProbeIsOneCommand() {
    // One line, one exec request: the Windows answer is the same line's fallback, not a second command.
    #expect(!HostSystemProbe.command.contains("\n"))
    #expect(HostSystemProbe.command.hasPrefix("sh -c '"))
    let windows = "\r\nMicrosoft Windows [版本 10.0.20348.2402]\r\n"
    #expect(HostSystemProbe.parse(windows) == HostSystem(id: "windows", name: "Windows 10.0.20348.2402", arch: nil))
    #expect(HostSystemProbe.parse("Linux says hello") == nil)
    #expect(HostSystemProbe.parse("ID=alpine\n---\nLinux aarch64\n")?.id == "alpine")
}
