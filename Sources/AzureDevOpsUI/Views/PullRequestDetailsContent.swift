import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// A pull request's details: what it is and where it stands, what's left before it can complete, its comment threads, its
/// builds and checks, who reviews it and what else is linked to it, all from what the list read. Beside the list on the
/// window's Pull Requests page (`PullRequestDetailsPanel`), and as the page of a pull request linked to a work item or
/// to another pull request (`LinkedItemPage`), so it reads the same wherever it opens. It goes where it's asked to
/// (`PullRequestDetailsStore.place`), pointing a thread, a build or a check out for a moment.
struct PullRequestDetailsContent: View {
    /// What shows it: the panel's, or a page's own.
    @ObservedObject var details: PullRequestDetailsStore
    /// The pull request, as the list has it now, or as it was last once it doesn't.
    let item: PRSnapshot

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var services: AppServices
    @Environment(\.itemNavigation) private var navigation

    /// The thread, the build or the check it just went to, pointed out for a moment.
    @LocalState private var highlighted: PullRequestDetailsStore.Anchor?

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
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 20) {
                PullRequestPanelHeading(item: item, panel: panel, isListed: !isShown || details.isListed, linked: linkFact)
                PullRequestSessionLine(item: item)
                // Its summary, of it and what's linked to it, under what it is.
                PageSummary(ref: ref)
                if let readiness = panel.readiness, !readiness.items.isEmpty {
                    PullRequestLeftSection(readiness: readiness, copilotAction: copilotAction) { section in
                        details.go(to: .section(section))
                    }
                }
                PullRequestCommentsSection(item: item, panel: panel, me: record?.me, place: details.place, highlighted: highlighted)
                    .id(PullRequestDetailsStore.Anchor.section(.comments))
                PullRequestChecksSection(panel: panel, highlighted: highlighted)
                    .id(PullRequestDetailsStore.Anchor.section(.checks))
                PullRequestReviewersSection(panel: panel)
                    .id(PullRequestDetailsStore.Anchor.section(.reviewers))
                WhereItStandsSection(subject: ref, excluding: Set(trail), title: "Also Linked", hidesWhenEmpty: true, showsSummary: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: details.place, initial: true) { go(proxy, in: panel) }
        }
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

    /// What the task Copilot is at work on for the pull request does, while Send Work to Copilot is on.
    private var copilotAction: PullRequestAction? {
        guard copilot.isOn, let entry = copilot.latest(forPullRequest: item.key), entry.status.phase.isActive else { return nil }
        return entry.action
    }

    /// To where they were asked to go, once it shows, pointing out a thread, a build or a check for a moment: to their
    /// comments, or their builds and checks, for one they don't have.
    private func go(_ proxy: ScrollViewProxy, in panel: PullRequestPanel) {
        guard let place = details.place, details.pages.isEmpty, isShown else { return }
        let anchor = place.anchor(in: panel)
        Task { @MainActor in
            // Once what's there shows, such as a resolved thread unfolded for it.
            try? await Task.sleep(for: .milliseconds(60))
            details.reached(place)
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(anchor, anchor: .top) }
            if case .section = anchor { return }
            withAnimation(.easeOut(duration: 0.2)) { highlighted = anchor }
            try? await Task.sleep(for: .seconds(1.6))
            if highlighted == anchor {
                withAnimation(.easeOut(duration: 0.4)) { highlighted = nil }
            }
        }
    }
}

/// The page of something linked to a work item or a pull request, over its details: for a pull request your list has, the
/// same as its own details beside the list on the window's Pull Requests page, which sees it, as showing those does; for
/// anything else, what Show Links knows of it (`ItemPageView`).
struct LinkedItemPage: View {
    let ref: ItemRef

    @EnvironmentObject private var store: PRStore

    var body: some View {
        if let item = Self.pullRequest(ref, in: store.items) {
            PullRequestPage(item: item)
        } else {
            ItemPageView(ref: ref)
        }
    }

    /// The pull request a page is of, as the list has it; nil for anything else.
    static func pullRequest(_ ref: ItemRef, in items: [PRSnapshot]) -> PRSnapshot? {
        guard ref.kind == .pullRequest else { return nil }
        return items.first { $0.key.linkRef == ref }
    }
}

/// A pull request's page: its details, in a store of its own, which follows the list as the panel's does, and sees it as it
/// shows, keeping what was new in its threads new while it does.
private struct PullRequestPage: View {
    let item: PRSnapshot

    @EnvironmentObject private var store: PRStore
    @LocalState private var details = PullRequestDetailsStore()

    var body: some View {
        PullRequestDetailsContent(details: details, item: item)
            .onAppear {
                details.use(store)
                details.show(item)
            }
            .onChange(of: item.key) { details.show(item) }
    }
}
