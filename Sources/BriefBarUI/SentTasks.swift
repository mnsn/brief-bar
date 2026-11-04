import BriefBarCore
import Combine
import SwiftUI

/// A task BriefBar sent to the Copilot CLI on your request, such as fixing a pull request's comments. Copilot works on it
/// on its own, in a session of its own that the Copilot app doesn't list, so the GitHub Copilot list shows it with the
/// app's sessions.
package struct SentTask: Identifiable {
    /// How it stands.
    package enum Stage: String, Sendable, CaseIterable {
        /// Getting its worktree ready, before Copilot starts.
        case starting
        case working
        /// Copilot called it done.
        case finished
        /// It couldn't start, or Copilot reported an error.
        case failed
        /// It ended before Copilot called it done.
        case stopped
    }

    /// Its Copilot session's ID.
    package var id: String
    /// What it's for, such as "Fix Comments: !4071 Fix the checkout total".
    package var name: String
    /// Where it works, such as its repository.
    package var place: String?
    package var stage: Stage
    /// What it's doing while it works, how it ended, or why it failed.
    package var detail: String?
    /// When it got to its stage.
    package var since: Date?
    /// You stopped it: there's nothing to look at.
    package var stoppedByYou: Bool
    /// What clicking it opens, such as "Pull Request" or "Work Item".
    package var opens: String
    /// Where that lives, such as "Azure DevOps", which opening it there says (`openTitle`).
    package var livesIn: String?
    /// Opens what it's for where it lives, such as its pull request in Azure DevOps.
    package var open: () -> Void
    /// Whether what it's for shows in BriefBar's window too, as it is now: its pull request, while a window has the Pull
    /// Requests page and its list has it. Never for a work item.
    package var canShow: () -> Bool
    /// Shows what it's for in BriefBar's window, such as its pull request's details: whether it could, for `open` to open
    /// it where it lives instead.
    package var show: () -> Bool
    /// Whether a click in the menu bar or a widget shows what it's for in BriefBar's window, where it can, rather than
    /// opening it where it lives: as a pull request's own row does there, once you chose to Open Pull Requests in BriefBar.
    /// From a page of the window, a click shows it there wherever it can.
    package var showsFromMenuBar: () -> Bool
    /// Its own menu items, after the ones that open it: go on with it in Terminal, show its worktree, stop it…
    package var menu: () -> AnyView

    package init(
        id: String, name: String, place: String?, stage: Stage, detail: String?, since: Date?, stoppedByYou: Bool = false,
        opens: String, livesIn: String? = nil, open: @escaping () -> Void, canShow: @escaping () -> Bool = { false },
        show: @escaping () -> Bool = { false }, showsFromMenuBar: @escaping () -> Bool = { false }, menu: @escaping () -> AnyView
    ) {
        self.id = id
        self.name = name
        self.place = place
        self.stage = stage
        self.detail = detail
        self.since = since
        self.stoppedByYou = stoppedByYou
        self.opens = opens
        self.livesIn = livesIn
        self.open = open
        self.canShow = canShow
        self.show = show
        self.showsFromMenuBar = showsFromMenuBar
        self.menu = menu
    }

    /// "Open Pull Request in Azure DevOps", for menus: where it lives.
    package var openTitle: String { "Open \(opens)" + (livesIn.map { " in \($0)" } ?? "") }

    /// "Show Pull Request in BriefBar", for menus.
    package var showTitle: String { "Show \(opens) in BriefBar" }

    /// Whether a click shows what it's for in BriefBar's window rather than where it lives: where it can, from a page of the
    /// window (`inWindow`), and from the menu bar or a widget as you chose (`showsFromMenuBar`).
    package func clickShows(inWindow: Bool) -> Bool {
        (inWindow || showsFromMenuBar()) && canShow()
    }

    /// What a click does, for its menu's first item: `showTitle` or `openTitle`.
    package func clickTitle(inWindow: Bool) -> String {
        clickShows(inWindow: inWindow) ? showTitle : openTitle
    }

    /// A click, from a page of BriefBar's window (`inWindow`), or else the menu bar or a widget: what it's for in the
    /// window, where a click shows it (`clickShows`), or else where it lives.
    package func click(inWindow: Bool) {
        if clickShows(inWindow: inWindow), show() { return }
        open()
    }

    /// What its menu has after what a click does: the other way to what it's for, where it lives or in BriefBar's window,
    /// when there's one.
    package func otherOpening(inWindow: Bool) -> (title: String, action: () -> Void)? {
        if clickShows(inWindow: inWindow) { return (openTitle, open) }
        guard canShow() else { return nil }
        return (showTitle, { if !show() { open() } })
    }
}

/// What the views compare to tell whether a task changed: everything but what its actions do.
extension SentTask: Equatable {
    package static func == (lhs: SentTask, rhs: SentTask) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.place == rhs.place && lhs.stage == rhs.stage && lhs.detail == rhs.detail
            && lhs.since == rhs.since && lhs.stoppedByYou == rhs.stoppedByYou && lhs.opens == rhs.opens && lhs.livesIn == rhs.livesIn
    }
}

/// The tasks BriefBar sent to the Copilot CLI, as the source that sends them says, for the GitHub Copilot list to show
/// with the Copilot app's sessions. Only in memory: the source that sent them keeps what it needs.
@MainActor
package final class SentTasks: ObservableObject {
    /// Every source's, each once.
    @Published package private(set) var tasks: [SentTask] = []
    private var bySource: [SourceID: [SentTask]] = [:]

    package init() {}

    /// What a source has sent, as it stands now: it replaces what it said before.
    package func publish(_ source: SourceID, tasks: [SentTask]) {
        guard bySource[source] != tasks else { return }
        bySource[source] = tasks
        rebuild()
    }

    /// A source stopped, or stopped sending: its tasks go with it.
    package func withdraw(_ source: SourceID) {
        guard bySource.removeValue(forKey: source) != nil else { return }
        rebuild()
    }

    private func rebuild() {
        var seen: Set<String> = []
        let all = SourceID.allCases.flatMap { bySource[$0] ?? [] }.filter { seen.insert($0.id).inserted }
        if all != tasks { tasks = all }
    }
}
