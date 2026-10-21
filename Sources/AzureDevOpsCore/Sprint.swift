import BriefBarCore
import Foundation

/// One of your teams, whose current sprint the Sprint page shows.
public struct TeamRef: Sendable, Codable, Hashable, Identifiable {
    public var organization: String
    public var projectId: String
    public var projectName: String
    /// The team's ID.
    public var id: String
    public var name: String

    public init(organization: String, projectId: String, projectName: String, id: String, name: String) {
        self.organization = organization
        self.projectId = projectId
        self.projectName = projectName
        self.id = id
        self.name = name
    }

    /// Nil when Azure DevOps didn't say which project the team is in.
    public init?(organization: String, _ dto: ADOTeam) {
        guard let projectId = dto.projectId, let projectName = dto.projectName else { return nil }
        self.init(organization: organization, projectId: projectId, projectName: projectName, id: dto.id, name: dto.name)
    }

    /// The sprint's task board in Azure DevOps.
    public func taskboardURL(sprint: Sprint?) -> URL {
        // The sprint's path (which starts with the project) picks the sprint; without it, the current one.
        let path = sprint.map { $0.path.split(separator: "\\").map(String.init) } ?? []
        return ADOEndpoint.url("https://dev.azure.com", [organization, projectName, "_sprints", "taskboard", name] + path, [])
    }
}

/// A team's sprint: an iteration with dates.
public struct Sprint: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Such as `Storefront\Sprint 42`.
    public var path: String
    /// The first and last days. Azure DevOps keeps days, not times: midnight UTC.
    public var start: Date?
    public var finish: Date?

    public init(id: String, name: String, path: String, start: Date?, finish: Date?) {
        self.id = id
        self.name = name
        self.path = path
        self.start = start
        self.finish = finish
    }

    public init(_ dto: ADOIteration) {
        self.init(id: dto.id, name: dto.name, path: dto.path ?? dto.name, start: dto.attributes?.startDate, finish: dto.attributes?.finishDate)
    }

    /// Days left, today and the last day included: 0 once it's over. Nil without dates.
    public func daysLeft(now: Date, calendar: Calendar = .current) -> Int? {
        guard let first = SprintDay.number(start), let last = SprintDay.number(finish) else { return nil }
        let today = SprintDay.today(now, calendar: calendar)
        return max(0, last - max(today, first) + 1)
    }

    /// Its length in days.
    public var length: Int? {
        guard let first = SprintDay.number(start), let last = SprintDay.number(finish), last >= first else { return nil }
        return last - first + 1
    }

    /// Which day of the sprint today is, from 1, within its length.
    public func day(now: Date, calendar: Calendar = .current) -> Int? {
        guard let first = SprintDay.number(start), let length else { return nil }
        return min(max(SprintDay.today(now, calendar: calendar) - first + 1, 1), length)
    }

    /// How much of the sprint has gone by, from 0 before it starts to 1 once it's over, counting today as half gone.
    public func elapsed(now: Date, calendar: Calendar = .current) -> Double? {
        guard let first = SprintDay.number(start), let length else { return nil }
        let gone = Double(SprintDay.today(now, calendar: calendar) - first) + 0.5
        return min(max(gone / Double(length), 0), 1)
    }

    /// Whether today is one of its days.
    public func isCurrent(now: Date, calendar: Calendar = .current) -> Bool {
        guard let first = SprintDay.number(start), let last = SprintDay.number(finish) else { return false }
        return (first...max(first, last)).contains(SprintDay.today(now, calendar: calendar))
    }
}

/// Sprint days as day numbers: a sprint's dates are days in UTC, and today is the day it is here.
enum SprintDay {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func number(_ date: Date?) -> Int? {
        guard let date else { return nil }
        return number(utc.dateComponents([.year, .month, .day], from: date))
    }

    static func today(_ now: Date, calendar: Calendar) -> Int {
        // The day it is in the calendar's time zone, as a Gregorian date like the sprint's, whatever calendar the
        // Mac uses (Buddhist, Persian, Hebrew...).
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return number(gregorian.dateComponents([.year, .month, .day], from: now)) ?? 0
    }

    private static func number(_ components: DateComponents) -> Int? {
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return Timestamp.daysFromCivil(year: year, month: month, day: day)
    }

    /// Midnight UTC of the day that's `offset` days from today here: how Azure DevOps keeps a sprint's dates.
    static func date(daysFromToday offset: Int, now: Date, calendar: Calendar = .current) -> Date {
        Date(timeIntervalSince1970: TimeInterval((today(now, calendar: calendar) + offset) * 86_400))
    }
}

/// A story, bug or task, with the fields the Sprint page shows.
public struct WorkItem: Sendable, Codable, Equatable, Identifiable {
    /// The category Azure DevOps puts each state in, whatever the process calls it.
    public enum Category: String, Sendable, Codable, CaseIterable {
        case proposed, inProgress, resolved, completed, removed

