import Foundation

// The Azure DevOps REST API (7.1) shapes that the Sprint and Pipelines pages read, decoded as leniently
// as the pull requests: a field the API leaves out, or sends with an unexpected type, is missing, and a
// list skips an element it can't decode.

/// A JSON array that skips the elements it can't decode, like `ADOList` does inside its envelope.
public struct LenientArray<Element: Decodable & Sendable>: Decodable, Sendable {
    public var elements: [Element]

    public init(_ elements: [Element] = []) {
        self.elements = elements
    }

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(Skip.self)
            }
        }
        self.elements = elements
    }
}

// MARK: - Teams and sprints

/// One of your teams, from `{org}/_apis/teams?$mine=true`.
public struct ADOTeam: Decodable, Sendable {
    public var id: String
    public var name: String
    public var projectId: String?
    public var projectName: String?
}

/// A team's sprint, from `{org}/{project}/{team}/_apis/work/teamsettings/iterations`.
public struct ADOIteration: Decodable, Sendable {
    public var id: String
    public var name: String
    public var path: String?
    public var attributes: Attributes?

    public struct Attributes: Decodable, Sendable {
        public var startDate: Date?
        public var finishDate: Date?
        /// `past`, `current` or `future`.
        public var timeFrame: String?

        private enum CodingKeys: String, CodingKey { case startDate, finishDate, timeFrame }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            startDate = container.lenient(Date.self, forKey: .startDate)
            finishDate = container.lenient(Date.self, forKey: .finishDate)
            timeFrame = container.lenient(String.self, forKey: .timeFrame)
        }
    }
}

/// The work items in a sprint, from `.../iterations/{id}/workitems`: each one at the top level (no
/// source), and each task under its parent (`System.LinkTypes.Hierarchy-Forward`).
public struct ADOIterationWorkItems: Decodable, Sendable {
    public var workItemRelations: LenientArray<Relation>

    public struct Relation: Decodable, Sendable {
        public var rel: String?
        public var source: Reference?
        public var target: Reference
    }

    public struct Reference: Decodable, Sendable {
        public var id: Int
    }

    private enum CodingKeys: String, CodingKey { case workItemRelations }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workItemRelations = container.lenient(LenientArray<Relation>.self, forKey: .workItemRelations) ?? LenientArray()
    }
}

/// A work item with the fields the Sprint page asks for, from `_apis/wit/workitems?ids=…&fields=…`.
public struct ADOWorkItem: Decodable, Sendable {
    public var id: Int
    public var fields: Fields

    public struct Fields: Decodable, Sendable {
        public var title: String?
        public var workItemType: String?
        public var state: String?
        public var assignedTo: ADOIdentity?
        public var teamProject: String?
        public var parent: Int?
        public var remainingWork: Double?
        public var stackRank: Double?
        public var backlogPriority: Double?
        public var changedDate: Date?
        public var tags: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case title = "System.Title"
            case workItemType = "System.WorkItemType"
            case state = "System.State"
            case assignedTo = "System.AssignedTo"
            case teamProject = "System.TeamProject"
            case parent = "System.Parent"
            case remainingWork = "Microsoft.VSTS.Scheduling.RemainingWork"
            case stackRank = "Microsoft.VSTS.Common.StackRank"
            case backlogPriority = "Microsoft.VSTS.Common.BacklogPriority"
            case changedDate = "System.ChangedDate"
            case tags = "System.Tags"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = container.lenient(String.self, forKey: .title)
            workItemType = container.lenient(String.self, forKey: .workItemType)
            state = container.lenient(String.self, forKey: .state)
            assignedTo = container.lenient(ADOIdentity.self, forKey: .assignedTo)
            teamProject = container.lenient(String.self, forKey: .teamProject)
            parent = container.lenient(Int.self, forKey: .parent)
            remainingWork = container.lenient(Double.self, forKey: .remainingWork)
            stackRank = container.lenient(Double.self, forKey: .stackRank)
            backlogPriority = container.lenient(Double.self, forKey: .backlogPriority)
            changedDate = container.lenient(Date.self, forKey: .changedDate)
            tags = container.lenient(String.self, forKey: .tags)
        }
    }

    /// The fields to ask for: only these come back.
    public static let fieldNames = Fields.CodingKeys.allCases.map(\.rawValue)
}

/// How a team's backlogs are set up, from `{org}/{project}/{team}/_apis/work/backlogconfiguration`: which
/// work item types are cards on its task board, and which category each state of each type is in.
public struct ADOBacklogConfiguration: Decodable, Sendable {
    public var taskBacklog: Level?
    public var workItemTypeMappedStates: LenientArray<MappedStates>?

    public struct Level: Decodable, Sendable {
        public var workItemTypes: LenientArray<TypeReference>?
    }

    public struct TypeReference: Decodable, Sendable {
        public var name: String
    }

    /// `{"workItemTypeName": "Task", "states": {"New": "Proposed", "Active": "InProgress", ...}}`
    public struct MappedStates: Decodable, Sendable {
        public var workItemTypeName: String
        /// State name → `Proposed`, `InProgress`, `Resolved`, `Completed` or `Removed`.
        public var states: [String: String]
    }

