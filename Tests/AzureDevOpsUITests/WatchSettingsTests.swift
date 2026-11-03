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

    /// Azure DevOps ignores the letter case of an organization's name, so a link that spells it differently is to the same
    /// pull request: one in your lists is listed once, as one you watch, and stopping watching it from its row works.
    @Test func aLinkThatSpellsTheOrganizationDifferentlyWatchesThePullRequestListed() throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        #expect(settings.watch(PullRequestLink(organization: "CONTOSO", project: "Storefront", repository: "search", number: 4071)))
        #expect(settings.isWatching(PRKey(DemoData.organization, 4071)))
        #expect(!settings.watch(PullRequestLink(organization: "Contoso", project: "Storefront", repository: "search", number: 4071)))

        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .demo)
        store.receive(DemoData.snapshot(now: store.now))
        let rows = store.items.filter { $0.key.number == 4071 }
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.key.organization == DemoData.organization)
        #expect(row.isWatched)

        store.stopWatching(row)
        #expect(settings.watchedPullRequests.isEmpty)
    }
}
