import Foundation

// My Work's + Sprint Tasks, while My Work Page is on: your open sprint work on the Board, with your pull requests. A work
// item that hasn't started is a card in To start, a column before In progress; one that has, with no pull request on the
// board, a card in In progress, after its pull requests; one with a pull request on the board has no card of its own: that
// pull request's card names it. Work items and pull requests go together only through Show Links' links, never by their
// states. Only how they're shown: no stage, Up Next slot, row, count or agent's answer changes for it, and nothing is read
// for it but the sprint, as while its Sprint section is on screen.

/// One of your work items in the sprint that isn't done: your task, or your story or bug without tasks, as the sprint's
/// own count of what's left has them (`SprintBoard.myWork`), with what the Board needs of it.
public struct SprintWork: Equatable, Sendable, Identifiable {
    /// How far along it is, by its state's category.
    public enum Progress: Equatable, Sendable {
        /// Not started, as New or To Do are.
        case toDo
        /// Started.
        case inProgress
        /// Resolved: it shows only on the card of a pull request of its on the board.
        case resolved
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
    }

    public var work: SprintWork
    public var column: Column
    public var why: Why
    /// Its pull request that was abandoned, which counts as none, for its card to say so.
    public var abandoned: ItemRef?

    public var id: ItemRef { work.ref }
    public var ref: ItemRef { work.ref }

    /// Where a work item goes with none of its pull requests on the board: In progress, for one with a pull request of
    /// another kind, then for one a Copilot task works on; else To start until it's started. Nil for one that's resolved.
    public init?(_ work: SprintWork) {
        guard work.progress != .resolved else { return nil }
        self.work = work
        let first = work.pullRequests.enumerated().min { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }?.element
        abandoned = first?.state == .abandoned ? first?.ref : nil
        if let first, first.state != .abandoned {
            column = .inProgress
            why = .pullRequest(first)
        } else if work.copilotWorks {
            column = .inProgress
            why = .copilot
        } else if work.progress == .toDo {
            column = .toStart
            why = .notStarted
        } else {
            column = .inProgress
            why = .started
        }
    }
}

/// A column of the Board, from left to right: To start, while it shows your sprint work, then each stage's.
public enum BoardColumn: Hashable, Sendable {
    case toStart
    case stage(PullRequestStage)

    /// Its stage, for a stage's column.
    public var stage: PullRequestStage? {
        if case .stage(let stage) = self { return stage }
        return nil
    }
}

extension BoardLane {
    /// Its work items' cards in a column, in the sprint's order.
    public func tasks(in column: BoardTask.Column) -> [BoardTask] {
        tasks.filter { $0.column == column }
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
        (showsWork ? [.toStart] : []) + PullRequestStage.columns.map(BoardColumn.stage)
    }

    /// How many cards a column has, each once, whatever lanes show it: In progress's pull requests with its work items'.
    public func count(of column: BoardColumn) -> Int {
        switch column {
        case .toStart: taskCounts[.toStart] ?? 0
        case .stage(let stage): (counts[stage] ?? 0) + (stage == .inProgress ? taskCounts[.inProgress] ?? 0 : 0)
        }
    }

    /// The board with your sprint work on it, for My Work's + Sprint Tasks: a card for each work item with no pull request
    /// on the board, in its story's mission's lane, else, with a lane for each mission, in a lane for its story, after the
    /// missions', where the sprint has that story, else in the lane of those in no mission; and, for each pull request on the
    /// board, the work items linked to it, which its card names, resolved ones too.
    /// - Parameters:
    ///   - work: your work items, in the sprint's order, which each column keeps.
    ///   - missions: the missions, as By Mission lists them, for a story's mission.
    ///   - stories: the sprint's stories and bugs, in its order: a story with no mission has a lane only if it's there.
    public func withWork(_ work: [SprintWork], missions: [OrderMission], stories: [ItemRef]) -> PullRequestBoard {
        var board = self
        board.showsWork = true
        var named: [ItemRef: [ItemRef]] = [:]
        var tasks: [BoardTask] = []
        for item in work {
            let onBoard = item.pullRequests.map(\.ref).filter(refs.contains)
            for ref in onBoard where named[ref]?.contains(item.ref) != true {
                named[ref, default: []].append(item.ref)
            }
            if onBoard.isEmpty, let task = BoardTask(item) { tasks.append(task) }
        }
        board.workOfPullRequests = named
        board.taskCounts = Dictionary(grouping: tasks, by: \.column).mapValues(\.count)

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

    /// Why a work item's card is where it is, on its card: "New", "Active · no pull request yet", "New · Copilot works on it",
    /// "Sam's !4120", "!4120 merged · task still open", and one abandoned after it, "New · !4120 abandoned".
    /// - Parameters:
    ///   - state: its state, as its process names it: "New", "Active".
    ///   - type: its type, as its process names it: "Task".
    public static func why(_ task: BoardTask, state: String, type: String) -> String {
        var parts: [String] = switch task.why {
        case .notStarted: [state]
        case .started: [state, "no pull request yet"]
        case .copilot: [state, "Copilot works on it"]
        case .pullRequest(let linked): [pullRequest(linked, type: type)]
        }
        if let abandoned = task.abandoned { parts.append("\(abandoned.shortOrderLabel) abandoned") }
        return parts.joined(separator: " · ")
    }

    /// A linked pull request that isn't on the board, by what it is: "Sam's !4120", "Your !4120", "#412 on GitHub", "!4120
    /// merged · task still open", "!4120 can't be read".
    static func pullRequest(_ linked: LinkedPullRequest, type: String) -> String {
        let label = linked.ref.shortOrderLabel
        switch linked.state {
        case .open(let author):
            if linked.ref.kind == .gitHubPullRequest { return "\(label) on GitHub" }
            return author.map { "\($0)'s \(label)" } ?? "Your \(label)"
        case .merged: return "\(label) merged · \(type.lowercased()) still open"
        case .abandoned: return "\(label) abandoned"
        case .unknown: return "\(label) can't be read"
        }
    }

    /// Why a work item's card doesn't move to another column: BriefBar changes no work item, and none of its stages is one.
    public static let workStays =
        "A work item's card moves by itself: to In progress once it's started in Azure DevOps, or a Copilot task works on it, and onto its pull request's card once one is linked to it"

    /// Why To start doesn't take a pull request's card.
    public static let toStartTakesNoPullRequest = "To start holds sprint work with no pull request: a pull request's card stays in its stage's column"
}
