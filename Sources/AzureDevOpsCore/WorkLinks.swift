import BriefBarCore
import Foundation

/// Identifies a work item: its ID is unique within its organization, whatever case that's written in.
public struct WorkItemKey: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var organization: String
    public var id: Int

    public init(_ organization: String, _ id: Int) {
        self.organization = organization.lowercased()
        self.id = id
    }

    public var description: String { "\(organization)/\(id)" }

    public static func < (lhs: WorkItemKey, rhs: WorkItemKey) -> Bool {
        (lhs.organization, lhs.id) < (rhs.organization, rhs.id)
    }
}

/// What Azure DevOps links, as BriefBar reads it for Show Links: your pull requests' work items, the sprint's work items'
/// pull requests, and what those linked work items and pull requests are, when no list shows them; and, while Pull Request
/// Order wants stories, the parents of linked work items that nothing else has. And what My Work's Map draws: the
/// dependencies and Related links Azure DevOps links the sprint's work items with, and, while it shows parents, your work's
/// parents all the way up, that the sprint doesn't have.
public struct WorkLinks: Sendable, Equatable {
    /// Each pull request's work items, by ID, in its organization.
    public var workItemsOfPullRequests: [PRKey: [Int]]
    /// Each sprint work item's pull requests.
    public var pullRequestsOfWorkItems: [WorkItemKey: [PRKey]]
    /// Linked work items the sprint doesn't show, as read.
    public var workItems: [WorkItemKey: WorkItem]
    /// Linked pull requests your lists don't show, as read.
    public var pullRequests: [PRKey: PullRequest]
    /// The parents of linked work items, their stories, that no list, sprint or link has, as read: only while stories are
    /// wanted, to name their missions.
    public var parents: [WorkItemKey: WorkItem]
    /// While stories are wanted, the work items linked to your pull requests that the sprint doesn't show and that no read
    /// answered for yet with what stories want: the stories of their pull requests aren't known until then. One a read left
    /// out, deleted or that can't be read, isn't among them, nor one whose read failed since: it gives no story until a read
    /// gets it, rather than keep its pull request's unknown, and every story's mission unseen, for as long as it fails.
    public var pendingWorkItems: Set<WorkItemKey>
    /// While stories are wanted, your pull requests whose work items' read failed and that no read answered for: their
    /// stories count as read, with none known, until a read gets them.
    public var unreadablePullRequests: Set<PRKey>
    /// While stories are wanted, the linked work items in `workItems` read without what stories want, their parent and place
    /// in the backlog: as read before stories were wanted, while no read with it answered since, as when it failed. What's
    /// read of them doesn't say whether a task has a parent, so a task among them is for no story, rather than a story of its
    /// own (`WorkItemStories`), until a read gets it.
    public var partlyRead: Set<WorkItemKey>
    /// The dependencies Azure DevOps links the sprint's work items with, in their organization, each a work item's on its
    /// predecessor: from their links, which the read of their pull requests brings, and those BriefBar linked or took away
    /// since, until the sprint is read again.
    public var dependencies: Set<WorkDependency>
    /// The Related links Azure DevOps has between the sprint's work items and others of their organization: from their
    /// links, which the read of their pull requests brings, as the dependencies do.
    public var related: Set<RelatedWork>
    /// While My Work's Map shows parents, the work items it asked for that the sprint doesn't have, nor `workItems` with what
    /// stories want, as read with their own parent: your linked work items, and their parents all the way up
    /// (`LinkEngine.Inputs.mapParents`).
    public var mapParents: [WorkItemKey: WorkItem]

    public init(
        workItemsOfPullRequests: [PRKey: [Int]] = [:], pullRequestsOfWorkItems: [WorkItemKey: [PRKey]] = [:],
        workItems: [WorkItemKey: WorkItem] = [:], pullRequests: [PRKey: PullRequest] = [:], parents: [WorkItemKey: WorkItem] = [:],
        pendingWorkItems: Set<WorkItemKey> = [], unreadablePullRequests: Set<PRKey> = [], partlyRead: Set<WorkItemKey> = [],
        dependencies: Set<WorkDependency> = [], related: Set<RelatedWork> = [], mapParents: [WorkItemKey: WorkItem] = [:]
    ) {
        self.workItemsOfPullRequests = workItemsOfPullRequests
        self.pullRequestsOfWorkItems = pullRequestsOfWorkItems
        self.workItems = workItems
        self.pullRequests = pullRequests
        self.parents = parents
        self.pendingWorkItems = pendingWorkItems
        self.unreadablePullRequests = unreadablePullRequests
        self.partlyRead = partlyRead
        self.dependencies = dependencies
        self.related = related
        self.mapParents = mapParents
    }

    /// Every link it read, between pull requests and work items.
    public var links: [ItemLink] {
        var links: [ItemLink] = []
        for (pullRequest, ids) in workItemsOfPullRequests {
            for id in ids {
                if let link = ItemLink(
                    .pullRequest(organization: pullRequest.organization, number: pullRequest.number),
                    .workItem(organization: pullRequest.organization, id: id), origin: .azureDevOps
                ) { links.append(link) }
            }
        }
        for (workItem, pullRequests) in pullRequestsOfWorkItems {
            for pullRequest in pullRequests {
                if let link = ItemLink(
                    .workItem(organization: workItem.organization, id: workItem.id),
                    .pullRequest(organization: pullRequest.organization, number: pullRequest.number), origin: .azureDevOps
                ) { links.append(link) }
            }
        }
        return links
    }

