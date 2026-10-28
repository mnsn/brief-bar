import Foundation
import Testing
@testable import AzureDevOpsCore

@Suite struct PullRequestPipelinesTests {
    private func build(
        _ id: Int, pr: Int = 7, definition: Int = 31, result: String = "succeeded", version: String? = "merge",
        source: String? = nil, queued: Date = t(-minute)
    ) throws -> ADOBuild {
        var json = WorkFixture.build(
            id, definition: definition, result: result, queued: queued, branch: "refs/pull/\(pr)/merge", reason: "pullRequest"
        )
        if let version { json["sourceVersion"] = version }
        if let source { json["triggerInfo"] = ["pr.sourceSha": source] }
        return try ADOJSON.decoder().decode(ADOBuild.self, from: Fixture.data(json))
    }

    private func group(_ pr: PullRequest, _ builds: [ADOBuild]?) -> PullRequestPipelines {
        PullRequestPipelines(pullRequest: pr, builds: builds) { PipelineStatus(pipeline: $0, runs: $1) }
    }

    @Test func groupsByPRAndKeepsLatestRunPerDefinition() throws {
        var pr = makePR()
        pr.mergeCommit = "MERGE"
        let builds = try [
            build(1, queued: t(-hour)), build(2, result: "failed"),
            build(3, pr: 8), build(4, definition: 32),
        ]
        let result = group(pr, builds)
        #expect(result.pipelines.map(\.pipeline.definitionId) == [31, 32])
        #expect(result.pipelines.compactMap(\.latest?.id) == [2, 4])
        #expect(result.headline == "1 failed · 1 passed")
        #expect(result.pipelines.allSatisfy { result.revision(of: $0) == .current })
        #expect(group(makePR(8), builds).pipelines.compactMap(\.latest?.id) == [3])
    }

    @Test func neverTreatsAnEarlierCommitsSuccessAsCurrent() throws {
        var pr = makePR()
        pr.mergeCommit = "new-merge"
        let result = group(pr, try [build(1), build(2, definition: 32, version: "new-merge")])
        #expect(result.headline == "1 passed · 1 outdated")
        pr.sourceCommit = "new-source"
        let oldSource = group(pr, try [build(3, version: "new-merge", source: "abc")])
        #expect(oldSource.headline == "1 outdated")
        #expect(!oldSource.headline.contains("passed"))
    }

    @Test func verifiesSourceMetadataAndLabelsMissingCommitInformation() throws {
        let pr = makePR()
        #expect(group(pr, try [build(1, version: nil, source: "ABC")]).headline == "1 passed")
        #expect(group(pr, try [build(2, source: "old")]).headline == "1 outdated")
        #expect(group(pr, try [build(3)]).headline == "1 commit unverified")
        #expect(group(pr, nil).headline == "Loading pipeline runs...")
        #expect(group(pr, []).headline == "No pipeline runs yet")
    }

    @Test func canceledAndPartialResultsAreNotReportedAsPassed() throws {
        var pr = makePR()
        pr.mergeCommit = "merge"
        let result = group(pr, try [build(1, result: "canceled"), build(2, definition: 32, result: "partiallySucceeded")])
        #expect(result.headline == "1 succeeded with issues · 1 canceled")
    }

    @Test func requiresSuccessfulMergeComputationBeforeCountingCurrentResults() throws {
        let statuses: [String?] = ["queued", "conflicts", "failure", nil]
        for mergeStatus in statuses {
            var pr = makePR(merge: mergeStatus)
            let sourceOnly = try build(1, version: nil, source: "abc")
            #expect(group(pr, [sourceOnly]).headline == "1 commit unverified")
            pr.mergeCommit = "merge"
            let matchingMerge = try build(2, source: "abc")
            #expect(group(pr, [matchingMerge]).headline == "1 commit unverified")
            let olderSource = try build(3, source: "old-source")
            #expect(group(pr, [olderSource]).headline == "1 outdated")
        }
    }

