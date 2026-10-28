import BriefBarCore
import Foundation

/// A work item as its details beside the sprint show it, read when you open it: what it is and where it stands, its long
/// text, the work items it links to, and its discussion.
public struct WorkItemDetails: Sendable, Equatable {
    /// One of its long text fields, such as its description.
    public struct LongText: Sendable, Equatable, Identifiable {
        /// The field, such as `System.Description`.
        public var id: String
        /// Such as "Description".
        public var title: String
        public var text: RichText

        public init(id: String, title: String, text: RichText) {
            self.id = id
            self.title = title
            self.text = text
        }
    }

    /// A work item it links to.
    public struct Link: Sendable, Equatable, Identifiable {
        public enum Kind: Int, Sendable, Comparable {
            case parent, child, other

            public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        public var kind: Kind
        /// Such as "Parent", "Child", "Related" or "Successor", as Azure DevOps names the link.
        public var name: String
        public var workItemId: Int
        /// What it is, when it could be read.
        public var item: WorkItem?

        public init(kind: Kind, name: String, workItemId: Int, item: WorkItem? = nil) {
            self.kind = kind
            self.name = name
            self.workItemId = workItemId
            self.item = item
        }

        public var id: String { "\(name)/\(workItemId)" }
    }

    /// A file attached to it, or a web page it links to, which open in the browser.
    public struct Resource: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case attachment, webPage
        }

        public var kind: Kind
        public var name: String
        public var url: URL

        public init(kind: Kind, name: String, url: URL) {
            self.kind = kind
            self.name = name
            self.url = url
        }

