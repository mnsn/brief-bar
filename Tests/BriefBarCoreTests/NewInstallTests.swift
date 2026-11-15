import Foundation
import Testing
@testable import BriefBarCore

@Suite struct NewInstallTests {
    /// Every section that can show in the menu bar, in the sources' order, and those that start hidden there.
    private let sections: [SectionID] = [
        .teamsChats, .teamsGroupChats, .azureDevOpsPullRequests, .azureDevOpsSprint, .azureDevOpsPipelines, .copilotSessions,
        .githubPullRequests,
    ]
    private let startHidden: Set<SectionID> = [.azureDevOpsSprint, .azureDevOpsPipelines]

    /// What BriefBar does with its preferences as it starts, as `AppModel` does: the look, then the menu bar.
    private func start(_ defaults: MemorySettings) {
        NewInstall.saveLook(to: defaults)
        NewInstall.saveMenuBar(sections: sections, hidden: startHidden, to: defaults)
    }

    @Test func aNewInstallStartsWithItsLookSavedAsIfYouChoseIt() {
        let defaults = MemorySettings()
        #expect(NewInstall.isNew(defaults))
        start(defaults)

        let options = InterfaceOptions.load(from: defaults)
        #expect(options == InterfaceOptions(enabled: [.clearerStates, .readableRows, .simpleLayoutControls]))
        // Every switch is saved, those off too, as Settings › Appearance saves them.
        for option in InterfaceOption.allCases {
            #expect(defaults.object(forKey: option.defaultsKey) as? Bool == options[option])
        }
        NewInstall.launched(defaults)
        #expect(!NewInstall.isNew(defaults))
        #expect(InterfaceOptions.load(from: defaults) == options)
    }

    @Test func aNewInstallKeepsAnOptionThatsAlreadySaved() {
        let defaults = MemorySettings()
        defaults.set(false, forKey: InterfaceOption.readableRows.defaultsKey)
        defaults.set(true, forKey: InterfaceOption.quietAppearance.defaultsKey)
        start(defaults)
        #expect(InterfaceOptions.load(from: defaults) == InterfaceOptions(enabled: [.clearerStates, .simpleLayoutControls, .quietAppearance]))
    }

    @Test func aNewInstallStartsWithOneMenuBarItemThatEverySourceJoins() throws {
        let defaults = MemorySettings()
        start(defaults)
        var layout = SectionLayout.load(.menuBar, from: defaults)
        let item = try #require(layout.items.first)
        #expect(layout.items.count == 1)
        #expect(item.sections == sections)
        #expect(layout.hidden == [.azureDevOpsSprint, .azureDevOpsPipelines])
        #expect(MenuBarItemOptions.load(from: defaults) == [item.id: MenuBarItemOptions(byState: true, listByState: true)])
        // The item's options stay while nothing shows in it yet, so turning a source on finds them.
        #expect(MenuBarItemOptions.kept(MenuBarItemOptions.load(from: defaults), in: layout) == MenuBarItemOptions.load(from: defaults))

        // Nothing is on yet: nothing shows.
        #expect(layout.visibleItems(showing: []).isEmpty)
        // Azure DevOps on, as turning it on places it: its pull requests show in the item, its sprint and pipelines stay
        // hidden.
        let azureDevOps: [SectionID] = [.azureDevOpsPullRequests, .azureDevOpsSprint, .azureDevOpsPipelines]
        layout.sourceTurnedOn(azureDevOps)
        #expect(layout.visibleItems(showing: azureDevOps) == [SectionLayout.Item(id: item.id, sections: [.azureDevOpsPullRequests])])
        // Copilot, then Teams, later: they join it.
        layout.sourceTurnedOn([.copilotSessions])
        layout.sourceTurnedOn([.teamsChats, .teamsGroupChats])
        #expect(layout.visibleItems(showing: azureDevOps + [.copilotSessions, .teamsChats, .teamsGroupChats]) == [
            SectionLayout.Item(id: item.id, sections: [.teamsChats, .teamsGroupChats, .azureDevOpsPullRequests, .copilotSessions]),
        ])
    }

    @Test func giveEachItsOwnItemStillSplitsANewInstallsItem() {
        let defaults = MemorySettings()
        start(defaults)
        var layout = SectionLayout.load(.menuBar, from: defaults)
        layout.separateAll()
        let on: [SectionID] = [.azureDevOpsPullRequests, .azureDevOpsSprint, .azureDevOpsPipelines, .copilotSessions]
        #expect(layout.visibleItems(showing: on).map(\.sections) == [[.azureDevOpsPullRequests], [.copilotSessions]])
        // A source turned on afterwards gets items of its own too.
        layout.sourceTurnedOn([.githubPullRequests])
        #expect(layout.visibleItems(showing: on + [.githubPullRequests]).map(\.sections)
            == [[.azureDevOpsPullRequests], [.copilotSessions], [.githubPullRequests]])
    }

    @Test func anUpdateKeepsTheLookAndTheMenuBarItHad() throws {
        // As an install that launched before has its preferences: a source on, an item for each section, and Appearance
        // as it was, each switch off, never saved.
        let defaults = MemorySettings()
        NewInstall.launched(defaults)
        defaults.set(Data("[\"copilot\"]".utf8), forKey: SourceChoices.defaultsKey)
        var layout = SectionLayout(.menuBar)
        layout.place([.copilotSessions, .githubPullRequests])
        layout.save(to: defaults)
        let before = defaults.dictionaryRepresentation()

        #expect(!NewInstall.isNew(defaults))
        start(defaults)
        #expect(NSDictionary(dictionary: defaults.dictionaryRepresentation()).isEqual(to: before))
        #expect(InterfaceOptions.load(from: defaults) == InterfaceOptions())
        #expect(SectionLayout.load(.menuBar, from: defaults) == layout)
        #expect(MenuBarItemOptions.load(from: defaults).isEmpty)
    }

    @Test func anUpdateWithNothingArrangedYetStillGetsAnItemForEachSection() {
        // Every source was off: no menu bar was saved.
        let defaults = MemorySettings()
        NewInstall.launched(defaults)
        start(defaults)
        #expect(defaults.object(forKey: Surface.menuBar.defaultsKey) == nil)
        #expect(SectionLayout.load(.menuBar, from: defaults).visibleItems(showing: [.copilotSessions, .githubPullRequests]).map(\.sections)
            == [[.copilotSessions], [.githubPullRequests]])
    }

    @Test func aNewInstallKeepsAMenuBarThatsAlreadySaved() {
        let defaults = MemorySettings()
        var layout = SectionLayout(.menuBar)
        layout.place([.teamsChats, .copilotSessions])
        layout.save(to: defaults)
        start(defaults)
        #expect(SectionLayout.load(.menuBar, from: defaults) == layout)
        #expect(MenuBarItemOptions.load(from: defaults).isEmpty)
    }
}
