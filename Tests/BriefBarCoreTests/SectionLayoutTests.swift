import Foundation
import Testing
@testable import BriefBarCore

@Suite struct SectionLayoutTests {
    private let chats = SectionID.teamsChats
    private let groups = SectionID.teamsGroupChats
    private let pullRequests = SectionID.azureDevOpsPullRequests
    private let sessions = SectionID.copilotSessions

    @Test func everySectionHasAnItemOfItsOwnAtFirst() {
        let items = SectionLayout().visibleItems(showing: [chats, groups, pullRequests])
        #expect(items.map(\.sections) == [[chats], [groups], [pullRequests]])
        #expect(items.map(\.id) == ["teams.chats", "teams.groupChats", "azureDevOps.pullRequests"])
    }

    @Test func combinesAndSeparatesSections() {
        var layout = SectionLayout()
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
        var layout = SectionLayout()
        layout.place([chats, groups])
        let before = layout
        layout.separate(chats)
        #expect(layout == before)
        layout.combine(chats, with: chats)
        #expect(layout == before)
    }

    @Test func showsOnlySectionsThatAreOnButRemembersWhereTheOthersGo() {
        var layout = SectionLayout()
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
        var layout = SectionLayout()
        layout.place([chats, outlook])
        layout.combine(outlook, with: chats)
        #expect(layout.visibleItems(showing: [chats]).map(\.sections) == [[chats]])
        #expect(layout.items.map(\.sections) == [[chats, outlook]])
    }

    @Test func hidesASectionButRemembersWhereItGoes() {
        var layout = SectionLayout()
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
        var layout = SectionLayout()
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
        var layout = SectionLayout()
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

    @Test func movesASectionWhereYouDropIt() {
        var layout = SectionLayout()
        layout.place([chats, groups, pullRequests, sessions])
        layout.move(sessions, to: .with(pullRequests))
        #expect(layout.items.map(\.sections) == [[chats], [groups], [pullRequests, sessions]])
        layout.move(pullRequests, to: .alone)
        #expect(layout.items.map(\.sections) == [[chats], [groups], [sessions], [pullRequests]])
        layout.move(groups, to: .hidden)
        #expect(layout.isHidden(groups))
        #expect(layout.visibleItems(showing: [chats, groups, pullRequests, sessions]).map(\.sections) == [[chats], [sessions], [pullRequests]])
        // Dropped in another item, a hidden section shows there.
        layout.move(groups, to: .with(chats))
        #expect(!layout.isHidden(groups))
        #expect(layout.items.map(\.sections) == [[chats, groups], [sessions], [pullRequests]])
    }

    @Test func droppingASectionInItsOwnItemKeepsItsPlace() {
        var layout = SectionLayout()
        layout.place([chats, groups, pullRequests])
        layout.move(groups, to: .with(chats))
        let before = layout
        layout.move(chats, to: .with(groups))
        #expect(layout == before)
        layout.move(chats, to: .with(chats))
        #expect(layout == before)

        // Hidden, it shows again where it was, rather than after the others.
        layout.move(chats, to: .hidden)
        layout.move(chats, to: .with(groups))
        #expect(layout == before)
    }

    @Test func turningASourceOnShowsItIfAllOfItWasHidden() {
        var layout = SectionLayout()
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
        var layout = SectionLayout()
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
        var later = SectionLayout()
        later.place([chats, sessions])
        later.combineAll([chats, sessions, pullRequests])
        #expect(later.visibleItems(showing: [chats, sessions]).map(\.sections) == [[chats, sessions]])
        #expect(later.visibleItems(showing: [chats, pullRequests, sessions]).map(\.sections) == [[chats, sessions, pullRequests]])
        #expect(later.items.map(\.id) == ["teams.chats"])
    }

    @Test func givesEverySectionAnItemOfItsOwn() {
        var layout = SectionLayout()
        layout.place([chats, groups, pullRequests, sessions])
        layout.hide(groups)
        layout.combineAll([chats, groups, pullRequests, sessions])
        layout.separateAll()
        #expect(layout.items.map(\.sections) == [[chats], [groups], [pullRequests], [sessions]])
        // Back to the IDs they had, and so to their places in the menu bar.
        #expect(layout.items.map(\.id) == ["teams.chats", "teams.groupChats", "azureDevOps.pullRequests", "copilot.sessions"])
        #expect(layout.isHidden(groups))

        var renamed = SectionLayout(items: [.init(id: "a", sections: [chats, groups]), .init(id: "teams.groupChats", sections: [sessions])])
        renamed.separateAll()
        #expect(renamed.items.map(\.id) == ["a", "teams.groupChats-2", "teams.groupChats"])
    }

    @Test func repairsASavedLayoutThatRepeatsSectionsOrIDs() throws {
        let saved = SectionLayout(items: [
            .init(id: "a", sections: [chats, chats, groups]),
            .init(id: "a", sections: [groups, pullRequests]),
            .init(id: "b", sections: []),
        ], hidden: [groups, groups])
        #expect(saved.items.map(\.sections) == [[chats, groups], [pullRequests]])
        #expect(saved.items.map(\.id) == ["a", "a-2"])
        #expect(saved.hidden == [groups])

        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(SectionLayout.self, from: data) == saved)
    }

