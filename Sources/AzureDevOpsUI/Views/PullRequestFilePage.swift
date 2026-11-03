import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// A file of a pull request's change, in its details in place of their parts: what happened to it, and its diff, its
/// changes with a few lines around them and the rest folded, to unfold a few at a time or all at once, with the comment
/// threads on it at their lines (`ThreadCard`), and, above, those on the whole file or on lines of an earlier version,
/// with the code they were made on. ‹ and ›, or ⌥⌘↑ and ⌥⌘↓, go to the files before and after it; ⌃⌘↑ and ⌃⌘↓ through
/// its open threads, on to another file's. ⤢ makes the details fill the page beside the list, for long lines, and ⤡ brings
/// the list back. ↗ opens it in Azure DevOps. Its diff is read as it shows (`PullRequestFilesStore`).
struct PullRequestFilePage: View {
    @ObservedObject var details: PullRequestDetailsStore
    let item: PRSnapshot
    /// The pull request as the list read it last, whose change it reads; nil when the list has none.
    let pullRequest: PullRequest?
    let threads: PullRequestPanel.Threads
    /// Your identity ID, to ring your avatar.
    let me: String?
    let open: PullRequestDetailsStore.OpenFile
    /// Scrolls the details, which hold it, to a thread.
    let scroll: ScrollViewProxy

    @EnvironmentObject private var files: PullRequestFilesStore
    @EnvironmentObject private var code: PullRequestCodeStore
    @EnvironmentObject private var store: PRStore
    @Environment(\.detailsRoom) private var room
    @Environment(\.shownSection) private var section
    @Environment(\.shownWindow) private var window
    @Environment(\.isRendering) private var isRendering
    /// What it tells the store it is, so that the same file's page elsewhere goes on being read once this one goes.
    @LocalState private var viewer = UUID()
    /// The diff it asked for last, to let go of when it shows another.
    @LocalState private var shownVersion: PullRequestFilesStore.Version?
    /// The lines you unfolded, of the diff they're of.
    @LocalState private var revealed = IndexSet()
    @LocalState private var revealedOf: PullRequestFilesStore.Version?
    /// The thread you went to last, from which the next and the previous go; and the one pointed out for a moment.
    @LocalState private var current: Int?
    @LocalState private var highlighted: Int?
    /// The resolved threads you unfolded.
    @LocalState private var unfoldedResolved: Set<Int> = []

    /// How many rows of code one view draws at most: past that, the next view does, so that only those on screen are laid
    /// out.
    static let rowsPerView = 200

    /// The window's page it's on: nil outside one, where nothing is read.
    private var page: String? {
        guard let section, let window else { return nil }
        return PullRequestCodeStore.page(section, window: window)
    }

    /// What its files are read again for: a push, another change, and its window showing it again.
    private struct ListReading: Equatable {
        var visibilityChanges: Int
        var head: PullRequestFilesStore.Head?
        var scope: ChangeScope
    }

