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
/// pull requests, and what those linked work items and pull requests are, when no list shows them.
public struct WorkLinks: Sendable, Equatable {
    /// Each pull request's work items, by ID, in its organization.
    public var workItemsOfPullRequests: [PRKey: [Int]]
    /// Each sprint work item's pull requests.
    public var pullRequestsOfWorkItems: [WorkItemKey: [PRKey]]
    /// Linked work items the sprint doesn't show, as read.
    public var workItems: [WorkItemKey: WorkItem]
    /// Linked pull requests your lists don't show, as read.
    public var pullRequests: [PRKey: PullRequest]

    public init(
        workItemsOfPullRequests: [PRKey: [Int]] = [:], pullRequestsOfWorkItems: [WorkItemKey: [PRKey]] = [:],
        workItems: [WorkItemKey: WorkItem] = [:], pullRequests: [PRKey: PullRequest] = [:]
    ) {
        self.workItemsOfPullRequests = workItemsOfPullRequests
        self.pullRequestsOfWorkItems = pullRequestsOfWorkItems
        self.workItems = workItems
        self.pullRequests = pullRequests
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

    /// What a linked work item shows: what it is, where it stands, and its project, for its page.
    public static let workItemFields = ["System.Title", "System.WorkItemType", "System.State", "System.TeamProject", "System.ChangedDate"]
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
/// while the sprint shows (one GET for up to 200, then every quarter of an hour), and what the linked work items and pull
/// requests that no list shows are (a GET for up to 200 work items; one for each pull request, ten a refresh). Every request
/// is a GET. What can't be read is tried again an hour later.
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

        public init(
            pullRequests: [PRKey: Place] = [:], sprintItems: Set<WorkItemKey> = [], sprintShows: Bool = false,
            workItemLookups: Set<WorkItemKey> = [], pullRequestLookups: Set<PRKey> = []
        ) {
            self.pullRequests = Dictionary(pullRequests.map { (PRKey($0.key.organization.lowercased(), $0.key.number), $0.value) },
                                           uniquingKeysWith: { first, _ in first })
            self.sprintItems = sprintItems
            self.sprintShows = sprintShows
            self.workItemLookups = workItemLookups
            self.pullRequestLookups = Set(pullRequestLookups.map { PRKey($0.organization.lowercased(), $0.number) })
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
    private var lookupsRead: [PRKey: Date] = [:]
    /// When each read failed, by what it read, to try again later rather than every refresh.
    private var failures: [String: Date] = [:]
    private var isRefreshing = false
    private var again = false
    private var isStopped = false
    private var lastPublished: WorkLinks?

    public init(client: ADOClient, now: @escaping @Sendable () -> Date = { Date() }, onChange: @escaping ChangeHandler) {
        self.client = client
        self.now = now
        self.onChange = onChange
    }

    /// What to read links for. What's no longer there is forgotten at once; what's new is read now.
    public func update(_ inputs: Inputs) async {
        guard inputs != self.inputs else { return }
        self.inputs = inputs
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

    private func readDue() async {
        let date = now()
        do {
            try await readWorkItemsOfPullRequests(at: date)
            try await readPullRequestsOfSprint(at: date)
            try await readLinkedWorkItems(at: date)
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

    private func isDue(_ read: Date?, failed: Date?, at date: Date, after interval: TimeInterval = relinkAfter) -> Bool {
        if let failed, date.timeIntervalSince(failed) < Self.retryAfter { return false }
        guard let read else { return true }
        return date.timeIntervalSince(read) >= interval
    }

    /// The pull requests' work items: the ones never read first, many at a time, then a few of those read longest ago.
    private func readWorkItemsOfPullRequests(at date: Date) async throws {
        let due = inputs.pullRequests.keys.filter { isDue(pullRequestsRead[$0], failed: failures["pr \($0)"], at: date) }
        let first = due.filter { pullRequestsRead[$0] == nil }.sorted().prefix(Self.firstReadsPerRefresh)
        let again = due.filter { pullRequestsRead[$0] != nil }
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
            } catch {
                try Self.rethrowThrottling(error)
                failures["pr \(key)"] = date
            }
        }
    }

    /// The sprint's work items' pull requests, while it shows: when its work items change, and every quarter of an hour.
    private func readPullRequestsOfSprint(at date: Date) async throws {
        guard inputs.sprintShows, !inputs.sprintItems.isEmpty else { return }
        if let sprintRead, sprintRead.items == inputs.sprintItems, date.timeIntervalSince(sprintRead.at) < Self.relinkAfter { return }
        if let failed = failures["sprint"], date.timeIntervalSince(failed) < Self.relinkAfter { return }
        let items = inputs.sprintItems
        var found: [WorkItemKey: [PRKey]] = [:]
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
                    }
                } catch {
                    try Self.rethrowThrottling(error)
                    failures["sprint"] = date
                    return
                }
            }
        }
        links.pullRequestsOfWorkItems = found.filter { inputs.sprintItems.contains($0.key) && !$0.value.isEmpty }
        sprintRead = (items, date)
        failures["sprint"] = nil
    }

    /// What the work items linked to your pull requests are, when the sprint doesn't show them, and those you linked.
    private func readLinkedWorkItems(at date: Date) async throws {
        var wanted = inputs.workItemLookups
        for (pullRequest, ids) in links.workItemsOfPullRequests {
            for id in ids { wanted.insert(WorkItemKey(pullRequest.organization, id)) }
        }
        wanted.subtract(inputs.sprintItems)
        links.workItems = links.workItems.filter { wanted.contains($0.key) }
        workItemsRead = workItemsRead.filter { wanted.contains($0.key) }
        let due = wanted.filter { isDue(workItemsRead[$0], failed: failures["wi \($0)"], at: date) }
        for (organization, keys) in Dictionary(grouping: due, by: \.organization) {
            let ids = keys.map(\.id).sorted()
            for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
                let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
                do {
                    let list = try await get(
                        ADOEndpoint.workItems(organization: organization, ids: batch, fields: WorkLinks.workItemFields),
                        as: ADOList<ADOWorkItem>.self
                    )
                    for dto in list.value {
                        let key = WorkItemKey(organization, dto.id)
                        guard wanted.contains(key) else { continue }
                        links.workItems[key] = WorkItem(organization: organization, project: dto.fields.teamProject ?? "", dto)
                    }
                    // Those left out were deleted, or can't be read: there's nothing more to show of them.
                    for id in batch { workItemsRead[WorkItemKey(organization, id)] = date }
                } catch {
                    try Self.rethrowThrottling(error)
                    for id in batch { failures["wi \(WorkItemKey(organization, id))"] = date }
                }
            }
        }
    }

    /// What the pull requests linked to the sprint's work items are, when your lists don't show them, and those you
    /// linked: ten a refresh, the ones never read first. An open one is read again every quarter of an hour, a closed one
    /// every six hours.
    private func readLinkedPullRequests(at date: Date) async throws {
        var wanted = inputs.pullRequestLookups
        for pullRequests in links.pullRequestsOfWorkItems.values { wanted.formUnion(pullRequests) }
        wanted.subtract(inputs.pullRequests.keys)
        links.pullRequests = links.pullRequests.filter { wanted.contains($0.key) }
        lookupsRead = lookupsRead.filter { wanted.contains($0.key) }
        let due = wanted.filter { key in
            let interval = links.pullRequests[key].map { $0.status == .active ? Self.relinkAfter : Self.closedRereadAfter } ?? 0
            return isDue(lookupsRead[key], failed: failures["lookup \(key)"], at: date, after: interval)
        }
        .sorted { (lookupsRead[$0] ?? .distantPast, $0) < (lookupsRead[$1] ?? .distantPast, $1) }
        for key in due.prefix(Self.lookupsPerRefresh) {
            do {
                let dto = try await get(ADOEndpoint.pullRequest(organization: key.organization, id: key.number), as: ADOPullRequest.self)
                if wanted.contains(key) { links.pullRequests[key] = PullRequest(organization: key.organization, dto) }
                lookupsRead[key] = date
                failures["lookup \(key)"] = nil
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

    /// Forgets what's no longer listed, or in the sprint.
    private func prune() {
        let listed = Set(inputs.pullRequests.keys)
        links.workItemsOfPullRequests = links.workItemsOfPullRequests.filter { listed.contains($0.key) }
        pullRequestsRead = pullRequestsRead.filter { listed.contains($0.key) }
        links.pullRequestsOfWorkItems = links.pullRequestsOfWorkItems.filter { inputs.sprintItems.contains($0.key) }
    }

    private func publish() {
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
