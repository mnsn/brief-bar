import Foundation

// A pull request's tags, which Azure DevOps calls its labels: what lists of pull requests carry of them, reading them on
// their own, what to suggest as you add one, and the tags you added, which BriefBar remembers for each project. Changing them
// is `ADOWrite`'s `addTag` and `removeTag`.

/// One of a pull request's tags, as Azure DevOps lists it (`WebApiTagDefinition`): the project's tag, by its ID, and its
/// name. One the project made inactive (`active` false) shows nowhere.
public struct ADOTag: Decodable, Sendable {
    public var id: String?
    public var name: String
    public var active: Bool?

    private enum CodingKeys: String, CodingKey { case id, name, active }

    public init(id: String? = nil, name: String, active: Bool? = nil) {
        self.id = id
        self.name = name
        self.active = active
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        id = container.lenient(String.self, forKey: .id)
        active = container.lenient(Bool.self, forKey: .active)
    }
}

/// A pull request's tags as a list of pull requests carries them (`labels`), read leniently: one that can't be read is left
/// out, and a value that isn't a list at all leaves them unknown.
public struct ADOTagList: Decodable, Sendable {
    /// Nil when it isn't a list.
    public var tags: [ADOTag]?

    public init(_ tags: [ADOTag]?) {
        self.tags = tags
    }

    /// Steps over one that can't be read.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    public init(from decoder: Decoder) throws {
        guard var items = try? decoder.unkeyedContainer() else {
            tags = nil
            return
        }
        var tags: [ADOTag] = []
        while !items.isAtEnd {
            if let tag = try? items.decode(ADOTag.self) {
                tags.append(tag)
            } else if (try? items.decode(Skip.self)) == nil {
                break
            }
        }
        self.tags = tags
    }
}

/// One of a pull request's tags: its name, as Azure DevOps spells it, and the ID of the project's tag, which taking it off
/// the pull request goes by, so a name with a slash in it is no trouble. Azure DevOps tells tags apart ignoring their letter
/// case, and so does BriefBar (`key`).
public struct PullRequestTag: Sendable, Codable, Hashable {
    public var name: String
    /// The project's tag's ID; nil for one the demo makes up.
    public var tagId: String?

    public init(_ name: String, tagId: String? = nil) {
        self.name = name
        self.tagId = tagId
    }

    /// Its name as tags are told apart: ignoring letter case.
    public var key: String { name.lowercased() }

    /// What a tag's name is, from what you typed: without the spaces and lines around it, and a line's break inside it as a
    /// space. Nil for nothing.
    public static func name(_ typed: String) -> String? {
        let name = typed.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The tags Azure DevOps lists for a pull request: the active ones, once each, in the order of their names.
    public static func tags(_ listed: [ADOTag]) -> [PullRequestTag] {
        var seen: Set<String> = []
        let tags = listed.compactMap { tag -> PullRequestTag? in
            guard tag.active != false, let name = name(tag.name), seen.insert(name.lowercased()).inserted else { return nil }
            return PullRequestTag(name, tagId: tag.id.flatMap { $0.isEmpty ? nil : $0 })
        }
        return sorted(tags)
    }

    /// What a list of pull requests carries of one's tags: none when it says nothing of them, as it leaves them out of a pull
    /// request that has none; nil, unknown, when what it says can't be read.
    public static func listed(_ labels: ADOTagList?) -> [PullRequestTag]? {
        guard let labels else { return [] }
        return labels.tags.map(tags)
    }

    /// In the order of their names, as they show: ignoring letter case, numbers by their value, so release-9 comes before
    /// release-10.
    public static func sorted(_ tags: [PullRequestTag]) -> [PullRequestTag] {
        tags.sorted { precedes($0.name, $1.name) }
    }

    /// Whether a tag's name comes before another's, as they show (`sorted`).
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.compare(rhs, options: [.caseInsensitive, .numeric]) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs < rhs
        }
    }

    /// Whether two pull requests' tags are the same, whatever their order, their letter case or their IDs; nil, unknown, is
    /// the same only as nil.
    public static func same(_ lhs: [PullRequestTag]?, _ rhs: [PullRequestTag]?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): Set(lhs.map(\.key)) == Set(rhs.map(\.key))
        default: false
        }
    }

    /// A pull request's tags with one Azure DevOps added, as it spells it: in place of one of that name it has already.
    public static func adding(_ tag: PullRequestTag, to tags: [PullRequestTag]) -> [PullRequestTag] {
        sorted(tags.filter { $0.key != tag.key } + [tag])
    }

    /// A pull request's tags without one.
    public static func removing(_ tag: PullRequestTag, from tags: [PullRequestTag]) -> [PullRequestTag] {
        tags.filter { $0.key != tag.key }
    }
}

