import Foundation

// My Work's + Sprint Tasks, while My Work Page is on: your sprint work on the Board, with your pull requests. A work item
// that hasn't started is a card in To start, a column before In progress; one that has, with no pull request on the board,
// a card in In progress, after its pull requests; one resolved, or whose pull request merged while it's still open, in
// Merged; one done in Completed, a column after Merged. One with a pull request on the board has no card of its own: that
// pull request's card names it, and once it merged, that card is in Merged until it's out, its pipelines after the merge
// done, and every work item of yours it names is done; then in Completed. Work items and pull requests go together only
// through Show Links' links, never by their states. Only how they're shown: no stage, Up Next slot, row, count or agent's
// answer changes for it, and nothing is read for it but the sprint, as while its Sprint section is on screen.

/// One of your work items in the sprint: your task, or your story or bug without tasks, as the sprint's own counts have
/// them, what's left (`SprintBoard.myWork`) and what's done (`SprintBoard.myDone`), with what the Board needs of it.
public struct SprintWork: Equatable, Sendable, Identifiable {
    /// How far along it is, by its state's category.
    public enum Progress: Equatable, Sendable {
        /// Not started, as New or To Do are.
        case toDo
        /// Started.
        case inProgress
        /// Resolved: done, but not closed yet.
        case resolved
        /// Done, as Closed is.
        case completed
    }

    public var ref: ItemRef
    /// The story it's for, whose mission's lane it goes in: its parent, for a task; itself, for a story or bug of yours
    /// without tasks; nil for a task with no parent.
    public var story: ItemRef?
    public var progress: Progress
    /// The pull requests Show Links links it to, each with what's known of it.
    public var pullRequests: [LinkedPullRequest]
    /// A task you sent to Copilot works on it now.
    public var copilotWorks: Bool

    public init(
        ref: ItemRef, story: ItemRef? = nil, progress: Progress, pullRequests: [LinkedPullRequest] = [], copilotWorks: Bool = false
    ) {
        self.ref = ref
        self.story = story
        self.progress = progress
        self.pullRequests = pullRequests
        self.copilotWorks = copilotWorks
    }

    public var id: ItemRef { ref }
}

/// A pull request linked to a work item, with what its source knows of it: for where the work item's card goes while the
/// pull request isn't on the board.
public struct LinkedPullRequest: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Open: someone else's, by their first name; nil for yours, and for one on GitHub, whose author isn't known.
        case open(author: String?)
        case merged
        /// Closed without merging: as if the work item had none.
        case abandoned
        /// BriefBar couldn't read what it is.
        case unknown
    }

    public var ref: ItemRef
    public var state: State

    public init(ref: ItemRef, state: State) {
        self.ref = ref
        self.state = state
    }

    /// Which counts first for a work item linked to several, none on the board: an open one, then one that merged, then
    /// one BriefBar couldn't read; one abandoned only for its card to say so.
    var rank: Int {
        switch state {
        case .open: 0
        case .merged: 1
        case .unknown: 2
        case .abandoned: 3
        }
    }
}

/// A work item's own card on the Board: one of yours in the sprint with no pull request on the board.
public struct BoardTask: Equatable, Sendable, Identifiable {
    public enum Column: Equatable, Sendable, CaseIterable {
        /// Not started: a column of its own, before In progress.
        case toStart
        /// Started: in In progress, after its pull requests.
        case inProgress
        /// Resolved, or its pull request merged while it's still open: in Merged, after the pull requests.
        case merged
        /// Done: a column of its own, after Merged.
        case completed
    }

    /// Why it's where it is, as its card says.
    public enum Why: Equatable, Sendable {
        case notStarted
        /// Started, with no pull request yet.
        case started
        /// A task you sent to Copilot works on it.
        case copilot
        /// It has a pull request, but not on your board: someone else's, one on GitHub, one that merged while the work item is
        /// still open, or one BriefBar couldn't read.
        case pullRequest(LinkedPullRequest)
        /// Resolved, with no pull request.
        case resolved
        /// Done, with the pull request it has, if any.
        case done(LinkedPullRequest?)
    }