        public var id: String { url.absoluteString }
    }

    public struct Comment: Sendable, Equatable, Identifiable {
        public var id: Int
        public var author: Person?
        public var createdAt: Date?
        /// It was changed after it was posted.
        public var isEdited: Bool
        public var text: RichText

        public init(id: Int, author: Person?, createdAt: Date?, isEdited: Bool = false, text: RichText) {
            self.id = id
            self.author = author
            self.createdAt = createdAt
            self.isEdited = isEdited
            self.text = text
        }
    }

    /// Its type, title, state, who has it, its parent, hours left and tags.
    public var item: WorkItem
    /// Why it's in its state, such as "Implementation started".
    public var reason: String?
    public var areaPath: String?
    public var iterationPath: String?
    public var priority: Int?
    /// A bug's, such as "2 - High".
    public var severity: String?
    /// How big a story, backlog item or bug is: its story points, effort or size.
    public var size: Double?
    /// What its process calls its size: "Story Points", "Effort" or "Size".
    public var sizeTitle: String?
    /// A task's hours estimated at first, and done so far.
    public var originalEstimate: Double?
    public var completedWork: Double?
    /// The kind of work, such as "Development".
    public var activity: String?
    public var createdBy: Person?
    public var createdAt: Date?
    public var changedBy: Person?
    /// Its description, repro steps, system info and acceptance criteria: those it has, in that order.
    public var texts: [LongText]
    /// Its parent, then its children in backlog order, then the rest by the link's name.
    public var links: [Link]
    /// Its attachments, then the web pages it links to.
    public var resources: [Resource]
    /// Its latest comments, newest first.
    public var comments: [Comment]
    /// How many comments it has: more than `comments` once it has more than BriefBar reads.
    public var commentCount: Int
    /// Why its comments couldn't be read; nil when they were.
    public var commentsProblem: String?
    public var readAt: Date

    public init(
        item: WorkItem, reason: String? = nil, areaPath: String? = nil, iterationPath: String? = nil, priority: Int? = nil,
        severity: String? = nil, size: Double? = nil, sizeTitle: String? = nil, originalEstimate: Double? = nil,
        completedWork: Double? = nil, activity: String? = nil, createdBy: Person? = nil, createdAt: Date? = nil,
        changedBy: Person? = nil, texts: [LongText] = [], links: [Link] = [], resources: [Resource] = [], comments: [Comment] = [],
        commentCount: Int? = nil, commentsProblem: String? = nil, readAt: Date
    ) {
        self.item = item
        self.reason = reason
        self.areaPath = areaPath
        self.iterationPath = iterationPath
        self.priority = priority
        self.severity = severity
        self.size = size
        self.sizeTitle = size == nil ? nil : sizeTitle ?? "Size"
        self.originalEstimate = originalEstimate
        self.completedWork = completedWork
        self.activity = activity
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.changedBy = changedBy
        self.texts = texts
        self.links = links.sorted(by: Self.order)
        self.resources = resources.filter { $0.kind == .attachment } + resources.filter { $0.kind == .webPage }
        self.comments = comments
        self.commentCount = max(commentCount ?? 0, comments.count)
        self.commentsProblem = commentsProblem
        self.readAt = readAt
    }

    public var key: WorkItemKey { item.key }

    public var parent: Link? { links.first { $0.kind == .parent } }

    public var children: [Link] { links.filter { $0.kind == .child } }

    /// Its links but to its parent and children, such as related work items.
    public var otherLinks: [Link] { links.filter { $0.kind == .other } }

    /// Parent, children, then the others by name; each in backlog order, then by ID.
    private static func order(_ lhs: Link, _ rhs: Link) -> Bool {
        func key(_ link: Link) -> (Int, String, Double, Int) {
            (link.kind.rawValue, link.kind == .other ? link.name.lowercased() : "", link.item?.rank ?? .greatestFiniteMagnitude, link.workItemId)
        }
        return key(lhs) < key(rhs)
    }

    /// The long text fields it shows, in order: what a story, a bug or a task is about.
    static let textFields: [(field: String, title: String)] = [
        ("System.Description", "Description"),
        ("Microsoft.VSTS.TCM.ReproSteps", "Repro Steps"),
        ("Microsoft.VSTS.TCM.SystemInfo", "System Info"),
        ("Microsoft.VSTS.Common.AcceptanceCriteria", "Acceptance Criteria"),
    ]

    /// What Azure DevOps read. `linked` are the work items it links to, by ID, as read.
    init(
        organization: String, project: String, _ dto: ADOWorkItemDetails, comments: Result<ADOWorkItemComments, ADOError>?,
        linked: [Int: WorkItem], readAt: Date
    ) {
        let fields = dto.fields
        let texts = Self.textFields.compactMap { field, title -> LongText? in
            guard let raw = fields.texts[field], !raw.allSatisfy(\.isWhitespace) else { return nil }
            let text = RichText(raw, format: dto.multilineFieldsFormat.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value)
            return text.isEmpty ? nil : LongText(id: field, title: title, text: text)
        }
        let links = dto.relations.compactMap { relation -> Link? in
            guard let id = relation.workItemId(in: organization) else { return nil }
            let kind: Link.Kind = switch relation.rel {
            case "System.LinkTypes.Hierarchy-Reverse": .parent
            case "System.LinkTypes.Hierarchy-Forward": .child
            default: .other
            }
            let name = relation.name.flatMap { $0.isEmpty ? nil : $0 } ?? Self.linkName(relation.rel)
            return Link(kind: kind, name: name, workItemId: id, item: linked[id])
        }
        var seen: Set<URL> = []
        let resources = dto.relations.compactMap { $0.resource(in: organization) }.filter { seen.insert($0.url).inserted }
        let size = fields.storyPoints.map { ($0, "Story Points") } ?? fields.effort.map { ($0, "Effort") } ?? fields.size.map { ($0, "Size") }
        var read: [Comment] = []
        var problem: String?
        var total = fields.commentCount
        switch comments {
        case .success(let list)?:
            read = list.comments.compactMap(Self.comment)
            total = list.totalCount ?? total
        case .failure(let error)?:
            problem = error.description
        case nil:
            problem = "Azure DevOps didn't say which project it's in."
        }
        func text(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        self.init(
            item: WorkItem(organization: organization, project: project, dto.basics), reason: text(fields.reason),
            areaPath: text(fields.areaPath), iterationPath: text(fields.iterationPath), priority: fields.priority,
            severity: text(fields.severity), size: size?.0, sizeTitle: size?.1, originalEstimate: fields.originalEstimate,
            completedWork: fields.completedWork, activity: text(fields.activity), createdBy: fields.createdBy.map(Person.init),
            createdAt: fields.createdDate, changedBy: fields.changedBy.map(Person.init), texts: texts, links: links,
            resources: resources, comments: read, commentCount: total, commentsProblem: problem, readAt: readAt
        )
    }

    /// A comment that wasn't deleted and says something: its text as Azure DevOps renders it, when it does.
    static func comment(_ dto: ADOWorkItemComments.Comment) -> Comment? {
        guard dto.isDeleted != true, let id = dto.id else { return nil }
        let text: RichText
        if let rendered = dto.renderedText, !rendered.allSatisfy(\.isWhitespace) {
            text = RichText(html: rendered)
        } else {
            text = RichText(dto.text ?? "", format: dto.format)
        }
        guard !text.isEmpty else { return nil }
        var edited = false
        if let created = dto.createdDate, let modified = dto.modifiedDate {
            edited = modified.timeIntervalSince(created) > 1
        }
        return Comment(id: id, author: dto.createdBy.map(Person.init), createdAt: dto.createdDate, isEdited: edited, text: text)
    }

    /// The name of a link to a work item, when Azure DevOps doesn't give it.
    static func linkName(_ rel: String?) -> String {
        switch rel {
        case "System.LinkTypes.Hierarchy-Reverse": return "Parent"
        case "System.LinkTypes.Hierarchy-Forward": return "Child"
        case "System.LinkTypes.Related": return "Related"
        case "System.LinkTypes.Remote.Related": return "Remote Related"
        case "System.LinkTypes.Dependency-Forward": return "Successor"
        case "System.LinkTypes.Dependency-Reverse": return "Predecessor"
        case "System.LinkTypes.Duplicate-Forward": return "Duplicate"
        case "System.LinkTypes.Duplicate-Reverse": return "Duplicate Of"
        case "Microsoft.VSTS.Common.TestedBy-Forward": return "Tested By"
        case "Microsoft.VSTS.Common.TestedBy-Reverse": return "Tests"
        case "Microsoft.VSTS.Common.Affects-Forward": return "Affects"
        case "Microsoft.VSTS.Common.Affects-Reverse": return "Affected By"
        default: return "Linked"
        }
    }
}