    private enum CodingKeys: String, CodingKey { case taskBacklog, workItemTypeMappedStates }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskBacklog = container.lenient(Level.self, forKey: .taskBacklog)
        workItemTypeMappedStates = container.lenient(LenientArray<MappedStates>.self, forKey: .workItemTypeMappedStates)
    }
}

// MARK: - Pipelines

/// A pipeline, from `{project}/_apis/build/definitions?name=…`.
public struct ADOBuildDefinition: Decodable, Sendable {
    public var id: Int
    public var name: String
    /// The folder, such as `\Storefront\CI`.
    public var path: String?
    public var project: ADOProjectRef?
    /// `enabled`, `paused` or `disabled`.
    public var queueStatus: String?
}

/// A pipeline run, from `{project}/_apis/build/builds?definitions=…`.
public struct ADOBuild: Decodable, Sendable {
    public var id: Int
    public var buildNumber: String?
    /// `notStarted`, `inProgress`, `completed`, `cancelling` or `postponed`.
    public var status: String?
    /// `succeeded`, `partiallySucceeded`, `failed`, `canceled` or `none`.
    public var result: String?
    /// `manual`, `individualCI`, `batchedCI`, `schedule`, `pullRequest`, `resourceTrigger`...
    public var reason: String?
    public var sourceBranch: String?
    public var queueTime: Date?
    public var startTime: Date?
    public var finishTime: Date?
    public var definition: Definition
    public var project: ADOProjectRef?
    public var requestedFor: ADOIdentity?
    /// The commit it built.
    public var sourceVersion: String?
    /// The run whose completion started it, for a pipeline-completion or resource trigger.
    public var triggeredByBuild: BuildRef?
    public var triggerInfo: [String: String]?

    public struct Definition: Decodable, Sendable {
        public var id: Int
        public var name: String?
        public var path: String?
    }

    public struct BuildRef: Decodable, Sendable {
        public var id: Int
    }

    private enum CodingKeys: String, CodingKey {
        case id, buildNumber, status, result, reason, sourceBranch, queueTime, startTime, finishTime, definition, project, requestedFor
        case sourceVersion, triggeredByBuild, triggerInfo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        definition = try container.decode(Definition.self, forKey: .definition)
        buildNumber = container.lenient(String.self, forKey: .buildNumber)
        status = container.lenient(String.self, forKey: .status)
        result = container.lenient(String.self, forKey: .result)
        reason = container.lenient(String.self, forKey: .reason)
        sourceBranch = container.lenient(String.self, forKey: .sourceBranch)
        queueTime = container.lenient(Date.self, forKey: .queueTime)
        startTime = container.lenient(Date.self, forKey: .startTime)
        finishTime = container.lenient(Date.self, forKey: .finishTime)
        project = container.lenient(ADOProjectRef.self, forKey: .project)
        requestedFor = container.lenient(ADOIdentity.self, forKey: .requestedFor)
        sourceVersion = container.lenient(String.self, forKey: .sourceVersion)
        triggeredByBuild = container.lenient(BuildRef.self, forKey: .triggeredByBuild)
        triggerInfo = container.lenient([String: String].self, forKey: .triggerInfo)
    }
}

/// A run's stages, jobs and tasks, from `{project}/_apis/build/builds/{id}/timeline`.
public struct ADOTimeline: Decodable, Sendable {
    public var records: LenientArray<Record>

    public struct Record: Decodable, Sendable {
        public var id: String
        public var parentId: String?
        /// `Stage`, `Phase`, `Job`, `Task` or `Checkpoint`.
        public var type: String?
        public var name: String?
        public var identifier: String?
        public var order: Int?
        /// `pending`, `inProgress` or `completed`.
        public var state: String?
        /// `succeeded`, `succeededWithIssues`, `failed`, `canceled`, `skipped` or `abandoned`.
        public var result: String?
        public var startTime: Date?
        public var finishTime: Date?
        public var issues: LenientArray<Issue>?

        public struct Issue: Decodable, Sendable {
            /// `error` or `warning`.
            public var type: String?
            public var message: String?
        }

        private enum CodingKeys: String, CodingKey {
            case id, parentId, type, name, identifier, order, state, result, startTime, finishTime, issues
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            parentId = container.lenient(String.self, forKey: .parentId)
            type = container.lenient(String.self, forKey: .type)
            name = container.lenient(String.self, forKey: .name)
            identifier = container.lenient(String.self, forKey: .identifier)
            order = container.lenient(Int.self, forKey: .order)
            state = container.lenient(String.self, forKey: .state)
            result = container.lenient(String.self, forKey: .result)
            startTime = container.lenient(Date.self, forKey: .startTime)
            finishTime = container.lenient(Date.self, forKey: .finishTime)
            issues = container.lenient(LenientArray<Issue>.self, forKey: .issues)
        }
    }

    private enum CodingKeys: String, CodingKey { case records }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = container.lenient(LenientArray<Record>.self, forKey: .records) ?? LenientArray()
    }
}
