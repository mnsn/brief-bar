import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// A pull request's comment threads, in its details, as someone reviewing it in Azure DevOps sees them: by file, as the
/// change lists its files, those on the pull request itself apart, first; in each, those that wait on you first, then the
/// other open ones. A thread on lines of a file shows the code it's on above what each person said, in full; each says who
/// it waits on and how it stands, with ↗ to open it in Azure DevOps. The resolved ones fold away until you ask for them.
struct PullRequestCommentsSection: View {
    let item: PRSnapshot
    let panel: PullRequestPanel
    /// The pull request as the list read it last, whose code the threads' code is read from; nil when the list has none.
    let pullRequest: PullRequest?
    /// Your identity ID in its organization, to ring your avatar.
    let me: String?
    /// Where the details are asked to go: a resolved thread there unfolds the resolved ones.
    let place: PullRequestDetailsStore.Place?
    /// The thread the details just went to, pointed out for a moment.
    let highlighted: PullRequestDetailsStore.Anchor?
    /// The composer in place that's open in the details, one at a time in them, so Esc, Return and the keyboard's focus are
    /// its own; and what you wrote in each.
    @Binding var composing: CopilotComposing?
    let drafts: CopilotDrafts

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var code: PullRequestCodeStore
    /// The threads you changed in the details, with your reply or their statuses, where each was as you first did: they
    /// stay there, however they stand now, while the details show the pull request, which keep them as a file's page shows.
    @Binding var held: [Int: PullRequestPanel.Thread.Held]
    /// Where the threads you marked as read there were then, which they stay at too, unless you changed them first.
    var readHolds: [Int: PullRequestPanel.Thread.Held] = [:]
    /// Which threads show, as you choose in the heading: all of them, or only the active ones (`AppSettings.commentFilter`).
    var filter: Binding<PullRequestPanel.CommentFilter> = .constant(.all)
    /// Mark as Read and Mark as Unread on the threads, the details'; nil where they can't be.
    var reading: ThreadReading? = nil
    @LocalState private var showsResolved = false
    /// The threads the details were taken to, which show with Active too, whatever their status.
    @LocalState private var revealed: Set<Int> = []

