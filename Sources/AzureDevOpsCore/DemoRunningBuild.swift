import Foundation

/// A made-up investigation of the demo's build that's still running, for `--demo` and the screenshots. Times are relative
/// to `now`.
extension DemoData {
    /// The run of `!4099`'s infra CI, which is still going.
    static let runningBuildId = 204_431

    /// What the demo's builds show when you open them in a pull request's details: the failed one
    /// (`buildInvestigation(buildId:of:now:)`), or the one still running. Nil for another build, or a pull request that
    /// isn't the demo's.
    public static func investigation(buildId: Int, of pullRequest: PullRequest, now: Date = Date()) -> BuildInvestigation? {
        buildInvestigation(buildId: buildId, of: pullRequest, now: now) ?? runningBuildInvestigation(buildId: buildId, of: pullRequest, now: now)
    }

    /// `!4099`'s infra CI, six minutes in: it built, and runs its integration tests; publishing waits for them.
    static func runningBuildInvestigation(buildId: Int, of pullRequest: PullRequest, now: Date) -> BuildInvestigation? {
        guard buildId == runningBuildId, pullRequest.key == PRKey(organization, 4099),
              let pipeline = morePipelines.first(where: { $0.name == "infra CI" })
        else { return nil }
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let dayFormat = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)", timeZone: .current, calendar: Calendar(identifier: .gregorian)
        )
        let run = PipelineRun(
            id: buildId, organization: organization, projectName: pullRequest.projectName, number: "\(ago(6).formatted(dayFormat)).6",
            status: .running, trigger: .pullRequest, branch: "!\(pullRequest.key.number)", requestedFor: me.name, queuedAt: ago(6.5),
            startedAt: ago(6)
        )
        let checkout = "Checkout \(pullRequest.repositoryName)@\(pullRequest.sourceBranch) to s"
        /// Tasks one after the other from `start`, each `(name, seconds, state)`: one running has no end, and one pending
        /// no start.
        func tasks(_ job: String, from start: Date, _ list: [(String, Double, PipelineStage.State)]) -> [BuildStep] {
            var at = start
            return list.enumerated().map { index, task in
                let (name, seconds, state) = task
                let started = state == .pending ? nil : at
                if state == .succeeded { at = at.addingTimeInterval(seconds) }
                return BuildStep(
                    id: "\(job)-task-\(index + 1)", kind: .task, name: name, state: state, startedAt: started,
                    finishedAt: state == .succeeded ? at : nil, logId: started == nil ? nil : 20 + index
                )
            }
        }
        let built = tasks("build", from: ago(6), [
            ("Initialize job", 3, .succeeded), (checkout, 5, .succeeded), ("Use .NET SDK 8.0.x", 9, .succeeded), ("Restore", 28, .succeeded),
            ("Build", 84, .succeeded), ("Post-job: Checkout", 1, .succeeded), ("Finalize Job", 1, .succeeded),
        ])
        let testing = tasks("test", from: ago(3.6), [
            ("Initialize job", 3, .succeeded), (checkout, 5, .succeeded), ("Start the test database", 28, .succeeded),
            ("Run integration tests", 0, .running), ("Publish test results", 0, .pending), ("Post-job: Checkout", 0, .pending),
            ("Finalize Job", 0, .pending),
        ])
        func job(_ id: String, _ name: String, _ state: PipelineStage.State, _ tasks: [BuildStep]) -> BuildStep {
            BuildStep(
                id: "\(id)-job", kind: .job, name: name, state: state, startedAt: tasks.first?.startedAt,
                finishedAt: state == .succeeded ? tasks.last?.finishedAt : nil, steps: tasks
            )
        }
        func stage(_ id: String, _ name: String, _ state: PipelineStage.State, _ jobs: [BuildStep]) -> BuildStep {
            BuildStep(
                id: "\(id)-stage", kind: .stage, name: name, state: state, startedAt: jobs.first?.startedAt,
                finishedAt: state == .succeeded ? jobs.last?.finishedAt : nil, steps: jobs
            )
        }
        return BuildInvestigation(
            pipeline: pipeline, run: run,
            steps: [
                stage("build", "Build", .succeeded, [job("build", "Build", .succeeded, built)]),
                stage("test", "Test", .running, [job("test", "Integration tests", .running, testing)]),
                stage("publish", "Publish", .pending, [job("publish", "Publish packages", .pending, [])]),
            ],
            comparison: BuildComparison(revision: .current, targetBranch: pullRequest.targetBranch),
            readAt: now
        )
    }
}
