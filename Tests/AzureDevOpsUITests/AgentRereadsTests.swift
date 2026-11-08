import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks
import Foundation
import Testing
@testable import AzureDevOpsUI

/// What Azure DevOps reads again, and when, as Copilot sessions say they changed things there.
@MainActor
@Suite(.opensNothing) struct AgentRereadsTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_791_979_200)
    }

    private static let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4102)
    private static let task = ItemRef.workItem(organization: "contoso", id: 5124)

    private static func updates(on: Bool = true) -> SessionUpdates {
        let defaults = MemoryDefaults()
        defaults.set(on, forKey: SessionUpdatesSetting.defaultsKey)
        return SessionUpdates(defaults: defaults, isDemo: false)
    }

    @Test func aBurstIsOnePassOfTheOrganizationsItReads() {
        var passes: [AgentRereads.Pass] = []
        let rereads = AgentRereads(updates: Self.updates(), organizations: { ["Contoso"] }) { passes.append($0) }
        rereads.receive([Self.pullRequest])
        rereads.receive([
            Self.task, .workItem(organization: "fabrikam", id: 1), .gitHubPullRequest(repository: "octo/app", number: 12),
            ItemRef.session("6f9619ff-8b86-d011-b42d-00c04fc964ff")!,
        ])
        rereads.pass()
        #expect(passes == [AgentRereads.Pass(pullRequests: [PRKey("contoso", 4102)], workItems: [WorkItemKey("contoso", 5124)])])
        rereads.pass()
        #expect(passes.count == 1)
        rereads.stop()
    }

    /// What Show Links looks up and the work item whose details show are read whichever organization they're in, so
    /// what sessions say they changed of those is taken; another organization's, once nothing reads it, isn't.
    @Test func takesWhatShowLinksAndTheDetailsReadInOtherOrganizations() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.organizations = ["Contoso"]
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .live)
        let sprint = SprintStore(settings: settings, mode: .live, client: store.client)
        let copilot = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        let links = Links(defaults: MemoryDefaults(), isDemo: false)
        links.setOn(true)
        let workLinks = WorkLinksStore(
            links: links, stories: ItemStories(links: links), store: store, sprint: sprint, copilot: copilot, settings: settings
        )
        // An engine with nothing to read, and no way to.
        workLinks.makeEngine = { onChange in LinkEngine(client: ADOClient(tokens: NoTokens()), onChange: onChange) }
        workLinks.start()
        defer { workLinks.stop() }
        // A Fabrikam bug a session works on, which Show Links looks up.
        let bug = ItemRef.workItem(organization: "fabrikam", id: 77)
        links.link(try #require(ItemRef.session("6f9619ff-8b86-d011-b42d-00c04fc964ff")), bug)
        try await until("Show Links looks it up") { workLinks.lookupOrganizations == ["fabrikam"] }
        // A Northwind story whose details show.
        let story = ItemRef.workItem(organization: "northwind", id: 31)
        let details = WorkItemDetailsStore(mode: .demo, client: store.client, board: Empty().eraseToAnyPublisher())
        details.show(try #require(WorkItemDetailsPanel.linkedItem(
            story, as: LinkedItem(ref: story, label: "31", title: "Retry payments", symbol: "doc.text", color: .blue)
        )))
        let rereads = AgentRereads(updates: Self.updates(), store: store, sprint: sprint, workLinks: workLinks, details: details, tags: nil)
        defer { rereads.stop() }

        rereads.receive([bug, story, .workItem(organization: "adatum", id: 9)])
        #expect(rereads.pending == AgentRereads.Pass(workItems: [WorkItemKey("fabrikam", 77), WorkItemKey("northwind", 31)]))

        links.setOn(false)
        details.close()
        try await until("Show Links stops") { workLinks.lookupOrganizations.isEmpty }
        rereads.receive([.workItem(organization: "fabrikam", id: 78), .workItem(organization: "northwind", id: 32)])
        #expect(rereads.pending.workItems.isDisjoint(with: [WorkItemKey("fabrikam", 78), WorkItemKey("northwind", 32)]))
    }

    /// A sprint has only its team's organization's work items: another's doesn't read it again, unless it doesn't know
    /// its team yet.
    @Test func theSprintIsReadAgainForWhatItMayHave() {
        let team = TeamRef(organization: "Contoso", projectId: "p1", projectName: "Shop", id: "t1", name: "Checkout")
        #expect(AgentRereads.sprintMayHave([WorkItemKey("contoso", 5124)], team: team))
        #expect(!AgentRereads.sprintMayHave([WorkItemKey("fabrikam", 77)], team: team))
        #expect(AgentRereads.sprintMayHave([WorkItemKey("fabrikam", 77)], team: nil))
        #expect(!AgentRereads.sprintMayHave([], team: nil))
    }

    @Test func passesAreThirtySecondsApartAtLeast() {
        let clock = Clock()
        let rereads = AgentRereads(updates: Self.updates(), organizations: { ["contoso"] }, now: { clock.now }) { _ in }
        #expect(rereads.delay(at: clock.now) == AgentRereads.gathering)
        rereads.receive([Self.pullRequest])
        rereads.pass()
        clock.now += 1
        #expect(rereads.delay(at: clock.now) == AgentRereads.spacing - 1)
        clock.now += 60
        #expect(rereads.delay(at: clock.now) == AgentRereads.gathering)
        rereads.stop()
    }

    @Test func nothingIsReadWhileItsOff() {
        var passes: [AgentRereads.Pass] = []
        let updates = Self.updates()
        let rereads = AgentRereads(updates: updates, organizations: { ["contoso"] }) { passes.append($0) }
        rereads.receive([Self.pullRequest])
        updates.setOn(false)
        rereads.pass()
        rereads.receive([Self.task])
        rereads.pass()
        #expect(passes.isEmpty)
        rereads.stop()
    }

    /// Turned off and on again while a pass waits, it forgets what that pass would have read, as it forgets what sessions
    /// asked before: only what they ask after is read.
    @Test func turningItOffAndOnForgetsWhatWaitsForItsPass() async throws {
        var passes: [AgentRereads.Pass] = []
        let updates = Self.updates()
        let rereads = AgentRereads(
            updates: updates, organizations: { ["contoso"] }, gathering: 0.05, spacing: 10
        ) { passes.append($0) }.started()
        rereads.receive([Self.pullRequest])
        updates.setOn(false)
        updates.setOn(true)
        rereads.receive([Self.task])
        // For as long as a busy machine could need.
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while passes.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(passes == [AgentRereads.Pass(workItems: [WorkItemKey("contoso", 5124)])])
        rereads.stop()
    }

    @Test func itReadsOnceWhatGathersAndHearsWhatAgentsAsk() async throws {
        var passes: [AgentRereads.Pass] = []
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: SessionUpdatesSetting.defaultsKey)
        let updates = SessionUpdates(defaults: defaults, isDemo: false)
        let rereads = AgentRereads(
            updates: updates, organizations: { ["contoso"] }, gathering: 0.05, spacing: 10
        ) { passes.append($0) }.started()
        RereadRequests.add([Self.pullRequest, Self.task], id: "this", to: defaults, now: Date().addingTimeInterval(1))
        updates.agentChanged()
        // For as long as a busy machine could need.
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while passes.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(passes == [AgentRereads.Pass(pullRequests: [PRKey("contoso", 4102)], workItems: [WorkItemKey("contoso", 5124)])])
        rereads.stop()
    }

    private struct NoTokens: AccessTokenProvider {
        struct Unused: Error {}
        func token(tenant: String?) async throws -> AccessToken { throw Unused() }
        func invalidate(tenant: String?) async {}
    }
}

private struct Timeout: Error, CustomStringConvertible {
    let description: String
}

/// Lets the stores take what they're told until `condition` holds.
@MainActor
private func until(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: waitLimit)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw Timeout(description: "Timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(2))
    }
}
