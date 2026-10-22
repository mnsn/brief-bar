import Foundation
import Testing
@testable import BriefBarCore

@Suite struct MenuBarTabsTests {
    private let chats = SectionID.teamsChats
    private let groups = SectionID.teamsGroupChats
    private let pullRequests = SectionID.azureDevOpsPullRequests
    private let sessions = SectionID.copilotSessions
    /// The item that Azure DevOps and Copilot share, as `combine` leaves it.
    private let shared = "azureDevOps.pullRequests"

    @Test func opensAtTheTabYouLookedAtLastEvenWhenAnotherNeedsYou() {
        var tabs = MenuBarTabs()
        tabs.remember(sessions, for: shared)
        #expect(tabs.tab(for: shared, sections: [pullRequests, sessions], needsYou: { $0 == pullRequests }) == sessions)
        #expect(tabs.tab(for: shared, sections: [pullRequests, sessions], needsYou: { _ in true }) == sessions)
    }

    @Test func opensAtWhatItsAskedForWhichItThenOpensAtNextTime() {
        var tabs = MenuBarTabs()
        tabs.remember(sessions, for: shared)
        // A notification about the pull requests.
        let asked = tabs.tab(for: shared, sections: [pullRequests, sessions], asked: pullRequests, needsYou: { _ in false })
        #expect(asked == pullRequests)
        tabs.remember(pullRequests, for: shared)
        #expect(tabs.tab(for: shared, sections: [pullRequests, sessions], needsYou: { $0 == sessions }) == pullRequests)
        // Something in another item isn't this item's to show.
        #expect(tabs.tab(for: shared, sections: [pullRequests, sessions], asked: chats, needsYou: { _ in false }) == pullRequests)
    }

    @Test func theFirstTimeOpensAtTheFirstThatNeedsYouOrTheFirst() {
        let tabs = MenuBarTabs()
        #expect(tabs.tab(for: shared, sections: [pullRequests, sessions], needsYou: { $0 == sessions }) == sessions)
        #expect(tabs.tab(for: shared, sections: [pullRequests, sessions], needsYou: { _ in true }) == pullRequests)
        #expect(tabs.tab(for: shared, sections: [pullRequests, sessions], needsYou: { _ in false }) == pullRequests)
        #expect(tabs.tab(for: shared, sections: [], needsYou: { _ in true }) == nil)
    }

    @Test func aTabThatMovedToAnotherItemDoesntCount() {
        var tabs = MenuBarTabs()
        tabs.remember(sessions, for: shared)
        // Copilot got an item of its own, and Azure DevOps has two sections there now.
        let sprint = SectionID.azureDevOpsSprint
        #expect(tabs.tab(for: shared, sections: [pullRequests, sprint], needsYou: { $0 == sprint }) == sprint)
        #expect(tabs.tab(for: shared, sections: [pullRequests, sprint], needsYou: { _ in false }) == pullRequests)
        // Back together, it opens at Copilot again.
        #expect(tabs.tab(for: shared, sections: [pullRequests, sessions], needsYou: { $0 == pullRequests }) == sessions)
    }

    @Test func eachItemKeepsItsOwnTabAfterARestart() {
        let defaults = MemorySettings()
        var tabs = MenuBarTabs.load(from: defaults)
        tabs.remember(sessions, for: shared)
        tabs.remember(groups, for: "teams.chats")
        tabs.save(to: defaults)

        let restarted = MenuBarTabs.load(from: defaults)
        #expect(restarted == tabs)
        #expect(restarted.tab(for: shared, sections: [pullRequests, sessions], needsYou: { $0 == pullRequests }) == sessions)
        #expect(restarted.tab(for: "teams.chats", sections: [chats, groups], needsYou: { $0 == chats }) == groups)
        // An item it hasn't seen opens as before.
        #expect(restarted.last(for: "teams.groupChats") == nil)
    }

    @Test func somethingUnreadableRemembersNothing() {
        let defaults = MemorySettings()
        defaults.set("copilot.sessions", forKey: MenuBarTabs.defaultsKey)
        #expect(MenuBarTabs.load(from: defaults) == MenuBarTabs())
        defaults.set([shared: 2], forKey: MenuBarTabs.defaultsKey)
        #expect(MenuBarTabs.load(from: defaults) == MenuBarTabs())
    }
}
