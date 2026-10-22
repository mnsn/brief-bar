import Foundation
import Testing
@testable import BriefBarCore

@Suite struct MenuBarItemOptionsTests {
    @Test func anItemStartsSideBySideAndAddsUpWithoutRunning() {
        let options = MenuBarItemOptions()
        #expect(!options.byState)
        #expect(options.shownStates == [.needsYou, .failing, .done])

        var withRunning = options
        withRunning.states.insert(.running)
        #expect(withRunning.shownStates == [.needsYou, .failing, .done, .running])
        withRunning.states = [.running, .needsYou]
        #expect(withRunning.shownStates == [.needsYou, .running])
    }

    @Test func savesAndLoadsEachItemsOptions() throws {
        let defaults = MemorySettings()
        #expect(MenuBarItemOptions.load(from: defaults).isEmpty)
        let saved = [
            "teams.chats": MenuBarItemOptions(byState: true),
            "copilot.sessions": MenuBarItemOptions(byState: true, states: [.running, .needsYou]),
        ]
        MenuBarItemOptions.save(saved, to: defaults)
        #expect(MenuBarItemOptions.load(from: defaults) == saved)

        // The states are saved in one order, whatever order the set has.
        let data = try #require(defaults.data(forKey: MenuBarItemOptions.defaultsKey))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""states":["needsYou","running"]"#))
    }

    @Test func keepsDefaultsForWhatsMissingAndSkipsStatesItDoesntKnow() throws {
        let decoded = try JSONDecoder().decode(
            [String: MenuBarItemOptions].self,
            from: Data(#"{"a":{},"b":{"byState":true,"states":["needsYou","waiting","running"]},"c":{"states":[]}}"#.utf8)
        )
        #expect(decoded["a"] == MenuBarItemOptions())
        #expect(decoded["b"] == MenuBarItemOptions(byState: true, states: [.needsYou, .running]))
        #expect(decoded["c"]?.states.isEmpty == true)

        // Something it can't read at all counts as nothing saved.
        let defaults = MemorySettings()
        defaults.set(Data("[1]".utf8), forKey: MenuBarItemOptions.defaultsKey)
        #expect(MenuBarItemOptions.load(from: defaults).isEmpty)
    }

    @Test func anItemThatGoesAwayTakesItsOptionsWithIt() {
        var layout = SectionLayout(.menuBar)
        layout.place([.teamsChats, .azureDevOpsPullRequests, .copilotSessions])
        var options = [
            "azureDevOps.pullRequests": MenuBarItemOptions(byState: true),
            "teams.chats": MenuBarItemOptions(byState: true, states: [.needsYou]),
            "copilot.sessions": MenuBarItemOptions(byState: true, states: [.running]),
            "gone": MenuBarItemOptions(byState: true),
            "plain": MenuBarItemOptions(),
        ]
        // As the app does after each change: Copilot joins Azure DevOps' item, and its own goes away. A section
        // that's hidden, or whose source is off, keeps its item, and the item its options.
        layout.combine(.copilotSessions, with: .azureDevOpsPullRequests)
        layout.hide(.teamsChats)
        options = MenuBarItemOptions.kept(options, in: layout)
        #expect(options == [
            "azureDevOps.pullRequests": MenuBarItemOptions(byState: true),
            "teams.chats": MenuBarItemOptions(byState: true, states: [.needsYou]),
        ])

        // Separated again, Copilot gets an item of its own under the same ID, which starts over.
        layout.separate(.copilotSessions)
        options = MenuBarItemOptions.kept(options, in: layout)
        #expect(layout.item(containing: .copilotSessions)?.id == "copilot.sessions")
        #expect(options["copilot.sessions"] == nil)
        #expect(options["azureDevOps.pullRequests"] == MenuBarItemOptions(byState: true))
    }
}
