import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// A pull request's details, beside the list on the window's Pull Requests page: what it is and where it stands, what's
/// left before it can complete, its comment threads, its builds and checks, who reviews it and what's linked to it, all
/// from what the list read. The work items and Copilot sessions linked to it open as pages over it, ‹ going back, and ↗
/// opens it in Azure DevOps, for what BriefBar doesn't do.
struct PullRequestDetailsPanel: View {
    @EnvironmentObject private var details: PullRequestDetailsStore
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var services: AppServices

    /// What you went back from, to show its row again where you return.
    @LocalState private var returnTo: ItemRef?
    /// The thread, the build or the check the details just went to, pointed out for a moment.
    @LocalState private var highlighted: PullRequestDetailsStore.Anchor?
    /// `--render` draws them without waiting for animations, which it doesn't run.
    @Environment(\.isRendering) private var isRendering

    var body: some View {
        if let item = details.selected {
            VStack(spacing: 0) {
                topBar(item)
                Divider()
                    .opacity(0.6)
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            if let page = details.pages.last {
                                ItemPageView(ref: page)
                            } else {
                                content(item)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // A work item or a session linked to it opens its page here.
                        .environment(\.itemNavigation, ItemNavigation(trail: [item.key.linkRef] + details.pages) { ref in
                            navigate(to: ref)
                        })
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // Each pull request, and each page, from the top, but where you came back to.
                    .id(scrollKey(item))
                    .onChange(of: scrollKey(item)) { scrollBack(proxy) }
                    .onChange(of: details.place, initial: true) { go(proxy) }
                }
            }
            // Pages come from Show Links: without it, they go.
            .onReceive(services.links.$isOn) { isOn in
                if !isOn { details.closePages() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityName(item))
        }
    }

    private func scrollKey(_ item: PRSnapshot) -> String {
        "\(item.key)/\(details.pages.last.map(String.init(describing:)) ?? "")"
    }

    /// Back to the row of what you came back from, once it shows.
    private func scrollBack(_ proxy: ScrollViewProxy) {
        guard let target = returnTo else { return }
        returnTo = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            proxy.scrollTo(target, anchor: .center)
        }
    }

    /// To where the details were asked to go, once they show it, pointing out a thread, a build or a check for a moment.
    private func go(_ proxy: ScrollViewProxy) {
        guard let place = details.place, details.pages.isEmpty, let item = details.selected else { return }
        let anchor = place.anchor(in: panel(for: item).checks)
        Task { @MainActor in
            // Once what's there shows, such as a resolved thread unfolded for it.
            try? await Task.sleep(for: .milliseconds(60))
            details.reached(place)
            guard let anchor else { return }
            withAnimation(isRendering ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo(anchor, anchor: .top) }
            if case .section = anchor { return }
            if anchor == .top { return }
            withAnimation(isRendering ? nil : .easeOut(duration: 0.2)) { highlighted = anchor }
            try? await Task.sleep(for: .seconds(1.6))
            if highlighted == anchor {
                withAnimation(.easeOut(duration: 0.4)) { highlighted = nil }
            }
        }
    }

    /// "Details of pull request 4102", or, on a page, "Work item 5160, from pull request 4102".
    private func accessibilityName(_ item: PRSnapshot) -> String {
        guard let page = details.pages.last else { return "Details of pull request \(item.key.number)" }
        return "\(ItemPageView.spokenName(of: services.links.describe(page))), from pull request \(item.key.number)"
    }

    private func goBack() {
        returnTo = details.pages.last
        withAnimation(.easeOut(duration: 0.15)) { details.back() }
    }

    /// "Back to Work Item 5160 · Retry payments", or to the pull request under the pages.
    private func backHelp(_ item: PRSnapshot) -> String {
        if details.pages.count > 1, let previous = details.pages.dropLast().last {
            return "Back to \(services.links.describe(previous).menuTitle)"
        }
        return "Back to " + Self.name(of: item)
    }

    /// "!4102: Add retry with backoff to the payments client".
    private static func name(of item: PRSnapshot) -> String {
        "!\(item.key.number): \(item.title)"
    }

    /// Opens something linked to the pull request as a page over its details: a work item, a Copilot session or another
    /// pull request; the pull request itself, its details.
    private func navigate(to ref: ItemRef) -> Bool {
        withAnimation(.easeOut(duration: 0.15)) { details.open(page: ref) }
        return true
    }

