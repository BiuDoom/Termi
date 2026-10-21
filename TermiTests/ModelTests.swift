import Testing
import Foundation
import SwiftUI
@testable import Termi

// MARK: - Host Tests

@Test func hostDefaultValues() {
    let host = Host.defaultValue()
    #expect(host.label == "")
    #expect(host.hostname == "")
    #expect(host.port == 22)
    #expect(host.username == "root")
    #expect(host.authType == "password")
    #expect(host.id == nil)
    #expect(host.passwordEncrypted == nil)
    #expect(host.privateKeyId == nil)
    #expect(host.identityId == nil)
    #expect(host.groupId == nil)
    #expect(host.sortOrder == 0)
    #expect(host.x11Forwarding == false)
}

@Test func hostTimestampsAreISO8601() {
    let host = Host.defaultValue()
    let formatter = ISO8601DateFormatter()
    #expect(formatter.date(from: host.createdAt) != nil)
    #expect(formatter.date(from: host.updatedAt) != nil)
}

// MARK: - TerminalTab Tests

@Test func terminalTabDefaultIsLocal() {
    let tab = TerminalTab(title: "Local")
    #expect(tab.title == "Local")
    #expect(tab.isSSH == false)
    #expect(tab.hostId == nil)
    #expect(tab.adHocHost == nil)
    #expect(tab.adHocPassword == nil)
}

@Test func terminalTabSSH() {
    let tab = TerminalTab(title: "server1", isSSH: true, hostId: 42)
    #expect(tab.title == "server1")
    #expect(tab.isSSH == true)
    #expect(tab.hostId == 42)
}

@Test func terminalTabEquatableByID() {
    let tab1 = TerminalTab(title: "A")
    let tab2 = TerminalTab(title: "A")
    // Different instances have different UUIDs
    #expect(tab1 != tab2)
    // Same instance equals itself
    #expect(tab1 == tab1)
}

/// SwiftUI skips re-rendering `ForEach(tabs)` while the tabs compare equal, so equality has to
/// see layout, focus, title and broadcast changes — not only the id.
@Test func terminalTabEqualityTracksContent() {
    let tab = TerminalTab(title: "A")
    let pane = TerminalPane(title: "A")

    var split = tab
    split.panes.append(pane)
    split.layout = split.layout.inserting(pane.id, nextTo: tab.focusedPaneId, axis: .horizontal)
    #expect(split != tab)

    var refocused = split
    refocused.focusedPaneId = pane.id
    #expect(refocused != split)

    var broadcasting = split
    broadcasting.broadcastInput = true
    #expect(broadcasting != split)

    var renamed = tab
    renamed.title = "B"
    #expect(renamed != tab)
}

@Test func terminalTabUniqueIDs() {
    let tabs = (0..<100).map { _ in TerminalTab() }
    let uniqueIDs = Set(tabs.map(\.id))
    #expect(uniqueIDs.count == 100)
}

// MARK: - SidebarItem Tests

@Test func sidebarItemAllCases() {
    #expect(SidebarItem.allCases.count == 12)
}

@Test func sidebarItemLabelsNonEmpty() {
    for item in SidebarItem.allCases {
        #expect(!item.label.isEmpty, "SidebarItem.\(item.rawValue) label should not be empty")
    }
}

@Test func sidebarItemIconsNonEmpty() {
    for item in SidebarItem.allCases {
        #expect(!item.icon.isEmpty, "SidebarItem.\(item.rawValue) icon should not be empty")
    }
}

@Test func sidebarItemIDMatchesRawValue() {
    for item in SidebarItem.allCases {
        #expect(item.id == item.rawValue)
    }
}

// MARK: - TerminalTheme Tests

@Test func terminalThemeBuiltInCount() {
    #expect(TerminalTheme.builtIn.count == 12)
}

@Test func terminalThemeAllHave16AnsiColors() {
    for theme in TerminalTheme.builtIn {
        #expect(theme.ansiColors.count == 16, "Theme \(theme.name) should have 16 ANSI colors")
    }
}

@Test func terminalThemeFindById() {
    let dracula = TerminalTheme.find("dracula")
    #expect(dracula.name == "Dracula")
    #expect(dracula.isDark == true)
}

@Test func terminalThemeFindFallback() {
    let unknown = TerminalTheme.find("nonexistent")
    #expect(unknown.id == "defaultDark")
}

@Test func terminalThemeUniqueIds() {
    let ids = TerminalTheme.builtIn.map(\.id)
    #expect(Set(ids).count == ids.count, "Theme IDs should be unique")
}

