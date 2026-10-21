import Foundation

/// Where this run keeps its data and its preferences — the one place that decides it.
///
/// - `standard`: the owner's real profile (Application Support/Termi, the app's own preferences
///   domain, ~/.termi/sync, ~/Documents/Termi).
/// - `isolated`: `TERMI_PROFILE_DIR=<absolute folder>` — everything inside that folder, like a
///   browser's `--user-data-dir`. Manual QA uses it; so can anyone who wants a second profile.
/// - `tests`: the process hosts a unit test run — a fresh folder under the temporary directory,
///   so that no test (and nothing the test host does) can reach the owner's data.
///
/// Database, vault key, session logs, the sync folder, the suggested backup folder and every
/// persistent preference derive from `AppProfile.current`; nothing else computes a location.
enum AppProfile {
    enum Kind: String, Sendable, Equatable {
        case standard, isolated, tests
    }

    /// The environment variable that asks for an isolated profile.
    static let overrideVariable = "TERMI_PROFILE_DIR"

    /// Set by xcodebuild / Xcode in a process that hosts a test run (observed on Xcode 27 for a
    /// hosted run with XCTest and Swift Testing; see `AppProfileTests`). Environment keys rather
    /// than a class lookup: `NSClassFromString("XCTestCase")` is also true wherever the XCTest
    /// framework happens to be loaded.
    static let testHostVariables = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]

    struct Locations: Sendable, Equatable {
        let kind: Kind
        /// Holds the database, the vault key and the session transcripts.
        let directory: URL
        /// Where encrypted sync exports are written.
        let syncDirectory: URL
        /// The folder suggested for backups.
        let backupDirectory: URL
        /// The preferences suite (a property list at this path + ".plist"); nil is the app's
        /// own domain, `UserDefaults.standard`.
        let preferencesSuite: String?

        var databaseURL: URL { directory.appendingPathComponent("termi.db") }
        var vaultKeyURL: URL { directory.appendingPathComponent(".vault-key") }
        var sessionLogsDirectory: URL { directory.appendingPathComponent("SessionLogs") }
    }

    enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        /// The override is empty, relative, starts with "~" or is the root folder.
        case notAnAbsoluteFolder(String)
        /// The override names the real profile, or a folder inside it: that is not isolation.
        case isStandardProfile(String)
        /// The folder cannot be created or written.
        case unusable(path: String, reason: String)

        var description: String {
            switch self {
            case .notAnAbsoluteFolder(let value):
                "\(AppProfile.overrideVariable) is set to \"\(value)\", which is not an absolute folder path."
            case .isStandardProfile(let value):
                "\(AppProfile.overrideVariable) is set to \"\(value)\", which is the standard profile folder or lies inside it."
            case .unusable(let path, let reason):
                "\(AppProfile.overrideVariable) is set to \"\(path)\", which cannot be used: \(reason)"
            }
        }
    }

    // MARK: - Resolver (pure)

    /// Decides the profile from what the process was given. Touches nothing on disk.
    /// Precedence: a hosted test run, then the override, then the standard profile. A set but
    /// unusable override is refused — it never falls back to the standard profile.
    static func resolve(environment: [String: String],
                        defaultDirectory: URL,
                        homeDirectory: URL,
                        temporaryDirectory: URL,
                        processIdentifier: Int32) -> Result<Locations, Refusal> {
        if testHostVariables.contains(where: { environment[$0] != nil }) {
            let directory = temporaryDirectory
                .appendingPathComponent("Termi-Tests", isDirectory: true)
                .appendingPathComponent("\(processIdentifier)", isDirectory: true)
            return .success(contained(in: directory, kind: .tests))
        }
        if let value = environment[overrideVariable] {
            guard value.hasPrefix("/") else { return .failure(.notAnAbsoluteFolder(value)) }
            let directory = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
            guard directory.path != "/" else { return .failure(.notAnAbsoluteFolder(value)) }
            // Compared without case: the usual volume is case-insensitive, where "…/termi" IS the
            // real folder. (On a case-sensitive volume this refuses a folder that only differs in
            // case from the real one — the safe side.) Other spellings of the same folder — links,
            // firmlinks — are caught on disk, by `namesStandardProfile`.
            let candidate = directory.path.lowercased()
            let standard = defaultDirectory.standardizedFileURL.path.lowercased()
            guard candidate != standard, !candidate.hasPrefix(standard + "/") else {
                return .failure(.isStandardProfile(value))
            }
            return .success(contained(in: directory, kind: .isolated))
        }
        return .success(Locations(
            kind: .standard,
            directory: defaultDirectory,
            syncDirectory: homeDirectory.appendingPathComponent(".termi").appendingPathComponent("sync"),
            backupDirectory: homeDirectory.appendingPathComponent("Documents/Termi"),
            preferencesSuite: nil
        ))
    }

    /// A profile that keeps everything, preferences included, inside one folder.
    private static func contained(in directory: URL, kind: Kind) -> Locations {
        Locations(
            kind: kind,
            directory: directory,
            syncDirectory: directory.appendingPathComponent("sync", isDirectory: true),
            backupDirectory: directory.appendingPathComponent("Backups", isDirectory: true),
            // A preferences "domain" that is an absolute path is a property list at that path:
            // the profile folder then holds its preferences too, and deleting it leaves nothing.
            preferencesSuite: directory.appendingPathComponent("Preferences").path
        )
    }

    // MARK: - The same folder under another name

    /// Whether `candidate` is `standard` or lies inside it, judged by the file system rather
    /// than by spelling: a symbolic link, a firmlink (/System/Volumes/Data/Users/…) or another
    /// case of the name all reach the same folder. Reads file identities; writes nothing.
    /// `candidate` need not exist yet: what does not exist cannot be a link, so its deepest
    /// existing ancestor decides where it would be created.
    static func namesStandardProfile(_ candidate: URL, standard: URL) -> Bool {
        guard let target = fileIdentity(atPath: standard.path) else { return false }
        var existing = candidate.standardizedFileURL
        while fileIdentity(atPath: existing.path) == nil, existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        guard let resolved = realpath(existing.path, nil) else { return false }
        defer { free(resolved) }
        var ancestor = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        // PATH_MAX bounds the depth of any real path; the bound only guards the loop.
        for _ in 0..<Int(PATH_MAX) {
            if let identity = fileIdentity(atPath: ancestor.path), identity == target { return true }
            if ancestor.path == "/" { break }
            ancestor.deleteLastPathComponent()
        }
        return false
    }

    /// Device and inode, following links.
    private static func fileIdentity(atPath path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private struct FileIdentity: Equatable {
        let device: Int64
        let inode: UInt64
    }

    // MARK: - This run

    /// The real profile folder of this user.
    private static var standardDirectory: URL {
        let fm = FileManager.default
        let applicationSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("Termi", isDirectory: true)
    }

    /// What this process would use, decided without creating or writing anything (it reads file
    /// identities to refuse an override that reaches the real profile under another name).
    /// `resolution` and `-debugPrintProfile` both start here, so what is printed is what runs.
    static func resolveForThisProcess() -> Result<Locations, Refusal> {
        let fm = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let standard = standardDirectory
        let resolved = resolve(
            environment: environment,
            defaultDirectory: standard,
            homeDirectory: fm.homeDirectoryForCurrentUser,
            temporaryDirectory: fm.temporaryDirectory,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        if case .success(let locations) = resolved, locations.kind == .isolated,
           namesStandardProfile(locations.directory, standard: standard) {
            return .failure(.isStandardProfile(environment[overrideVariable] ?? locations.directory.path))
        }
        return resolved
    }

    /// What this process uses, or why it must not start. `main.swift` looks at this before
    /// anything reads `current`.
    static let resolution: Result<Locations, Refusal> = {
        let fm = FileManager.default
        let resolved = resolveForThisProcess()
        // The standard profile is created where it always was: by the database on first use.
        guard case .success(let locations) = resolved, locations.kind != .standard else { return resolved }
        do {
            if locations.kind == .tests, fm.fileExists(atPath: locations.directory.path) {
                // An earlier test process with the same process identifier: start empty.
                try fm.removeItem(at: locations.directory)
            }
            try fm.createDirectory(at: locations.directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            guard fm.isWritableFile(atPath: locations.directory.path) else {
                return .failure(.unusable(path: locations.directory.path, reason: "the folder is not writable."))
            }
        } catch {
            return .failure(.unusable(path: locations.directory.path, reason: error.localizedDescription))
        }
        return resolved
    }()

    /// The locations of this run. `main.swift` has already left if the profile was refused.
    static let current: Locations = {
        switch resolution {
        case .success(let locations): return locations
        case .failure(let refusal): fatalError(refusal.description)
        }
    }()

    /// Every persistent preference of the app is read and written here (and SwiftUI's
    /// `@AppStorage` through `.defaultAppStorage`). In the standard profile this is
    /// `UserDefaults.standard` itself; in the others `main.swift` makes `.standard` this object
    /// (see `redirectStandardDefaults`). `UserDefaults` is documented as thread-safe; the SDK
    /// just does not mark it Sendable.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard let suite = current.preferencesSuite, let defaults = UserDefaults(suiteName: suite) else {
            precondition(current.kind == .standard, "A separate profile must not use the standard preferences")
            return UserDefaults.standard
        }
        if current.kind == .tests {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }()

    /// Makes `UserDefaults.standard` the profile's preferences for the rest of the process.
    /// Nothing happens in the standard profile. Returns false when a separate profile was asked
    /// for and `.standard` is still the real domain afterwards: the caller must not go on.
    ///
    /// The app's own code asks for `AppProfile.defaults`, but AppKit and libraries write to
    /// `UserDefaults.standard` without asking anyone: window and split view frames, toolbar
    /// and file panel state, text-substitution switches. Measured: one isolated run that
    /// resized its window changed "NSWindow Frame main-AppWindow-1" in the owner's real
    /// preferences. There is no public way to give a process another standard domain, so the
    /// class method is replaced — only where a separate profile was asked for. (What reads
    /// CFPreferences directly, such as the bundle's language list, still sees the real domain;
    /// those are reads.)
    @discardableResult
    static func redirectStandardDefaults() -> Bool {
        guard current.kind != .standard else { return true }
        // Read from the real argument domain before `.standard` changes.
        _ = arguments
        let profileDefaults = defaults
        if profileDefaults !== UserDefaults.standard,
           let method = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")) {
            let replacement: @convention(block) (AnyObject) -> UserDefaults = { _ in profileDefaults }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        // Judged by the outcome, not by the steps: whatever went wrong above, a run that still
        // has the real domain behind `.standard` would let AppKit write the owner's preferences.
        return UserDefaults.standard === profileDefaults
    }

    /// Whether LaunchServices started this very app (Finder, the Dock, `open`): then
    /// XPC_SERVICE_NAME is "application.<bundle identifier>.<n>.<n>". The variable is inherited,
    /// so a terminal inside another app passes "application.<that app>…" on to what it runs —
    /// which is why the bundle identifier is part of the test.
    static func wasStartedByLaunchServices(environment: [String: String], bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let service = environment["XPC_SERVICE_NAME"] else { return false }
        return service.hasPrefix("application.\(bundleIdentifier).")
    }

    /// The `-name value` pairs this process was launched with (`-debugPage keys` …). Launch
    /// arguments are not preferences: they are read from the argument domain alone, in every
    /// kind of profile, and never from (or into) a stored domain.
    static let arguments = LaunchArguments(
        domain: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    )

    /// What `-debugPrintProfile YES` prints: enough to see what a run would use without
    /// starting it.
    static func report(for resolution: Result<Locations, Refusal>) -> String {
        switch resolution {
        case .success(let locations):
            return [
                "kind: \(locations.kind.rawValue)",
                "directory: \(locations.directory.path)",
                "database: \(locations.databaseURL.path)",
                "vault key: \(locations.vaultKeyURL.path)",
                "session logs: \(locations.sessionLogsDirectory.path)",
                "sync: \(locations.syncDirectory.path)",
                "backups: \(locations.backupDirectory.path)",
                "preferences: \(locations.preferencesSuite.map { $0 + ".plist" } ?? "standard (\(Bundle.main.bundleIdentifier ?? "dev.termi.Termi"))")"
            ].joined(separator: "\n")
        case .failure(let refusal):
            return "refused: \(refusal.description)"
        }
    }
}

/// A snapshot of the argument domain. Values are text, as typed on the command line.
struct LaunchArguments: Sendable, Equatable {
    private let values: [String: String]

    init(domain: [String: Any]) {
        values = domain.mapValues { ($0 as? String) ?? "\($0)" }
    }

    func string(forKey key: String) -> String? { values[key] }

    /// YES / true / 1, as `UserDefaults.bool(forKey:)` reads an argument.
    func bool(forKey key: String) -> Bool {
        guard let value = values[key] else { return false }
        return (value as NSString).boolValue
    }

    func integer(forKey key: String) -> Int {
        guard let value = values[key] else { return 0 }
        return (value as NSString).integerValue
    }

    func double(forKey key: String) -> Double {
        guard let value = values[key] else { return 0 }
        return (value as NSString).doubleValue
    }

    func object(forKey key: String) -> Any? { values[key] }
}
