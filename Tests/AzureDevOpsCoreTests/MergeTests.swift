import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// The pipelines after a merge: which runs belong to it, how they add up, what the merged pull request then says, what's
/// announced, and the engine's requests.
@Suite struct MergeTests {
    /// A run of a pipeline, on a commit, started by a push or by another run.
    private func build(
        _ id: Int, definition: Int, commit: String = "m1", status: String = "completed", result: String? = "succeeded",
        queued: Date, reason: String = "individualCI", triggeredBy: Int? = nil
    ) -> [String: Any] {
        var json = WorkFixture.build(id, definition: definition, status: status, result: result, queued: queued, reason: reason)
        json["sourceVersion"] = commit
        if let triggeredBy { json["triggeredByBuild"] = ["id": triggeredBy] }
        return json
    }

    private func status(
        _ id: Int, _ run: PipelineRun.Status, stages: [PipelineStage] = [], failure: PipelineFailure? = nil, finished: Date? = nil
    ) -> PipelineStatus {
        let pipeline = PipelineRef(organization: Fixture.org, projectId: "p1", projectName: "Shop", definitionId: id, name: "pipeline \(id)")
        let latest = PipelineRun(
            id: id, organization: Fixture.org, projectName: "Shop", number: "20261018.\(id)", status: run, trigger: .push,
            branch: "main", queuedAt: t(-50 * minute), startedAt: t(-49 * minute), finishedAt: run.isFinished ? (finished ?? t(-minute)) : nil
        )
        return PipelineStatus(pipeline: pipeline, runs: [latest], stages: stages, failure: failure)
    }

    private let waitingStage = PipelineStage(id: "s3", name: "Production", state: .waiting)
    private let unitTests = PipelineFailure(stage: "Test", step: "Run unit tests", message: "2 tests failed.")

    // MARK: Which runs

    @Test func findsTheRunsOnTheMergeAndTheOnesTheyStarted() throws {
        let onBranch = try Fixture.decode([ADOBuild].self, [
            build(1, definition: 10, commit: "ABC", queued: t(0)),
            // A scheduled run only happened to pick the commit up.
            build(2, definition: 11, commit: "abc", queued: t(0), reason: "schedule"),
            build(3, definition: 12, commit: "other", queued: t(0)),
        ])
        let triggered = try Fixture.decode([ADOBuild].self, [
            build(5, definition: 21, commit: "x", queued: t(minute), reason: "resourceTrigger", triggeredBy: 4),
            build(4, definition: 20, commit: "abc", queued: t(minute), reason: "buildCompletion", triggeredBy: 1),
            build(6, definition: 22, queued: t(minute), reason: "buildCompletion", triggeredBy: 3),
        ])
        #expect(MergeChain.runs(onBranch: onBranch, triggered: triggered, mergeCommit: "abc").map(\.id) == [1, 4, 5])
        #expect(MergeChain.runs(onBranch: onBranch, triggered: triggered, mergeCommit: "none").isEmpty)
    }

    @Test func followsAMergeWhileRunsMayStillStart() {
        func run(_ status: PipelineRun.Status, finished: Date? = nil) -> PipelineRun {
            PipelineRun(id: 1, organization: Fixture.org, projectName: "Shop", number: "1", status: status, trigger: .push,
                        branch: "main", finishedAt: finished)
        }
        let merged = t(0)
        #expect(MergeChain.isFollowing(mergedAt: merged, runs: [], at: t(10 * minute)))
        #expect(!MergeChain.isFollowing(mergedAt: merged, runs: [], at: t(31 * minute)))
        #expect(MergeChain.isFollowing(mergedAt: merged, runs: [run(.queued)], at: t(5 * hour)))
        #expect(MergeChain.isFollowing(mergedAt: merged, runs: [run(.succeeded, finished: t(50 * minute))], at: t(60 * minute)))
        #expect(!MergeChain.isFollowing(mergedAt: merged, runs: [run(.succeeded, finished: t(50 * minute))], at: t(66 * minute)))
    }

    // MARK: How they add up

    @Test func whatFailedComesFirstThenWhatWaitsThenWhatRuns() throws {
        #expect(MergeSummary([]) == nil)

        let passed = try #require(MergeSummary([status(1, .succeeded), status(2, .partiallySucceeded), status(3, .canceled)]))
        #expect(passed.outcome == .passed)
        #expect(passed.total == 3)

        let running = try #require(MergeSummary([status(1, .succeeded), status(2, .running)]))
        #expect(running.outcome == .running)
        #expect(running.running == 1)

        let waiting = try #require(MergeSummary([status(1, .running), status(2, .running, stages: [waitingStage])]))
        #expect(waiting.outcome == .waiting)
        #expect(waiting.pipeline == "pipeline 2")
        #expect(waiting.stage == "Production")
        #expect(waiting.runId == 2)

        let failed = try #require(MergeSummary([status(1, .running, stages: [waitingStage]), status(2, .failed, failure: unitTests)]))
        #expect(failed.outcome == .failed)
        #expect(failed.pipeline == "pipeline 2")
        #expect(failed.failure == unitTests)
        #expect(failed.runURL?.absoluteString.contains("buildId=2") == true)
    }