    public var work: SprintWork
    public var column: Column
    public var why: Why
    /// Its pull request that was abandoned, which counts as none, for its card to say so.
    public var abandoned: ItemRef?

    public var id: ItemRef { work.ref }
    public var ref: ItemRef { work.ref }

    /// Where a work item goes with none of its pull requests on the board: Completed, once it's done, whatever its pull
    /// requests are; else, with a pull request of another kind, Merged for one that merged and In progress for the rest; then
    /// In progress for one a Copilot task works on; Merged for one resolved; else To start until it's started.
    public init(_ work: SprintWork) {
        self.work = work
        let first = work.pullRequests.enumerated().min { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }?.element
        abandoned = first?.state == .abandoned ? first?.ref : nil
        let linked = first?.state == .abandoned ? nil : first
        if work.progress == .completed {
            column = .completed
            why = .done(linked)
        } else if let linked {
            column = linked.state == .merged ? .merged : .inProgress
            why = .pullRequest(linked)
        } else if work.copilotWorks {
            column = .inProgress
            why = .copilot
        } else if work.progress == .resolved {
            column = .merged
            why = .resolved
        } else if work.progress == .toDo {
            column = .toStart
            why = .notStarted
        } else {
            column = .inProgress
            why = .started
        }
    }
}

/// A column of the Board, from left to right: To start, while it shows your sprint work, then each stage's, then Completed,
/// while it shows your sprint work.
public enum BoardColumn: Hashable, Sendable {
    case toStart
    case stage(PullRequestStage)
    /// What you finished: your work that's done, and your pull requests that are out, with your work on them done.
    case completed

    /// Its stage, for a stage's column.
    public var stage: PullRequestStage? {
        if case .stage(let stage) = self { return stage }
        return nil
    }

    /// The column a work item's card is in.
    public init(_ column: BoardTask.Column) {
        switch column {
        case .toStart: self = .toStart
        case .inProgress: self = .stage(.inProgress)
        case .merged: self = .stage(.merged)
        case .completed: self = .completed
        }
    }
}

extension BoardLane {
    /// Its work items' cards in a column, in the sprint's order.
    public func tasks(in column: BoardTask.Column) -> [BoardTask] {
        tasks.filter { $0.column == column }
    }

    /// Its pull requests' cards in a column, in the order they come there: in Merged, those that aren't in Completed.
    public func cards(in column: BoardColumn) -> [BoardCard] {
        switch column {
        case .toStart: []
        case .stage(.merged): cards(in: .merged).filter { !completed.contains($0.ref) }
        case .stage(let stage): cards(in: stage)
        case .completed: cards(in: .merged).filter { completed.contains($0.ref) }
        }
    }

    /// The story whose lane it is, for one of a story without a mission.
    public var story: ItemRef? {
        if case .story(let ref) = kind { return ref }
        return nil
    }
}

extension PullRequestBoard {
    /// Its columns, from left to right: what its widths and its column titles are made from.
    public var columns: [BoardColumn] {
        (showsWork ? [.toStart] : []) + PullRequestStage.columns.map(BoardColumn.stage) + (showsWork ? [.completed] : [])
    }

    /// How many cards a column has, each once, whatever lanes show it: a stage's pull requests, but those in Completed, with
    /// its work items'.
    public func count(of column: BoardColumn) -> Int {
        switch column {
        case .toStart: taskCounts[.toStart] ?? 0
        case .stage(.inProgress): (counts[.inProgress] ?? 0) + (taskCounts[.inProgress] ?? 0)
        case .stage(.merged): (counts[.merged] ?? 0) - completed.count + (taskCounts[.merged] ?? 0)
        case .stage(let stage): counts[stage] ?? 0
        case .completed: completed.count + (taskCounts[.completed] ?? 0)
        }
    }

