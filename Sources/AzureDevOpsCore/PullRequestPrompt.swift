import Foundation

/// A failed build of a pull request, for the prompt that asks Copilot to fix it: where it failed, and its errors, from
/// the run's timeline.
public struct FailedBuildReport: Sendable, Equatable {
    /// The build policy's name, such as `shop-web CI`.
    public var name: String
    public var buildId: Int
    /// The run's page.
    public var url: URL
    public var failure: PipelineFailure?
    /// Its error messages, the first ones, each on one line.
    public var errors: [String]

    public init(name: String, buildId: Int, url: URL, failure: PipelineFailure?, errors: [String]) {
        self.name = name
        self.buildId = buildId
        self.url = url
        self.failure = failure
        self.errors = errors
    }
}

/// The prompts that ask Copilot to work on a pull request: what it is, what to do, and what BriefBar already knows,
/// such as the comments that wait on you, word for word, or where its build failed. Copilot works in a worktree
/// detached at the pull request's latest commit, on its own, or for an agent that asks through `--mcp`, wherever that
/// agent is: each prompt says what it may change, and only Push & Reply pushes or writes on the pull request.
public enum PullRequestPrompt {
    /// The most comment threads, and errors per build, a prompt quotes.
    static let threadLimit = 30
    static let errorLimit = 10

    /// Where Copilot works on the pull request.
    public enum Workplace: Sendable {
        /// The worktree BriefBar makes for the task, detached at the pull request's latest commit.
        case worktree
        /// Wherever the agent that asked for the prompt through `--mcp` works, which may be another branch, with
        /// changes of its own, or not this repository at all.
        case agent

        /// Where the work is, in a sentence's middle.
        var here: String {
            switch self {
            case .worktree: return "this worktree"
            case .agent: return "your checkout"
            }
        }
    }

    /// The threads on your pull request that wait on you: someone else spoke last in them, and they're unresolved. Without
    /// any, every unresolved thread.
    public static func waitingThreads(_ record: PRRecord) -> [ReviewThread] {
        let open = (record.details?.threads ?? []).filter { !$0.isResolved }
        let waiting = open.filter { $0.comments.last?.author.id != record.me }
        return waiting.isEmpty ? open : waiting
    }

    public static func fixComments(_ record: PRRecord, workplace: Workplace = .worktree) -> String {
        let threads = waitingThreads(record)
        return """
            \(header(record, workplace: workplace))

            Address these review comments:

            \(threads.isEmpty ? "(There are no unresolved comment threads right now.)" : list(threads, record: record))

            For each thread, make the change, or say briefly why not. Keep the changes focused. Build, and run the \
            tests that cover what you changed. Don't commit, push or reply on the pull request: end with a short \
            summary for each thread, so I can check your changes before they go out.
            """
    }

    public static func fixBuild(_ record: PRRecord, failures: [FailedBuildReport], workplace: Workplace = .worktree) -> String {
        let builds = failures.enumerated().map { index, report in
            var lines = ["\(index + 1). \(report.name): \(report.url.absoluteString)"]
            if let failure = report.failure {
                lines.append("   Failed" + (failure.stage.map { " in \($0)," } ?? "") + " at \(failure.step).")
            }
            for error in report.errors.prefix(errorLimit) {
                lines.append("   - \(error)")
            }
            return lines.joined(separator: "\n")
        }
        return """
            \(header(record, workplace: workplace))

            \(builds.isEmpty ? "Its build failed, but BriefBar couldn't tell which run." : "Its build failed:\n\n" + builds.joined(separator: "\n\n"))

            Reproduce the failure here: build, and run the failing tests. Read the run's whole log with your Azure DevOps \
            tools if these errors aren't enough. Fix the cause, in the code or the configuration, and build and test \
            again until it passes. If it's the build's infrastructure or a flaky test rather than this change, say so, \
            with the evidence, instead of changing code. Don't queue, retry or change pipelines. Don't commit or push: \
            end with what caused it and what you changed.
            """
    }

    public static func resolveConflicts(_ record: PRRecord, workplace: Workplace = .worktree) -> String {
        let target = record.pullRequest.targetBranch
        return """
            \(header(record, workplace: workplace))

            It has merge conflicts with \(target). Fetch origin/\(target), merge it into \(workplace.here), and resolve the \
            conflicts, keeping what each side meant. Build, and run the tests that cover what conflicted. Don't push: \
            end with what conflicted and how you resolved it.
            """
    }

