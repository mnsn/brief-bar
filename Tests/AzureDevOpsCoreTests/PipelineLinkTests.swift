import Foundation
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// Links to pipelines and runs, pasted in Add Pipeline.
@Suite struct PipelineLinkTests {
    @Test func readsLinksToPipelinesAndRuns() {
        #expect(PipelineLink("https://dev.azure.com/contoso/Shop/_build?definitionId=12")
            == PipelineLink(organization: "contoso", project: "Shop", target: .pipeline(12)))
        #expect(PipelineLink("dev.azure.com/contoso/Shop/_build/results?buildId=4071&view=logs&j=1")
            == PipelineLink(organization: "contoso", project: "Shop", target: .run(4071)))
        #expect(PipelineLink("https://contoso.visualstudio.com/DefaultCollection/Shop%20Web/_build?definitionId=7&_a=summary")
            == PipelineLink(organization: "contoso", project: "Shop Web", target: .pipeline(7)))
        #expect(PipelineLink("  https://contoso.visualstudio.com/Shop/_build/definition?definitionId=3  ")
            == PipelineLink(organization: "contoso", project: "Shop", target: .pipeline(3)))
        // A run's link names its pipeline too: the run wins.
        #expect(PipelineLink("https://dev.azure.com/contoso/Shop/_build/results?buildId=9&definitionId=12")?.target == .run(9))
    }

    @Test func ignoresAnythingElse() {
        for text in [
            "shop-web CI", "https://dev.azure.com/contoso/Shop/_build", "https://dev.azure.com/contoso/Shop/_git/web/pullrequest/7",
            "https://example.com/contoso/Shop/_build?definitionId=12", "https://dev.azure.com/contoso/_build?definitionId=12",
            "https://dev.azure.com/contoso/Shop/_build?definitionId=abc", "https://dev.azure.com/contoso/Shop/_build?definitionId=0",
            "https://dev.azure.com/bad_name!/Shop/_build?definitionId=1",
        ] {
            #expect(PipelineLink(text) == nil, "\(text)")
        }
    }

    @Test func findsThePipelineALinkIsTo() async throws {
        let server = StubServer()
        server.on("/contoso/Shop/_apis/build/definitions/12", json: [
            "id": 12, "name": "web CI", "path": "\\Shop\\CI", "project": ["id": "p1", "name": "Shop"],
        ])
        var run = WorkFixture.build(4071, definition: 12, queued: t(0), branch: "refs/heads/release/2.0")
        run["definition"] = ["id": 12, "name": "web CI", "path": "\\Shop\\CI"]
        server.on("/contoso/Shop/_apis/build/builds/4071", json: run)
        var pullRequestRun = run
        pullRequestRun["sourceBranch"] = "refs/pull/7/merge"
        server.on("/contoso/Shop/_apis/build/builds/4072", json: pullRequestRun)
        let client = server.client()

        let pipeline = try await PipelineSearch.pipeline(
            for: PipelineLink(organization: "contoso", project: "Shop", target: .pipeline(12)), client: client
        )
        #expect(pipeline == PipelineRef(organization: "contoso", projectId: "p1", projectName: "Shop", definitionId: 12, name: "web CI",
                                        folder: "Shop\\CI"))

        // A run's link pins its pipeline, showing that run's branch, but not a pull request's.
        let fromRun = try await PipelineSearch.pipeline(for: PipelineLink(organization: "contoso", project: "Shop", target: .run(4071)), client: client)
        #expect(fromRun.id == pipeline.id)
        #expect(fromRun.branch == "release/2.0")
        let fromPullRequest = try await PipelineSearch.pipeline(
            for: PipelineLink(organization: "contoso", project: "Shop", target: .run(4072)), client: client
        )
        #expect(fromPullRequest.branch == nil)

        await #expect(throws: ADOError.self) {
            try await PipelineSearch.pipeline(for: PipelineLink(organization: "contoso", project: "Shop", target: .pipeline(99)), client: client)
        }
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}