        /// From the team's state mapping (`InProgress`), or guessed from the state's name when there's none.
        public init(category: String?, state: String) {
            switch category?.lowercased() {
            case "proposed": self = .proposed
            case "inprogress": self = .inProgress
            case "resolved": self = .resolved
            case "completed": self = .completed
            case "removed": self = .removed
            default:
                switch state.lowercased() {
                case "new", "to do", "proposed", "approved", "design", "ready to code": self = .proposed
                case "resolved": self = .resolved
                case "closed", "done", "completed", "inactive": self = .completed
                case "removed", "cut": self = .removed
                default: self = .inProgress
                }
            }
        }

        /// The task board column it's in. Removed work items aren't shown.
        public var column: SprintBoard.Column? {
            switch self {
            case .proposed: return .toDo
            case .inProgress, .resolved: return .inProgress
            case .completed: return .done
            case .removed: return nil
            }
        }
    }

    public var id: Int
    public var organization: String
    public var project: String
    /// Such as `User Story`, `Bug`, `Product Backlog Item` or `Task`.
    public var type: String
    public var title: String
    /// The state's name in its process, such as `Active`.
    public var state: String
    public var category: Category
    public var assignedTo: Person?
    public var parentId: Int?
    /// Hours left, for tasks that track it.
    public var remainingWork: Double?
    /// Its place in the backlog: lower comes first.
    public var rank: Double?
    public var changedAt: Date?
    public var tags: [String]

    public init(
        id: Int, organization: String, project: String, type: String, title: String, state: String, category: Category,
        assignedTo: Person? = nil, parentId: Int? = nil, remainingWork: Double? = nil, rank: Double? = nil, changedAt: Date? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.organization = organization
        self.project = project
        self.type = type
        self.title = title
        self.state = state
        self.category = category
        self.assignedTo = assignedTo
        self.parentId = parentId
        self.remainingWork = remainingWork
        self.rank = rank
        self.changedAt = changedAt
        self.tags = tags
    }