extension WorkItem {
    /// Which work item it is, in its organization.
    public var key: WorkItemKey { WorkItemKey(organization, id) }
}

extension SprintBoard {
    /// A story, bug or task on the board.
    public func item(_ key: WorkItemKey) -> WorkItem? {
        for row in rows {
            if let parent = row.parent, parent.key == key { return parent }
            if let task = row.tasks.first(where: { $0.key == key }) { return task }
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Responses

/// A work item with all its fields and its links, from `_apis/wit/workitems/{id}?$expand=relations`.
public struct ADOWorkItemDetails: Decodable, Sendable {
    public var id: Int
    /// The fields the sprint reads too.
    public var basics: ADOWorkItem
    public var fields: Fields
    public var relations: [Relation]
    /// Field → `Markdown`, for the long text fields kept as Markdown; the others are HTML.
    public var multilineFieldsFormat: [String: String]

    public struct Fields: Decodable, Sendable {
        public var reason: String?
        public var areaPath: String?
        public var iterationPath: String?
        public var createdBy: ADOIdentity?
        public var createdDate: Date?
        public var changedBy: ADOIdentity?
        public var commentCount: Int?
        public var priority: Int?
        public var severity: String?
        public var storyPoints: Double?
        public var effort: Double?
        public var size: Double?
        public var originalEstimate: Double?
        public var completedWork: Double?
        public var activity: String?
        /// The long text fields, by field: description, repro steps, system info and acceptance criteria.
        public var texts: [String: String]

        enum CodingKeys: String, CodingKey {
            case reason = "System.Reason"
            case areaPath = "System.AreaPath"
            case iterationPath = "System.IterationPath"
            case createdBy = "System.CreatedBy"
            case createdDate = "System.CreatedDate"
            case changedBy = "System.ChangedBy"
            case commentCount = "System.CommentCount"
            case priority = "Microsoft.VSTS.Common.Priority"
            case severity = "Microsoft.VSTS.Common.Severity"
            case storyPoints = "Microsoft.VSTS.Scheduling.StoryPoints"
            case effort = "Microsoft.VSTS.Scheduling.Effort"
            case size = "Microsoft.VSTS.Scheduling.Size"
            case originalEstimate = "Microsoft.VSTS.Scheduling.OriginalEstimate"
            case completedWork = "Microsoft.VSTS.Scheduling.CompletedWork"
            case activity = "Microsoft.VSTS.Common.Activity"
            case description = "System.Description"
            case reproSteps = "Microsoft.VSTS.TCM.ReproSteps"
            case systemInfo = "Microsoft.VSTS.TCM.SystemInfo"
            case acceptanceCriteria = "Microsoft.VSTS.Common.AcceptanceCriteria"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func number(_ key: CodingKeys) -> Double? {
                container.lenient(Double.self, forKey: key)
            }
            reason = container.lenient(String.self, forKey: .reason)
            areaPath = container.lenient(String.self, forKey: .areaPath)
            iterationPath = container.lenient(String.self, forKey: .iterationPath)
            createdBy = container.lenient(ADOIdentity.self, forKey: .createdBy)
            createdDate = container.lenient(Date.self, forKey: .createdDate)
            changedBy = container.lenient(ADOIdentity.self, forKey: .changedBy)
            commentCount = number(.commentCount).flatMap { Int(exactly: $0) }
            priority = number(.priority).flatMap { Int(exactly: $0) }
            severity = container.lenient(String.self, forKey: .severity)
            storyPoints = number(.storyPoints)
            effort = number(.effort)
            size = number(.size)
            originalEstimate = number(.originalEstimate)
            completedWork = number(.completedWork)
            activity = container.lenient(String.self, forKey: .activity)
            var texts: [String: String] = [:]
            for key in [CodingKeys.description, .reproSteps, .systemInfo, .acceptanceCriteria] {
                texts[key.rawValue] = container.lenient(String.self, forKey: key)
            }
            self.texts = texts
        }
    }

    /// A link: to a work item, or to something else, such as a pull request (`ArtifactLink`), a file (`AttachedFile`) or a
    /// web page (`Hyperlink`).
    public struct Relation: Decodable, Sendable {
        public var rel: String?
        public var url: String?
        /// How Azure DevOps names it: a link's type, such as "Parent", or an attachment's file name.
        public var name: String?
        /// What a web page is, as whoever linked it said.
        public var comment: String?

        private enum CodingKeys: String, CodingKey { case rel, url, attributes }

        private struct Attributes: Decodable {
            var name: String?
            var comment: String?

            private enum CodingKeys: String, CodingKey { case name, comment }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = container.lenient(String.self, forKey: .name)
                comment = container.lenient(String.self, forKey: .comment)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rel = container.lenient(String.self, forKey: .rel)
            url = container.lenient(String.self, forKey: .url)
            let attributes = container.lenient(Attributes.self, forKey: .attributes)
            name = attributes?.name
            comment = attributes?.comment
        }

        /// A file attached to it, which opens with its name, a web page it links to, or a work item in another organization
        /// than `organization`, such as a remote link's, which opens there.
        public func resource(in organization: String) -> WorkItemDetails.Resource? {
            let named = name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            switch rel {
            case "AttachedFile":
                guard let link = RichText.webLink(url) else { return nil }
                let fileName = named ?? RichText.fileName(of: link) ?? "Attachment"
                guard var components = URLComponents(url: link, resolvingAgainstBaseURL: false) else {
                    return WorkItemDetails.Resource(kind: .attachment, name: fileName, url: link)
                }
                let query = components.queryItems ?? []
                if !query.contains(where: { $0.name.lowercased() == "filename" }) {
                    components.queryItems = query + [URLQueryItem(name: "fileName", value: fileName)]
                }
                return WorkItemDetails.Resource(kind: .attachment, name: fileName, url: components.url ?? link)
            case "Hyperlink":
                guard let link = RichText.webLink(url) else { return nil }
                let said = comment?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                return WorkItemDetails.Resource(kind: .webPage, name: said ?? link.absoluteString, url: link)
            default:
                guard let target, target.organization.caseInsensitiveCompare(organization) != .orderedSame else { return nil }
                let page = ADOEndpoint.url(
                    "https://dev.azure.com", [target.organization] + (target.project.map { [$0] } ?? []) + ["_workitems", "edit", String(target.id)],
                    []
                )
                let title = "\(named ?? WorkItemDetails.linkName(rel)): work item \(target.id) in \(target.organization)"
                return WorkItemDetails.Resource(kind: .webPage, name: title, url: page)
            }
        }

        /// The ID of the work item it links to in `organization`; nil for a link to anything else, or to a work item in
        /// another organization, whose ID means another work item here.
        public func workItemId(in organization: String) -> Int? {
            guard let target, target.organization.caseInsensitiveCompare(organization) == .orderedSame else { return nil }
            return target.id
        }

        /// The work item it links to, for a link to one, as its address says: `{organization}[/{project}]/_apis/wit/
        /// workItems/{id}` on dev.azure.com, or on `{organization}.visualstudio.com`.
        var target: (organization: String, project: String?, id: Int)? {
            guard let rel, !["ArtifactLink", "Hyperlink", "AttachedFile"].contains(rel), let url,
                  let components = URLComponents(string: url), let host = components.host?.lowercased()
            else { return nil }
            var parts = components.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            let organization: String
            if host == "dev.azure.com" {
                guard !parts.isEmpty else { return nil }
                organization = parts.removeFirst()
            } else if host.hasSuffix(".visualstudio.com") {
                organization = String(host.dropLast(".visualstudio.com".count))
                if parts.first?.lowercased() == "defaultcollection" { parts.removeFirst() }
            } else {
                return nil
            }
            guard !organization.isEmpty, let index = parts.firstIndex(where: { $0.lowercased() == "_apis" }), index <= 1,
                  parts.count == index + 4, parts[index + 1].lowercased() == "wit", parts[index + 2].lowercased() == "workitems",
                  let id = Int(parts[index + 3]), id > 0
            else { return nil }
            return (organization, index == 1 ? parts[0] : nil, id)
        }
    }

    private enum CodingKeys: String, CodingKey { case id, fields, relations, multilineFieldsFormat }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        basics = try ADOWorkItem(from: decoder)
        fields = try container.decode(Fields.self, forKey: .fields)
        relations = container.lenient(LenientArray<Relation>.self, forKey: .relations)?.elements ?? []
        multilineFieldsFormat = container.lenient([String: String].self, forKey: .multilineFieldsFormat) ?? [:]
    }
}

/// A work item's comments, from `{project}/_apis/wit/workItems/{id}/comments`.
public struct ADOWorkItemComments: Decodable, Sendable {
    public var totalCount: Int?
    public var comments: [Comment]

    public struct Comment: Decodable, Sendable {
        public var id: Int?
        /// As written: HTML, or Markdown when `format` says so.
        public var text: String?
        /// As HTML, whatever it was written in, when asked for (`$expand=renderedText`).
        public var renderedText: String?
        /// `html` or `markdown`.
        public var format: String?
        public var createdBy: ADOIdentity?
        public var createdDate: Date?
        public var modifiedDate: Date?
        public var isDeleted: Bool?

        // Older answers call its ID `commentId`.
        private enum CodingKeys: String, CodingKey {
            case id, commentId, text, renderedText, format, createdBy, createdDate, modifiedDate, isDeleted
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.lenient(Int.self, forKey: .id) ?? container.lenient(Int.self, forKey: .commentId)
            text = container.lenient(String.self, forKey: .text)
            renderedText = container.lenient(String.self, forKey: .renderedText)
            format = container.lenient(String.self, forKey: .format)
            createdBy = container.lenient(ADOIdentity.self, forKey: .createdBy)
            createdDate = container.lenient(Date.self, forKey: .createdDate)
            modifiedDate = container.lenient(Date.self, forKey: .modifiedDate)
            isDeleted = container.lenient(Bool.self, forKey: .isDeleted)
        }
    }

    private enum CodingKeys: String, CodingKey { case totalCount, comments }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalCount = container.lenient(Int.self, forKey: .totalCount)
        comments = container.lenient(LenientArray<Comment>.self, forKey: .comments)?.elements ?? []
    }
}

extension ADOEndpoint {
    /// A work item with all its fields and its links.
    public static func workItem(organization: String, id: Int) -> URL {
        url("https://dev.azure.com", [organization, "_apis", "wit", "workitems", String(id)],
            [("$expand", "relations"), ("api-version", apiVersion)])
    }