    /// What a linked work item shows: what it is, where it stands, who has it, and its project, for its page.
    public static let workItemFields = [
        "System.Title", "System.WorkItemType", "System.State", "System.AssignedTo", "System.TeamProject", "System.ChangedDate",
    ]

    /// With stories wanted, a linked work item's parent and its place in the backlog too, as the sprint reads them.
    public static let storyFields = ["System.Parent", "Microsoft.VSTS.Common.StackRank", "Microsoft.VSTS.Common.BacklogPriority"]
}

// MARK: - Responses

/// A pull request's work items, from `.../pullRequests/{id}/workitems`: references only, `{"id": "5101", "url": ...}`.
public struct ADOWorkItemRefs: Decodable, Sendable {
    public var ids: [Int]

    private enum CodingKeys: String, CodingKey { case value }

    private struct Reference: Decodable, Sendable {
        var id: Int?

        private enum CodingKeys: String, CodingKey { case id }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A string, as Azure DevOps sends it, or a number.
            id = container.lenient(String.self, forKey: .id).flatMap { Int($0) } ?? container.lenient(Int.self, forKey: .id)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let references = container.lenient(LenientArray<Reference>.self, forKey: .value)?.elements ?? []
        ids = references.compactMap(\.id).filter { $0 > 0 }
    }
}

/// A work item with its relations, from `_apis/wit/workitems?ids=…&$expand=relations`: its links to other work items, and
/// to pull requests, commits and branches (`ArtifactLink`).
public struct ADOWorkItemRelations: Decodable, Sendable {
    public var id: Int
    public var relations: [Relation]

    public struct Relation: Decodable, Sendable {
        public var rel: String?
        public var url: String?
    }

    private enum CodingKeys: String, CodingKey { case id, relations }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        relations = container.lenient(LenientArray<Relation>.self, forKey: .relations)?.elements ?? []
    }

    /// The pull requests it links to, in its organization.
    public func pullRequests(in organization: String) -> [PRKey] {
        let numbers = relations.compactMap { relation -> Int? in
            guard relation.rel == "ArtifactLink", let url = relation.url else { return nil }
            return ArtifactLink.pullRequest(url)?.id
        }
        return Set(numbers).sorted().map { PRKey(organization.lowercased(), $0) }
    }

    /// The dependencies it's in with work items of its organization: its own on its predecessors, and its successors' on it.
    public func dependencies(in organization: String) -> Set<WorkDependency> {
        let itself = WorkItemKey(organization, id)
        var found: Set<WorkDependency> = []
        for relation in relations {
            guard let url = relation.url, let target = ADOWorkItemDetails.Relation.workItem(at: url),
                  target.organization.caseInsensitiveCompare(organization) == .orderedSame, target.id != id
            else { continue }
            let other = WorkItemKey(organization, target.id)
            switch relation.rel {
            case WorkDependency.predecessor: found.insert(WorkDependency(other, itself))
            case WorkDependency.successor: found.insert(WorkDependency(itself, other))
            default: break
            }
        }
        return found
    }

    /// The Related links it has with work items of its organization.
    public func related(in organization: String) -> Set<RelatedWork> {
        let itself = WorkItemKey(organization, id)
        var found: Set<RelatedWork> = []
        for relation in relations where relation.rel == RelatedWork.link {
            guard let url = relation.url, let target = ADOWorkItemDetails.Relation.workItem(at: url),
                  target.organization.caseInsensitiveCompare(organization) == .orderedSame, target.id != id
            else { continue }
            found.insert(RelatedWork(itself, WorkItemKey(organization, target.id)))
        }
        return found
    }
}

/// A dependency Azure DevOps links between two work items of an organization: `after` waits for `before`, its predecessor,
/// as `before` has `after` for its successor.
public struct WorkDependency: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var before: WorkItemKey
    public var after: WorkItemKey

    public init(_ before: WorkItemKey, _ after: WorkItemKey) {
        self.before = before
        self.after = after
    }

    /// The link a work item has to its predecessor, as Azure DevOps names it.
    public static let predecessor = "System.LinkTypes.Dependency-Reverse"
    /// The link a work item has to its successor.
    public static let successor = "System.LinkTypes.Dependency-Forward"

    /// A work item's address, as a link to it names it: `https://dev.azure.com/{organization}/_apis/wit/workItems/{id}`.
    public static func address(of key: WorkItemKey) -> URL {
        ADOEndpoint.url("https://dev.azure.com", [key.organization, "_apis", "wit", "workItems", String(key.id)], [])
    }

    public var description: String { "\(before) > \(after)" }

    public static func < (lhs: WorkDependency, rhs: WorkDependency) -> Bool {
        (lhs.after, lhs.before) < (rhs.after, rhs.before)
    }
}

/// A Related link Azure DevOps has between two work items of an organization. It has no direction: either end names the
/// other the same way, so `first` is always the lower.
public struct RelatedWork: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let first: WorkItemKey
    public let second: WorkItemKey

    public init(_ one: WorkItemKey, _ other: WorkItemKey) {
        first = min(one, other)
        second = max(one, other)
    }

    /// The link, as Azure DevOps names it from either end.
    public static let link = "System.LinkTypes.Related"

    public var description: String { "\(first) ~ \(second)" }

    public static func < (lhs: RelatedWork, rhs: RelatedWork) -> Bool {
        (lhs.first, lhs.second) < (rhs.first, rhs.second)
    }
}

