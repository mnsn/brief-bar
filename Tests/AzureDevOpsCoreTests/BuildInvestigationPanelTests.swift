import BriefBarCore
import Foundation
import Testing
@testable import AzureDevOpsCore

/// What a pull request's details show of a build they look into: which builds open, where one failed or what it's doing,
/// whether it's the change's doing, how its tests went, what its errors and log's end say, and what couldn't be read.
@Suite struct BuildInvestigationPanelTests {
    private typealias F = InvestigationFixture

    private func panel(_ checks: [Check]) throws -> PullRequestPanel {
        let pr = makePR()
        let record = PRRecord(
            pullRequest: pr, role: .author, details: makeDetails(for: pr, checks: checks, lastActivity: t(-hour)), me: People.me.id
        )
        let row = try #require(PRClassifier.snapshot(for: record, seenCutoff: t(-3 * day), dismissedCutoff: t(-3 * day), now: t(0)))
        return PullRequestPanel(row, record: record)
    }

    /// A run with these steps, which failed at `failedStepId`, or is `status`.
    private func investigation(
        _ steps: [BuildStep], failedStepId: String? = nil, failure: PipelineFailure? = nil, status: PipelineRun.Status = .failed,
        unread: [BuildInvestigation.Part: ADOError] = [:]
    ) -> BuildInvestigation {
        BuildInvestigation(
            pipeline: F.pipeline, run: F.run(status: status), steps: steps, failure: failure, failedStepId: failedStepId,
            comparison: BuildComparison(revision: .current, targetBranch: "main"), unread: unread, readAt: t(0)
        )
    }

    private func step(
        _ id: String, _ kind: BuildStep.Kind, _ name: String, _ state: PipelineStage.State = .succeeded, _ steps: [BuildStep] = []
    ) -> BuildStep {
        BuildStep(id: id, kind: kind, name: name, state: state, startedAt: t(-hour), finishedAt: state == .running ? nil : t(-50 * minute),
                  steps: steps)
    }

    // MARK: Which builds open

