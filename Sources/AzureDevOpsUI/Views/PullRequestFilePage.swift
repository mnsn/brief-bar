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
    /// VoiceOver goes to the file's name as its page opens, and as it goes to another file.
    @AccessibilityFocusState private var isNameFocused: Bool
    /// Its toolbar is at the details' top, where it stays as the code scrolls under it.
    @LocalState private var isToolbarPinned = false

    /// How many rows of code one view draws at most: past that, the next view does, so that only those on screen are laid
    /// out.
    static let rowsPerView = 200
    /// How wide a thread's card gets, on a page the details fill: as wide as reads well.
    static let widestThread: CGFloat = 720

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
        let state = pullRequest.flatMap { files.list(of: $0.key, open.scope) }
        let threadFile = threadFile(state)
        let shown: Shown? = if let pullRequest, case .read(let changes)? = state,
            let file = threadFile ?? changes.file(atPath: open.path) {
            Shown(file: file, changes: changes, threads: threads, diff: diff(of: file, in: changes, pullRequest))
        } else {
            nil
        }
        // Its toolbar stays at the top as its diff scrolls.
        LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
            Section {
                if let pullRequest, let shown {
                    heading(shown)
                    content(shown, pullRequest)
                    footer(shown)
                } else if case .read(let changes)? = state {
                    gone(changes)
                } else if case .failed(let problem)? = state {
                    headerPlaceholder
                    notice(
                        "BriefBar can't list the pull request's files. " + (ThreadCode.sentence(for: problem) ?? problem.description),
                        symbol: "eye.slash", url: PullRequestFilesSection.filesPage(item),
                        again: ThreadCode.mayPass(problem)
                            ? { pullRequest.map { files.showList(of: $0, scope: open.scope, on: page, again: true) } } : nil
                    )
                } else {
                    headerPlaceholder
                    codePlaceholder
                }
            } header: {
                if let shown {
                    toolbar(shown)
                }
            }
        }
        // Its top, over its toolbar, is where the details go as it opens.
        .id(PullRequestDetailsStore.Anchor.top)
        .frame(maxWidth: .infinity, alignment: .leading)
        // It asks for the whole page while it shows, once you made it fill it.
        .preference(key: DetailsFillsPageKey.self, value: details.fillsPage)
        .task(id: ListReading(
            visibilityChanges: code.visibilityChanges, head: pullRequest.map(PullRequestFilesStore.Head.init), scope: open.scope
        )) {
            guard let pullRequest else { return }
            // Asked for again every half minute, for what couldn't be read, which the store reads again then.
            while !Task.isCancelled {
                files.showList(of: pullRequest, scope: open.scope, on: page)
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
        // Opened at a thread on a file renamed since, whose old path another file took: the file it's on now, for good.
        .onChange(of: threadFile?.id, initial: true) {
            if let threadFile, threadFile.id != open.id { details.open(file: threadFile.path, at: open.thread) }
        }
        .onChange(of: open.id) {
            current = nil
            unfoldedResolved = []
            // For VoiceOver to go to the next file's name, though it was on this one's.
            isNameFocused = false
            scrollToTop()
        }
        .onDisappear {
            if let shownVersion, let key = pullRequest?.key { files.hideDiff(shownVersion, of: key, by: viewer) }
        }
        .accessibilityElement(children: .contain)
    }

    /// While it goes to a thread, the file Azure DevOps tracks it on, which the path it opened at may not be.
    private func threadFile(_ state: PullRequestFilesStore.State<ChangedFiles>?) -> FileChange? {
        guard case .read(let changes)? = state, let id = open.thread, let thread = threads.all.first(where: { $0.id == id })
        else { return nil }
        return changes.file(of: thread.thread)
    }

    private func diff(of file: FileChange, in changes: ChangedFiles, _ pullRequest: PullRequest) -> PullRequestFilesStore.State<FileDiff>? {
        files.diff(of: PullRequestFilesStore.Version(file, in: changes), in: pullRequest.key)
    }

    /// To its top, and VoiceOver to the file's name, unless it goes to one of its threads, which VoiceOver goes to then.
    private func scrollToTop() {
        guard open.thread == nil, open.comment == nil else { return }
        toTop()
    }

    private func toTop() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            scroll.scrollTo(PullRequestDetailsStore.Anchor.top, anchor: .top)
            try? await Task.sleep(for: .milliseconds(120))
            isNameFocused = true
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
        /// Those on the whole file first, then those on lines, as they show.
        var apart: [PullRequestPanel.Thread] = []
        /// The lines its open threads are on, on the side each is on.
        var marked = IndexSet()
        /// The lines the threads it places are on, all of which show.
        var spans = IndexSet()
        /// Its open threads, in the order it shows them, to go through.
        var openThreads: [Int] = []

        init(file: FileChange, changes: ChangedFiles, threads: PullRequestPanel.Threads, diff: PullRequestFilesStore.State<FileDiff>?) {
            self.file = file
            self.changes = changes
            index = changes.index(of: file.id) ?? 0
            self.diff = diff
            let onFile = threads.comments(on: file).threads
            guard case .read(let read)? = diff else {
                apart = Self.asApart(onFile)
                openThreads = apart.filter(Self.isOpen).map(\.id)
                return
            }
            for thread in onFile {
                if let row = read.row(of: thread.thread, in: changes) {
                    placed[row, default: []].append(thread)
                    if let rows = read.rows(of: thread.thread, in: changes) {
                        spans.insert(integersIn: rows)
                        if Self.isOpen(thread) { marked.formUnion(read.markedRows(of: thread.thread, in: changes)) }
                    }
                } else {
                    apart.append(thread)
                }
            }
            apart = Self.asApart(apart)
            openThreads = apart.filter(Self.isOpen).map(\.id)
                + placed.keys.sorted().flatMap { placed[$0, default: []].filter(Self.isOpen).map(\.id) }
        }

        /// Those on the whole file, then those on lines, as they show above the diff.
        private static func asApart(_ threads: [PullRequestPanel.Thread]) -> [PullRequestPanel.Thread] {
            threads.filter { !ThreadCode.isOnLines($0.thread) } + threads.filter { ThreadCode.isOnLines($0.thread) }
        }

        static func isOpen(_ thread: PullRequestPanel.Thread) -> Bool {
            thread.waitsOnYou || !thread.isResolved
        }

        var hasNext: Bool { index < changes.files.count - 1 }
        var hasPrevious: Bool { index > 0 }
    }

    // MARK: Heading and toolbar

    /// The file's name, what happened to it, and its comments, which scroll with its diff.
    private func heading(_ shown: Shown) -> some View {
        let file = shown.file
        let kind = FileKindStyle(file.kind)
        let comments = threads.comments(on: file)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: kind.symbol)
                    .font(size: 13, weight: .semibold)
                    .foregroundStyle(kind.color)
                    .accessibilityHidden(true)
                Text(file.name)
                    .font(size: 14.5, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(file.path)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($isNameFocused)
            }
            // "src · Edited · +51 −8", wrapping as one text would.
            facts(shown)
                .font(size: 12)
                .fixedSize(horizontal: false, vertical: true)
            if !comments.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: comments.open > 0 ? "bubble.left.fill" : "checkmark.bubble")
                        .font(size: 10, weight: .semibold)
                        .foregroundStyle(comments.waitingOnYou > 0 ? AnyShapeStyle(ItemState.needsYou.textColor) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                    Text(comments.spoken)
                        .font(size: 12)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Its folder, or its repository's name at the top, what happened to it, how many lines it adds and removes, in their
    /// colors, and, since you last looked, that it's what changed since.
    private func facts(_ shown: Shown) -> Text {
        let file = shown.file
        var text = Text([file.folder ?? pullRequest?.repositoryName, file.what].compactMap { $0 }.joined(separator: " · "))
            .foregroundStyle(.secondary)
        if case .read(let diff)? = shown.diff, diff.counts.added > 0 || diff.counts.removed > 0 {
            text = text + Text(" · ").foregroundStyle(.tertiary)
            if diff.counts.isApproximate {
                text = text + Text("about ").foregroundStyle(.secondary)
            }
            if diff.counts.added > 0 {
                text = text + Text(verbatim: "+\(diff.counts.added)").foregroundStyle(ItemState.done.textColor).fontWeight(.medium)
            }
            if diff.counts.added > 0 && diff.counts.removed > 0 { text = text + Text(" ") }
            if diff.counts.removed > 0 {
                text = text + Text(verbatim: "−\(diff.counts.removed)").foregroundStyle(ItemState.failing.textColor).fontWeight(.medium)
            }
        }
        if open.scope != .whole {
            text = text + Text(" · ").foregroundStyle(.tertiary) + Text("since you last looked").foregroundStyle(ItemState.running.textColor)
        }
        return text
    }

    /// ‹ 4 of 9 ›, from file to file; ⌃ ⌄, from open comment to open comment; ⤢, the whole page; ↗, the file in Azure
    /// DevOps. It stays at the top as the diff scrolls.
    private func toolbar(_ shown: Shown) -> some View {
        HStack(spacing: 8) {
            fileNavigation(shown)
            commentNavigation(shown)
            Spacer(minLength: 4)
            roomButton
            Button {
                AzureDevOps.open(shown.changes.filePageURL(of: shown.file, in: item))
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(size: 12, weight: .medium)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open \(shown.file.name)'s changes in Azure DevOps")
            .accessibilityLabel("Open \(shown.file.name) in Azure DevOps")
        }
        .padding(.vertical, 5)
        .background {
            // Once it stays at the top, over the code that scrolls under it, from edge to edge of the details.
            if isToolbarPinned {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .bottom) {
                        Divider()
                            .opacity(0.6)
                    }
                    .padding(.horizontal, -16)
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            // The details' top, as it reaches it.
            (proxy.bounds(of: .scrollView)?.minY ?? -1) > -1
        } action: { isToolbarPinned = $0 }
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
                    .frame(width: 24, height: 24)
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
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(next == nil)
            .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            .help(next.map { "Next file: \($0.name) (⌥⌘↓)" } ?? "This is the last file")
            .accessibilityLabel("Next File")
        }
        .padding(.horizontal, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    /// ⌃ and ⌄, through the open threads, on to another file's, while the change has any: each off when there's none that
    /// way.
    @ViewBuilder
    private func commentNavigation(_ shown: Shown) -> some View {
        let onFiles = threads.openOnFiles(of: shown.changes)
        let previous = commentTarget(-1, shown, onFiles)
        let next = commentTarget(1, shown, onFiles)
        if !onFiles.isEmpty || !shown.openThreads.isEmpty {
            HStack(spacing: 0) {
                Button {
                    if let previous { go(to: previous) }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(size: 10.5, weight: .semibold)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(previous == nil)
                .keyboardShortcut(.upArrow, modifiers: [.control, .command])
                .help(Self.help(previous, "Previous open comment") + " (⌃⌘↑)")
                .accessibilityLabel("Previous Comment")
                Image(systemName: "bubble.left")
                    .font(size: 10.5, weight: .medium)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button {
                    if let next { go(to: next) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(size: 10.5, weight: .semibold)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(next == nil)
                .keyboardShortcut(.downArrow, modifiers: [.control, .command])
                .help(Self.help(next, "Next open comment") + " (⌃⌘↓)")
                .accessibilityLabel("Next Comment")
            }
            .padding(.horizontal, 2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
    }

    /// "Next open comment", or, on another file, "Next open comment, on RetryOptions.cs".
    private static func help(_ target: CommentTarget?, _ what: String) -> String {
        switch target {
        case .here?, nil: what
        case .file(let file, _)?: "\(what), on \(file.name)"
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
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(fills ? "Show the list beside the details again" : "Make the details fill the page, for long lines")
            .accessibilityLabel(fills ? "Show the List Again" : "Fill the Page")
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
    }

    // MARK: Going places

    private func go(to file: FileChange) {
        withAnimation(.easeOut(duration: 0.15)) { details.open(file: file.path) }
    }

    /// Where the next open thread is, or the previous, from the one you went to last: on this file, or, past its first or
    /// last, the next file's first, or the previous file's last, that has one, as its page shows them. Nil when there's none
    /// that way.
    private enum CommentTarget: Equatable {
        case here(Int)
        case file(FileChange, PullRequestDetailsStore.OpenFile.Edge)
    }

    private func commentTarget(
        _ step: Int, _ shown: Shown, _ onFiles: [(index: Int, threads: [PullRequestPanel.Thread])]
    ) -> CommentTarget? {
        let ids = shown.openThreads
        let at = current.flatMap { ids.firstIndex(of: $0) }
        let target = at.map { $0 + step } ?? (step > 0 ? 0 : ids.count - 1)
        if ids.indices.contains(target) { return .here(ids[target]) }
        let other = step > 0 ? onFiles.first { $0.index > shown.index } : onFiles.last { $0.index < shown.index }
        guard let other else { return nil }
        return .file(shown.changes.files[other.index], step > 0 ? .first : .last)
    }

    private func go(to target: CommentTarget) {
        switch target {
        case .here(let thread):
            reach(thread)
        case .file(let file, let edge):
            withAnimation(.easeOut(duration: 0.15)) { details.open(file: file.path, comment: edge) }
        }
    }

    /// Scrolls to a thread and points it out for a moment, which takes VoiceOver to it (`ThreadCard`).
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
                    apartThreads(shown.apart, pullRequest, diffShows: true)
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
                    apartThreads(shown.apart, pullRequest, diffShows: false)
                }
            case .reading?, nil:
                codePlaceholder
            }
        }
        // Gone while the page stays, as after a push that took the file out of the change: what it asked for is let go of.
        .onDisappear { files.hideDiff(version, of: pullRequest.key, by: viewer) }
        .task(id: DiffReading(version: version, visibilityChanges: code.visibilityChanges)) {
            if let previous = shownVersion, previous != version { files.hideDiff(previous, of: pullRequest.key, by: viewer) }
            shownVersion = version
            guard code.isVisible(page) else {
                files.hideDiff(version, of: pullRequest.key, by: viewer)
                return
            }
            // Asked for again every half minute while it shows, for a diff that couldn't be read in a way that may pass,
            // which the store reads again then.
            while !Task.isCancelled {
                files.showDiff(of: shown.file, in: shown.changes, of: pullRequest, by: viewer, on: page)
                try? await Task.sleep(for: .seconds(PullRequestCodeStore.retryInterval))
            }
        }
        // Asked to go to one of its threads, or to its first or last open one, once its diff shows or says why it can't:
        // also on another file whose diff was read already.
        .task(id: ThreadReaching(version: version, isSettled: isSettled(shown), thread: open.thread, comment: open.comment)) {
            guard isSettled(shown), open.thread != nil || open.comment != nil else { return }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            if let thread = open.thread {
                reach(thread)
                details.reachedThread(thread)
            } else if let edge = open.comment {
                details.reachedComment(edge)
                if let thread = edge == .first ? shown.openThreads.first : shown.openThreads.last {
                    reach(thread)
                } else {
                    toTop()
                }
            }
        }
    }

    /// What it goes to a thread again for: another file, its diff read or failing, or another thread.
    private struct ThreadReaching: Equatable {
        var version: PullRequestFilesStore.Version
        var isSettled: Bool
        var thread: Int?
        var comment: PullRequestDetailsStore.OpenFile.Edge?
    }

    /// Its diff is read, or can't be: its threads show, either way.
    private func isSettled(_ shown: Shown) -> Bool {
        switch shown.diff {
        case .read?, .failed?: true
        case .reading?, nil: false
        }
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
        // All the lines each thread is on show, with a few around them; a thread's card goes under the last.
        let anchors = shown.spans.union(IndexSet(shown.placed.keys))
        let blocks = DiffLayout.blocks(of: diff.lines, anchors: Array(anchors), revealed: revealed, breaks: Set(shown.placed.keys))
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
            if !diff.isLinedUp {
                Label(
                    "It changed in more places than BriefBar lines up exactly, so what shows as changed, and how many lines, "
                        + "may differ a little from Azure DevOps.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                                .frame(maxWidth: Self.widestThread, alignment: .leading)
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
    /// - Parameter diffShows: its diff shows, so that those on lines are on a version it doesn't show; else they're all
    ///   apart, on its lines.
    private func apartThreads(_ threads: [PullRequestPanel.Thread], _ pullRequest: PullRequest, diffShows: Bool) -> some View {
        let whole = threads.filter { !ThreadCode.isOnLines($0.thread) }
        let earlier = threads.filter { ThreadCode.isOnLines($0.thread) }
        return VStack(alignment: .leading, spacing: 8) {
            if !whole.isEmpty {
                apartHeading("On the Whole File")
                ForEach(whole) { thread in
                    threadView(thread, showsCode: false)
                        .frame(maxWidth: Self.widestThread, alignment: .leading)
                        .id(PullRequestDetailsStore.Anchor.thread(thread.id))
                }
            }
            if !earlier.isEmpty {
                if diffShows {
                    apartHeading("On an Earlier Version")
                        .help("Made on an update before the one this shows, and not followed to it since: with the code it was made on")
                } else {
                    apartHeading("On Its Lines")
                }
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
            Button(open.from == nil ? "Back to Its Files" : "Back") {
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
                        .foregroundStyle(.secondary)
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