    var body: some View {
        let threads = panel.threads
        let kept = PullRequestPanel.Thread.Held.kept(changed: held, read: readHolds)
        let listing = threads.listed(filter.wrappedValue, holding: kept, revealing: revealed)
        let resolvedCount = listing.resolved.reduce(0) { $0 + $1.threads.count }
        VStack(alignment: .leading, spacing: 8) {
            // With Fix All, while comments wait on you on your pull request; and Active | All, once there are threads.
            CommentsHeader(
                item: item, count: listing.count > 0 ? listing.count : nil, filter: panel.hasDetails && !threads.isEmpty ? filter : nil,
                composing: $composing, drafts: drafts
            )
            if !panel.hasDetails {
                Text(panel.isClosed ? "BriefBar reads a pull request's comments only while it's open."
                    : "BriefBar hasn't read its comments.")
                    .font(size: 12.5)
                    .foregroundStyle(.tertiary)
            } else if threads.isEmpty {
                Text("No comments yet")
                    .font(size: 12.5)
                    .foregroundStyle(.tertiary)
            } else {
                if listing.count == 0 {
                    Text(filter.wrappedValue == .active ? "No active comments." : "Every thread is resolved.")
                        .font(size: 12.5)
                        .foregroundStyle(.secondary)
                }
                files(listing.open)
                if let hidden = listing.hiddenSentence {
                    HiddenCommentsLine(sentence: hidden) { filter.wrappedValue = .all }
                }
                if resolvedCount > 0 {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showsResolved.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .font(size: 9, weight: .bold)
                                .rotationEffect(.degrees(showsResolved ? 90 : 0))
                            Text(verbatim: showsResolved ? "Hide Resolved" : "Show \(resolvedCount) Resolved")
                        }
                        .font(size: 11.5, weight: .medium)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(showsResolved ? "Hide the threads that are resolved" : "Show the threads that are fixed, won't be fixed, closed or by design")
                    .accessibilityValue(showsResolved ? "Expanded" : "Collapsed")
                    if showsResolved {
                        files(listing.resolved)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Asked to go to a thread that's resolved: it shows; and with Active, it shows too, whatever its status.
        .onChange(of: place, initial: true) {
            if case .thread(let id)? = place, panel.threads.resolved.contains(where: { $0.id == id }) {
                showsResolved = true
            }
            if case .thread(let id)? = place, panel.threads.contains(id) {
                revealed.insert(id)
            }
        }
        // Its threads' code is read, and kept, while it shows: in the panel's details, or on a pull request's page.
        .task(id: item.key) {
            let hold = code.hold(item.key)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
            }
            code.release(hold)
        }
    }

    private func files(_ files: [PullRequestPanel.FileThreads]) -> some View {
        ForEach(files) { file in
            FileThreadsView(file: file, key: item.key) { thread in
                ThreadCard(
                    thread: thread, item: item, pullRequest: pullRequest, me: me, now: store.now,
                    isHighlighted: highlighted == .thread(thread.id), composing: $composing, drafts: drafts,
                    hold: { held[$0.id] = .holding($0, changed: held, read: readHolds) }, reading: reading
                )
            }
        }
    }
}

/// Mark as Read on a thread that waits on you, and Mark as Unread on one you marked while the details show its pull
/// request: the details' (`PullRequestDetailsStore.markRead`).
@MainActor
struct ThreadReading {
    /// The threads you marked as read while the details show the pull request.
    var marked: Set<Int>
    var markRead: (PullRequestPanel.Thread) -> Void
    var markUnread: (Int) -> Void

    init(_ details: PullRequestDetailsStore) {
        marked = Set(details.markedRead.keys)
        // VoiceOver hears it, since the button it was on goes.
        markRead = { [weak details] thread in
            details?.markRead(thread)
            SpokenText.announce("Marked as read")
        }
        markUnread = { [weak details] thread in
            details?.markUnread(thread)
            SpokenText.announce("Marked as unread")
        }
    }
}

/// "4 closed or resolved comments hidden", with All, when the comments show only the active ones: in the details'
/// comments, and on a file's page for its own.
struct HiddenCommentsLine: View {
    let sentence: String
    let showAll: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "eye.slash")
                .font(size: 10.5, weight: .medium)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(sentence)
                .font(size: 11.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showAll() }
            } label: {
                Text("Show All")
                    .font(size: 11.5, weight: .medium)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Show every comment, the closed and resolved ones too")
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Show All") { showAll() }
    }
}

/// A file's threads, under its name and folder, or those on the pull request itself. The details scroll to each thread
/// by its ID, and to the first with the file's name above it.
private struct FileThreadsView<Card: View>: View {
    let file: PullRequestPanel.FileThreads
    /// Its pull request, whose threads' code is read.
    let key: PRKey
    @ViewBuilder var card: (PullRequestPanel.Thread) -> Card

