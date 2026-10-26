import Foundation
import Testing
@testable import BriefBarCore

@Suite struct InterfaceOptionsTests {
    @Test func everyOptionStartsOffWithoutWritingPreferences() {
        let defaults = MemorySettings()
        let options = InterfaceOptions.load(from: defaults)
        #expect(options == InterfaceOptions())
        for option in InterfaceOption.allCases {
            #expect(!options[option])
            #expect(defaults.object(forKey: option.defaultsKey) == nil)
        }
    }

    @Test(arguments: InterfaceOption.allCases)
    func optionsPersistIndependentlyAndCanBeTurnedOff(_ option: InterfaceOption) {
        let defaults = MemorySettings()
        var options = InterfaceOptions()
        options[option] = true
        options.save(to: defaults)
        let loaded = InterfaceOptions.load(from: defaults)
        #expect(loaded == options)
        #expect(InterfaceOption.allCases.filter { loaded[$0] } == [option])

        options[option] = false
        options.save(to: defaults)
        #expect(InterfaceOptions.load(from: defaults) == InterfaceOptions())
    }

    @Test func preferencesNeverRewriteLayoutsOrExistingOptions() throws {
        let defaults = MemorySettings()
        var layout = SectionLayout(.menuBar)
        layout.place([.teamsChats, .teamsGroupChats, .copilotSessions])
        layout.hide(.teamsGroupChats)
        layout.save(to: defaults)
        MenuBarItemOptions.save(["teams.chats": MenuBarItemOptions(byState: true)], to: defaults)
        let savedLayout = try #require(defaults.data(forKey: Surface.menuBar.defaultsKey))
        let savedOptions = try #require(defaults.data(forKey: MenuBarItemOptions.defaultsKey))
        defaults.set("source consent", forKey: SourceChoices.defaultsKey)

        #expect(InterfaceOptions.load(from: defaults) == InterfaceOptions())
        InterfaceOptions(enabled: Set(InterfaceOption.allCases)).save(to: defaults)
        #expect(defaults.data(forKey: Surface.menuBar.defaultsKey) == savedLayout)
        #expect(defaults.data(forKey: MenuBarItemOptions.defaultsKey) == savedOptions)
        #expect(defaults.string(forKey: SourceChoices.defaultsKey) == "source consent")
    }

    @Test func compactMenuIsOnlyAReversibleViewOfVisibleItems() {
        let layout = SectionLayout(.menuBar, items: [
            .init(id: "custom-first", sections: [.copilotSessions, .teamsChats]),
            .init(id: "custom-second", sections: [.teamsGroupChats, .azureDevOpsPullRequests]),
        ], hidden: [.teamsGroupChats])
        let visible = layout.visibleItems(showing: [.copilotSessions, .teamsChats, .teamsGroupChats, .azureDevOpsPullRequests])
        var options = InterfaceOptions()
        #expect(options.menuBarItems(visible) == visible)

        options[.compactMenuBar] = true
        #expect(options.menuBarItems(visible) == [
            .init(id: InterfaceOptions.compactMenuBarID, sections: [.copilotSessions, .teamsChats, .azureDevOpsPullRequests]),
        ])
        #expect(options.menuBarItems([]).isEmpty)
        #expect(layout.hidden == [.teamsGroupChats])
        #expect(layout.items.map(\.id) == ["custom-first", "custom-second"])
        options[.compactMenuBar] = false
        #expect(options.menuBarItems(visible) == visible)
    }

    @Test func otherOptionsDoNotCombineTheMenuBar() {
        let items = [SectionLayout.Item(id: "one", sections: [.teamsChats]), .init(id: "two", sections: [.copilotSessions])]
        let options = InterfaceOptions(enabled: Set(InterfaceOption.allCases.filter { $0 != .compactMenuBar }))
        #expect(options.menuBarItems(items) == items)
    }
}