@Test func terminalThemeNsColorParsing() {
    let color = TerminalTheme.nsColor(hex: "#FF0000")
    var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
    let srgb = color.usingColorSpace(.sRGB) ?? color
    srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
    #expect(r > 0.99)
    #expect(g < 0.01)
    #expect(b < 0.01)
}

@Test func terminalThemeLightAndDarkPresent() {
    let darkThemes = TerminalTheme.builtIn.filter(\.isDark)
    let lightThemes = TerminalTheme.builtIn.filter { !$0.isDark }
    #expect(!darkThemes.isEmpty, "Should have at least one dark theme")
    #expect(!lightThemes.isEmpty, "Should have at least one light theme")
}

// MARK: - SFTPItem Tests

private func sftpEntry(_ name: String, permissions: UInt32, size: UInt64 = 0,
                       longName: String = "") -> SFTPClient.DirectoryEntry {
    SFTPClient.DirectoryEntry(
        name: name,
        longName: longName,
        attributes: SFTPClient.Attributes(size: size, uid: 0, gid: 0, permissions: permissions,
                                          accessTime: 0, modificationTime: 1_700_000_000)
    )
}

@Test func sftpItemFromFileEntry() {
    let entry = sftpEntry("readme.txt", permissions: 0o100644, size: 12345,
                          longName: "-rw-r--r--    1 root     wheel       12345 Nov 14 22:13 readme.txt")
    let item = SFTPItem(entry: entry, parentPath: "/home")
    #expect(item.name == "readme.txt")
    #expect(item.path == "/home/readme.txt")
    #expect(item.isDirectory == false)
    #expect(item.isSymlink == false)
    #expect(item.size == 12345)
    #expect(item.permissions == "-rw-r--r--")
    #expect(item.octalPermissions == "644")
    #expect(item.owner == "root")
    #expect(item.group == "wheel")
    #expect(item.modified == Date(timeIntervalSince1970: 1_700_000_000))
}

@Test func sftpItemFromDirectoryAndSymlinkEntries() {
    let dir = SFTPItem(entry: sftpEntry("projects", permissions: 0o040755), parentPath: "/var/")
    #expect(dir.isDirectory)
    #expect(dir.path == "/var/projects")
    #expect(dir.permissions == "drwxr-xr-x")
    #expect(dir.displaySize == "—")
    #expect(dir.icon == "folder.fill")

    let link = SFTPItem(entry: sftpEntry("current", permissions: 0o120777), parentPath: "/srv")
    #expect(link.isSymlink)
    #expect(!link.isDirectory)
    #expect(link.permissions == "lrwxrwxrwx")
    #expect(link.icon == "link")
}

@Test func sftpItemNamesWithSpacesAndIcons() {
    let item = SFTPItem(entry: sftpEntry("my file.swift", permissions: 0o100600, size: 1_048_576), parentPath: "/")
    #expect(item.path == "/my file.swift")
    #expect(item.icon == "chevron.left.forwardslash.chevron.right")
    #expect(item.displaySize != "—")
}

@Test func sftpItemSortsDirectoriesFirst() {
    let items = [
        SFTPItem(entry: sftpEntry("b.txt", permissions: 0o100644), parentPath: "/"),
        SFTPItem(entry: sftpEntry("a-dir", permissions: 0o040755), parentPath: "/"),
        SFTPItem(entry: sftpEntry("A.txt", permissions: 0o100644), parentPath: "/"),
    ].sorted(by: SFTPItem.directoriesFirst)
    #expect(items.map(\.name) == ["a-dir", "A.txt", "b.txt"])
}

@Test func sftpPathHelpers() {
    #expect(SFTPClient.join("/", "etc") == "/etc")
    #expect(SFTPClient.join("/etc", "hosts") == "/etc/hosts")
    #expect(SFTPClient.parent(of: "/etc/hosts") == "/etc")
    #expect(SFTPClient.parent(of: "/etc") == "/")
    #expect(SFTPClient.parent(of: "/") == "/")
}

// MARK: - SSH key type

@Test func sshKeyTypeComesFromPublicKey() {
    // Every OpenSSH-format private key has the same header, whatever the algorithm.
    let openSSHKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\n-----END OPENSSH PRIVATE KEY-----"
    #expect(SSHKeyGenerator.keyType(publicKey: "ssh-ed25519 AAAAC3Nz test", privateKey: openSSHKey) == "ed25519")
    #expect(SSHKeyGenerator.keyType(publicKey: "ssh-rsa AAAAB3Nz test", privateKey: openSSHKey) == "rsa")
    #expect(SSHKeyGenerator.keyType(publicKey: "ecdsa-sha2-nistp256 AAAAE2Vj test", privateKey: openSSHKey) == "ecdsa")
}