    // MARK: The merged pull request

    @Test func aMergedPullRequestSaysWhatItsPipelinesDo() throws {
        var pr = makePR(status: .completed, closed: t(-hour))
        pr.mergeCommit = "m1"
        func classify(_ statuses: [PipelineStatus], seen: Date) -> PRSnapshot? {
            let merge = MergePipelines(pullRequest: pr.key, title: pr.title, targetBranch: pr.targetBranch, mergedAt: t(-hour),
                                       url: pr.webURL, pipelines: statuses, isFollowing: true)
            return PRClassifier.snapshot(for: PRRecord(pullRequest: pr, role: .author, me: People.me.id, merge: merge), seenCutoff: seen, now: t(0))
        }

        // While they run, it stays in Done, even once you've seen it.
        let running = try #require(classify([status(1, .succeeded), status(2, .running)], seen: t(-minute)))
        #expect(running.group == .done)
        #expect(running.reason == .completed)
        #expect(running.detail == "Merged into main · 1 pipeline running")
        #expect(running.url == pr.webURL)

        // A failed one is wrong, and opens the run.
        let failed = try #require(classify([status(1, .succeeded), status(2, .failed, failure: unitTests)], seen: t(-minute)))
        #expect(failed.group == .failing)
        #expect(failed.reason == .failedAfterMerge)
        #expect(failed.headline == "Failed after merge")
        #expect(failed.detail == "pipeline 2 · Run unit tests: 2 tests failed.")
        #expect(failed.failure == unitTests)
        #expect(failed.url.absoluteString.contains("buildId=2"))
        #expect(failed.merge?.outcome == .failed)
        #expect(Brief.item(failed, reader: nil).sentence == "“pipeline 2” failed after “Fix the checkout total” merged.")

        let waiting = try #require(classify([status(1, .running, stages: [waitingStage])], seen: t(-minute)))
        #expect(waiting.group == .done)
        #expect(waiting.reason == .waitingForApproval)
        #expect(waiting.headline == "Waiting for approval")
        #expect(waiting.detail == "pipeline 1 · Production")

        // Once they all passed, it's Done as before: until you've seen it.
        let passed = try #require(classify([status(1, .succeeded), status(2, .succeeded)], seen: t(-2 * hour)))
        #expect(passed.group == .done)
        #expect(passed.detail == "Merged into main · 2 pipelines passed")
        #expect(classify([status(1, .succeeded)], seen: t(-2 * hour))?.detail == "Merged into main · its pipeline passed")
        #expect(classify([status(1, .succeeded)], seen: t(-minute)) == nil)

        // Someone else's merge, or one abandoned, says nothing about pipelines.
        var abandoned = pr
        abandoned.status = .abandoned
        let merge = MergePipelines(pullRequest: pr.key, title: pr.title, targetBranch: "main", mergedAt: t(-hour), url: pr.webURL,
                                   pipelines: [status(1, .failed)], isFollowing: false)
        let gone = PRClassifier.snapshot(
            for: PRRecord(pullRequest: abandoned, role: .author, me: People.me.id, merge: merge), seenCutoff: t(-2 * hour), now: t(0)
        )
        #expect(gone?.group == .done)
        #expect(gone?.reason == .abandoned)
        #expect(gone?.merge == nil)
    }

    // MARK: Notifications

    private func snapshot(_ merge: MergeSummary?, group: PRGroup = .done, reason: PRReason = .completed) -> PRSnapshot {
        var snapshot = PRSnapshot(
            key: PRKey(Fixture.org, 7), title: "Fix the checkout total", repository: "shop-web", project: "Shop", author: "Robin Diaz",
            role: .author, isDraft: false, group: group, reason: reason, headline: "Completed", detail: nil, since: t(-hour),
            url: URL(string: "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/7")!, events: [], approvals: [],
            checkState: nil, hasDetails: false
        )
        snapshot.merge = merge
        return snapshot
    }

    @Test func announcesWhatHappensAfterAMergeOnce() {
        let running = MergeSummary(outcome: .running, total: 2, running: 2, since: t(-minute))
        let failed = MergeSummary(
            outcome: .failed, total: 2, running: 1, pipeline: "shop-web CD", failure: PipelineFailure(stage: nil, step: "Deploy", message: "Timed out."),
            runId: 7, since: t(0)
        )
        func plan(_ previous: [PRSnapshot], _ current: [PRSnapshot]) -> [PulseNotification] {
            NotificationPlanner.plan(previous: previous, current: current, notBefore: t(-hour))
        }

        let notes = plan([snapshot(running)], [snapshot(failed, group: .failing, reason: .failedAfterMerge)])
        #expect(notes.map(\.title) == ["Failed after merge"])
        #expect(notes.first?.body == "“shop-web CD”: Deploy: Timed out.")
        // The same failure again isn't news; a later run failing is.
        #expect(plan([snapshot(failed)], [snapshot(failed)]).isEmpty)
        var again = failed
        again.runId = 8
        #expect(plan([snapshot(failed)], [snapshot(again)]).count == 1)

        let waiting = MergeSummary(outcome: .waiting, total: 1, running: 1, pipeline: "shop-web CD", stage: "Production", runId: 9, since: t(0))
        #expect(plan([snapshot(running)], [snapshot(waiting)]).first?.body == "“shop-web CD” waits for approval to Production.")
        #expect(plan([snapshot(waiting)], [snapshot(waiting)]).isEmpty)

        let passed = MergeSummary(outcome: .passed, total: 2, since: t(0))
        let done = plan([snapshot(running)], [snapshot(passed)])
        #expect(done.map(\.title) == ["Pipelines passed"])
        #expect(done.first?.body == "All 2 pipelines passed after it merged.")
        // Pipelines that had passed already when BriefBar first saw them aren't news, and neither is what happened before
        // it started.
        #expect(plan([], [snapshot(passed)]).isEmpty)
        var old = failed
        old.since = t(-2 * hour)
        #expect(plan([snapshot(running)], [snapshot(old)]).isEmpty)
    }

