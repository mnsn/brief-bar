import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// What a pull request's menus have after opening it, in its row's and in its details: summarizing it, the message it was
/// sent in, taking it off Needs You, what Copilot can do with it while Send Work to Copilot is on, its stage while Pull
/// Request Order shows one, its links, and no longer watching it.
struct PullRequestMenuItems: View {
    let item: PRSnapshot
    /// Opens the message it was sent in; nil when it wasn't.
    var openSource: (() -> Void)?
    /// Takes it off Needs You; nil when it isn't there.
    var dismiss: (() -> Void)?
    /// Stops watching it; nil when you don't watch it.
    var stopWatching: (() -> Void)?
    /// Pull Request Order, for Stage ▸, while it's on, for a full row; nil otherwise.
    var ordering: PullRequestOrder? = nil

    var body: some View {
        // Right after opening it, a group of its own.
        SummarizeMenuItems(item.key.linkRef)
        if let source = item.chatSource, let openSource {
            Button(source.messageURL == nil ? "Show \(source.appName)" : "Open Message in \(source.appName)", action: openSource)
        }
        if let dismiss {
            Button("Remove from Needs You", action: dismiss)
        }
        PullRequestCopilotMenuItems(item: item)
        // A group of its own, as its order's is: what Pull Request Order says of it.
        if let ordering {
            StageSubmenu(ref: item.key.linkRef, order: ordering)
        }
        LinkMenuItems(item.key.linkRef)
        if item.isWatched, let stopWatching {
            Divider()
            Button("Stop Watching", action: stopWatching)
        }
    }
}

/// The menu of a pull request's details, ⋯ above them, and of its page over a work item's or another pull request's:
/// opening it, copying it, and what its row's menu has while the list has it, Copilot's actions among them while Send Work
/// to Copilot is on; or else its links.
struct PullRequestDetailsMenuItems: View {
    let item: PRSnapshot
    /// The list still has it, and its row.
    let isListed: Bool

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var ordering: PullRequestOrder

    var body: some View {
        Button("Open in Azure DevOps") { store.open(item) }
        Button("Copy Link") { PullRequestDetailsPanel.copy(item.pageURL().absoluteString) }
        Button("Copy Number and Title") { PullRequestDetailsPanel.copy("!\(item.key.number) \(item.title)") }
        // The row's own, while there's a row.
        if isListed {
            PullRequestMenuItems(
                item: item,
                openSource: item.chatSource == nil ? nil : { store.openSource(item) },
                dismiss: item.group == .needsYou ? { store.dismiss(item) } : nil,
                stopWatching: item.isWatched ? { store.stopWatching(item) } : nil,
                ordering: ordering.isOn ? ordering : nil
            )
        } else {
            LinkMenuItems(item.key.linkRef)
        }
    }
}

/// The menu of a page over a work item's details or a pull request's, ⋯ above it: for one of your pull requests, its
/// details' menu, as the page shows it; for anything else, opening it, copying it, and linking it to more.
struct PageMenuItems: View {
    let ref: ItemRef
    /// The details' store for the pull request their page shows, which keeps it once the list doesn't have it.
    @ObservedObject var details: PullRequestDetailsStore

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var services: AppServices

    var body: some View {
        if let item = LinkedItemPage.pullRequest(ref, in: store.items, kept: details) {
            PullRequestDetailsMenuItems(item: item, isListed: details.selected?.key.linkRef == ref ? details.isListed : true)
        } else {
            let item = services.links.describe(ref)
            if let menu = item.menu {
                menu()
                Divider()
            } else if let open = item.open {
                Button(ref.kind.openTitle, action: open)
            }
            if let link = item.link {
                Button("Copy Link") { PullRequestDetailsPanel.copy(link.absoluteString) }
            }
            if ref.kind == .session {
                Button("Copy Name") { PullRequestDetailsPanel.copy(item.label) }
            } else {
                Button("Copy Number and Title") { PullRequestDetailsPanel.copy("\(item.label) \(item.title)") }
            }
            LinkMenuItems(ref)
        }
    }
}
