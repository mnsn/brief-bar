import BriefBarCore
import Foundation

/// What a pull request adds to a summary of it beyond its story, read only as a summary is written: what its
/// description says, and how its comment threads go, in plain text, cut to fit. Nothing of it is kept.
public enum PullRequestContext {
    /// The parts' labels.
    public static let descriptionLabel = "Description"
    public static let threadsLabel = "Comment threads"
    /// How long each part is, at most.
    public static let descriptionLimit = 3_000
    public static let threadsLimit = 3_000

    // MARK: Reading

    /// Reads what it adds from Azure DevOps, with GETs: the pull request, for its description, then its comment threads,
    /// where it says it is, unless they're given, as your pull requests' are. A read that fails leaves its part out; once
    /// Azure DevOps asks to slow down, or the task that reads is cancelled, nothing more is read.
    /// - Parameters:
    ///   - pullRequest: as it was last read: where it is, should reading it again fail, and who's on it.
    ///   - threads: its comment threads, when they were read already.
    ///   - me: your identity ID in its organization, to say "you".
    public static func read(
        _ pullRequest: PullRequest, threads given: [ReviewThread]? = nil, me: String? = nil, client: ADOClient
    ) async -> [ItemStory.Fact] {
        let key = pullRequest.key
        var current = pullRequest
        var description: String?
        var stopped = Task.isCancelled
        if !stopped {
            do {
                let address = ADOEndpoint.pullRequest(organization: key.organization, id: key.number)
                let dto = try await client.get(address, as: ADOPullRequest.self)
                current = PullRequest(organization: key.organization, dto)
                description = dto.description
            } catch {
                stopped = stops(error)
            }
        }
        var threads = given
        if threads == nil, !stopped, !Task.isCancelled {
            let address = ADOEndpoint.threads(
                organization: key.organization, projectId: current.projectId, repositoryId: current.repositoryId, pullRequestId: key.number
            )
            // Left out when they can't be read.
            threads = (try? await client.get(address, as: ADOList<ADOThread>.self)).map { conversations($0.value, on: current) }
        }
        return parts(of: current, description: description, threads: threads, me: me)
    }

    /// Whether reading stops: Azure DevOps asked to slow down, or the task that reads was cancelled.
    private static func stops(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if case .throttled = error as? ADOError { return true }
        return false
    }

    /// The conversations among a pull request's threads, as its details have them: not the system threads that record
    /// what happened on it, such as votes, nor those deleted.
    static func conversations(_ threads: [ADOThread], on pullRequest: PullRequest) -> [ReviewThread] {
        let names = names(on: pullRequest)
        return threads.compactMap { thread in
            guard thread.isDeleted != true, thread.activityType == nil else { return nil }
            return ReviewThread(thread, names: names)
        }
    }

    /// Who's on it, by ID, for the people a text mentions.
    private static func names(on pullRequest: PullRequest) -> [String: String] {
        var names: [String: String] = [:]
        for reviewer in pullRequest.reviewers { names[reviewer.person.id] = reviewer.person.name }
        names[pullRequest.author.id] = pullRequest.author.name
        return names
    }

    // MARK: The parts

    /// The parts, from what's known of it, each when it's known: its description, as Azure DevOps keeps it, in Markdown, and
    /// its comment threads.
    /// - Parameter me: your identity ID in its organization, to say "you".
    public static func parts(
        of pullRequest: PullRequest, description: String?, threads: [ReviewThread]?, me: String? = nil
    ) -> [ItemStory.Fact] {
        var parts: [ItemStory.Fact] = []
        if let described = description.flatMap({ Self.description($0, names: names(on: pullRequest)) }) {
            parts.append(ItemStory.Fact(descriptionLabel, described))
        }
        if let threads { parts.append(ItemStory.Fact(threadsLabel, digest(threads, me: me))) }
        return parts
    }

    /// A description in plain text, with its paragraphs and lists, the people it mentions by name, and without what its
    /// template asks of its author in HTML comments; cut to `limit` characters. Nil when it says nothing.
    public static func description(_ markdown: String, names: [String: String] = [:], limit: Int = descriptionLimit) -> String? {
        let text = CommentText.naming(markdown, names: names).replacing(/(?s)<!--.*?(?:-->|\z)/, with: "")
        let plain = StoryText.paragraph(RichText(markdown: text).plainText, limit: limit)
        return plain.isEmpty ? nil : plain
    }

