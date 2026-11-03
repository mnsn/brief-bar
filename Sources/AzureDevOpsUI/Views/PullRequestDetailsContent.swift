import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// A pull request's details: what it is and where it stands, what's left before it can complete, its comment threads, the
/// files its change touched, its builds and checks, who reviews it and what else is linked to it, all from what the list
/// read but its files. Beside the list on the window's Pull Requests page (`PullRequestDetailsPanel`), and as the page of a
/// pull request linked to a work item or to another pull request (`LinkedItemPage`), so it reads the same wherever it
/// opens. It goes where it's asked to (`PullRequestDetailsStore.place`), pointing a thread, a file, a build or a check out
/// for a moment; and shows a file's page in place of its parts while one is open (`PullRequestDetailsStore.file`).
struct PullRequestDetailsContent: View {
    /// What shows it: the panel's, or a page's own.
    @ObservedObject var details: PullRequestDetailsStore
    /// The pull request, as the list has it now, or as it was last once it doesn't.
    let item: PRSnapshot
    /// Scrolls the details or the page it's in, which holds it, to where they're asked to go.
    let scroll: ScrollViewProxy

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var sessions: PullRequestSessions
    @EnvironmentObject private var services: AppServices
    @Environment(\.itemNavigation) private var navigation
    /// The window's page it's on, which its Copilot session is read only while the window shows on screen.
    @Environment(\.shownSection) private var section
    @Environment(\.shownWindow) private var window

    /// The thread, the build or the check it just went to, pointed out for a moment.
    @LocalState private var highlighted: PullRequestDetailsStore.Anchor?
    /// `--render` draws it without waiting for animations, which it doesn't run.
    @Environment(\.isRendering) private var isRendering

    /// Whether `details` shows this pull request yet: a page's own store shows it once the page appears.
    private var isShown: Bool { details.selected?.key == item.key }

    /// What the list read of it: as `details` keeps it, once it shows it; as the list has it until then.
    private var record: PRRecord? {
        isShown ? details.record : store.record(for: item.key)
    }

    /// What shows under it, from the work item or the pull request it opened from, as a page; nothing beside the list.
    private var trail: [ItemRef] {
        guard let navigation, let index = navigation.trail.lastIndex(of: item.key.linkRef) else { return [] }
        return Array(navigation.trail[..<index])
    }