    /// The board with your sprint work on it, for My Work's + Sprint Tasks: a card for each work item with no pull request
    /// on the board, in its story's mission's lane, else, with a lane for each mission, in a lane for its story, after the
    /// missions', where the sprint has that story, else in the lane of those in no mission; and, for each pull request on the
    /// board, the work items linked to it, which its card names, done ones too. A merged pull request's card goes in
    /// Completed once it's out and every work item of yours it names is done, one with none too.
    /// - Parameters:
    ///   - work: your work items, in the sprint's order, which each column keeps.
    ///   - missions: the missions, as By Mission lists them, for a story's mission.
    ///   - stories: the sprint's stories and bugs, in its order: a story with no mission has a lane only if it's there.
    ///   - isOut: whether a merged pull request of yours is out, its pipelines after the merge done, as far as its source
    ///     knows.
    public func withWork(
        _ work: [SprintWork], missions: [OrderMission], stories: [ItemRef], isOut: (ItemRef) -> Bool = { _ in true }
    ) -> PullRequestBoard {
        var board = self
        board.showsWork = true
        var named: [ItemRef: [ItemRef]] = [:]
        var done: Set<ItemRef> = []
        var tasks: [BoardTask] = []
        for item in work {
            if item.progress == .completed { done.insert(item.ref) }
            let onBoard = item.pullRequests.map(\.ref).filter(refs.contains)
            for ref in onBoard where named[ref]?.contains(item.ref) != true {
                named[ref, default: []].append(item.ref)
            }
            if onBoard.isEmpty { tasks.append(BoardTask(item)) }
        }
        board.workOfPullRequests = named
        board.taskCounts = Dictionary(grouping: tasks, by: \.column).mapValues(\.count)
        let merged = Set(lanes.flatMap { $0.cards(in: PullRequestStage.merged) }.map(\.ref))
        board.completed = merged.filter { ref in isOut(ref) && (named[ref] ?? []).allSatisfy(done.contains) }
        for index in board.lanes.indices {
            board.lanes[index].completed = board.completed.intersection(board.lanes[index].cards(in: PullRequestStage.merged).map(\.ref))
        }

        let shown = missions.filter { $0.shows(kinds) }
        var byLane: [BoardLane.Kind: [BoardTask]] = [:]
        for task in tasks {
            byLane[lane(for: task.work, missions: shown, stories: stories), default: []].append(task)
        }
        for index in board.lanes.indices {
            board.lanes[index].tasks = byLane.removeValue(forKey: board.lanes[index].kind) ?? []
        }
        let storyLanes = stories.compactMap { story in
            byLane.removeValue(forKey: .story(story)).map { BoardLane(kind: .story(story), columns: [:], tasks: $0) }
        }
        board.lanes.insert(contentsOf: storyLanes, at: board.lanes.firstIndex { $0.kind == .notInAMission } ?? board.lanes.endIndex)
        for kind in [BoardLane.Kind.notInAMission, .all] {
            if let rest = byLane[kind] { board.lanes.append(BoardLane(kind: kind, columns: [:], tasks: rest)) }
        }
        return board
    }

    /// The lane a work item's card goes in.
    private func lane(for work: SprintWork, missions: [OrderMission], stories: [ItemRef]) -> BoardLane.Kind {
        guard mode == .missions else { return .all }
        guard let story = work.story else { return .notInAMission }
        if let mission = missions.first(where: { $0.story?.ref == story }), lanes.contains(where: { $0.mission == mission.key }) {
            return .mission(mission.key)
        }
        // A story or bug of yours without tasks has no lane of its own: its header would say what its one card does.
        return story != work.ref && stories.contains(story) ? .story(story) : .notInAMission
    }
}

extension BoardText {
    /// To start's title on the Board.
    public static let toStart = "To start"