extension ADOEndpoint {
    /// A pull request's tags, which Azure DevOps calls its labels.
    public static func tags(of pullRequest: PullRequestAddress) -> URL {
        url("https://dev.azure.com", pullRequest.path + ["labels"], [("api-version", apiVersion)])
    }
}

extension ADOClient {
    /// A pull request's tags, as Azure DevOps has them now: one GET.
    public func tags(of pullRequest: PullRequestAddress) async throws -> [PullRequestTag] {
        PullRequestTag.tags(try await get(ADOEndpoint.tags(of: pullRequest), as: ADOList<ADOTag>.self).value)
    }
}

// MARK: - Suggestions

/// What adding a tag to a pull request offers as you type: the tags you added in its project, the latest first, then those on
/// the pull requests BriefBar read there, the most used first, but for the pull request's own; those whose names start with
/// what you typed first, then those with a word that does, such as eu in deploy-eu, then those that have it anywhere,
/// ignoring letter case. What you typed is a new tag when it's none of them, nor one the pull request has.
public struct TagChoices: Sendable, Equatable {
    /// The tags to add, the best first, as Azure DevOps spells them.
    public var suggestions: [String]
    /// What you typed, as a new tag: when no suggestion and none of the pull request's tags is it.
    public var newTag: String?
    /// The pull request's tag that what you typed is, as it spells it: it has it already.
    public var alreadyOn: String?

    /// How many it suggests at most.
    public static let limit = 6

    /// Everything to choose from, in order: the suggestions, then the new tag.
    public var rows: [String] { suggestions + (newTag.map { [$0] } ?? []) }

    /// - Parameters:
    ///   - typed: what you typed so far.
    ///   - used: the tags you added in the pull request's project, the latest first (`UsedTags`).
    ///   - seen: the tags of each pull request BriefBar read in that project.
    ///   - current: the pull request's own, which it doesn't suggest.
    public init(typed: String, used: [String], seen: [[PullRequestTag]], current: [PullRequestTag], limit: Int = TagChoices.limit) {
        struct Candidate {
            var name: String
            /// How recently you added it: 0 for the latest; nil for one you didn't.
            var used: Int?
            /// How many of the pull requests read have it.
            var count = 0
        }
        var candidates: [String: Candidate] = [:]
        for tags in seen {
            var counted: Set<String> = []
            for tag in tags where counted.insert(tag.key).inserted {
                candidates[tag.key, default: Candidate(name: tag.name)].count += 1
            }
        }
        for (index, name) in used.enumerated() {
            guard let name = PullRequestTag.name(name) else { continue }
            let key = name.lowercased()
            if candidates[key] == nil { candidates[key] = Candidate(name: name) }
            if candidates[key]?.used == nil { candidates[key]?.used = index }
        }
        let currentKeys = Set(current.map(\.key))
        let needle = PullRequestTag.name(typed)?.lowercased() ?? ""
        let ranked = candidates.values
            .filter { !currentKeys.contains($0.name.lowercased()) }
            .compactMap { candidate -> (Int, Candidate)? in Self.match(candidate.name, needle).map { ($0, candidate) } }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                switch (lhs.1.used, rhs.1.used) {
                case let (left?, right?) where left != right: return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
                if lhs.1.count != rhs.1.count { return lhs.1.count > rhs.1.count }
                return PullRequestTag.precedes(lhs.1.name, rhs.1.name)
            }
        suggestions = ranked.prefix(limit).map(\.1.name)
        let typedName = PullRequestTag.name(typed)
        alreadyOn = typedName.flatMap { name in current.first { $0.key == name.lowercased() }?.name }
        if let typedName, alreadyOn == nil, !suggestions.contains(where: { $0.lowercased() == typedName.lowercased() }) {
            newTag = typedName
        } else {
            newTag = nil
        }
    }

