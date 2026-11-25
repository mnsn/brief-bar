import Foundation

/// One of a team's backlogs above its tasks, such as Stories or Features.
public struct BacklogLevel: Sendable, Equatable {
    /// As the team's backlogs name it, such as Stories, Backlog items or Features.
    public var name: String
    /// Its work item types, lowercased, such as user story.
    public var types: Set<String>

    public init(name: String, types: Set<String>) {
        self.name = name
        self.types = Set(types.map { $0.lowercased() })
    }
}

/// How high each work item type is on a team's backlogs, for how far up My Work's Map shows parents: tasks at 0, then each
/// backlog above them from the lowest, its stories at 1, its features at 2, and so on up to its highest, such as Epics, or
/// Objectives where the process adds Key Results and Objectives above them.
public struct BacklogLevels: Sendable, Equatable {
    /// The task board's types, lowercased.
    public var tasks: Set<String>
    /// The backlogs above tasks, from the lowest.
    public var levels: [BacklogLevel]

    public init(tasks: Set<String>, levels: [BacklogLevel]) {
        self.tasks = Set(tasks.map { $0.lowercased() })
        self.levels = levels
    }

    /// As Azure DevOps' Agile, Scrum and CMMI processes have them, with Basic's issues as stories: Task, then Stories, Features
    /// and Epics.
    public static let standard = BacklogLevels(tasks: ["Task"], levels: [
        BacklogLevel(name: "Stories", types: ["User Story", "Product Backlog Item", "Requirement", "Issue"]),
        BacklogLevel(name: "Features", types: ["Feature"]),
        BacklogLevel(name: "Epics", types: ["Epic"]),
    ])

    /// As the sprint's team's backlog configuration says; as standard when it couldn't be read.
    public init(board: SprintBoard) {
        guard !board.levels.isEmpty else {
            self = .standard
            return
        }
        self.init(tasks: board.taskTypes.isEmpty ? Self.standard.tasks : board.taskTypes, levels: board.levels)
    }

    /// The backlogs' names, from the lowest, such as Stories, Features and Epics.
    public var names: [String] { levels.map(\.name) }

    /// How high a type is: 0 for a task, 1 for one on the lowest backlog above tasks, such as a user story, and so on; nil
    /// for one on none, such as a bug on a team that keeps bugs off its backlogs, or one not read yet.
    public func level(of type: String) -> Int? {
        let type = type.trimmingCharacters(in: .whitespaces).lowercased()
        if tasks.contains(type) { return 0 }
        return levels.firstIndex { $0.types.contains(type) }.map { $0 + 1 }
    }
}

/// How high each work item is on its project's backlogs: by the sprint's team's backlogs in its project, and as standard
/// elsewhere, as `WorkItemStories` takes their types.
public struct WorkItemLevels: Sendable {
    /// The sprint's team's backlogs, or the standard ones without a sprint: those My Work's Map offers.
    public let levels: BacklogLevels
    /// The sprint's team's organization and project, lowercased.
    private let project: (organization: String, name: String)?

    public init(board: SprintBoard?) {
        levels = board.map(BacklogLevels.init(board:)) ?? .standard
        project = board.map { ($0.team.organization.lowercased(), $0.team.projectName.lowercased()) }
    }

    /// How high a work item is (`BacklogLevels.level(of:)`).
    public func level(of item: WorkItem) -> Int? {
        guard let project, item.organization.lowercased() == project.organization, item.project.lowercased() == project.name
        else { return BacklogLevels.standard.level(of: item.type) }
        return levels.level(of: item.type)
    }
}