    /// How its comment threads go: how many aren't resolved, then each of them on a line, the open ones first, the newest
    /// first, with who started it and where, what they said and the latest reply; then how many are resolved, with the
    /// latest in brief. "No comments." without any. Cut to about `limit` characters: when all of them don't fit, each says
    /// less, and then the last ones are left out.
    /// - Parameter me: your identity ID, to say "you".
    public static func digest(_ threads: [ReviewThread], me: String? = nil, limit: Int = threadsLimit) -> String {
        guard !threads.isEmpty else { return "No comments." }
        let newestFirst = threads.sorted { (latest($0), $0.id) > (latest($1), $1.id) }
        let unresolved = newestFirst.filter(isOpen) + newestFirst.filter { !isOpen($0) && !$0.isResolved }
        let header = unresolved.isEmpty ? "Unresolved: none" : "Unresolved (\(unresolved.count)):"
        let footer = resolution(of: newestFirst.filter(\.isResolved), me: me)
        let room = limit - header.count - footer.count - 2
        var entries = unresolved.map { entry($0, me: me, said: 400, reply: 300) }
        if entries.reduce(0, { $0 + $1.count + 1 }) > room {
            entries = unresolved.map { entry($0, me: me, said: 160, reply: 120) }
        }
        var lines = [header]
        var used = 0
        for (index, entry) in entries.enumerated() {
            let left = entries.count - index - 1
            // With room to say how many more there are.
            guard used + entry.count + 1 + (left > 0 ? 16 : 0) <= room else {
                lines.append("(\(left + 1) more)")
                break
            }
            lines.append(entry)
            used += entry.count + 1
        }
        lines.append(footer)
        return StoryText.paragraph(lines.joined(separator: "\n"), limit: limit)
    }

    /// "Sam Rivera on src/Cart.swift:42: Round half up? — Priya Shah: Done.": who started a thread and where, what they
    /// said, and the latest reply, each cut to its length.
    static func entry(_ thread: ReviewThread, me: String?, said: Int, reply: Int) -> String {
        var line = "\(opening(thread, me: me)): \(StoryText.line(thread.comments.first?.text ?? "", limit: said))"
        if thread.comments.count > 1, let last = thread.comments.last {
            line += " — \(who(last.author, me: me)): \(StoryText.line(last.text, limit: reply))"
        }
        return line
    }

    /// "Resolved (3), the latest: Sam Rivera on src/Cart.swift:42: Round half up? (fixed); …": how many are resolved, and
    /// the latest two, in brief.
    static func resolution(of resolved: [ReviewThread], me: String?) -> String {
        guard !resolved.isEmpty else { return "Resolved: none" }
        let latest = resolved.prefix(2).map { thread in
            "\(opening(thread, me: me)): \(StoryText.line(thread.comments.first?.text ?? "", limit: 100)) (\(outcome(thread.status)))"
        }
        let count = resolved.count > latest.count ? "Resolved (\(resolved.count)), the latest" : "Resolved (\(resolved.count))"
        return "\(count): \(latest.joined(separator: "; "))"
    }

    /// "Sam Rivera on src/Cart.swift:42", or "Sam Rivera" for a general thread: who started it, and where.
    static func opening(_ thread: ReviewThread, me: String?) -> String {
        let author = thread.comments.first.map { who($0.author, me: me) } ?? "Someone"
        return place(thread).map { "\(author) on \($0)" } ?? author
    }

    /// "src/Cart.swift:42": the file a thread is on, from the repository's root, or only its name when that's long, and the
    /// line. Nil for a general thread.
    static func place(_ thread: ReviewThread) -> String? {
        guard var path = thread.filePath, !path.isEmpty else { return nil }
        if path.hasPrefix("/") { path.removeFirst() }
        if path.count > 100, let name = thread.fileName { path = name }
        guard !path.isEmpty else { return nil }
        return thread.line.map { "\(path):\($0)" } ?? path
    }

    /// A person by name, or "You".
    private static func who(_ person: Person, me: String?) -> String {
        PullRequestStory.isMe(person, me) ? "You" : StoryText.line(person.name, limit: 60)
    }

    /// Active or pending: waiting on someone.
    private static func isOpen(_ thread: ReviewThread) -> Bool {
        thread.status == "active" || thread.status == "pending"
    }

    /// When someone last said something in it.
    private static func latest(_ thread: ReviewThread) -> Date {
        thread.comments.map(\.publishedAt).max() ?? .distantPast
    }

    /// How a thread was resolved: "fixed", "won't fix", "closed" or "by design".
    private static func outcome(_ status: String?) -> String {
        switch status {
        case "fixed": return "fixed"
        case "wontFix": return "won't fix"
        case "byDesign": return "by design"
        case "closed": return "closed"
        default: return status ?? "resolved"
        }
    }
}