    var body: some View {
        let state = pullRequest.flatMap { files.list(of: $0.key, details.scope) }
        VStack(alignment: .leading, spacing: 14) {
            if let pullRequest, case .read(let changes)? = state, let file = changes.file(atPath: open.path) {
                let shown = Shown(file: file, changes: changes, threads: threads, diff: diff(of: file, in: changes, pullRequest))
                header(shown)
                content(shown, pullRequest)
                footer(shown)
            } else if case .read(let changes)? = state {
                gone(changes)
            } else if case .failed(let problem)? = state {
                headerPlaceholder
                notice(
                    "BriefBar can't list the pull request's files. " + (ThreadCode.sentence(for: problem) ?? problem.description),
                    symbol: "eye.slash", url: PullRequestFilesSection.filesPage(item),
                    again: ThreadCode.mayPass(problem) ? { pullRequest.map { files.showList(of: $0, scope: details.scope, on: page, again: true) } } : nil
                )
            } else {
                headerPlaceholder
                codePlaceholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // It asks for the whole page while it shows, once you made it fill it.
        .preference(key: DetailsFillsPageKey.self, value: details.fillsPage)
        .task(id: ListReading(
            visibilityChanges: code.visibilityChanges, head: pullRequest.map(PullRequestFilesStore.Head.init), scope: details.scope
        )) {
            guard let pullRequest else { return }
            // Asked for again every half minute, for what couldn't be read, which the store reads again then.
            while !Task.isCancelled {
                files.showList(of: pullRequest, scope: details.scope, on: page)
                try? await Task.sleep(for: .seconds(PullRequestCodeStore.retryInterval))
            }
        }
        // Its pull request's change is read, and kept, while it shows: in the panel's details, or on a pull request's page.
        .task(id: item.key) {
            let hold = code.hold(item.key)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
            }
            code.release(hold)
        }
        .onAppear { scrollToTop() }
        .onChange(of: open.id) {
            current = nil
            unfoldedResolved = []
            scrollToTop()
        }
        .onDisappear {
            if let shownVersion, let key = pullRequest?.key { files.hideDiff(shownVersion, of: key, by: viewer) }
        }
        .accessibilityElement(children: .contain)
    }

    private func diff(of file: FileChange, in changes: ChangedFiles, _ pullRequest: PullRequest) -> PullRequestFilesStore.State<FileDiff>? {
        files.diff(of: PullRequestFilesStore.Version(file, in: changes), in: pullRequest.key)
    }

    private func scrollToTop() {
        guard open.thread == nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            scroll.scrollTo(PullRequestDetailsStore.Anchor.top, anchor: .top)
        }
    }

    // MARK: What it shows

    /// The file as it shows: where it is among the change's files, and, once its diff is read, where each of its threads
    /// is: under the line it ends on, or apart, above the diff, for one on the whole file or on lines of a version the diff
    /// doesn't show.
    private struct Shown {
        var file: FileChange
        var changes: ChangedFiles
        var index: Int
        var diff: PullRequestFilesStore.State<FileDiff>?
        /// By the line they show under.
        var placed: [Int: [PullRequestPanel.Thread]] = [:]
        var apart: [PullRequestPanel.Thread] = []
        /// The lines its open threads are on.
        var marked = IndexSet()
        /// Its open threads, in the order it shows them, to go through.
        var openThreads: [Int] = []

        init(file: FileChange, changes: ChangedFiles, threads: PullRequestPanel.Threads, diff: PullRequestFilesStore.State<FileDiff>?) {
            self.file = file
            self.changes = changes
            index = changes.index(of: file.id) ?? 0
            self.diff = diff
            let onFile = threads.comments(on: file).threads
            guard case .read(let read)? = diff else {
                apart = onFile
                openThreads = onFile.filter(Self.isOpen).map(\.id)
                return
            }
            for thread in onFile {
                if let row = read.row(of: thread.thread, in: changes) {
                    placed[row, default: []].append(thread)
                    if Self.isOpen(thread), let rows = read.rows(of: thread.thread, in: changes) { marked.insert(integersIn: rows) }
                } else {
                    apart.append(thread)
                }
            }
            openThreads = apart.filter(Self.isOpen).map(\.id)
                + placed.keys.sorted().flatMap { placed[$0, default: []].filter(Self.isOpen).map(\.id) }
        }

        static func isOpen(_ thread: PullRequestPanel.Thread) -> Bool {
            thread.waitsOnYou || !thread.isResolved
        }

        var hasNext: Bool { index < changes.files.count - 1 }
        var hasPrevious: Bool { index > 0 }
    }

    // MARK: Header