    @EnvironmentObject private var code: PullRequestCodeStore
    @Environment(\.changedFileOpener) private var opener

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let first = file.threads.first {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    card(first)
                }
                .id(PullRequestDetailsStore.Anchor.thread(first.id))
            }
            ForEach(file.threads.dropFirst()) { thread in
                card(thread)
                    .id(PullRequestDetailsStore.Anchor.thread(thread.id))
            }
        }
        .padding(.top, 4)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: file.path == nil ? "text.bubble" : "doc.text")
                    .font(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(file.name ?? "On the pull request")
                    .font(size: 12.5, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let folder = file.folder {
                    Text(folder)
                        .font(size: 11.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let change {
                    Text(change)
                        .font(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(file.path.map { path in change.map { "\(path) · \($0)" } ?? path } ?? "Comments on the whole pull request")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let path = file.path, let opener {
                Spacer(minLength: 4)
                // Its whole diff, with these threads at their lines.
                Button {
                    opener.open(path, file.threads.first?.id)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(size: 11, weight: .medium)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("See this file's changes, with its comments at their lines")
                .accessibilityLabel("Show Its Changes")
            }
        }
    }

    /// What the change did to the file, as the code read of its threads says, when it did more than edit it: "Added",
    /// "Deleted", "Renamed from RetryPolicy.cs".
    private var change: String? {
        let read = file.threads.lazy.compactMap { thread -> ThreadExcerpt? in
            if case .read(let excerpt)? = code.state(of: thread.id, in: key) { excerpt } else { nil }
        }.first
        guard let read, let kind = read.change else { return nil }
        if kind.contains(.add) { return "Added" }
        if kind.contains(.delete) { return "Deleted" }
        if kind.contains(.rename), let original = read.originalPath {
            return "Renamed from " + (original as NSString).lastPathComponent
        }
        return nil
    }
}

/// One thread: how it stands and who it waits on, the code it's on, and what each person said in it, the first first. In
/// the details' comments, and at its line on its file's page (`PullRequestFilePage`), which shows its code already.
struct ThreadCard: View {
    let thread: PullRequestPanel.Thread
    let item: PRSnapshot
    let pullRequest: PullRequest?
    /// Your identity ID, to ring your avatar.
    let me: String?
    let now: Date
    let isHighlighted: Bool
    /// The composer in place that's open in the comments, and what you wrote in each.
    @Binding var composing: CopilotComposing?
    let drafts: CopilotDrafts
    /// Whether it shows the code it's on: not on its file's page, around it already.
    var showsCode = true
    /// Keeps it where it is as you change it, with your reply or its status: in the comments, with the open ones it was
    /// with; on its file's page, unfolded.
    var hold: (PullRequestPanel.Thread) -> Void = { _ in }
    /// Mark as Read while it waits on you, and Mark as Unread once you did while the details show it; nil where it can't be.
    var reading: ThreadReading? = nil

    @EnvironmentObject private var changes: ThreadChanges
    @Environment(\.threadChangesPreview) private var preview
    @Environment(\.detailsWidening) private var widening
    /// Opens its file's changes, from the details' comments; nil on its file's page, which shows them.
    @Environment(\.changedFileOpener) private var opener
    /// The comments folded between the first and the latest show.
    @LocalState private var isUnfolded = false
    /// VoiceOver goes to it as the details point it out, going to it or coming back to it.
    @AccessibilityFocusState private var isFocused: Bool
    /// How much wider its code's longest line is than the room it has.
    @LocalState private var codeOverflow: CGFloat = 0

    /// Resolved, and nothing in it waits on you: it reads quieter.
    private var isQuiet: Bool { thread.isResolved && !thread.waitsOnYou }

    /// The pull request's page, at this thread.
    private var url: URL { item.pageURL(thread: thread.id) }

    /// Reply and its status, while you can make changes in Azure DevOps: in the row with Copilot's Explain and Fix. With
    /// Make Changes in Azure DevOps on, on a pull request that can't be changed, a lock in their place, which says why.
    private var yours: AnyView? {
        if let reason = preview?.readOnly ?? changes.readOnlyReason(pullRequest) {
            return AnyView(ThreadReadOnlyMark(reason: reason))
        }
        guard changes.canChange(pullRequest) else { return nil }
        return AnyView(ThreadReplyButtons(thread: thread, item: item, composing: $composing, hold: hold))
    }

    /// The lines it's on, which its code shows.
    private var span: (lines: ClosedRange<Int>, side: ThreadExcerpt.Side)? { ThreadCode.span(of: thread.thread) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 10)
                .padding(.top, 9)
                .padding(.bottom, span == nil || !showsCode ? 2 : 8)
            if showsCode, span != nil, let pullRequest {
                ThreadCodeArea(thread: thread.thread, item: item, pullRequest: pullRequest, overflow: $codeOverflow)
            }
            comments
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
            // What Copilot does about it, and, on an open one, Explain and Fix; and, with Make Changes in Azure DevOps on,
            // Reply and its status in their row, your reply open under it, or what went wrong with a change.
            ThreadCopilotActions(thread: thread, item: item, now: now, composing: $composing, drafts: drafts, yours: yours)
            ThreadReplyArea(thread: thread, item: item, pullRequest: pullRequest, composing: $composing, hold: hold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isHighlighted ? 0.8 : 0), lineWidth: 1.5)
        }
        .contextMenu {
            // BriefBar's own, with or without Make Changes in Azure DevOps.
            if let reading, thread.waitsOnYou {
                Button("Mark as Read") { reading.markRead(thread) }
                Divider()
            } else if let reading, reading.marked.contains(thread.id) {
                Button("Mark as Unread") { reading.markUnread(thread.id) }
                Divider()
            }
            if changes.canChange(pullRequest) {
                let sending = changes.isSending(ThreadChanges.Key(pullRequest: item.key, thread: thread.id))
                Button("Reply") { ThreadReplyArea.open(thread, composing: $composing, hold: hold) }
                    .disabled(sending)
                Menu("Status") {
                    ThreadStatusMenuItems(current: thread.thread.threadStatus) { status in
                        hold(thread)
                        Task { await changes.setStatus(status, of: thread.thread, in: item.key) }
                    }
                }
                .disabled(sending)
                Divider()
            }
            if let path = thread.thread.filePath, !path.isEmpty, let opener {
                Button("Show in Its File's Changes") { opener.open(path, thread.id) }
            }
            Button("Open in Azure DevOps") { AzureDevOps.open(url) }
            Button("Copy Link") { PullRequestDetailsPanel.copy(url.absoluteString) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityActions {
            if let reading, thread.waitsOnYou {
                Button("Mark as Read") { reading.markRead(thread) }
            } else if let reading, reading.marked.contains(thread.id) {
                Button("Mark as Unread") { reading.markUnread(thread.id) }
            }
        }
        .accessibilityFocused($isFocused)
        // Also as it's made, once the details scrolled to it.
        .onAppear { if isHighlighted { isFocused = true } }
        .onChange(of: isHighlighted) {
            if isHighlighted { isFocused = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            // Its words beside where it is while they fit, or else under it.
            FlowLayout(spacing: 6, lineSpacing: 4) {
                if let lines = place {
                    Text(lines)
                        .font(size: 12, weight: .semibold)
                        .foregroundStyle(isQuiet ? .secondary : .primary)
                        .lineLimit(1)
                        .help(placeHelp)
                }
                if thread.waitsOnYou {
                    // With Mark as Read beside it, which goes where it goes.
                    HStack(spacing: 3) {
                        Chip(text: "Waits on you", color: ItemState.needsYou.textColor, symbol: ItemState.needsYou.symbol)
                            .help(waitsHelp)
                        if let reading {
                            // Takes it off waiting on you, here and in Needs You: BriefBar's own, nothing goes to Azure
                            // DevOps. A capsule as tall as the chip, so it reads as the chip's, not as the status after it.
                            Button {
                                reading.markRead(thread)
                            } label: {
                                Text(Image(systemName: "checkmark"))
                                    .font(size: 10.5, weight: .bold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                            .help("Mark as Read")
                            .accessibilityLabel("Mark as Read")
                        }
                    }
                }
                standing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let widening, widening.canWiden, codeOverflow > 1 {
                Button {
                    widening.widen(widening.width + codeOverflow + 2)
                } label: {
                    Image(systemName: "arrow.left.and.right")
                        .font(size: 11, weight: .medium)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Make the details wider, to show its code's lines in full")
                .accessibilityLabel("Make the Details Wider")
            }
            if thread.isNew {
                Circle()
                    .fill(.tint)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                    .help("New since you last looked")
                    .accessibilityLabel("New")
            }
            Button {
                AzureDevOps.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(size: 11.5, weight: .medium)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open this thread in Azure DevOps")
            .accessibilityLabel("Open in Azure DevOps")
        }
    }

    /// "Line 88", "Lines 86–88", "Whole file"; nil for one on the pull request, which its file's heading says.
    private var place: String? {
        if let span { return ThreadCode.linesName(span.lines) }
        return thread.thread.filePath.map { $0.isEmpty ? nil : "Whole file" } ?? nil
    }

    private var placeHelp: String {
        guard let span else { return "A comment on the whole file" }
        let lines = span.lines.count == 1 ? "line \(span.lines.lowerBound)" : "lines \(span.lines.lowerBound) to \(span.lines.upperBound)"
        return span.side == .left ? "On \(lines) of the file before the change" : "On \(lines)"
    }

    /// "Active · Waiting on Sam", "Resolved": how it stands, in its color, and who has to answer.
    private var standing: some View {
        let status = thread.status.map { Text($0).foregroundStyle(Self.color(of: thread)) }
        let waiting = waitingOn.map { Text("Waiting on \($0)").foregroundStyle(.secondary) }
        let separator = status != nil && waiting != nil ? Text(" · ").foregroundStyle(.tertiary) : nil
        return ([status, separator, waiting].compactMap { $0 }.reduce(Text("")) { Text("\($0)\($1)") })
            .font(size: 11.5)
            .lineLimit(1)
    }

    private var waitingOn: String? {
        pullRequest.flatMap { thread.waitingOn(in: $0, me: me) }
    }

    /// Why it waits on you: in a resolved thread, only a comment you haven't seen does.
    private var waitsHelp: String {
        thread.isResolved ? "New since you last looked" : "It waits on you until you reply in it, or mark it as read"
    }

    /// Resolved green, pending orange; active, won't fix, closed and by design gray.
    private static func color(of thread: PullRequestPanel.Thread) -> Color {
        switch thread.thread.status {
        case "fixed"?: ItemState.done.textColor
        case "pending"?: ItemState.needsYou.textColor
        default: .secondary
        }
    }

    // MARK: Comments

    private var comments: some View {
        let all = thread.comments
        let folded = isUnfolded ? 0 : thread.foldedComments
        return VStack(alignment: .leading, spacing: 10) {
            if folded > 0, let first = all.first, let latest = all.last {
                line(first)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isUnfolded = true }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "ellipsis")
                            .font(size: 10, weight: .bold)
                        Text(verbatim: folded == 1 ? "Show 1 more comment" : "Show \(folded) more comments")
                    }
                    .font(size: 11.5, weight: .medium)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.leading, 28)
                .help("Show the comments between the first and the latest")
                line(latest)
            } else {
                ForEach(all, id: \.id) { comment in
                    line(comment)
                }
            }
        }
    }

    private func line(_ comment: ReviewComment) -> some View {
        CommentLine(comment: comment, now: now, isMine: me.map { comment.author.id == $0.lowercased() } ?? false, isQuiet: isQuiet)
    }

    /// "PaymentsClient.cs, line 88, waits on you, Active, 2 comments".
    private var accessibilityLabel: String {
        let name = thread.thread.fileName.flatMap { $0.isEmpty ? nil : $0 }
        var parts = [name.map { name in place.map { "\(name), \($0.lowercased())" } ?? name } ?? "On the pull request"]
        if thread.waitsOnYou { parts.append("waits on you") }
        if thread.isNew { parts.append("new") }
        if let status = thread.status { parts.append(status) }
        if let waitingOn { parts.append("waiting on \(waitingOn)") }
        parts.append(thread.comments.count == 1 ? "1 comment" : "\(thread.comments.count) comments")
        return parts.joined(separator: ", ")
    }
}

/// The code a thread is on, read as it comes on screen, in a window that shows it, and called off as it leaves, or as the
/// window is minimized, hidden or covered, before it's read: what's read, a stand-in as tall as it's likely to be until
/// then, or why it can't show.
private struct ThreadCodeArea: View {
    let thread: ReviewThread
    let item: PRSnapshot
    let pullRequest: PullRequest
    @Binding var overflow: CGFloat

    @EnvironmentObject private var code: PullRequestCodeStore
    @Environment(\.textScale) private var textScale
    /// The window's page it's on, which its code is read only while the window shows on screen.
    @Environment(\.shownSection) private var section
    @Environment(\.shownWindow) private var window
    @LocalState private var isOnScreen = false
    /// What it tells the store it is, so that another view showing the same thread, such as its pull request's details
    /// in another window, goes on reading it once this one leaves the screen.
    @LocalState private var viewer = UUID()

    /// What its code is read again for, while it's on screen: a push, or the thread followed to other lines; and a window
    /// showing it on screen again, after none did.
    private struct Reading: Equatable {
        var isOnScreen: Bool
        var visibilityChanges: Int
        var ask: PullRequestCodeStore.Ask
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSomething {
                Divider()
                    .opacity(0.6)
                content
                Divider()
                    .opacity(0.6)
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            // Outside a scroll view, it's on screen.
            proxy.bounds(of: .scrollView).map { $0.intersects(CGRect(origin: .zero, size: proxy.size)) } ?? true
        } action: { isOnScreen = $0 }
        .task(id: Reading(
            isOnScreen: isOnScreen, visibilityChanges: code.visibilityChanges, ask: PullRequestCodeStore.Ask(thread, pullRequest)
        )) {
            // In the details' scroll view, and in a window that shows it: a minimized, hidden or covered one doesn't.
            guard isOnScreen, code.isVisible(page) else {
                code.hide(thread.id, of: pullRequest.key, by: viewer)
                return
            }
            // Not for a thread scrolled past.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            code.show(thread, of: pullRequest, by: viewer, on: page)
        }
        .onDisappear { code.hide(thread.id, of: pullRequest.key, by: viewer) }
    }

    /// The window's page it's on: nil outside one, where its code isn't read.
    private var page: String? {
        guard let section, let window else { return nil }
        return PullRequestCodeStore.page(section, window: window)
    }

    /// What's read of its code, of its pull request's: another's thread with the same ID, as the details move from one to
    /// another, has its own.
    private var state: PullRequestCodeStore.State? {
        code.state(of: thread.id, in: pullRequest.key)
    }

    /// Its code, why it can't show, or a stand-in until it's read: nothing for a thread that turns out not to be on lines.
    private var showsSomething: Bool {
        guard case .failed(let problem)? = state else { return true }
        return ThreadCode.sentence(for: problem) != nil
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .read(let excerpt)?:
            VStack(alignment: .leading, spacing: 0) {
                CodeView(
                    // Without the indentation its lines share, to make the most of the room it has.
                    rows: ThreadCode.outdented(ThreadCode.rows(of: excerpt)),
                    showsOldNumbers: excerpt.side == .left || excerpt.lines.contains { $0.kind == .removed },
                    label: codeLabel(excerpt)
                ) { overflow = $0 }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                if excerpt.changedSince != false {
                    changedSince(excerpt)
                }
            }
        case .failed(let problem)?:
            if let sentence = ThreadCode.sentence(for: problem) {
                unreadable(sentence, mayPass: ThreadCode.mayPass(problem))
            }
        case .reading?, nil:
            placeholder
        }
    }

    /// "Code of PaymentsClient.cs, lines 85 to 91; the comment is on line 88".
    private func codeLabel(_ excerpt: ThreadExcerpt) -> String {
        let numbers = excerpt.lines.compactMap { excerpt.side == .left ? $0.oldNumber : $0.newNumber }
        let marked = excerpt.lines.filter(\.isCommented).compactMap { excerpt.side == .left ? $0.oldNumber : $0.newNumber }
        var label = "Code of " + (excerpt.path as NSString).lastPathComponent
        if let first = numbers.min(), let last = numbers.max() { label += ", lines \(first) to \(last)" }
        if let first = marked.min(), let last = marked.max() {
            label += first == last ? "; the comment is on line \(first)" : "; the comment is on lines \(first) to \(last)"
        }
        return label
    }

    /// The file changed after the comment was made on it, or may have, when that couldn't be read though the pull request
    /// changed since: what changed opens in Azure DevOps.
    private func changedSince(_ excerpt: ThreadExcerpt) -> some View {
        let url = item.filePageURL(path: excerpt.path, since: excerpt)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(size: 10.5, weight: .medium)
                .accessibilityHidden(true)
            Text(excerpt.changedSince == true ? "The code changed since this comment." : "The code may have changed since this comment.")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                AzureDevOps.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(size: 11, weight: .medium)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("See what changed in it since, in Azure DevOps")
            .accessibilityLabel("See What Changed in Azure DevOps")
        }
        .font(size: 11.5)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03))
    }

    /// Why its code can't show, with ↗ to the thread in Azure DevOps, where it does, and Try Again when that may help.
    private func unreadable(_ sentence: String, mayPass: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "eye.slash")
                .font(size: 10.5, weight: .medium)
                .accessibilityHidden(true)
            Text("BriefBar can't show its code. " + sentence)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if mayPass {
                Button {
                    code.show(thread, of: pullRequest, by: viewer, on: page, again: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(size: 11, weight: .medium)
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Read its code again")
                .accessibilityLabel("Try Again")
            }
            Button {
                AzureDevOps.open(item.pageURL(thread: thread.id))
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(size: 11, weight: .medium)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("See its code in Azure DevOps")
            .accessibilityLabel("Open in Azure DevOps")
        }
        .font(size: 11.5)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// As tall as its code is likely to be, so that what's under it stays put once it's read.
    private var placeholder: some View {
        let metrics = CodeMetrics(scale: textScale)
        let rows = ThreadCode.expectedRows(of: thread) ?? 1
        let widths: [CGFloat] = [0.5, 0.8, 0.35, 0.7, 0.6, 0.9, 0.45, 0.65]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<rows, id: \.self) { row in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 220 * widths[row % widths.count], height: max(4, metrics.lineHeight * 0.42))
                    .frame(height: metrics.lineHeight)
            }
        }
        .padding(.leading, 12 + 4 * metrics.digitWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
        .accessibilityElement()
        .accessibilityLabel("Reading its code")
    }
}

/// What someone said in a thread: who and when, then all of it, formatted as they wrote it.
private struct CommentLine: View {
    let comment: ReviewComment
    let now: Date
    let isMine: Bool
    let isQuiet: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(name: comment.author.name, size: 20, isMe: isMine)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(comment.author.name)
                        .font(size: 12, weight: .semibold)
                        .lineLimit(1)
                    Text(WorkItemDetailsPanel.ago(comment.publishedAt, now: now))
                        .font(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(comment.publishedAt.formatted(date: .complete, time: .shortened))
                }
                .accessibilityElement(children: .combine)
                // Parsed once for what it says, not again each time "ago" changes.
                CommentBody(markdown: comment.markdown, isQuiet: isQuiet)
                    .equatable()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// What a comment says, formatted as its author wrote it. It's drawn again only when that changes, byte for byte, or how
/// quiet it reads: not as the time beside it moves on, which would parse its Markdown again each time.
struct CommentBody: View, Equatable {
    let markdown: String
    let isQuiet: Bool

    var body: some View {
        RichTextView(text: RichText(markdown: markdown), size: 12.5)
            .foregroundStyle(isQuiet ? .secondary : .primary)
    }

    nonisolated static func == (lhs: CommentBody, rhs: CommentBody) -> Bool {
        lhs.isQuiet == rhs.isQuiet && lhs.markdown.utf8.elementsEqual(rhs.markdown.utf8)
    }
}