    /// A work item's latest comments, newest first, each also as HTML (`renderedText`). Only a preview version of the API
    /// has comments.
    public static func workItemComments(organization: String, project: String, id: Int, top: Int) -> URL {
        url("https://dev.azure.com", [organization, project, "_apis", "wit", "workItems", String(id), "comments"], [
            ("$top", String(top)), ("order", "desc"), ("$expand", "renderedText"), ("api-version", "7.1-preview.4"),
        ])
    }
}

// MARK: - Reading

/// Reads a work item's details when you open it, with GETs: the work item with its fields and links, and its latest
/// comments, at the same time when its project is known; then what the work items it links to are, in one request.
public enum WorkItemDetailsReader {
    /// The latest comments it reads; Azure DevOps has the rest.
    public static let commentsRead = 50
    /// What a linked work item shows: what it is, where it stands, who has it and its place in the backlog.
    static let linkedFields = [
        "System.Title", "System.WorkItemType", "System.State", "System.TeamProject", "System.AssignedTo",
        "Microsoft.VSTS.Scheduling.RemainingWork", "Microsoft.VSTS.Common.StackRank", "Microsoft.VSTS.Common.BacklogPriority",
        "System.ChangedDate",
    ]

    /// - Parameter project: its project's name, as the sprint knows it, to read its comments with it; nil when it isn't
    ///   known, to read them once the work item says.
    public static func read(client: ADOClient, organization: String, project: String?, id: Int, now: Date = Date()) async throws
        -> WorkItemDetails {
        let address = ADOEndpoint.workItem(organization: organization, id: id)
        let dto: ADOWorkItemDetails
        var comments: Result<ADOWorkItemComments, ADOError>?
        if let project, !project.isEmpty {
            async let item = client.get(address, as: ADOWorkItemDetails.self)
            async let discussion = readComments(client: client, organization: organization, project: project, id: id)
            dto = try await item
            comments = await discussion
        } else {
            dto = try await client.get(address, as: ADOWorkItemDetails.self)
        }
        let itsProject = dto.basics.fields.teamProject ?? project ?? ""
        // Not read yet, or read through a project it has left.
        if !itsProject.isEmpty, comments == nil || (comments.map(isNotFound) == true && itsProject.caseInsensitiveCompare(project ?? "") != .orderedSame) {
            comments = await readComments(client: client, organization: organization, project: itsProject, id: id)
        }
        try Task.checkCancellation()
        let linked = await readLinked(client: client, organization: organization, ids: dto.relations.compactMap { $0.workItemId(in: organization) })
        return WorkItemDetails(organization: organization, project: itsProject, dto, comments: comments, linked: linked, readAt: now)
    }

