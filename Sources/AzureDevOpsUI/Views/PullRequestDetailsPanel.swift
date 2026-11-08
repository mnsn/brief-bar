import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// A pull request's details, beside the list on the window's Pull Requests page: what it is and where it stands, what's
/// left before it can complete, its comment threads, its builds and checks, who reviews it and what's linked to it, all
/// from what the list read (`PullRequestDetailsContent`). The work items, Copilot sessions and pull requests linked to it
/// open as pages over it, a pull request's the same as its own details, ‹ going back, and ↗ opens it in Azure DevOps, for
/// what BriefBar doesn't do.
struct PullRequestDetailsPanel: View {
    @EnvironmentObject private var details: PullRequestDetailsStore
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var services: AppServices

    /// What you went back from, to show its row again where you return.
    @LocalState private var returnTo: ItemRef?
    /// The pull request a page over the details shows, which the page, ↗ and ⋯ share, and which keeps it while the page
    /// shows, once the list doesn't have it.
    @LocalState private var pageDetails = PullRequestDetailsStore()
    /// A composer in place is open in them, which takes Esc: they close once it's closed.
    @LocalState private var isComposing = false

    var body: some View {
        if let item = details.selected {
            VStack(spacing: 0) {
                // Drawn again as the pull request a page shows changes too, such as when its file's page opens.
                Observing(pageDetails) { topBar(item) }
                Divider()
                    .opacity(0.6)
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            if let page = details.pages.last {
                                LinkedItemPage(ref: page, scroll: proxy, details: pageDetails)
                            } else {
                                PullRequestDetailsContent(details: details, item: item, scroll: proxy)
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
                        // A composer in place scrolls itself into view as it opens.
                        .environment(\.detailsScroll, proxy)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // Each pull request, and each page, from the top, but where you came back to.
                    .id(scrollKey(item))
                    .onChange(of: scrollKey(item)) { scrollBack(proxy) }
                }
                // Once fixes of its comments are done, and not pushed: Push & Reply. Under a pull request's page over them,
                // that one's.
                if let page = details.pages.last {
                    Observing(pageDetails) { ReadyFixesBar.under(page, details: pageDetails, items: store.items) }
                } else {
                    ReadyFixesBar(item: item, details: details)
                }
            }
            .onPreferenceChange(InlineComposerOpen.self) { isComposing = $0 }
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

    /// "Details of pull request 4102", or, on a page, "Work item 5160, from pull request 4102", or, on a file's page,
    /// "PaymentsClient.cs, from pull request 4102".
    private func accessibilityName(_ item: PRSnapshot) -> String {
        guard let page = details.pages.last else {
            guard let file = details.file else { return "Details of pull request \(item.key.number)" }
            return "\(file.name), from pull request \(item.key.number)"
        }
        return "\(ItemPageView.spokenName(of: services.links.describe(page))), from pull request \(item.key.number)"
    }

    private func goBack() {
        // From a file's page in the pull request's page on top, to that pull request's details.
        if let page = details.pages.last, pageDetails.showsFile(of: page) {
            withAnimation(.easeOut(duration: 0.15)) { pageDetails.closeFile() }
            return
        }
        returnTo = details.pages.last
        withAnimation(.easeOut(duration: 0.15)) { details.back() }
    }

    /// "Back to Work Item 5160 · Retry payments", to the pull request under the pages, or to a file's page under them.
    private func backHelp(_ item: PRSnapshot) -> String {
        if let page = details.pages.last, pageDetails.showsFile(of: page) {
            return "Back to \(services.links.describe(page).menuTitle)"
        }
        if details.pages.count > 1, let previous = details.pages.dropLast().last {
            return "Back to \(services.links.describe(previous).menuTitle)"
        }
        if !details.pages.isEmpty, let file = details.file {
            return "Back to " + file.name
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
                        .font(size: 13)
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
                    PageMenuItems(ref: page, details: pageDetails)
                } else {
                    PullRequestDetailsMenuItems(item: item, isListed: details.isListed)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(size: 13)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .labelMenuStyle()
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
            // On a page, or a file's, Esc goes back to what's under it; in a composer in place, it closes that.
            .keyboardShortcut(details.canGoBack || isComposing ? nil : .cancelAction)
            .help(details.canGoBack ? "Close" : "Close (Esc)")
            .accessibilityLabel("Close Details")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 44)
        .background {
            if details.canGoBack, !isComposing {
                Button("Back", action: goBack)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// ↗: the pull request in Azure DevOps, at the comment that needs you, as its row opens it; on a pull request's page,
    /// that one. A page of anything else has its own, beside its title.
    @ViewBuilder
    private func openButton(_ item: PRSnapshot) -> some View {
        if let page = details.pages.last {
            PullRequestPageOpener(ref: page, details: pageDetails)
        } else if details.file == nil {
            // A file's page has its own, for the file.
            PullRequestOpenButton(item: item)
        }
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
    /// PaymentsClient.cs:41", the pull request going back to their top; a file's page, "!4102 › PaymentsClient.cs", the pull
    /// request going back to its row; or, on a page, the way there: "!4102 › 5160", the pull request and each page but the
    /// last one going back to it, and a file's page of the pull request a page shows after it, "!4102 › !4091 › Rounding.cs".
    @ViewBuilder
    private func crumbs(_ item: PRSnapshot) -> some View {
        let pages = details.pages
        let number = "!\(item.key.number)"
        if pages.isEmpty, let file = details.file {
            DetailsTrail(crumbs: [
                .init(title: number, help: "Back to " + Self.name(of: item)) {
                    withAnimation(.easeOut(duration: 0.15)) { details.closeFile() }
                },
                .init(title: file.name, help: file.path),
            ])
        } else if pages.isEmpty, let thread = trailThread(item) {
            DetailsTrail(crumbs: [
                .init(title: number, help: "Back to the top of " + Self.name(of: item)) {
                    withAnimation(.easeOut(duration: 0.15)) { details.goToTop() }
                },
                // Where its card says it is, where it was made.
                .init(title: ThreadCode.place(of: thread.thread) ?? "Comment", help: ThreadCode.placeHelp(of: thread.thread)),
            ])
        } else if pages.isEmpty {
            Text(verbatim: number)
                .font(size: 12, weight: .medium).monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        } else {
            DetailsTrail(crumbs: pageCrumbs(item, number: number))
        }
    }

    /// The trail to the page on top: the pull request, a file's page under the pages, and each page.
    private func pageCrumbs(_ item: PRSnapshot, number: String) -> [DetailsTrail.Crumb] {
        let pages = details.pages
        var crumbs: [DetailsTrail.Crumb] = [
            .init(title: number, help: "Back to " + Self.name(of: item)) {
                returnTo = pages.first
                withAnimation(.easeOut(duration: 0.15)) {
                    details.back(toPage: nil)
                    details.closeFile()
                }
            },
        ]
        if let file = details.file {
            crumbs.append(.init(title: file.name, help: "Back to " + file.path) {
                returnTo = pages.first
                withAnimation(.easeOut(duration: 0.15)) { details.back(toPage: nil) }
            })
        }
        for (index, page) in pages.enumerated() {
            let linked = services.links.describe(page)
            if index < pages.count - 1 {
                crumbs.append(.init(title: ItemPageView.crumb(of: linked), help: "Back to \(linked.menuTitle)") {
                    returnTo = pages[index + 1]
                    withAnimation(.easeOut(duration: 0.15)) { details.back(toPage: index) }
                })
            } else {
                crumbs += DetailsTrail.lastPage(linked, details: pageDetails, ref: page)
            }
        }
        return crumbs
    }

    /// The thread the details were taken to, which the trail names, while they have it.
    private func trailThread(_ item: PRSnapshot) -> PullRequestPanel.Thread? {
        guard let id = details.trailThread else { return nil }
        let record = details.record
        let panel = PullRequestPanel(item, record: record, events: details.pendingEvents(of: item, record: record))
        return panel.threads.all.first { $0.id == id }
    }

    static func copy(_ text: String) {
        ThisMac.copy(text)
    }
}
