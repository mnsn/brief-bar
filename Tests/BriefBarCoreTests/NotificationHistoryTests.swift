import Testing
@testable import BriefBarCore

@Suite struct NotificationHistoryTests {
    private func entry(_ id: String, at seconds: Double, source: SourceID = .azureDevOps) -> NotificationHistory.Entry {
        NotificationHistory.Entry(id: id, source: source, title: "Sam Rivera replied", body: "Done.", date: t(seconds))
    }

    @Test func theNewestComesFirstAndPostingAgainReplaces() {
        var history = NotificationHistory()
        history.add(entry("a", at: 10))
        history.add(entry("c", at: 30))
        history.add(entry("b", at: 20))
        #expect(history.entries.map(\.id) == ["c", "b", "a"])

        // The same news again moves to its new date, unseen.
        history.markSeen("a")
        history.add(entry("a", at: 40))
        #expect(history.entries.map(\.id) == ["a", "c", "b"])
        #expect(history.entries.first?.isSeen == false)
        // Posted together, at the same time, they stay in the order they came, the newest first.
        history.add(entry("d", at: 40))
        history.add(entry("e", at: 40))
        #expect(history.entries.map(\.id) == ["a", "d", "e", "c", "b"])
        #expect(NotificationHistory(entries: [entry("x", at: 1), entry("y", at: 2)]).entries.map(\.id) == ["y", "x"])
    }

    @Test func itKeepsAtMostItsLimitTheOldestGoingFirst() {
        var history = NotificationHistory()
        for index in 0..<(NotificationHistory.limit + 5) {
            history.add(entry("\(index)", at: Double(index)))
        }
        #expect(history.entries.count == NotificationHistory.limit)
        #expect(history.entries.first?.id == "\(NotificationHistory.limit + 4)")
        #expect(history.entries.last?.id == "5")
    }

    @Test func itDropsWhatsOlderThanItKeeps() {
        let hour = 3600.0
        var history = NotificationHistory(entries: [entry("day", at: 0), entry("hours", at: 5 * hour), entry("now", at: 24 * hour)])
        let dropped = history.prune(now: t(24 * hour), keepHours: 24)
        #expect(dropped)
        #expect(history.entries.map(\.id) == ["now", "hours"])
        let droppedAgain = history.prune(now: t(24 * hour), keepHours: 24)
        #expect(!droppedAgain)
        // A shorter choice drops more at once.
        let droppedSooner = history.prune(now: t(24 * hour), keepHours: 4)
        #expect(droppedSooner)
        #expect(history.entries.map(\.id) == ["now"])
    }

    @Test func itsSeenOneAtATimeOrUpToWhenYouLeftThePage() {
        var history = NotificationHistory(entries: [entry("a", at: 10), entry("b", at: 20), entry("c", at: 30)])
        #expect(history.unseenCount == 3)
        history.markSeen("c")
        #expect(history.unseenCount == 2)
        history.markSeen(through: t(15))
        #expect(history.entries.filter { !$0.isSeen }.map(\.id) == ["b"])
        history.markSeen("unknown")
        #expect(history.unseenCount == 1)
    }

    @Test func aSourceTurnedOffTakesItsEntriesWithIt() {
        var history = NotificationHistory(entries: [
            entry("a", at: 10), entry("b", at: 20, source: .github), entry("c", at: 30),
        ])
        history.remove("c")
        #expect(history.entries.map(\.id) == ["b", "a"])
        history.removeAll(from: .azureDevOps)
        #expect(history.entries.map(\.id) == ["b"])
        history.removeAll()
        #expect(history.isEmpty)
    }

    @Test func whatYouCanKeepThemForFallsBackToADay() {
        #expect(NotificationHistory.keepHoursChoices.contains(NotificationHistory.defaultKeepHours))
        for hours in NotificationHistory.keepHoursChoices {
            #expect(NotificationHistory.keepHours(hours) == hours)
        }
        #expect(NotificationHistory.keepHours(0) == 24)
        #expect(NotificationHistory.keepHours(5) == 24)
    }
}