    /// How well a name matches what you typed: 0 when it starts with it, 1 when one of its words does, 2 when it has it
    /// anywhere; nil when it doesn't. Everything matches nothing typed, as well as anything.
    static func match(_ name: String, _ typed: String) -> Int? {
        guard !typed.isEmpty else { return 0 }
        let name = name.lowercased()
        if name.hasPrefix(typed) { return 0 }
        var wordStart = false
        for index in name.indices {
            if wordStart, name[index...].hasPrefix(typed) { return 1 }
            wordStart = !(name[index].isLetter || name[index].isNumber)
        }
        return name.contains(typed) ? 2 : nil
    }
}

// MARK: - The tags you added

/// The tags you added to pull requests from BriefBar, which it remembers to suggest them: for each project, the latest first,
/// up to 20, and for the 20 projects you added tags in last. Only their names, by their projects' organizations and IDs.
public struct UsedTags: Sendable, Codable, Equatable {
    /// A project's, the latest first.
    public struct Project: Sendable, Codable, Equatable {
        /// `organization/project`, in lowercase, the project by its ID.
        public var project: String
        public var tags: [String]
    }

    /// The projects, the one you added a tag in last first.
    public private(set) var projects: [Project] = []

    public static let tagsPerProject = 20
    public static let projectLimit = 20

    public init() {}

    /// A project's, as BriefBar keeps them: its organization and its ID, which Azure DevOps tells apart ignoring case.
    static func project(organization: String, projectId: String) -> String {
        "\(organization)/\(projectId)".lowercased()
    }

    /// The tags you added in a project, the latest first.
    public func tags(organization: String, projectId: String) -> [String] {
        let project = Self.project(organization: organization, projectId: projectId)
        return projects.first { $0.project == project }?.tags ?? []
    }

    /// You added a tag in a project: it comes first there, once, as you spelled it last, and the project comes first.
    public mutating func add(_ tag: String, organization: String, projectId: String) {
        guard let name = PullRequestTag.name(tag) else { return }
        let project = Self.project(organization: organization, projectId: projectId)
        var tags = projects.first { $0.project == project }?.tags ?? []
        tags.removeAll { $0.lowercased() == name.lowercased() }
        tags.insert(name, at: 0)
        projects.removeAll { $0.project == project }
        projects.insert(Project(project: project, tags: Array(tags.prefix(Self.tagsPerProject))), at: 0)
        projects = Array(projects.prefix(Self.projectLimit))
    }

    public var isEmpty: Bool { projects.isEmpty }
}

// MARK: - The demo

/// The demo's made-up tags, which tell where a pull request deploys, a hotfix, or one that needs QA; and the tags you add
/// there, which change only its made-up data, in memory, while it runs.
public enum DemoTags {
    /// A made-up pull request's tags.
    public static func tags(of number: Int) -> [PullRequestTag] {
        let names: [String] = switch number {
        case 4102: ["deploy-eu", "needs-qa"]
        case 4091: ["deploy-eu", "deploy-us", "hotfix"]
        case 4093: ["deploy-us"]
        case 4088: ["deploy-eu", "release-notes"]
        case 4099: ["deploy-apac"]
        case 4097: ["needs-qa"]
        case 4113: ["deploy-us"]
        case 4085: ["deploy-eu", "deploy-us"]
        case 4060: ["deploy-us", "hotfix"]
        default: []
        }
        return PullRequestTag.sorted(names.map(tag))
    }

    /// A tag the demo adds, as Azure DevOps would answer: with a made-up ID.
    public static func tag(_ name: String) -> PullRequestTag {
        PullRequestTag(name, tagId: "demo-tag-\(name.lowercased())")
    }
}
