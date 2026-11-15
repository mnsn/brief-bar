import BriefBarCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Where Azure DevOps' settings show: in the Settings window each once, on its own page, on the Pull Requests page for those
/// about its pull requests, or, for Send Work to Copilot, on the Send to Copilot page, kept where they always were; and in its
/// menus only those you'd change in the moment.
@MainActor
@Suite struct SettingsPlacesTests {
    private let aboutPullRequests: [AzureDevOpsSetting] = [
        .showToReview, .followMerges, .opensPullRequestsInBriefBar, .chatLinks, .keepDone, .idle, .watchedPullRequests,
        .makesChanges,
    ]

    /// Notifications, say for a meeting, and a pull request to watch from a link you've just been sent; refresh intervals,
    /// how long things are kept, organizations, and what sends or writes are only in Settings.
    @Test func theMenusHaveOnlyThoseForTheMoment() {
        #expect(AzureDevOpsSettings.Place.menu.settings == [.notifications, .watchedPullRequests])
        #expect(AzureDevOpsSettings.Place.menu.groups.count == 2)
    }

    @Test func theSettingsWindowShowsEachOnce() {
        let shown = [AzureDevOpsSettings.Place.ownPage, .pullRequestsPage, .sendToCopilotPage].flatMap(\.settings)
        #expect(Set(shown) == Set(AzureDevOpsSetting.allCases))
        #expect(shown.count == AzureDevOpsSetting.allCases.count)
    }

    /// Those about its pull requests are on the Pull Requests page, and Send Work to Copilot on a page of its own; the rest,
    /// about all it reads, stayed on its page.
    @Test func eachIsOnItsPage() {
        #expect(AzureDevOpsSettings.Place.pullRequestsPage.settings == aboutPullRequests)
        #expect(AzureDevOpsSettings.Place.sendToCopilotPage.settings == [.copilot])
        #expect(AzureDevOpsSettings.Place.ownPage.settings == [.notifications, .summaries, .refresh, .organizations])
    }

    /// Send to Copilot shows Send Work to Copilot whether Azure DevOps is on or not: disabled while it's off or paused.
    @Test func sendToCopilotShowsItsSettingsWhileAzureDevOpsIsOff() {
        let source = AzureDevOpsSource(services: AppServices(defaults: MemoryDefaults(), isDemo: true), summarizer: .withoutModel)
        #expect(source.hasSendToCopilotSettings)
        #expect(source.sendToCopilotSettingsView(state: .off) != nil)
        #expect(source.sendToCopilotSettingsView(state: .needsReview) != nil)
    }

    /// The page lists each of them once, under Azure DevOps only, after Pull Request Order, which works with GitHub's too: My
    /// Work Page first, which works only with Azure DevOps' pull requests.
    @Test func thePullRequestsPageListsEachOnceWithWhereItWorks() {
        let source = AzureDevOpsSource(services: AppServices(defaults: MemoryDefaults(), isDemo: true), summarizer: .withoutModel)
        #expect(source.pullRequestSettings == [
            "My Work Page (preview)", "Show To Review in the Menu Bar", "Follow Pipelines After You Merge", "Open Pull Requests in BriefBar",
            "Pull Requests Sent in Chats", "Keep Done For", "Idle After No Activity For", "Watched Pull Requests",
            "Make Changes in Azure DevOps",
        ])
        let groups = PullRequestSettings.groups([(id: source.id, settings: source.pullRequestSettings)])
        #expect(groups.map(\.sources) == [[.azureDevOps, .github], [.azureDevOps]])
        #expect(groups.first?.settings == ["Pull Request Order"])
        let names = groups.flatMap(\.settings)
        #expect(Set(names).count == names.count)
        // Whatever it's called on the page, as the menus call it.
        #expect(names.dropFirst(2) == ArraySlice(aboutPullRequests.map(\.title)))
        // And they show while it's off, as well as on.
        #expect(source.pullRequestSettingsView(state: .off) != nil)
        #expect(source.pullRequestSettingsView(state: .needsReview) != nil)
    }

    /// Moving them changed where they show, not what they're kept as: each keeps its key and its default, off for what
    /// you may not want.
    @Test func eachKeepsItsKeyAndDefault() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.showToReview)
        #expect(settings.followMerges)
        #expect(!settings.opensPullRequestsInBriefBar)
        #expect(!settings.chatLinksEnabled)
        #expect(settings.keepDoneHours == 24)
        #expect(settings.idleDays == 14)
        #expect(settings.watchedPullRequests.isEmpty)
        #expect(!settings.makesChanges)
        #expect(defaults.dictionaryRepresentation().isEmpty)

        settings.showToReview = true
        settings.followMerges = false
        settings.opensPullRequestsInBriefBar = true
        settings.keepDoneHours = 72
        settings.idleDays = 0
        settings.makesChanges = true
        #expect(defaults.bool(forKey: "ado.showToReviewInMenuBar"))
        #expect(defaults.object(forKey: "ado.followMerges") as? Bool == false)
        #expect(defaults.bool(forKey: "ado.opensPullRequestsInBriefBar"))
        #expect(defaults.integer(forKey: "ado.keepDoneHours") == 72)
        #expect(defaults.object(forKey: "ado.idleDays") as? Int == 0)
        #expect(defaults.bool(forKey: "ado.makeChanges"))
        #expect(SettingsKey.chatLinksEnabled == "ado.chatLinksEnabled")
        #expect(SettingsKey.watchedPullRequests == "ado.watchedPullRequests")
    }
}
