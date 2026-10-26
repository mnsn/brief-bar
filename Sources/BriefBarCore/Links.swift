import Foundation

/// One of the things links join, from whichever source lists it: an Azure DevOps pull request or work item, a GitHub
/// pull request, or a Copilot session. It says which one and nothing else: never its title.
public struct ItemRef: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// In the order their links show: work items, pull requests, then sessions.
    public enum Kind: String, Sendable, CaseIterable, Comparable {
        /// An Azure DevOps work item: its ID is unique within its organization.
        case workItem
        /// An Azure DevOps pull request: its number is unique within its organization.
        case pullRequest
        /// A GitHub pull request, numbered within its repository.
        case gitHubPullRequest
        /// A Copilot session, the app's or one BriefBar started: its ID is a UUID.
        case session

        public var isPullRequest: Bool { self == .pullRequest || self == .gitHubPullRequest }

        public static func < (lhs: Kind, rhs: Kind) -> Bool {
            (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
        }
    }

    public let kind: Kind
    /// Where its number is unique, lowercased: the Azure DevOps organization, the GitHub repository (`owner/name`), or
    /// nothing for a session.
    public let scope: String
    /// Its number, or the session's ID, lowercased.
    public let id: String

    private init(kind: Kind, scope: String, id: String) {
        self.kind = kind
        self.scope = scope
        self.id = id
    }

    public static func workItem(organization: String, id: Int) -> ItemRef {
        ItemRef(kind: .workItem, scope: organization.lowercased(), id: String(id))
    }

    public static func pullRequest(organization: String, number: Int) -> ItemRef {
        ItemRef(kind: .pullRequest, scope: organization.lowercased(), id: String(number))
    }

    public static func gitHubPullRequest(repository: String, number: Int) -> ItemRef {
        ItemRef(kind: .gitHubPullRequest, scope: repository.lowercased(), id: String(number))
    }

    /// A session, by its ID: nil unless it's a UUID, which is all a session's ID can be.
    public static func session(_ id: String) -> ItemRef? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return ItemRef(kind: .session, scope: "", id: uuid.uuidString.lowercased())
    }

    /// A work item's or a pull request's number.
    public var number: Int? { kind == .session ? nil : Int(id) }

    /// `workItem/contoso/5101`, `gitHubPullRequest/octo/app/12`, `session//<id>`: what's kept in the preferences.
    public var description: String { "\(kind.rawValue)/\(scope)/\(id)" }

    /// The reference a description names, checked as when it was made: nil for anything else, such as what another
    /// program wrote to the preferences.
    public init?(_ description: String) {
        let parts = description.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let kind = Kind(rawValue: parts[0]) else { return nil }
        let scope = parts[1..<(parts.count - 1)].joined(separator: "/")
        let id = parts[parts.count - 1]
        switch kind {
        case .session:
            guard scope.isEmpty, let made = ItemRef.session(id) else { return nil }
            self = made
        case .workItem, .pullRequest:
            guard Self.isOrganization(scope), let number = Self.number(id) else { return nil }
            self = kind == .workItem ? .workItem(organization: scope, id: number) : .pullRequest(organization: scope, number: number)
        case .gitHubPullRequest:
            guard Self.isRepository(scope), let number = Self.number(id) else { return nil }
            self = .gitHubPullRequest(repository: scope, number: number)
        }
    }

    public static func < (lhs: ItemRef, rhs: ItemRef) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.scope != rhs.scope { return lhs.scope < rhs.scope }
        if let left = lhs.number, let right = rhs.number { return left < right }
        return lhs.id < rhs.id
    }

    /// Whether the two can be linked: a pull request and a work item, or a session and either. Not two of a kind, and
    /// not two pull requests.
    public static func canLink(_ lhs: ItemRef, _ rhs: ItemRef) -> Bool {
        guard lhs != rhs, lhs.kind != rhs.kind else { return false }
        return !(lhs.kind.isPullRequest && rhs.kind.isPullRequest)
    }

    // MARK: Checks

    static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 10, text.allSatisfy(\.isASCIIDigit), let number = Int(text), number > 0 else { return nil }
        return number
    }

    /// An Azure DevOps organization's name: letters, digits and hyphens.
    static func isOrganization(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 100 && text.allSatisfy { $0.isASCIIAlphanumeric || $0 == "-" || $0 == "_" || $0 == "." }
    }

    /// A GitHub repository, `owner/name`: an owner of letters, digits and hyphens, and a name that may have dots and
    /// underscores too, but isn't `.` or `..`.
    static func isRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let owner = parts.first, let name = parts.last,
              !owner.isEmpty, owner.count <= 100, owner.allSatisfy({ $0.isASCIIAlphanumeric || $0 == "-" }),
              !name.isEmpty, name.count <= 100, name != ".", name != "..",
              name.allSatisfy({ $0.isASCIIAlphanumeric || $0 == "-" || $0 == "_" || $0 == "." })
        else { return false }
        return true
    }
}

