import AppKit
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import Termi

// Where a run keeps its data and its preferences: the pure resolver for the three kinds of
// profile, and that this very test process is in the tests profile (so that no test, and nothing
// the test host does, can reach the owner's real database, vault key or preferences).

private let profileHome = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
private let profileDefault = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Termi", isDirectory: true)
private let profileTemporary = URL(fileURLWithPath: "/var/folders/xx/T", isDirectory: true)

private func resolveProfile(_ environment: [String: String]) -> Result<AppProfile.Locations, AppProfile.Refusal> {
    AppProfile.resolve(environment: environment,
                       defaultDirectory: profileDefault,
                       homeDirectory: profileHome,
                       temporaryDirectory: profileTemporary,
                       processIdentifier: 4242)
}

private func resolvedLocations(_ environment: [String: String]) -> AppProfile.Locations? {
    try? resolveProfile(environment).get()
}

@Test func appProfileStandardIsExactlyTheLocationsTheAppAlwaysUsed() {
    let locations = resolvedLocations(["HOME": "/Users/someone", "PATH": "/usr/bin"])
    #expect(locations?.kind == .standard)
    #expect(locations?.directory.path == "/Users/someone/Library/Application Support/Termi")
    #expect(locations?.databaseURL.path == "/Users/someone/Library/Application Support/Termi/termi.db")
    #expect(locations?.vaultKeyURL.path == "/Users/someone/Library/Application Support/Termi/.vault-key")
    #expect(locations?.sessionLogsDirectory.path == "/Users/someone/Library/Application Support/Termi/SessionLogs")
    #expect(locations?.syncDirectory.path == "/Users/someone/.termi/sync")
    #expect(locations?.backupDirectory.path == "/Users/someone/Documents/Termi")
    // nil = UserDefaults.standard, the app's own domain.
    #expect(locations?.preferencesSuite == nil)
}

@Test func appProfileOverrideKeepsEverythingInsideTheGivenFolder() {
    let locations = resolvedLocations([AppProfile.overrideVariable: "/opt/termi-qa/profile-a"])
    #expect(locations?.kind == .isolated)
    #expect(locations?.directory.path == "/opt/termi-qa/profile-a")
    #expect(locations?.databaseURL.path == "/opt/termi-qa/profile-a/termi.db")
    #expect(locations?.vaultKeyURL.path == "/opt/termi-qa/profile-a/.vault-key")
    #expect(locations?.sessionLogsDirectory.path == "/opt/termi-qa/profile-a/SessionLogs")
    #expect(locations?.syncDirectory.path == "/opt/termi-qa/profile-a/sync")
    #expect(locations?.backupDirectory.path == "/opt/termi-qa/profile-a/Backups")
    #expect(locations?.preferencesSuite == "/opt/termi-qa/profile-a/Preferences")
}

@Test func appProfileOverrideIsStandardizedBeforeUse() {
    #expect(resolvedLocations([AppProfile.overrideVariable: "/opt/termi-qa/x/../profile-b/"])?.directory.path == "/opt/termi-qa/profile-b")
}

@Test(arguments: AppProfile.testHostVariables)
func appProfileHostedTestRunGetsAFolderOfItsOwnUnderTheTemporaryDirectory(variable: String) {
    // The variable only has to be there: Xcode sets some of them to an empty string.
    let locations = resolvedLocations([variable: ""])
    #expect(locations?.kind == .tests)
    #expect(locations?.directory.path == "/var/folders/xx/T/Termi-Tests/4242")
    #expect(locations?.databaseURL.path == "/var/folders/xx/T/Termi-Tests/4242/termi.db")
    #expect(locations?.syncDirectory.path == "/var/folders/xx/T/Termi-Tests/4242/sync")
    #expect(locations?.backupDirectory.path == "/var/folders/xx/T/Termi-Tests/4242/Backups")
    #expect(locations?.preferencesSuite == "/var/folders/xx/T/Termi-Tests/4242/Preferences")
}

@Test func appProfileTestFolderIsUniquePerProcess() {
    let one = AppProfile.resolve(environment: ["XCTestConfigurationFilePath": ""], defaultDirectory: profileDefault,
                                 homeDirectory: profileHome, temporaryDirectory: profileTemporary, processIdentifier: 1)
    let two = AppProfile.resolve(environment: ["XCTestConfigurationFilePath": ""], defaultDirectory: profileDefault,
                                 homeDirectory: profileHome, temporaryDirectory: profileTemporary, processIdentifier: 2)
    #expect(one != two)
}

