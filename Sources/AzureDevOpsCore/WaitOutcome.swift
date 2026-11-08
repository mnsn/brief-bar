import Foundation

/// What ends `BriefBar --wait` on one of your pull requests: what happened on it since the wait began, from two reads of it,
/// each with its details. A build counts only once it has run since then, so one that had failed already ends nothing until
/// it runs again; and only the builds that block it, as only those hold up its merge. Comments count as Needs You counts
/// them: someone else's, not a bot's, in a thread still open, after your last word there, that wasn't there when the wait
/// began. Merge conflicts count whenever it has them, since no build runs until they're resolved.
public enum WaitOutcome: Sendable, Equatable {
    /// Builds that ran since the wait began and failed: it ends as soon as one does, even while others still run.
    case buildFailed([Check])
    /// It has merge conflicts with its target branch.
    case conflicts
    /// Open threads with a comment that waits on you, as Needs You counts it, that wasn't there when the wait began.
    case comments([ReviewThread])
    /// The builds that ran since the wait began, once every build that blocks it has passed: none still to run, nor to run
    /// again.
    case buildPassed([Check])

    /// What happened on it between `baseline`, the first read of it with its details, and `current`, a later one: a failed
    /// build first, then its conflicts, then its comments, then its builds that passed; nothing yet, while none of them did.
    public static func since(_ baseline: PRRecord, in current: PRRecord) -> [WaitOutcome] {
        var outcomes: [WaitOutcome] = []
        let before = builds(of: baseline)
        let now = builds(of: current)
        let finished = now.filter { hasFinished($0, since: before) }
        let failed = finished.filter { $0.state == .failed }
        if !failed.isEmpty { outcomes.append(.buildFailed(failed)) }
        if current.pullRequest.hasConflicts { outcomes.append(.conflicts) }
        let threads = comments(in: current, since: baseline)
        if !threads.isEmpty { outcomes.append(.comments(threads)) }
        // One that failed before the wait began, expired or never ran still holds it up, though nothing runs it.
        if failed.isEmpty, !finished.isEmpty, now.allSatisfy({ $0.state == .passed || $0.state == .notApplicable }) {
            outcomes.append(.buildPassed(finished))
        }
        return outcomes
    }

    /// Its builds that block it: what its merge waits for.
    public static func builds(of record: PRRecord) -> [Check] {
        (record.details?.checks ?? []).filter { $0.kind == .build && $0.isBlocking }
    }

    /// Whether a build has a result it didn't have when the wait began: it was still to run then, or it ran again since,
    /// as another run or the same one retried, which keeps its ID but finishes later.
    static func hasFinished(_ build: Check, since baseline: [Check]) -> Bool {
        guard build.state == .passed || build.state == .failed else { return false }
        guard let before = baseline.first(where: { isSamePolicy($0, build) }) else { return true }
        guard before.state == .passed || before.state == .failed else { return true }
        if build.buildId != before.buildId { return true }
        if let finished = build.completedAt, let earlier = before.completedAt, finished > earlier { return true }
        return false
    }

    /// The same build policy in two reads: by its policy, as Azure DevOps names it, since two policies may run one pipeline
    /// under one name; or else, when it doesn't say, by its pipeline, or else by its name.
    static func isSamePolicy(_ one: Check, _ other: Check) -> Bool {
        if let policy = one.policyId, let otherPolicy = other.policyId { return policy == otherPolicy }
        if let pipeline = one.definitionId, let otherPipeline = other.definitionId { return pipeline == otherPipeline }
        return one.name == other.name
    }

    /// Its open threads with a comment that waits on you and wasn't there when the wait began: someone else's, not a bot's,
    /// after your last word there (`PRClassifier.waitingComments`), so a bot's note during a build, or a reply you've
    /// answered, ends nothing. Matched by their IDs, and their comments' IDs, so an edit to a comment isn't news.
    static func comments(in current: PRRecord, since baseline: PRRecord) -> [ReviewThread] {
        let before = Dictionary(
            (baseline.details?.threads ?? []).map { ($0.id, Set($0.comments.map(\.id))) }, uniquingKeysWith: { first, _ in first }
        )
        return (current.details?.threads ?? []).filter { thread in
            guard !thread.isResolved else { return false }
            let known = before[thread.id] ?? []
            return PRClassifier.waitingComments(in: thread, me: current.me, dismissedCutoff: .distantPast)
                .contains { !known.contains($0.id) }
        }
    }

    /// Its builds that are still queued or running, which a wait that ends with nothing waits on.
    public static func running(in record: PRRecord) -> [Check] {
        builds(of: record).filter { $0.state == .queued || $0.state == .running }
    }

    /// Its builds that hold it up though nothing runs them: one that failed before the wait began, expired or never ran, until
    /// someone queues it again.
    public static func stalled(in record: PRRecord) -> [Check] {
        builds(of: record).filter { ![.passed, .notApplicable, .queued, .running].contains($0.state) }
    }
}

extension PulseEngine.Configuration {
    /// For `--wait`'s one pull request, read by its link, at its caller's pace: at each refresh, the pull request and its
    /// details, however soon after the last, rather than when they're due, so its last read, cut short by its timeout,
    /// still sees what changed; and one that couldn't be read, at the next. No organization's lists, nothing after a merge.
    /// - Parameter interval: how often it's refreshed, for what else waits that long, such as a failed build's timeline
    ///   that couldn't be read.
    public static func waiting(interval: TimeInterval) -> Self {
        Self(
            organizations: [], interval: interval, inactiveAfter: nil,
            planner: RefreshPlanner.Options(busyInterval: 0, activeInterval: 0, quietInterval: 0, budget: 1),
            concurrency: 1, followMerges: false, retryLinkedAfter: 0
        )
    }
}
