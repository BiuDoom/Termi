import SwiftUI
import UniformTypeIdentifiers

/// Remote file browser panel for SFTP
struct RemoteFilePanelView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Bindable var viewModel: SFTPViewModel
    @State private var pathInput = ""
    @State private var isDropTarget = false
    @State private var columns = FileColumnVisibility()

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            pathBar

            ZStack {
                if viewModel.remoteLoading && viewModel.remoteItems.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.remoteError {
                    errorView(error)
                } else if viewModel.visibleRemoteItems.isEmpty {
                    emptyView
                } else {
                    fileList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A directory that could not be listed has no count: the rows kept from the folder
            // before it are not this folder's ("10 items · 209.7 MB" stood under the error).
            FilePanelFooter(summary: viewModel.remoteError != nil ? nil
                            : SFTPListingSummary(items: viewModel.visibleRemoteItems,
                                                 selection: viewModel.selectedRemoteItems))
        }
        .filePanelCard()
        .overlay {
            if isDropTarget {
                FileDropHighlight(label: Text("Upload to \(viewModel.remotePath)"))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.uploadToRemoteFolder(urls.filter(\.isFileURL))
        } isTargeted: { isDropTarget = $0 }
        .onGeometryChange(for: FileColumnVisibility.self) { proxy in
            .fitting(proxy.size.width, hasPermissions: true)
        } action: { columns = $0 }
        .environment(\.fileColumns, columns)
        .onAppear { pathInput = viewModel.remotePath }
        .onChange(of: viewModel.remotePath) { _, newValue in pathInput = newValue }
        .alert("New Folder", isPresented: $viewModel.showingNewFolder) {
            TextField("Folder name", text: $viewModel.newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                Task { await viewModel.createRemoteFolder() }
            }
        }
        .alert("Rename", isPresented: $viewModel.showingRename) {
            TextField("New name", text: $viewModel.renameValue)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                Task { await viewModel.renameRemoteItem() }
            }
        }
        .alert("Change Permissions", isPresented: $viewModel.showingChmod) {
            TextField("Permissions (e.g. 755)", text: $viewModel.chmodValue)
            Button("Cancel", role: .cancel) {}
            Button("Apply") {
                Task { await viewModel.chmodRemoteItem() }
            }
        } message: {
            if let item = viewModel.chmodTarget, item.isSymlink {
                Text("“\(item.name)” is a link. This changes the permissions of what it points to.")
            }
        }
        .alert("Delete Items", isPresented: $viewModel.showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await viewModel.deleteRemoteItems(viewModel.deleteTargets) }
            }
        } message: {
            Text(verbatim: SFTPViewModel.deleteConfirmation(for: viewModel.deleteTargets))
        }
        .alert("The operation could not be completed", isPresented: actionErrorShown) {
            Button("OK") {}
        } message: {
            Text(verbatim: viewModel.remoteActionError ?? "")
        }
    }

    private var actionErrorShown: Binding<Bool> {
        Binding {
            viewModel.remoteActionError != nil
        } set: { shown in
            guard !shown else { return }
            viewModel.remoteActionError = nil
            // A path typed into the bar that could not be opened: the bar shows where we are.
            pathInput = viewModel.remotePath
        }
    }

    private var selectedItems: [SFTPItem] { viewModel.selectedRemote }

    private var panelHeader: some View {
        let host = viewModel.selectedHost
        let jump = host?.firstJumpName(hosts: appViewModel.hostsPage.hosts, groups: appViewModel.hostsPage.allGroups)
        return FilePanelHeader(title: host?.displayName ?? String(localized: "Remote"),
                               subtitle: host?.addressDescription ?? "", isAddress: true, jump: jump,
                               titleMenu: hostMenu) {
            if let host {
                DSHostAvatar(host, size: 32, status: .live)
            } else {
                DSHostAvatar(os: .unknown, size: 32)
            }
        } actions: {
            // The page's one primary action: taking the selection to this Mac.
            Button {
                viewModel.downloadSelected()
            } label: {
                Label("Download", systemImage: "arrow.down.to.line")
            }
            .dsButtonStyle(.prominent)
            .disabled(selectedItems.isEmpty || !viewModel.remoteListingIsCurrent)
            .help("Download the selection into the local folder")

            DSGlassIconMenu {
                Button {
                    viewModel.beginNewFolder()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(!viewModel.remoteListingIsCurrent)
                // What only this menu has: "Download" is the button next to it, hidden files
                // the toolbar's switch.
                if let item = selectedItems.first {
                    Divider()
                    itemActions(item, selection: selectedItems, listingIsCurrent: viewModel.remoteListingIsCurrent,
                                includesDownload: false)
                }
            }
        }
    }

    /// The panel's name is the way to another host (it was a capsule in the toolbar, with the
    /// same tile and name as this head).
    private var hostMenu: FilePanelTitleMenu? {
        guard viewModel.selectedHost != nil, !viewModel.hosts.isEmpty else { return nil }
        // Switching disconnects, which would cancel what is running.
        let isBusy = viewModel.hasActiveTransfers
        return FilePanelTitleMenu(
            items: viewModel.hosts.map { other in
                FilePanelTitleMenu.Item(id: other.connectionKey,
                                        title: other.label.isEmpty ? other.addressDescription : other.label) {
                    Task { await viewModel.connect(to: other) }
                }
            },
            isDisabled: isBusy,
            help: isBusy ? "Wait for transfers to finish" : "Switch host")
    }

    private var pathBar: some View {
        // From the root: a server's home is one folder among others, and "/" is one click away.
        FilePathBar(path: $pathInput, crumbs: SFTPBreadcrumbs(path: viewModel.remotePath, home: nil),
                    rootSymbol: "externaldrive", isLoading: viewModel.remoteLoading,
                    editShortcut: KeyboardShortcut("l", modifiers: .command)) {
            DSRowButton("chevron.left", help: "Back") {
                Task { await viewModel.navigateRemoteBack() }
            }
            .disabled(!viewModel.canGoBack)

            DSRowButton("chevron.up", help: "Enclosing folder") {
                Task { await viewModel.navigateRemoteUp() }
            }
            .disabled(viewModel.remotePath == "/")

            DSRowButton("house", help: "Home folder") {
                Task { await viewModel.navigateRemoteHome() }
            }
        } onOpen: { path in
            Task { await viewModel.navigateRemote(to: path) }
        } onSubmit: {
            Task { await viewModel.navigateRemote(to: pathInput) }
        } onCancel: {
            pathInput = viewModel.remotePath
        } onRefresh: {
            Task { await viewModel.loadRemoteDirectory() }
        }
    }

    private var fileList: some View {
        // Once for all rows: each row's menu is built with the row, and working these out per
        // row would walk the whole listing for every row on screen.
        let selection = selectedItems
        let listingIsCurrent = viewModel.remoteListingIsCurrent
        return VStack(spacing: 0) {
            FileListHeader(showPermissions: true)
            List(viewModel.visibleRemoteItems, selection: $viewModel.selectedRemoteItems) { item in
                Group {
                if item.isNameRepresentable {
                    FileRowView(item: item, showPermissions: true)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            Task { await viewModel.openRemote(item) }
                        }
                        .draggable(viewModel.remoteDragPayload(for: item))
                        .contextMenu { itemActions(item, selection: selection, listingIsCurrent: listingIsCurrent) }
                } else {
                    // Listed so the folder is seen as it is, but with no action: the name
                    // shown is not the name the server has, and no request can carry that one.
                    FileRowView(item: item, showPermissions: true)
                        .selectionDisabled()
                        .help("This name is not valid UTF-8, so it cannot be sent back to the server exactly. Rename the file on the server to work with it here.")
                }
                }
                .filePanelRow()
            }
            .filePanelList()
            .onDeleteCommand {
                viewModel.beginDelete(selectedItems)
            }
        }
    }

    @ViewBuilder
    private func itemActions(_ item: SFTPItem, selection: [SFTPItem], listingIsCurrent: Bool,
                             includesDownload: Bool = true) -> some View {
        let targets = viewModel.selectedRemoteItems.contains(item.id) ? selection : [item]
        // Only while the rows are the contents of the path in the bar: while another folder
        // loads they are not, and every command but copying the path is off. (A row that has
        // a menu is one of the rows shown; the view model checks again when a command runs.)
        let isShown = listingIsCurrent && item.isNameRepresentable
        Group {
            Button(item.isDirectory ? "Open" : "Edit in Default App") {
                Task { await viewModel.openRemote(item) }
            }
            if includesDownload {
                Button("Download") { viewModel.downloadToLocalFolder(targets) }
            }
            Divider()
            Button("Rename…") { viewModel.beginRename(item) }
            Button("Permissions…") { Task { await viewModel.beginPermissions(item) } }
        }
        .disabled(!isShown)
        Button("Copy Path") { viewModel.copyRemotePath(item) }
        Divider()
        Button("Delete", role: .destructive) { viewModel.beginDelete(targets) }
            .disabled(!isShown)
    }

    private func errorView(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(verbatim: error)
                .textSelection(.enabled)
        } actions: {
            Button("Retry") {
                Task { await viewModel.loadRemoteDirectory() }
            }
            .buttonStyle(.borderedProminent)
            Button("Home") { Task { await viewModel.navigateRemoteHome() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("Empty Folder", systemImage: "folder")
        } description: {
            Text("Drop files here to upload them.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared File Row

/// Column widths shared by the header and the rows of both panels.
private enum FileColumn {
    static let permissions: CGFloat = 66
    static let size: CGFloat = 68
    static let modified: CGFloat = 92
    static let modifiedCompact: CGFloat = 56
    static let spacing: CGFloat = DS.Space.md
    /// From the card's edge to the footer's text.
    static let inset: CGFloat = 16
    /// From the card's edge to a row's content: the inset the list gives its rows. The column
    /// titles, the rows' glyphs and the footer share this left edge.
    static let rowLeading: CGFloat = 16
    static let rowTrailing: CGFloat = 16
}

/// Which trailing columns of a file list fit its panel. A narrow panel drops the permissions
/// first, then shortens the modification date, then drops it, so the name always keeps a
/// readable width and the two panels show the same columns side by side for as long as possible.
struct FileColumnVisibility: Equatable {
    var permissions = true
    var modified = true
    /// The date without the time of day (and today's as the time alone).
    var compactDate = false

    var modifiedWidth: CGFloat { compactDate ? FileColumn.modifiedCompact : FileColumn.modified }

    static func fitting(_ width: CGFloat, hasPermissions: Bool) -> FileColumnVisibility {
        let spacing = FileColumn.spacing
        // Row insets, icon, size column and a name that is still worth reading.
        let always = FileColumn.rowLeading + FileColumn.rowTrailing + 20 + spacing + FileColumn.size + spacing + 90
        let room = width - always
        let permissionsCost = hasPermissions ? FileColumn.permissions + spacing : 0
        if room >= FileColumn.modified + spacing + permissionsCost {
            return FileColumnVisibility()
        }
        // The permissions go before the date gets shorter: both panels then show the same.
        if room >= FileColumn.modified + spacing {
            return FileColumnVisibility(permissions: false)
        }
        return FileColumnVisibility(permissions: false, modified: room >= FileColumn.modifiedCompact + spacing,
                                    compactDate: true)
    }
}

private struct FileColumnVisibilityKey: EnvironmentKey {
    static let defaultValue = FileColumnVisibility()
}

extension EnvironmentValues {
    var fileColumns: FileColumnVisibility {
        get { self[FileColumnVisibilityKey.self] }
        set { self[FileColumnVisibilityKey.self] = newValue }
    }
}

extension SFTPItem {
    /// The glyph of a row. One neutral family of sheets; only folders carry the accent, as in
    /// Finder — a list of files is not colour-coded by type.
    var rowSymbol: String {
        if isDirectory { return "folder.fill" }
        if isSymlink { return "arrow.up.right.square.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "part": return "arrow.down.doc.fill"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "tgz", "zst", "rar": return "doc.zipper"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "ico", "bmp", "tiff": return "photo.fill"
        case "txt", "md", "log", "conf", "cfg", "ini", "env", "csv": return "doc.text.fill"
        case "sh", "bash", "zsh", "swift", "py", "js", "ts", "rs", "go", "c", "cpp", "h", "java", "rb", "php",
             "json", "yml", "yaml", "xml", "toml", "html", "css", "sql":
            return "doc.plaintext.fill"
        default: return "doc.fill"
        }
    }
}

struct FileRowView: View {
    let item: SFTPItem
    var showPermissions: Bool = false
    @Environment(\.fileColumns) private var columns

    var body: some View {
        HStack(spacing: FileColumn.spacing) {
            HStack(spacing: 9) {
                Image(systemName: item.rowSymbol)
                    .font(.system(size: 15))
                    // One tone for every sheet: hierarchical layers differ from symbol to
                    // symbol, and a list of files then looks like it has dim and bright rows.
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(item.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text(verbatim: item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Hidden files and downloads still under way are quieter.
                    .foregroundStyle(item.name.hasPrefix(".") || item.name.hasSuffix(".part") ? .secondary : .primary)
                    .layoutPriority(1)

                if item.isSymlink {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .help("Link")
                        .accessibilityLabel(Text("Link"))
                }

                if !item.isNameRepresentable {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Name is not valid UTF-8")
                }

                Spacer(minLength: 0)
            }

            Text(verbatim: item.displaySize)
                .monospacedDigit()
                .foregroundStyle(item.isDirectory ? .tertiary : .secondary)
                .frame(width: FileColumn.size, alignment: .trailing)

            if columns.modified {
                TimelineView(.everyMinute) { context in
                    Text(verbatim: item.modified.map {
                        SFTPItem.modifiedText($0, now: context.date, compact: columns.compactDate)
                    } ?? "")
                }
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: columns.modifiedWidth, alignment: .leading)
                .help(Text(verbatim: item.modified.map { DisplayDateFormatter.mediumDateShortTime.string(from: $0) } ?? ""))
            }

            if showPermissions && columns.permissions {
                Text(verbatim: item.permissionBits)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: FileColumn.permissions, alignment: .leading)
                    .help(item.owner.isEmpty ? "" : "\(item.owner):\(item.group)")
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        // Reads as unavailable, like a disabled control.
        .opacity(item.isNameRepresentable ? 1 : 0.5)
    }
}

/// Column titles above a file list (same metrics as `FileRowView`).
struct FileListHeader: View {
    var showPermissions = false
    @Environment(\.fileColumns) private var columns

    var body: some View {
        HStack(spacing: FileColumn.spacing) {
            Text("Name")
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Size")
                .frame(width: FileColumn.size, alignment: .trailing)
            if columns.modified {
                Text("Modified")
                    .frame(width: columns.modifiedWidth, alignment: .leading)
            }
            if showPermissions && columns.permissions {
                Text("Permissions")
                    .frame(width: FileColumn.permissions, alignment: .leading)
            }
        }
        .font(DS.Font.sectionHeader)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.leading, FileColumn.rowLeading)
        .padding(.trailing, FileColumn.rowTrailing)
        .frame(height: 26)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityHidden(true)
    }
}

extension View {
    /// The list of a file panel: on the card, 30 pt rows, no separators.
    func filePanelList() -> some View {
        listStyle(.inset)
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .environment(\.defaultMinListRowHeight, 30)
    }

    func filePanelRow() -> some View {
        listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    /// A file panel is one card of the content layer.
    func filePanelCard() -> some View {
        clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCard()
    }
}

// MARK: - Shared panel chrome

/// The choices behind a panel's name (the remote panel: the hosts to switch to).
struct FilePanelTitleMenu {
    struct Item: Identifiable {
        let id: String
        let title: String
        let action: () -> Void
    }

    var items: [Item]
    var isDisabled = false
    var help: LocalizedStringKey
}

/// Head of a file panel: whose files these are (tile, name, address) and the panel's actions.
struct FilePanelHeader<Icon: View, Actions: View>: View {
    let title: String
    let subtitle: String
    /// The subtitle is an address (monospaced).
    var isAddress = false
    /// The jump host the connection goes through.
    var jump: String?
    /// The name opens this menu (and carries a small chevron).
    var titleMenu: FilePanelTitleMenu?
    @ViewBuilder var icon: Icon
    @ViewBuilder var actions: Actions

    /// The gap after the name plus the chevron's own width.
    private static var titleChevronRoom: CGFloat { 14 }

    var body: some View {
        HStack(spacing: DS.Space.card) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let titleMenu {
                        Menu {
                            // Not a disabled menu: its label is the panel's title, which must
                            // not go grey. The menu says why there is nothing to choose.
                            if titleMenu.isDisabled {
                                Button {} label: { Text(titleMenu.help) }
                                    .disabled(true)
                            } else {
                                ForEach(titleMenu.items) { item in
                                    Button(action: item.action) {
                                        Text(verbatim: item.title)
                                    }
                                }
                            }
                        } label: {
                            // The name alone: a chevron inside the label was a second menu
                            // button to accessibility (the name, and an 8 × 5 pt one). It is
                            // drawn over the room kept free at the label's end instead.
                            Text(verbatim: title)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .padding(.trailing, Self.titleChevronRoom)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .overlay(alignment: .trailing) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        // As high as its text, as wide as there is room: a long name is cut
                        // like any other panel title, it does not push the actions out.
                        .fixedSize(horizontal: false, vertical: true)
                        .help(titleMenu.help)
                        .accessibilityLabel(Text(verbatim: title))
                        .accessibilityHint(Text(titleMenu.help))
                        .layoutPriority(1)
                    } else {
                        Text(verbatim: title)
                            .font(.system(size: 15, weight: .bold))
                            .layoutPriority(1)
                    }
                    if let jump {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text("via \(jump)")
                                .font(DS.Font.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(verbatim: subtitle)
                    .font(isAddress ? .system(size: 11, design: .monospaced) : DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: DS.Space.xs)
            actions
        }
        .padding(.leading, FileColumn.inset)
        .padding(.trailing, DS.Space.md)
        .frame(height: 56)
    }
}

/// Navigation buttons, the path as steps and refresh of a file panel. A click beside the steps
/// (or the shortcut) turns them into a field to type a path in; Return opens it, Esc gives up.
struct FilePathBar<Navigation: View>: View {
    @Binding var path: String
    let crumbs: SFTPBreadcrumbs
    /// Stands for the root when the path does not start at home.
    var rootSymbol = "externaldrive"
    var isLoading = false
    var editShortcut: KeyboardShortcut?
    @ViewBuilder var navigation: Navigation
    /// A step was clicked.
    let onOpen: (String) -> Void
    let onSubmit: () -> Void
    /// Editing ended without a path being opened: the field goes back to where the panel is.
    let onCancel: () -> Void
    let onRefresh: () -> Void

    @State private var isEditing = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            navigation

            Group {
                if isEditing {
                    TextField("Path", text: $path)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        // Not in onAppear: the field is not in the window yet, the request was
                        // dropped and the field came up without the insertion point (typing
                        // went to the file list). After ⌘L even the next turn of the run loop
                        // is too early — AppKit is still handling the key.
                        .task {
                            try? await Task.sleep(for: .milliseconds(80))
                            fieldFocused = true
                        }
                        .onSubmit {
                            onSubmit()
                            isEditing = false
                        }
                        .onExitCommand { endEditing() }
                        .onChange(of: fieldFocused) { _, focused in
                            if !focused, isEditing { endEditing() }
                        }
                } else {
                    steps
                }
            }
            .padding(.horizontal, DS.Space.md)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.chip, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .onTapGesture {
                if !isEditing { isEditing = true }
            }
            // A long path runs out of the bar; hovering shows all of it.
            .help(Text(verbatim: path))
            .padding(.horizontal, DS.Space.xs)
            .background {
                if let editShortcut {
                    Button("Edit Path") { isEditing = true }
                        .keyboardShortcut(editShortcut)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }

            // One slot for the refresh button and the spinner: the path bar keeps its width
            // while a folder loads.
            ZStack {
                DSRowButton("arrow.clockwise", help: "Refresh", action: onRefresh)
                    .opacity(isLoading ? 0 : 1)
                    .disabled(isLoading)
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, DS.Space.card)
        .frame(height: 30)
        .padding(.bottom, DS.Space.card)
    }

    private func endEditing() {
        isEditing = false
        onCancel()
    }

    /// The steps in a row; a path too long for the bar scrolls, with its end in view (where
    /// we are is at the end).
    private var steps: some View {
        ViewThatFits(in: .horizontal) {
            stepRow
            ScrollView(.horizontal, showsIndicators: false) {
                stepRow
            }
            .defaultScrollAnchor(.trailing)
        }
    }

    private var stepRow: some View {
        HStack(spacing: DS.Space.xs) {
            Button {
                onOpen(crumbs.rootPath)
            } label: {
                Image(systemName: crumbs.startsAtHome ? "house" : rootSymbol)
                    .foregroundStyle(crumbs.steps.isEmpty ? .primary : .secondary)
            }
            .help(Text(verbatim: crumbs.rootPath))
            .accessibilityLabel(Text(verbatim: crumbs.rootPath))
            ForEach(Array(crumbs.steps.enumerated()), id: \.offset) { index, step in
                Image(systemName: "chevron.compact.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                let isLast = index == crumbs.steps.count - 1
                Button {
                    onOpen(step.path)
                } label: {
                    Text(verbatim: step.title)
                        .fontWeight(isLast ? .semibold : .regular)
                        .foregroundStyle(isLast ? .primary : .secondary)
                }
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// The line under a file list: how many items, how much, and the same of the selection.
struct FilePanelFooter: View {
    /// Nil while there is no listing to count (the directory could not be read): the strip
    /// stays, empty.
    let summary: SFTPListingSummary?

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            if let summary {
                Text(verbatim: Self.text(count: summary.count, bytes: summary.bytes))
                if summary.selectedCount > 0 {
                    Text(verbatim: "·")
                        .foregroundStyle(.tertiary)
                    Text(verbatim: Self.selectionText(count: summary.selectedCount, bytes: summary.selectedBytes))
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(DS.Font.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, FileColumn.inset)
        .frame(height: 32)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityHidden(summary == nil)
    }

    static func text(count: Int, bytes: Int64) -> String {
        let items = String(localized: "\(count) items")
        guard bytes > 0 else { return items }
        return items + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func selectionText(count: Int, bytes: Int64) -> String {
        let selected = String(localized: "\(count) selected")
        guard bytes > 0 else { return selected }
        return selected + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Shown while a drag hovers over a panel: an accent ring and where the drop goes.
struct FileDropHighlight: View {
    let label: Text

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        shape
            .strokeBorder(.tint, lineWidth: 2)
            .background(Color.accentColor.opacity(0.06), in: shape)
            .overlay {
                label
                    .font(DS.Font.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, DS.Space.lg)
                    .frame(height: DS.Height.control)
                    .background(.regularMaterial, in: Capsule(style: .continuous))
                    .padding(DS.Space.lg)
            }
            .allowsHitTesting(false)
    }
}