@Test func appProfileTestRunWinsOverTheOverrideEvenAnUnusableOne() {
    let usable = resolvedLocations(["XCTestConfigurationFilePath": "/x.xctestconfiguration",
                                    AppProfile.overrideVariable: "/opt/termi-qa/profile-a"])
    #expect(usable?.kind == .tests)
    let unusable = resolvedLocations(["XCTestBundlePath": "/x.xctest", AppProfile.overrideVariable: "relative/path"])
    #expect(unusable?.kind == .tests)
}

@Test(arguments: ["", "relative/path", "./here", "../up", "~/profile", "profile", "/"])
func appProfileOverrideThatIsNotAnAbsoluteFolderIsRefusedNotIgnored(value: String) {
    // Never the standard profile when isolation was asked for.
    #expect(resolveProfile([AppProfile.overrideVariable: value]) == .failure(.notAnAbsoluteFolder(value)))
}

@Test(arguments: ["/Users/someone/Library/Application Support/Termi",
                  "/Users/someone/Library/Application Support/Termi/",
                  "/Users/someone/Library/Application Support/x/../Termi"])
func appProfileOverrideNamingTheStandardFolderIsRefused(value: String) {
    #expect(resolveProfile([AppProfile.overrideVariable: value]) == .failure(.isStandardProfile(value)))
}

// The usual volume is case-insensitive: another case of the name, or a folder inside the real
// profile, is still the real profile.
@Test(arguments: ["/Users/someone/Library/Application Support/termi",
                  "/users/someone/library/application support/TERMI/",
                  "/Users/someone/Library/Application Support/Termi/SessionLogs",
                  "/Users/someone/Library/Application Support/termi/qa/profile-a"])
func appProfileOverrideReachingTheStandardFolderByCaseOrFromInsideIsRefused(value: String) {
    #expect(resolveProfile([AppProfile.overrideVariable: value]) == .failure(.isStandardProfile(value)))
}

@Test func appProfileOverrideNextToTheStandardFolderIsAccepted() {
    // A sibling whose name merely starts the same way is another folder.
    let sibling = resolvedLocations([AppProfile.overrideVariable: "/Users/someone/Library/Application Support/Termi-QA"])
    #expect(sibling?.kind == .isolated)
}

// Judged by the file system: a link to the real folder, a link into it, and a folder that does
// not exist yet below either, all name the real profile — however they are spelled.
@Test func appProfileFolderReachedThroughALinkIsRecognizedAsTheStandardOne() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("Termi-ProfileIdentity-\(UUID().uuidString)", isDirectory: true)
    let standard = root.appendingPathComponent("Real/Termi", isDirectory: true)
    let inside = standard.appendingPathComponent("SessionLogs", isDirectory: true)
    let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
    try fm.createDirectory(at: inside, withIntermediateDirectories: true)
    try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let linkToStandard = root.appendingPathComponent("link-to-profile")
    let linkInside = root.appendingPathComponent("link-inside")
    let linkElsewhere = root.appendingPathComponent("link-elsewhere")
    try fm.createSymbolicLink(at: linkToStandard, withDestinationURL: standard)
    try fm.createSymbolicLink(at: linkInside, withDestinationURL: inside)
    try fm.createSymbolicLink(at: linkElsewhere, withDestinationURL: elsewhere)

    let same: Bool = AppProfile.namesStandardProfile(standard, standard: standard)
    let throughLink: Bool = AppProfile.namesStandardProfile(linkToStandard, standard: standard)
    let belowLink: Bool = AppProfile.namesStandardProfile(linkToStandard.appendingPathComponent("new/deeper"), standard: standard)
    let subfolder: Bool = AppProfile.namesStandardProfile(inside, standard: standard)
    let throughLinkInside: Bool = AppProfile.namesStandardProfile(linkInside, standard: standard)
    let belowLinkInside: Bool = AppProfile.namesStandardProfile(linkInside.appendingPathComponent("new"), standard: standard)
    #expect(same)
    #expect(throughLink)
    #expect(belowLink)
    #expect(subfolder)
    #expect(throughLinkInside)
    #expect(belowLinkInside)

    let other: Bool = AppProfile.namesStandardProfile(elsewhere, standard: standard)
    let otherThroughLink: Bool = AppProfile.namesStandardProfile(linkElsewhere.appendingPathComponent("new"), standard: standard)
    let parent: Bool = AppProfile.namesStandardProfile(standard.deletingLastPathComponent(), standard: standard)
    let notYetThere: Bool = AppProfile.namesStandardProfile(root.appendingPathComponent("absent/profile"), standard: standard)
    // A standard profile that was never created cannot be reached by any name.
    let noStandard: Bool = AppProfile.namesStandardProfile(elsewhere, standard: root.appendingPathComponent("absent"))
    #expect(!other)
    #expect(!otherThroughLink)
    #expect(!parent)
    #expect(!notYetThere)
    #expect(!noStandard)
}

