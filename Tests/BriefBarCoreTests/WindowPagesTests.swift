import Testing
@testable import BriefBarCore

@Suite struct WindowPagesTests {
    @Test func aWindowWithSeveralPagesStartsWithTheOverview() {
        let window = WindowPages(sections: [.teamsChats, .azureDevOpsPullRequests, .copilotSessions])
        #expect(window.pages == [WindowPages.overview, .teamsChats, .azureDevOpsPullRequests, .copilotSessions])
        #expect(window.hasOverview)
        // It opens on the Overview, unless you chose a page it still has.
        #expect(window.current(chosen: nil) == WindowPages.overview)
        #expect(window.current(chosen: .copilotSessions) == .copilotSessions)
        #expect(window.current(chosen: .azureDevOpsSprint) == WindowPages.overview)

        // Asked for no page, it goes to the Overview; asked for one of its pages, there; for another, nowhere.
        #expect(window.page(for: nil) == WindowPages.overview)
        #expect(window.page(for: .teamsChats) == .teamsChats)
        #expect(window.page(for: WindowPages.overview) == WindowPages.overview)
        #expect(window.page(for: .azureDevOpsPipelines) == nil)
    }

    @Test func theOverviewOpensTheFirstWindowWithSeveralPages() {
        let sessions = SectionLayout.Item(id: "sessions", sections: [.copilotSessions])
        let work = SectionLayout.Item(id: "work", sections: [.azureDevOpsPullRequests, .azureDevOpsSprint])
        let chats = SectionLayout.Item(id: "chats", sections: [.teamsChats, .teamsGroupChats])
        #expect(WindowPages.overviewWindow(in: [sessions, work, chats]) == work)
        #expect(WindowPages.overviewWindow(in: [chats, work]) == chats)
        // With a window for each section, or none, there's no Overview to open.
        #expect(WindowPages.overviewWindow(in: [sessions]) == nil)
        #expect(WindowPages.overviewWindow(in: []) == nil)
    }

    @Test func aWindowWithOnePageHasNoOverview() {
        let window = WindowPages(sections: [.copilotSessions])
        #expect(window.pages == [.copilotSessions])
        #expect(!window.hasOverview)
        #expect(window.current(chosen: WindowPages.overview) == .copilotSessions)
        #expect(window.page(for: nil) == nil)
        #expect(WindowPages(sections: []).current(chosen: nil) == nil)
        #expect(WindowPages.overview.source == nil)
    }
}