    // MARK: Top

    private func topBar(_ item: PRSnapshot) -> some View {
        HStack(spacing: 8) {
            if details.canGoBack {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(size: 13, weight: .semibold)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("[", modifiers: .command)
                .help(backHelp(item) + " (⌘[)")
                .accessibilityLabel(backHelp(item))
            }
            RowIcon(item: item, size: 16)
                .accessibilityHidden(true)
            crumbs(item)
            Spacer(minLength: 6)
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 22, height: 22)
                    .help("Reading your pull requests from Azure DevOps")
            } else if store.mode == .live {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Read your pull requests again")
                .accessibilityLabel("Refresh")
            }
            openButton(item)
            Menu {
                if let page = details.pages.last {
                    pageMenuItems(page)
                } else {
                    menuItems(item)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
            Button {
                withAnimation(.easeOut(duration: 0.2)) { details.close() }
            } label: {
                Image(systemName: "xmark")
                    .font(size: 12, weight: .semibold)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            // On a page, Esc goes back to what's under it.
            .keyboardShortcut(details.pages.isEmpty ? .cancelAction : nil)
            .help(details.pages.isEmpty ? "Close (Esc)" : "Close")
            .accessibilityLabel("Close Details")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 44)
        .background {
            if !details.pages.isEmpty {
                Button("Back", action: goBack)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// ↗: the pull request in Azure DevOps, at the comment that needs you, as its row opens it.
    @ViewBuilder
    private func openButton(_ item: PRSnapshot) -> some View {
        if let opener = opener(item) {
            Button(action: opener.open) {
                Image(systemName: "arrow.up.forward.app")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(opener.help)
            .accessibilityLabel(opener.title)
        }
    }

    /// The pull request's, while its details show: a page over them has its own, beside its title.
    private func opener(_ item: PRSnapshot) -> (title: String, help: String, open: () -> Void)? {
        guard details.pages.isEmpty else { return nil }
        return ("Open in Azure DevOps", Self.openHelp(item), { store.open(item) })
    }

    /// What ↗ opens: the pull request, or, as its row opens it, the comment that needs you or that you answered, or the
    /// run after its merge that failed or waits.
    static func openHelp(_ item: PRSnapshot) -> String {
        let title = "Open in Azure DevOps"
        guard item.url != item.pageURL() else { return title }
        if item.merge != nil { return "Open the run after its merge in Azure DevOps" }
        return item.group == .needsYou ? "\(title), at the comment that needs you" : "\(title), at the comment you answered"
    }

    /// "!4102", which the heading under it names in full; the thread they were taken to after it, "!4102 ›
    /// PaymentsClient.cs:41", the pull request going back to their top; or, on a page, the way there: "!4102 › 5160", the
    /// pull request and each page but the last one going back to it.
    @ViewBuilder
    private func crumbs(_ item: PRSnapshot) -> some View {
        let pages = details.pages
        if pages.isEmpty, let thread = trailThread(item) {
            HStack(spacing: 5) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { details.goToTop() }
                } label: {
                    Text(verbatim: "!\(item.key.number)")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to the top of " + Self.name(of: item))
                .layoutPriority(1)
                Image(systemName: "chevron.right")
                    .font(size: 8.5, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                // Where its card says it is, where it was made.
                Text(ThreadCode.place(of: thread.thread) ?? "Comment")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(ThreadCode.placeHelp(of: thread.thread))
            }
            .font(size: 12, weight: .medium).monospacedDigit()
        } else if pages.isEmpty {
            Text(verbatim: "!\(item.key.number)")
                .font(size: 12, weight: .medium).monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        } else {
            HStack(spacing: 5) {
                Button {
                    returnTo = pages.first
                    withAnimation(.easeOut(duration: 0.15)) { details.back(toPage: nil) }
                } label: {
                    Text(verbatim: "!\(item.key.number)")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to " + Self.name(of: item))
                .layoutPriority(1)
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    let linked = services.links.describe(page)
                    Image(systemName: "chevron.right")
                        .font(size: 8.5, weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    if index == pages.count - 1 {
                        Text(ItemPageView.crumb(of: linked))
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(linked.menuTitle)
                            .layoutPriority(1)
                    } else {
                        Button {
                            returnTo = pages[index + 1]
                            withAnimation(.easeOut(duration: 0.15)) { details.back(toPage: index) }
                        } label: {
                            Text(ItemPageView.crumb(of: linked))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Back to \(linked.menuTitle)")
                    }
                }
            }
            .font(size: 12, weight: .medium).monospacedDigit()
        }
    }

    /// The thread the details were taken to, which the trail names, while they have it.
    private func trailThread(_ item: PRSnapshot) -> PullRequestPanel.Thread? {
        guard let id = details.trailThread else { return nil }
        return panel(for: item).threads.all.first { $0.id == id }
    }

    /// The pull request's own: opening it, copying it, and what its row's menu has, Copilot's actions among them while
    /// Send Work to Copilot is on.
    @ViewBuilder
    private func menuItems(_ item: PRSnapshot) -> some View {
        Button("Open in Azure DevOps") { store.open(item) }
        Button("Copy Link") { Self.copy(item.pageURL().absoluteString) }
        Button("Copy Number and Title") { Self.copy("!\(item.key.number) \(item.title)") }
        // The row's own, while there's a row.
        if details.isListed {
            rowMenuItems(item)
        } else {
            LinkMenuItems(item.key.linkRef)
        }
    }

    private func rowMenuItems(_ item: PRSnapshot) -> some View {
        PullRequestMenuItems(
            item: item,
            openSource: item.chatSource == nil ? nil : { store.openSource(item) },
            dismiss: item.group == .needsYou ? { store.dismiss(item) } : nil,
            stopWatching: item.isWatched ? { store.stopWatching(item) } : nil
        )
    }

    /// The page's own: opening it, copying it, and linking it to more.
    @ViewBuilder
    private func pageMenuItems(_ ref: ItemRef) -> some View {
        let item = services.links.describe(ref)
        if let menu = item.menu {
            menu()
            Divider()
        } else if let open = item.open {
            Button(ref.kind.openTitle, action: open)
        }
        if let link = item.link {
            Button("Copy Link") { Self.copy(link.absoluteString) }
        }
        if ref.kind == .session {
            Button("Copy Name") { Self.copy(item.label) }
        } else {
            Button("Copy Number and Title") { Self.copy("\(item.label) \(item.title)") }
        }
        LinkMenuItems(ref)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Content

    /// What the task Copilot is at work on for the pull request does, while Send Work to Copilot is on.
    private func copilotAction(_ item: PRSnapshot) -> PullRequestAction? {
        guard copilot.isOn, let entry = copilot.latest(forPullRequest: item.key), entry.status.phase.isActive else { return nil }
        return entry.action
    }

    /// What they show of it, from what the list read of it as they keep it (`PullRequestDetailsStore.record`), with what
    /// waits on you in its threads as when they showed it.
    private func panel(for item: PRSnapshot) -> PullRequestPanel {
        let record = details.record
        return PullRequestPanel(item, record: record, events: details.pendingEvents(of: item, record: record))
    }

    private func content(_ item: PRSnapshot) -> some View {
        let record = details.record
        let panel = panel(for: item)
        let ref = item.key.linkRef
        return VStack(alignment: .leading, spacing: 20) {
            PullRequestPanelHeading(item: item, panel: panel, isListed: details.isListed)
                .id(PullRequestDetailsStore.Anchor.top)
            PullRequestSessionLine(item: item)
            // Its summary, of it and what's linked to it, under what it is.
            PageSummary(ref: ref)
            if let readiness = panel.readiness, !readiness.items.isEmpty {
                PullRequestLeftSection(readiness: readiness, copilotAction: copilotAction(item)) { section in
                    details.go(to: .section(section))
                }
            }
            PullRequestCommentsSection(
                item: item, panel: panel, pullRequest: record?.pullRequest, me: record?.me, place: details.place, highlighted: highlighted
            )
                .id(PullRequestDetailsStore.Anchor.section(.comments))
            PullRequestChecksSection(panel: panel, highlighted: highlighted)
                .id(PullRequestDetailsStore.Anchor.section(.checks))
            PullRequestReviewersSection(panel: panel)
                .id(PullRequestDetailsStore.Anchor.section(.reviewers))
            WhereItStandsSection(subject: ref, title: "Also Linked", hidesWhenEmpty: true, showsSummary: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tellsStory(of: ref)
        // Once it's shown a moment, its summary, unless one that's current is there, as for a work item's details.
        .writesSummary(of: ref)
    }
}