// The profile folder holds the database, the vault key and session transcripts. It has to be
// 0700 before any of those are written, and a symlink at the path — or as a parent that does
// not exist yet — must not be chmod'd or written through. A parent other accounts can rename
// a new child in is refused; one that is already there is tightened and kept.
@Test func profileDirectoryIsOwnerOnlyAndDoesNotFollowASymlink() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-ProfileDir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let created = root.appendingPathComponent("created", isDirectory: true)
    try AppProfile.ensureOwnerOnlyDirectory(at: created)
    #expect(try profileDirectoryMode(created.path) == 0o700)
    let createdNames = try FileManager.default.contentsOfDirectory(atPath: created.path)
    #expect(createdNames.isEmpty)

    let nested = root.appendingPathComponent("missing/nested/profile", isDirectory: true)
    try AppProfile.ensureOwnerOnlyDirectory(at: nested)
    let missingMode = try profileDirectoryMode(root.appendingPathComponent("missing").path)
    let nestedParentMode = try profileDirectoryMode(root.appendingPathComponent("missing/nested").path)
    let nestedMode = try profileDirectoryMode(nested.path)
    #expect(missingMode == 0o700)
    #expect(nestedParentMode == 0o700)
    #expect(nestedMode == 0o700)

    let existing = root.appendingPathComponent("existing", isDirectory: true)
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: existing.path)
    try Data("db".utf8).write(to: existing.appendingPathComponent("termi.db"))
    try AppProfile.ensureOwnerOnlyDirectory(at: existing)
    #expect(try profileDirectoryMode(existing.path) == 0o700)
    #expect(try Data(contentsOf: existing.appendingPathComponent("termi.db")) == Data("db".utf8))

    let target = root.appendingPathComponent("target-dir", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    let link = root.appendingPathComponent("link-dir")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let followed = Result { try AppProfile.ensureOwnerOnlyDirectory(at: link) }
    if case .success = followed {
        Issue.record("secured a profile through a symlink")
    }
    #expect(try profileDirectoryMode(target.path) == 0o755)
    #expect(profilePathIsSymbolicLink(link.path))

    let parentLink = root.appendingPathComponent("parent-link")
    try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: target)
    let throughParent = Result {
        try AppProfile.ensureOwnerOnlyDirectory(at: parentLink.appendingPathComponent("profile"))
    }
    if case .success = throughParent {
        Issue.record("created a profile through a symlink")
    }
    let targetNames = try FileManager.default.contentsOfDirectory(atPath: target.path)
    #expect(!targetNames.contains("profile"))
    #expect(try profileDirectoryMode(target.path) == 0o755)

    let file = root.appendingPathComponent("not-a-directory")
    try Data("keep".utf8).write(to: file)
    let overwritten = Result { try AppProfile.ensureOwnerOnlyDirectory(at: file) }
    if case .success = overwritten {
        Issue.record("turned a file into a directory")
    }
    #expect(try Data(contentsOf: file) == Data("keep".utf8))

    let loose = root.appendingPathComponent("loose", isDirectory: true)
    try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: loose.path)
    let looseChild = loose.appendingPathComponent("profile", isDirectory: true)
    let inLooseParent = Result { try AppProfile.ensureOwnerOnlyDirectory(at: looseChild) }
    if case .success = inLooseParent {
        Issue.record("created a profile in a directory other accounts can rename")
    }
    #expect(!FileManager.default.fileExists(atPath: looseChild.path))
    // A folder that is already there still has to open: tighten it, keep what it holds.
    let already = loose.appendingPathComponent("already", isDirectory: true)
    try FileManager.default.createDirectory(at: already, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: already.path)
    try Data("stay".utf8).write(to: already.appendingPathComponent("note"))
    try AppProfile.ensureOwnerOnlyDirectory(at: already)
    let alreadyMode = try profileDirectoryMode(already.path)
    let alreadyPermissions: Int = alreadyMode & 0o777
    #expect(alreadyPermissions == 0o700)
    #expect(try Data(contentsOf: already.appendingPathComponent("note")) == Data("stay".utf8))

    let sticky = root.appendingPathComponent("sticky", isDirectory: true)
    try FileManager.default.createDirectory(at: sticky, withIntermediateDirectories: true)
    // `setAttributes` is not a reliable way to set the sticky bit. `chmod` does not follow this
    // path: it is a real directory we just created.
    #expect(chmod(sticky.path, 0o1777) == 0)
    let stickyParent = try profileDirectoryMode(sticky.path)
    let stickyBit: Int = stickyParent & 0o1000
    #expect(stickyBit == 0o1000)
    let stickyChild = sticky.appendingPathComponent("profile", isDirectory: true)
    try AppProfile.ensureOwnerOnlyDirectory(at: stickyChild)
    #expect(try profileDirectoryMode(stickyChild.path) == 0o700)
}