/// A work item's links as they are now, with its revision, from `_apis/wit/workitems/{id}?$expand=relations`: what linking a
/// dependency, or taking one away, reads right before (`ADOWrite.addDependency`, `removeDependency`).
public struct ADOWorkItemLinks: Decodable, Sendable {
    public var id: Int
    public var revision: Int
    /// Its links, in Azure DevOps' order, which a link's index counts in.
    public var relations: [ADOWorkItemRelations.Relation]

    private enum CodingKeys: String, CodingKey { case id, rev, relations }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        revision = try container.decode(Int.self, forKey: .rev)
        // Every link, readable or not, as each one's index counts.
        relations = try container.decodeIfPresent([ADOWorkItemRelations.Relation].self, forKey: .relations) ?? []
    }

    /// The index of its link to its predecessor `earlier`, among all its links; nil while it has none.
    public func predecessorIndex(_ earlier: Int, in organization: String) -> Int? {
        relations.firstIndex { relation in
            guard relation.rel == WorkDependency.predecessor, let url = relation.url,
                  let target = ADOWorkItemDetails.Relation.workItem(at: url)
            else { return false }
            return target.id == earlier && target.organization.caseInsensitiveCompare(organization) == .orderedSame
        }
    }
}

/// Azure DevOps' names for what a work item links to outside work items.
public enum ArtifactLink {
    /// The pull request a link names: `vstfs:///Git/PullRequestId/{project}%2F{repository}%2F{id}`.
    public static func pullRequest(_ url: String) -> (projectId: String, repositoryId: String, id: Int)? {
        let prefix = "vstfs:///git/pullrequestid/"
        guard url.lowercased().hasPrefix(prefix), let rest = String(url.dropFirst(prefix.count)).removingPercentEncoding else {
            return nil
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, let id = Int(parts[2]), id > 0 else { return nil }
        return (String(parts[0]), String(parts[1]), id)
    }
}

extension ADOEndpoint {
    /// A pull request's work items, as references.
    public static func pullRequestWorkItems(organization: String, projectId: String, repositoryId: String, pullRequestId: Int) -> URL {
        url("https://dev.azure.com",
            [organization, projectId, "_apis", "git", "repositories", repositoryId, "pullRequests", String(pullRequestId), "workitems"],
            [("api-version", apiVersion)])
    }

