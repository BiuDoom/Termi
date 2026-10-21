import Foundation
import os.log

/// Reads what a saved host runs — its distribution, version and architecture — once it has
/// connected, so its tile can carry that system's mark.
///
/// ONE read-only command over the connection that is already open (a mux client of the master:
/// no new authentication, no prompt), at most once per host per app run and not again while the
/// stored answer is younger than a week. Nothing waits for it, and a host that does not answer
/// simply keeps the generic tile.
actor HostSystemProbe {
    static let shared = HostSystemProbe()

    /// The one command. POSIX sh runs the quoted part whatever the login shell is (csh and fish
    /// read `2>/dev/null` differently). Where there is no `sh` — Windows OpenSSH, whose default
    /// shell is cmd.exe or PowerShell 7 — the first half fails and the same line falls through
    /// to `ver` (a cmd builtin), in UTF-8 so that a localised answer can be read.
    static let command = "sh -c 'cat /etc/os-release 2>/dev/null; echo ---; uname -sm 2>/dev/null'"
        + " || cmd /c \"chcp 65001 >nul & ver\""
    /// UserDefaults key of the setting; on unless switched off.
    static let settingKey = "detectHostSystem"
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "HostSystemProbe")
    /// Hosts looked at in this run of the app, whatever came of it.
    private var attempted = Set<Int64>()

    static var isEnabled: Bool {
        AppProfile.defaults.object(forKey: settingKey) as? Bool ?? true
    }

    /// Whether a system read at `detectedAt` is due to be read again.
    static func isDue(detectedAt: Date?, now: Date = Date()) -> Bool {
        guard let detectedAt else { return true }
        // A date in the future (the clock was set back) does not postpone the next read.
        return now.timeIntervalSince(detectedAt) >= maximumAge || detectedAt > now
    }

    /// What the answer to `command` says: the POSIX half's, otherwise the Windows half's.
    static func parse(_ output: String) -> HostSystem? {
        HostSystem.parse(probeOutput: output) ?? HostSystem.parse(windowsVersion: output)
    }

    /// The saved host `id` has a live master connection to `hostname:port`. Returns at once;
    /// the read happens in the background and never fails the connection.
    nonisolated func hostConnected(id: Int64, hostname: String, port: Int, master: SSHMasterConnection) {
        Task(priority: .utility) {
            await self.probe(hostId: id, hostname: hostname, port: port, master: master)
        }
    }

    private func probe(hostId: Int64, hostname: String, port: Int, master: SSHMasterConnection) async {
        guard Self.isEnabled, attempted.insert(hostId).inserted else { return }
        do {
            // Edited to point elsewhere since it connected: this connection is not that machine.
            guard let host = try await HostRepository.shared.fetch(id: hostId),
                  host.hostname == hostname, host.port == port,
                  Self.isDue(detectedAt: host.systemDetectedDate) else { return }
            let answer = try await master.run(Self.command)
            guard let system = Self.parse(answer.stdout) else {
                logger.debug("Host \(hostId): the system was not recognised")
                return
            }
            // Only while the host still has the address that was asked.
            guard try await HostRepository.shared.setSystem(system, id: hostId, at: (hostname, port)) else { return }
            // The id only: what a host runs, and what it answered, stay out of the log.
            logger.debug("Host \(hostId): the system was stored")
            await MainActor.run {
                NotificationCenter.default.post(name: .dsDataChanged, object: nil,
                                                userInfo: [HostSystemProbe.hostIdKey: hostId])
            }
        } catch {
            logger.debug("Host \(hostId): reading the system failed (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    /// `userInfo` key of the data-changed notification: the host whose system was just stored.
    static let hostIdKey = "detectedSystemHostId"
}
