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

    @Test func hidesASectionButRemembersWhereItGoes() {
        var layout = MenuBarLayout()
        layout.place([chats, groups, pullRequests])
        layout.combine(groups, with: chats)
        layout.hide(groups)
        #expect(layout.isHidden(groups))
        #expect(layout.visibleItems(showing: [chats, groups, pullRequests]).map(\.sections) == [[chats], [pullRequests]])
        #expect(layout.items.map(\.sections) == [[chats, groups], [pullRequests]])

        layout.show(groups)
        #expect(!layout.isHidden(groups))
        #expect(layout.visibleItems(showing: [chats, groups, pullRequests]).map(\.sections) == [[chats, groups], [pullRequests]])
    }

    @Test func anItemWithOnlyHiddenSectionsDisappears() {
        var layout = MenuBarLayout()
        layout.place([chats, pullRequests, sessions])
        layout.combine(sessions, with: pullRequests)
        layout.hide(pullRequests)
        layout.hide(sessions)
        #expect(layout.visibleItems(showing: [chats, pullRequests, sessions]).map(\.sections) == [[chats]])
        // Hidden before it was ever placed: it shows nowhere, but has a place for when it's shown.
        layout.hide(groups)
        #expect(layout.visibleItems(showing: [chats, groups]).map(\.sections) == [[chats]])
        #expect(layout.item(containing: groups) != nil)
    }

    @Test func puttingAHiddenSectionSomewhereShowsIt() {
        var layout = MenuBarLayout()
        layout.place([chats, groups, pullRequests])
        layout.hide(groups)
        layout.separate(groups)
        #expect(!layout.isHidden(groups))
        #expect(layout.visibleItems(showing: [chats, groups, pullRequests]).map(\.sections) == [[chats], [groups], [pullRequests]])

        layout.hide(pullRequests)
        layout.combine(pullRequests, with: chats)
        #expect(!layout.isHidden(pullRequests))
        #expect(layout.visibleItems(showing: [chats, groups, pullRequests]).map(\.sections) == [[chats, pullRequests], [groups]])
    }

    @Test func turningASourceOnShowsItIfAllOfItWasHidden() {
        var layout = MenuBarLayout()
        layout.place([chats, groups, pullRequests])
        layout.hide(groups)
        layout.sourceTurnedOn([chats, groups])
        // Only part of it was hidden: that stays as you chose.
        #expect(layout.isHidden(groups))

        layout.hide(chats)
        layout.sourceTurnedOn([chats, groups])
        #expect(!layout.isHidden(chats) && !layout.isHidden(groups))
        #expect(layout.visibleItems(showing: [chats, groups, pullRequests]).map(\.sections) == [[chats], [groups], [pullRequests]])

        // Never on before: its sections get items of their own.
        layout.sourceTurnedOn([sessions])
        #expect(layout.items.map(\.sections).last == [sessions])
    }

    @Test func putsEverySectionInOneItem() {
        var layout = MenuBarLayout()
        layout.place([chats, groups, pullRequests, sessions])
        layout.combine(chats, with: sessions)
        layout.hide(groups)
        // As shown, left to right, then the rest, such as a source that's off.
        layout.combineAll([pullRequests, sessions, chats, groups])
        #expect(layout.items.map(\.sections) == [[pullRequests, sessions, chats, groups]])
        #expect(layout.items.map(\.id) == ["azureDevOps.pullRequests"])
        #expect(layout.isHidden(groups))
        #expect(layout.visibleItems(showing: [chats, groups, pullRequests, sessions]).map(\.sections) == [[pullRequests, sessions, chats]])

        // Azure DevOps was off: turned on, it joins the others.
        var later = MenuBarLayout()
        later.place([chats, sessions])
        later.combineAll([chats, sessions, pullRequests])
        #expect(later.visibleItems(showing: [chats, sessions]).map(\.sections) == [[chats, sessions]])
        #expect(later.visibleItems(showing: [chats, pullRequests, sessions]).map(\.sections) == [[chats, sessions, pullRequests]])
        #expect(later.items.map(\.id) == ["teams.chats"])
    }

    @Test func givesEverySectionAnItemOfItsOwn() {
        var layout = MenuBarLayout()
        layout.place([chats, groups, pullRequests, sessions])
        layout.hide(groups)
        layout.combineAll([chats, groups, pullRequests, sessions])
        layout.separateAll()
        #expect(layout.items.map(\.sections) == [[chats], [groups], [pullRequests], [sessions]])
        // Back to the IDs they had, and so to their places in the menu bar.
        #expect(layout.items.map(\.id) == ["teams.chats", "teams.groupChats", "azureDevOps.pullRequests", "copilot.sessions"])
        #expect(layout.isHidden(groups))

        var renamed = MenuBarLayout(items: [.init(id: "a", sections: [chats, groups]), .init(id: "teams.groupChats", sections: [sessions])])
        renamed.separateAll()
        #expect(renamed.items.map(\.id) == ["a", "teams.groupChats-2", "teams.groupChats"])
    }

    @Test func repairsASavedLayoutThatRepeatsSectionsOrIDs() throws {
        let saved = MenuBarLayout(items: [
            .init(id: "a", sections: [chats, chats, groups]),
            .init(id: "a", sections: [groups, pullRequests]),
            .init(id: "b", sections: []),
        ], hidden: [groups, groups])
        #expect(saved.items.map(\.sections) == [[chats, groups], [pullRequests]])
        #expect(saved.items.map(\.id) == ["a", "a-2"])
        #expect(saved.hidden == [groups])

        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(MenuBarLayout.self, from: data) == saved)
    }

    @Test func readsALayoutSavedBeforeSectionsCouldBeHidden() throws {
        let data = Data(#"{"items":[{"id":"teams.chats","sections":["teams.chats","teams.groupChats"]}]}"#.utf8)
        let layout = try JSONDecoder().decode(MenuBarLayout.self, from: data)
        #expect(layout.items.map(\.sections) == [[chats, groups]])
        #expect(layout.hidden.isEmpty)
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
