import AzureDevOpsCore
import BriefBarCore
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

    /// Everything the preferences hold, as text: what any program running as you could read there. JSON, as the seen
    /// state is saved, escapes `/` as `\/`, so that's undone: "contoso/7" is found as it would be read.
    private func readable(_ defaults: MemoryDefaults) -> String {
        defaults.dictionaryRepresentation().map { key, value in
            "\(key)=" + ((value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)")
        }.sorted().joined(separator: "\n").replacingOccurrences(of: "\\/", with: "/")
    }

    /// The check below would see a pull request saved the way the seen state saves one.
    @Test func wouldSeeAPullRequestSavedAsJSON() throws {
        let defaults = MemoryDefaults()
        defaults.set(try JSONEncoder().encode([sentInChat.description: now]), forKey: "leak")
        #expect(readable(defaults).contains("contoso/7"))
    }

    /// The stage you set on one listed only because someone sent it to you stays in memory, as what you've seen of it
    /// does; one you watch is kept, as what you've seen of it is.
    @Test func theStageYouSetOnOneSentToYouStaysOutOfThePreferences() {
        let defaults = preferences(enabled: true)
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let order = PullRequestOrder(defaults: defaults, isDemo: false, now: { self.now })
        let records = [sentInChat, yours].map { key in
            PRRecord(pullRequest: PullRequest(
                key: key, title: "Pull request \(key.number)", author: Person(id: "dana", name: "Dana Whitfield"), createdAt: now,
                projectId: "shop", projectName: "Shop", repositoryId: "web", repositoryName: "web"
            ), role: .linked, me: "robin")
        }
        // Both listed, as one that needs you and one you watch are.
        let stages = PullRequestOrderFacts.stages(records, items: [], tasks: [], watched: [yours]).mapValues { facts in
            var listed = facts
            listed.isListed = true
            return listed
        }
        order.publish(.azureDevOps, stages: stages, account: "robin@contoso.com")
        let before = readable(defaults)

        #expect(order.setStage(.yourReview, of: sentInChat.linkRef) == .done)
        #expect(order.stage(of: sentInChat.linkRef)?.stage == .yourReview)
        #expect(readable(defaults) == before)

        #expect(order.setStage(.yourReview, of: yours.linkRef) == .done)
        let after = readable(defaults)
        #expect(after.contains("contoso/9"))
        #expect(!after.contains("contoso/7"))
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

    /// What you've seen of one sent to you, and took off Needs You, is the same however its organization is spelled: Azure
    /// DevOps ignores the case of organizations' names.
    @Test func whatYouveSeenOfOneSentToYouIsTheSameHoweverItsOrganizationIsSpelled() {
        let settings = AppSettings(defaults: preferences(enabled: true), now: now)
        let spelledAnotherWay = PRKey("Contoso", 7)
        settings.markSeen([spelledAnotherWay], at: now.addingTimeInterval(60), sentInChats: [spelledAnotherWay])
        settings.dismiss([(key: spelledAnotherWay, date: now.addingTimeInterval(30))], sentInChats: [spelledAnotherWay])
        #expect(settings.seenCutoff(for: sentInChat) == now.addingTimeInterval(60))
        #expect(settings.dismissedCutoff(for: sentInChat) == now.addingTimeInterval(30))
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

    /// Taking a pull request off Needs You is remembered like seeing it: yours in the preferences, and one listed only
    /// because someone sent it to you in memory only.
    @Test func takesThemOffNeedsYouInMemoryOnly() throws {
        let defaults = preferences(enabled: true)
        let settings = AppSettings(defaults: defaults, now: now)
        settings.startSeeing(now: now)
        #expect(settings.addChatLinks([link(7, sentAt: now)], now: now))
        let before = readable(defaults)

        settings.dismiss([(key: sentInChat, date: now)], sentInChats: [sentInChat])
        #expect(settings.dismissedCutoff(for: sentInChat) == now)
        #expect(settings.seenCutoff(for: sentInChat) == now)
        #expect(readable(defaults) == before)

        settings.dismiss([(key: yours, date: now)])
        #expect(settings.dismissedCutoff(for: yours) == now)
        #expect(try savedSeen(in: defaults).dismissedAt.keys.sorted() == ["contoso/9"])
        #expect(AppSettings(defaults: defaults, now: now).dismissedCutoff(for: yours) == now)

        // Forgotten with the links, or when someone else signs in.
        settings.chatLinksEnabled = false
        #expect(settings.dismissedCutoff(for: sentInChat) < now)
        #expect(!settings.useAccount("avery@contoso.example", now: now))
        settings.dismiss([(key: sentInChat, date: now)], sentInChats: [sentInChat])
        #expect(settings.useAccount("sam@contoso.example", now: now))
        #expect(settings.dismissedCutoff(for: sentInChat) < now)
    }

    /// You took them off Needs You long ago and have looked at them since, then they aren't listed anymore: Dana's link
    /// expired, and your organization isn't chosen. Pruning keeps when you took them off for as long as when you looked at
    /// them, in memory as in the preferences, so once a new link or your organization brings them back with something new,
    /// what you took off stays off.
    @Test func keepsWhatYouTookOffForAsLongAsWhatYouSaw() throws {
        let defaults = preferences(enabled: true)
        // BriefBar has run for months.
        let firstRun = now.addingTimeInterval(-200 * 86_400)
        let settings = AppSettings(defaults: defaults, now: firstRun)
        settings.startSeeing(now: firstRun)
        let tookOff = now.addingTimeInterval(-70 * 86_400)
        let looked = now.addingTimeInterval(-86_400)
        settings.dismiss([(key: sentInChat, date: tookOff)], sentInChats: [sentInChat])
        settings.markSeen([sentInChat], at: looked, sentInChats: [sentInChat])
        settings.dismiss([(key: yours, date: tookOff)])
        settings.markSeen([yours], at: looked)

        settings.pruneSeen(keeping: [], now: now)
        for key in [sentInChat, yours] {
            #expect(settings.seenCutoff(for: key) == looked)
            #expect(settings.dismissedCutoff(for: key) == tookOff)
        }
        #expect(!readable(defaults).contains("contoso/7"))
        #expect(try savedSeen(in: defaults).dismissedAt.keys.sorted() == ["contoso/9"])
        #expect(AppSettings(defaults: defaults, now: now).dismissedCutoff(for: yours) == tookOff)

        // Once you last looked at them two months ago and more, both go.
        settings.pruneSeen(keeping: [], now: looked.addingTimeInterval(61 * 86_400))
        for key in [sentInChat, yours] {
            #expect(settings.seenCutoff(for: key) < tookOff)
            #expect(settings.dismissedCutoff(for: key) < tookOff)
        }
    }

    @Test func movesWhatAnEarlierBuildTookOffNeedsYouIntoMemory() throws {
        let defaults = preferences(enabled: true)
        var earlier = SeenState.firstRun(now: now)
        earlier.dismiss([sentInChat, yours], at: now)
        defaults.set(try JSONEncoder().encode(earlier), forKey: SettingsKey.seen)
        let settings = AppSettings(defaults: defaults, now: now)

        settings.keepSeenInMemory([sentInChat])
        let saved = try savedSeen(in: defaults)
        #expect(saved.dismissedAt.keys.sorted() == ["contoso/9"])
        #expect(saved.seenAt.keys.sorted() == ["contoso/9"])
        #expect(settings.dismissedCutoff(for: sentInChat) == now)
        #expect(settings.seenCutoff(for: sentInChat) == now)
    }

    /// The threads you mark as read are remembered like what you've seen: yours in the preferences, and those of one listed
    /// only because someone sent it to you in memory only, forgotten with the links, when someone else signs in, or with
    /// what you saw of it; and what another program put in the preferences for one moves into memory.
    @Test func keepsTheThreadsYouMarkAsReadThereInMemoryOnly() throws {
        let defaults = preferences(enabled: true)
        let settings = AppSettings(defaults: defaults, now: now)
        settings.startSeeing(now: now)
        #expect(!settings.useAccount("avery@contoso.example", now: now))
        #expect(settings.addChatLinks([link(7, sentAt: now)], now: now))
        let before = readable(defaults)

        settings.markRead(5, of: sentInChat, upTo: now, for: settings.account, sentInChat: true)
        #expect(settings.readThreads(of: sentInChat) == [5: now])
        #expect(readable(defaults) == before)
        settings.markRead(5, of: yours, upTo: now, for: settings.account)
        #expect(try savedSeen(in: defaults).readThreads.keys.sorted() == ["contoso/9"])
        #expect(AppSettings(defaults: defaults, now: now).readThreads(of: yours) == [5: now])

        // Not for another account, whose isn't kept in memory.
        settings.markRead(6, of: sentInChat, upTo: now, for: "sam@contoso.example", sentInChat: true)
        #expect(settings.readThreads(of: sentInChat) == [5: now])
        #expect(settings.useAccount("sam@contoso.example", now: now))
        #expect(settings.readThreads(of: sentInChat).isEmpty)
        #expect(settings.useAccount("avery@contoso.example", now: now))
        settings.markRead(5, of: sentInChat, upTo: now, for: settings.account, sentInChat: true)
        settings.chatLinksEnabled = false
        #expect(settings.readThreads(of: sentInChat).isEmpty)

        // Seen long ago, and not listed: gone with what you saw of it.
        settings.markSeen([sentInChat], at: now, sentInChats: [sentInChat])
        settings.markRead(5, of: sentInChat, upTo: now, for: settings.account, sentInChat: true)
        settings.pruneSeen(keeping: [sentInChat, yours], now: now.addingTimeInterval(61 * 86_400))
        #expect(settings.readThreads(of: sentInChat) == [5: now])
        settings.pruneSeen(keeping: [yours], now: now.addingTimeInterval(61 * 86_400))
        #expect(settings.readThreads(of: sentInChat).isEmpty)
        #expect(settings.readThreads(of: yours) == [5: now])

        var earlier = try savedSeen(in: defaults)
        earlier.markRead(8, of: sentInChat, upTo: now)
        defaults.set(try JSONEncoder().encode(earlier), forKey: SettingsKey.seen)
        let again = AppSettings(defaults: defaults, now: now)
        again.keepSeenInMemory([sentInChat])
        #expect(try savedSeen(in: defaults).readThreads.keys.sorted() == ["contoso/9"])
        #expect(again.readThreads(of: sentInChat) == [8: now])
    }

    /// As the list does it: clearing Needs You, in the demo, keeps what you've seen of the pull request Dana sent you
    /// in memory, and of the others in the preferences.
    @Test func theListKeepsWhatYouveSeenOfPullRequestsSentInChatsInMemory() async throws {
        let defaults = preferences(enabled: false)
        let settings = AppSettings(defaults: defaults)
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .demo)
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

    /// What you change of the mission of a pull request sent to you only in a chat stays in memory, while the
    /// preferences keep the rest of the same change. The pull requests are the demo's, Dana's sent in a chat among
    /// them; the order is an ordinary one, with Pull Request Order on, as outside the demo.
    @Test func whatYouChangeOfTheMissionOfOneSentToYouStaysInMemory() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let orderDefaults = MemoryDefaults()
        orderDefaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let order = PullRequestOrder(defaults: orderDefaults, isDemo: false)
        let demo = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        await demo.loadOnce()
        let sent = try #require(demo.records.first { $0.role == .linked })
        let yours = try #require(demo.records.first { $0.role == .author && $0.pullRequest.status == .active })
        order.publish(
            .azureDevOps, pullRequests: PullRequestOrderFacts.pullRequests(demo.records, items: demo.items, showToReview: false),
            inMemory: PullRequestOrderFacts.sentInChats(demo.records, watched: settings.watchedKeys)
        )

        order.change(.move([sent.id.linkRef, yours.id.linkRef], to: .into(.mine(UUID())), from: nil))

        #expect(order.changes[sent.id.linkRef] != nil && order.changes[yours.id.linkRef] != nil)
        #expect(OrderChanges.load(from: orderDefaults).all.map(\.ref) == [yours.id.linkRef])
    }
}
