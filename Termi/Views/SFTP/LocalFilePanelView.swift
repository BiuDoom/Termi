import SwiftUI

/// Local file browser panel for SFTP
struct LocalFilePanelView: View {
    @Bindable var viewModel: SFTPViewModel
    @State private var pathInput = ""
    @State private var isDropTarget = false
    @State private var columns = FileColumnVisibility()

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            pathBar
            fileList
            FilePanelFooter(summary: SFTPListingSummary(items: viewModel.visibleLocalItems,
                                                        selection: viewModel.selectedLocalItems))
        }
        .filePanelCard()
        .overlay {
            if isDropTarget {
                FileDropHighlight(label: Text("Download to \((viewModel.localPath as NSString).abbreviatingWithTildeInPath)"))
            }
        }
        // Remote items dragged from the other panel → download here.
        .dropDestination(for: String.self) { payloads, _ in
            viewModel.downloadDragged(payloads)
        } isTargeted: { isDropTarget = $0 }
        .onGeometryChange(for: FileColumnVisibility.self) { proxy in
            .fitting(proxy.size.width, hasPermissions: false)
        } action: { columns = $0 }
        .environment(\.fileColumns, columns)
        .onAppear { pathInput = viewModel.localPath }
        .onChange(of: viewModel.localPath) { _, newValue in pathInput = newValue }
    }

    private var selectedItems: [SFTPItem] { viewModel.selectedLocal }

    private var panelHeader: some View {
        // The account on this Mac, as the remote panel has the account on the host.
        FilePanelHeader(title: DSOperatingSystem.local.name, subtitle: SFTPViewModel.localAccount,
                        isAddress: true) {
            DSHostAvatar.local(size: 32)
        } actions: {
            Button {
                viewModel.uploadSelected()
            } label: {
                Label("Upload", systemImage: "arrow.up.to.line")
            }
            .dsButtonStyle(.glass)
            .disabled(selectedItems.isEmpty || !viewModel.remoteListingIsCurrent)
            .help(selectedItems.isEmpty ? "Select files to upload" : "Upload to the remote folder")

            // (Hidden files are the toolbar's switch, for both panels.)
            DSGlassIconButton("arrow.up.forward.app", help: "Reveal in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: viewModel.localPath))
            }
        }
    }

    private var pathBar: some View {
        let crumbs = SFTPBreadcrumbs(path: viewModel.localPath, home: NSHomeDirectory())
        return FilePathBar(path: $pathInput, crumbs: crumbs, rootSymbol: "internaldrive") {
            DSRowButton("chevron.up", help: "Enclosing folder") {
                viewModel.navigateLocalUp()
            }
            .disabled(viewModel.localPath == "/")

            // Below home the path starts with the house, which goes there: a second one next
            // to it only while the path is somewhere else.
            if !crumbs.startsAtHome {
                DSRowButton("house", help: "Home folder") {
                    viewModel.navigateLocal(toPath: NSHomeDirectory())
                }
            }
        } onOpen: { path in
            viewModel.navigateLocal(toPath: path)
        } onSubmit: {
            viewModel.navigateLocal(toPath: pathInput)
            // Refused (no such folder): the bar shows where we are, as on the remote side.
            if (pathInput as NSString).expandingTildeInPath != viewModel.localPath { NSSound.beep() }
            pathInput = viewModel.localPath
        } onCancel: {
            pathInput = viewModel.localPath
        } onRefresh: {
            viewModel.loadLocalDirectory()
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            FileListHeader()
            List(viewModel.visibleLocalItems, selection: $viewModel.selectedLocalItems) { item in
                FileRowView(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        viewModel.navigateLocal(to: item)
                    }
                    .draggable(URL(fileURLWithPath: item.path))
                    .contextMenu {
                        let targets = viewModel.selectedLocalItems.contains(item.id) ? selectedItems : [item]
                        Button("Upload") {
                            viewModel.uploadToRemoteFolder(targets.map { URL(fileURLWithPath: $0.path) })
                        }
                        .disabled(!viewModel.remoteListingIsCurrent)
                        Button("Reveal in Finder") { viewModel.revealLocal(item) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { viewModel.deleteLocalItems(targets) }
                    }
                    .filePanelRow()
            }
            .filePanelList()
        }
    }
}
