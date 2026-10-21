import Testing
import Foundation
@testable import Termi

// The logic behind the terminal status bar, the inspector and the SFTP panels: the session clock,
// path steps, the footers' totals, the transfer bar's summary, dates in the file list, which
// columns fit, snippets by category.

private func file(_ name: String, size: Int64 = 0, directory: Bool = false, permissions: String = "-rw-r--r--",
                  in folder: String = "/srv") -> SFTPItem {
    SFTPItem(name: name, path: folder + "/" + name, isDirectory: directory, size: size, permissions: permissions,
             owner: "", group: "", modified: nil)
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    utcCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
}

// MARK: - Session clock

@Test func elapsedTextHasFixedFields() {
    #expect(TerminalSession.elapsedText(seconds: 0) == "00:00:00")
    #expect(TerminalSession.elapsedText(seconds: 724) == "00:12:04")
    #expect(TerminalSession.elapsedText(seconds: 10_859) == "03:00:59")
    // More than a day keeps counting hours; a clock that went backwards shows zero.
    #expect(TerminalSession.elapsedText(seconds: 360_000) == "100:00:00")
    #expect(TerminalSession.elapsedText(seconds: -5) == "00:00:00")
}

// MARK: - Path steps

@Test func breadcrumbsStartAtTheRoot() {
    let crumbs = SFTPBreadcrumbs(path: "/home/deploy/app", home: nil)
    #expect(!crumbs.startsAtHome)
    #expect(crumbs.rootPath == "/")
    #expect(crumbs.steps.map(\.title) == ["home", "deploy", "app"])
    #expect(crumbs.steps.map(\.path) == ["/home", "/home/deploy", "/home/deploy/app"])
    #expect(SFTPBreadcrumbs(path: "/", home: nil).steps.isEmpty)
}

@Test func breadcrumbsBelowHomeStartAtHome() {
    let crumbs = SFTPBreadcrumbs(path: "/Users/me/Projects/web", home: "/Users/me")
    #expect(crumbs.startsAtHome)
    #expect(crumbs.rootPath == "/Users/me")
    #expect(crumbs.steps.map(\.title) == ["Projects", "web"])
    #expect(crumbs.steps.map(\.path) == ["/Users/me/Projects", "/Users/me/Projects/web"])

    let home = SFTPBreadcrumbs(path: "/Users/me", home: "/Users/me")
    #expect(home.startsAtHome)
    #expect(home.steps.isEmpty)
}

@Test func breadcrumbsOutsideHomeStartAtTheRoot() {
    // "/Users/meadow" is not below "/Users/me".
    let crumbs = SFTPBreadcrumbs(path: "/Users/meadow/x", home: "/Users/me")
    #expect(!crumbs.startsAtHome)
    #expect(crumbs.steps.map(\.title) == ["Users", "meadow", "x"])
    // A home of "/" is the root, not a house.
    #expect(!SFTPBreadcrumbs(path: "/etc", home: "/").startsAtHome)
}

@Test func breadcrumbsSplitByBytes() {
    // A combining accent right after a "/" forms one character with it: split on characters, the
    // step "b" + accent would be glued to "a".
    let path = "/a/\u{0301}b/c"
    let crumbs = SFTPBreadcrumbs(path: path, home: nil)
    #expect(crumbs.steps.count == 3)
    #expect(Array(crumbs.steps[1].title.utf8) == Array("\u{0301}b".utf8))
    #expect(Array(crumbs.steps[2].path.utf8) == Array(path.utf8))
    // Doubled and trailing slashes add no steps.
    #expect(SFTPBreadcrumbs(path: "/a//b/", home: nil).steps.map(\.title) == ["a", "b"])
}

// MARK: - Footer totals

