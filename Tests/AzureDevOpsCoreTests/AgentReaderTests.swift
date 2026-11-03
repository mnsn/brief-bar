import AzureDevOpsCore
import BriefBarUI
import Foundation
import SQLite3
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

    /// `pull_request` names the session BriefBar sends the pull request's work to, as its Send to Copilot window would,
    /// while Send Work to Copilot is on: here, one of the Copilot app's on its branch, made up, in a folder of its own.
    @Test func namesTheSessionItsWorkGoesTo() async throws {
        // In whole seconds, as the app's database keeps its times to the millisecond.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1, title: "Mine", created: now.addingTimeInterval(-day))])
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarAgentSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "44444444-4444-4444-8444-444444444444"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let updated = formatter.string(from: now.addingTimeInterval(-300))
        var handle: OpaquePointer?
        try #require(sqlite3_open(home.appendingPathComponent("data.db").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        // What the Copilot app's session list reads: a session in a clone of shop-web, on the pull request's branch. In one
        // transaction, written at once.
        try #require(sqlite3_exec(handle, """
            BEGIN;
            CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, github_owner TEXT, github_repo TEXT, main_repo_path TEXT);
            CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, title TEXT, session_type TEXT NOT NULL, mode TEXT,
                is_running INTEGER NOT NULL DEFAULT 0, was_interrupted INTEGER NOT NULL DEFAULT 0, interruption_reason TEXT,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT);
            CREATE TABLE workspaces (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL, session_id TEXT, branch TEXT NOT NULL,
                name TEXT NOT NULL, creator_session_id TEXT, archived_at TEXT, updated_at TEXT NOT NULL,
                source_pr_repo_full_name TEXT, source_pr_number INTEGER, source_pr_html_url TEXT,
                created_pr_repo_full_name TEXT, created_pr_number INTEGER, created_pr_html_url TEXT);
            CREATE TABLE workspace_pull_request_links (workspace_id TEXT PRIMARY KEY NOT NULL, uri TEXT NOT NULL);
            INSERT INTO projects (id, name) VALUES ('shop', 'shop-web');
            INSERT INTO sessions (id, title, session_type, created_at, updated_at) VALUES ('\(id)', 'Fix the total', 'project', '\(updated)', '\(updated)');
            INSERT INTO workspaces (id, project_id, session_id, branch, name, updated_at) VALUES ('w', 'shop', '\(id)', 'fix-total', 'Fix the total', '\(updated)');
            COMMIT;
            """, nil, nil, nil) == SQLITE_OK)
        func agent(sending: Bool) -> AzureDevOpsAgent {
            let defaults = defaults()
            defaults.set(sending, forKey: SettingsKey.copilotEnabled)
            return AzureDevOpsAgent(reader: AzureDevOpsReader(
                demo: false, organizations: [], defaults: defaults, client: server.client(), appHome: home
            ) {})
        }

        // Only while Send Work to Copilot is on, as its window reads sessions only then.
        #expect(!(try await agent(sending: false).pullRequest(.int(1), now: now)).contains("Its session"))
        let text = try await agent(sending: true).pullRequest(.int(1), now: now)
        #expect(text.contains("""
            Its session, where BriefBar sends its work unless you choose another: “Fix the total”, in the Copilot app, on its branch.
              shop-web · fix-total · active 5m ago · session \(id)
            """))
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
            #expect(error.description == "Sign in to the Azure CLI to see your pull requests. Run az login --allow-no-subscriptions, then ask again.")
        } catch {
            Issue.record("Unexpected \(error)")
        }
    }

    /// An agent has no Sign In button: it's told what to run, with the directory's ID, which signing in needs.
    @Test func saysWhatToRunForAnOrganizationInAnotherDirectory() async {
        let now = Date()
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1, title: "Mine", created: now.addingTimeInterval(-day))])
        server.serveOrganization("fabrikam")
        server.put("fabrikam", in: Tenants.other)
        let reader = AzureDevOpsReader(
            demo: false, organizations: [], defaults: defaults(organizations: [Fixture.org, "fabrikam"]),
            client: server.client(tokens: FakeTokens(server.id, tenant: Tenants.home))
        ) {}
        let read = await reader.pullRequests(now: now)
        #expect(read.items.map { $0.key.number } == [1])
        #expect(read.problem == "fabrikam is in a directory your Azure CLI isn't signed in to. Run az login --tenant \(Tenants.other) --allow-no-subscriptions, then ask again in a minute.")
        // The others were read: calls within the minute share that read, as when any organization can't be read.
        let once = server.requests.count
        _ = await reader.pullRequests(now: now.addingTimeInterval(30))
        #expect(server.requests.count == once)
    }

    /// With no organizations chosen, an agent's reader finds yours: one in a directory to sign in to is looked in again at
    /// each read, so signing in there finds your pull requests there, rather than never for the session.
    @Test func findsYourOrganizationInAnotherDirectoryOnceSignedInThere() async {
        let now = Date()
        let server = StubServer()
        server.on("/_apis/profile/profiles/me", json: ["id": "profile-id", "publicAlias": "alias"])
        server.on("/_apis/accounts", query: ["memberId": "alias"], json: Fixture.list([["accountName": "fabrikam"]]))
        server.serveOrganization("fabrikam", mine: [Fixture.pullRequest(1, title: "Mine", created: now.addingTimeInterval(-day))])
        server.put("fabrikam", in: Tenants.other)
        let tokens = FakeTokens(server.id, tenant: Tenants.home)
        let reader = AzureDevOpsReader(
            demo: false, organizations: [], defaults: defaults(organizations: []), client: server.client(tokens: tokens)
        ) {}
        #expect(await reader.pullRequests(now: now).items.isEmpty)
        await tokens.signIn(to: Tenants.other)
        let read = await reader.pullRequests(now: now.addingTimeInterval(Double(AzureDevOpsReader.freshFor) + 1))
        #expect(read.items.map(\.key) == [PRKey("fabrikam", 1)])
    }

    /// A work item asked for by its number may be in any of your organizations: one in a directory to sign in to doesn't
    /// stop the others being looked in, and is named only when none of them has it.
    @Test func looksForAWorkItemPastAnOrganizationInAnotherDirectory() async throws {
        let server = StubServer()
        server.put("fabrikam", in: Tenants.other)
        server.on("/\(Fixture.org)/_apis/wit/workitems/5", json: WorkFixture.workItem(5, "Task", "Show saved items"))
        let reader = AzureDevOpsReader(
            demo: false, organizations: [], defaults: defaults(organizations: ["fabrikam", Fixture.org]),
            client: server.client(tokens: FakeTokens(server.id, tenant: Tenants.home))
        ) {}
        let read = try await reader.workItem(5, organization: nil)
        #expect(read.item.id == 5)
        #expect(read.item.organization == Fixture.org)
        await #expect(throws: MCPToolError(
            "fabrikam is in a directory your Azure CLI isn't signed in to. Run az login --tenant \(Tenants.other) --allow-no-subscriptions, then ask again."
        )) {
            try await reader.workItem(6, organization: nil)
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

/// The projects the Add Pipelines sheet searches in, as the app reads them: those of an organization in a directory to
/// sign in to are said to be missing, with a way to sign in there.
@MainActor
@Suite struct PipelineProjectsTests {
    @Test func saysWhichOrganizationsProjectsWaitOnASignIn() async {
        let server = StubServer()
        server.on("/contoso/_apis/projects", json: Fixture.list([["id": "p1", "name": "Shop"]]))
        server.put("fabrikam", in: Tenants.other)
        let defaults = MemoryDefaults()
        defaults.set([Fixture.org, "fabrikam"], forKey: SettingsKey.organizations)
        let pipelines = PipelinesStore(
            settings: AppSettings(defaults: defaults), mode: .live, client: server.client(tokens: FakeTokens(server.id, tenant: Tenants.home))
        )
        let (projects, problem) = await pipelines.allProjects()
        #expect(projects.map(\.name) == ["Shop"])
        #expect(problem == .otherDirectory(organizations: ["fabrikam"], tenant: Tenants.other, others: nil))
    }
}
