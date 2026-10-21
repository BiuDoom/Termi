import SwiftUI

/// Keyboard shortcuts reference (⌘/): the shortcuts of the menus, grouped by area.
/// Modifiers are written in the system's order (⌃⌥⇧⌘), as the menus show them.
struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                row("Command Palette", "⌘K")
                row("Quick Connect", "⇧⌘N")
                row("Show Host Details", "⌘I")
                row("Keyboard Shortcuts", "⌘/")
                row("Lock App", "⇧⌘L")
                row("Settings", "⌘,")
                row("Quit", "⌘Q")
            } header: {
                // A sheet has no title bar: the first header carries the sheet's title.
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    DSSheetTitle("Keyboard Shortcuts")
                    Text("General")
                }
            }

            Section("Tabs") {
                row("New Terminal Tab", "⌘T")
                row("New Window", "⌘N")
                row("Close Tab or Pane", "⌘W")
                row("Close Window", "⇧⌘W")
                row("Select Tab 1–9", "⌘1", "⌘9")
                row("Select Previous Tab", "⌘[")
                row("Select Next Tab", "⌘]")
            }

            Section("Panes") {
                row("Split Right", "⌘D")
                row("Split Down", "⇧⌘D")
                row("Next Pane", "⌥⌘]")
                row("Previous Pane", "⌥⌘[")
                row("Broadcast Input to All Panes", "⇧⌘B")
            }

            Section("Terminal") {
                row("Snippets", "⇧⌘S")
                row("Open SFTP for Host", "⇧⌘O")
                row("Reconnect", "⇧⌘R")
                row("Clear Buffer", "⌥⌘K")
                row("Increase Font Size", "⌘=")
                row("Decrease Font Size", "⌘-")
                row("Reset Font Size", "⌘0")
            }

            Section("Find") {
                row("Find…", "⌘F")
                row("Find Next", "⌘G")
                row("Find Previous", "⇧⌘G")
            }

            Section("Tools") {
                row("Refresh", "⌘R")
                row("Run Batch Command", "⌘↩")
            }

            Section("Editing") {
                row("Copy", "⌘C")
                row("Paste", "⌘V")
                row("Select All", "⌘A")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onExitCommand { dismiss() }
    }

    // MARK: - Row

    /// Description on the leading side, key caps on the trailing side. Two caps are the ends
    /// of a range (⌘1 – ⌘9).
    private func row(_ title: LocalizedStringKey, _ keys: String...) -> some View {
        LabeledContent {
            HStack(spacing: DS.Space.xs) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    if index > 0 {
                        Text(verbatim: "–")
                            .foregroundStyle(.tertiary)
                    }
                    DSShortcut(key)
                }
            }
        } label: {
            Text(title)
        }
    }
}
