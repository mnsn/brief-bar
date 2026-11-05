import BriefBarCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Where Azure DevOps' settings show: in its menus all of them, and in the Settings window each once, on its own page or,
/// for those about its pull requests, on the Pull Requests page, kept where they always were.
@MainActor
@Suite struct SettingsPlacesTests {
    private let aboutPullRequests: [AzureDevOpsSetting] = [
        .showToReview, .followMerges, .opensPullRequestsInBriefBar, .chatLinks, .keepDone, .idle, .watchedPullRequests,
        .makesChanges,
    ]

    @Test func theMenusHaveAllOfThem() {
        #expect(AzureDevOpsSettings.Place.menu.settings == AzureDevOpsSetting.allCases)
        #expect(AzureDevOpsSettings.Place.menu.groups.count == 3)
    }

    @Test func theSettingsWindowShowsEachOnce() {
        let own = AzureDevOpsSettings.Place.ownPage.settings
        let pullRequests = AzureDevOpsSettings.Place.pullRequestsPage.settings
        #expect(Set(own).isDisjoint(with: pullRequests))
        #expect(Set(own).union(pullRequests) == Set(AzureDevOpsSetting.allCases))
        #expect(own.count + pullRequests.count == AzureDevOpsSetting.allCases.count)
    }

    /// Those about its pull requests left its page for the Pull Requests page; the rest, about all it reads, stayed.
    @Test func thoseAboutPullRequestsMovedToThePullRequestsPage() {
        #expect(AzureDevOpsSettings.Place.pullRequestsPage.settings == aboutPullRequests)
        #expect(AzureDevOpsSettings.Place.ownPage.settings == [.notifications, .summaries, .refresh, .organizations, .copilot])
    }

    /// The page lists each of them once, under Azure DevOps only, after Pull Request Order, which works with GitHub's too.
    @Test func thePullRequestsPageListsEachOnceWithWhereItWorks() {
        let source = AzureDevOpsSource(services: AppServices(defaults: MemoryDefaults(), isDemo: true), summarizer: .withoutModel)
        #expect(source.pullRequestSettings == [
            "Show To Review in the Menu Bar", "Follow Pipelines After You Merge", "Open Pull Requests in BriefBar",
            "Pull Requests Sent in Chats", "Keep Done For", "Idle After No Activity For", "Watched Pull Requests",
            "Make Changes in Azure DevOps",
        ])
        let groups = PullRequestSettings.groups([(id: source.id, settings: source.pullRequestSettings)])
        #expect(groups.map(\.sources) == [[.azureDevOps, .github], [.azureDevOps]])
        #expect(groups.first?.settings == ["Pull Request Order"])
        let names = groups.flatMap(\.settings)
        #expect(Set(names).count == names.count)
        // Whatever it's called on the page, as the menus call it.
        #expect(names.dropFirst() == ArraySlice(aboutPullRequests.map(\.title)))
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