    @Test func onlyThePullRequestsBuildsThatFailedOrAreGoingOpen() throws {
        let panel = try panel([
            Check(name: "failed", kind: .build, state: .failed, buildId: 1),
            Check(name: "running", kind: .build, state: .running, buildId: 2),
            Check(name: "queued", kind: .build, state: .queued, buildId: 3),
            Check(name: "optional", kind: .build, state: .failed, isBlocking: false, buildId: 4),
            Check(name: "passed", kind: .build, state: .passed, buildId: 5),
            Check(name: "expired", kind: .build, state: .expired, buildId: 6),
            Check(name: "without a run", kind: .build, state: .failed),
            Check(name: "status", kind: .status, state: .failed),
            Check(name: "not run", kind: .build, state: .notRun),
        ])
        let open = Dictionary(uniqueKeysWithValues: panel.checks.map { ($0.run.name, $0.canInvestigate) })
        #expect(open == [
            "failed": true, "running": true, "queued": true, "optional": true, "passed": false, "expired": false,
            "without a run": false, "status": false, "not run": false,
        ])

        // The pipelines after a merge built the target branch, not the pull request.
        let pr = makePR(status: .completed, closed: t(-hour))
        var merged = PRRecord(pullRequest: pr, role: .author, details: nil, me: People.me.id)
        merged.merge = MergePipelines(
            pullRequest: pr.key, title: pr.title, targetBranch: "main", mergedAt: t(-hour), url: pr.webURL,
            pipelines: [PipelineStatus(
                pipeline: PipelineRef(organization: "contoso", projectId: "p1", projectName: "Shop", definitionId: 9, name: "shop-web CD"),
                runs: [PipelineRun(id: 77, organization: "contoso", projectName: "Shop", number: "1", status: .failed, trigger: .push,
                                   branch: "main", queuedAt: t(-50 * minute), startedAt: t(-49 * minute), finishedAt: t(-40 * minute))]
            )],
            isFollowing: true
        )
        let row = try #require(PRClassifier.snapshot(for: merged, seenCutoff: t(-3 * day), dismissedCutoff: t(-3 * day), now: t(0)))
        let afterMerge = PullRequestPanel(row, record: merged)
        #expect(afterMerge.checks.map(\.buildId) == [77])
        #expect(afterMerge.checks.allSatisfy { !$0.canInvestigate })
    }

    // MARK: Where it failed, and what it's doing

    @Test func itSaysWhereItFailedFromItsStageToItsTask() {
        let steps = [
            step("s1", .stage, "Build", .succeeded, [step("j1", .job, "Build", .succeeded, [step("t1", .task, "Compile")])]),
            step("s2", .stage, "Test", .failed, [step("j2", .job, "Unit tests", .failed, [step("t2", .task, "Run unit tests", .failed)])]),
            step("s3", .stage, "Publish", .skipped),
        ]
        let failed = investigation(steps, failedStepId: "t2")
        #expect(failed.failurePlace == ["Test", "Unit tests", "Run unit tests"])
        #expect(failed.stages.map(\.name) == ["Build", "Test", "Publish"])
        #expect(failed.stages.map(\.state) == [.succeeded, .failed, .skipped])
        #expect(failed.stages.map(\.id) == ["s1", "s2", "s3"])
        #expect(failed.stages.first?.startedAt == t(-hour))
        // A stage's only job, of the same name, isn't said twice.
        #expect(investigation(steps, failedStepId: "t1").failurePlace == ["Build", "Compile"])
        // Without its steps, as its checks said it.
        let said = PipelineFailure(stage: "Test", step: "Run unit tests", message: "2 tests failed.")
        #expect(investigation([], failedStepId: "gone", failure: said).failurePlace == ["Test", "Run unit tests"])
        #expect(investigation([], failure: PipelineFailure(stage: nil, step: "Build", message: nil)).failurePlace == ["Build"])
        #expect(investigation(steps).failurePlace.isEmpty)
        // A run that failed has nothing going on.
        #expect(failed.progress == nil)
    }

    @Test func aRunThatsGoingSaysWhatItsDoing() {
        let running = [
            step("s1", .stage, "Build", .succeeded),
            step("s2", .stage, "Test", .running, [
                step("j1", .job, "Lint", .succeeded),
                step("j2", .job, "Integration tests", .running, [
                    step("t1", .task, "Start the database"), step("t2", .task, "Run integration tests", .running),
                    step("t3", .task, "Publish test results", .pending),
                ]),
            ]),
            step("s3", .stage, "Publish", .pending),
        ]
        let progress = investigation(running, status: .running).progress
        #expect(progress == .running(["Test", "Integration tests", "Run integration tests"]))
        #expect(progress?.sentence == "Running Test › Integration tests › Run integration tests")
        // Between two steps.
        let between = investigation([step("s1", .stage, "Build", .succeeded), step("s2", .stage, "Test", .pending)], status: .running)
        #expect(between.progress == .running([]))
        #expect(between.progress?.sentence == "Running")
        // A stage that waits for an approval.
        let waiting = investigation([step("s1", .stage, "Build"), step("s2", .stage, "Production", .waiting)], status: .running)
        #expect(waiting.progress == .waiting("Production"))
        #expect(waiting.progress?.sentence == "Waiting for approval to Production")
        // In the queue.
        #expect(investigation([], status: .queued).progress == .queued)
        #expect(BuildInvestigation.Progress.queued.sentence == "Queued: it hasn't started")
        // Once it's done, nothing.
        for status: PipelineRun.Status in [.succeeded, .partiallySucceeded, .failed, .canceled] {
            #expect(investigation(running, status: status).progress == nil)
        }
    }

    // MARK: Is it this change?

    @Test func eachHintHasItsStateAndTheRunItNames() {
        let passed = F.run(1, status: .succeeded, number: "20261018.1")
        let onMain = F.run(2, status: .failed, number: "20261018.2", branch: "main")
        #expect(BuildHint.olderCommit.run == nil)
        #expect(BuildHint.olderCommit.state == .needsYou)
        #expect(BuildHint.passedBefore(passed).run == passed)
        #expect(BuildHint.passedBefore(passed).state == .needsYou)
        #expect(BuildHint.passedBeforeTargetChanged(branch: "main", run: passed).run == passed)
        #expect(BuildHint.passedBeforeTargetChanged(branch: "main", run: passed).state == .needsYou)
        #expect(BuildHint.targetFails(branch: "main", run: onMain).run == onMain)
        #expect(BuildHint.targetFails(branch: "main", run: onMain).state == .failing)
        #expect(BuildHint.targetPasses(branch: "main", run: onMain).run == onMain)
        #expect(BuildHint.targetPasses(branch: "main", run: onMain).state == .done)
    }

    // MARK: Tests, errors and the log

    @Test func itsTestsSayHowTheyWent() {
        func tests(total: Int, passed: Int, failed: Int, complete: Bool = true) -> String {
            BuildTests(total: total, passed: passed, failed: failed, runs: 1, failures: [], isComplete: complete).summary
        }
        #expect(tests(total: 320, passed: 318, failed: 2) == "2 of 320 failed")
        #expect(tests(total: 1, passed: 0, failed: 1) == "1 of 1 failed")
        #expect(tests(total: 320, passed: 318, failed: 2, complete: false) == "At least 2 failed")
        #expect(tests(total: 0, passed: 0, failed: 1, complete: false) == "At least 1 failed")
        // Counts that don't add up.
        #expect(tests(total: 1, passed: 0, failed: 3) == "3 failed")
        #expect(tests(total: 320, passed: 320, failed: 0) == "None of 320 failed")
        #expect(tests(total: 320, passed: 300, failed: 0, complete: false) == "320 counted, none failed")
        #expect(tests(total: 0, passed: 0, failed: 0) == "None ran")
        #expect(tests(total: 0, passed: 0, failed: 0, complete: false) == "None counted")
    }

    @Test func anErrorSaysWhatItsMessageDoesnt() {
        func issue(_ message: String, file: String? = nil, line: Int? = nil, column: Int? = nil, code: String? = nil, step: String = "t1")
            -> BuildIssue {
            BuildIssue(kind: .error, message: message, file: file, line: line, column: column, code: code, stepId: step, step: "Build")
        }
        #expect(issue("; expected", file: "src/Cart.cs", line: 41, column: 5).place == "src/Cart.cs:41:5")
        #expect(issue("; expected", file: "src/Cart.cs", line: 41).place == "src/Cart.cs:41")
        #expect(issue("; expected", file: "src/Cart.cs").place == "src/Cart.cs")
        #expect(issue("; expected").place == nil)
        #expect(issue("; expected", file: "").place == nil)
        // Where it is and its code, unless its message says them, and the step, unless it's the one that failed.
        #expect(issue("; expected", file: "src/Cart.cs", line: 41, column: 5, code: "CS1002").context(besides: "t1")
            == "src/Cart.cs:41:5 · CS1002")
        #expect(issue("src/Cart.cs(41,5): error CS1002: ; expected", file: "src/Cart.cs", line: 41, code: "CS1002").context(besides: "t1")
            == nil)
        #expect(issue("D:\\a\\1\\s\\src\\Cart.cs(41,5): error: ; expected", file: "src/Cart.cs", line: 41).context(besides: "t1") == nil)
        #expect(issue("Tests failed", step: "t2").context(besides: "t1") == "Build")
        #expect(issue("Tests failed", step: "t2").context(besides: nil) == "Build")
        #expect(issue("Tests failed").context(besides: "t1") == nil)
    }

    @Test func aFailedTestSaysItsSuiteAndHowLongItRan() {
        func test(_ fullName: String?, duration: TimeInterval? = nil) -> FailedTest {
            FailedTest(id: "1/1", name: "Test", fullName: fullName, duration: duration)
        }
        #expect(test("Storefront.Tests.Delivery.DeliveryEstimateTests.EstimateSkipsWeekends").suite == "DeliveryEstimateTests")
        #expect(test("Cart.Tests.RoundsHalfUp(amount: 1.5)").suite == "Tests")
        #expect(test("RoundsHalfUp").suite == nil)
        #expect(test(nil).suite == nil)
        #expect(test(nil, duration: 0.014).durationText == "14 ms")
        #expect(test(nil, duration: 0).durationText == "0 ms")
        #expect(test(nil, duration: 3.2).durationText == "3s")
        #expect(test(nil, duration: 65).durationText == "1m 5s")
        #expect(test(nil).durationText == nil)
    }

    @Test func aLogsEndSaysHowMuchOfItShows() {
        let lines = (1...40).map { BuildLogLine(number: 2_372 + $0, text: "line \($0)") }
        let log = BuildLog(stepId: "t1", logId: 9, lines: lines, lineCount: 2_412, firstLine: 2_373)
        #expect(log.last(30).map(\.number) == Array(2_383...2_412))
        #expect(log.last(100).count == 40)
        #expect(log.last(0).isEmpty)
        #expect(log.last(-1).isEmpty)
        #expect(log.extent(showing: 30) == "The last 30 of its 2412 lines")
        #expect(log.extent(showing: 100) == "The last 40 of its 2412 lines")
        #expect(log.extent(showing: 1) == "The last of its 2412 lines")
        #expect(log.linesRead == 40)
        let short = BuildLog(stepId: "t1", logId: 9, lines: (1...12).map { BuildLogLine(number: $0, text: "line \($0)") }, lineCount: 12)
        #expect(short.extent(showing: 30) == "Its 12 lines")
        #expect(short.extent(showing: 12) == "Its 12 lines")
        #expect(short.extent(showing: 5) == "The last 5 of its 12 lines")
        #expect(short.linesRead == 12)
        #expect(BuildLog(stepId: "t1", logId: 9, lines: [BuildLogLine(number: 1, text: "x")], lineCount: 1).extent(showing: 30)
            == "Its only line")
        #expect(BuildLog(stepId: "t1", logId: 9, lines: [], lineCount: 0).extent(showing: 30) == "It's empty")
        #expect(BuildLog(stepId: "t1", logId: 9, lines: [], lineCount: 0).linesRead == 0)
        #expect(BuildLog(stepId: "t1", logId: 9, lines: [], lineCount: 3).extent(showing: 30) == "None of its 3 lines can be shown")
        // The end of a group shows nothing, but counts: all of a log that has one is all of it, and its last lines count it.
        let grouped = BuildLog(stepId: "t1", logId: 9, lines: [1, 2, 4, 5].map { BuildLogLine(number: $0, text: "line \($0)") }, lineCount: 5)
        #expect(grouped.extent(showing: 4) == "Its 5 lines")
        #expect(grouped.extent(showing: 3) == "The last 4 of its 5 lines")
        #expect(grouped.extent(showing: 1) == "The last of its 5 lines")
    }

    @Test func itNamesTheStepWhoseLogItIsAndWhereItsTestsAre() {
        let steps = [step("s1", .stage, "Test", .failed, [step("j1", .job, "Unit tests", .failed, [step("t1", .task, "Run tests", .failed)])])]
        var failed = investigation(steps, failedStepId: "t1")
        #expect(failed.logStep == nil)
        failed.log = BuildLog(stepId: "t1", logId: 3, lines: [], lineCount: 0)
        #expect(failed.logStep?.name == "Run tests")
        let page = URLComponents(url: failed.testsPage, resolvingAgainstBaseURL: false)
        #expect(page?.path == "/contoso/Shop/_build/results")
        #expect(page?.queryItems?.map { "\($0.name)=\($0.value ?? "")" } == ["buildId=77", "view=ms.vss-test-web.build-test-results-tab"])
    }

    @Test func whatCouldntBeReadIsSaidInOneSentence() {
        #expect(investigation([]).unreadSentence == nil)
        #expect(investigation([], unread: [.log: .offline]).unreadSentence == "BriefBar couldn't read its log.")
        #expect(investigation([], unread: [.targetBranch: .throttled(retryAfter: 60), .log: .http(500)]).unreadSentence
            == "BriefBar couldn't read its log or main's latest runs.")
        #expect(investigation([], unread: [.steps: .offline, .tests: .offline, .earlierRuns: .offline]).unreadSentence
            == "BriefBar couldn't read all of its steps, all of its tests or its earlier runs.")
    }

    // MARK: The demo

    /// The demo's failed build, and the one still going, open in their pull requests' details.
    @Test func theDemosBuildsOpen() throws {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        let records = DemoData.records(now: now)
        func line(_ number: Int) throws -> (PullRequest, PullRequestPanel.CheckLine) {
            let record = try #require(records.first { $0.id.number == number })
            let row = try #require(PRClassifier.snapshot(
                for: record, seenCutoff: seen.cutoff(for: record.id), dismissedCutoff: seen.dismissedCutoff(for: record.id), now: now
            ))
            return (record.pullRequest, try #require(PullRequestPanel(row, record: record).checks.first { $0.canInvestigate }))
        }

        let (delivery, failedLine) = try line(4088)
        let failedRun = try #require(failedLine.buildId)
        let failed = try #require(DemoData.investigation(buildId: failedRun, of: delivery, now: now))
        #expect(failed.failurePlace == ["Test", "Unit tests", "Run unit tests"])
        #expect(failed.stages.map(\.state) == [.succeeded, .failed, .skipped])
        #expect(failed.hints.map(\.state) == [.failing])
        #expect(failed.tests?.summary == "2 of 320 failed")
        #expect(failed.logStep?.name == "Run unit tests")
        #expect(failed.progress == nil)

        let (slowQueries, runningLine) = try line(4099)
        #expect(runningLine.run.state == .running)
        let runningRun = try #require(runningLine.buildId)
        let running = try #require(DemoData.investigation(buildId: runningRun, of: slowQueries, now: now))
        #expect(running.progress == .running(["Test", "Integration tests", "Run integration tests"]))
        #expect(running.stages.map(\.state) == [.succeeded, .running, .pending])
        #expect(running.failurePlace.isEmpty && running.hints.isEmpty && running.log == nil && running.tests == nil)

        // Not another pull request's.
        #expect(DemoData.investigation(buildId: runningRun, of: delivery, now: now) == nil)
    }
}