private func profileDirectoryMode(_ path: String) throws -> Int {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    // Keeps the sticky bit (0o1000) so a parent can be checked for it. The file type lives above these bits.
    return Int(info.st_mode) & 0o7777
}

private func profilePathIsSymbolicLink(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    return info.st_mode & S_IFMT == S_IFLNK
}

@Test func appProfileThisProcessResolvesTheWayItRuns() {
    // `-debugPrintProfile` prints this; `resolution` starts from it and only adds the folder.
    #expect(AppProfile.resolveForThisProcess() == AppProfile.resolution)
}

@Test func appProfileAlertOnlyWhenLaunchServicesStartedThisApp() {
    let id = "dev.termi.Termi"
    let byOpen: Bool = AppProfile.wasStartedByLaunchServices(
        environment: ["XPC_SERVICE_NAME": "application.dev.termi.Termi.127959032.127959038"], bundleIdentifier: id)
    // Inherited from the app that owns the terminal the command was typed in.
    let fromAnotherAppsTerminal: Bool = AppProfile.wasStartedByLaunchServices(
        environment: ["XPC_SERVICE_NAME": "application.com.anthropic.claudefordesktop.127959032.127959038"], bundleIdentifier: id)
    let longerIdentifier: Bool = AppProfile.wasStartedByLaunchServices(
        environment: ["XPC_SERVICE_NAME": "application.dev.termi.TermiHelper.1.2"], bundleIdentifier: id)
    let plainShell: Bool = AppProfile.wasStartedByLaunchServices(environment: ["XPC_SERVICE_NAME": "0"], bundleIdentifier: id)
    let noVariable: Bool = AppProfile.wasStartedByLaunchServices(environment: [:], bundleIdentifier: id)
    let noIdentifier: Bool = AppProfile.wasStartedByLaunchServices(
        environment: ["XPC_SERVICE_NAME": "application..1.2"], bundleIdentifier: nil)
    #expect(byOpen)
    #expect(!fromAnotherAppsTerminal)
    #expect(!longerIdentifier)
    #expect(!plainShell)
    #expect(!noVariable)
    #expect(!noIdentifier)
}

@Test func appProfileReportNamesKindFolderAndPreferences() {
    let isolated = AppProfile.report(for: resolveProfile([AppProfile.overrideVariable: "/opt/termi-qa/profile-a"]))
    #expect(isolated.contains("kind: isolated"))
    #expect(isolated.contains("directory: /opt/termi-qa/profile-a\n"))
    #expect(isolated.contains("preferences: /opt/termi-qa/profile-a/Preferences.plist"))
    let standard = AppProfile.report(for: resolveProfile([:]))
    #expect(standard.contains("kind: standard"))
    #expect(standard.contains("directory: /Users/someone/Library/Application Support/Termi\n"))
    #expect(standard.contains("preferences: standard"))
    let refused = AppProfile.report(for: resolveProfile([AppProfile.overrideVariable: "relative/path"]))
    #expect(refused.hasPrefix("refused: "))
    #expect(refused.contains("relative/path"))
}

