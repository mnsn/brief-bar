import BriefBarCore
import Foundation
import Testing
@testable import CopilotTasks

/// BriefBar's checks and changes reach the Copilot CLI one at a time, in the order they were asked for, and the Agents page
/// shows what the last one found, once it's done.
@Suite struct CopilotCLIProgressTests {
    @Test func showsTheLastAnswerOnceEverythingIsDone() {
        var progress = CopilotCLIProgress<CopilotMCPRegistration.Status>()
        #expect(!progress.isWorking)
        #expect(progress.status == nil)
        let check = progress.ask()
        let change = progress.ask()
        #expect(progress.isWorking)
        progress.answer(check, with: .absent)
        // The change is still to come, so what the check found isn't what the CLI has.
        #expect(progress.isWorking)
        #expect(progress.status == nil)
        progress.answer(change, with: .added(enabled: true))
        #expect(!progress.isWorking)
        #expect(progress.status == .added(enabled: true))

        #expect(CopilotCLIProgress<CopilotMCPRegistration.Status>(status: .absent).status == .absent)
    }

    /// The page shows, so BriefBar asks the CLI what it has, and agents are turned off before it answers: what the checks
    /// found, that BriefBar is still there, isn't what turning agents off left, as the removals are still to come.
    @Test func aCheckThatEndsBeforeTurningOffIsntALeftover() {
        var server = CopilotCLIProgress<CopilotMCPRegistration.Status>()
        var plugin = CopilotCLIProgress<CopilotPluginRegistration.Status>()
        let checkServer = server.ask()
        let checkPlugin = plugin.ask()
        let removeServer = server.ask()
        let removePlugin = plugin.ask()

        server.answer(checkServer, with: .added(enabled: true))
        plugin.answer(checkPlugin, with: .installed(enabled: true))
        #expect(server.isWorking && plugin.isWorking)
        #expect(AgentCleanup.left(server: server, plugin: plugin) == nil)

        server.answer(removeServer, with: .absent)
        #expect(AgentCleanup.left(server: server, plugin: plugin) == nil)

        plugin.answer(removePlugin, with: .failed("Timed out after 30 seconds"))
        #expect(AgentCleanup.left(server: server, plugin: plugin) == AgentCleanup(server: .absent, plugin: .failed("Timed out after 30 seconds")))
    }

    @Test func nothingIsLeftOnceItsGone() {
        var server = CopilotCLIProgress<CopilotMCPRegistration.Status>()
        var plugin = CopilotCLIProgress<CopilotPluginRegistration.Status>()
        // Agents were off when BriefBar started: it hasn't asked the CLI anything.
        #expect(AgentCleanup.left(server: server, plugin: plugin) == nil)
        let removeServer = server.ask()
        let removePlugin = plugin.ask()
        server.answer(removeServer, with: .absent)
        plugin.answer(removePlugin, with: .absent)
        #expect(AgentCleanup.left(server: server, plugin: plugin) == nil)
    }
}
