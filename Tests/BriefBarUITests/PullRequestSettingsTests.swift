import BriefBarCore
import Testing
@testable import BriefBarUI

/// The Settings window's Pull Requests page: each setting about pull requests once, under the sources it works with, and
/// what it says while they're off.
@Suite struct PullRequestSettingsTests {
    private let azureDevOps = ["Show To Review in the Menu Bar", "Make Changes in Azure DevOps"]

    @Test func listsTheSharedSettingsFirstThenEachSourcesOwn() {
        let groups = PullRequestSettings.groups([
            (id: .teams, settings: []), (id: .azureDevOps, settings: azureDevOps), (id: .copilot, settings: []),
            (id: .github, settings: []),
        ])
        #expect(groups == [
            PullRequestSettings.Group(sources: [.azureDevOps, .github], settings: ["Pull Request Order"]),
            PullRequestSettings.Group(sources: [.azureDevOps], settings: azureDevOps),
        ])
        // Each once.
        let names = groups.flatMap(\.settings)
        #expect(Set(names).count == names.count)
    }

    @Test func saysWhereEachGroupWorks() {
        #expect(PullRequestSettings.place(["Azure DevOps", "GitHub"]) == "Azure DevOps and GitHub")
        #expect(PullRequestSettings.place(["Azure DevOps"]) == "Azure DevOps only")
        #expect(PullRequestSettings.place(["Azure DevOps", "GitHub", "Teams"]) == "Azure DevOps, GitHub and Teams")
    }

    /// Pull Request Order is GitHub's too, though GitHub has none of its own; Teams and Copilot have none.
    @Test func knowsWhichSourcesHaveSettingsThere() {
        #expect(PullRequestSettings.has(.azureDevOps, ownSettings: azureDevOps))
        #expect(PullRequestSettings.has(.github, ownSettings: []))
        #expect(!PullRequestSettings.has(.teams, ownSettings: []))
        #expect(!PullRequestSettings.has(.copilot, ownSettings: []))
    }

    @Test func saysASourcesSettingsWorkOnlyWhileItsOn() {
        let notice = { (state: SourceState, count: Int) in
            PullRequestSettings.notice(names: ["Azure DevOps"], states: [state], count: count)
        }
        #expect(notice(.on, 8) == nil)
        #expect(notice(.off, 8) == "Azure DevOps is off: these work once you turn it on.")
        #expect(notice(.off, 1) == "Azure DevOps is off: it works once you turn it on.")
        #expect(notice(.needsReview, 8)
            == "Azure DevOps is paused until you look at what it reads now: these work once it's on again.")
    }

    /// Shared settings work with whichever of their sources is on, so they say nothing while one is.
    @Test func saysSharedSettingsWorkWithWhicheverSourceIsOn() {
        let names = ["Azure DevOps", "GitHub"]
        #expect(PullRequestSettings.notice(names: names, states: [.on, .off], count: 1) == nil)
        #expect(PullRequestSettings.notice(names: names, states: [.needsReview, .on], count: 1) == nil)
        let neither = "Neither Azure DevOps nor GitHub is on: it works with the pull requests of whichever you turn on."
        #expect(PullRequestSettings.notice(names: names, states: [.off, .off], count: 1) == neither)
        #expect(PullRequestSettings.notice(names: names, states: [.off, .needsReview], count: 1) == neither)
    }
}
