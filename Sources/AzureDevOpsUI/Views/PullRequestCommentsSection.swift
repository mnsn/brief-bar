import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// A pull request's comment threads, in its details: those that wait on you first, then the other open ones, each saying
/// where it is and how it stands, with what each person said, and ↗ to open it in Azure DevOps; the resolved ones fold
/// away until you ask for them.
struct PullRequestCommentsSection: View {
    let item: PRSnapshot
    let panel: PullRequestPanel
    /// Your identity ID in its organization, to ring your avatar.
    let me: String?
    /// Where the details are asked to go: a resolved thread there unfolds the resolved ones.
    let place: PullRequestDetailsStore.Place?
    /// The thread the details just went to, pointed out for a moment.
    let highlighted: PullRequestDetailsStore.Anchor?

    @EnvironmentObject private var store: PRStore
    @LocalState private var showsResolved = false

    var body: some View {
        let threads = panel.threads
        VStack(alignment: .leading, spacing: 8) {
            PageSectionHeader(title: "Comments", count: threads.unresolvedCount > 0 ? threads.unresolvedCount : nil)
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
                if threads.unresolvedCount == 0 {
                    Text("Every thread is resolved.")
                        .font(size: 12.5)
                        .foregroundStyle(.secondary)
                }
                ForEach(threads.waitingOnYou + threads.open) { thread in
                    card(thread, me: me)
                }
                if !threads.resolved.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showsResolved.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .font(size: 9, weight: .bold)
                                .rotationEffect(.degrees(showsResolved ? 90 : 0))
                            Text(verbatim: showsResolved ? "Hide Resolved" : "Show \(threads.resolved.count) Resolved")
                        }
                        .font(size: 11.5, weight: .medium)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(showsResolved ? "Hide the threads that are resolved" : "Show the threads that are fixed, won't be fixed, closed or by design")
                    .accessibilityValue(showsResolved ? "Expanded" : "Collapsed")
                    if showsResolved {
                        ForEach(threads.resolved) { thread in
                            card(thread, me: me)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Asked to go to a thread that's resolved: it shows.
        .onChange(of: place, initial: true) {
            if case .thread(let id)? = place, panel.threads.resolved.contains(where: { $0.id == id }) {
                showsResolved = true
            }
        }
    }

    private func card(_ thread: PullRequestPanel.Thread, me: String?) -> some View {
        ThreadCard(thread: thread, url: item.pageURL(thread: thread.id), me: me, now: store.now,
                   isHighlighted: highlighted == .thread(thread.id))
            .id(PullRequestDetailsStore.Anchor.thread(thread.id))
    }
}

/// One thread: where it is, how it stands, and what each person said in it, the first first.
private struct ThreadCard: View {
    let thread: PullRequestPanel.Thread
    /// The pull request's page, at this thread.
    let url: URL
    /// Your identity ID, to ring your avatar.
    let me: String?
    let now: Date
    let isHighlighted: Bool

    /// Resolved, and nothing in it waits on you: it reads quieter.
    private var isQuiet: Bool { thread.isResolved && !thread.waitsOnYou }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            ForEach(thread.comments, id: \.id) { comment in
                CommentLine(comment: comment, now: now, isMine: me.map { comment.author.id == $0 } ?? false, isQuiet: isQuiet)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isHighlighted ? 0.8 : 0), lineWidth: 1.5)
        }
        .contextMenu {
            Button("Open in Azure DevOps") { AzureDevOps.open(url) }
            Button("Copy Link") { PullRequestDetailsPanel.copy(url.absoluteString) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            // Its chips beside where it is while they fit, or else under it, rather than cutting the file's name short.
            FlowLayout(spacing: 6, lineSpacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: thread.place == nil ? "text.bubble" : "doc.text")
                        .font(size: 11, weight: .medium)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(thread.place ?? "On the pull request")
                        .font(size: 12, weight: .semibold)
                        .foregroundStyle(isQuiet ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(thread.thread.filePath.map { path in thread.thread.line.map { "\(path), line \($0)" } ?? path }
                              ?? "A comment on the whole pull request")
                }
                if thread.waitsOnYou {
                    Chip(text: "Waits on you", color: ItemState.needsYou.textColor, symbol: ItemState.needsYou.symbol)
                }
                // Open threads are active: only another status is worth saying.
                if let status = thread.status, status != "Active" {
                    Chip(text: status, color: Self.color(of: thread))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Resolved green, pending orange; won't fix, closed and by design gray.
    private static func color(of thread: PullRequestPanel.Thread) -> Color {
        switch thread.thread.status {
        case "fixed"?: ItemState.done.textColor
        case "pending"?: ItemState.needsYou.textColor
        default: .secondary
        }
    }

    /// "PaymentsClient.cs:88, waits on you, 2 comments".
    private var accessibilityLabel: String {
        var parts = [thread.place ?? "On the pull request"]
        if thread.waitsOnYou { parts.append("waits on you") }
        if thread.isNew { parts.append("new") }
        if let status = thread.status { parts.append(status) }
        parts.append(thread.comments.count == 1 ? "1 comment" : "\(thread.comments.count) comments")
        return parts.joined(separator: ", ")
    }
}

/// What someone said in a thread: who and when, then what, as plain text.
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
                Text(comment.text)
                    .font(size: 12.5)
                    .foregroundStyle(isQuiet ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
