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

    /// Turning agents off removes BriefBar's extension for the app's sessions too: what's left of it says why, once
    /// BriefBar is done trying.
    @Test func reportsWhatsLeftOfTheSessionsExtension() {
        let left = AgentCleanup(server: .absent, plugin: .absent, sessionPrompts: .failed("It timed out."))
        #expect(!left.isDone)
        #expect(left.sessionPrompts == "It timed out.")
        #expect(AgentCleanup(server: .absent, plugin: .absent, sessionPrompts: .installed(enabled: true)).sessionPrompts
            == "The Copilot CLI still has it.")
        #expect(AgentCleanup(server: .absent, plugin: .absent, sessionPrompts: .absent).isDone)

        let done = CopilotCLIProgress<CopilotPluginRegistration.Status>(status: .absent)
        var removing = CopilotCLIProgress<CopilotPluginRegistration.Status>()
        let asked = removing.ask()
        #expect(AgentCleanup.left(server: CopilotCLIProgress(status: .absent), plugin: done, sessionPrompts: removing) == nil)
        removing.answer(asked, with: .failed("It timed out."))
        #expect(AgentCleanup.left(server: CopilotCLIProgress(status: .absent), plugin: done, sessionPrompts: removing)?.sessionPrompts
            == "It timed out.")
    }

    /// Turning agents off removes Pull Request Order's skill too: what's left of it says why, once BriefBar is done trying.
    @Test func reportsWhatsLeftOfTheOrdersSkill() {
        let left = AgentCleanup(server: .absent, plugin: .absent, order: .failed("It timed out."))
        #expect(!left.isDone)
        #expect(left.order == "It timed out." && left.sessionPrompts == nil)
        #expect(AgentCleanup(server: .absent, plugin: .absent, order: .installed(enabled: false)).order == "The Copilot CLI still has it.")
        #expect(AgentCleanup(server: .absent, plugin: .absent, order: .absent).isDone)

        let done = CopilotCLIProgress<CopilotPluginRegistration.Status>(status: .absent)
        var removing = CopilotCLIProgress<CopilotPluginRegistration.Status>()
        let asked = removing.ask()
        #expect(AgentCleanup.left(server: CopilotCLIProgress(status: .absent), plugin: done, sessionPrompts: done, order: removing) == nil)
        removing.answer(asked, with: .failed("It timed out."))
        #expect(AgentCleanup.left(server: CopilotCLIProgress(status: .absent), plugin: done, order: removing)?.order == "It timed out.")
    }

    /// Turning agents off removes Updates from Copilot Sessions' skill too: what's left of it says why, once BriefBar is
    /// done trying.
    @Test func reportsWhatsLeftOfTheSessionUpdatesSkill() {
        let left = AgentCleanup(server: .absent, plugin: .absent, updates: .failed("It timed out."))
        #expect(!left.isDone)
        #expect(left.updates == "It timed out." && left.order == nil)
        #expect(AgentCleanup(server: .absent, plugin: .absent, order: .absent, updates: .absent).isDone)

        let done = CopilotCLIProgress<CopilotPluginRegistration.Status>(status: .absent)
        var removing = CopilotCLIProgress<CopilotPluginRegistration.Status>()
        let asked = removing.ask()
        #expect(AgentCleanup.left(server: CopilotCLIProgress(status: .absent), plugin: done, updates: removing) == nil)
        removing.answer(asked, with: .installed(enabled: true))
        #expect(AgentCleanup.left(server: CopilotCLIProgress(status: .absent), plugin: done, updates: removing)?.updates
            == "The Copilot CLI still has it.")
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