    /// What To start holds, for its title's tooltip.
    public static let toStartHelp = "Your sprint work that hasn't started: no pull request is linked to it, and no Copilot task works on it"

    /// Completed's title on the Board.
    public static let completed = "Completed"

    /// Its marker, where other columns have a dot: the Sprint page's Done.
    public static let completedSymbol = "checkmark.circle.fill"

    /// What Completed holds.
    public static let completedHolds =
        "your sprint work that's done, and your merged pull requests once their pipelines after the merge are done and your work they're for is done"

    /// What Completed holds, for its title's tooltip.
    public static let completedHelp = "What you finished: " + completedHolds

    /// What Merged holds while the board shows your sprint work, for its title's tooltip.
    public static let mergedWithWorkHelp =
        "Merged, but not out yet: its pipelines after the merge still run, wait or failed, or your work it's for is still open; and your sprint work that's resolved, or whose pull request merged while it's still open"

    /// Why a work item's card is where it is, on its card: "New", "Active · no pull request yet", "New · Copilot works on it",
    /// "Sam's !4120", "!4120 merged · task still open", "Resolved", "Resolved · !4120 merged", "Closed", "Closed · !4120
    /// merged", and one abandoned after it, "New · !4120 abandoned".
    /// - Parameters:
    ///   - state: its state, as its process names it: "New", "Active".
    ///   - type: its type, as its process names it: "Task".
    public static func why(_ task: BoardTask, state: String, type: String) -> String {
        var parts: [String] = switch task.why {
        case .notStarted, .resolved: [state]
        case .started: [state, "no pull request yet"]
        case .copilot: [state, "Copilot works on it"]
        case .pullRequest(let linked) where task.work.progress == .resolved: [state, pullRequest(linked)]
        case .pullRequest(let linked): [pullRequest(linked, type: type)]
        case .done(let linked): [state] + (linked.map { [pullRequest($0)] } ?? [])
        }
        if let abandoned = task.abandoned { parts.append("\(abandoned.shortOrderLabel) abandoned") }
        return parts.joined(separator: " · ")
    }

    /// A linked pull request that isn't on the board, by what it is, for a work item that's still open: "Sam's !4120", "Your
    /// !4120", "#412 on GitHub", "!4120 merged · task still open", "!4120 can't be read".
    static func pullRequest(_ linked: LinkedPullRequest, type: String) -> String {
        linked.state == .merged ? "\(linked.ref.shortOrderLabel) merged · \(type.lowercased()) still open" : pullRequest(linked)
    }

    /// The same, after the state of a work item that's resolved or done: "Sam's !4120", "!4120 merged".
    static func pullRequest(_ linked: LinkedPullRequest) -> String {
        let label = linked.ref.shortOrderLabel
        switch linked.state {
        case .open(let author):
            if linked.ref.kind == .gitHubPullRequest { return "\(label) on GitHub" }
            return author.map { "\($0)'s \(label)" } ?? "Your \(label)"
        case .merged: return "\(label) merged"
        case .abandoned: return "\(label) abandoned"
        case .unknown: return "\(label) can't be read"
        }
    }

    /// Why a work item's card doesn't move to another column: BriefBar changes no work item, and none of its stages is one.
    public static let workStays =
        "A work item's card moves by itself, as its work does in Azure DevOps: to In progress once it's started, or a Copilot task works on it; onto its pull request's card once one is linked to it; to Merged once it's resolved, and to Completed once it's done"

    /// Why Completed doesn't take a pull request's card that isn't there.
    public static let completedTakesNoPullRequest =
        "A pull request goes to Completed by itself, once it merged, its pipelines after the merge are done and your work it's for is done"

    /// Why To start doesn't take a pull request's card.
    public static let toStartTakesNoPullRequest = "To start holds sprint work with no pull request: a pull request's card stays in its stage's column"
}