    @Test func scopesEndpointToRepositoryAndExactPRRef() {
        let url = ADOEndpoint.pullRequestBuilds(makePR())
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path == "/contoso/p1/_apis/build/builds")
        #expect(query.contains(URLQueryItem(name: "repositoryId", value: "r1")))
        #expect(query.contains(URLQueryItem(name: "repositoryType", value: "TfsGit")))
        #expect(query.contains(URLQueryItem(name: "branchName", value: "refs/pull/7/merge")))
        #expect(query.contains(URLQueryItem(name: "queryOrder", value: "queueTimeDescending")))
    }

    @Test func readsPRsWithoutPinnedPipelinesAndReusesTimelineCache() async throws {
        let server = StubServer()
        var pr = makePR()
        pr.mergeCommit = "merge"
        var json = WorkFixture.build(1, definition: 31, result: "failed", queued: t(-hour), branch: "refs/pull/7/merge")
        json["sourceVersion"] = "merge"
        server.on("/p1/_apis/build/builds", json: Fixture.list([json]))
        server.on("/builds/1/timeline", json: WorkFixture.timeline([
            WorkFixture.record("stage", "Stage", "Test", result: "failed"),
            WorkFixture.record("task", "Task", "Unit tests", parent: "stage", result: "failed",
                               issues: [["type": "error", "message": "Test failed"]]),
        ]))
        let engine = PipelinesEngine(client: server.client(), configuration: .init(pipelines: [], pullRequests: [pr])) { _ in }
        await engine.setActive(true)
        await engine.refreshNow()
        await engine.refreshNow()
        let snapshot = await engine.currentSnapshot()
        #expect(snapshot.problem == nil)
        #expect(snapshot.statuses.isEmpty)
        #expect(snapshot.pullRequests.first?.headline == "1 failed")
        #expect(snapshot.pullRequests.first?.pipelines.first?.failure?.message == "Test failed")
        #expect(server.requests.filter { $0.url?.path.hasSuffix("/timeline") == true }.count == 1)
        #expect(await engine.sleepTime() < 3_600)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func removesClosedPRsAndClearsTheirRunsOnReopen() async throws {
        let server = StubServer()
        let json = WorkFixture.build(1, definition: 31, queued: t(-hour), branch: "refs/pull/7/merge")
        server.on("/p1/_apis/build/builds", json: Fixture.list([json]))
        server.on("/timeline", json: WorkFixture.timeline([]))
        let pr = makePR()
        let engine = PipelinesEngine(client: server.client(), configuration: .init(pipelines: [], pullRequests: [pr])) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().pullRequests.first?.pipelines.count == 1)
        for status in [PullRequest.Status.completed, .abandoned] {
            var closed = pr
            closed.status = status
            await engine.setConfiguration(.init(pipelines: [], pullRequests: [closed]))
            #expect(await engine.currentSnapshot().pullRequests.isEmpty)
            await engine.setConfiguration(.init(pipelines: [], pullRequests: [pr]))
            #expect(await engine.currentSnapshot().pullRequests.first?.hasLoaded == false)
        }
    }

    @Test func surfacesListErrorsRatherThanReportingNoRuns() async {
        let server = StubServer()
        server.on("/p1/_apis/build/builds") { _ in .status(403) }
        let engine = PipelinesEngine(client: server.client(), configuration: .init(pipelines: [], pullRequests: [makePR()])) { _ in }
        await engine.refreshNow()
        let result = await engine.currentSnapshot()
        #expect(result.problem != nil)
        #expect(result.pullRequests.first?.hasLoaded == false)
    }

    @Test func keepsSharedDefinitionsSeparateAcrossPRs() async {
        let server = StubServer()
        server.on("/p1/_apis/build/builds") { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let second = query.contains(URLQueryItem(name: "branchName", value: "refs/pull/8/merge"))
            return .json(Fixture.list([
                WorkFixture.build(
                    second ? 2 : 1, definition: 31, result: second ? "failed" : "succeeded", queued: t(-hour),
                    branch: "refs/pull/\(second ? 8 : 7)/merge"
                ),
            ]))
        }
        server.on("/timeline", json: WorkFixture.timeline([]))
        let engine = PipelinesEngine(
            client: server.client(), configuration: .init(pipelines: [], pullRequests: [makePR(7), makePR(8)])
        ) { _ in }
        await engine.refreshNow()
        let groups = await engine.currentSnapshot().pullRequests
        #expect(groups.map(\.id.number) == [7, 8])
        #expect(groups[0].pipelines.first?.latest?.status == .succeeded)
        #expect(groups[1].pipelines.first?.latest?.status == .failed)
        #expect(groups.flatMap(\.pipelines).compactMap(\.latest?.id) == [1, 2])
    }

    @Test func commitChangesReclassifyCachedResultsWithoutAnotherRequest() async {
        let server = StubServer()
        var json = WorkFixture.build(1, definition: 31, queued: t(-hour), branch: "refs/pull/7/merge")
        json["triggerInfo"] = ["pr.sourceSha": "abc"]
        server.on("/p1/_apis/build/builds", json: Fixture.list([json]))
        server.on("/timeline", json: WorkFixture.timeline([]))
        var pr = makePR()
        let engine = PipelinesEngine(client: server.client(), configuration: .init(pipelines: [], pullRequests: [pr])) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().pullRequests.first?.headline == "1 passed")
        let requests = server.requests.count
        pr.sourceCommit = "new-source"
        await engine.setConfiguration(.init(pipelines: [], pullRequests: [pr]))
        #expect(await engine.currentSnapshot().pullRequests.first?.headline == "1 outdated")
        #expect(server.requests.count == requests)
    }

    @Test func hiddenPRPipelinesDoNotPoll() async throws {
        let server = StubServer()
        let engine = PipelinesEngine(client: server.client(), configuration: .init(pipelines: [], pullRequests: [makePR()])) { _ in }
        await engine.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.requests.isEmpty)
        await engine.stop()
    }

    @Test func closingPRsDuringRefreshDoesNotRestoreCardsOrReadTheNextPR() async throws {
        let server = StubServer()
        server.on("/p1/_apis/build/builds", json: Fixture.list([
            WorkFixture.build(1, definition: 31, queued: t(-hour), branch: "refs/pull/7/merge"),
        ]))
        let tokens = HeldTokens(server.id, holdAt: 2)
        let engine = PipelinesEngine(
            client: server.client(tokens: tokens), configuration: .init(pipelines: [], pullRequests: [makePR(7), makePR(8)])
        ) { _ in }
        let refresh = Task { await engine.refreshNow() }
        try await waitUntilHeld(tokens)
        await engine.setConfiguration(.init(pipelines: []))
        await tokens.release()
        await refresh.value
        #expect(await engine.currentSnapshot().pullRequests.isEmpty)
        #expect(server.requests.count == 1)
    }

    @Test func changingAccountsDiscardsPRRunsEvenWhenTheNewReadFails() async {
        let server = StubServer()
        let tokens = FakeTokens(server.id)
        await tokens.signIn(as: "tenant/robin")
        server.on("/p1/_apis/build/builds", json: Fixture.list([
            WorkFixture.build(1, definition: 31, queued: t(-hour), branch: "refs/pull/7/merge"),
        ]))
        server.on("/timeline", json: WorkFixture.timeline([]))
        let engine = PipelinesEngine(
            client: server.client(tokens: tokens),
            configuration: .init(pipelines: [], pullRequests: [makePR()], pullRequestAccount: "tenant/robin")
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().pullRequests.first?.pipelines.count == 1)
        await tokens.signIn(as: "tenant/sam")
        server.on("/p1/_apis/build/builds") { _ in .status(403) }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().pullRequests.isEmpty)
    }

    @Test func readableOldAccountsPRsStaySuspendedUntilMatchingAuthoredListArrives() async {
        let server = StubServer()
        let tokens = FakeTokens(server.id)
        await tokens.signIn(as: "tenant/robin")
        server.on("/p1/_apis/build/builds", json: Fixture.list([
            WorkFixture.build(1, definition: 31, queued: t(-hour), branch: "refs/pull/7/merge"),
        ]))
        server.on("/timeline", json: WorkFixture.timeline([]))
        let engine = PipelinesEngine(
            client: server.client(tokens: tokens),
            configuration: .init(pipelines: [], pullRequests: [makePR()], pullRequestAccount: "tenant/robin")
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().pullRequests.first?.pipelines.count == 1)
        let requests = server.requests.count

        // Both identities can read this repository: a 403 must not be needed to protect the old authored list.
        await tokens.signIn(as: "tenant/sam")
        await engine.refreshNow()
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().account == "tenant/sam")
        #expect(await engine.currentSnapshot().pullRequests.isEmpty)
        #expect(server.requests.count == requests)

        // A delayed update from the old PR engine must not resume reads.
        await engine.setConfiguration(.init(
            pipelines: [], pullRequests: [makePR(), makePR(8)], pullRequestAccount: "tenant/robin"
        ))
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().pullRequests.isEmpty)
        #expect(server.requests.count == requests)

        // Even if the fresh authored list happens to contain the same PR, the previous account's cache is gone.
        await engine.setConfiguration(.init(pipelines: [], pullRequests: [makePR()], pullRequestAccount: "tenant/sam"))
        #expect(await engine.currentSnapshot().pullRequests.first?.hasLoaded == false)
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().pullRequests.first?.pipelines.count == 1)
        #expect(server.requests.count > requests)
    }

    @Test func refusesUnattributedPRConfigurationWithAnIdentifiedToken() async {
        let server = StubServer()
        let tokens = FakeTokens(server.id)
        await tokens.signIn(as: "tenant/sam")
        let engine = PipelinesEngine(
            client: server.client(tokens: tokens), configuration: .init(pipelines: [], pullRequests: [makePR()])
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().pullRequests.isEmpty)
        #expect(server.requests.isEmpty)
    }

    @Test func PRListThrottlingStopsRequestsAndBacksOff() async {
        let server = StubServer()
        server.on("/p1/_apis/build/builds") { _ in .status(429, headers: ["Retry-After": "120"]) }
        let engine = PipelinesEngine(
            client: server.client(), configuration: .init(pipelines: [], pullRequests: [makePR(7), makePR(8)])
        ) { _ in }
        await engine.refreshNow()
        #expect(server.requests.count == 1)
        #expect(await engine.currentSnapshot().problem != nil)
        #expect(await engine.nextDelay() > 100)
    }

    @Test func skippedOldAccountPRsDoNotDisablePinnedListBackoff() async {
        let server = StubServer()
        let tokens = FakeTokens(server.id)
        await tokens.signIn(as: "tenant/sam")
        let pinned = PipelineRef(organization: Fixture.org, projectId: "p1", projectName: "Shop", definitionId: 31, name: "CI")
        server.on("/p1/_apis/build/builds") { _ in .status(500) }
        let engine = PipelinesEngine(
            client: server.client(tokens: tokens),
            configuration: .init(pipelines: [pinned], pullRequests: [makePR()], pullRequestAccount: "tenant/robin")
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().problem == .unreachable("Azure DevOps answered with HTTP 500."))
        #expect(await engine.nextDelay() == 120)
        await engine.refreshNow()
        #expect(await engine.nextDelay() == 240)
        #expect(server.requests.count == 2)
    }

    @Test func PRsClosedDuringRefreshDoNotCountAsSuccessfulListReads() async throws {
        let server = StubServer()
        let tokens = HeldTokens(server.id, holdAt: 2)
        let pinned = PipelineRef(organization: Fixture.org, projectId: "p1", projectName: "Shop", definitionId: 31, name: "CI")
        server.on("/p1/_apis/build/builds") { _ in .status(500) }
        let engine = PipelinesEngine(
            client: server.client(tokens: tokens), configuration: .init(pipelines: [pinned], pullRequests: [makePR()])
        ) { _ in }
        let refresh = Task { await engine.refreshNow() }
        try await waitUntilHeld(tokens)
        await engine.setConfiguration(.init(pipelines: [pinned]))
        await tokens.release()
        await refresh.value
        #expect(server.requests.count == 1)
        #expect(await engine.nextDelay() == 120)
        #expect(await engine.currentSnapshot().problem == .unreachable("Azure DevOps answered with HTTP 500."))
    }

    @Test func successfulPRListKeepsPinnedFailurePartialWithoutBackoff() async {
        let server = StubServer()
        let pinned = PipelineRef(organization: Fixture.org, projectId: "p1", projectName: "Shop", definitionId: 31, name: "CI")
        server.on("/p1/_apis/build/builds") { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(URLQueryItem(name: "branchName", value: "refs/pull/7/merge")) {
                return .json(Fixture.list([]))
            }
            return .status(500)
        }
        let engine = PipelinesEngine(
            client: server.client(), configuration: .init(pipelines: [pinned], pullRequests: [makePR()])
        ) { _ in }
        await engine.refreshNow()
        #expect(await engine.nextDelay() == 60)
        #expect(await engine.currentSnapshot().problem == .unreachable(
            "Couldn't read some pipelines: Azure DevOps answered with HTTP 500."
        ))
        #expect(server.requests.count == 2)
    }

    @Test func demoUsesSeparateRunsForEachPRAndIncludesOutdatedResults() {
        let prs = DemoData.records(now: t(0)).filter { $0.role == .author && $0.pullRequest.status == .active }.map(\.pullRequest)
        let groups = DemoData.pullRequestPipelines(prs, now: t(0))
        #expect(groups.map(\.id) == prs.map(\.key))
        let runs = groups.flatMap(\.pipelines).compactMap(\.latest?.id)
        #expect(Set(runs).count == runs.count)
        #expect(groups.contains { $0.headline.contains("outdated") })
    }
}