@Test func launchArgumentsReadTextTheWayDefaultsReadAnArgument() {
    let arguments = LaunchArguments(domain: ["debugPage": "keys", "debugActive": "YES", "debugLockSessions": "3",
                                             "debugGalleryScroll": "120.5", "off": "NO", "number": 7])
    #expect(arguments.string(forKey: "debugPage") == "keys")
    #expect(arguments.string(forKey: "missing") == nil)
    #expect(arguments.bool(forKey: "debugActive"))
    #expect(!arguments.bool(forKey: "off"))
    #expect(!arguments.bool(forKey: "missing"))
    #expect(arguments.integer(forKey: "debugLockSessions") == 3)
    #expect(arguments.integer(forKey: "number") == 7)
    #expect(arguments.double(forKey: "debugGalleryScroll") == 120.5)
    #expect(arguments.object(forKey: "debugGalleryScroll") != nil)
    #expect(arguments.object(forKey: "missing") == nil)
}

// MARK: - This process

@Test func appProfileOfTheTestProcessIsTheTestsProfile() async throws {
    // What the detection rests on: the keys a hosted run really has (printed for the record).
    let keys = ProcessInfo.processInfo.environment.keys
        .filter { $0.contains("XCTest") || $0.contains("XCInject") || $0.contains("DYLD_INSERT") }
        .sorted()
    print("APPPROFILE-PROBE test host environment keys: \(keys)")
    let detected = AppProfile.testHostVariables.filter { ProcessInfo.processInfo.environment[$0] != nil }
    #expect(!detected.isEmpty)

    let profile = AppProfile.current
    let temporary = FileManager.default.temporaryDirectory.path
    let expected = FileManager.default.temporaryDirectory
        .appendingPathComponent("Termi-Tests/\(ProcessInfo.processInfo.processIdentifier)").path
    #expect(profile.kind == .tests)
    #expect(profile.directory.path == expected)

    // The app's singletons land there.
    let database = try await DatabaseManager.shared.databaseURL.path
    let expectedDatabase: String = expected + "/termi.db"
    let expectedLogs: String = expected + "/SessionLogs"
    let expectedTranscript: String = expected + "/SessionLogs/7.log"
    let isUnderTemporary: Bool = database.hasPrefix(temporary)
    #expect(database == expectedDatabase)
    #expect(isUnderTemporary)
    #expect(TerminalSession.sessionLogsDirectory.path == expectedLogs)
    #expect(TerminalSession.transcriptPath(for: 7) == expectedTranscript)

    // Preferences: a property list inside the folder, not the app's own domain — also for
    // whoever asks for `.standard` (AppKit, libraries).
    // Required, not expected: without the redirection the write below would land in the owner's
    // real preferences, and a failed expectation would not stop it.
    let redirected: Bool = UserDefaults.standard === AppProfile.defaults
    try #require(redirected)
    let key = "appProfileTests.marker"
    UserDefaults.standard.set("here", forKey: key)
    #expect(AppProfile.defaults.string(forKey: key) == "here")
    let suite: String = expected + "/Preferences"
    let stored = AppProfile.defaults.persistentDomain(forName: suite)?[key] as? String
    #expect(stored == "here")
    let realDomain = Bundle.main.bundleIdentifier ?? "dev.termi.Termi"
    let leaked = AppProfile.defaults.persistentDomain(forName: realDomain)?[key]
    #expect(leaked == nil)
    // Reads do not fall through to the real domain either: on a Mac where the app has run,
    // the updater's first-launch mark is there — and must not be visible from here.
    let fallenThrough = AppProfile.defaults.object(forKey: "SUHasLaunchedBefore")
    #expect(fallenThrough == nil)
    AppProfile.defaults.removeObject(forKey: key)
}

@MainActor
@Test func appProfileTestHostRunsNoneOfTheApp() {
    // A bare application: the app delegate (launch clean-up, updater, notification request,
    // network monitor, database) was never created.
    #expect(AppDelegate.shared == nil)
    #expect(NSApp.delegate == nil)
    #expect(!SparkleUpdater.isAvailable)
}
