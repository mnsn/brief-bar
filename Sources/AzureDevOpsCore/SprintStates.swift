import Foundation

// A work item's state on the Sprint page and My Work, with Make Changes in Azure DevOps on: one of the states its type has,
// as the team's backlog configuration maps them to their categories, which the sprint engine reads already
// (`SprintBoard.stateCategories`), for the sprint's work and any other work item in the team's project. The change itself
// is `ADOWrite.setState`. What it changed shows in its new state at once, named and assigned as Azure DevOps answered
// (`SprintBoard.changingState`, `OutsideWork.changingState`), until the sprint is read again.

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

    /// Whether a work item's type has the states the team's backlog configuration maps (`states(of:)`): one on the board, and
    /// any other in the team's project, whose process gives every work item of a type the same states; not one in another
    /// project, or whose project isn't known. Its organization's and project's names whatever the case of their letters.
    public func isInTeamsProject(_ item: WorkItem) -> Bool {
        if self.item(item.key) != nil { return true }
        return item.organization.caseInsensitiveCompare(team.organization) == .orderedSame
            && item.project.caseInsensitiveCompare(team.projectName) == .orderedSame
    }

    /// As it is once BriefBar changed the state of one of its work items, as Azure DevOps answered: that work item in its new
    /// state, named and assigned as the change has it (`WorkItem.takingState(of:)`), where it is, until the sprint is read
    /// again; out of it, in a removed state, as a read would leave it out (`removing`). The rest of it, such as what's left
    /// of it and the story it's under, as read. Unchanged when it doesn't have it.
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
    /// when they don't (`Category`); changed when it says, or at `date` when it says nothing; and named and assigned as it
    /// says when it answered with the whole work item, as it does, which has its title, and leaves its owner out when no
    /// one has it, as a read takes them (`init(organization:project:_:categories:)`); so that what shows of it, such as its
    /// details and its node on My Work's Map, follows, though it was renamed or given to someone else since it was read.
    public func changing(state: String, answer: ADOWorkItem?, at date: Date, categories: [String: String]?) -> WorkItem {
        var item = self
        let name = answer?.fields.state ?? state
        item.state = name
        item.category = Category(category: categories?[name], state: name)
        item.changedAt = answer?.fields.changedDate ?? date
        if let fields = answer?.fields, let title = fields.title {
            item.title = PlainText.singleLine(title)
            item.assignedTo = fields.assignedTo.map(Person.init)
        }
        return item
    }

    /// With the state of `changed`, its category and when it changed, and its title and owner, as Azure DevOps answered the
    /// change, or BriefBar last read the work item before it (`StateChanges`), which every read of it asks for: what shows
    /// of a change of its state, so that one renamed since the sprint was read doesn't take its old name back, stamped as
    /// changed when the change was. Nothing else, such as where it is or what's left of it, which not every read has.
    func takingState(of changed: WorkItem) -> WorkItem {
        var item = self
        item.state = changed.state
        item.category = changed.category
        item.changedAt = changed.changedAt
        item.title = changed.title
        item.assignedTo = changed.assignedTo
        return item
    }
}