    /// `categories` maps a work item type, then a state, to its category, as the team's backlog configuration does.
    public init(organization: String, project: String, _ dto: ADOWorkItem, categories: [String: [String: String]] = [:]) {
        let fields = dto.fields
        let type = fields.workItemType ?? "Work Item"
        let state = fields.state ?? ""
        self.init(
            id: dto.id, organization: organization, project: fields.teamProject ?? project, type: type,
            title: PlainText.singleLine(fields.title ?? "Untitled"), state: state,
            category: Category(category: categories[type]?[state], state: state),
            assignedTo: fields.assignedTo.map(Person.init), parentId: fields.parent,
            remainingWork: fields.remainingWork, rank: fields.stackRank ?? fields.backlogPriority, changedAt: fields.changedDate,
            tags: (fields.tags ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
    }

    public var webURL: URL {
        ADOEndpoint.workItemPage(organization: organization, project: project, id: id)
    }

    public var isDone: Bool { category == .completed }

    public func isAssigned(to me: String) -> Bool {
        !me.isEmpty && assignedTo?.id == me.lowercased()
    }

    /// Backlog order, then ID.
    static func ordered(_ lhs: WorkItem, _ rhs: WorkItem) -> Bool {
        let left = lhs.rank ?? .greatestFiniteMagnitude
        let right = rhs.rank ?? .greatestFiniteMagnitude
        return left != right ? left < right : lhs.id < rhs.id
    }
}

/// A sprint's task board: a row for each story or bug, with its tasks in To Do, In Progress and Done.
public struct SprintBoard: Sendable, Equatable {
    public enum Column: String, Sendable, Codable, CaseIterable, Identifiable {
        case toDo, inProgress, done
        public var id: String { rawValue }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        /// The story or bug; nil for the row of tasks whose parent isn't in the sprint.
        public var parent: WorkItem?
        public var tasks: [WorkItem]

        public init(parent: WorkItem?, tasks: [WorkItem]) {
            self.parent = parent
            self.tasks = tasks
        }

        public var id: Int { parent?.id ?? 0 }

        public func tasks(in column: Column) -> [WorkItem] {
            tasks.filter { $0.category.column == column }
        }

        public var doneCount: Int { tasks.filter(\.isDone).count }

        /// The story is done, and so are its tasks.
        public var isDone: Bool {
            (parent?.isDone ?? false) && tasks.allSatisfy(\.isDone)
        }

        /// Where the story stands, from its own state and its tasks': done once it's done; in progress when it,
        /// or any of its tasks, is in progress, or some tasks are done (stories aren't always moved along);
        /// to do otherwise. For the tasks without a story, from the tasks alone.
        public var progress: Column {
            if let parent, parent.category.column == .done { return .done }
            if parent == nil, !tasks.isEmpty, tasks.allSatisfy(\.isDone) { return .done }
            if parent?.category.column == .inProgress { return .inProgress }
            if tasks.contains(where: { $0.category.column == .inProgress || $0.isDone }) { return .inProgress }
            return .toDo
        }

        /// In progress first, then to do, then done; each in backlog order.
        public var tasksInWorkOrder: [WorkItem] {
            let rank: [Column: Int] = [.inProgress: 0, .toDo: 1, .done: 2]
            return tasks.sorted { lhs, rhs in
                let left = rank[lhs.category.column ?? .toDo] ?? 1
                let right = rank[rhs.category.column ?? .toDo] ?? 1
                return left != right ? left < right : WorkItem.ordered(lhs, rhs)
            }
        }
    }

    public var team: TeamRef
    public var sprint: Sprint
    public var rows: [Row]
    /// Your identity in the team's organization, for Just Mine.
    public var me: String

    public init(team: TeamRef, sprint: Sprint, rows: [Row], me: String) {
        self.team = team
        self.sprint = sprint
        self.rows = rows
        self.me = me.lowercased()
    }

    /// Lays the sprint's work items out as a task board. `relations` are the sprint's (each work item at the top
    /// level, and each task under its parent); `taskTypes` are the types that are cards rather than rows, such as
    /// Task (and Bug, for teams that track bugs as tasks). Removed work items are left out.
    public static func build(
        team: TeamRef, sprint: Sprint, me: String, relations: [ADOIterationWorkItems.Relation], items: [WorkItem],
        taskTypes: Set<String>
    ) -> SprintBoard {
        var byId: [Int: WorkItem] = [:]
        for item in items where item.category != .removed {
            byId[item.id] = item
        }
        var roots: [Int] = []
        var children: [Int: [Int]] = [:]
        var placed: Set<Int> = []
        for relation in relations {
            let target = relation.target.id
            if let source = relation.source?.id {
                guard relation.rel == "System.LinkTypes.Hierarchy-Forward", placed.insert(target).inserted else { continue }
                children[source, default: []].append(target)
            } else if !roots.contains(target) {
                roots.append(target)
            }
        }

        var rows: [Row] = []
        var unparented: [WorkItem] = []
        let lowercasedTaskTypes = Set(taskTypes.map { $0.lowercased() })
        for id in roots where !placed.contains(id) {
            guard let item = byId[id] else {
                // A story that was removed, or can't be read: its tasks are still in the sprint.
                unparented += (children[id] ?? []).compactMap { byId[$0] }
                continue
            }
            let tasks = (children[id] ?? []).compactMap { byId[$0] }
            if tasks.isEmpty && children[id] == nil && lowercasedTaskTypes.contains(item.type.lowercased()) {
                unparented.append(item)
            } else {
                rows.append(Row(parent: item, tasks: tasks.sorted(by: WorkItem.ordered)))
            }
        }
        // Tasks under a parent that isn't a row itself, such as a task's task.
        let shownParents = Set(rows.compactMap(\.parent?.id))
        for (parent, ids) in children where !shownParents.contains(parent) && !roots.contains(parent) {
            unparented += ids.compactMap { byId[$0] }
        }
        rows.sort { lhs, rhs in WorkItem.ordered(lhs.parent!, rhs.parent!) }
        if !unparented.isEmpty {
            rows.append(Row(parent: nil, tasks: unparented.sorted(by: WorkItem.ordered)))
        }
        return SprintBoard(team: team, sprint: sprint, rows: rows, me: me)
    }

    /// Just Mine: your stories and bugs with all their tasks, and your tasks under anyone else's.
    public func justMine() -> SprintBoard {
        var board = self
        board.rows = rows.compactMap { row in
            if let parent = row.parent, parent.isAssigned(to: me) { return row }
            let mine = row.tasks.filter { $0.isAssigned(to: me) }
            return mine.isEmpty ? nil : Row(parent: row.parent, tasks: mine)
        }
        return board
    }

    public var tasks: [WorkItem] { rows.flatMap(\.tasks) }

    public func count(in column: Column) -> Int {
        tasks.filter { $0.category.column == column }.count
    }

    /// Hours left on the tasks that aren't done.
    public var remainingWork: Double {
        tasks.filter { !$0.isDone }.compactMap(\.remainingWork).reduce(0, +)
    }

    /// What you have to do: your tasks, and your stories and bugs without tasks, that aren't done. In progress
    /// first, then to do, each in backlog order.
    public var myWork: [WorkItem] {
        var items = tasks.filter { $0.isAssigned(to: me) }
        items += rows.filter(\.tasks.isEmpty).compactMap(\.parent).filter { $0.isAssigned(to: me) }
        return items
            .filter { $0.category.column == .toDo || $0.category.column == .inProgress }
            .sorted { lhs, rhs in
                let left = lhs.category.column == .inProgress ? 0 : 1
                let right = rhs.category.column == .inProgress ? 0 : 1
                return left != right ? left < right : WorkItem.ordered(lhs, rhs)
            }
    }

    /// Your tasks, and stories and bugs without tasks, that are done.
    public var myDoneCount: Int {
        let tasks = self.tasks.filter { $0.isAssigned(to: me) && $0.isDone }.count
        let parents = rows.filter(\.tasks.isEmpty).compactMap(\.parent).filter { $0.isAssigned(to: me) && $0.isDone }.count
        return tasks + parents
    }
}
