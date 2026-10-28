import BriefBarCore
import Foundation
import Testing
@testable import BriefBarUI

@MainActor
@Suite struct RecentNotificationsTests {
    private func note(_ id: String, source: SourceID = .azureDevOps, sumsUp: Bool = false) -> BriefBarNotification {
        BriefBarNotification(
            id: id, source: source, state: .needsYou, title: "Sam Rivera replied", subtitle: "Fix the checkout total", body: "Done.",
            thread: "contoso", userInfo: ["url": "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/4071"], sumsUp: sumsUp
        )
    }

    @Test func thePageIsOffUntilYouTurnItOnAndKeepsWhatItListsForADay() {
        let defaults = MemoryDefaults()
        let recent = RecentNotifications(defaults: defaults, isDemo: false)
        #expect(!recent.isOn)
        #expect(recent.keepHours == 24)
        recent.setOn(true)
        recent.setKeepHours(4)
        let restored = RecentNotifications(defaults: defaults, isDemo: false)
        #expect(restored.isOn)
        #expect(restored.keepHours == 4)
        // Anything else in the preferences is a day.
        defaults.set(5, forKey: RecentNotifications.keepHoursKey)
        #expect(RecentNotifications(defaults: defaults, isDemo: false).keepHours == 24)
        // The demo shows the page, in preferences that are thrown away.
        #expect(RecentNotifications(defaults: MemoryDefaults(), isDemo: true).isOn)
    }

    @Test func itListsWhatWasPostedEvenWhileOffAndShowsOnlyWhileItListsSomething() {
        let recent = RecentNotifications(defaults: MemoryDefaults(), isDemo: false)
        let notifier = Notifier(recent: recent, posts: false)
        // A note that only counts others isn't listed: those it counts are, after the ones posted, the newest first.
        notifier.post([note("a"), note("b"), note("more", sumsUp: true)], more: [note("c"), note("d")])
        #expect(recent.history.entries.map(\.id) == ["a", "b", "c", "d"])
        #expect(recent.history.entries.first { $0.id == "a" }?.state == .needsYou)
        #expect(recent.history.entries.first { $0.id == "a" }?.userInfo["url"] != nil)
        #expect(!recent.showsPage)

        recent.setOn(true)
        #expect(recent.showsPage)
        recent.remove("a")
        #expect(recent.history.entries.count == 3)
        recent.clear()
        #expect(!recent.showsPage)
    }

    @Test func whatThePageShowedIsSeenOnceNothingShowsIt() {
        let recent = RecentNotifications(defaults: MemoryDefaults(), isDemo: false)
        recent.record([note("a"), note("b")])
        recent.pageVisibilityChanged(true, by: "window.main")
        recent.pageVisibilityChanged(true, by: "window.other")
        recent.pageVisibilityChanged(false, by: "window.main")
        #expect(recent.history.unseenCount == 2)
        recent.pageVisibilityChanged(false, by: "window.other")
        #expect(recent.history.unseenCount == 0)

        // Something that never showed it going away changes nothing.
        recent.record([note("c")])
        recent.pageVisibilityChanged(false, by: "window.main")
        #expect(recent.history.unseenCount == 1)
        recent.markSeen("c")
        #expect(recent.history.unseenCount == 0)
    }

    @Test func whatsOlderThanItKeepsGoes() {
        let recent = RecentNotifications(defaults: MemoryDefaults(), isDemo: false)
        recent.record([note("earlier")], at: Date().addingTimeInterval(-5 * 3600))
        recent.record([note("now")])
        #expect(recent.history.entries.map(\.id) == ["now", "earlier"])
        recent.setKeepHours(4)
        #expect(recent.history.entries.map(\.id) == ["now"])
        // Already older than it keeps, it isn't listed at all.
        recent.record([note("late")], at: Date().addingTimeInterval(-5 * 3600))
        #expect(recent.history.entries.map(\.id) == ["now"])
    }

    @Test func aSourceTurnedOffTakesItsNotificationsWithIt() {
        let recent = RecentNotifications(defaults: MemoryDefaults(), isDemo: false)
        recent.record([note("a"), note("b", source: .github)])
        recent.forget(.azureDevOps)
        #expect(recent.history.entries.map(\.id) == ["b"])
    }

    @Test func aNotificationPostedAgainTakesItsPlaceAndOneTakenBackLeavesThePage() {
        let recent = RecentNotifications(defaults: MemoryDefaults(), isDemo: false)
        let notifier = Notifier(recent: recent, posts: false)
        // A Copilot task's, as it starts, then as it ends.
        notifier.post([note("copilot.1"), note("b")])
        notifier.post([note("copilot.1")])
        #expect(recent.history.entries.count == 2)
        // Taken back, as for a task you stopped, it no longer says what's going on.
        notifier.remove(["copilot.1"])
        #expect(recent.history.entries.map(\.id) == ["b"])
    }

    @Test func nothingItListsGoesToThePreferences() {
        let defaults = MemoryDefaults()
        let recent = RecentNotifications(defaults: defaults, isDemo: false)
        recent.setOn(true)
        recent.record([note("a")])
        let saved = defaults.dictionaryRepresentation().description
        #expect(!saved.contains("Sam Rivera"))
        #expect(!saved.contains("Fix the checkout total"))
        #expect(!saved.contains("dev.azure.com"))
    }
}

@MainActor
@Suite struct NotificationClickTests {
    private func makeNotifier(wait: TimeInterval) -> (Notifier, RecentNotifications) {
        let recent = RecentNotifications(defaults: MemoryDefaults(), isDemo: false)
        let notifier = Notifier(recent: recent, posts: false)
        notifier.clickWait = wait
        return (notifier, recent)
    }

    @Test func aClickOpensOnceBriefBarIsInFrontInsteadOfWhatOpeningItShows() {
        let (notifier, recent) = makeNotifier(wait: 60)
        var opened: [NotificationClick] = []
        notifier.onOpen = { opened.append($0) }
        recent.record([BriefBarNotification(id: "a", source: .azureDevOps, title: "Sam Rivera replied", body: "Done.", thread: "t")])

        // Without a click, opening BriefBar again is just that.
        #expect(!notifier.handleReopen())
        let click = NotificationClick(id: "a", source: .azureDevOps, userInfo: ["url": "https://dev.azure.com/contoso"])
        notifier.clicked(click)
        #expect(opened.isEmpty)
        #expect(recent.history.unseenCount == 0)

        // macOS brings BriefBar to the front for the click: what it's about opens then, and nothing else does.
        #expect(notifier.handleReopen())
        #expect(opened == [click])
        // Once only.
        #expect(notifier.handleReopen())
        #expect(opened == [click])
        // Well after the click, opening BriefBar again is just that.
        #expect(!notifier.handleReopen(at: Date().addingTimeInterval(10)))
    }

    @Test func aClickOpensAnywayWhenBriefBarDoesntComeToTheFront() async throws {
        let (notifier, _) = makeNotifier(wait: 0)
        var opened: [String] = []
        notifier.onOpen = { opened.append($0.id) }
        notifier.clicked(NotificationClick(id: "a", source: .azureDevOps))
        for _ in 0..<200 where opened.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(opened == ["a"])

        // A click while another waits opens that one first.
        notifier.clickWait = 60
        notifier.clicked(NotificationClick(id: "b", source: .azureDevOps))
        notifier.clicked(NotificationClick(id: "c", source: .azureDevOps, sumsUp: true))
        #expect(opened == ["a", "b"])
        #expect(notifier.handleReopen())
        #expect(opened == ["a", "b", "c"])
    }
}
