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
/// detached at the pull request's latest commit, on its own: each prompt says what it may change, and only Push & Reply
/// pushes or writes on the pull request.
public enum PullRequestPrompt {
    /// The most comment threads, and errors per build, a prompt quotes.
    static let threadLimit = 30
    static let errorLimit = 10

    /// The threads on your pull request that wait on you: someone else spoke last in them, and they're unresolved. Without
    /// any, every unresolved thread.
    public static func waitingThreads(_ record: PRRecord) -> [ReviewThread] {
        let open = (record.details?.threads ?? []).filter { !$0.isResolved }
        let waiting = open.filter { $0.comments.last?.author.id != record.me }
        return waiting.isEmpty ? open : waiting
    }

    public static func fixComments(_ record: PRRecord) -> String {
        let threads = waitingThreads(record)
        return """
            \(header(record))

            Address these review comments:

            \(threads.isEmpty ? "(There are no unresolved comment threads right now.)" : list(threads, record: record))

            For each thread, make the change, or say briefly why not. Keep the changes focused. Build, and run the \
            tests that cover what you changed. Don't commit, push or reply on the pull request: end with a short \
            summary for each thread, so I can check your changes before they go out.
            """
    }

    public static func fixBuild(_ record: PRRecord, failures: [FailedBuildReport]) -> String {
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
            \(header(record))

            \(builds.isEmpty ? "Its build failed, but BriefBar couldn't tell which run." : "Its build failed:\n\n" + builds.joined(separator: "\n\n"))

            Reproduce the failure here: build, and run the failing tests. Read the run's whole log with your Azure DevOps \
            tools if these errors aren't enough. Fix the cause, in the code or the configuration, and build and test \
            again until it passes. If it's the build's infrastructure or a flaky test rather than this change, say so, \
            with the evidence, instead of changing code. Don't queue, retry or change pipelines. Don't commit or push: \
            end with what caused it and what you changed.
            """
    }

    public static func resolveConflicts(_ record: PRRecord) -> String {
        let target = record.pullRequest.targetBranch
        return """
            \(header(record))

            It has merge conflicts with \(target). Fetch origin/\(target), merge it into this worktree, and resolve the \
            conflicts, keeping what each side meant. Build, and run the tests that cover what conflicted. Don't push: \
            end with what conflicted and how you resolved it.
            """
    }

    public static func review(_ record: PRRecord) -> String {
        let pr = record.pullRequest
        let threads = (record.details?.threads ?? []).filter { !$0.isResolved }
        let reviewedAt = lastReview(record)
        let again = reviewedAt.map {
            "\nYou reviewed it before, last on \($0.formatted(date: .abbreviated, time: .omitted)): focus on what changed since.\n"
        } ?? ""
        return """
            \(header(record))

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

    public static func pushAndReply(_ record: PRRecord) -> String {
        let pr = record.pullRequest
        let threads = waitingThreads(record)
        return """
            Ship what you changed for pull request !\(pr.key.number) “\(pr.title)”, in this worktree:
            \(pr.webURL.absoluteString)

            1. Make sure it builds and the tests you ran pass, then commit your changes with a clear message.
            2. Push them to \(pr.sourceBranch), without force: git push origin HEAD:refs/heads/\(pr.sourceBranch). If \
            that's rejected, rebase on origin/\(pr.sourceBranch) first, and stop and tell me if that conflicts.
            3. On the pull request, with your Azure DevOps tools, reply to each comment thread you addressed, saying what \
            you changed, and resolve it. For a thread you didn't change, reply why, and leave it active.

            Don't complete, approve or abandon the pull request, and don't change pipelines. End with the commit you \
            pushed and the threads you replied to.

            Its unresolved comment threads:

            \(threads.isEmpty ? "(none)" : list(threads, record: record, full: false))
            """
    }

    // MARK: Parts

    /// What the pull request is, and where Copilot works on it.
    static func header(_ record: PRRecord) -> String {
        let pr = record.pullRequest
        return """
            Pull request !\(pr.key.number) “\(pr.title)” in \(pr.repositoryName), from \(pr.sourceBranch) into \(pr.targetBranch):
            \(pr.webURL.absoluteString)

            You're in a git worktree of this repository, detached at origin/\(pr.sourceBranch), the pull request's latest \
            commit.
            """
    }

    /// The threads, numbered: where each is, and its comments, each person's on a line of its own.
    static func list(_ threads: [ReviewThread], record: PRRecord, full: Bool = true) -> String {
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
            return "\(index + 1). \(place) (thread \(thread.id))\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// When you last voted or commented on it.
    static func lastReview(_ record: PRRecord) -> Date? {
        guard let details = record.details else { return nil }
        let votes = details.activity.filter { $0.kind == .vote && $0.actor?.id == record.me }.map(\.at)
        let comments = details.threads.flatMap(\.comments).filter { $0.author.id == record.me }.map(\.publishedAt)
        return (votes + comments).max()
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
