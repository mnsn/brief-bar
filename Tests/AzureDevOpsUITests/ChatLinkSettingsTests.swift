import AzureDevOpsCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Pull requests sent in chats: the links found, with who sent them, and what you've seen of the pull requests listed
/// only because of them, are kept in memory only, since any program running as you can read the preferences.
@MainActor
@Suite struct ChatLinkSettingsTests {
    private let now = Date(timeIntervalSince1970: 1_792_317_600)
    /// Listed only because Dana sent it.
    private let sentInChat = PRKey("contoso", 7)
    /// One you review.
    private let yours = PRKey("contoso", 9)

    private func link(_ number: Int, sentAt: Date) -> ChatLink {
        ChatLink(link: PullRequestLink(organization: "contoso", project: "Shop", repository: "web", number: number),
                 app: "com.microsoft.teams2", sender: "Dana Whitfield", sentAt: sentAt, notificationKey: "n\(number)",
                 conversation: "19:dana-and-you@unq.gbl.spaces", messageID: "1792317000000")
    }

    /// Preferences in memory, so the tests leave nothing in ~/Library/Preferences, with the feature on or off.
    private func preferences(enabled: Bool) -> MemoryDefaults {
        let defaults = MemoryDefaults()
        defaults.set(enabled, forKey: SettingsKey.chatLinksEnabled)
        return defaults
    }

    /// Everything the preferences hold, as text: what any program running as you could read there.
    private func readable(_ defaults: MemoryDefaults) -> String {
        defaults.dictionaryRepresentation().map { key, value in
            "\(key)=" + ((value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)")
        }.sorted().joined(separator: "\n")
    }

    private func savedSeen(in defaults: MemoryDefaults) throws -> SeenState {
        try JSONDecoder().decode(SeenState.self, from: try #require(defaults.data(forKey: SettingsKey.seen)))
    }

    @Test func keepsNothingFromChatsInThePreferences() {
        let defaults = preferences(enabled: true)
        let settings = AppSettings(defaults: defaults, now: now)
        settings.startSeeing(now: now)
        let before = readable(defaults)

        #expect(settings.addChatLinks([link(7, sentAt: now)], now: now))
        settings.markSeen([sentInChat], at: now.addingTimeInterval(60), sentInChats: [sentInChat])
        #expect(settings.chatLinks.links.count == 1)
        #expect(settings.seenCutoff(for: sentInChat) == now.addingTimeInterval(60))

        let after = readable(defaults)
        #expect(after == before)
        for found in ["Dana Whitfield", "contoso/7", "dana-and-you", "1792317000000", "teams2"] {
            #expect(!after.contains(found), "The preferences say \(found)")
        }
    }

    @Test func remembersWhatYouveSeenOfYourOwnPullRequestsInThePreferences() throws {
        let defaults = preferences(enabled: true)
        let settings = AppSettings(defaults: defaults, now: now)
        settings.markSeen([(key: sentInChat, date: now), (key: yours, date: now)], sentInChats: [sentInChat])
        let saved = try savedSeen(in: defaults)
        #expect(saved.seenAt.keys.sorted() == ["contoso/9"])
        #expect(settings.seenCutoff(for: sentInChat) == now)
        #expect(settings.seenCutoff(for: yours) == now)

        // The next launch remembers yours, and only those.
        let again = AppSettings(defaults: defaults, now: now)
        #expect(again.seenCutoff(for: yours) == now)
        #expect(again.seenCutoff(for: sentInChat) < now)
    }

    @Test func removesTheLinksAnEarlierBuildSavedWhateverTheSetting() throws {
        for enabled in [true, false] {
            let defaults = preferences(enabled: enabled)
            defaults.set(try JSONEncoder().encode(ChatLinkState(links: [link(7, sentAt: now)])), forKey: SettingsKey.chatLinks)
            let settings = AppSettings(defaults: defaults, now: now)
            #expect(defaults.object(forKey: SettingsKey.chatLinks) == nil)
            #expect(settings.chatLinks.links.isEmpty)
            #expect(!readable(defaults).contains("Dana Whitfield"))
        }
    }

    @Test func movesWhatAnEarlierBuildSawOfThemIntoMemory() throws {
        let defaults = preferences(enabled: true)
        var earlier = SeenState.firstRun(now: now)
        earlier.markSeen([sentInChat, yours], at: now)
        defaults.set(try JSONEncoder().encode(earlier), forKey: SettingsKey.seen)
        let settings = AppSettings(defaults: defaults, now: now)

        settings.keepSeenInMemory([sentInChat])
        #expect(try savedSeen(in: defaults).seenAt.keys.sorted() == ["contoso/9"])
        #expect(settings.seenCutoff(for: sentInChat) == now)
        #expect(settings.seenCutoff(for: yours) == now)
    }

    @Test func turningItOffForgetsTheLinksAndWhatYouSawOfThem() {
        let settings = AppSettings(defaults: preferences(enabled: true), now: now)
        #expect(settings.addChatLinks([link(7, sentAt: now)], now: now))
        settings.markSeen([sentInChat], at: now, sentInChats: [sentInChat])

        settings.chatLinksEnabled = false
        #expect(settings.chatLinks.links.isEmpty)
        #expect(settings.seenCutoff(for: sentInChat) < now)
        // And nothing is kept while it's off.
        #expect(!settings.addChatLinks([link(7, sentAt: now)], now: now))
        #expect(settings.chatLinks.links.isEmpty)
    }

    @Test func forgetsLinksThatExpireWhileItRuns() {
        let settings = AppSettings(defaults: preferences(enabled: true), now: now)
        #expect(settings.addChatLinks([link(7, sentAt: now)], now: now))
        #expect(!settings.addChatLinks([], now: now.addingTimeInterval(ChatLinkState.keepFor + 60)))
        #expect(settings.chatLinks.links.isEmpty)
    }

    @Test func anotherAccountHasNotSeenThem() {
        let settings = AppSettings(defaults: preferences(enabled: true), now: now)
        #expect(!settings.useAccount("avery@contoso.example", now: now))
        settings.markSeen([sentInChat], at: now, sentInChats: [sentInChat])
        #expect(settings.useAccount("sam@contoso.example", now: now))
        #expect(settings.seenCutoff(for: sentInChat) < now)
    }

    /// As the list does it: clearing Needs You, in the demo, keeps what you've seen of the pull request Dana sent you
    /// in memory, and of the others in the preferences.
    @Test func theListKeepsWhatYouveSeenOfPullRequestsSentInChatsInMemory() async throws {
        let defaults = preferences(enabled: false)
        let settings = AppSettings(defaults: defaults)
        let store = PRStore(settings: settings, mode: .demo)
        await store.loadOnce()
        let needsYou = store.items(in: .needsYou)
        let sent = try #require(needsYou.first { $0.role == .linked })
        #expect(needsYou.contains { $0.role != .linked })

        store.clear(.needsYou)
        let saved = try savedSeen(in: defaults)
        #expect(saved.seenAt[sent.key.description] == nil)
        #expect(settings.seenSentInChats[sent.key.description] != nil)
        #expect(Set(saved.seenAt.keys) == Set(needsYou.filter { $0.role != .linked }.map(\.key.description)))
    }
}
