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

    @Test func theNotificationsPageFollowsTheOverviewWhileItShows() {
        let sections: [SectionID] = [.teamsChats, .azureDevOpsPullRequests]
        let window = WindowPages(sections: sections, notifications: true)
        #expect(window.pages == [WindowPages.overview, WindowPages.notifications, .teamsChats, .azureDevOpsPullRequests])
        #expect(window.current(chosen: nil) == WindowPages.overview)
        #expect(window.current(chosen: WindowPages.notifications) == WindowPages.notifications)
        #expect(window.page(for: WindowPages.notifications) == WindowPages.notifications)
        #expect(WindowPages.notifications.source == nil)

        // Once there's nothing to show, the window goes back to its Overview.
        let empty = WindowPages(sections: sections)
        #expect(empty.pages == [WindowPages.overview, .teamsChats, .azureDevOpsPullRequests])
        #expect(empty.current(chosen: WindowPages.notifications) == WindowPages.overview)
        #expect(empty.page(for: WindowPages.notifications) == nil)

        // A window without an Overview has no Notifications page either.
        #expect(WindowPages(sections: [.copilotSessions], notifications: true).pages == [.copilotSessions])
    }

    /// My Work goes right before Azure DevOps' Pull Requests while it shows, with a sidebar even in a window with no other
    /// section, but no Overview there; once it's gone, the window shows another page.
    @Test func aSectionsCompanionsComeRightBeforeIt() {
        let companions: [SectionID: [SectionID]] = [.azureDevOpsPullRequests: [.azureDevOpsMyWork]]
        let window = WindowPages(sections: [.teamsChats, .azureDevOpsPullRequests, .copilotSessions], companions: companions)
        #expect(window.pages == [WindowPages.overview, .teamsChats, .azureDevOpsMyWork, .azureDevOpsPullRequests, .copilotSessions])
        #expect(window.page(for: .azureDevOpsMyWork) == .azureDevOpsMyWork)
        #expect(window.current(chosen: .azureDevOpsMyWork) == .azureDevOpsMyWork)
        #expect(window.hasSeveralPages)

        let alone = WindowPages(sections: [.azureDevOpsPullRequests], companions: companions)
        #expect(alone.pages == [.azureDevOpsMyWork, .azureDevOpsPullRequests])
        #expect(!alone.hasOverview)
        #expect(alone.hasSeveralPages)
        #expect(alone.current(chosen: nil) == .azureDevOpsMyWork)

        // Without the section it goes with, it isn't there either.
        #expect(WindowPages(sections: [.copilotSessions], companions: companions).pages == [.copilotSessions])
        let off = WindowPages(sections: [.azureDevOpsPullRequests])
        #expect(!off.hasSeveralPages)
        #expect(off.current(chosen: .azureDevOpsMyWork) == .azureDevOpsPullRequests)
        #expect(off.page(for: .azureDevOpsMyWork) == nil)
    }

    /// As My Work comes, the window stays at the page it showed, even one chosen before My Work last went; once My Work goes
    /// while it shows, the window shows Pull Requests, for good, rather than its Overview until My Work comes back.
    @Test func aWindowKeepsWhatItShowsAsACompanionComesAndGoes() {
        let sections: [SectionID] = [.teamsChats, .azureDevOpsPullRequests]
        let on = WindowPages(sections: sections, companions: [.azureDevOpsPullRequests: [.azureDevOpsMyWork]])
        let off = WindowPages(sections: sections)
        #expect(off.keepingShown(.azureDevOpsMyWork, from: on) == .azureDevOpsPullRequests)
        #expect(on.keepingShown(.azureDevOpsMyWork, from: off) == WindowPages.overview)
        #expect(on.keepingShown(.azureDevOpsPullRequests, from: off) == nil)
        #expect(off.keepingShown(.teamsChats, from: on) == nil)
        #expect(off.keepingShown(nil, from: on) == nil)

        // A window with Pull Requests alone shows it, not My Work, which would come first.
        let alone = WindowPages(sections: [.azureDevOpsPullRequests])
        let aloneOn = WindowPages(sections: [.azureDevOpsPullRequests], companions: [.azureDevOpsPullRequests: [.azureDevOpsMyWork]])
        #expect(aloneOn.keepingShown(nil, from: alone) == .azureDevOpsPullRequests)
        #expect(alone.keepingShown(.azureDevOpsMyWork, from: aloneOn) == .azureDevOpsPullRequests)
    }
}
