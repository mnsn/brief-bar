import Foundation

// A work item's state on the Sprint page, with Make Changes in Azure DevOps on: one of the states its type has, as the
// team's backlog configuration maps them to their categories, which the sprint engine reads already
// (`SprintBoard.stateCategories`). The change itself is `ADOWrite.setState`. What it changed shows in its new state at once
// (`SprintBoard.changingState`), until the sprint is read again.

/// A state a work item can be put in: its name in its process, such as Active, and the category Azure DevOps puts it in.
public struct WorkItemState: Sendable, Hashable {
    public var name: String
    public var category: WorkItem.Category

    public init(name: String, category: WorkItem.Category) {
        self.name = name
        self.category = category
    }

    /// The default processes' states, Agile's, Scrum's, CMMI's and Basic's, each in the order its work item types go through
    /// them, lowercased: two states of the same category go in this order, before any other.
    static let defaultOrder = [
        "new", "to do", "proposed", "approved", "committed", "active", "in progress", "doing", "resolved", "closed", "done",
    ]

    /// By category, in the order work goes through them, to start, in progress, resolved, then done; two of the same
    /// category as the default processes order them, then by name.
    static func ordered(_ lhs: WorkItemState, _ rhs: WorkItemState) -> Bool {
        let categories: [WorkItem.Category] = [.proposed, .inProgress, .resolved, .completed, .removed]
        let left = categories.firstIndex(of: lhs.category) ?? categories.count
        let right = categories.firstIndex(of: rhs.category) ?? categories.count
        if left != right { return left < right }
        let leftKnown = defaultOrder.firstIndex(of: lhs.name.lowercased()) ?? defaultOrder.count
        let rightKnown = defaultOrder.firstIndex(of: rhs.name.lowercased()) ?? defaultOrder.count
        if leftKnown != rightKnown { return leftKnown < rightKnown }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

extension SprintBoard {
    /// A type's states, by the category of each, as the team's backlog configuration maps them; nil when it doesn't, as
    /// when it couldn't be read. Its type's name whatever the case of its letters.
    public func categories(of type: String) -> [String: String]? {
        stateCategories[type] ?? stateCategories.first { $0.key.caseInsensitiveCompare(type) == .orderedSame }?.value
    }

    /// The states a work item of a type can be put in from its menus, in the order its process goes through them
    /// (`WorkItemState.ordered`), but Removed's, which takes it off the board: empty when the team's backlog configuration
    /// doesn't map the type's states.
    public func states(of type: String) -> [WorkItemState] {
        guard let categories = categories(of: type) else { return [] }
        return categories
            .map { name, category in WorkItemState(name: name, category: WorkItem.Category(category: category, state: name)) }
            .filter { $0.category != .removed }
            .sorted(by: WorkItemState.ordered)
    }

    /// As it is once BriefBar changed the state of one of its work items, as Azure DevOps answered: that work item in its new
    /// state, where it is, until the sprint is read again; out of it, in a removed state, as a read would leave it out
    /// (`removing`). The rest of it, as read. Unchanged when it doesn't have it.
    public func changingState(_ item: WorkItem) -> SprintBoard {
        guard self.item(item.key) != nil else { return self }
        if item.category == .removed { return removing(item.key) }
        var board = self
        board.rows = rows.map { row in
            var row = row
            if let parent = row.parent, parent.key == item.key { row.parent = parent.takingState(of: item) }
            row.tasks = row.tasks.map { $0.key == item.key ? $0.takingState(of: item) : $0 }
            return row
        }
        return board
    }
}

extension WorkItem {
    /// As Azure DevOps answered a change of its state to `state`: in the state it says, or, when it says nothing, `state`,
    /// in the category `categories`, its type's as the team's board maps them, puts that one in, guessed from its name
    /// when they don't (`Category`); and changed when it says, or at `date` when it says nothing, so that what shows of it,
    /// such as its details, follows.
    public func changing(state: String, answer: ADOWorkItem?, at date: Date, categories: [String: String]?) -> WorkItem {
        var item = self
        let name = answer?.fields.state ?? state
        item.state = name
        item.category = Category(category: categories?[name], state: name)
        item.changedAt = answer?.fields.changedDate ?? date
        return item
    }

    /// With the state of `changed`, its category and when it changed: what a change of its state changes, and nothing else.
    func takingState(of changed: WorkItem) -> WorkItem {
        var item = self
        item.state = changed.state
        item.category = changed.category
        item.changedAt = changed.changedAt
        return item
    }
}