@Test func listingSummaryCountsItemsAndBytes() {
    let items = [file("dir", size: 4096, directory: true), file("a.txt", size: 6), file("big.bin", size: 1000)]
    let all = SFTPListingSummary(items: items, selection: [])
    #expect(all.count == 3)
    // A folder's own size says nothing about what is in it.
    #expect(all.bytes == 1006)
    #expect(all.selectedCount == 0)

    let some = SFTPListingSummary(items: items, selection: [items[0].id, items[2].id])
    #expect(some.selectedCount == 2)
    #expect(some.selectedBytes == 1000)
    // A selection that names a row no longer shown counts nothing.
    let gone = SFTPListingSummary(items: items, selection: [file("other").id])
    #expect(gone.selectedCount == 0)
}

@Test func permissionBitsDropTheTypeCharacter() {
    #expect(file("a", permissions: "-rw-r--r--").permissionBits == "rw-r--r--")
    #expect(file("d", permissions: "drwxr-xr-x").permissionBits == "rwxr-xr-x")
    // A server that sent none, or something else, is shown as it is.
    #expect(file("x", permissions: "").permissionBits == "")
    #expect(file("x", permissions: "rwx").permissionBits == "rwx")
}

// MARK: - Transfer bar

@Test func transferSummaryAddsUpRunningTransfers() {
    var first = TransferItem(name: "a", direction: .download, totalBytes: 100)
    first.transferredBytes = 50
    var second = TransferItem(name: "b", direction: .upload, totalBytes: 300)
    second.transferredBytes = 150
    var done = TransferItem(name: "c", direction: .upload, totalBytes: 10)
    done.state = .completed
    var failed = TransferItem(name: "d", direction: .upload, totalBytes: 10)
    failed.state = .failed("no")

    let summary = TransferSummary([first, second, done, failed])
    #expect(summary.running == 2)
    #expect(summary.finished == 2)
    #expect(summary.fraction == 0.5)
    #expect(TransferQueueView.percentText(summary) == "50")
}

@Test func transferSummaryWithoutAKnownSize() {
    // Nothing running, or a folder whose size is still being counted: no percentage.
    #expect(TransferSummary([]).fraction == nil)
    #expect(TransferQueueView.percentText(TransferSummary([])) == "—")
    let counting = TransferItem(name: "dir", direction: .download, totalBytes: 0)
    #expect(TransferSummary([counting]).fraction == nil)
    #expect(TransferSummary([counting]).running == 1)

    // More reported than the total (a file that grew): never past 100 %.
    var over = TransferItem(name: "log", direction: .download, totalBytes: 10)
    over.transferredBytes = 25
    #expect(TransferSummary([over]).fraction == 1)
}

@Test func secondsLeftNeedsASpeedAndATotal() {
    var transfer = TransferItem(name: "a", direction: .download, totalBytes: 1000)
    transfer.startedAt = Date().addingTimeInterval(-10)
    #expect(transfer.secondsLeft == nil)
    transfer.transferredBytes = 500
    let left = transfer.secondsLeft ?? 0
    #expect(left > 9 && left < 11)
    transfer.state = .completed
    #expect(transfer.secondsLeft == nil)
}

// MARK: - Dates in the file list

@Test func modifiedTextIsShortForToday() {
    let calendar = utcCalendar()
    let locale = Locale(identifier: "en_US_POSIX")
    let now = date(2026, 10, 4, 22, 10)
    let today = SFTPItem.modifiedText(date(2026, 10, 4, 21, 40), now: now, calendar: calendar, locale: locale)
    #expect(today.contains("40"))
    #expect(!today.contains("Oct"))
    let earlier = SFTPItem.modifiedText(date(2026, 9, 30, 8, 5), now: now, calendar: calendar, locale: locale)
    #expect(earlier.contains("30"))
    #expect(!earlier.contains("2026"))
    #expect(!earlier.contains("05"))
    let lastYear = SFTPItem.modifiedText(date(2025, 9, 30), now: now, calendar: calendar, locale: locale)
    #expect(lastYear.contains("2025"))
}