extension ItemRef: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let made = ItemRef(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an item reference"))
        }
        self = made
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
    fileprivate var isASCIIAlphanumeric: Bool { isASCII && (isLetter || isNumber) }
}

// MARK: - Links

/// Where a link comes from, the most telling first.
public enum LinkOrigin: String, Codable, Sendable, CaseIterable, Comparable {
    /// Linked in Azure DevOps: a pull request's work items.
    case azureDevOps
    /// Copilot started there, or opened it: a session sent from a work item or a pull request, the pull request a session
    /// opened, or the work item it opened it for.
    case copilot
    /// A session on the pull request's branch, in the same repository.
    case branch
    /// You linked them, in BriefBar only.
    case you

    public static func < (lhs: LinkOrigin, rhs: LinkOrigin) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }

    /// "Linked in Azure DevOps", for menus and tooltips.
    public var title: String {
        switch self {
        case .azureDevOps: return "Linked in Azure DevOps"
        case .copilot: return "Recorded by Copilot"
        case .branch: return "On its branch"
        case .you: return "Linked by you, in BriefBar"
        }
    }
}

/// Two things that go together, in either order: what links compare by.
public struct LinkPair: Hashable, Sendable {
    /// The lesser of the two.
    public let first: ItemRef
    public let second: ItemRef

    /// Nil for two that can't be linked (`ItemRef.canLink`).
    public init?(_ lhs: ItemRef, _ rhs: ItemRef) {
        guard ItemRef.canLink(lhs, rhs) else { return nil }
        (first, second) = lhs < rhs ? (lhs, rhs) : (rhs, lhs)
    }

    public func contains(_ ref: ItemRef) -> Bool { first == ref || second == ref }

    /// The other end, for one of its ends.
    public func other(than ref: ItemRef) -> ItemRef? {
        first == ref ? second : second == ref ? first : nil
    }
}

/// A link a source knows from what it read, such as a pull request's work item in Azure DevOps.
public struct ItemLink: Hashable, Sendable {
    public let pair: LinkPair
    public let origin: LinkOrigin

    /// Nil for two that can't be linked.
    public init?(_ lhs: ItemRef, _ rhs: ItemRef, origin: LinkOrigin) {
        guard let pair = LinkPair(lhs, rhs) else { return nil }
        self.pair = pair
        self.origin = origin
    }
}

// MARK: - Your edits

/// The links you added in BriefBar, and the ones you hid there: BriefBar's own layer over what the sources know.
/// Nothing here goes back to Azure DevOps, GitHub or Copilot. It's kept in the preferences with references only, never
/// titles.
public struct LinkEdits: Equatable, Sendable {
    public private(set) var added: [LinkPair: Date]
    public private(set) var hidden: [LinkPair: Date]

    public init(added: [LinkPair: Date] = [:], hidden: [LinkPair: Date] = [:]) {
        self.added = added
        self.hidden = hidden
    }

    public var isEmpty: Bool { added.isEmpty && hidden.isEmpty }

    /// Links the two, and shows them again if you'd hidden their link.
    public mutating func link(_ lhs: ItemRef, _ rhs: ItemRef, at date: Date = Date()) {
        guard let pair = LinkPair(lhs, rhs) else { return }
        hidden[pair] = nil
        added[pair] = date
    }

    /// Takes away the link you added, and hides what a source knows of it, in BriefBar only.
    /// - Parameter hides: a source links them too, so the link stays hidden until you show it again.
    public mutating func unlink(_ lhs: ItemRef, _ rhs: ItemRef, hides: Bool, at date: Date = Date()) {
        guard let pair = LinkPair(lhs, rhs) else { return }
        added[pair] = nil
        if hides { hidden[pair] = date }
    }

    /// Shows a link you hid again.
    public mutating func showAgain(_ lhs: ItemRef, _ rhs: ItemRef) {
        guard let pair = LinkPair(lhs, rhs) else { return }
        hidden[pair] = nil
    }

