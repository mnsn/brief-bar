import Foundation
import Testing
@testable import AzureDevOpsCore

/// A pull request's tags: as its lists carry them, read on their own, what adding one suggests, and the tags you added, which
/// BriefBar remembers; and what the engine does with them, so a read that started before a change never undoes it.
@Suite struct PullRequestTagsTests {
    // MARK: Reading them

    /// As lists carry them: the active ones, once each, by name; left out when it has none; unknown when what they say about
    /// them can't be read; a tag that can't be read is left out.
    @Test func readsTagsAsListsCarryThem() throws {
        var json = Fixture.pullRequest(7)
        json["labels"] = [
            ["id": "b2", "name": "Hotfix", "active": true],
            ["id": "a1", "name": "deploy-eu", "active": true, "url": NSNull()],
            ["id": "c3", "name": "retired", "active": false],
            ["id": "d4", "name": "HOTFIX"],
            ["id": "e5"],
            ["name": "   "],
            ["id": "f6", "name": " release-10 "],
            ["name": "release-9"],
        ]
        let dto = try Fixture.decode(ADOPullRequest.self, json)
        let tags = try #require(PullRequestTag.listed(dto.labels))
        #expect(tags.map(\.name) == ["deploy-eu", "Hotfix", "release-9", "release-10"])
        #expect(tags.map(\.tagId) == ["a1", "b2", nil, "f6"])

        // None: a list leaves them out.
        let none = try Fixture.decode(ADOPullRequest.self, Fixture.pullRequest(8))
        #expect(none.labels == nil)
        #expect(PullRequestTag.listed(none.labels) == [])
        // What isn't a list, and isn't nothing, leaves them unknown, and the pull request read all the same.
        var odd = Fixture.pullRequest(9)
        odd["labels"] = ["name": "deploy-eu"]
        let oddly = try Fixture.decode(ADOPullRequest.self, odd)
        #expect(oddly.pullRequestId == 9)
        #expect(PullRequestTag.listed(oddly.labels) == nil)
        var null = Fixture.pullRequest(10)
        null["labels"] = NSNull()
        #expect(PullRequestTag.listed(try Fixture.decode(ADOPullRequest.self, null).labels) == [])
    }

    @Test func namesATagAsYouTypedIt() {
        #expect(PullRequestTag.name("  deploy-eu \n") == "deploy-eu")
        #expect(PullRequestTag.name("deploy\neu") == "deploy eu")
        #expect(PullRequestTag.name(" \n ") == nil)
        #expect(PullRequestTag.name("") == nil)
    }

    /// Ignoring letter case, numbers by their value; told apart by name, ignoring letter case, whatever their IDs.
    @Test func ordersAndComparesTagsByName() {
        let tags = ["release-10", "Deploy-US", "release-9", "deploy-eu"].map { PullRequestTag($0) }
        #expect(PullRequestTag.sorted(tags).map(\.name) == ["deploy-eu", "Deploy-US", "release-9", "release-10"])
        #expect(PullRequestTag.same([PullRequestTag("A", tagId: "1"), PullRequestTag("b")], [PullRequestTag("B"), PullRequestTag("a")]))
        #expect(!PullRequestTag.same([PullRequestTag("a")], [PullRequestTag("a"), PullRequestTag("b")]))
        #expect(PullRequestTag.same(nil, nil))
        #expect(!PullRequestTag.same(nil, []))
        // Added as Azure DevOps spells it, in place of one of that name; taken off by name.
        let added = PullRequestTag.adding(PullRequestTag("Hotfix", tagId: "h"), to: [PullRequestTag("hotfix"), PullRequestTag("deploy-eu")])
        #expect(added == [PullRequestTag("deploy-eu"), PullRequestTag("Hotfix", tagId: "h")])
        #expect(PullRequestTag.removing(PullRequestTag("HOTFIX"), from: added) == [PullRequestTag("deploy-eu")])
    }

