import AzureDevOpsCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// The pull requests you watch are kept in the preferences, by their links: they're your choice, like your
/// organizations, not something read from Notification Center.
@MainActor
@Suite struct WatchSettingsTests {
    private func link(_ number: Int) -> PullRequestLink {
        PullRequestLink(organization: "contoso", project: "Shop", repository: "web", number: number)
    }

    @Test func watchesAndStopsWatching() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.watchedPullRequests.isEmpty)
        #expect(settings.watch(link(7)))
        #expect(!settings.watch(link(7)))
        #expect(settings.watch(link(8)))
        #expect(settings.isWatching(PRKey("contoso", 7)))
        #expect(settings.watchedKeys == [PRKey("contoso", 7), PRKey("contoso", 8)])

        // Kept for the next launch, and for the command line.
        #expect(AppSettings(defaults: defaults).watchedPullRequests == [link(7), link(8)])

        settings.unwatch([PRKey("contoso", 7), PRKey("contoso", 99)])
        #expect(settings.watchedPullRequests == [link(8)])
        #expect(AppSettings(defaults: defaults).watchedPullRequests == [link(8)])
    }

    @Test func somethingUnreadableWatchesNothing() {
        let defaults = MemoryDefaults()
        defaults.set(Data("not json".utf8), forKey: SettingsKey.watchedPullRequests)
        #expect(AppSettings(defaults: defaults).watchedPullRequests.isEmpty)
    }
}
