import BriefBarCore
import Foundation

/// Which stories your pull requests are for, for Pull Request Order's missions by story (§7.4.2): by each of a pull
/// request's linked work items' own type, never its parent's, and never guessed. A task gives its parent, and none without
/// one; a feature or an epic, too broad for a mission, none; anything else on the backlog, such as a user story, a product
/// backlog item, a requirement, an issue or a bug, is a story itself; and one whose type BriefBar hasn't read yet, none,
/// until it has. Tasks are the types on the sprint's team's task board, in its project, and those its sprint places under a
/// story; features and epics, its portfolio backlogs' types. Elsewhere, as in every process Azure DevOps comes with: Task,
/// and Feature and Epic.
public struct WorkItemStories: Sendable {
    /// What a project's types are, lowercased.
    public struct Types: Sendable, Equatable {
        public var tasks: Set<String>
        public var portfolio: Set<String>

        public init(tasks: Set<String>, portfolio: Set<String>) {
            self.tasks = Set(tasks.map { $0.lowercased() })
            self.portfolio = Set(portfolio.map { $0.lowercased() })
        }

        /// As in every process Azure DevOps comes with.
        public static let standard = Types(tasks: ["Task"], portfolio: ["Feature", "Epic"])

        /// As a team's backlog configuration says, read by the sprint: what it couldn't read is as standard.
        public init(board: SprintBoard) {
            self.init(
                tasks: board.taskTypes.isEmpty ? Self.standard.tasks : board.taskTypes,
                portfolio: board.portfolioTypes.isEmpty ? Self.standard.portfolio : board.portfolioTypes
            )
        }
    }

    private let workItems: [WorkItemKey: WorkItem]
    /// The sprint's tasks, by the story each is under on its board.
    private let placed: [WorkItemKey: Int]
    /// The sprint's team's project, by organization and name, lowercased, and its types.
    private let project: (organization: String, name: String, types: Types)?

    /// - Parameters:
    ///   - workItems: the work items BriefBar read: the sprint's, the linked ones Show Links read, and their parents. The
    ///     first of each wins.
    ///   - board: the sprint's task board, when BriefBar has it.
    public init(workItems: [WorkItem], board: SprintBoard?) {
        var byKey: [WorkItemKey: WorkItem] = [:]
        for item in workItems where byKey[item.key] == nil {
            byKey[item.key] = item
        }
        self.workItems = byKey
        var placed: [WorkItemKey: Int] = [:]
        for row in board?.rows ?? [] {
            guard let story = row.parent else { continue }
            for task in row.tasks { placed[task.key] = story.id }
        }
        self.placed = placed
        project = board.map { ($0.team.organization.lowercased(), $0.team.projectName.lowercased(), Types(board: $0)) }
    }

    /// The types in a work item's project.
    func types(of item: WorkItem) -> Types {
        guard let project, item.organization.lowercased() == project.organization, item.project.lowercased() == project.name
        else { return .standard }
        return project.types
    }

    /// The story a work item is for, by its own type; nil for none, or while its type isn't read.
    public func story(of key: WorkItemKey) -> OrderStory? {
        let ref = ItemRef.workItem(organization: key.organization, id: key.id)
        let item = workItems[key]
        if let parent = placed[key] {
            return story(WorkItemKey(key.organization, parent), task: ref, rank: item?.rank)
        }
        guard let item else { return nil }
        let types = types(of: item)
        let type = item.type.lowercased()
        if types.tasks.contains(type) {
            return item.parentId.map { story(WorkItemKey(key.organization, $0), task: ref, rank: item.rank) }
        }
        if types.portfolio.contains(type) { return nil }
        return OrderStory(ref: ref, type: item.type)
    }

    private func story(_ key: WorkItemKey, task: ItemRef, rank: Double?) -> OrderStory {
        OrderStory(ref: .workItem(organization: key.organization, id: key.id), type: workItems[key]?.type, task: task, rank: rank)
    }

    /// The stories a pull request is for, each once, with its task that comes first in the backlog: none when none of its
    /// work items is a story or a story's task.
    /// - Parameter ids: its work items' IDs, in its organization.
    public func stories(of pullRequest: PRKey, workItems ids: [Int]) -> [OrderStory] {
        var stories: [OrderStory] = []
        for id in Set(ids).sorted() {
            guard let story = story(of: WorkItemKey(pullRequest.organization, id)) else { continue }
            if let index = stories.firstIndex(where: { $0.ref == story.ref }) {
                // The pull request linked to the story itself, and to one of its tasks: the task says where it goes.
                if stories[index].task == nil || Self.ranksFirst(story, stories[index]) { stories[index] = story }
            } else {
                stories.append(story)
            }
        }
        return stories
    }

    /// Whether one of a story's tasks comes before another in the backlog, what isn't ranked last.
    private static func ranksFirst(_ lhs: OrderStory, _ rhs: OrderStory) -> Bool {
        guard lhs.task != nil else { return false }
        switch (lhs.rank, rhs.rank) {
        case let (left?, right?): return left < right
        case (.some, nil): return true
        default: return false
        }
    }

    /// The stories of the tasks among these work items, by their keys: the parents to read what they are, for their
    /// missions' names, but for those a list, the sprint or a link has, which the engine leaves out. What it read of them
    /// stays among them, so that it doesn't forget them and read them again.
    /// - Parameter linked: the work items linked to your pull requests.
    public func parents(ofTasksIn linked: Set<WorkItemKey>) -> Set<WorkItemKey> {
        var parents: Set<WorkItemKey> = []
        for key in linked {
            guard let story = story(of: key), story.task != nil, let id = story.ref.number else { continue }
            parents.insert(WorkItemKey(story.ref.scope, id))
        }
        return parents
    }
}
