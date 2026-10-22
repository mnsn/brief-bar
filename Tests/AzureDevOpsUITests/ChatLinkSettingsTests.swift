import AzureDevOpsCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Pull requests sent in chats: the links found, with who sent them, are kept in the preferences only while the
/// feature is on and until they expire, and turning it off forgets them there too, not only in memory.
@MainActor
@Suite struct ChatLinkSettingsTests {
    private let now = Date(timeIntervalSince1970: 1_792_317_600)

    /// Sent longer ago than links are kept.
    private var expired: Date { now.addingTimeInterval(-ChatLinkState.keepFor - 3_600) }

    private func link(_ number: Int, sentAt: Date) -> ChatLink {
        ChatLink(link: PullRequestLink(organization: "contoso", project: "Shop", repository: "web", number: number),
                 app: "com.microsoft.teams2", sender: "Dana Whitfield", sentAt: sentAt, notificationKey: "n\(number)")
    }

    /// Preferences in memory, so the tests leave nothing in ~/Library/Preferences, with the feature on or off and
    /// these links saved.
    private func preferences(enabled: Bool, saving links: [ChatLink]? = nil) throws -> MemoryDefaults {
        let defaults = MemoryDefaults()
        defaults.set(enabled, forKey: SettingsKey.chatLinksEnabled)
        if let links {
            try save(links, in: defaults)
        }
        return defaults
    }

    private func save(_ links: [ChatLink], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(ChatLinkState(links: links)), forKey: SettingsKey.chatLinks)
    }

    /// The pull requests whose links the preferences hold; nil when they hold nothing.
    private func saved(in defaults: UserDefaults) throws -> [Int]? {
        try defaults.data(forKey: SettingsKey.chatLinks).map {
            try JSONDecoder().decode(ChatLinkState.self, from: $0).links.map(\.key.number)
        }
    }

    @Test func turningItOffForgetsLinksThatHadExpired() throws {
        // Every link saved has expired by the time BriefBar starts.
        let defaults = try preferences(enabled: true, saving: [link(1, sentAt: expired)])
        let settings = AppSettings(defaults: defaults, now: now)
        #expect(settings.chatLinks.links.isEmpty)

        settings.chatLinksEnabled = false
        #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
    }

    @Test func forgettingRemovesWhatThePreferencesHaveNotOnlyWhatsInMemory() throws {
        let defaults = try preferences(enabled: true)
        let settings = AppSettings(defaults: defaults, now: now)
        // Links in the preferences that the settings don't have.
        try save([link(1, sentAt: now)], in: defaults)
        #expect(settings.chatLinks.links.isEmpty)

        settings.forgetChatLinks()
        #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
    }

    @Test func turningItOffForgetsTheLinksFoundAtOnce() throws {
        let defaults = try preferences(enabled: true)
        let settings = AppSettings(defaults: defaults, now: now)
        #expect(settings.addChatLinks([link(1, sentAt: now)], now: now))
        let stored = try saved(in: defaults)
        #expect(stored == [1])

        // Without waiting for the pull requests' store to hear of it, as when BriefBar quits right away.
        settings.chatLinksEnabled = false
        #expect(settings.chatLinks.links.isEmpty)
        #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
    }

    @Test func linksThatExpiredGoFromThePreferencesWhenItStarts() throws {
        let some = try preferences(enabled: true, saving: [link(1, sentAt: expired), link(2, sentAt: now)])
        let settings = AppSettings(defaults: some, now: now)
        #expect(settings.chatLinks.links.map(\.key.number) == [2])
        let stored = try saved(in: some)
        #expect(stored == [2])

        let all = try preferences(enabled: true, saving: [link(1, sentAt: expired)])
        _ = AppSettings(defaults: all, now: now)
        #expect(all.object(forKey: SettingsKey.chatLinks) == nil)
    }

    @Test func linksThatExpireWhileItRunsGoFromThePreferences() throws {
        let defaults = try preferences(enabled: true, saving: [link(1, sentAt: now)])
        let settings = AppSettings(defaults: defaults, now: now)
        let stored = try saved(in: defaults)
        #expect(stored == [1])

        // Nothing new a while later: the link has expired, which leaves no list behind, not even an empty one.
        #expect(!settings.addChatLinks([], now: now.addingTimeInterval(ChatLinkState.keepFor + 60)))
        #expect(settings.chatLinks.links.isEmpty)
        #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
    }

    @Test func linksLeftWhileItsOffGoWhenItStarts() throws {
        let defaults = try preferences(enabled: false, saving: [link(1, sentAt: now)])
        let settings = AppSettings(defaults: defaults, now: now)
        #expect(settings.chatLinks.links.isEmpty)
        #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
    }

    @Test func linksItCantReadGoWhenItStarts() throws {
        let defaults = try preferences(enabled: true)
        defaults.set(Data("Dana Whitfield sent !7, in another format".utf8), forKey: SettingsKey.chatLinks)
        let settings = AppSettings(defaults: defaults, now: now)
        #expect(settings.chatLinks.links.isEmpty)
        #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
    }

    @Test func nothingIsKeptWhileItsOff() throws {
        let defaults = try preferences(enabled: false)
        let settings = AppSettings(defaults: defaults, now: now)
        #expect(!settings.addChatLinks([link(1, sentAt: now)], now: now))
        #expect(settings.chatLinks.links.isEmpty)
        #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
    }
}
