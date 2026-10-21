import SwiftUI
import os.log

/// ViewModel for code snippet management
@Observable
@MainActor
final class SnippetsViewModel {
    private let dataGeneration: UUID

    init(dataGeneration: UUID = DataSnapshot.current) {
        self.dataGeneration = dataGeneration
    }

    private let logger = Logger(subsystem: "dev.termi.Termi", category: "SnippetsVM")
    private let repo = SnippetRepository.shared

    var snippets: [Snippet] = []
    var categories: [String] = []
    var selectedCategory: String?
    var searchText = ""
    var isLoading = false
    /// True once the first `loadSnippets()` is over (the page draws nothing before that).
    private(set) var hasLoaded = false
    var error: String?

    // Edit state
    var showingForm = false
    var editingSnippet: Snippet?
    var showingDeleteConfirm = false
    var snippetToDelete: Snippet?
    /// The snippet "Add" just created, until the page has selected it.
    var addedSnippetId: Int64?

    var filteredSnippets: [Snippet] {
        var result = snippets
        if let cat = selectedCategory {
            result = result.filter { $0.category == cat }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(q) ||
                $0.command.lowercased().contains(q) ||
                ($0.description?.lowercased().contains(q) ?? false)
            }
        }
        return result
    }

    func loadSnippets() async {
        isLoading = true
        do {
            let fetched = try await repo.fetchAll()
            // The first fill just appears; later changes (a snippet added or deleted) animate.
            if hasLoaded { withAnimation(DS.Motion.standard) { snippets = fetched } } else { snippets = fetched }
            categories = try await repo.categories()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
        hasLoaded = true
    }

    func save(_ snippet: Snippet) async {
        await DataSnapshot.$expected.withValue(dataGeneration) { await saveCurrent(snippet) }
    }

    private func saveCurrent(_ snippet: Snippet) async {
        do {
            try DataSnapshot.check(dataGeneration)
            let saved = try await repo.save(snippet)
            await loadSnippets()
            // A new snippet becomes the page's selection (set after the list holds it).
            if snippet.id == nil { addedSnippetId = saved.id }
            NotificationCenter.default.post(name: .dsDataChanged, object: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteSnippet(_ snippet: Snippet) async {
        await DataSnapshot.$expected.withValue(dataGeneration) { await deleteCurrentSnippet(snippet) }
    }

    private func deleteCurrentSnippet(_ snippet: Snippet) async {
        guard let id = snippet.id else { return }
        do {
            try DataSnapshot.check(dataGeneration)
            try await repo.delete(id: id)
            await loadSnippets()
            NotificationCenter.default.post(name: .dsDataChanged, object: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyCommand(_ snippet: Snippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.command, forType: .string)
    }

    func addNew() {
        editingSnippet = nil
        showingForm = true
    }

    func edit(_ snippet: Snippet) {
        editingSnippet = snippet
        showingForm = true
    }

    // MARK: - Sections

    /// The filtered snippets as the master list shows them.
    var sections: [Section] {
        Self.sections(of: filteredSnippets)
    }

    /// How many snippets a category holds (for its filter).
    func count(inCategory category: String) -> Int {
        snippets.filter { $0.category == category }.count
    }

    /// The count a section's header shows: none when the category's filter already says the
    /// same number right above the list.
    func headerCount(for section: Section) -> Int? {
        Self.headerCount(shown: section.snippets.count,
                         filterCount: section.title.map { count(inCategory: $0) })
    }
}

extension SnippetsViewModel {
    /// The snippets of one category; `title` is nil for those without one.
    struct Section: Identifiable, Equatable {
        let title: String?
        let snippets: [Snippet]

        var id: String { title ?? "" }

        static func == (lhs: Section, rhs: Section) -> Bool {
            lhs.title == rhs.title && lhs.snippets.map(\.id) == rhs.snippets.map(\.id)
        }
    }

    /// By category, categories in alphabetical order, snippets in the order given; the ones
    /// without a category last.
    nonisolated static func sections(of snippets: [Snippet]) -> [Section] {
        var byCategory: [String: [Snippet]] = [:]
        var uncategorized: [Snippet] = []
        for snippet in snippets {
            if let category = snippet.category, !category.isEmpty {
                byCategory[category, default: []].append(snippet)
            } else {
                uncategorized.append(snippet)
            }
        }
        var sections = byCategory.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { Section(title: $0, snippets: byCategory[$0] ?? []) }
        if !uncategorized.isEmpty {
            sections.append(Section(title: nil, snippets: uncategorized))
        }
        return sections
    }

    /// `filterCount`: what the section's filter chip shows (nil: it has no chip of its own).
    nonisolated static func headerCount(shown: Int, filterCount: Int?) -> Int? {
        shown == filterCount ? nil : shown
    }

    /// "Run In" lists the sessions only when there is a choice to make: with one session the
    /// header's Run already goes there.
    nonisolated static func showsRunTargets(sessionCount: Int) -> Bool {
        sessionCount > 1
    }

    /// Whether the list has to drop its search and category filter to show a snippet: only
    /// when the snippet exists and they hide it.
    nonisolated static func filtersHide(_ id: Int64, shown: [Int64], all: [Int64]) -> Bool {
        all.contains(id) && !shown.contains(id)
    }

    /// The first line of a command, for a one-line row.
    nonisolated static func firstLine(of command: String) -> String {
        let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }
}