    /// Forgets every edit about these kinds of things, when their source is turned off.
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) {
        let touches = { (pair: LinkPair) in kinds.contains(pair.first.kind) || kinds.contains(pair.second.kind) }
        added = added.filter { !touches($0.key) }
        hidden = hidden.filter { !touches($0.key) }
    }

    /// Forgets edits made before a date: what they joined has long moved on.
    public mutating func forget(before date: Date) {
        added = added.filter { $0.value >= date }
        hidden = hidden.filter { $0.value >= date }
    }

    // MARK: Saving

    public static let defaultsKey = "links"
    /// How long an edit is kept: pull requests and sessions are long done by then.
    public static let lifetime: TimeInterval = 180 * 86_400

    private struct Record: Codable {
        var first: ItemRef
        var second: ItemRef
        var hidden: Bool
        var date: Date
    }

    /// What's saved, without what can't be read, such as references another program wrote that aren't BriefBar's.
    public static func load(from defaults: some SettingsStorage) -> LinkEdits {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([Lossy<Record>].self, from: data)
        else { return LinkEdits() }
        var edits = LinkEdits()
        for record in records.compactMap(\.value) {
            guard let pair = LinkPair(record.first, record.second) else { continue }
            if record.hidden { edits.hidden[pair] = record.date } else { edits.added[pair] = record.date }
        }
        return edits
    }

    public func save(to defaults: some SettingsStorage) {
        guard !isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let records = added.map { Record(first: $0.key.first, second: $0.key.second, hidden: false, date: $0.value) }
            + hidden.map { Record(first: $0.key.first, second: $0.key.second, hidden: true, date: $0.value) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sorted = records.sorted { ($0.first, $0.second, $0.hidden ? 1 : 0) < ($1.first, $1.second, $1.hidden ? 1 : 0) }
        if let data = try? encoder.encode(sorted) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// A value that decodes to nil instead of failing, so one odd record doesn't lose the rest.
private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

// MARK: - The graph

/// Every link, what the sources know with your edits over it, and what a thing is linked to: the things linked to it, and,
/// between a work item and a session, through a pull request linked to both, since a work item's pull requests and their
/// sessions are all its work.
public struct LinkGraph: Sendable {
    /// Something linked to a thing.
    public struct Connection: Equatable, Sendable {
        public var item: ItemRef
        /// Why, the most telling first; empty for one linked only through a pull request.
        public var origins: [LinkOrigin]
        /// The pull request it's linked through, for a work item and a session.
        public var via: ItemRef?
        /// You hid it in BriefBar.
        public var isHidden: Bool

        public init(item: ItemRef, origins: [LinkOrigin], via: ItemRef? = nil, isHidden: Bool = false) {
            self.item = item
            self.origins = origins
            self.via = via
            self.isHidden = isHidden
        }

        /// Whether taking it away only hides it: something other than you links them.
        public var isKnownElsewhere: Bool { origins.contains { $0 != .you } || via != nil }
    }

    private var all: [ItemRef: [ItemRef: Set<LinkOrigin>]] = [:]
    private var hidden: Set<LinkPair> = []

    public init(links: [ItemLink] = [], edits: LinkEdits = LinkEdits()) {
        for link in links {
            add(link.pair, link.origin)
        }
        for pair in edits.added.keys {
            add(pair, .you)
        }
        hidden = Set(edits.hidden.keys)
    }

    private mutating func add(_ pair: LinkPair, _ origin: LinkOrigin) {
        all[pair.first, default: [:]][pair.second, default: []].insert(origin)
        all[pair.second, default: [:]][pair.first, default: []].insert(origin)
    }

    /// Every thing in a link, hidden or not.
    public var items: Set<ItemRef> { Set(all.keys) }

    /// What `ref` is linked to: directly, then through a pull request; then what you hid. In kind order, then by
    /// reference. What's linked only through a link you hid isn't there at all: that link is, as hidden.
    public func connections(of ref: ItemRef) -> [Connection] {
        let direct = all[ref] ?? [:]
        var found: [ItemRef: Connection] = [:]
        for (other, origins) in direct {
            found[other] = Connection(item: other, origins: origins.sorted(), isHidden: isHidden(ref, other))
        }
        if let wanted = Self.throughPullRequests[ref.kind] {
            for pullRequest in direct.keys.sorted() where pullRequest.kind.isPullRequest && !isHidden(ref, pullRequest) {
                for other in (all[pullRequest] ?? [:]).keys.sorted()
                where other.kind == wanted && found[other] == nil && !isHidden(pullRequest, other) {
                    found[other] = Connection(item: other, origins: [], via: pullRequest, isHidden: isHidden(ref, other))
                }
            }
        }
        return found.values.sorted { ($0.isHidden ? 1 : 0, $0.item) < ($1.isHidden ? 1 : 0, $1.item) }
    }

    /// The links that show: not hidden, nor through a link you hid.
    public func visibleConnections(of ref: ItemRef) -> [Connection] {
        connections(of: ref).filter { !$0.isHidden }
    }

    /// Whether two things are linked, directly, and you haven't hidden it.
    public func isLinked(_ lhs: ItemRef, _ rhs: ItemRef) -> Bool {
        guard let pair = LinkPair(lhs, rhs) else { return false }
        return all[lhs]?[rhs] != nil && !hidden.contains(pair)
    }

    /// What links them directly, the most telling first.
    public func origins(_ lhs: ItemRef, _ rhs: ItemRef) -> [LinkOrigin] {
        (all[lhs]?[rhs] ?? []).sorted()
    }

    /// A work item reaches sessions through pull requests, and a session work items.
    private static let throughPullRequests: [ItemRef.Kind: ItemRef.Kind] = [.workItem: .session, .session: .workItem]

    private func isHidden(_ lhs: ItemRef, _ rhs: ItemRef) -> Bool {
        LinkPair(lhs, rhs).map(hidden.contains) ?? false
    }
}

// MARK: - Branches

/// What links a session and a pull request by branch: the branch, the pull request's target, and the repository's
/// names, lowercased, such as `shop-web`, or `octo/shop-web` and `shop-web` on GitHub.
public struct BranchHint: Hashable, Sendable {
    public var branch: String
    public var target: String?
    public var repositories: Set<String>

    public init(branch: String, target: String? = nil, repositories: Set<String>) {
        self.branch = Self.name(branch)
        self.target = target.map(Self.name)
        self.repositories = Set(repositories.map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    /// `users/robin/fix` from `refs/heads/users/robin/fix`.
    static func name(_ ref: String) -> String {
        let trimmed = ref.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("refs/heads/") ? String(trimmed.dropFirst("refs/heads/".count)) : trimmed
    }

    /// The repository's names for a folder or a project, and a GitHub repository, as hints keep them.
    public static func repositories(_ names: [String?], gitHub: String? = nil) -> Set<String> {
        var all = Set(names.compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        if let gitHub, ItemRef.isRepository(gitHub.lowercased()) {
            all.insert(gitHub.lowercased())
            if let name = gitHub.lowercased().split(separator: "/").last { all.insert(String(name)) }
        }
        return all
    }
}

public enum BranchLinks {
    /// Branches too common to say anything: a session on main isn't working on every pull request into it.
    static let shared: Set<String> = ["main", "master", "develop", "development", "dev", "trunk", "head", "release", "staging"]

    /// Whether a session's branch is a pull request's: the same branch, not one everybody works on nor the one it merges
    /// into, in the same repository.
    public static func matches(session: BranchHint, pullRequest: BranchHint) -> Bool {
        let branch = session.branch.lowercased()
        guard !branch.isEmpty, !shared.contains(branch), branch == pullRequest.branch.lowercased(),
              branch != pullRequest.target?.lowercased()
        else { return false }
        return !session.repositories.isDisjoint(with: pullRequest.repositories)
    }

    /// The links between sessions and pull requests on the same branch.
    public static func links(sessions: [ItemRef: BranchHint], pullRequests: [ItemRef: BranchHint]) -> [ItemLink] {
        var byBranch: [String: [(ItemRef, BranchHint)]] = [:]
        for (ref, hint) in pullRequests where ref.kind.isPullRequest {
            byBranch[hint.branch.lowercased(), default: []].append((ref, hint))
        }
        var links: [ItemLink] = []
        for (session, hint) in sessions where session.kind == .session {
            for (pullRequest, prHint) in byBranch[hint.branch.lowercased()] ?? [] where matches(session: hint, pullRequest: prHint) {
                if let link = ItemLink(session, pullRequest, origin: .branch) { links.append(link) }
            }
        }
        return links
    }
}

// MARK: - Pasted links

extension ItemRef {
    /// What a link you paste points to: an Azure DevOps pull request or work item, a GitHub pull request, or a Copilot
    /// session, by its `ghapp://sessions/` link or its ID. Nil for anything else.
    public static func from(link text: String) -> ItemRef? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session = ItemRef.session(trimmed) { return session }
        guard let url = URLComponents(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        let parts = url.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        if scheme == "ghapp" {
            // ghapp://sessions/<id>: the host is "sessions".
            guard url.host?.lowercased() == "sessions", parts.count == 1 else { return nil }
            return ItemRef.session(parts[0])
        }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return nil }
        if host == "github.com" || host == "www.github.com" {
            guard parts.count >= 4, parts[2] == "pull", let number = ItemRef.number(parts[3]) else { return nil }
            let repository = "\(parts[0])/\(parts[1])".lowercased()
            return isRepository(repository) ? .gitHubPullRequest(repository: repository, number: number) : nil
        }
        var organization: String
        var rest = parts[...]
        if host == "dev.azure.com" {
            guard let first = rest.popFirst() else { return nil }
            organization = first
        } else if host.hasSuffix(".visualstudio.com") {
            organization = String(host.dropLast(".visualstudio.com".count))
            if rest.first?.lowercased() == "defaultcollection" { rest.removeFirst() }
        } else {
            return nil
        }
        organization = organization.lowercased()
        guard isOrganization(organization) else { return nil }
        let path = Array(rest)
        if let index = path.firstIndex(where: { $0.lowercased() == "pullrequest" }), index + 1 < path.count,
           path[..<index].contains(where: { $0.lowercased() == "_git" }), let number = number(path[index + 1]) {
            return .pullRequest(organization: organization, number: number)
        }
        if let index = path.firstIndex(where: { $0.lowercased() == "_workitems" }), index + 2 < path.count,
           path[index + 1].lowercased() == "edit", let id = number(path[index + 2]) {
            return .workItem(organization: organization, id: id)
        }
        return nil
    }
}

// MARK: - Suggestions

/// What the picker knows of a thing, to suggest what goes with it.
public struct LinkCandidate: Sendable {
    public var ref: ItemRef
    public var title: String
    public var hint: BranchHint?
    public var date: Date?

    public init(ref: ItemRef, title: String, hint: BranchHint? = nil, date: Date? = nil) {
        self.ref = ref
        self.title = title
        self.hint = hint
        self.date = date
    }
}

public enum LinkSuggestions {
    /// The candidates most likely to go with `subject`, the likeliest first: on its branch, naming its number, sharing
    /// words of its title, in its repository. Only those with more than a repository in common.
    public static func rank(_ candidates: [LinkCandidate], for subject: LinkCandidate, limit: Int = 4) -> [ItemRef] {
        let scored = candidates.compactMap { candidate -> (ItemRef, Int, Date)? in
            guard ItemRef.canLink(candidate.ref, subject.ref) else { return nil }
            let score = self.score(candidate, for: subject)
            return score >= 20 ? (candidate.ref, score, candidate.date ?? .distantPast) : nil
        }
        return scored.sorted { ($0.1, $0.2) > ($1.1, $1.2) }.prefix(limit).map(\.0)
    }

    static func score(_ candidate: LinkCandidate, for subject: LinkCandidate) -> Int {
        var score = 0
        if let mine = subject.hint, let theirs = candidate.hint {
            let (session, pullRequest) = subject.ref.kind == .session ? (mine, theirs) : (theirs, mine)
            if BranchLinks.matches(session: session, pullRequest: pullRequest) { score += 100 }
            if !mine.repositories.isDisjoint(with: theirs.repositories) { score += 10 }
        }
        if mentions(subject, number: candidate.ref.number) || mentions(candidate, number: subject.ref.number) { score += 50 }
        let shared = words(subject.title).intersection(words(candidate.title)).count
        score += min(shared * 10, 40)
        return score
    }

    /// Whether its title or branch names the number, as a word of its own: "Fix 5101", `users/robin/5101-fix`, `wi-5101`.
    static func mentions(_ candidate: LinkCandidate, number: Int?) -> Bool {
        guard let number else { return false }
        let text = [candidate.title, candidate.hint?.branch ?? ""].joined(separator: " ")
        let tokens = text.split { !$0.isNumber }.map(String.init)
        return tokens.contains(String(number))
    }

    /// Words that say what something's about: four letters or more, not the usual ones.
    static func words(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 }
        return Set(words).subtracting(common)
    }

    private static let common: Set<String> = [
        "with", "from", "into", "that", "this", "when", "then", "than", "have", "make", "update", "updates", "change", "changes",
        "fix", "fixes", "add", "adds", "remove", "removes", "work", "item", "task", "pull", "request", "session", "copilot",
    ]
}
