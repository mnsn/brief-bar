import BriefBarCore
import Foundation

/// A work item linked to a pull request, with the one it's under, such as a task's story: what agents are told of the work
/// a pull request is for (plan §7.4.6), as Azure DevOps links them.
public struct LinkedWork: Sendable, Equatable {
    public var item: WorkItem
    /// What it's under, once read; nil for none, or one that couldn't be read, which `item.parentId` still names.
    public var parent: WorkItem?

    public init(item: WorkItem, parent: WorkItem? = nil) {
        self.item = item
        self.parent = parent
    }
}

/// What agents' tools read of the work items that go with pull requests, as they answer, with GETs only.
public enum PullRequestWork {
    /// A pull request's work items, each with the one it's under, in ID order: one GET for their IDs, one for what they are,
    /// and one for what those they're under are, when they aren't among them; up to 200 each. Those deleted or that can't
    /// be read are left out.
    public static func read(_ pullRequest: PullRequest, client: ADOClient) async throws -> [LinkedWork] {
        let organization = pullRequest.key.organization
        let refs = try await client.get(ADOEndpoint.pullRequestWorkItems(
            organization: organization, projectId: pullRequest.projectId, repositoryId: pullRequest.repositoryId,
            pullRequestId: pullRequest.key.number
        ), as: ADOWorkItemRefs.self)
        let ids = Array(Set(refs.ids).sorted().prefix(LinkEngine.batchSize))
        guard !ids.isEmpty else { return [] }
        let items = try await workItems(ids, in: organization, fields: WorkLinks.workItemFields + ["System.Parent"], client: client)
        var known = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let parents = Set(items.compactMap(\.parentId)).subtracting(known.keys).sorted().prefix(LinkEngine.batchSize)
        if !parents.isEmpty {
            for parent in try await workItems(Array(parents), in: organization, fields: WorkLinks.workItemFields, client: client) {
                known[parent.id] = parent
            }
        }
        return linked(items, known: known)
    }

    /// Each of these work items, with the one it's under, as `read` gives them, from work items read already.
    public static func linked(_ items: [WorkItem], known: [Int: WorkItem]) -> [LinkedWork] {
        items.sorted { $0.id < $1.id }.map { item in LinkedWork(item: item, parent: item.parentId.flatMap { known[$0] }) }
    }

    /// The pull requests linked to each of these work items, in one organization: one GET for up to 200, with their
    /// relations. Those deleted or that can't be read are left out, and so are the others.
    public static func pullRequests(of ids: [Int], in organization: String, client: ADOClient) async throws -> [Int: [PRKey]] {
        let batch = Array(Set(ids).sorted().prefix(LinkEngine.batchSize))
        guard !batch.isEmpty else { return [:] }
        let list = try await client.get(
            ADOEndpoint.workItemRelations(organization: organization, ids: batch), as: ADOList<ADOWorkItemRelations>.self
        )
        var found: [Int: [PRKey]] = [:]
        for item in list.value {
            let pullRequests = item.pullRequests(in: organization)
            if !pullRequests.isEmpty { found[item.id] = pullRequests }
        }
        return found
    }

    private static func workItems(_ ids: [Int], in organization: String, fields: [String], client: ADOClient) async throws -> [WorkItem] {
        let list = try await client.get(ADOEndpoint.workItems(organization: organization, ids: ids, fields: fields), as: ADOList<ADOWorkItem>.self)
        return list.value.map { WorkItem(organization: organization, project: $0.fields.teamProject ?? "", $0) }
    }
}