    @Test func readsALayoutSavedBeforeSectionsCouldBeHidden() throws {
        let data = Data(#"{"items":[{"id":"teams.chats","sections":["teams.chats","teams.groupChats"]}]}"#.utf8)
        let layout = try JSONDecoder().decode(SectionLayout.self, from: data)
        #expect(layout.items.map(\.sections) == [[chats, groups]])
        #expect(layout.hidden.isEmpty)
    }

    @Test func somethingUnreadableStartsOver() {
        let defaults = MemorySettings()
        defaults.set(Data("[1,2]".utf8), forKey: Surface.menuBar.defaultsKey)
        #expect(SectionLayout.load(.menuBar, from: defaults) == SectionLayout())

        var layout = SectionLayout()
        layout.place([sessions, chats])
        layout.save(to: defaults)
        #expect(SectionLayout.load(.menuBar, from: defaults) == layout)
    }

    // MARK: Widgets and windows

    @Test func eachSurfaceKeepsALayoutOfItsOwn() {
        let defaults = MemorySettings()
        var menuBar = SectionLayout(.menuBar)
        menuBar.place([pullRequests, sessions])
        menuBar.combine(sessions, with: pullRequests)
        menuBar.save(to: defaults)
        var widgets = SectionLayout(.widgets)
        widgets.place([pullRequests, sessions])
        widgets.hide(sessions)
        widgets.save(to: defaults)

        #expect(SectionLayout.load(.menuBar, from: defaults) == menuBar)
        #expect(SectionLayout.load(.widgets, from: defaults) == widgets)
        #expect(SectionLayout.load(.widgets, from: defaults).surface == .widgets)
        #expect(SectionLayout.load(.windows, from: defaults) == SectionLayout(.windows))
        #expect(Set(Surface.allCases.map(\.defaultsKey)).count == Surface.allCases.count)
    }

    @Test func widgetsStartOnePerSection() {
        let items = SectionLayout(.widgets).visibleItems(showing: [pullRequests, sessions])
        #expect(items.map(\.sections) == [[pullRequests], [sessions]])
        #expect(items.map(\.id) == ["azureDevOps.pullRequests", "copilot.sessions"])
    }

    @Test func windowsStartAsOneWithEveryPage() {
        var layout = SectionLayout(.windows)
        #expect(layout.visibleItems(showing: [chats, groups, pullRequests]).map(\.sections) == [[chats, groups, pullRequests]])
        layout.place([chats, groups, pullRequests])
        #expect(layout.items.map(\.id) == [Surface.firstItemID])

        // A page of its own, then a source turned on later: it joins the first window.
        layout.separate(pullRequests)
        layout.sourceTurnedOn([sessions])
        #expect(layout.items.map(\.sections) == [[chats, groups, sessions], [pullRequests]])
        #expect(layout.items.map(\.id) == [Surface.firstItemID, "azureDevOps.pullRequests"])
    }

    @Test func aPageThatWasNeverPlacedCanHaveAWindowOfItsOwn() {
        var layout = SectionLayout(.windows)
        layout.place([chats])
        layout.separate(sessions)
        #expect(layout.items.map(\.sections) == [[chats], [sessions]])
        layout.hide(groups)
        #expect(layout.items.map(\.sections) == [[chats, groups], [sessions]])
        #expect(layout.visibleItems(showing: [chats, groups, sessions]).map(\.sections) == [[chats], [sessions]])
    }

    @Test func windowsCombineAndSeparateLikeMenuBarItems() {
        var layout = SectionLayout(.windows)
        layout.place([chats, groups, pullRequests, sessions])
        layout.separateAll()
        #expect(layout.items.map(\.sections) == [[chats], [groups], [pullRequests], [sessions]])
        #expect(layout.items.first?.id == Surface.firstItemID)
        layout.combine(sessions, with: pullRequests)
        #expect(layout.items.map(\.sections) == [[chats], [groups], [pullRequests, sessions]])
        layout.combineAll([sessions, chats])
        #expect(layout.items.map(\.sections) == [[sessions, chats, groups, pullRequests]])
        // Starting from a page that was never placed, the window is the first one.
        var fresh = SectionLayout(.windows)
        fresh.combineAll([chats, groups])
        #expect(fresh.items.map(\.id) == [Surface.firstItemID])
    }
}
