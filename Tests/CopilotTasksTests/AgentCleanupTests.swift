import BriefBarCore
import Foundation
import Testing
@testable import CopilotTasks

/// What turning agents off left in the Copilot CLI, which the Agents page shows while agents are off, with Try Again.
@Suite struct AgentCleanupTests {
    @Test func reportsOnlyWhatsLeftOfBriefBars() {
        #expect(AgentCleanup(server: .absent, plugin: .absent).isDone)
        // Still removing them.
        #expect(AgentCleanup(server: nil, plugin: nil).isDone)
        // Without a Copilot CLI there's nothing to remove, and what isn't BriefBar's was never its to remove.
        #expect(AgentCleanup(server: .noCLI, plugin: .noCLI).isDone)
        #expect(AgentCleanup(server: .taken, plugin: .taken).isDone)

        let failed = AgentCleanup(server: .failed("Couldn't read the settings"), plugin: .failed("It timed out."))
        #expect(!failed.isDone)
        #expect(failed.server == "Couldn't read the settings")
        #expect(failed.plugin == "It timed out.")

        let stillThere = AgentCleanup(server: .added(enabled: true), plugin: .installedElsewhere("/tmp/BriefBar.app/Contents/Resources/CopilotPlugin"))
        #expect(stillThere.server == "The Copilot CLI still has it.")
        #expect(stillThere.plugin == "The Copilot CLI still has it.")
        #expect(AgentCleanup(server: .addedElsewhere("/tmp/BriefBar"), plugin: .installed(enabled: false)) == stillThere)
    }

    /// The CLI can't remove the plugin's marketplace when agents are turned off, so the page says why; Try Again removes
    /// what's left, and then nothing is.
    @Test func tryingAgainRemovesWhatsLeft() async {
        var state = CopilotPluginRegistrationTests.installed()
        state.failures[["plugin", "marketplace", "remove"]] = "Timed out after 30 seconds"
        let cli = CopilotPluginRegistrationTests.CLI(state)

        let turnedOff = await cli.registration().remove()
        #expect(turnedOff == .failed("Timed out after 30 seconds"))
        let left = AgentCleanup(server: .absent, plugin: turnedOff)
        #expect(!left.isDone)
        #expect(left.server == nil)
        #expect(left.plugin == "Timed out after 30 seconds")
        // Turned off already, so that it stays off whatever happens next.
        #expect(cli.current.plugins == ["briefbar@briefbar": false])

        let again = await cli.registration().remove()
        #expect(again == .absent)
        #expect(AgentCleanup(server: .absent, plugin: again).isDone)
        #expect(cli.current == CopilotPluginRegistrationTests.State(plugins: ["briefbar@briefbar": false]))
    }

    /// When a plugin the CLI copied keeps the marketplace there, what's left says which, as the CLI does, since Try Again
    /// can't remove it until the user deals with that plugin; then it does.
    @Test func theLeftoverNamesWhatKeepsItThere() async throws {
        var state = CopilotPluginRegistrationTests.installed()
        state.plugins["helper@briefbar"] = true
        state.copied = ["helper@briefbar"]
        let cli = CopilotPluginRegistrationTests.CLI(state)

        let turnedOff = await cli.registration().remove()
        let left = AgentCleanup(server: .absent, plugin: turnedOff)
        let why = try #require(left.plugin)
        #expect(why.hasPrefix("Cannot remove marketplace \"briefbar\"."))
        #expect(why.contains("Installed plugins from this marketplace: helper"))
        #expect(await cli.registration().remove() == turnedOff)

        cli.run(["plugin", "uninstall", "helper@briefbar"])
        let again = await cli.registration().remove()
        #expect(again == .absent)
        #expect(AgentCleanup(server: .absent, plugin: again).isDone)
    }
}
