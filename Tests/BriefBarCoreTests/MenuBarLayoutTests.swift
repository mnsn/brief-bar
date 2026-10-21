import Foundation
import Testing
@testable import BriefBarCore

@Suite struct MenuBarLayoutTests {
    private let chats = SectionID.teamsChats
    private let groups = SectionID.teamsGroupChats
    private let pullRequests = SectionID.azureDevOpsPullRequests
    private let sessions = SectionID.copilotSessions

    @Test func everySectionHasAnItemOfItsOwnAtFirst() {
        let items = MenuBarLayout().visibleItems(showing: [chats, groups, pullRequests])
        #expect(items.map(\.sections) == [[chats], [groups], [pullRequests]])
        #expect(items.map(\.id) == ["teams.chats", "teams.groupChats", "azureDevOps.pullRequests"])
    }

    @Test func combinesAndSeparatesSections() {
        var layout = MenuBarLayout()
        layout.place([chats, groups, pullRequests, sessions])
        layout.combine(sessions, with: pullRequests)
        #expect(layout.items.map(\.sections) == [[chats], [groups], [pullRequests, sessions]])
        layout.combine(groups, with: chats)
        #expect(layout.items.map(\.sections) == [[chats, groups], [pullRequests, sessions]])
        #expect(layout.items.map(\.id) == ["teams.chats", "azureDevOps.pullRequests"])

        layout.separate(pullRequests)
        #expect(layout.items.map(\.sections) == [[chats, groups], [sessions], [pullRequests]])
        // The item kept its ID, so the section that left it gets another.
        #expect(layout.items.map(\.id) == ["teams.chats", "azureDevOps.pullRequests", "azureDevOps.pullRequests-2"])
    }

    @Test func separatingASectionThatsAloneChangesNothing() {
        var layout = MenuBarLayout()
        layout.place([chats, groups])
        let before = layout
        layout.separate(chats)
        #expect(layout == before)
        layout.combine(chats, with: chats)
        #expect(layout == before)
    }

    @Test func showsOnlySectionsThatAreOnButRemembersWhereTheOthersGo() {
        var layout = MenuBarLayout()
        layout.place([chats, groups, pullRequests, sessions])
        layout.combine(sessions, with: pullRequests)
        // Azure DevOps is off: Copilot shows in the item they share.
        #expect(layout.visibleItems(showing: [chats, groups, sessions]).map(\.sections) == [[chats], [groups], [sessions]])
        #expect(layout.visibleItems(showing: [chats, groups, sessions]).map(\.id).last == "azureDevOps.pullRequests")
        // Back on, it's back with Copilot.
        #expect(layout.visibleItems(showing: [chats, groups, pullRequests, sessions]).map(\.sections)
            == [[chats], [groups], [pullRequests, sessions]])
        // Nothing on, nothing shown.
        #expect(layout.visibleItems(showing: []).isEmpty)
    }

    @Test func keepsButNeverShowsSectionsThisVersionDoesntKnow() {
        let outlook = SectionID(rawValue: "outlook.mail")
        var layout = MenuBarLayout()
        layout.place([chats, outlook])
        layout.combine(outlook, with: chats)
        #expect(layout.visibleItems(showing: [chats]).map(\.sections) == [[chats]])
        #expect(layout.items.map(\.sections) == [[chats, outlook]])
    }

    @Test func repairsASavedLayoutThatRepeatsSectionsOrIDs() throws {
        let saved = MenuBarLayout(items: [
            .init(id: "a", sections: [chats, chats, groups]),
            .init(id: "a", sections: [groups, pullRequests]),
            .init(id: "b", sections: []),
        ])
        #expect(saved.items.map(\.sections) == [[chats, groups], [pullRequests]])
        #expect(saved.items.map(\.id) == ["a", "a-2"])

        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(MenuBarLayout.self, from: data) == saved)
    }

    @Test func somethingUnreadableStartsOver() {
        let defaults = MemorySettings()
        defaults.set(Data("[1,2]".utf8), forKey: MenuBarLayout.defaultsKey)
        #expect(MenuBarLayout.load(from: defaults) == MenuBarLayout())

        var layout = MenuBarLayout()
        layout.place([sessions, chats])
        layout.save(to: defaults)
        #expect(MenuBarLayout.load(from: defaults) == layout)
    }
}