@Test func sshKeyTypeFallsBackToPEMHeader() {
    #expect(SSHKeyGenerator.keyType(publicKey: "", privateKey: "-----BEGIN RSA PRIVATE KEY-----") == "rsa")
    #expect(SSHKeyGenerator.keyType(publicKey: "", privateKey: "-----BEGIN EC PRIVATE KEY-----") == "ecdsa")
    // An encrypted OpenSSH-format key without its public key does not reveal the algorithm.
    #expect(SSHKeyGenerator.keyType(publicKey: "", privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----") == "unknown")
}

// MARK: - Page state that lives with the window

// The page models are kept by the window's AppViewModel, so what they hold has to survive the
// hosts being edited or deleted on the Hosts page meanwhile. These only set in-memory state;
// nothing is read from the database and nothing connects.

private func pickedHost(id: Int64, hostname: String = "10.0.0.5") -> Termi.Host {
    var host = Host.defaultValue()
    host.id = id
    host.label = "staging"
    host.hostname = hostname
    return host
}

@Test func toolsPageSelectionSurvivesAConnection() {
    // Every connection stamps last_connected_at, reordering changes sort_order: still the
    // host that was picked, and its results stay.
    let picked = pickedHost(id: 7)
    var current = picked
    current.lastConnectedAt = "2026-10-04T10:00:00Z"
    current.sortOrder = 3
    #expect(DevOpsHostSelection(of: picked, in: [pickedHost(id: 1), current]) == .same(current))
}

@Test func toolsPageSelectionNoticesAnEditedHost() {
    let picked = pickedHost(id: 7)

    var moved = picked
    moved.hostname = "10.0.0.9"
    #expect(DevOpsHostSelection(of: picked, in: [moved]) == .changed(moved))

    var otherUser = picked
    otherUser.username = "deploy"
    #expect(DevOpsHostSelection(of: picked, in: [otherUser]) == .changed(otherUser))

    var otherKey = picked
    otherKey.authType = "privateKey"
    otherKey.privateKeyId = 3
    #expect(DevOpsHostSelection(of: picked, in: [otherKey]) == .changed(otherKey))

    var viaJumpHost = picked
    viaJumpHost.jumpHostId = 2
    #expect(DevOpsHostSelection(of: picked, in: [viaJumpHost]) == .changed(viaJumpHost))

    // Only the password was replaced: it is in the vault, the record just gets a new save time.
    var savedAgain = picked
    savedAgain.updatedAt = "2026-10-04T10:00:00Z"
    #expect(DevOpsHostSelection(of: picked, in: [savedAgain]) == .changed(savedAgain))
}

@Test func toolsPageSelectionOfADeletedHostIsGone() {
    #expect(DevOpsHostSelection(of: pickedHost(id: 7), in: [pickedHost(id: 1)]) == .gone)
    #expect(DevOpsHostSelection(of: pickedHost(id: 7), in: []) == .gone)
}

@Test @MainActor func dockerPageForgetsADeletedHost() {
    let viewModel = DockerViewModel()
    viewModel.selectedHost = pickedHost(id: 7)
    viewModel.containers = [DockerService.Container(id: "4f1c2a9be0d3", name: "web", image: "nginx",
                                                    status: "Up 2 hours", ports: "", created: "")]
    viewModel.error = "Docker error: permission denied"
    viewModel.showingLogs = true

    viewModel.hosts = [pickedHost(id: 1)]
    viewModel.refreshSelectedHost()

    #expect(viewModel.selectedHost == nil)
    #expect(viewModel.containers.isEmpty)
    // Would otherwise be shown in place of "No Hosts" once the last host is gone.
    #expect(viewModel.error == nil)
    #expect(viewModel.isLoading == false)
    #expect(viewModel.showingLogs == false)
}

@Test @MainActor func dockerPageWorksOnTheSavedCopyOfItsHost() {
    let viewModel = DockerViewModel()
    let picked = pickedHost(id: 7)
    viewModel.selectedHost = picked
    viewModel.containers = [DockerService.Container(id: "4f1c2a9be0d3", name: "web", image: "nginx",
                                                    status: "Up 2 hours", ports: "", created: "")]

    var current = picked
    current.lastConnectedAt = "2026-10-04T10:00:00Z"
    viewModel.hosts = [current]
    viewModel.refreshSelectedHost()

    #expect(viewModel.selectedHost == current)
    #expect(viewModel.containers.count == 1)
}