@Test func modifiedTextCompactIsShorter() {
    let calendar = utcCalendar()
    let locale = Locale(identifier: "en_US_POSIX")
    let now = date(2026, 10, 4, 22, 10)
    let when = date(2026, 10, 4, 21, 40)
    let full = SFTPItem.modifiedText(when, now: now, calendar: calendar, locale: locale)
    let compact = SFTPItem.modifiedText(when, now: now, calendar: calendar, locale: locale, compact: true)
    #expect(compact.count < full.count)
    #expect(compact.contains("40"))
}

// MARK: - Columns

@Test func fileColumnsGiveWayInOrder() {
    #expect(FileColumnVisibility.fitting(640, hasPermissions: true) == FileColumnVisibility())
    // The permissions go first, then the date loses its time, then it goes too.
    let narrow = FileColumnVisibility.fitting(400, hasPermissions: true)
    #expect(!narrow.permissions && narrow.modified && !narrow.compactDate)
    let min = FileColumnVisibility.fitting(330, hasPermissions: true)
    #expect(!min.permissions && min.modified && min.compactDate)
    let tiny = FileColumnVisibility.fitting(240, hasPermissions: true)
    #expect(!tiny.modified)
    // Without a permissions column the local panel keeps its full date for longer.
    #expect(FileColumnVisibility.fitting(400, hasPermissions: false) == FileColumnVisibility())
}

// MARK: - Inspector

@Test func snippetsAreGroupedByCategory() {
    func snippet(_ name: String, _ category: String?) -> Snippet {
        Snippet(id: nil, name: name, command: name, category: category, sortOrder: 0, createdAt: "")
    }
    let sections = SnippetPanelView.sections(of: [
        snippet("a", "deploy"), snippet("b", nil), snippet("c", "logs"), snippet("d", "deploy"), snippet("e", "  ")
    ])
    // Those without a category first and without a title, then the categories as they first appear.
    #expect(sections.map(\.title) == [nil, "deploy", "logs"])
    #expect(sections.map { $0.snippets.map(\.name) } == [["b", "e"], ["a", "d"], ["c"]])
    #expect(SnippetPanelView.sections(of: []).isEmpty)
}

// MARK: - Regression audit

@Test func transferPercentRoundsDown() {
    // 99.9 % is not "100": the bar says 100 only when everything is through.
    var almost = TransferItem(name: "a", direction: .download, totalBytes: 1000)
    almost.transferredBytes = 999
    #expect(TransferQueueView.percentText(TransferSummary([almost])) == "99")
    almost.transferredBytes = 1000
    #expect(TransferQueueView.percentText(TransferSummary([almost])) == "100")
    // Finished transfers do not count towards the share of what is running.
    var done = TransferItem(name: "b", direction: .upload, totalBytes: 5000)
    done.transferredBytes = 5000
    done.state = .completed
    almost.transferredBytes = 250
    #expect(TransferQueueView.percentText(TransferSummary([done, almost])) == "25")
}

@Test func rowSymbolsAreOneNeutralFamily() {
    #expect(file("dir", directory: true).rowSymbol == "folder.fill")
    // A folder named like an archive is still a folder.
    #expect(file("backup.zip", directory: true).rowSymbol == "folder.fill")
    #expect(file("backup.ZIP").rowSymbol == "doc.zipper")
    #expect(file("notes.txt").rowSymbol == "doc.text.fill")
    #expect(file("big.bin.part").rowSymbol == "arrow.down.doc.fill")
    #expect(file("Makefile").rowSymbol == "doc.fill")
}

@Test func modifiedTextOfTodayDoesNotDependOnTheFormatterUsed() {
    // The user's own locale and calendar take the cached formatter, any other a fresh one:
    // both end with the time of day.
    let now = Date()
    let own = SFTPItem.modifiedText(now, now: now)
    let ownCompact = SFTPItem.modifiedText(now, now: now, compact: true)
    #expect(own.hasSuffix(ownCompact))
    #expect(own.count > ownCompact.count)
}

@Test func reconnectDelayIsPositive() {
    // The countdown ring divides by it.
    for attempt in 1...8 {
        #expect(TerminalSession.reconnectDelay(attempt: attempt) > 0)
    }
}
