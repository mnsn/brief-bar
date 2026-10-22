import AzureDevOpsCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Only the app itself reads Notification Center for pull requests sent in chats: the store and the source read nothing
/// there unless given `ChatReading.notificationCenter()`, so `--render`, the demo and these tests can't, even with the
/// feature on. A stand-in replaces Notification Center here.
@MainActor
@Suite struct ChatReadingTests {
    /// Notification Center as a stand-in, holding one link Dana sent, which notes how often it's watched.
    @MainActor
    private final class StandIn {
        private(set) var watched = 0
        let link = ChatLink(
            link: PullRequestLink(organization: "contoso", project: "Shop", repository: "web", number: 7),
            app: "com.microsoft.teams2", sender: "Dana Whitfield", sentAt: Date(), notificationKey: "n7",
            conversation: "19:dana-and-you@unq.gbl.spaces", messageID: "1792317000000"
        )

        var reading: ChatReading {
            let database = URL(fileURLWithPath: "/nonexistent/db")
            return ChatReading(database: database) { [self] onChange in
                watched += 1
                let link = link
                return ChatLinkMonitor(
                    database: database, deliverOn: .main, scan: { _ in ChatLinkMonitor.Snapshot(access: .granted, links: [link]) },
                    onChange: onChange
                )
            }
        }
    }

    private func settings(enabled: Bool) -> AppSettings {
        let defaults = MemoryDefaults()
        defaults.set(enabled, forKey: SettingsKey.chatLinksEnabled)
        return AppSettings(defaults: defaults)
    }

    @Test func readsNothingUnlessTheAppGivesItNotificationCenter() async {
        // As `--render` makes it: for your own pull requests, with the feature on.
        let store = PRStore(settings: settings(enabled: true))
        store.updateChatMonitor()
        // A monitor would say what it found by now, if only that it may not read.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(store.chatAccess == nil)
        // And the source asks for no Full Disk Access for it.
        #expect(AzureDevOpsSource(services: AppServices(defaults: MemoryDefaults(), isDemo: false)).chats.database == nil)
    }

    @Test func readsThroughWhatTheAppGivesIt() async {
        let standIn = StandIn()
        let settings = settings(enabled: true)
        let store = PRStore(settings: settings, chats: standIn.reading)
        store.updateChatMonitor()
        for _ in 0..<100 where settings.chatLinks.links.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(standIn.watched == 1)
        #expect(store.chatAccess == .granted)
        #expect(settings.chatLinks.links.map(\.sender) == ["Dana Whitfield"])

        // Turned off, it stops watching, and forgets.
        settings.chatLinksEnabled = false
        store.updateChatMonitor()
        #expect(settings.chatLinks.links.isEmpty)
        #expect(store.chatAccess == nil)
    }

    @Test func theDemoNeverReadsIt() {
        let standIn = StandIn()
        let store = PRStore(settings: settings(enabled: true), mode: .demo, chats: standIn.reading)
        store.updateChatMonitor()
        #expect(standIn.watched == 0)
    }
}
