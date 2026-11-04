import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// What Azure DevOps reads again, and when, as Copilot sessions say they changed things there.
@MainActor
@Suite struct AgentRereadsTests {
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
}
