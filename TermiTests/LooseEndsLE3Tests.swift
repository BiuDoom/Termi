import Testing
import Foundation
@testable import Termi

// Loose ends of the click acceptance, tools and Settings: a port forward's delete confirmation
// names the rule, the import confirmation says where the replaced database stays, a snippet
// that was just added is shown even when the filters would hide it.

private func le3Rule(_ type: String, localPort: Int, remoteHost: String, remotePort: Int) -> PortForward {
    PortForward(id: 1, hostId: 7, type: type, localPort: localPort, remoteHost: remoteHost,
                remotePort: remotePort, enabled: false, createdAt: "")
}

@Test func le3ADeleteConfirmationNamesTheRuleTheWayItsRowReads() {
    let local = le3Rule("local", localPort: 18080, remoteHost: "127.0.0.1", remotePort: 8080)
    #expect(PortForwardViewModel.routeText(of: local, hostLabel: "test-a") == "localhost:18080 → 127.0.0.1:8080")

    // A remote forward listens on the host, not on this Mac.
    let remote = le3Rule("remote", localPort: 9000, remoteHost: "localhost", remotePort: 3000)
    #expect(PortForwardViewModel.routeText(of: remote, hostLabel: "test-a") == "test-a:9000 → localhost:3000")

    // An IPv6 target keeps its brackets, as in the row.
    let v6 = le3Rule("local", localPort: 5432, remoteHost: "::1", remotePort: 5432)
    #expect(PortForwardViewModel.routeText(of: v6, hostLabel: "db") == "localhost:5432 → [::1]:5432")
}

@Test func le3ADynamicRuleIsNamedByItsListenerNotByAnUnusedTarget() {
    let dynamic = le3Rule("dynamic", localPort: 1080, remoteHost: "ignored", remotePort: 1)
    let text = PortForwardViewModel.routeText(of: dynamic, hostLabel: "test-a")
    #expect(text.hasPrefix("localhost:1080 → "))
    #expect(!text.contains("ignored"))
}

@Test func le3TheImportConfirmationSaysHowMuchAndWhereTheOldDatabaseStays() {
    let folder = URL(fileURLWithPath: "/Users/Shared/Termi")
    let text = SettingsViewModel.importWarning(hosts: 12, keys: 3, identities: 4, databaseFolder: folder)
    #expect(text.contains("12"))
    #expect(text.contains("3"))
    #expect(text.contains("4"))
    #expect(text.contains("/Users/Shared/Termi"))
    #expect(text.contains("termi.before-import-"))
    // Without the folder the sentence is still whole.
    let unknown = SettingsViewModel.importWarning(hosts: 12, keys: 3, identities: 4, databaseFolder: nil)
    #expect(unknown.contains("termi.before-import-"))
    #expect(unknown != text)
}

@Test func le3ANewSnippetClearsTheFiltersOnlyWhenTheyHideIt() {
    // Shown already: the search and the category stay as they are.
    #expect(!SnippetsViewModel.filtersHide(5, shown: [3, 5], all: [1, 3, 5]))
    // Saved, but outside the filtered list.
    #expect(SnippetsViewModel.filtersHide(5, shown: [3], all: [1, 3, 5]))
    // Not a snippet at all (deleted meanwhile): nothing to reveal.
    #expect(!SnippetsViewModel.filtersHide(9, shown: [3], all: [1, 3, 5]))
}
