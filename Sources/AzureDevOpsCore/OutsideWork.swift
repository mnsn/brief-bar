import BriefBarCore
import Foundation

/// Your open tasks and bugs in the sprint's project that its board doesn't have, for My Work: in other sprints, at other
/// iteration paths, or in none, as Azure DevOps' Assigned to me query finds them. Read with the sprint, only while My Work
/// wants them (`SprintEngine.setReadsOutside`), and kept in memory only.
public struct OutsideWork: Sendable, Equatable {
    /// Yours, in order (`yours`).
    public var items: [WorkItem]
    /// The path of the sprint they're outside of; nil when the team has no sprint today.
    public var sprintPath: String?
    /// The query found more assigned to you than it listed: there may be more of them.
    public var isPartial: Bool
    /// When they were read; nil until a read got them.
    public var readAt: Date?
    /// Why the last read failed, as Azure DevOps or the network said it, over what was read before; nil once one didn't.
    public var problem: String?
    /// The types that are cards on the team's task board, such as Task: one of another, a bug, is its own story.
    public var taskTypes: Set<String>

    public init(
        items: [WorkItem] = [], sprintPath: String? = nil, isPartial: Bool = false, readAt: Date? = nil, problem: String? = nil,
        taskTypes: Set<String> = ["Task"]
    ) {
        self.items = items
        self.sprintPath = sprintPath
        self.isPartial = isPartial
        self.readAt = readAt
        self.problem = problem
        self.taskTypes = taskTypes
    }

    /// What a card says of one in no sprint, at its project's root.
    public static let noSprint = "No sprint"

    /// How many of them aren't in the sprint's iteration, what My Work's line counts: those in its iteration that its board
    /// doesn't have, such as one under another team's area, have cards, but aren't counted.
    public var count: Int {
        items.filter { !isInSprint($0) }.count
    }

    /// How many of those are bugs, by their type's name, which the line counts apart from tasks.
    public var bugCount: Int {
        items.filter { !isInSprint($0) && $0.type.caseInsensitiveCompare("Bug") == .orderedSame }.count
    }

    /// The story a work item is for, whose mission's lane it goes in, as the sprint has it: its parent, for a task; itself,
    /// for a bug, which has no tasks of yours (`yours`).
    public func story(of item: WorkItem) -> ItemRef? {
        guard taskTypes.contains(where: { $0.caseInsensitiveCompare(item.type) == .orderedSame }) else {
            return .workItem(organization: item.organization, id: item.id)
        }
        return item.parentId.map { .workItem(organization: item.organization, id: $0) }
    }

    /// Whether a work item is in the sprint's own iteration, whatever the letter case of its path.
    public func isInSprint(_ item: WorkItem) -> Bool {
        guard let sprintPath, let path = item.iteration else { return false }
        return path.caseInsensitiveCompare(sprintPath) == .orderedSame
    }

    /// Where one of yours is, as its card says: its iteration's name, the last part of its path, such as "Sprint 38", or "No
    /// sprint" for the project's own, its root; nil for one in the sprint's own iteration, or read without its iteration.
    public func place(of item: WorkItem) -> String? {
        guard !isInSprint(item), let path = item.iteration else { return nil }
        let parts = path.split(separator: "\\", omittingEmptySubsequences: true)
        guard parts.count > 1, let last = parts.last else { return Self.noSprint }
        return String(last)
    }

    /// Without what the sprint's board has now: one moved into the sprint since a read that failed after, which the board
    /// shows.
    public func without(_ board: SprintBoard?) -> OutsideWork {
        guard let board else { return self }
        let onBoard = Set(board.items.map(\.id))
        var work = self
        work.items = items.filter { !onBoard.contains($0.id) }
        return work
    }

    /// Your open tasks and bugs among the work items the query found, that the sprint's board doesn't have: not resolved,
    /// done or removed, as their states' categories say; of the team's task types, such as Task, or bugs. A bug that's the
    /// parent of a task of yours, outside the sprint or on its board, is left out, as the sprint leaves out a story or bug
    /// with tasks: the tasks are the work. In order: by iteration, the latest name first (Sprint 41 before Sprint 38), those in
    /// no sprint last; in one iteration, in backlog order.
    /// - Parameters:
    ///   - found: the work items assigned to you, as the query lists them, read with their iterations.
    ///   - taskTypes: the types that are cards on the team's task board, such as Task.
    public static func yours(_ found: [WorkItem], board: SprintBoard?, taskTypes: Set<String>) -> [WorkItem] {
        let onBoard = Set((board?.items ?? []).map(\.id))
        let tasks = Set(taskTypes.map { $0.lowercased() })
        let isTask = { (item: WorkItem) in tasks.contains(item.type.lowercased()) }
        let yourTasks = found.filter { isTask($0) && $0.category != .removed } + (board.map { board in
            board.tasks.filter { $0.isAssigned(to: board.me) }
        } ?? [])
        let parents = Set(yourTasks.compactMap(\.parentId))
        var seen: Set<Int> = []
        let yours = found.filter { item in
            guard !onBoard.contains(item.id), item.category == .proposed || item.category == .inProgress else { return false }
            // A bug with tasks of yours under it is theirs to show, whether or not the team tracks bugs as tasks.
            let isBug = item.type.caseInsensitiveCompare("Bug") == .orderedSame
            guard isTask(item) || isBug, !(isBug && parents.contains(item.id)) else { return false }
            return seen.insert(item.id).inserted
        }
        return yours.sorted { lhs, rhs in
            let left = sprintPath(of: lhs)
            let right = sprintPath(of: rhs)
            switch (left, right) {
            case (nil, .some): return false
            case (.some, nil): return true
            case let (.some(left), .some(right)):
                let order = left.compare(right, options: [.numeric, .caseInsensitive])
                if order != .orderedSame { return order == .orderedDescending }
                return WorkItem.ordered(lhs, rhs)
            case (nil, nil):
                return WorkItem.ordered(lhs, rhs)
            }
        }
    }

    /// The path of a work item's sprint, nil for one in none: at its project's root, or read without its iteration.
    private static func sprintPath(of item: WorkItem) -> String? {
        guard let path = item.iteration, path.split(separator: "\\", omittingEmptySubsequences: true).count > 1 else { return nil }
        return path
    }
}

extension SprintBoard {
    /// Every work item on it: its stories and bugs, and their tasks.
    public var items: [WorkItem] {
        rows.flatMap { ($0.parent.map { [$0] } ?? []) + $0.tasks }
    }
}
