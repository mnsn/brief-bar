import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

extension PRKey {
    /// The pull request, for Show Links.
    var linkRef: ItemRef { .pullRequest(organization: organization, number: number) }
}

extension WorkItem {
    /// The work item, for Show Links.
    var linkRef: ItemRef { .workItem(organization: organization, id: id) }
}

extension WorkItemKey {
    /// The work item, for Show Links and the Map.
    var linkRef: ItemRef { .workItem(organization: organization, id: id) }
}

/// A pull request's links on its row, but for the task Copilot is doing on it, which its own capsule shows.
struct PullRequestLinks: View {
    let key: PRKey
    var opensMenu = false
    /// What else it leaves out, as what shows them says them already, such as the work items a Board card names.
    var excluding: Set<ItemRef> = []
    /// Above and below the capsules, to sit level with taller controls beside them, as a Board card's stage pill.
    var inset: CGFloat = 0

    @EnvironmentObject private var copilot: CopilotTasksStore

    var body: some View {
        LinkCapsules(
            key.linkRef, excluding: Self.session(of: copilot.isOn ? copilot.latest(forPullRequest: key) : nil).union(excluding),
            opensMenu: opensMenu, inset: inset
        )
    }

    static func session(of entry: CopilotTaskEntry?) -> Set<ItemRef> {
        entry.flatMap { ItemRef.session($0.id) }.map { [$0] } ?? []
    }
}

/// A work item's links, on its card or its line, but for its latest task sent to Copilot, and the pull request that task
/// opened, which the task's own capsule shows.
struct WorkItemLinks: View {
    let item: WorkItem
    var opensMenu = true

    @EnvironmentObject private var copilot: CopilotTasksStore

    var body: some View {
        LinkCapsules(item.linkRef, excluding: Self.shown(by: copilot.isOn ? copilot.latest(for: item) : nil), opensMenu: opensMenu)
    }

    /// What a task's capsule shows already: its session, and the pull request it opened once it's done.
    static func shown(by entry: CopilotTaskEntry?) -> Set<ItemRef> {
        guard let entry else { return [] }
        var shown = PullRequestLinks.session(of: entry)
        if entry.opensPullRequest, let opened = entry.pullRequest.flatMap({ ItemRef.from(link: $0.absoluteString) }) {
            shown.insert(opened)
        }
        return shown
    }
}