    private static func isNotFound(_ result: Result<ADOWorkItemComments, ADOError>) -> Bool {
        if case .failure(.notFound) = result { return true }
        return false
    }

    static func readComments(client: ADOClient, organization: String, project: String, id: Int) async -> Result<ADOWorkItemComments, ADOError> {
        do {
            let address = ADOEndpoint.workItemComments(organization: organization, project: project, id: id, top: commentsRead)
            return .success(try await client.get(address, as: ADOWorkItemComments.self))
        } catch let error as ADOError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// What the linked work items are, by ID: those that can't be read are left out, and so is everything when the
    /// request fails, which leaves their IDs to show.
    static func readLinked(client: ADOClient, organization: String, ids: [Int]) async -> [Int: WorkItem] {
        let unique = Array(Set(ids)).sorted().prefix(SprintEngine.batchSize)
        guard !unique.isEmpty else { return [:] }
        do {
            let list = try await client.get(
                ADOEndpoint.workItems(organization: organization, ids: Array(unique), fields: linkedFields), as: ADOList<ADOWorkItem>.self
            )
            var items: [Int: WorkItem] = [:]
            for dto in list.value {
                items[dto.id] = WorkItem(organization: organization, project: dto.fields.teamProject ?? "", dto)
            }
            return items
        } catch {
            return [:]
        }
    }
}
