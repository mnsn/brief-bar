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
    package var open: () -> Void
    /// Its own menu items, after the one that opens it: go on with it in Terminal, show its worktree, stop it…
    package var menu: () -> AnyView

    package init(
        id: String, name: String, place: String?, stage: Stage, detail: String?, since: Date?, stoppedByYou: Bool = false,
        opens: String, open: @escaping () -> Void, menu: @escaping () -> AnyView
    ) {
        self.id = id
        self.name = name
        self.place = place
        self.stage = stage
        self.detail = detail
        self.since = since
        self.stoppedByYou = stoppedByYou
        self.opens = opens
        self.open = open
        self.menu = menu
    }

    /// "Open Pull Request", for menus.
    package var openTitle: String { "Open \(opens)" }
}

/// What the views compare to tell whether a task changed: everything but what its actions do.
extension SentTask: Equatable {
    package static func == (lhs: SentTask, rhs: SentTask) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.place == rhs.place && lhs.stage == rhs.stage && lhs.detail == rhs.detail
            && lhs.since == rhs.since && lhs.stoppedByYou == rhs.stoppedByYou && lhs.opens == rhs.opens
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