    public static func review(_ record: PRRecord, workplace: Workplace = .worktree) -> String {
        let pr = record.pullRequest
        let threads = (record.details?.threads ?? []).filter { !$0.isResolved }
        let reviewedAt = lastReview(record)
        let again = reviewedAt.map {
            "\nYou reviewed it before, last on \($0.formatted(date: .abbreviated, time: .omitted)): focus on what changed since.\n"
        } ?? ""
        return """
            \(header(record, workplace: workplace))

            Review it for me. Fetch origin/\(pr.targetBranch), then read what it changes, \
            git diff origin/\(pr.targetBranch)...HEAD, and the code around the changes.
            \(again)
            Its unresolved comment threads, so you don't repeat them:

            \(threads.isEmpty ? "(none)" : list(threads, record: record))

            For each issue, give the file and line, how much it matters (blocking, should fix, or a nit) and the \
            comment I can paste. Then a short verdict, approve, approve with suggestions, or wait for the author, with \
            the main risks. Don't change any file, and don't comment, vote or push.
            """
    }

    public static func pushAndReply(_ record: PRRecord, workplace: Workplace = .worktree) -> String {
        let pr = record.pullRequest
        let source = pr.sourceBranch
        let threads = waitingThreads(record)
        var steps: [String] = []
        let ifRejected: String
        switch workplace {
        case .worktree:
            // BriefBar's own worktree, where a task that changed code for it finished.
            ifRejected = "If that's rejected, rebase on origin/\(source) first, and stop and tell me if that conflicts."
        case .agent:
            // Wherever the agent is, which may be another branch, or hold other work: it checks first, and never rebases.
            steps.append("""
                First make sure it's safe: this must be a clone of \(pr.repositoryName), HEAD must contain origin/\(source) once \
                you've fetched it (git merge-base --is-ancestor origin/\(source) HEAD), and everything you'd commit and push, \
                in git status and git log origin/\(source)..HEAD, must have been made for this pull request. If any of that \
                isn't so, stop and ask me before you commit or push anything.
                """)
            ifRejected = "If that's rejected, stop and tell me: don't rebase, merge or force."
        }
        steps += [
            "Make sure it builds and the tests you ran pass, then commit your changes with a clear message.",
            "Push them to \(source), without force: git push origin HEAD:refs/heads/\(source). \(ifRejected)",
            """
            On the pull request, with your Azure DevOps tools, reply to each comment thread you addressed, saying what \
            you changed, and resolve it. For a thread you didn't change, reply why, and leave it active.
            """,
        ]
        let numbered = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
            Ship what you changed for pull request !\(pr.key.number) “\(pr.title)”, in \(workplace.here):
            \(pr.webURL.absoluteString)

            \(numbered)

            Don't complete, approve or abandon the pull request, and don't change pipelines. End with the commit you \
            pushed and the threads you replied to.

            Its unresolved comment threads:

            \(threads.isEmpty ? "(none)" : list(threads, record: record, full: false))
            """
    }

    // MARK: Parts

    /// What the pull request is, and where Copilot works on it.
    static func header(_ record: PRRecord, workplace: Workplace = .worktree) -> String {
        let pr = record.pullRequest
        let place: String
        switch workplace {
        case .worktree:
            place = """
                You're in a git worktree of this repository, detached at origin/\(pr.sourceBranch), the pull request's latest \
                commit.
                """
        case .agent:
            place = """
                Work on its branch in a clone of \(pr.repositoryName): fetch origin/\(pr.sourceBranch), the pull request's \
                latest commit, and check it out. If you're not in a clone of \(pr.repositoryName), or it has changes of its \
                own, ask me where to work before you change anything.
                """
        }
        return """
            Pull request !\(pr.key.number) “\(pr.title)” in \(pr.repositoryName), from \(pr.sourceBranch) into \(pr.targetBranch):
            \(pr.webURL.absoluteString)

            \(place)
            """
    }

    /// The threads, numbered: where each is, and its comments, each person's on a line of its own.
    public static func list(_ threads: [ReviewThread], record: PRRecord, full: Bool = true) -> String {
        threads.prefix(threadLimit).enumerated().map { index, thread in
            var place = "General comment"
            if let path = thread.filePath {
                let file = path.hasPrefix("/") ? String(path.dropFirst()) : path
                place = thread.line.map { "\(file), line \($0)" } ?? file
            }
            let comments = full ? thread.comments : Array(thread.comments.suffix(1))
            let lines = comments.map { comment in
                let who = comment.author.id == record.me ? "You" : comment.author.name
                return "   \(who): \(comment.text)"
            }
            return "\(index + 1). \(place) \(marker(thread: thread.id))\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// How a prompt names a comment thread: what's handed to Copilot is told by what's still in the prompt you send
    /// (`CommentHandOff`).
    static func marker(thread id: Int) -> String {
        "(thread \(id))"
    }

    /// When you last voted or commented on it.
    static func lastReview(_ record: PRRecord) -> Date? {
        guard let details = record.details else { return nil }
        let votes = details.activity.filter { $0.kind == .vote && $0.actor?.id == record.me }.map(\.at)
        let comments = details.threads.flatMap(\.comments).filter { $0.author.id == record.me }.map(\.publishedAt)
        return (votes + comments).max()
    }
}

/// What a prompt that takes care of the comments that wait on you on your pull request, Fix Comments' or Push & Reply's,
/// hands to Copilot, as it was when it was written: the comments that waited on you then, by thread. Sending it takes those
/// in the threads it still quotes off Needs You. A comment that came after it was written isn't among them, and neither is
/// one in a thread the prompt doesn't quote, beyond the most it quotes or taken out of it before you sent it: those still
/// need you.
public struct CommentHandOff: Sendable, Equatable {
    /// An unresolved thread, with the first and the last of its comments that waited on you.
    public struct Waiting: Sendable, Equatable {
        public var thread: Int
        public var first: Date
        public var last: Date

        public init(thread: Int, first: Date, last: Date) {
            self.thread = thread
            self.first = first
            self.last = last
        }
    }

    /// The pull request, as the list names it.
    public var key: PRKey
    public var waiting: [Waiting]

    public init(key: PRKey, waiting: [Waiting]) {
        self.key = key
        self.waiting = waiting
    }

    /// As the prompt sees `record`.
    /// - Parameter dismissedCutoff: what came up to then doesn't wait on you anymore (`SeenState.dismissedCutoff`).
    public init(_ record: PRRecord, dismissedCutoff: Date) {
        let threads = (record.details?.threads ?? []).filter { !$0.isResolved }
        self.init(key: record.id, waiting: threads.compactMap { thread in
            let times = PRClassifier.waitingComments(in: thread, me: record.me, dismissedCutoff: dismissedCutoff).map(\.publishedAt)
            guard let first = times.min(), let last = times.max() else { return nil }
            return Waiting(thread: thread.id, first: first, last: last)
        })
    }

    /// Up to when what waits on you leaves Needs You once `prompt` is sent: the last comment that waited on you in the
    /// threads it quotes, but before the first in one it doesn't, since a pull request has one cutoff. Nil when it quotes
    /// none of them.
    public func handedOff(in prompt: String) -> Date? {
        let quoted = Set(waiting.map(\.thread).filter { prompt.contains(PullRequestPrompt.marker(thread: $0)) })
        guard let last = waiting.filter({ quoted.contains($0.thread) }).map(\.last).max() else { return nil }
        guard let kept = waiting.filter({ !quoted.contains($0.thread) }).map(\.first).min() else { return last }
        return min(last, kept.addingTimeInterval(-0.001))
    }
}

extension PipelineFailure {
    /// Every error in a run's timeline, in order, once each, at most `limit`: for the prompt that asks Copilot to fix it.
    public static func errors(in timeline: ADOTimeline, limit: Int = 10) -> [String] {
        var seen: Set<String> = []
        var errors: [String] = []
        let records = timeline.records.elements
            .filter { $0.result == "failed" || $0.issues?.elements.contains { $0.type == "error" } == true }
            .sorted { ($0.finishTime ?? .distantFuture, $0.order ?? .max) < ($1.finishTime ?? .distantFuture, $1.order ?? .max) }
        for record in records {
            for issue in record.issues?.elements ?? [] where issue.type == "error" {
                guard let message = issue.message.map(clean), !message.isEmpty, seen.insert(message).inserted else { continue }
                errors.append(message)
                if errors.count == limit { return errors }
            }
        }
        return errors
    }
}