    // MARK: The engine

    @Test func followsThePipelinesAfterYourMergeWithGETRequests() async throws {
        let start = Date()
        let clock = Mutex(start)
        let server = StubServer()
        var merged = Fixture.pullRequest(3, title: "Merged", created: start.addingTimeInterval(-day), status: "completed",
                                         closed: start.addingTimeInterval(-10 * minute))
        merged["lastMergeCommit"] = ["commitId": "m1"]
        server.serveOrganization(completed: [merged])
        func serve(finished: Bool) {
            let status = finished ? "completed" : "inProgress"
            let result: String? = finished ? "succeeded" : nil
            server.on("/_apis/build/builds", query: ["repositoryId": "r1"], json: Fixture.list([
                build(1, definition: 10, queued: start.addingTimeInterval(-9 * minute)),
                build(2, definition: 11, status: status, result: result, queued: start.addingTimeInterval(-8 * minute)),
                build(4, definition: 12, commit: "before", queued: start.addingTimeInterval(-9 * minute)),
            ]))
            server.on("/_apis/build/builds", query: ["reasonFilter": "buildCompletion,resourceTrigger"], json: Fixture.list([
                build(5, definition: 20, status: status, result: result, queued: start.addingTimeInterval(-2 * minute),
                      reason: "buildCompletion", triggeredBy: 1),
            ]))
        }
        serve(finished: false)
        server.on("/builds/2/timeline", json: WorkFixture.timeline([
            WorkFixture.record("s1", "Stage", "Staging", order: 1),
            WorkFixture.record("s2", "Stage", "Production", order: 2, state: "pending", result: nil),
            WorkFixture.record("c2", "Checkpoint", "Checkpoint", parent: "s2", state: "inProgress", result: nil),
        ]))
        let engine = PulseEngine(
            client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org]), now: { clock.withLock { $0 } }
        ) { _ in }
        func lookups() -> Int {
            server.requests.filter { $0.url?.query?.contains("repositoryId=r1") == true }.count
        }

        await engine.refreshNow()
        let first = try #require(await engine.currentSnapshot().records.first { $0.id.number == 3 }?.merge)
        #expect(first.pipelines.map(\.pipeline.definitionId) == [10, 11, 20])
        #expect(first.pipelines.map(\.pipeline.name) == ["pipeline 10", "pipeline 11", "pipeline 20"])
        #expect(first.isFollowing)
        #expect(first.summary?.outcome == .waiting)
        #expect(first.summary?.stage == "Production")
        let item = try #require(classify(await engine.currentSnapshot(), now: start))
        #expect(item.reason == .waitingForApproval)

        // They finish; a refresh later, BriefBar reads that, and then stops looking a while after the last one finished.
        serve(finished: true)
        clock.withLock { $0 = start.addingTimeInterval(5 * minute) }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().records.first { $0.id.number == 3 }?.merge?.summary?.outcome == .passed)
        #expect(lookups() == 2)
        clock.withLock { $0 = start.addingTimeInterval(2 * hour) }
        await engine.refreshNow()
        #expect(lookups() == 2)
        #expect(await engine.currentSnapshot().records.first { $0.id.number == 3 }?.merge?.isFollowing == false)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    }

    @Test func turnedOffItReadsNoRuns() async throws {
        let server = StubServer()
        var merged = Fixture.pullRequest(3, status: "completed", closed: Date().addingTimeInterval(-minute))
        merged["lastMergeCommit"] = ["commitId": "m1"]
        server.serveOrganization(completed: [merged])
        let snapshot = await PulseEngine.loadOnce(
            client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org], followMerges: false)
        )
        #expect(snapshot.records.first?.merge == nil)
        #expect(!server.requests.contains { $0.url?.path.contains("/_apis/build/") == true })
    }

    private func classify(_ snapshot: PulseSnapshot, now: Date) -> PRSnapshot? {
        snapshot.records.first { $0.id.number == 3 }.flatMap { record in
            PRClassifier.snapshot(for: record, seenCutoff: SeenState.firstRun(now: now).cutoff(for: record.id), now: now)
        }
    }
}