    private func header(_ shown: Shown) -> some View {
        let file = shown.file
        let kind = FileKindStyle(file.kind)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: kind.symbol)
                    .font(size: 13, weight: .semibold)
                    .foregroundStyle(kind.color)
                    .accessibilityHidden(true)
                Text(file.name)
                    .font(size: 14.5, weight: .semibold)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(file.path)
                    .accessibilityAddTraits(.isHeader)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                fileNavigation(shown)
                roomButton
                Button {
                    AzureDevOps.open(shown.changes.filePageURL(of: file, in: item))
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(size: 12, weight: .medium)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Open this file's changes in Azure DevOps")
                .accessibilityLabel("Open in Azure DevOps")
            }
            FlowLayout(spacing: 8, lineSpacing: 4) {
                // "src · Edited", or the repository's name for a file at its top.
                Text([file.folder ?? pullRequest?.repositoryName, file.what].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if case .read(let diff)? = shown.diff, diff.counts.added > 0 || diff.counts.removed > 0 {
                    FileCountsText(counts: .success(diff.counts))
                }
                if details.scope != .whole {
                    Chip(text: "Since you last looked", color: ItemState.running.textColor)
                }
                // Its comments, and a way through the open ones, on to another file's.
                let comments = threads.comments(on: file)
                if !comments.isEmpty || shown.changes.files.contains(where: { threads.comments(on: $0).open > 0 }) {
                    commentNavigation(shown, comments)
                }
            }
            .font(size: 12)
        }
        .id(PullRequestDetailsStore.Anchor.top)
    }

    /// ‹ and ›, the files before and after it, and where it is among them, which lists them all to go to.
    private func fileNavigation(_ shown: Shown) -> some View {
        let files = shown.changes.files
        let previous = shown.hasPrevious ? files[shown.index - 1] : nil
        let next = shown.hasNext ? files[shown.index + 1] : nil
        return HStack(spacing: 0) {
            Button {
                if let previous { go(to: previous) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(size: 11.5, weight: .semibold)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(previous == nil)
            .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            .help(previous.map { "Previous file: \($0.name) (⌥⌘↑)" } ?? "This is the first file")
            .accessibilityLabel("Previous File")
            Menu {
                ForEach(files) { file in
                    Button {
                        go(to: file)
                    } label: {
                        Label(file.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), systemImage: FileKindStyle(file.kind).symbol)
                    }
                }
            } label: {
                Text(verbatim: "\(shown.index + 1) of \(files.count)")
                    .font(size: 11.5, weight: .medium).monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Go to another of the change's files")
            .accessibilityLabel("File \(shown.index + 1) of \(files.count)")
            Button {
                if let next { go(to: next) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(size: 11.5, weight: .semibold)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(next == nil)
            .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            .help(next.map { "Next file: \($0.name) (⌥⌘↓)" } ?? "This is the last file")
            .accessibilityLabel("Next File")
        }
    }

    /// ⤢, the whole page for the diff, beside the list; ⤡, the list beside it again.
    @ViewBuilder
    private var roomButton: some View {
        if room == .beside || room == .fillingPage {
            let fills = room == .fillingPage
            Button {
                withAnimation(isRendering ? nil : .easeOut(duration: 0.2)) { details.fillsPage = !fills }
            } label: {
                Image(systemName: fills ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(size: 11.5, weight: .medium)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(fills ? "Show the list beside the details again" : "Make the details fill the page, for long lines")
            .accessibilityLabel(fills ? "Show the List Again" : "Fill the Page")
        }
    }

    /// "2 open comments", or "No comments" on a file without any, and ⌃ ⌄, through the open ones, on to another file's.
    private func commentNavigation(_ shown: Shown, _ comments: PullRequestPanel.FileComments) -> some View {
        HStack(spacing: 2) {
            Image(systemName: comments.open > 0 ? "bubble.left.fill" : comments.isEmpty ? "bubble.left" : "checkmark.bubble")
                .font(size: 10, weight: .semibold)
                .foregroundStyle(comments.waitingOnYou > 0 ? AnyShapeStyle(ItemState.needsYou.textColor) : AnyShapeStyle(.secondary))
                .padding(.trailing, 3)
                .accessibilityHidden(true)
            Text(comments.spoken)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                goToComment(-1, shown)
            } label: {
                Image(systemName: "chevron.up")
                    .font(size: 10, weight: .semibold)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.upArrow, modifiers: [.control, .command])
            .help("Previous open comment (⌃⌘↑)")
            .accessibilityLabel("Previous Comment")
            Button {
                goToComment(1, shown)
            } label: {
                Image(systemName: "chevron.down")
                    .font(size: 10, weight: .semibold)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.downArrow, modifiers: [.control, .command])
            .help("Next open comment (⌃⌘↓)")
            .accessibilityLabel("Next Comment")
        }
    }

    private var headerPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(size: 13, weight: .semibold)
                .foregroundStyle(.secondary)
            Text((open.path as NSString).lastPathComponent)
                .font(size: 14.5, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .id(PullRequestDetailsStore.Anchor.top)
    }

    // MARK: Going places

    private func go(to file: FileChange) {
        withAnimation(.easeOut(duration: 0.15)) { details.open(file: file.path) }
    }

    /// The next open thread, or the previous, from the one you went to last; past the file's first or last, the next file's
    /// first, or the previous file's last, that has one.
    private func goToComment(_ step: Int, _ shown: Shown) {
        let ids = shown.openThreads
        let at = current.flatMap { ids.firstIndex(of: $0) }
        let target = at.map { $0 + step } ?? (step > 0 ? 0 : ids.count - 1)
        if ids.indices.contains(target) {
            reach(ids[target])
            return
        }
        let others = step > 0 ? Array(shown.changes.files.dropFirst(shown.index + 1))
            : Array(shown.changes.files.prefix(shown.index).reversed())
        for other in others {
            let open = threads.comments(on: other).threads.filter(Shown.isOpen).sorted { line(of: $0) < line(of: $1) }
            if let thread = step > 0 ? open.first : open.last {
                withAnimation(.easeOut(duration: 0.15)) { details.open(file: other.path, at: thread.id) }
                return
            }
        }
        NSSound.beep()
    }

    private func line(of thread: PullRequestPanel.Thread) -> Int {
        ThreadCode.span(of: thread.thread)?.lines.lowerBound ?? thread.thread.line ?? 0
    }

    /// Scrolls to a thread and points it out for a moment.
    private func reach(_ thread: Int) {
        current = thread
        withAnimation(isRendering ? nil : .easeOut(duration: 0.25)) {
            scroll.scrollTo(PullRequestDetailsStore.Anchor.thread(thread), anchor: .center)
        }
        withAnimation(isRendering ? nil : .easeOut(duration: 0.2)) { highlighted = thread }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if highlighted == thread {
                withAnimation(.easeOut(duration: 0.4)) { highlighted = nil }
            }
        }
    }

    // MARK: The diff

    /// What its diff is read again for: another file or version, and its window showing it again.
    private struct DiffReading: Equatable {
        var version: PullRequestFilesStore.Version
        var visibilityChanges: Int
    }

    @ViewBuilder
    private func content(_ shown: Shown, _ pullRequest: PullRequest) -> some View {
        let version = PullRequestFilesStore.Version(shown.file, in: shown.changes)
        VStack(alignment: .leading, spacing: 12) {
            switch shown.diff {
            case .read(let diff)?:
                if !shown.apart.isEmpty {
                    apartThreads(shown.apart, pullRequest)
                }
                diffView(diff, shown, version)
            case .failed(let problem)?:
                notice(
                    Self.sentence(for: problem), symbol: problem == .binary ? "photo" : "eye.slash",
                    url: shown.changes.filePageURL(of: shown.file, in: item),
                    again: ThreadCode.mayPass(problem)
                        ? { files.showDiff(of: shown.file, in: shown.changes, of: pullRequest, by: viewer, on: page, again: true) } : nil
                )
                if !shown.apart.isEmpty {
                    apartThreads(shown.apart, pullRequest)
                }
            case .reading?, nil:
                codePlaceholder
            }
        }
        .task(id: DiffReading(version: version, visibilityChanges: code.visibilityChanges)) {
            if let previous = shownVersion, previous != version { files.hideDiff(previous, of: pullRequest.key, by: viewer) }
            shownVersion = version
            guard code.isVisible(page) else {
                files.hideDiff(version, of: pullRequest.key, by: viewer)
                return
            }
            files.showDiff(of: shown.file, in: shown.changes, of: pullRequest, by: viewer, on: page)
        }
        // Asked to go to one of its threads, once it shows: also on another file whose diff was read already.
        .task(id: ThreadReaching(version: version, isRead: diffIsRead(shown), thread: open.thread)) {
            guard diffIsRead(shown), let thread = open.thread else { return }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            reach(thread)
            details.reachedThread(thread)
        }
    }

    /// What it goes to a thread again for: another file, its diff read, or another thread.
    private struct ThreadReaching: Equatable {
        var version: PullRequestFilesStore.Version
        var isRead: Bool
        var thread: Int?
    }

    private func diffIsRead(_ shown: Shown) -> Bool {
        if case .read? = shown.diff { return true }
        return false
    }

    /// Why its diff can't show, in a sentence.
    static func sentence(for problem: ThreadExcerpt.Problem) -> String {
        switch problem {
        case .binary: "This file isn't text, so BriefBar doesn't show its changes."
        case .tooLarge: "This file is longer than BriefBar reads, 1 MB, so it doesn't show its changes."
        default: "BriefBar can't show its changes. " + (ThreadCode.sentence(for: problem) ?? problem.description)
        }
    }

    /// A part of what it shows, by its place: lines of code, folded lines, or a thread.
    private enum Entry: Identifiable {
        case code(Range<Int>)
        case folded(Range<Int>)
        case thread(PullRequestPanel.Thread)

        /// A thread's is what the details scroll to.
        var id: AnyHashable {
            switch self {
            case .code(let range): AnyHashable("code \(range.lowerBound)")
            case .folded(let range): AnyHashable("folded \(range.lowerBound)")
            case .thread(let thread): AnyHashable(PullRequestDetailsStore.Anchor.thread(thread.id))
            }
        }
    }

    private func entries(_ blocks: [DiffLayout.Block], placed: [Int: [PullRequestPanel.Thread]]) -> [Entry] {
        var entries: [Entry] = []
        for block in blocks {
            switch block {
            case .folded(let range):
                entries.append(.folded(range))
            case .lines(let range):
                var start = range.lowerBound
                while start < range.upperBound {
                    let end = min(range.upperBound, start + Self.rowsPerView)
                    entries.append(.code(start..<end))
                    start = end
                }
                entries += (placed[range.upperBound - 1] ?? []).map(Entry.thread)
            }
        }
        return entries
    }

    private func diffView(_ diff: FileDiff, _ shown: Shown, _ version: PullRequestFilesStore.Version) -> some View {
        let revealed = revealedOf == version ? self.revealed : IndexSet()
        let blocks = DiffLayout.blocks(of: diff.lines, anchors: Array(shown.placed.keys), revealed: revealed, breaks: Set(shown.placed.keys))
        let digits = String(max(diff.lines.last { $0.oldNumber != nil }?.oldNumber ?? 0, diff.lines.last { $0.newNumber != nil }?.newNumber ?? 0)).count
        let showsOldNumbers = !shown.file.kind.contains(.add)
        return VStack(alignment: .leading, spacing: 6) {
            if diff.lines.isEmpty {
                Text("The file is empty.")
                    .font(size: 12)
                    .foregroundStyle(.secondary)
            } else if diff.counts.added == 0 && diff.counts.removed == 0 {
                Text("Its lines didn't change.")
                    .font(size: 12)
                    .foregroundStyle(.secondary)
            }
            if !diff.lines.isEmpty {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries(blocks, placed: shown.placed)) { entry in
                        switch entry {
                        case .code(let range):
                            CodeView(
                                rows: rows(diff, range, marked: shown.marked), showsOldNumbers: showsOldNumbers,
                                label: label(diff, range, shown.file), numberDigits: max(2, digits)
                            )
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                        case .folded(let range):
                            FoldedLines(range: range, isFirst: range.lowerBound == 0, isLast: range.upperBound == diff.lines.count) { unfold in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    self.revealed = DiffLayout.reveal(range, unfold, in: revealed)
                                    revealedOf = version
                                }
                            }
                        case .thread(let thread):
                            threadView(thread, showsCode: false)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                }
            }
        }
    }

    /// The rows of a run of the diff's lines, the lines its open threads are on marked, each cut where an excerpt's is.
    private func rows(_ diff: FileDiff, _ range: Range<Int>, marked: IndexSet) -> [CodeRow] {
        range.map { index in
            let line = diff.lines[index]
            let text = line.text.count > ThreadExcerpt.maxLineLength
                ? String(line.text.prefix(ThreadExcerpt.maxLineLength - 1)) + "…" : line.text
            return CodeRow(.line(line.kind), text, old: line.oldNumber, new: line.newNumber, isMarked: marked.contains(index))
        }
    }

    /// "Lines 12 to 40 of PaymentsClient.cs".
    private func label(_ diff: FileDiff, _ range: Range<Int>, _ file: FileChange) -> String {
        let numbers = diff.lines[range].compactMap { $0.newNumber ?? $0.oldNumber }
        guard let first = numbers.first, let last = numbers.last else { return "Code of \(file.name)" }
        return first == last ? "Line \(first) of \(file.name)" : "Lines \(first) to \(last) of \(file.name)"
    }

    /// The threads on the whole file, and those on lines of a version the diff doesn't show, with the code they were made on.
    private func apartThreads(_ threads: [PullRequestPanel.Thread], _ pullRequest: PullRequest) -> some View {
        let whole = threads.filter { !ThreadCode.isOnLines($0.thread) }
        let earlier = threads.filter { ThreadCode.isOnLines($0.thread) }
        return VStack(alignment: .leading, spacing: 8) {
            if !whole.isEmpty {
                apartHeading("On the Whole File")
                ForEach(whole) { thread in
                    threadView(thread, showsCode: false)
                        .id(PullRequestDetailsStore.Anchor.thread(thread.id))
                }
            }
            if !earlier.isEmpty {
                apartHeading("On an Earlier Version")
                    .help("Made on an update before the one this shows, and not followed to it since: with the code it was made on")
                ForEach(earlier) { thread in
                    threadView(thread, showsCode: true)
                        .id(PullRequestDetailsStore.Anchor.thread(thread.id))
                }
            }
        }
    }

    private func apartHeading(_ title: String) -> some View {
        Text(title)
            .font(size: 11.5, weight: .semibold)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    /// An open thread's card; a resolved one folded to a line, until you unfold it.
    @ViewBuilder
    private func threadView(_ thread: PullRequestPanel.Thread, showsCode: Bool) -> some View {
        if Shown.isOpen(thread) || unfoldedResolved.contains(thread.id) {
            ThreadCard(
                thread: thread, item: item, pullRequest: pullRequest, me: me, now: store.now, isHighlighted: highlighted == thread.id,
                showsCode: showsCode
            )
        } else {
            ResolvedThreadLine(thread: thread) {
                withAnimation(.easeOut(duration: 0.15)) { _ = unfoldedResolved.insert(thread.id) }
            }
        }
    }

    // MARK: Around it

    /// The files before and after it, at its end.
    @ViewBuilder
    private func footer(_ shown: Shown) -> some View {
        let files = shown.changes.files
        if shown.hasPrevious || shown.hasNext {
            HStack(spacing: 12) {
                if shown.hasPrevious {
                    let previous = files[shown.index - 1]
                    Button {
                        go(to: previous)
                    } label: {
                        Label("Previous: \(previous.name)", systemImage: "chevron.left")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(previous.path)
                }
                Spacer(minLength: 0)
                if shown.hasNext {
                    let next = files[shown.index + 1]
                    Button {
                        go(to: next)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Next: \(next.name)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.right")
                        }
                    }
                    .help(next.path)
                }
            }
            .buttonStyle(.borderless)
            .font(size: 12, weight: .medium)
            .padding(.top, 2)
        }
    }

    /// The file isn't among those of the change it shows: after a push, or since another update.
    private func gone(_ changes: ChangedFiles) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            headerPlaceholder
            Text(changes.scope == .whole ? "The pull request doesn't change this file anymore."
                : "This file didn't change since you last looked.")
                .font(size: 12.5)
                .foregroundStyle(.secondary)
            Button("Back to Its Files") {
                withAnimation(.easeOut(duration: 0.15)) { details.closeFile() }
            }
        }
    }

    /// Why something can't show, with ↗ to it in Azure DevOps, and Try Again when that may help.
    private func notice(_ sentence: String, symbol: String, url: URL, again: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(sentence, systemImage: symbol)
                .font(size: 12.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open in Azure DevOps") { AzureDevOps.open(url) }
                if let again {
                    Button("Try Again", action: again)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassCard(cornerRadius: 10, raised: true))
    }

    /// A few rows' worth, until its diff is read.
    private var codePlaceholder: some View {
        let widths: [CGFloat] = [0.5, 0.8, 0.35, 0.7, 0.6, 0.9, 0.45, 0.65, 0.3, 0.75]
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 300 * width, height: 7)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Reading the file's changes")
    }
}

/// Lines folded away between those a diff shows: how many, and buttons to show 20 more, down from the code above them or
/// up from the code below, or all of them.
private struct FoldedLines: View {
    let range: Range<Int>
    /// It's at the top of the file, with no code above it.
    let isFirst: Bool
    /// At the end, with none below.
    let isLast: Bool
    let unfold: (DiffLayout.Unfold) -> Void

    var body: some View {
        let count = range.count
        let step = DiffLayout.unfoldStep
        HStack(spacing: 6) {
            Image(systemName: "ellipsis")
                .font(size: 10, weight: .bold)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(count == 1 ? "1 unchanged line" : "\(count) unchanged lines")
                .font(size: 11.5)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if count > step {
                if !isLast {
                    button(symbol: "chevron.up", text: "\(step)", help: "Show \(step) more lines, up from the code below",
                           label: "Show \(step) Lines Above the Code Below") { unfold(.up(step)) }
                }
                if !isFirst {
                    button(symbol: "chevron.down", text: "\(step)", help: "Show \(step) more lines, down from the code above",
                           label: "Show \(step) Lines Below the Code Above") { unfold(.down(step)) }
                }
            }
            button(symbol: "arrow.up.and.down", text: "All", help: "Show all \(count) lines", label: "Show All \(count) Lines") {
                unfold(.all)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045))
        .accessibilityElement(children: .contain)
    }

    private func button(symbol: String, text: String, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(size: 9, weight: .bold)
                Text(text)
                    .font(size: 11, weight: .medium).monospacedDigit()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// A resolved thread on a file's page, folded to a line: how it stands, who said what first, and Show to unfold it.
private struct ResolvedThreadLine: View {
    let thread: PullRequestPanel.Thread
    let unfold: () -> Void

    var body: some View {
        Button(action: unfold) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.bubble")
                    .font(size: 10.5, weight: .medium)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(thread.status ?? "Resolved")
                    .font(size: 11.5, weight: .medium)
                    .foregroundStyle(.secondary)
                if let first = thread.comments.first {
                    Text("\(first.author.name): \(first.text)")
                        .font(size: 11.5)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Text("Show")
                    .font(size: 11.5, weight: .medium)
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this resolved thread")
        .accessibilityLabel("\(thread.status ?? "Resolved") thread" + (thread.comments.first.map { ", \($0.author.name): \($0.text)" } ?? ""))
        .accessibilityHint("Shows it")
    }
}