    /// Up to 200 work items with their relations. Azure DevOps doesn't take the fields to return with relations, so all of
    /// them come too. Ones that were deleted or can't be read are left out.
    public static func workItemRelations(organization: String, ids: [Int]) -> URL {
        url("https://dev.azure.com", [organization, "_apis", "wit", "workitems"], [
            ("ids", ids.map(String.init).joined(separator: ",")), ("$expand", "relations"), ("errorPolicy", "omit"),
            ("api-version", apiVersion),
        ])
    }
}

// MARK: - Reading

/// Reads what Show Links needs from Azure DevOps, with the pull requests' client, after each of their refreshes: each of
/// your pull requests' work items (one GET each, then every quarter of an hour), the sprint's work items' pull requests
/// while the sprint shows (one GET for up to 200, then every quarter of an hour), with the dependencies and Related links
/// Azure DevOps links them with, which come with them, and what the linked work items and pull requests that no list shows
/// are, who has each work item too (a GET for up to 200 work items; one for each pull request, ten a refresh). While Pull
/// Request Order wants stories, the linked work items' parent and place in the backlog come with what they are, three more
/// fields, and the parents nothing else has are read as they are, with what they are only (a GET for up to 200). While My
/// Work's Map shows parents, the work items it asks for are read with what they are and their parent (a GET for up to 200,
/// then every quarter of an hour). Every request is a GET. What can't be read is tried again an hour later.
public actor LinkEngine {
    public typealias ChangeHandler = @Sendable (WorkLinks) -> Void

    /// Where a pull request is, to read its work items.
    public struct Place: Sendable, Equatable {
        public var projectId: String
        public var repositoryId: String

        public init(projectId: String, repositoryId: String) {
            self.projectId = projectId
            self.repositoryId = repositoryId
        }
    }

    /// What there is to read links for.
    public struct Inputs: Sendable, Equatable {
        /// Your pull requests and the ones you review, whose work items it reads.
        public var pullRequests: [PRKey: Place]
        /// The sprint's work items, whose pull requests it reads while `sprintShows`.
        public var sprintItems: Set<WorkItemKey>
        public var sprintShows: Bool
        /// Linked things that no list shows, to read what they are.
        public var workItemLookups: Set<WorkItemKey>
        public var pullRequestLookups: Set<PRKey>
        /// Whether Pull Request Order wants the stories your pull requests are for: the linked work items' parent and place
        /// in the backlog, and `parentLookups`.
        public var wantsStories: Bool
        /// The parents of linked work items to read what they are, while stories are wanted: those no list, sprint or link
        /// has.
        public var parentLookups: Set<WorkItemKey>
        /// The work items My Work's Map wants with their parent, while it shows parents: your linked work items, then their
        /// parents, a level more each time a read names them (`WorkLinks.mapParents`). The sprint's aren't read, nor linked
        /// work items read with what stories want.
        public var mapParents: Set<WorkItemKey>

        public init(
            pullRequests: [PRKey: Place] = [:], sprintItems: Set<WorkItemKey> = [], sprintShows: Bool = false,
            workItemLookups: Set<WorkItemKey> = [], pullRequestLookups: Set<PRKey> = [], wantsStories: Bool = false,
            parentLookups: Set<WorkItemKey> = [], mapParents: Set<WorkItemKey> = []
        ) {
            self.pullRequests = Dictionary(pullRequests.map { (PRKey($0.key.organization.lowercased(), $0.key.number), $0.value) },
                                           uniquingKeysWith: { first, _ in first })
            self.sprintItems = sprintItems
            self.sprintShows = sprintShows
            self.workItemLookups = workItemLookups
            self.pullRequestLookups = Set(pullRequestLookups.map { PRKey($0.organization.lowercased(), $0.number) })
            self.wantsStories = wantsStories
            self.parentLookups = wantsStories ? parentLookups : []
            self.mapParents = mapParents
        }
    }

    /// How long what's read is kept before it's read again.
    static let relinkAfter: TimeInterval = 15 * 60
    /// A closed pull request changes little.
    static let closedRereadAfter: TimeInterval = 6 * 3_600
    static let retryAfter: TimeInterval = 3_600
    static let firstReadsPerRefresh = 20
    static let rereadsPerRefresh = 4
    static let lookupsPerRefresh = 10
    static let batchSize = 200

    private let client: ADOClient
    private let now: @Sendable () -> Date
    private let onChange: ChangeHandler
    private var inputs = Inputs()
    private var links = WorkLinks()
    private var pullRequestsRead: [PRKey: Date] = [:]
    private var sprintRead: (items: Set<WorkItemKey>, at: Date)?
    private var workItemsRead: [WorkItemKey: Date] = [:]
    /// The linked work items whose last read had what stories want, their parent and place in the backlog: what's kept of
    /// the rest doesn't say whether a task has a parent (`WorkLinks.partlyRead`).
    private var readWithStories: Set<WorkItemKey> = []
    private var parentsRead: [WorkItemKey: Date] = [:]
    private var mapParentsRead: [WorkItemKey: Date] = [:]
    private var lookupsRead: [PRKey: Date] = [:]
    /// When each read failed, by what it read, to try again later rather than every refresh.
    private var failures: [String: Date] = [:]
    /// When a Copilot session said it changed what each read reads (`reread`), by what it reads: it's due until read after
    /// then, even when a read under way, which started before, finishes after.
    private var asked: [String: Date] = [:]
    private var isRefreshing = false
    private var again = false
    private var isStopped = false
    private var lastPublished: WorkLinks?
    /// The dependencies the sprint's last read found.
    private var readDependencies: Set<WorkDependency> = []
    /// The Related links the sprint's last read found.
    private var readRelated: Set<RelatedWork> = []
    /// The dependencies BriefBar linked or took away since, with when (`changed`): each shows so until a read of the sprint
    /// that started after it.
    private var dependencyChanges: [WorkDependency: (linked: Bool, at: Date)] = [:]

    public init(client: ADOClient, now: @escaping @Sendable () -> Date = { Date() }, onChange: @escaping ChangeHandler) {
        self.client = client
        self.now = now
        self.onChange = onChange
    }

    /// What to read links for. What's no longer there is forgotten at once; what's new is read now. Once stories are
    /// wanted, the linked work items are read again, with their parent and place in the backlog; once they aren't, those
    /// and the parents read go at once.
    public func update(_ inputs: Inputs) async {
        guard inputs != self.inputs else { return }
        let storiesChanged = inputs.wantsStories != self.inputs.wantsStories
        self.inputs = inputs
        if storiesChanged {
            if inputs.wantsStories {
                workItemsRead = [:]
            } else {
                links.workItems = links.workItems.mapValues { item in
                    var item = item
                    item.parentId = nil
                    item.rank = nil
                    return item
                }
                readWithStories = []
            }
        }
        prune()
        publish()
        await refresh()
    }

    /// Stops for good, when Show Links or Azure DevOps is turned off: a refresh under way stops before its next request.
    public func stop() {
        isStopped = true
    }

    /// Reads what's due: after each refresh of the pull requests, and when there's something new to read.
    public func refresh() async {
        guard !isStopped else { return }
        if isRefreshing {
            again = true
            return
        }
        isRefreshing = true
        repeat {
            again = false
            await readDue()
            publish()
        } while again
        isRefreshing = false
    }

    public func currentLinks() -> WorkLinks {
        links
    }

    /// A dependency BriefBar just linked in Azure DevOps, or took away: it shows so at once, and the sprint is read again,
    /// which says so too once Azure DevOps does.
    public func changed(_ dependency: WorkDependency, linked: Bool) async {
        let date = now()
        dependencyChanges[dependency] = (linked, date)
        asked["sprint"] = date
        publish()
        await refresh()
    }

    /// Reads the sprint again now, as after a change to a dependency that Azure DevOps may have made though it didn't say:
    /// what it reads shows how it stands.
    public func rereadSprint() async {
        asked["sprint"] = now()
        await refresh()
    }

    /// The most pull requests, and work items, a re-read reads again at once.
    static let mostRereads = 10

    /// Reads again now, rather than when they're due, what a Copilot session said it changed: the work items of these of
    /// your pull requests, and what these linked pull requests no list shows are, the first `mostRereads` of each; the
    /// sprint's pull requests, when it names one of the sprint's work items; and what these linked work items, and these
    /// that My Work's Map asked for with their parent, are. Only
    /// what it reads anyway, ahead of the rest; one that failed still waits its hour. A read under way that started before
    /// now doesn't count, though it's the first: it's read again after it. A request is forgotten after a quarter of an
    /// hour, when it's read again anyway.
    public func reread(pullRequests: Set<PRKey>, workItems: Set<WorkItemKey>) async {
        let date = now()
        forgetOldRequests(at: date)
        let named = Set(pullRequests.map { PRKey($0.organization.lowercased(), $0.number) })
        for key in inputs.pullRequests.keys.filter(named.contains).sorted().prefix(Self.mostRereads) {
            asked["pr \(key)"] = date
        }
        for key in wantedPullRequests().filter(named.contains).sorted().prefix(Self.mostRereads) {
            asked["lookup \(key)"] = date
        }
        if !inputs.sprintItems.isDisjoint(with: workItems) { asked["sprint"] = date }
        for key in wantedWorkItems().filter(workItems.contains).sorted().prefix(Self.mostRereads) {
            asked["wi \(key)"] = date
        }
        for key in wantedParents().filter(workItems.contains).sorted().prefix(Self.mostRereads) {
            asked["parent \(key)"] = date
        }
        for key in wantedMapParents().filter(workItems.contains).sorted().prefix(Self.mostRereads) {
            asked["mapParent \(key)"] = date
        }
        await refresh()
    }

    /// Whether a session asked to read it again after it was last read.
    private func isAsked(_ what: String, read: Date?) -> Bool {
        guard let asked = asked[what] else { return false }
        return read.map { $0 < asked } ?? true
    }

    /// It was read, in a read that started at `date`: what a session asked before then is done.
    private func settle(_ what: String, readAt date: Date) {
        if let asked = asked[what], asked <= date { self.asked[what] = nil }
    }

    private func forgetOldRequests(at date: Date) {
        asked = asked.filter { date.timeIntervalSince($0.value) < Self.relinkAfter }
    }

    private func readDue() async {
        let date = now()
        forgetOldRequests(at: date)
        do {
            try await readWorkItemsOfPullRequests(at: date)
            try await readPullRequestsOfSprint(at: date)
            try await readLinkedWorkItems(at: date)
            try await readParents(at: date)
            try await readMapParents(at: date)
            try await readLinkedPullRequests(at: date)
        } catch {
            // Azure DevOps asked to slow down, or it stopped: the rest waits.
        }
    }

    /// Every request goes through here, to stop before the next one once stopped.
    private func get<T: Decodable & Sendable>(_ url: URL, as type: T.Type) async throws -> T {
        guard !isStopped else { throw CancellationError() }
        return try await client.get(url, as: type)
    }

    private func isDue(
        _ read: Date?, failed: Date?, at date: Date, after interval: TimeInterval = relinkAfter, asked: Bool = false
    ) -> Bool {
        if let failed, date.timeIntervalSince(failed) < Self.retryAfter { return false }
        guard let read, !asked else { return true }
        return date.timeIntervalSince(read) >= interval
    }

    /// The pull requests' work items: the ones never read first, many at a time, then a few of those read longest ago.
    private func readWorkItemsOfPullRequests(at date: Date) async throws {
        let isAsked = { (key: PRKey) in self.isAsked("pr \(key)", read: self.pullRequestsRead[key]) }
        let due = inputs.pullRequests.keys.filter {
            isDue(pullRequestsRead[$0], failed: failures["pr \($0)"], at: date, asked: isAsked($0))
        }
        // Those never read, and those a session asked for, first.
        let first = due.filter { pullRequestsRead[$0] == nil || isAsked($0) }.sorted().prefix(Self.firstReadsPerRefresh)
        let again = due.filter { pullRequestsRead[$0] != nil && !isAsked($0) }
            .sorted { (pullRequestsRead[$0] ?? .distantPast, $0) < (pullRequestsRead[$1] ?? .distantPast, $1) }
            .prefix(Self.rereadsPerRefresh)
        for key in Array(first) + Array(again) {
            guard let place = inputs.pullRequests[key] else { continue }
            do {
                let refs = try await get(ADOEndpoint.pullRequestWorkItems(
                    organization: key.organization, projectId: place.projectId, repositoryId: place.repositoryId, pullRequestId: key.number
                ), as: ADOWorkItemRefs.self)
                guard inputs.pullRequests[key] != nil else { continue }
                links.workItemsOfPullRequests[key] = Set(refs.ids).sorted()
                pullRequestsRead[key] = date
                failures["pr \(key)"] = nil
                settle("pr \(key)", readAt: date)
            } catch {
                try Self.rethrowThrottling(error)
                failures["pr \(key)"] = date
            }
        }
    }

    /// The sprint's work items' pull requests, while it shows: when its work items change, and every quarter of an hour.
    private func readPullRequestsOfSprint(at date: Date) async throws {
        guard inputs.sprintShows, !inputs.sprintItems.isEmpty else { return }
        if let sprintRead, sprintRead.items == inputs.sprintItems, date.timeIntervalSince(sprintRead.at) < Self.relinkAfter,
           !isAsked("sprint", read: sprintRead.at) { return }
        if let failed = failures["sprint"], date.timeIntervalSince(failed) < Self.relinkAfter { return }
        let items = inputs.sprintItems
        var found: [WorkItemKey: [PRKey]] = [:]
        var dependencies: Set<WorkDependency> = []
        var related: Set<RelatedWork> = []
        for (organization, keys) in Dictionary(grouping: items, by: \.organization) {
            let ids = keys.map(\.id).sorted()
            for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
                let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
                do {
                    let list = try await get(
                        ADOEndpoint.workItemRelations(organization: organization, ids: batch), as: ADOList<ADOWorkItemRelations>.self
                    )
                    for item in list.value {
                        found[WorkItemKey(organization, item.id)] = item.pullRequests(in: organization)
                        dependencies.formUnion(item.dependencies(in: organization))
                        related.formUnion(item.related(in: organization))
                    }
                } catch {
                    try Self.rethrowThrottling(error)
                    failures["sprint"] = date
                    return
                }
            }
        }
        // Of what the sprint has now: what it no longer has went while it read, as `prune()` takes it away.
        let sprint = inputs.sprintItems
        links.pullRequestsOfWorkItems = found.filter { sprint.contains($0.key) && !$0.value.isEmpty }
        readDependencies = dependencies.filter { sprint.contains($0.before) || sprint.contains($0.after) }
        readRelated = related.filter { sprint.contains($0.first) || sprint.contains($0.second) }
        // What BriefBar changed before this read started, Azure DevOps says now, where it read either end; of work items
        // the sprint doesn't have, no read says, so it stays.
        dependencyChanges = dependencyChanges.filter { dependency, change in
            change.at > date || !items.contains(dependency.before) && !items.contains(dependency.after)
        }
        sprintRead = (items, date)
        failures["sprint"] = nil
        settle("sprint", readAt: date)
    }

