import AppKit
import Foundation
import SwiftUI

// ssh runs this same executable as SSH_ASKPASS: answer the prompt through the app's askpass
// socket and exit before any UI is created. First of all: an askpass child inherits its
// parent's environment (a test run's, an isolated profile's) and must still be an askpass client.
if AskpassClient.isAskpassInvocation {
    exit(AskpassClient.run())
}

// Writing to a pipe whose reader went away (e.g. an SFTP session that ended) must return an
// error instead of terminating the app.
signal(SIGPIPE, SIG_IGN)

#if DEBUG
// -debugPrintProfile YES: say what this run would use, and leave before any UI or database.
if AppProfile.arguments.bool(forKey: "debugPrintProfile") {
    // The step `AppProfile.resolution` itself starts from, without the part that creates the
    // folder: what is printed is what a run uses, and printing leaves nothing behind.
    let resolved = AppProfile.resolveForThisProcess()
    print(AppProfile.report(for: resolved))
    if case .failure = resolved { exit(EX_CONFIG) }
    exit(0)
}
#endif

// A separate profile was asked for and cannot be had: refuse to start. Falling back to the
// standard profile here would put a QA run on the owner's real data.
if case .failure(let refusal) = AppProfile.resolution {
    let explanation = "Termi does not start: \(refusal.description) "
        + "It never falls back to the standard profile when a separate one was asked for."
    FileHandle.standardError.write(Data((explanation + "\n").utf8))
    // Launched from Finder / `open`, nobody reads stderr: say it in an alert as well. (Not from
    // a shell or a script, where a modal alert would only block: there stderr is a terminal, or
    // the inherited XPC_SERVICE_NAME names the app that owns the terminal, not this one.)
    if isatty(STDERR_FILENO) == 0,
       AppProfile.wasStartedByLaunchServices(environment: ProcessInfo.processInfo.environment,
                                             bundleIdentifier: Bundle.main.bundleIdentifier) {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "Termi cannot start")
            alert.informativeText = explanation
            alert.runModal()
        }
    }
    exit(EX_CONFIG)
}

// From here on, in a separate profile, AppKit's and every library's `UserDefaults.standard` is
// the profile's preferences as well. Before the application object exists.
// If that did not take, stop: going on would let AppKit write the owner's real preferences from
// a run that was promised a profile of its own.
if !AppProfile.redirectStandardDefaults() {
    FileHandle.standardError.write(Data(("Termi does not start: the preferences of this \(AppProfile.current.kind.rawValue) "
        + "profile could not be separated from the standard ones.\n").utf8))
    exit(EX_CONFIG)
}

MainActor.assumeIsolated {
    if AppProfile.current.kind == .tests {
        // Hosting a unit test run: a bare application, so that the tests can be injected and
        // run — no scenes, no app delegate, no windows, no updater, no notification request,
        // no network monitor, no clean-up of earlier runs, no database opened by the host.
        // Whatever a test opens through the app's singletons lands in the tests profile.
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        // The folder is this process's own (…/Termi-Tests/<pid>): it goes with the process.
        atexit {
            guard AppProfile.current.kind == .tests else { return }
            try? FileManager.default.removeItem(at: AppProfile.current.directory)
        }
        application.run()
    } else {
        TermiApp.main()
    }
}