@Test @MainActor func monitoringPageForgetsADeletedHost() {
    let viewModel = MonitorViewModel()
    viewModel.selectedHost = pickedHost(id: 7)
    viewModel.stats = MonitorService.ServerStats()
    viewModel.error = "Connection refused"

    viewModel.hosts = []
    viewModel.refreshSelectedHost()

    #expect(viewModel.selectedHost == nil)
    #expect(viewModel.stats == nil)
    #expect(viewModel.error == nil)
    #expect(viewModel.isLoading == false)
    #expect(viewModel.isAutoRefresh == false)
}

@Test @MainActor func monitoringPageKeepsTheReadingOfAnUnchangedHost() {
    let viewModel = MonitorViewModel()
    let picked = pickedHost(id: 7)
    viewModel.selectedHost = picked
    viewModel.stats = MonitorService.ServerStats()

    var current = picked
    current.lastConnectedAt = "2026-10-04T10:00:00Z"
    viewModel.hosts = [pickedHost(id: 1), current]
    viewModel.refreshSelectedHost()

    #expect(viewModel.selectedHost == current)
    #expect(viewModel.stats != nil)
}

@Test @MainActor func batchSelectionForgetsDeletedHosts() {
    let viewModel = BatchCommandViewModel()
    viewModel.allHosts = [pickedHost(id: 1), pickedHost(id: 2)]
    viewModel.selectAllHosts()
    #expect(viewModel.selectedHosts.count == 2)

    // Host 2 was deleted on the Hosts page; the list is read again when the page comes back.
    viewModel.allHosts = [pickedHost(id: 1)]

    #expect(viewModel.selectedHostIds == [1])
    #expect(viewModel.selectedHosts.map(\.id) == [1])

    viewModel.allHosts = []
    #expect(viewModel.selectedHostIds.isEmpty)
    #expect(viewModel.selectedHosts.isEmpty)
}

@Test @MainActor func hostsPageDropsTheSelectionOfADeletedHost() {
    let viewModel = HostsViewModel()
    viewModel.hosts = [pickedHost(id: 1), pickedHost(id: 2)]
    viewModel.selectedHostId = 2

    // A reload that still has the host keeps it selected.
    viewModel.hosts = [pickedHost(id: 1), pickedHost(id: 2)]
    #expect(viewModel.selectedHostId == 2)

    // The model outlives the page: the deleted host does not stay selected, and no other
    // host is selected in its place (nobody chose it).
    viewModel.hosts = [pickedHost(id: 1)]
    #expect(viewModel.selectedHostId == nil)

    viewModel.selectedHostId = 1
    viewModel.hosts = []
    #expect(viewModel.selectedHostId == nil)
}

@Test @MainActor func hostsPageSheetsDoNotOutliveThePage() {
    let viewModel = HostsViewModel()
    viewModel.searchText = "prod"
    viewModel.selectedTag = "prod"
    viewModel.showingAddHost = true
    viewModel.editingHost = pickedHost(id: 1)
    viewModel.showingAddGroup = true
    viewModel.showingDeleteConfirm = true
    viewModel.hostToDelete = pickedHost(id: 1)

    viewModel.dismissSheets()

    #expect(viewModel.showingAddHost == false)
    #expect(viewModel.editingHost == nil)
    #expect(viewModel.showingAddGroup == false)
    #expect(viewModel.editingGroup == nil)
    #expect(viewModel.showingDeleteConfirm == false)
    #expect(viewModel.hostToDelete == nil)
    #expect(viewModel.groupToDelete == nil)
    // What the page is kept for stays.
    #expect(viewModel.searchText == "prod")
    #expect(viewModel.selectedTag == "prod")
}

// MARK: - Secure field

@Test @MainActor func secureFieldLeavesReturnToTheDefaultButton() {
    let field = NSSecureTextField()
    let editor = NSTextView()
    let insertNewline = #selector(NSResponder.insertNewline(_:))

    // No handler (a password field in a sheet): Return is not the field's, so it ends editing
    // and reaches the sheet's default button.
    let plain = ASCIISecureField.Coordinator(text: .constant(""), onSubmit: nil)
    #expect(plain.control(field, textView: editor, doCommandBy: insertNewline) == false)

    var submitted = 0
    let submitting = ASCIISecureField.Coordinator(text: .constant(""), onSubmit: { submitted += 1 })
    #expect(submitting.control(field, textView: editor, doCommandBy: insertNewline) == true)
    #expect(submitted == 1)
    // Other keys stay the field's own business.
    #expect(submitting.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))) == false)
    #expect(submitted == 1)
}
