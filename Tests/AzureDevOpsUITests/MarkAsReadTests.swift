import AzureDevOpsCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Mark as Read takes a comment thread off waiting on you, in the details at once and in Needs You, for the account it was
/// read as, until a newer comment; Mark as Unread puts it back. Active | All, in the details' comments, is kept. With the
/// made-up pull requests, which never use the Azure CLI or Azure DevOps.
@MainActor
@Suite struct MarkAsReadTests {
    /// The demo's pull requests, read once, as of a time of their own, and what the next refresh reads.
    @MainActor
    private struct Demo {
        let store: PRStore
        let settings: AppSettings
        let defaults: MemoryDefaults
        let now: Date
        var snapshot: PulseSnapshot

        func refresh() {
            store.receive(snapshot)
        }

        func item(_ number: Int) -> PRSnapshot? {
            store.items.first { $0.key.number == number }
        }

        func thread(_ id: Int, of number: Int) -> ReviewThread? {
            store.record(for: PRKey(DemoData.organization, number))?.details?.threads.first { $0.id == id }
        }

        /// Adds a comment to one of the pull request's threads, for the next refresh.
        mutating func add(_ comment: ReviewComment, to number: Int, thread: Int) {
            guard let index = snapshot.records.firstIndex(where: { $0.id.number == number }), var details = snapshot.records[index].details,
                  let existing = details.threads.firstIndex(where: { $0.id == thread })
            else { return }
            details.threads[existing].comments.append(comment)
            details.lastActivity = max(details.lastActivity ?? .distantPast, comment.publishedAt)
            snapshot.records[index].details = details
        }
    }

    /// Someone else, as the demo's comments are written.
    private let sam = Person(id: "6f1c1a52-0000-4000-8000-00000000b001", name: "Sam Rivera")

