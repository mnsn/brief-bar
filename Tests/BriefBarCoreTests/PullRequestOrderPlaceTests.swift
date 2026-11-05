import Testing

/// Each setting shows in one place in the Settings window. Pull Request Order works with Azure DevOps' and GitHub's pull
/// requests, so it's on the Pull Requests page, with the other settings about pull requests, and no longer in General:
/// only that page makes its view. (Azure DevOps' own are placed by `AzureDevOpsSettings.Place`, which its tests check.)
struct PullRequestOrderPlaceTests {
    @Test(.onTestThreads) func pullRequestOrderShowsOnlyOnThePullRequestsPage() throws {
        #expect(try sourcesMatching(/PullRequestOrderSettingView\(/) == ["BriefBar/PullRequestsSettingsPage.swift"])
    }
}