    /// The linked work items to read what they are: those linked to your pull requests, when the sprint doesn't show them,
    /// and those you linked; whether they were read or not yet, as for the first time now.
    private func wantedWorkItems() -> Set<WorkItemKey> {
        var wanted = inputs.workItemLookups
        for (pullRequest, ids) in links.workItemsOfPullRequests {
            for id in ids { wanted.insert(WorkItemKey(pullRequest.organization, id)) }
        }
        return wanted.subtracting(inputs.sprintItems)
    }

    /// The linked pull requests to read what they are: those linked to the sprint's work items, when your lists don't show
    /// them, and those you linked; whether they were read or not yet, as for the first time now.
    private func wantedPullRequests() -> Set<PRKey> {
        var wanted = inputs.pullRequestLookups
        for pullRequests in links.pullRequestsOfWorkItems.values { wanted.formUnion(pullRequests) }
        return wanted.subtracting(inputs.pullRequests.keys)
    }

    /// What the work items linked to your pull requests are, when the sprint doesn't show them, and those you linked: with
    /// their parent and place in the backlog while stories are wanted, as each request goes.
    private func readLinkedWorkItems(at date: Date) async throws {
        let wanted = wantedWorkItems()
        links.workItems = links.workItems.filter { wanted.contains($0.key) }
        workItemsRead = workItemsRead.filter { wanted.contains($0.key) }
        readWithStories.formIntersection(wanted)
        let due = wanted.filter {
            isDue(workItemsRead[$0], failed: failures["wi \($0)"], at: date, asked: isAsked("wi \($0)", read: workItemsRead[$0]))
        }
        for (organization, keys) in Dictionary(grouping: due, by: \.organization) {
            let ids = keys.map(\.id).sorted()
            for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
                let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
                // Stories may have been turned on or off during the last request.
                let readsStories = inputs.wantsStories
                let fields = readsStories ? WorkLinks.workItemFields + WorkLinks.storyFields : WorkLinks.workItemFields
                do {
                    let list = try await get(
                        ADOEndpoint.workItems(organization: organization, ids: batch, fields: fields),
                        as: ADOList<ADOWorkItem>.self
                    )
                    // Those left out were deleted, or can't be read: there's nothing more to show of them, nor stories.
                    for id in batch {
                        links.workItems[WorkItemKey(organization, id)] = nil
                        readWithStories.remove(WorkItemKey(organization, id))
                    }
                    // Stories may have been turned on or off while it read: what they don't want isn't kept, and what was
                    // read without what they want is read again.
                    let wantsStories = inputs.wantsStories
                    for dto in list.value {
                        let key = WorkItemKey(organization, dto.id)
                        guard wanted.contains(key) else { continue }
                        var item = WorkItem(organization: organization, project: dto.fields.teamProject ?? "", dto)
                        if !wantsStories {
                            item.parentId = nil
                            item.rank = nil
                        }
                        links.workItems[key] = item
                        if readsStories && wantsStories { readWithStories.insert(key) }
                    }
                    guard readsStories || !wantsStories else { continue }
                    for id in batch {
                        workItemsRead[WorkItemKey(organization, id)] = date
                        failures["wi \(WorkItemKey(organization, id))"] = nil
                        settle("wi \(WorkItemKey(organization, id))", readAt: date)
                    }
                } catch {
                    try Self.rethrowThrottling(error)
                    for id in batch { failures["wi \(WorkItemKey(organization, id))"] = date }
                }
            }
        }
    }

    /// The parents of linked work items that no list, sprint or link has, to read what they are, while stories are wanted.
    private func wantedParents() -> Set<WorkItemKey> {
        guard inputs.wantsStories else { return [] }
        return inputs.parentLookups.subtracting(inputs.sprintItems).subtracting(wantedWorkItems())
    }

    /// What those parents are, while stories are wanted, as linked work items are read: with what they are only, a GET for
    /// up to 200, read again every quarter of an hour.
    private func readParents(at date: Date) async throws {
        let wanted = wantedParents()
        links.parents = links.parents.filter { wanted.contains($0.key) }
        parentsRead = parentsRead.filter { wanted.contains($0.key) }
        let due = wanted.filter {
            isDue(parentsRead[$0], failed: failures["parent \($0)"], at: date, asked: isAsked("parent \($0)", read: parentsRead[$0]))
        }
        for (organization, keys) in Dictionary(grouping: due, by: \.organization) {
            let ids = keys.map(\.id).sorted()
            for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
                // Only those still wanted: stories may have been turned off, or their tasks gone, during the last request.
                let wantedNow = wantedParents()
                let batch = ids[start..<min(start + Self.batchSize, ids.count)].filter { wantedNow.contains(WorkItemKey(organization, $0)) }
                guard !batch.isEmpty else { continue }
                do {
                    let list = try await get(
                        ADOEndpoint.workItems(organization: organization, ids: batch, fields: WorkLinks.workItemFields),
                        as: ADOList<ADOWorkItem>.self
                    )
                    let stillWanted = wantedParents()
                    // Those left out were deleted, or can't be read: their missions are named by their numbers.
                    for id in batch {
                        links.parents[WorkItemKey(organization, id)] = nil
                    }
                    for dto in list.value {
                        let key = WorkItemKey(organization, dto.id)
                        guard stillWanted.contains(key) else { continue }
                        links.parents[key] = WorkItem(organization: organization, project: dto.fields.teamProject ?? "", dto)
                    }
                    for id in batch where stillWanted.contains(WorkItemKey(organization, id)) {
                        parentsRead[WorkItemKey(organization, id)] = date
                        settle("parent \(WorkItemKey(organization, id))", readAt: date)
                    }
                } catch {
                    try Self.rethrowThrottling(error)
                    for id in batch { failures["parent \(WorkItemKey(organization, id))"] = date }
                }
            }
        }
    }

    /// The work items My Work's Map wants with their parent, while it shows parents: those the sprint doesn't have, nor the
    /// linked work items read with what stories want, which have their parent already and are read again with it.
    private func wantedMapParents() -> Set<WorkItemKey> {
        inputs.mapParents.subtracting(inputs.sprintItems).subtracting(readWithStories)
    }

    /// What those work items are, with their parent, for the Map to climb a level more: a GET for up to 200, read again
    /// every quarter of an hour. One a read leaves out, deleted or that can't be read, is forgotten.
    private func readMapParents(at date: Date) async throws {
        let wanted = wantedMapParents()
        links.mapParents = links.mapParents.filter { wanted.contains($0.key) }
        mapParentsRead = mapParentsRead.filter { wanted.contains($0.key) }
        let due = wanted.filter { key in
            let read = mapParentsRead[key]
            return isDue(read, failed: failures["mapParent \(key)"], at: date, asked: isAsked("mapParent \(key)", read: read))
        }
        let fields = WorkLinks.workItemFields + ["System.Parent"]
        for (organization, keys) in Dictionary(grouping: due, by: \.organization) {
            let ids = keys.map(\.id).sorted()
            for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
                // Only those still wanted: the Map may have gone, or what it climbs from changed, during the last request.
                let wantedNow = wantedMapParents()
                let batch = ids[start..<min(start + Self.batchSize, ids.count)].filter { wantedNow.contains(WorkItemKey(organization, $0)) }
                guard !batch.isEmpty else { continue }
                do {
                    let list = try await get(
                        ADOEndpoint.workItems(organization: organization, ids: batch, fields: fields), as: ADOList<ADOWorkItem>.self
                    )
                    let stillWanted = wantedMapParents()
                    for id in batch {
                        links.mapParents[WorkItemKey(organization, id)] = nil
                    }
                    for dto in list.value {
                        let key = WorkItemKey(organization, dto.id)
                        guard stillWanted.contains(key) else { continue }
                        links.mapParents[key] = WorkItem(organization: organization, project: dto.fields.teamProject ?? "", dto)
                    }
                    for id in batch where stillWanted.contains(WorkItemKey(organization, id)) {
                        let key = WorkItemKey(organization, id)
                        mapParentsRead[key] = date
                        failures["mapParent \(key)"] = nil
                        settle("mapParent \(key)", readAt: date)
                    }
                } catch {
                    try Self.rethrowThrottling(error)
                    for id in batch { failures["mapParent \(WorkItemKey(organization, id))"] = date }
                }
            }
        }
    }

    /// What the pull requests linked to the sprint's work items are, when your lists don't show them, and those you
    /// linked: ten a refresh, the ones never read first. An open one is read again every quarter of an hour, a closed one
    /// every six hours.
    private func readLinkedPullRequests(at date: Date) async throws {
        let wanted = wantedPullRequests()
        links.pullRequests = links.pullRequests.filter { wanted.contains($0.key) }
        lookupsRead = lookupsRead.filter { wanted.contains($0.key) }
        let isAsked = { (key: PRKey) in self.isAsked("lookup \(key)", read: self.lookupsRead[key]) }
        let due = wanted.filter { key in
            let interval = links.pullRequests[key].map { $0.status == .active ? Self.relinkAfter : Self.closedRereadAfter } ?? 0
            return isDue(lookupsRead[key], failed: failures["lookup \(key)"], at: date, after: interval, asked: isAsked(key))
        }
        // Those a session asked for first, then those read longest ago.
        .sorted {
            (isAsked($0) ? 0 : 1, lookupsRead[$0] ?? .distantPast, $0) < (isAsked($1) ? 0 : 1, lookupsRead[$1] ?? .distantPast, $1)
        }
        for key in due.prefix(Self.lookupsPerRefresh) {
            do {
                let dto = try await get(ADOEndpoint.pullRequest(organization: key.organization, id: key.number), as: ADOPullRequest.self)
                if wanted.contains(key) { links.pullRequests[key] = PullRequest(organization: key.organization, dto) }
                lookupsRead[key] = date
                failures["lookup \(key)"] = nil
                settle("lookup \(key)", readAt: date)
            } catch {
                try Self.rethrowThrottling(error)
                failures["lookup \(key)"] = date
            }
        }
    }

    /// Azure DevOps asking to slow down, and stopping, end the refresh; anything else is about one read.
    private static func rethrowThrottling(_ error: Error) throws {
        if error is CancellationError { throw error }
        if case .throttled = error as? ADOError { throw error }
    }

    /// Forgets what's no longer listed, or in the sprint, and the parents no longer wanted.
    private func prune() {
        let listed = Set(inputs.pullRequests.keys)
        links.workItemsOfPullRequests = links.workItemsOfPullRequests.filter { listed.contains($0.key) }
        pullRequestsRead = pullRequestsRead.filter { listed.contains($0.key) }
        links.pullRequestsOfWorkItems = links.pullRequestsOfWorkItems.filter { inputs.sprintItems.contains($0.key) }
        let sprint = inputs.sprintItems
        readDependencies = readDependencies.filter { sprint.contains($0.before) || sprint.contains($0.after) }
        readRelated = readRelated.filter { sprint.contains($0.first) || sprint.contains($0.second) }
        let parents = wantedParents()
        links.parents = links.parents.filter { parents.contains($0.key) }
        parentsRead = parentsRead.filter { parents.contains($0.key) }
        let mapParents = wantedMapParents()
        links.mapParents = links.mapParents.filter { mapParents.contains($0.key) }
        mapParentsRead = mapParentsRead.filter { mapParents.contains($0.key) }
    }

    private func publish() {
        var pending: Set<WorkItemKey> = []
        var unreadable: Set<PRKey> = []
        var partlyRead: Set<WorkItemKey> = []
        if inputs.wantsStories {
            for (pullRequest, ids) in links.workItemsOfPullRequests {
                for id in ids {
                    let key = WorkItemKey(pullRequest.organization, id)
                    if workItemsRead[key] == nil, !inputs.sprintItems.contains(key), failures["wi \(key)"] == nil { pending.insert(key) }
                }
            }
            unreadable = Set(inputs.pullRequests.keys.filter { links.workItemsOfPullRequests[$0] == nil && failures["pr \($0)"] != nil })
            partlyRead = Set(links.workItems.keys).subtracting(readWithStories).subtracting(inputs.sprintItems)
        }
        links.pendingWorkItems = pending
        links.unreadablePullRequests = unreadable
        links.partlyRead = partlyRead
        var dependencies = readDependencies
        for (dependency, change) in dependencyChanges {
            if change.linked { dependencies.insert(dependency) } else { dependencies.remove(dependency) }
        }
        links.dependencies = dependencies
        links.related = readRelated
        guard links != lastPublished else { return }
        lastPublished = links
        onChange(links)
    }
}

extension LinkEngine {
    /// What reading pull requests by their numbers got: the ones read, and the ones that couldn't be. One it didn't get to,
    /// once Azure DevOps asked to slow down or the read was cancelled, is in neither.
    public struct Lookups: Sendable, Equatable {
        public var read: [PRKey: PullRequest] = [:]
        public var failed: Set<PRKey> = []

        public init(read: [PRKey: PullRequest] = [:], failed: Set<PRKey> = []) {
            self.read = read
            self.failed = failed
        }
    }

    /// Reads pull requests by their numbers, as Show Links reads those your lists don't have: a GET each, one after another,
    /// every one of them, unless Azure DevOps asks to slow down or the read is cancelled.
    public static func lookUp(_ keys: [PRKey], client: ADOClient) async -> Lookups {
        var lookups = Lookups()
        for key in keys {
            guard !Task.isCancelled else { break }
            do {
                let dto = try await client.get(ADOEndpoint.pullRequest(organization: key.organization, id: key.number), as: ADOPullRequest.self)
                lookups.read[key] = PullRequest(organization: key.organization, dto)
            } catch {
                if error is CancellationError { break }
                if case .throttled = error as? ADOError { break }
                lookups.failed.insert(key)
            }
        }
        return lookups
    }
}