    @Test func readsAPullRequestsTagsOnTheirOwnWithAGet() async throws {
        let address = PullRequestAddress(makePR(7))
        #expect(ADOEndpoint.tags(of: address).absoluteString
            == "https://dev.azure.com/contoso/p1/_apis/git/repositories/r1/pullRequests/7/labels?api-version=7.1")
        let server = StubServer()
        server.on("/pullRequests/7/labels", json: Fixture.list([
            ["id": "b2", "name": "needs-qa", "active": true, "url": "https://example.invalid/b2"],
            ["id": "a1", "name": "deploy-eu", "active": true],
            ["id": "c3", "name": "old", "active": false],
        ]))
        let tags = try await server.client().tags(of: address)
        #expect(tags == [PullRequestTag("deploy-eu", tagId: "a1"), PullRequestTag("needs-qa", tagId: "b2")])
        #expect(server.requests.map(\.httpMethod) == ["GET"])
    }

    // MARK: What adding one suggests

    /// With nothing typed: the tags you added in the project, the latest first, then the pull requests', the most used first,
    /// then by name; but the pull request's own.
    @Test func suggestsTheTagsYouAddedFirstThenTheMostUsed() {
        let seen: [[PullRequestTag]] = [["deploy-eu", "hotfix"], ["deploy-eu", "Deploy-EU"], ["deploy-us"], ["zeta"], ["alpha"]]
            .map { $0.map { PullRequestTag($0) } }
        let choices = TagChoices(typed: "", used: ["needs-qa", "deploy-us"], seen: seen, current: [PullRequestTag("Hotfix")])
        #expect(choices.suggestions == ["needs-qa", "deploy-us", "deploy-eu", "alpha", "zeta"])
        #expect(choices.newTag == nil)
        #expect(choices.alreadyOn == nil)
        #expect(choices.rows == choices.suggestions)
    }

    /// Those that start with what you typed first, then those with a word that does, then those that have it anywhere,
    /// ignoring letter case; spelled as the pull requests have them.
    @Test func matchesWhatYouTypedAtTheStartThenAWordThenAnywhere() {
        let seen = [["deploy-eu", "eu-west", "neutral", "Europe", "asia"].map { PullRequestTag($0) }]
        let choices = TagChoices(typed: "EU", used: ["europe"], seen: seen, current: [])
        #expect(choices.suggestions == ["Europe", "eu-west", "deploy-eu", "neutral"])
        #expect(choices.newTag == "EU")
        #expect(TagChoices.match("deploy-eu", "eu") == 1)
        #expect(TagChoices.match("deploy_eu", "eu") == 1)
        #expect(TagChoices.match("deployeu", "eu") == 2)
        #expect(TagChoices.match("asia", "eu") == nil)
    }

    /// What you typed is a new tag, unless it's a suggestion, or the pull request has it, ignoring letter case.
    @Test func offersWhatYouTypedAsANewTag() {
        let seen = [["deploy-us", "deploy-eu"].map { PullRequestTag($0) }]
        let current = [PullRequestTag("deploy-eu")]
        let partial = TagChoices(typed: " dep ", used: [], seen: seen, current: current)
        #expect(partial.suggestions == ["deploy-us"])
        #expect(partial.newTag == "dep")
        #expect(partial.rows == ["deploy-us", "dep"])
        let whole = TagChoices(typed: "DEPLOY-US", used: [], seen: seen, current: current)
        #expect(whole.suggestions == ["deploy-us"])
        #expect(whole.newTag == nil)
        let had = TagChoices(typed: "Deploy-EU", used: [], seen: seen, current: current)
        #expect(had.alreadyOn == "deploy-eu")
        #expect(had.newTag == nil)
        #expect(had.rows.isEmpty)
        #expect(TagChoices(typed: "  ", used: [], seen: [], current: []).newTag == nil)
    }

    @Test func suggestsAFewAtMost() {
        let seen = [(1...10).map { PullRequestTag("tag-\($0)") }]
        #expect(TagChoices(typed: "", used: [], seen: seen, current: []).suggestions
            == ["tag-1", "tag-2", "tag-3", "tag-4", "tag-5", "tag-6"])
        #expect(TagChoices(typed: "tag", used: [], seen: seen, current: [], limit: 2).suggestions == ["tag-1", "tag-2"])
    }

    // MARK: The tags you added

    @Test func remembersTheTagsYouAddedForEachProject() throws {
        var used = UsedTags()
        #expect(used.isEmpty)
        used.add("deploy-eu", organization: "Contoso", projectId: "P1")
        used.add("hotfix", organization: "contoso", projectId: "p1")
        used.add(" Deploy-EU ", organization: "contoso", projectId: "p1")
        used.add("   ", organization: "contoso", projectId: "p1")
        used.add("needs-qa", organization: "contoso", projectId: "p2")
        #expect(used.tags(organization: "CONTOSO", projectId: "p1") == ["Deploy-EU", "hotfix"])
        #expect(used.tags(organization: "contoso", projectId: "p2") == ["needs-qa"])
        #expect(used.tags(organization: "fabrikam", projectId: "p1") == [])
        // The project you added a tag in last comes first.
        #expect(used.projects.map(\.project) == ["contoso/p2", "contoso/p1"])

        // Up to 20 for each project, and for 20 projects: the latest.
        for index in 1...25 { used.add("tag-\(index)", organization: "contoso", projectId: "p1") }
        let kept = used.tags(organization: "contoso", projectId: "p1")
        #expect(kept.count == UsedTags.tagsPerProject)
        #expect(kept.first == "tag-25")
        for index in 1...25 { used.add("t", organization: "contoso", projectId: "project-\(index)") }
        #expect(used.projects.count == UsedTags.projectLimit)
        #expect(used.tags(organization: "contoso", projectId: "p1").isEmpty)

        let saved = try JSONDecoder().decode(UsedTags.self, from: JSONEncoder().encode(used))
        #expect(saved == used)
    }

    @Test func madeUpTagsComeWithMadeUpIDs() {
        #expect(DemoTags.tags(of: 4102).map(\.name) == ["deploy-eu", "needs-qa"])
        #expect(DemoTags.tags(of: 4102).allSatisfy { $0.tagId?.hasPrefix("demo-tag-") == true })
        #expect(DemoTags.tags(of: 1).isEmpty)
        #expect(DemoData.snapshot().records.first { $0.id.number == 4091 }?.tags?.map(\.name) == ["deploy-eu", "deploy-us", "hotfix"])
        // Every made-up pull request's are known.
        #expect(DemoData.snapshot().records.allSatisfy { $0.tags != nil })
    }

    // MARK: The engine

    private static func labels(_ names: [String]) -> [[String: Any]] {
        names.map { ["id": "id-\($0)", "name": $0, "active": true] }
    }

    private static func pullRequest(_ id: Int, author: Person = People.me, tags: [String]?) -> [String: Any] {
        var json = Fixture.pullRequest(id, author: author)
        if let tags { json["labels"] = labels(tags) }
        return json
    }

    private func tags(_ snapshot: PulseSnapshot?, _ number: Int) -> [String]? {
        snapshot?.records.first { $0.id == PRKey(Fixture.org, number) }?.tags?.map(\.name)
    }

    /// Your lists carry your pull requests' tags, and those you review: one without is one with none.
    @Test func listsCarryPullRequestsTags() async {
        let server = StubServer()
        server.serveOrganization(
            mine: [Self.pullRequest(1, tags: ["needs-qa", "deploy-eu"])],
            reviewing: [Self.pullRequest(2, author: People.sam, tags: nil)],
            completed: [{
                var done = Self.pullRequest(3, tags: ["hotfix"])
                done["status"] = "completed"
                done["closedDate"] = iso(Date().addingTimeInterval(-hour))
                return done
            }()]
        )
        let snapshot = await PulseEngine.loadOnce(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org]))
        #expect(tags(snapshot, 1) == ["deploy-eu", "needs-qa"])
        #expect(tags(snapshot, 2) == [])
        #expect(tags(snapshot, 3) == ["hotfix"])
        #expect(!server.requests.contains { $0.url?.path.hasSuffix("/labels") == true })
    }

    /// A pull request sent to you, read on its own, has no tags until they're read, one request: then they stay, as its own
    /// read doesn't carry them.
    @Test func aPullRequestReadOnItsOwnHasItsTagsReadOnce() async throws {
        let server = StubServer()
        server.serveOrganization()
        server.on("/contoso/_apis/git/pullrequests/9", json: Fixture.pullRequest(9, author: People.sam))
        server.on("/pullRequests/9/labels", json: Fixture.list(Self.labels(["deploy-us"])))
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])) { _ in }
        let key = PRKey(Fixture.org, 9)
        await engine.setLinkedPullRequests([key])
        await engine.refreshNow()
        #expect(await engine.currentSnapshot().records.contains { $0.id == key })
        #expect(tags(await engine.currentSnapshot(), 9) == nil)

        guard case .success(let read) = await engine.readTags(key) else {
            Issue.record("Expected its tags")
            return
        }
        #expect(read.map(\.name) == ["deploy-us"])
        #expect(tags(await engine.currentSnapshot(), 9) == ["deploy-us"])
        await engine.refreshNow()
        #expect(tags(await engine.currentSnapshot(), 9) == ["deploy-us"])
        #expect(server.requests.filter { $0.url?.path.hasSuffix("/pullRequests/9/labels") == true }.count == 1)
        // Not one it doesn't list.
        guard case .failure(.notFound) = await engine.readTags(PRKey(Fixture.org, 99)) else {
            Issue.record("Expected nothing read")
            return
        }
    }

    /// Tags changed show at once, as Azure DevOps answered, then as it has them, read again: with a change someone made
    /// meanwhile.
    @Test func changedTagsShowAtOnceAndAreReadAgain() async throws {
        let server = StubServer()
        server.serveOrganization(mine: [Self.pullRequest(1, tags: ["deploy-eu"])])
        server.on("/pullRequests/1/labels", json: Fixture.list(Self.labels(["deploy-eu", "hotfix", "needs-qa"])))
        let collector = SnapshotCollector()
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])) {
            collector.add($0)
        }
        await engine.refreshNow()
        let published = collector.count
        await engine.changedTags(PRKey(Fixture.org, 1), to: [PullRequestTag("hotfix", tagId: "id-hotfix"), PullRequestTag("deploy-eu")])
        let first = try #require(collector.all.dropFirst(published).first)
        #expect(tags(first, 1) == ["deploy-eu", "hotfix"])
        #expect(tags(await engine.currentSnapshot(), 1) == ["deploy-eu", "hotfix", "needs-qa"])
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    /// A list that was read before a change, and answers as the tags were, doesn't undo it; one read after it is taken, as it
    /// may have a change made since.
    @Test(.timeLimit(.minutes(1)))
    func aListReadThatStartedBeforeAChangeDoesntUndoIt() async throws {
        let server = StubServer()
        server.serveOrganization(mine: [Self.pullRequest(1, tags: ["deploy-eu"])])
        let collector = SnapshotCollector()
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])) {
            collector.add($0)
        }
        await engine.refreshNow()

        // The next read of your list is slow, and answers as the tags were before the change; later ones, as someone left them
        // since.
        let before = StubServer.Reply.json(Fixture.list([Self.pullRequest(1, tags: ["deploy-eu"])]))
        let later = StubServer.Reply.json(Fixture.list([Self.pullRequest(1, tags: ["deploy-us"])]))
        let reads = Locked(0)
        server.on("/contoso/_apis/git/pullrequests", query: ["searchCriteria.creatorId": Fixture.me, "searchCriteria.status": "active"]) { _ in
            guard reads.increment() == 1 else { return later }
            Thread.sleep(forTimeInterval: 0.3)
            return before
        }
        server.on("/pullRequests/1/labels", json: Fixture.list(Self.labels(["deploy-eu", "hotfix"])))
        let refresh = Task { await engine.refreshNow() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: waitLimit)
        while reads.value < 1, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reads.value >= 1)
        let published = collector.count
        await engine.changedTags(PRKey(Fixture.org, 1), to: [PullRequestTag("deploy-eu"), PullRequestTag("hotfix")])
        await refresh.value

        let since = collector.all.dropFirst(published)
        #expect(!since.isEmpty)
        #expect(since.allSatisfy { tags($0, 1) == ["deploy-eu", "hotfix"] })
        // Read after the change, the list has the tags as they are now.
        await engine.refreshNow()
        #expect(tags(await engine.currentSnapshot(), 1) == ["deploy-us"])
    }
}
