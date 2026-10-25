import AzureDevOpsCore
import BriefBarUI
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// `--mcp`'s reader of Azure DevOps, against the stub Azure DevOps: it reads as the app does, shares a read between
/// the calls of a minute, and changes only the app's lists, telling the app each time. (It's here, rather than with the
/// app code's tests, for the stub.)
@Suite struct AgentReaderTests {
    /// How many times the reader told the app its settings changed.
    final class Announcements: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    private func reader(_ server: StubServer, defaults: MemoryDefaults, announced: Announcements? = nil) -> AzureDevOpsReader {
        AzureDevOpsReader(demo: false, organizations: [], defaults: defaults, client: server.client()) {
            announced?.add()
        }
    }

    private func defaults(organizations: [String] = [Fixture.org]) -> MemoryDefaults {
        let defaults = MemoryDefaults()
        defaults.set(organizations, forKey: SettingsKey.organizations)
        return defaults
    }

    @Test func sharesAReadForAMinute() async {
        let now = Date()
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1, title: "Mine", created: now.addingTimeInterval(-day))])
        let reader = reader(server, defaults: defaults())

        async let first = reader.pullRequests(now: now)
        async let second = reader.pullRequests(now: now)
        let (a, b) = await (first, second)
        #expect(a.items.map { $0.key.number } == [1])
        #expect(b.items.map { $0.key.number } == [1])
        let once = server.requests.count
        #expect(once > 0)

        _ = await reader.pullRequests(now: now.addingTimeInterval(30))
        #expect(server.requests.count == once)
        _ = await reader.pullRequests(now: now.addingTimeInterval(Double(AzureDevOpsReader.freshFor) + 1))
        #expect(server.requests.count > once)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    }

    @Test func watchesAPullRequestOnceItReadsIt() async throws {
        let now = Date()
        let server = StubServer()
        server.serveOrganization()
        server.on("/_apis/git/pullrequests/77", json: Fixture.pullRequest(77, title: "Theirs", author: People.sam))
        server.on("/_apis/git/pullrequests/78") { _ in .status(404) }
        let defaults = defaults()
        let announced = Announcements()
        let agent = AzureDevOpsAgent(reader: reader(server, defaults: defaults, announced: announced))

        let watched = try await agent.watch(.string("https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/77"), now: now)
        #expect(watched == "BriefBar watches !77 “Theirs” in contoso now, and lists it until it closes or you stop watching it.")
        #expect(announced.value == 1)
        let list = try await agent.pullRequests(group: nil, now: now)
        #expect(list.contains("!77 “Theirs” in shop-web (by Sam Rivera, watched)"))

        // One that's gone isn't watched after all.
        await #expect(throws: MCPToolError("BriefBar didn't watch !78: it's closed, or you can't read it.")) {
            try await agent.watch(.string("https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/78"), now: now)
        }
        let links = try JSONDecoder().decode([PullRequestLink].self, from: try #require(defaults.data(forKey: SettingsKey.watchedPullRequests)))
        #expect(links.map(\.number) == [77])
        #expect(announced.value == 3)
    }

    @Test func writesTheFixBuildPromptWithTheRunsErrors() async throws {
        let now = Date()
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1, title: "Mine", created: now.addingTimeInterval(-day))])
        server.on("/_apis/policy/evaluations", query: ["artifactId": "vstfs:///CodeReview/CodeReviewId/p1/1"], json: Fixture.list([
            Fixture.evaluation("Build", status: "rejected", settings: ["displayName": "web-ci"], context: ["buildId": 4, "isExpired": false]),
        ]))
        server.on("/p1/_apis/build/builds/4/timeline", json: WorkFixture.timeline([
            WorkFixture.record("s", "Stage", "Test", result: "failed"),
            WorkFixture.record("t", "Task", "Run unit tests", parent: "s", result: "failed", issues: [
                ["type": "error", "message": "2 tests failed in CheckoutTests."],
                ["type": "error", "message": "CheckoutTests.testTotal: expected 10, got 9"],
            ]),
        ]))
        let agent = AzureDevOpsAgent(reader: reader(server, defaults: defaults()))

        let prompt = try await agent.prompt(.int(1), action: .string("fix_build"), now: now)
        #expect(prompt.contains("1. web-ci: https://dev.azure.com/contoso/Shop/_build/results?buildId=4"))
        #expect(prompt.contains("   - CheckoutTests.testTotal: expected 10, got 9"))
        #expect(prompt.contains("Work on its branch in a clone of shop-web"))
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func saysWhyItCantRead() async {
        let server = StubServer()
        let agent = AzureDevOpsAgent(reader: AzureDevOpsReader(
            demo: false, organizations: [], defaults: defaults(), client: server.client(tokens: FakeTokens(server.id, error: .signedOut("")))
        ) {})
        do {
            _ = try await agent.needsYou()
            Issue.record("Read without signing in")
        } catch let error as MCPToolError {
            #expect(error.description == "Sign in to the Azure CLI to see your pull requests. Run az login, then ask again.")
        } catch {
            Issue.record("Unexpected \(error)")
        }
    }

    @Test func pinsAndUnpinsPipelinesByTheirLinks() async throws {
        let server = StubServer()
        server.on("/contoso/Shop/_apis/build/definitions/12", json: [
            "id": 12, "name": "web-ci", "path": "\\CI", "project": ["id": "p1", "name": "Shop"],
        ])
        let defaults = defaults()
        let announced = Announcements()
        let agent = AzureDevOpsAgent(reader: reader(server, defaults: defaults, announced: announced))

        #expect(try await agent.pin(.string("https://dev.azure.com/contoso/Shop/_build?definitionId=12")) == "Pinned “web-ci”.")
        #expect(try await agent.pin(.string("https://dev.azure.com/contoso/Shop/_build?definitionId=12")) == "“web-ci” is pinned already.")
        let pinned = try JSONDecoder().decode([PipelineRef].self, from: try #require(defaults.data(forKey: SettingsKey.pinnedPipelines)))
        #expect(pinned.map(\.definitionId) == [12])
        #expect(try await agent.unpin(.string("https://dev.azure.com/contoso/Shop/_build?definitionId=12")) == "Unpinned “web-ci”.")
        #expect(announced.value == 2)
    }
}
