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
            let comments = full ? thread.comments : Array(thread.comments.suffix(1))
            let lines = comments.map { comment in
                let who = comment.author.id == record.me ? "You" : comment.author.name
                return "   \(who): \(comment.text)"
            }
            return entry(index, thread) + "\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// The line a thread's entry in the list starts with: its number, where it is, and which thread. Its comments follow,
    /// each on an indented line of its own (`CommentText.plain` makes a comment one line), so no comment, whatever it says,
    /// makes a line like it: what's handed to Copilot is told by which of these lines are still in the prompt you send
    /// (`CommentHandOff`).
    static func entry(_ index: Int, _ thread: ReviewThread) -> String {
        var place = "General comment"
        if let path = thread.filePath {
            let file = path.hasPrefix("/") ? String(path.dropFirst()) : path
            place = thread.line.map { "\(file), line \($0)" } ?? file
        }
        return "\(index + 1). \(place) (thread \(thread.id))"
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
/// hands to Copilot, as it was when it was written: the comments that waited on you then, by thread, for the account
/// signed in then. Sending it takes those in the entries still in the prompt off that account's Needs You. A comment that
/// came after it was written isn't among them, and neither is one in a thread whose entry isn't in the prompt you send,
/// beyond the most it lists or deleted from it, nor one that waits on you when the task starts but didn't when the prompt
/// was written, such as in a thread reopened since: those still need you.
public struct CommentHandOff: Sendable, Equatable {
    /// An unresolved thread, with its comments that waited on you.
    public struct Waiting: Sendable, Equatable {
        public var thread: Int
        /// The line its entry in the prompt starts with; nil when the prompt doesn't list it.
        public var entry: String?
        /// Those comments, by ID.
        public var comments: [Int]
        public var first: Date
        public var last: Date

        public init(thread: Int, entry: String?, comments: [Int], first: Date, last: Date) {
            self.thread = thread
            self.entry = entry
            self.comments = comments
            self.first = first
            self.last = last
        }
    }

    /// The pull request, as the list names it.
    public var key: PRKey
    public var waiting: [Waiting]
    /// The Azure CLI account whose seen state the prompt was written with (`SeenState.account`), once known: the
    /// comments leave its Needs You, whoever is signed in once the task starts.
    public var account: String?
    /// Your identity ID in the pull request's organization, with that account (`PRRecord.me`).
    public var me: String
    /// What came up to then didn't wait on you anymore when the prompt was written (`SeenState.dismissedCutoff`).
    public var dismissedCutoff: Date

    public init(key: PRKey, waiting: [Waiting], account: String?, me: String, dismissedCutoff: Date) {
        self.key = key
        self.waiting = waiting
        self.account = account
        self.me = me
        self.dismissedCutoff = dismissedCutoff
    }

    /// As the prompt sees `record`, with `account` signed in.
    /// - Parameter dismissedCutoff: what came up to then doesn't wait on you anymore (`SeenState.dismissedCutoff`).
    public init(_ record: PRRecord, dismissedCutoff: Date, account: String?) {
        // The prompts list these, in this order, each under its entry's line.
        let listed = PullRequestPrompt.waitingThreads(record).prefix(PullRequestPrompt.threadLimit)
        let entries = Dictionary(listed.enumerated().map { ($1.id, PullRequestPrompt.entry($0, $1)) }, uniquingKeysWith: { first, _ in first })
        let threads = (record.details?.threads ?? []).filter { !$0.isResolved }
        self.init(key: record.id, waiting: threads.compactMap { thread in
            let comments = PRClassifier.waitingComments(in: thread, me: record.me, dismissedCutoff: dismissedCutoff)
            let times = comments.map(\.publishedAt)
            guard let first = times.min(), let last = times.max() else { return nil }
            return Waiting(thread: thread.id, entry: entries[thread.id], comments: comments.map(\.id), first: first, last: last)
        }, account: account, me: record.me, dismissedCutoff: dismissedCutoff)
    }

    /// Up to when what waits on you leaves Needs You once `prompt` is sent: the last comment that waited on you in the
    /// threads whose entries are still in it, but before the first that still waits on you and isn't handed off, since
    /// a pull request has one cutoff. With the pull request as BriefBar last read it when the task starts (`now`),
    /// that's one that waits on you then that the prompt doesn't have: in a thread whose entry isn't in the prompt, in
    /// one reopened since it was written, or one that came since. A thread answered or resolved meanwhile doesn't wait
    /// on you, and doesn't hold it back. Without it, that's one that waited on you in a thread whose entry isn't in the
    /// prompt, as it was written. A thread's entry is still there while its own line is: a comment in another entry
    /// that names it doesn't count. Nil when none of them is still there.
    public func handedOff(in prompt: String, now: PRRecord? = nil) -> Date? {
        let lines = Set(prompt.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        let kept = waiting.filter { $0.entry.map(lines.contains) ?? false }
        guard let last = kept.map(\.last).max() else { return nil }
        let stays: [Date]
        if let threads = now?.details?.threads {
            let handed = Set(kept.flatMap { thread in thread.comments.map { "\(thread.thread).\($0)" } })
            stays = threads.filter { !$0.isResolved }.flatMap { thread in
                PRClassifier.waitingComments(in: thread, me: me, dismissedCutoff: dismissedCutoff)
                    .filter { !handed.contains("\(thread.id).\($0.id)") }.map(\.publishedAt)
            }
        } else {
            stays = waiting.filter { !kept.contains($0) }.map(\.first)
        }
        guard let first = stays.min() else { return last }
        return min(last, first.addingTimeInterval(-0.001))
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