    private func loadDemo() async -> Demo {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .demo)
        // What `loadOnce` makes the demo up as of.
        let now = store.now
        await store.loadOnce()
        return Demo(store: store, settings: settings, defaults: defaults, now: now, snapshot: DemoData.snapshot(now: now))
    }

    /// On your pull request, Sam's reply, which you've seen, is all that waits on you: marked as read, it leaves Needs You,
    /// until he says more. Mark as Unread puts it back as it was.
    @Test func markingTheOnlyThreadThatWaitsTakesItOffNeedsYou() async throws {
        var demo = await loadDemo()
        let store = demo.store
        let key = PRKey(DemoData.organization, 4102)
        #expect(demo.item(4102)?.group == .needsYou)
        let thread = try #require(demo.thread(11, of: 4102))
        let latest = try #require(thread.comments.last?.publishedAt)

        let mark = store.markRead(11, of: key, upTo: latest)
        #expect(mark == PRStore.ReadMark(before: nil, account: demo.settings.account, sentInChat: false))
        demo.refresh()
        let read = try #require(demo.item(4102))
        #expect(read.group != .needsYou)
        #expect(!read.events.contains { $0.threadId == 11 })
        #expect(store.counts.needsYou == 3)
        // Nothing went anywhere but the preferences, where what you've seen is.
        #expect(try savedSeen(demo.defaults).readThreads(of: key) == [11: latest])

        // Sam says more: that waits on you again, as new.
        demo.add(ReviewComment(id: 3, author: sam, text: "Any news?", publishedAt: demo.now.addingTimeInterval(60)), to: 4102, thread: 11)
        demo.refresh()
        let again = try #require(demo.item(4102))
        #expect(again.group == .needsYou)
        #expect(again.hasNews)
        #expect(again.events.filter { $0.threadId == 11 }.map(\.id) == ["c11.3"])

        // Mark as Unread, before he did: his reply waits on you again, as you'd seen it.
        demo.snapshot = DemoData.snapshot(now: demo.now)
        store.markUnread(11, of: key, as: mark)
        demo.refresh()
        let unread = try #require(demo.item(4102))
        #expect(unread.group == .needsYou && !unread.hasNews)
        #expect(unread.headline == "Sam Rivera replied")
        #expect(demo.settings.readThreads(of: key).isEmpty)
    }

    /// On a review, the assistant's closed thread mentions you, as new: marked as read, it doesn't wait on you anymore, but
    /// Alex's mention still does.
    @Test func aResolvedThreadOnAReviewLeavesTheRest() async throws {
        let demo = await loadDemo()
        let review = try #require(demo.item(4097))
        #expect(review.pendingEvents.contains { $0.threadId == 23 && $0.kind == .mention && $0.isNew })
        let thread = try #require(demo.thread(23, of: 4097))
        #expect(thread.isResolved)
        demo.store.markRead(23, of: review.key, upTo: try #require(thread.comments.last?.publishedAt))
        demo.refresh()
        let read = try #require(demo.item(4097))
        #expect(read.group == .needsYou)
        #expect(read.headline == "Alex Kim mentioned you")
        #expect(!read.events.contains { $0.threadId == 23 })
    }

    /// A pull request someone sent you, which you're not on: what you mark as read there is kept in memory only, as what
    /// you've seen of it.
    @Test func oneSentToYouKeepsItInMemoryOnly() async throws {
        var demo = await loadDemo()
        let sent = try #require(demo.item(4113))
        #expect(sent.role == .linked)
        let index = try #require(demo.snapshot.records.firstIndex { $0.id == sent.key })
        let mention = ReviewComment(
            id: 1, author: sam, text: "@Robin Diaz could you check the numbers?", mentions: [DemoData.me.id],
            publishedAt: demo.now.addingTimeInterval(-120)
        )
        demo.snapshot.records[index].details?.threads.append(ReviewThread(id: 70, comments: [mention]))
        demo.refresh()
        #expect(try #require(demo.item(4113)).pendingEvents.contains { $0.threadId == 70 })

        let mark = demo.store.markRead(70, of: sent.key, upTo: mention.publishedAt)
        #expect(mark.sentInChat)
        demo.refresh()
        #expect(demo.item(4113).map { !$0.pendingEvents.contains { $0.threadId == 70 } } ?? true)
        #expect(demo.settings.readSentInChats[SeenState.name(of: sent.key)] == [70: mention.publishedAt])
        #expect(demo.settings.readThreads(of: sent.key) == [70: mention.publishedAt])
        // Nothing in the preferences says which pull request it was.
        let preferences = demo.defaults.dictionaryRepresentation().values.map { value in
            (value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
        }.joined(separator: "\n").replacingOccurrences(of: "\\/", with: "/")
        #expect(!preferences.contains(SeenState.name(of: sent.key)))
    }

    /// Kept for the account it was read as: another account's Needs You keeps it, and that one has it again once it signs
    /// in again. One BriefBar doesn't remember changes nothing.
    @Test func eachAccountKeepsItsOwn() throws {
        let defaults = MemoryDefaults()
        let now = Date(timeIntervalSince1970: 1_792_317_600)
        let settings = AppSettings(defaults: defaults, now: now)
        let key = PRKey(DemoData.organization, 4102)
        let latest = now.addingTimeInterval(-600)
        #expect(!settings.useAccount("tenant/robin", now: now))
        settings.markRead(11, of: key, upTo: latest, for: "tenant/robin")
        #expect(settings.readThreads(of: key) == [11: latest])

        #expect(settings.useAccount("tenant/sam", now: now))
        #expect(settings.readThreads(of: key).isEmpty)
        // Robin's, while Sam is signed in, as a task sent before he did would: kept for Robin.
        settings.markRead(18, of: key, upTo: latest, for: "tenant/robin")
        #expect(settings.readThreads(of: key).isEmpty)
        settings.markRead(19, of: key, upTo: latest, for: "tenant/avery")
        settings.setRead(11, of: key, to: nil, for: "tenant/avery")

        let restarted = AppSettings(defaults: defaults, now: now)
        for kept in [settings, restarted] {
            #expect(kept.useAccount("tenant/robin", now: now))
            #expect(kept.readThreads(of: key) == [11: latest, 18: latest])
        }
        #expect(settings.useAccount("tenant/avery", now: now))
        #expect(settings.readThreads(of: key).isEmpty)
    }

    /// In the details, at once: the thread doesn't wait on you anymore, though they still show what was new as it was when
    /// they showed it, and it stays where it was. Mark as Unread puts it back, new again; another pull request has nothing
    /// to put back.
    @Test func theDetailsShowItAtOnce() async throws {
        let demo = await loadDemo()
        let store = demo.store
        let details = PullRequestDetailsStore()
        details.use(store)
        let review = try #require(demo.item(4097))
        details.show(review)
        // The next refresh, which sees it: the list's row doesn't have the assistant's comment anymore, its details do.
        demo.refresh()
        #expect(demo.item(4097)?.pendingEvents.contains { $0.threadId == 23 } == false)
        func threads() throws -> PullRequestPanel.Threads {
            let item = try #require(details.selected)
            return PullRequestPanel(item, record: details.record, events: details.pendingEvents(of: item, record: details.record)).threads
        }
        let waiting = try #require(try threads().waitingOnYou.first { $0.id == 23 })
        #expect(waiting.isNew)

        details.markRead(waiting)
        #expect(details.markedRead[23]?.mark.before == nil)
        #expect(try !threads().waitingOnYou.contains { $0.id == 23 })
        #expect(try threads().resolved.contains { $0.id == 23 && !$0.isNew })
        // Where it was, with those that wait on you, rather than folded away with the resolved ones.
        let held = details.holding([:])
        #expect(held[23]?.placement == .waitingOnYou)
        let arranged = try threads().arranged(holding: held)
        #expect(arranged.open.flatMap(\.threads).map(\.id).contains(23))
        #expect(!arranged.resolved.flatMap(\.threads).map(\.id).contains(23))
        // A hold of its own in the details wins.
        let replied = PullRequestPanel.Thread.Held(placement: .open, date: nil)
        #expect(details.holding([23: replied])[23] == replied)

        details.markUnread(23)
        #expect(details.markedRead.isEmpty && details.holding([:]).isEmpty)
        #expect(try threads().waitingOnYou.first { $0.id == 23 }?.isNew == true)
        #expect(demo.settings.readThreads(of: review.key).isEmpty)

        details.markRead(waiting)
        let other = try #require(demo.item(4102))
        details.show(other)
        #expect(details.markedRead.isEmpty)
        details.markUnread(23)
        // It stays read: Mark as Unread was for while they showed it.
        #expect(demo.settings.readThreads(of: review.key).keys.sorted() == [23])
    }

    /// Active or All, as you chose last, for every pull request and after a restart; All until you choose, and for what's
    /// neither.
    @Test func keepsWhichCommentsShow() {
        let defaults = MemoryDefaults()
        #expect(AppSettings(defaults: defaults).commentFilter == .all)
        #expect(defaults.object(forKey: SettingsKey.commentFilter) == nil)
        AppSettings(defaults: defaults).commentFilter = .active
        #expect(AppSettings(defaults: defaults).commentFilter == .active)
        defaults.set("closed", forKey: SettingsKey.commentFilter)
        #expect(AppSettings(defaults: defaults).commentFilter == .all)
    }

    private func savedSeen(_ defaults: MemoryDefaults) throws -> SeenState {
        try JSONDecoder().decode(SeenState.self, from: try #require(defaults.data(forKey: SettingsKey.seen)))
    }
}