    var body: some View {
        let record = record
        let panel = PullRequestPanel(item, record: record, events: details.pendingEvents(of: item, record: record))
        let ref = item.key.linkRef
        VStack(alignment: .leading, spacing: 20) {
            if let file = isShown ? details.file : nil {
                PullRequestFilePage(
                    details: details, item: item, pullRequest: record?.pullRequest, threads: panel.threads, me: record?.me, open: file,
                    scroll: scroll
                )
            } else {
                PullRequestPanelHeading(item: item, panel: panel, isListed: !isShown || details.isListed, linked: linkFact)
                    .id(PullRequestDetailsStore.Anchor.top)
                PullRequestSessionLine(item: item)
                // Its summary, of it and what's linked to it, under what it is.
                PageSummary(ref: ref)
                if let readiness = panel.readiness, !readiness.items.isEmpty {
                    PullRequestLeftSection(readiness: readiness, copilotAction: copilotAction) { left in
                        if let place = PullRequestDetailsStore.Place.of(left, in: panel) { details.go(to: place) }
                    }
                }
                PullRequestCommentsSection(
                    item: item, panel: panel, pullRequest: record?.pullRequest, me: record?.me, place: details.place,
                    highlighted: highlighted
                )
                    .id(PullRequestDetailsStore.Anchor.section(.comments))
                    // A thread's file opens here, at the thread, in all of the change, which has it whatever the Files show.
                    .environment(\.changedFileOpener, ChangedFileOpener { path, thread in
                        withAnimation(.easeOut(duration: 0.15)) {
                            details.open(file: path, at: thread, from: thread.map(PullRequestDetailsStore.Place.thread), scope: .whole)
                        }
                    })
                PullRequestFilesSection(
                    details: details, item: item, pullRequest: record?.pullRequest, threads: panel.threads, highlighted: highlighted
                )
                    .id(PullRequestDetailsStore.Anchor.files)
                PullRequestChecksSection(
                    item: item, pullRequest: record?.pullRequest, panel: panel, place: details.place, highlighted: highlighted
                )
                    .id(PullRequestDetailsStore.Anchor.section(.checks))
                PullRequestReviewersSection(panel: panel)
                    .id(PullRequestDetailsStore.Anchor.section(.reviewers))
                // Its own session is on its line, under its heading.
                WhereItStandsSection(
                    subject: ref, excluding: Set(trail).union(ownSession), title: "Also Linked", hidesWhenEmpty: true, showsSummary: false
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: details.place, initial: true) { go(in: panel) }
        // Its Copilot session, kept up to date while it shows on screen.
        .task(id: SessionFollowing(key: item.key, page: page)) { await sessions.follow(item, record: record, on: page) }
        .tellsStory(of: ref)
        // Once it's shown a moment, its summary, unless one that's current is there, as for a work item's details.
        .writesSummary(of: ref)
    }

    /// How it's linked to what it opened from, as a page.
    private var linkFact: ItemStory.Fact? {
        guard let previous = trail.last,
              let connection = services.links.connections(of: previous).first(where: { $0.item.ref == item.key.linkRef })
        else { return nil }
        return WhereItStandsSection.linkFact(connection, from: services.links.describe(previous))
    }

    /// The session its work goes to, which its line shows (`PullRequestSessionLine`), rather than Also Linked.
    private var ownSession: Set<ItemRef> {
        guard let id = sessions.session(for: item.key)?.session?.id, let ref = ItemRef.session(id) else { return [] }
        return [ref]
    }

    /// The window's page it's on (`PullRequestCodeStore.page`): nil outside one, where its session isn't read.
    private var page: String? {
        guard let section, let window else { return nil }
        return PullRequestCodeStore.page(section, window: window)
    }

    /// What its session is followed for: the pull request, on the window's page it's on.
    private struct SessionFollowing: Equatable {
        let key: PRKey
        let page: String?
    }

    /// What the task Copilot is at work on for the pull request does, while Send Work to Copilot is on.
    private var copilotAction: PullRequestAction? {
        guard copilot.isOn, let entry = copilot.latest(forPullRequest: item.key), entry.status.phase.isActive else { return nil }
        return entry.action
    }

    /// To where they were asked to go, once it shows, pointing out a thread, a file's row, a build or a check for a moment:
    /// to their comments, or their builds and checks, for one they don't have.
    private func go(in panel: PullRequestPanel) {
        guard let place = details.place, details.pages.isEmpty, details.file == nil, isShown else { return }
        let anchor = place.anchor(in: panel)
        Task { @MainActor in
            // Once what's there shows, such as a resolved thread unfolded for it.
            try? await Task.sleep(for: .milliseconds(60))
            details.reached(place)
            // A file's row, which they come back to from its page, in the middle, with the files around it.
            let position: UnitPoint = if case .file = anchor { .center } else { .top }
            withAnimation(isRendering ? nil : .easeOut(duration: 0.25)) { scroll.scrollTo(anchor, anchor: position) }
            if case .section = anchor { return }
            if anchor == .top || anchor == .files { return }
            withAnimation(isRendering ? nil : .easeOut(duration: 0.2)) { highlighted = anchor }
            try? await Task.sleep(for: .seconds(1.6))
            if highlighted == anchor {
                withAnimation(.easeOut(duration: 0.4)) { highlighted = nil }
            }
        }
    }
}

/// The page of something linked to a work item or a pull request, over its details: for one of your pull requests, the same
/// as its own details beside the list on the window's Pull Requests page, which sees it, as showing those does, in a store
/// the details keep for their pages (`details`), which follows the list as the panel's does and keeps the pull request
/// while the page shows, once the list doesn't have it, such as one under Done that you've now seen; for anything else,
/// what Show Links knows of it (`ItemPageView`).
struct LinkedItemPage: View {
    let ref: ItemRef
    /// Scrolls the details it's over, which hold it.
    let scroll: ScrollViewProxy
    /// The details' store for the pull request their page shows, which their header's ↗ and ⋯ read too.
    @ObservedObject var details: PullRequestDetailsStore

    @EnvironmentObject private var store: PRStore

    var body: some View {
        if let item = Self.pullRequest(ref, in: store.items, kept: details) {
            PullRequestDetailsContent(details: details, item: item, scroll: scroll)
                .onAppear { show(item) }
                // Gone, as you navigate elsewhere: unless another page of a pull request took the store over already.
                .onDisappear {
                    if details.selected?.key.linkRef == ref { details.close() }
                }
        } else {
            ItemPageView(ref: ref)
        }
    }

    /// Shows the pull request in the store, which sees it, unless it shows already.
    private func show(_ item: PRSnapshot) {
        guard details.selected?.key.linkRef != ref else { return }
        details.use(store)
        details.show(item)
    }

    /// The pull request a page is of: as `kept` keeps it while its page shows, or as the list has it; nil for anything else.
    static func pullRequest(_ ref: ItemRef, in items: [PRSnapshot], kept: PullRequestDetailsStore? = nil) -> PRSnapshot? {
        guard ref.kind == .pullRequest else { return nil }
        if let selected = kept?.selected, selected.key.linkRef == ref { return selected }
        return items.first { $0.key.linkRef == ref }
    }
}

/// ↗ above a pull request's page, as above its own details: it in Azure DevOps, as its row opens it. A page of anything else
/// has its own, beside its title.
struct PullRequestPageOpener: View {
    let ref: ItemRef
    /// The details' store for the pull request their page shows.
    @ObservedObject var details: PullRequestDetailsStore

    @EnvironmentObject private var store: PRStore

    var body: some View {
        // A file's page has its own, for the file.
        if let item = LinkedItemPage.pullRequest(ref, in: store.items, kept: details), !details.showsFile(of: ref) {
            PullRequestOpenButton(item: item)
        }
    }
}

/// ↗: a pull request in Azure DevOps, at the comment that needs you, as its row opens it.
struct PullRequestOpenButton: View {
    let item: PRSnapshot

    @EnvironmentObject private var store: PRStore

    var body: some View {
        Button {
            store.open(item)
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(PullRequestDetailsPanel.openHelp(item))
        .accessibilityLabel("Open in Azure DevOps")
    }
}
