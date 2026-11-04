import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// Your replies in pull requests' threads and their statuses, with Make Changes in Azure DevOps on: what goes to Azure
/// DevOps, and only when it's on and you click; what shows at once; what you wrote, kept until it goes; and what a thread
/// says when it can't. With the demo's made-up pull requests, read as a list that reads Azure DevOps would, and a stand-in
/// for Azure DevOps that answers as it does.
@MainActor
@Suite struct ThreadChangesTests {
    /// What the stand-in for Azure DevOps was sent, and answers.
    final class AzureDevOps {
        var sent: [ADOWrite] = []
        var fails: ADOError?

        func send(_ write: ADOWrite) throws -> ADOWrite.Answer {
            sent.append(write)
            if let fails { throw fails }
            switch write {
            case .reply(_, let markdown, _):
                return .comment(try decode(ADOComment.self, [
                    "id": 3, "parentCommentId": 1, "content": markdown, "commentType": "text", "publishedDate": "2030-01-01T10:00:00Z",
                    "author": ["id": DemoData.me.id, "displayName": DemoData.me.name, "uniqueName": "robin@contoso.example"],
                ]))
            case .setStatus(let address, let status):
                return .thread(try decode(ADOThread.self, ["id": address.id, "status": status.rawValue]))
            case .addTag, .removeTag:
                // Threads' changes never send one (TagChangesTests).
                throw ADOError.http(400)
            }
        }

        private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
            try ADOJSON.decoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    /// The demo's pull request that Sam replied on, on its thread 11, which waits on you.
    private let key = PRKey(DemoData.organization, 4102)

    /// A list that reads Azure DevOps, with the demo's pull requests read, and what changes their threads.
    private func live(makesChanges: Bool = true) -> (store: PRStore, changes: ThreadChanges, azure: AzureDevOps) {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.makesChanges = makesChanges
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .live)
        settings.useSeenState(DemoData.seenState(now: store.now))
        store.receive(DemoData.snapshot(now: store.now))
        let changes = ThreadChanges(store: store, settings: settings)
        let azure = AzureDevOps()
        changes.send = { write, _ in try azure.send(write) }
        return (store, changes, azure)
    }

    private func thread(_ store: PRStore, _ id: Int = 11) throws -> ReviewThread {
        try #require(store.record(for: key)?.details?.threads.first { $0.id == id })
    }

    @Test func nothingShowsOrGoesWhileItsOff() async throws {
        let (store, changes, azure) = live(makesChanges: false)
        let record = try #require(store.record(for: key))
        #expect(!changes.canChange(record.pullRequest))
        #expect(await changes.reply("Done", to: try thread(store), of: key) == false)
        await changes.setStatus(.fixed, of: try thread(store), in: key)
        #expect(azure.sent.isEmpty)
        #expect(try thread(store).comments.count == 2)
    }

    /// A pull request sent to you in a chat, which you're not on, leaves your lists as its details show it, which sees it;
    /// but the list still reads it open, and so do its details: your reply, and a status you set, go once, and show there.
    @Test func aChangeToALinkedPullRequestYouveSeenShowsInItsDetails() async throws {
        let (store, changes, azure) = live()
        let linked = PRKey(DemoData.organization, 4113)
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == linked })
        #expect(snapshot.records[index].role == .linked)
        let sam = try #require(thread(store).comments.first { $0.author != DemoData.me }?.author)
        snapshot.records[index].details?.threads = [ReviewThread(id: 70, comments: [
            ReviewComment(id: 1, author: sam, text: "Is the cache cleared on deploy?", publishedAt: store.now.addingTimeInterval(-600)),
        ])]
        store.receive(snapshot)
        let details = PullRequestDetailsStore()
        details.use(store)
        details.show(try #require(store.items.first { $0.key == linked }))
        // The next refresh, once it's seen.
        store.receive(snapshot)
        #expect(!store.items.contains { $0.key == linked })
        #expect(!details.isListed && details.isStillRead)
        #expect(changes.canChange(details.record?.pullRequest))

        let shown = try #require(details.record?.details?.threads.first { $0.id == 70 })
        #expect(await changes.reply("Yes, by the deploy script.", to: shown, of: linked))
        #expect(details.record?.details?.threads.first { $0.id == 70 }?.comments.last?.markdown == "Yes, by the deploy script.")
        await changes.setStatus(.fixed, of: shown, in: linked)
        #expect(details.record?.details?.threads.first { $0.id == 70 }?.status == "fixed")
        #expect(details.record?.details?.threads.first { $0.id == 70 }?.comments.count == 2)
        #expect(azure.sent.map(\.kind) == [.reply, .setStatus])
        #expect(details.isStillRead)
    }

    /// Nothing goes for a pull request your lists don't have anymore, though its details still show it as it was when it
    /// left them, open: its threads are read-only, which says why, and a change that finds it so says so on the thread.
    @Test func nothingGoesForAPullRequestThatLeftYourLists() async throws {
        let (store, changes, azure) = live()
        let shown = try #require(store.record(for: key))
        let original = try thread(store)
        var snapshot = DemoData.snapshot(now: store.now)
        snapshot.records.removeAll { $0.id == key }
        store.receive(snapshot)
        #expect(store.record(for: key) == nil)
        #expect(shown.pullRequest.status == .active)
        #expect(!changes.canChange(shown.pullRequest))
        #expect(changes.readOnlyReason(shown.pullRequest) == ThreadChanges.notListed)

        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        changes.keep("Capped it.", for: threadKey)
        #expect(await changes.reply("Capped it.", then: .fixed, to: original, of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.notListed, .reply(then: .fixed)))
        #expect(changes.draft(threadKey) == "Capped it.")
        await changes.setStatus(.wontFix, of: original, in: key)
        #expect(changes.state(of: threadKey) == .failed(.notListed, .status(.wontFix)))
        #expect(azure.sent.isEmpty)

        // Back in your lists, it can be changed again.
        store.receive(DemoData.snapshot(now: store.now))
        #expect(changes.canChange(store.record(for: key)?.pullRequest))
        #expect(changes.readOnlyReason(store.record(for: key)?.pullRequest) == nil)
    }

    /// Nor for one that's completed or abandoned, which Azure DevOps takes no change to; and while the setting is off, none
    /// of it shows, nor says why.
    @Test func nothingGoesForACompletedPullRequest() async throws {
        let (store, changes, azure) = live()
        let done = try #require(store.records.first { $0.pullRequest.status != .active })
        // A thread as its details would have it: what's refused is the pull request.
        let doneThread = try thread(store)
        #expect(!changes.canChange(done.pullRequest))
        #expect(changes.readOnlyReason(done.pullRequest) == ThreadChanges.closed)
        #expect(await changes.reply("Late.", to: doneThread, of: done.id) == false)
        #expect(changes.state(of: ThreadChanges.Key(pullRequest: done.id, thread: doneThread.id)) == .failed(.closed, .reply(then: nil)))
        #expect(azure.sent.isEmpty)
        changes.settings.makesChanges = false
        #expect(changes.readOnlyReason(done.pullRequest) == nil)
    }

    /// A reply goes once, as you wrote it, in reply to the thread's first comment; it shows at once, as Azure DevOps answered,
    /// what you wrote goes, and the thread doesn't wait on you anymore.
    @Test func aReplyGoesOnceAndShowsAtOnce() async throws {
        let (store, changes, azure) = live()
        #expect(store.items.first { $0.key == key }?.group == .needsYou)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        changes.keep("Capped it at 30 seconds.", for: threadKey)
        let record = try #require(store.record(for: key))

        #expect(await changes.reply("\n \nCapped it at 30 seconds.\n\n", to: try thread(store), of: key))
        #expect(azure.sent == [.reply(ThreadAddress(record.pullRequest, thread: 11), markdown: "Capped it at 30 seconds.", parentCommentId: 1)])
        let replied = try thread(store)
        #expect(replied.comments.map(\.id) == [1, 2, 3])
        #expect(replied.comments.last?.markdown == "Capped it at 30 seconds.")
        #expect(changes.draft(threadKey).isEmpty)
        #expect(changes.state(of: threadKey) == nil)
        // Answered: it doesn't wait on you.
        #expect(store.items.first { $0.key == key }?.group != .needsYou)
    }

    /// A reply goes as you wrote it, but for the lines that say nothing before it and the spaces after it: its first line's
    /// indent stays, which makes it code.
    @Test func aReplyKeepsItsFirstLinesIndent() async throws {
        let (store, changes, azure) = live()
        #expect(await changes.reply("\n    let retrys = 1\n\nThat caps it.  \n", to: try thread(store), of: key))
        #expect(azure.sent == [.reply(ThreadAddress(try #require(store.record(for: key)).pullRequest, thread: 11),
                                      markdown: "    let retrys = 1\n\nThat caps it.", parentCommentId: 1)])
        #expect(ThreadChanges.posted(" \r\n  \n- one\r\n- two\r\n") == "- one\n- two")
        #expect(ThreadChanges.posted(" \n\t\n").isEmpty)
    }

    /// A change goes as whom the list was read as when you clicked: someone else signed in since, the client sends nothing.
    @Test func aChangeGoesAsWhomTheListWasReadAs() async throws {
        let (store, changes, azure) = live()
        var accounts: [String?] = []
        changes.send = { write, account in
            accounts.append(account)
            return try azure.send(write)
        }
        changes.accountChanged("home/robin")
        #expect(await changes.reply("Capped it.", then: .fixed, to: try thread(store), of: key))
        #expect(accounts == ["home/robin", "home/robin"])

        // Someone else signed in, as the list tells: the client said so first.
        azure.fails = .otherAccount
        await changes.setStatus(.active, of: try thread(store), in: key)
        #expect(changes.state(of: ThreadChanges.Key(pullRequest: key, thread: 11)) == .failed(.otherAccount, .status(.active)))
    }

    /// Called off while a reply that may have gone is checked, as the setting is turned off and on again, it does nothing
    /// more as the thread comes back read: not to another reply under way on its thread, nor by sending what it said.
    @Test(.timeLimit(.minutes(1)))
    func aReplyCalledOffWhileItsThreadIsReadDoesNothingMore() async throws {
        let (store, changes, azure) = live()
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key) == false)
        azure.fails = nil

        var reading: CheckedContinuation<Void, Never>?
        let threads = [try thread(store)]
        changes.readThreads = { _ in
            await withCheckedContinuation { reading = $0 }
            return threads
        }
        let original = try thread(store)
        let checking = Task { await changes.reply("Capped it.", to: original, of: key) }
        for _ in 0..<1_000 where reading == nil { await Task.yield() }
        changes.settings.makesChanges = false
        changes.settings.makesChanges = true

        // Another reply on the thread, which resolves it too, on its way.
        var sending: CheckedContinuation<Void, Never>?
        var holds = true
        changes.send = { write, _ in
            if holds {
                holds = false
                await withCheckedContinuation { sending = $0 }
            }
            return try azure.send(write)
        }
        let replying = Task { await changes.reply("Tested it too.", then: .fixed, to: original, of: key) }
        for _ in 0..<1_000 where sending == nil { await Task.yield() }
        #expect(changes.state(of: threadKey) == .sending(.reply(then: .fixed)))

        try #require(reading).resume()
        #expect(await checking.value == false)
        #expect(changes.state(of: threadKey) == .sending(.reply(then: .fixed)))
        try #require(sending).resume()
        #expect(await replying.value)
        let replies = azure.sent.compactMap { write -> String? in
            if case .reply(_, let markdown, _) = write { return markdown }
            return nil
        }
        #expect(replies == ["Capped it.", "Tested it too."])
        #expect(azure.sent.map(\.kind) == [.reply, .reply, .setStatus])
    }

    /// Reply & Resolve replies, then resolves the thread.
    @Test func replyAndResolveResolvesAfterTheReply() async throws {
        let (store, changes, azure) = live()
        #expect(await changes.reply("Done.", then: .fixed, to: try thread(store), of: key))
        #expect(azure.sent.map(\.kind) == [.reply, .setStatus])
        #expect(azure.sent.last == .setStatus(ThreadAddress(try #require(store.record(for: key)).pullRequest, thread: 11), .fixed))
        #expect(try thread(store).status == "fixed")
        #expect(try thread(store).comments.count == 3)
    }

    /// A reply that fails keeps what you wrote, and the thread says why; one that surely didn't go goes as you try again.
    @Test func aReplyThatFailsKeepsWhatYouWrote() async throws {
        let (store, changes, azure) = live()
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        changes.keep("Capped it.", for: threadKey)
        azure.fails = .forbidden
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.notAllowed, .reply(then: nil)))
        #expect(changes.draft(threadKey) == "Capped it.")
        #expect(try thread(store).comments.count == 2)
        changes.dismiss(threadKey)
        #expect(changes.state(of: threadKey) == nil)

        // Refused, it didn't go: it goes, with nothing read first.
        azure.fails = nil
        var reads = 0
        changes.readThreads = { _ in
            reads += 1
            return nil
        }
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key))
        #expect(reads == 0)
        #expect(azure.sent.map(\.kind) == [.reply, .reply])
        #expect(changes.draft(threadKey).isEmpty)
        #expect(try thread(store).comments.last?.markdown == "Capped it.")
    }

    /// A reply Azure DevOps didn't answer in time may have gone: it isn't sent again until its thread, read again for it,
    /// tells. Not while the thread can't be read, which keeps what you wrote; and not when the thread has it.
    @Test func aReplyThatMayHaveGoneIsntSentAgainUnchecked() async throws {
        let (store, changes, azure) = live()
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        changes.keep("Capped it.", for: threadKey)
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.unanswered, .reply(then: nil)))
        azure.fails = nil
        let sent = azure.sent.count

        var reads = 0
        changes.readThreads = { _ in
            reads += 1
            return nil
        }
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key) == false)
        #expect(reads == 1)
        #expect(azure.sent.count == sent)
        #expect(changes.state(of: threadKey) == .failed(.unconfirmed, .reply(then: nil)))
        #expect(changes.draft(threadKey) == "Capped it.")

        // Read, it has the reply: it went, and goes no more.
        var read = try thread(store)
        read.comments.append(ReviewComment(id: 3, author: DemoData.me, text: "Capped it.", publishedAt: store.now))
        let threads = [read]
        changes.readThreads = { _ in
            reads += 1
            return threads
        }
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key))
        #expect(reads == 2)
        #expect(azure.sent.count == sent)
        #expect(changes.draft(threadKey).isEmpty)
        #expect(changes.state(of: threadKey) == nil)
    }

    /// A reply that may have gone is found in its thread, read again, though someone else spoke after it: it isn't sent
    /// twice.
    @Test func aReplyThatWentIsFoundWhateverCameAfterIt() async throws {
        let (store, changes, azure) = live()
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        changes.keep("Capped it.\r\nTested too.", for: threadKey)
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.reply("Capped it.\r\nTested too.", to: try thread(store), of: key) == false)
        azure.fails = nil

        var read = try thread(store)
        let sam = try #require(read.comments.first { $0.author != DemoData.me }?.author)
        read.comments.append(ReviewComment(id: 3, author: DemoData.me, text: "Capped it.\nTested too.", publishedAt: store.now))
        read.comments.append(ReviewComment(id: 4, author: sam, text: "Thanks!", publishedAt: store.now))
        let threads = [read]
        changes.readThreads = { _ in threads }
        #expect(await changes.reply("Capped it.\r\nTested too.", to: try thread(store), of: key))
        #expect(azure.sent.count == 1)
        #expect(changes.draft(threadKey).isEmpty)
        #expect(changes.state(of: threadKey) == nil)
    }

    /// A reply with a mention that may have gone is found as Azure DevOps keeps it, though the details show the mention as a
    /// name: it isn't sent twice.
    @Test func aReplyWithAMentionThatWentIsFound() async throws {
        let (store, changes, azure) = live()
        let reply = "Thanks @<8d3f0e7a-1b2c-4d5e-8f90-a1b2c3d4e5f6>, capped it."
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.reply(reply, to: try thread(store), of: key) == false)
        azure.fails = nil

        var read = try thread(store)
        read.comments.append(ReviewComment(
            id: 3, author: DemoData.me, text: "Thanks @Sam Rivera, capped it.", markdown: "Thanks @Sam Rivera, capped it.",
            mentions: ["8d3f0e7a-1b2c-4d5e-8f90-a1b2c3d4e5f6"], publishedAt: store.now, content: reply
        ))
        let threads = [read]
        changes.readThreads = { _ in threads }
        #expect(await changes.reply(reply, to: try thread(store), of: key))
        #expect(azure.sent.count == 1)
    }

    /// A reply that may have gone, made code since, isn't the one that went: its first line's indent is part of what it
    /// says, and it goes.
    @Test func aReplyMadeCodeSinceItMayHaveGoneGoes() async throws {
        let (store, changes, azure) = live()
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.reply("let retrys = 1", to: try thread(store), of: key) == false)
        azure.fails = nil

        var read = try thread(store)
        read.comments.append(ReviewComment(id: 3, author: DemoData.me, text: "let retrys = 1", publishedAt: store.now, content: "let retrys = 1"))
        let threads = [read]
        changes.readThreads = { _ in threads }
        #expect(await changes.reply("    let retrys = 1", to: try thread(store), of: key))
        let replies = azure.sent.compactMap { write -> String? in
            if case .reply(_, let markdown, _) = write { return markdown }
            return nil
        }
        #expect(replies == ["let retrys = 1", "    let retrys = 1"])
    }

    /// The same reply of yours from before the one that may have gone isn't it: read, the thread hasn't it, and it goes.
    @Test func aReplyLikeOneYouSentBeforeIsntTakenForIt() async throws {
        let (store, changes, azure) = live()
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        snapshot.records[index].details?.threads[0].comments.append(
            ReviewComment(id: 3, author: DemoData.me, text: "Done.", publishedAt: store.now)
        )
        store.receive(snapshot)
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.reply("Done.", to: try thread(store), of: key) == false)
        azure.fails = nil

        let threads = [try thread(store)]
        changes.readThreads = { _ in threads }
        #expect(await changes.reply("Done.", to: try thread(store), of: key))
        #expect(azure.sent.map(\.kind) == [.reply, .reply])
    }

    /// Turned off while a reply waits to go, as for a token, it never goes, and nor does the status after it; nothing says
    /// it failed, and nothing is read, since nothing went.
    @Test func turnedOffWhileAReplyWaitsNothingGoes() async throws {
        let (store, changes, azure) = live()
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        var readAgain: [PRKey] = []
        changes.readAgain = { readAgain.append($0) }
        var waiting: CheckedContinuation<Void, Never>?
        changes.send = { write, _ in
            await withCheckedContinuation { waiting = $0 }
            try Task.checkCancellation()
            return try azure.send(write)
        }
        let original = try thread(store)
        let replying = Task { await changes.reply("Capped it.", then: .fixed, to: original, of: key) }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
        #expect(changes.isSending(threadKey))

        changes.settings.makesChanges = false
        try #require(waiting).resume()
        #expect(await replying.value == false)
        #expect(azure.sent.isEmpty)
        #expect(changes.state(of: threadKey) == nil)
        #expect(try thread(store).comments.count == 2)
        #expect(try thread(store).status == original.status)
        #expect(readAgain.isEmpty)
    }

    /// A reply answered 503, which the client says as no answer in time (`WriteTests.aChangeAnswered503MayHaveBeenMade`),
    /// isn't sent again while its thread can't be read, nor once the read shows it went; and is checked before it goes again.
    @Test func aReplyAnswered503IsCheckedBeforeItGoesAgain() async throws {
        let (store, changes, azure) = live()
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.unanswered, .reply(then: nil)))
        #expect(ADOWriteProblem.unanswered.sentence(.reply).contains("may have gone"))
        azure.fails = nil

        var reads = 0
        changes.readThreads = { _ in
            reads += 1
            return nil
        }
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key) == false)
        #expect(reads == 1)
        #expect(azure.sent.count == 1)

        var read = try thread(store)
        read.comments.append(ReviewComment(id: 3, author: DemoData.me, text: "Capped it.", publishedAt: store.now, content: "Capped it."))
        let threads = [read]
        changes.readThreads = { _ in
            reads += 1
            return threads
        }
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key))
        #expect(reads == 2)
        #expect(azure.sent.count == 1)
    }

    /// Asked to slow down, as when Azure DevOps asked a build's reads to wait five minutes, which holds every request, a
    /// change says until when, rather than in a minute; and nothing is read again, since nothing went.
    @Test func aChangeAskedToSlowDownSaysUntilWhen() async throws {
        let (store, changes, azure) = live()
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        changes.now = { at }
        var readAgain: [PRKey] = []
        changes.readAgain = { readAgain.append($0) }
        azure.fails = .throttled(retryAfter: 300)
        await changes.setStatus(.fixed, of: try thread(store), in: key)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        #expect(changes.state(of: threadKey) == .failed(.slowedDown(until: at.addingTimeInterval(300)), .status(.fixed)))
        #expect(readAgain.isEmpty)
    }

    /// A reply under way as the setting goes off, gone already, which the client doesn't call off then, settles all the
    /// same: what Azure DevOps answered shows, nothing more happens, and nothing says it failed.
    @Test func turnedOffAsAReplyGoesItShowsWhatAzureDevOpsAnswered() async throws {
        let (store, changes, azure) = live()
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        var readAgain: [PRKey] = []
        changes.readAgain = { readAgain.append($0) }
        var waiting: CheckedContinuation<Void, Never>?
        // Gone: it answers, called off or not.
        changes.send = { write, _ in
            await withCheckedContinuation { waiting = $0 }
            return try azure.send(write)
        }
        let original = try thread(store)
        let replying = Task { await changes.reply("Capped it.", then: .fixed, to: original, of: key) }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
        changes.settings.makesChanges = false
        try #require(waiting).resume()
        #expect(await replying.value == false)
        #expect(try thread(store).comments.last?.markdown == "Capped it.")
        // The status after it doesn't go: the setting's off.
        #expect(azure.sent.map(\.kind) == [.reply])
        #expect(changes.state(of: threadKey) == nil)
        #expect(readAgain.isEmpty)
    }

    /// One that may have gone though it didn't say so, as one Azure DevOps didn't answer in time, is read again once it has
    /// settled, not as the setting goes off, which may be before Azure DevOps made it; and on again, the same reply is checked
    /// before it goes, though what you wrote went with the setting: it isn't sent twice.
    @Test func turnedOffAsAReplyGoesThatMayHaveGoneItsCheckedOnceItSettles() async throws {
        let (store, changes, azure) = live()
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        var readAgain: [PRKey] = []
        changes.readAgain = { readAgain.append($0) }
        var waiting: CheckedContinuation<Void, Never>?
        changes.send = { write, _ in
            await withCheckedContinuation { waiting = $0 }
            return try azure.send(write)
        }
        changes.keep("Capped it.", for: threadKey)
        let original = try thread(store)
        let replying = Task { await changes.reply("Capped it.", to: original, of: key) }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
        changes.settings.makesChanges = false
        #expect(readAgain.isEmpty)
        azure.fails = .network(ADOClient.unansweredMessage)
        try #require(waiting).resume()
        #expect(await replying.value == false)
        #expect(readAgain == [key])
        #expect(changes.state(of: threadKey) == nil)
        #expect(changes.draft(threadKey).isEmpty)

        // On again: Azure DevOps made it after all, as its thread, read again first, says.
        azure.fails = nil
        changes.send = { write, _ in try azure.send(write) }
        changes.settings.makesChanges = true
        var read = try thread(store)
        read.comments.append(ReviewComment(id: 3, author: DemoData.me, text: "Capped it.", publishedAt: store.now, content: "Capped it."))
        let threads = [read]
        var reads = 0
        changes.readThreads = { _ in
            reads += 1
            return threads
        }
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key))
        #expect(reads == 1)
        #expect(azure.sent.count == 1)
        // Another reply goes without reading it first: it can't be the one that may have gone.
        #expect(await changes.reply("And tested it.", to: try thread(store), of: key))
        #expect(reads == 1)
        #expect(azure.sent.count == 2)
    }

    /// On again before a change under way as it went off has settled, its thread shows it on its way, without the status
    /// after a reply, which doesn't go, and takes no other change, the same reply included, until it has: then one that may
    /// have gone is checked before the same goes again, rather than read while Azure DevOps may still be making it.
    @Test(.timeLimit(.minutes(1)))
    func onAgainBeforeAReplySettlesItsThreadWaitsForIt() async throws {
        let (store, changes, azure) = live()
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        var readAgain: [PRKey] = []
        changes.readAgain = { readAgain.append($0) }
        var waiting: CheckedContinuation<Void, Never>?
        // Only the first is held: another would go at once.
        var held = false
        changes.send = { write, _ in
            if !held {
                held = true
                await withCheckedContinuation { waiting = $0 }
            }
            return try azure.send(write)
        }
        let original = try thread(store)
        let replying = Task { await changes.reply("Capped it.", then: .fixed, to: original, of: key) }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
        changes.settings.makesChanges = false
        changes.settings.makesChanges = true
        #expect(changes.state(of: threadKey) == .sending(.reply(then: nil)))
        var reads = 0
        changes.readThreads = { _ in
            reads += 1
            return nil
        }
        #expect(await changes.reply("Capped it.", to: original, of: key) == false)
        await changes.setStatus(.fixed, of: original, in: key)
        #expect(azure.sent.isEmpty)
        #expect(reads == 0)

        azure.fails = .network(ADOClient.unansweredMessage)
        try #require(waiting).resume()
        #expect(await replying.value == false)
        #expect(changes.state(of: threadKey) == nil)
        #expect(readAgain == [key])
        #expect(azure.sent.map(\.kind) == [.reply])

        // Azure DevOps made it after all, as its thread, read again first, says.
        azure.fails = nil
        changes.send = { write, _ in try azure.send(write) }
        var read = try thread(store)
        read.comments.append(ReviewComment(id: 3, author: DemoData.me, text: "Capped it.", publishedAt: store.now, content: "Capped it."))
        let threads = [read]
        changes.readThreads = { _ in
            reads += 1
            return threads
        }
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key))
        #expect(reads == 1)
        #expect(azure.sent.count == 1)
    }

    /// Someone else signing in while a change under way as the setting went off settles doesn't wait for it: it was the last
    /// one's.
    @Test(.timeLimit(.minutes(1)))
    func someoneElseSigningInDoesntWaitForTheLastOnesChange() async throws {
        let (store, changes, azure) = live()
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        changes.accountChanged("home/robin")
        var waiting: CheckedContinuation<Void, Never>?
        changes.send = { write, _ in
            await withCheckedContinuation { waiting = $0 }
            return try azure.send(write)
        }
        let original = try thread(store)
        let replying = Task { await changes.reply("Capped it.", to: original, of: key) }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
        changes.settings.makesChanges = false
        changes.settings.makesChanges = true
        #expect(changes.isSending(threadKey))
        changes.accountChanged("home/sam")
        #expect(changes.state(of: threadKey) == nil)
        try #require(waiting).resume()
        #expect(await replying.value == false)
        #expect(changes.state(of: threadKey) == nil)
        #expect(azure.sent.map(\.kind) == [.reply])
    }

    /// Someone else signing in forgets a reply that may have gone: what they write is theirs, and isn't checked against it.
    @Test func someoneElseSigningInForgetsWhatMayHaveGone() async throws {
        let (store, changes, azure) = live()
        changes.accountChanged("home/robin")
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key) == false)
        azure.fails = nil
        changes.accountChanged("home/sam")
        var reads = 0
        changes.readThreads = { _ in
            reads += 1
            return nil
        }
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key))
        #expect(reads == 0)
        #expect(azure.sent.count == 2)
    }

    /// The reads of a pull request after a change to its threads stop as Azure DevOps does: as it's turned off, or BriefBar
    /// quits.
    @Test(.timeLimit(.minutes(1)))
    func stoppingCallsOffTheReadsAfterAChange() async throws {
        let (store, _, _) = live()
        let (started, startedOne) = AsyncStream<Void>.makeStream()
        let calledOff = Mutex(0)
        store.readAfterChange = { _, _ in
            startedOne.yield()
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            calledOff.withLock { $0 += 1 }
            return nil
        }
        store.changed(key, by: ThreadChange(thread: 11, status: "fixed"))
        store.mayHaveChanged(key)
        let read = Task { await store.threadsReadAgain(key) }
        var count = 0
        for await _ in started {
            count += 1
            if count == 3 { break }
        }
        #expect(store.changeReadsUnderWay == 3)
        store.stop()
        #expect(store.changeReadsUnderWay == 0)
        #expect(await read.value == nil)
        for _ in 0..<1_000 where calledOff.withLock({ $0 }) < 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(calledOff.withLock { $0 } == 3)
        // Stopped, nothing more is read.
        store.mayHaveChanged(key)
        #expect(store.changeReadsUnderWay == 0)
    }

    /// Read, a thread that hasn't the reply that may have gone gets it, once; and the next reply goes without reading it.
    @Test func aReplyThatDidntGoIsSentOnceItsThreadSaysSo() async throws {
        let (store, changes, azure) = live()
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key) == false)
        azure.fails = nil
        var reads = 0
        let threads = [try thread(store)]
        changes.readThreads = { _ in
            reads += 1
            return threads
        }
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key))
        #expect(reads == 1)
        #expect(azure.sent.map(\.kind) == [.reply, .reply])
        #expect(await changes.reply("And tested it.", to: try thread(store), of: key))
        #expect(reads == 1)
        #expect(azure.sent.count == 3)
    }

    /// A status goes as you chose it, and shows at once; it can be set back the same way.
    @Test func aStatusGoesAndShowsAtOnce() async throws {
        let (store, changes, azure) = live()
        await changes.setStatus(.wontFix, of: try thread(store), in: key)
        #expect(azure.sent.map(\.kind) == [.setStatus])
        #expect(try thread(store).status == "wontFix")
        await changes.setStatus(.active, of: try thread(store), in: key)
        #expect(try thread(store).status == "active")
        #expect(azure.sent.count == 2)

        azure.fails = .refused(.notEditable, message: "TF401181: The pull request cannot be edited due to its state.")
        await changes.setStatus(.closed, of: try thread(store), in: key)
        #expect(changes.state(of: ThreadChanges.Key(pullRequest: key, thread: 11)) == .failed(.closed, .status(.closed)))
        #expect(try thread(store).status == "active")
    }

    /// What waited on you in a thread you resolved here doesn't, in its details, which show what was new as it was when they
    /// showed it: but what comes after does.
    @Test func whatWaitedOnYouInAThreadYouResolvedDoesntAnymore() async throws {
        let (store, changes, _) = live()
        let events = try #require(store.items.first { $0.key == key }).pendingEvents
        #expect(events.contains { $0.threadId == 11 })
        await changes.setStatus(.fixed, of: try thread(store), in: key)
        #expect(!changes.waiting(events, of: key).contains { $0.threadId == 11 })
        let later = PREvent(id: "c11.9", kind: .reply, at: store.now.addingTimeInterval(3_600), actor: "Sam Rivera", threadId: 11)
        #expect(changes.waiting(events + [later], of: key).contains(later))
        // Another pull request's are as they were.
        #expect(changes.waiting(events, of: PRKey(DemoData.organization, 4097)) == events)
    }

    /// The demo sends nothing: its changes are made up, in its made-up data.
    @Test func theDemoChangesOnlyItsMadeUpData() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .demo)
        await store.loadOnce()
        let changes = ThreadChanges(store: store, settings: settings)
        var sent = 0
        changes.send = { _, _ in
            sent += 1
            throw ADOError.offline
        }
        // The demo shows them.
        #expect(settings.makesChanges)
        #expect(await changes.reply("Capped it.", then: .fixed, to: try thread(store), of: key))
        #expect(sent == 0)
        let replied = try thread(store)
        #expect(replied.comments.last?.author == DemoData.me)
        #expect(replied.comments.last?.markdown == "Capped it.")
        #expect(replied.status == "fixed")
        // And keeps them, as the demo's list comes again.
        store.receive(DemoData.snapshot(now: store.now))
        #expect(try thread(store).status == "fixed")
    }

    /// Turned off, what you wrote goes, and nothing shows.
    @Test func turnedOffItForgetsWhatYouWrote() {
        let (store, changes, _) = live()
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        changes.keep("Half a reply", for: threadKey)
        changes.settings.makesChanges = false
        #expect(changes.draft(threadKey).isEmpty)
        #expect(!changes.canChange(store.record(for: key)?.pullRequest))
    }

    /// The changes kept over the list's refreshes until they have them: one they have is done with.
    @Test func keepsAChangeUntilTheListHasIt() throws {
        let records = DemoData.records(now: Date())
        let change = ThreadChange(thread: 11, comments: [ReviewComment(id: 3, author: DemoData.me, text: "Done", publishedAt: Date())])
        let changed = PRStore.applying([key: [change]], to: records)
        #expect(changed.first { $0.id == key }?.details?.threads.first?.comments.count == 3)
        #expect(PRStore.pending([key: [change]], in: records) == [key: [change]])
        #expect(PRStore.pending([key: [change]], in: changed).isEmpty)
        // Gone from the list: done with too.
        #expect(PRStore.pending([key: [change]], in: records.filter { $0.id != key }).isEmpty)
    }

    /// A status set back, as Reactivate after Reply & Resolve, replaces the one before it, whose reply stays: a list that
    /// has the thread active is done with both statuses, and keeps the reply until it has it too.
    @Test func aStatusSetBackReplacesTheOneBefore() throws {
        let reply = ReviewComment(id: 3, author: DemoData.me, text: "Done", publishedAt: Date())
        let resolved = ThreadChange(thread: 11, comments: [reply], status: "fixed")
        let reactivated = ThreadChange(thread: 11, status: "active")
        let elsewhere = ThreadChange(thread: 12, status: "fixed")
        let made = PRStore.adding(reactivated, to: PRStore.adding(resolved, to: [elsewhere]))
        #expect(made == [elsewhere, ThreadChange(thread: 11, comments: [reply]), reactivated])
        // A status alone, set back, is gone.
        #expect(PRStore.adding(reactivated, to: [ThreadChange(thread: 11, status: "fixed")]) == [reactivated])

        // Read with the thread active, as it was: only the reply is left. (The pull request has no thread 12, whose change is
        // done with as one that changes nothing.)
        let records = DemoData.records(now: Date())
        #expect(PRStore.pending([key: made], in: records) == [key: [ThreadChange(thread: 11, comments: [reply])]])
        let shown = PRStore.applying([key: made], to: records)
        #expect(shown.first { $0.id == key }?.details?.threads.first { $0.id == 11 }?.status == "active")
    }

    // MARK: Fix Grammar

    @Test func fixGrammarCorrectsWithTheModelYouChose() async {
        let fixer = GrammarFixer(isDemo: false)
        // Apple Intelligence as on a Mac that runs it, whether this one does or not.
        fixer.onDeviceUnavailable = { nil }
        var asked: [(String, String)] = []
        fixer.askCopilot = { prompt, model in
            asked.append((prompt, model))
            return .success("```\nI use {{1}}, as @sam asked.\n```")
        }
        var toldOnDevice: [(String, String)] = []
        fixer.askOnDevice = { text, instructions, _ in
            toldOnDevice.append((text, instructions))
            return .success("I use {{1}}.")
        }
        let text = "i use `retryCount` as @sam asked"
        let fixed = await fixer.fix(text, with: "claude-haiku-5.5")
        #expect(fixed == .failure(GrammarFixer.turnedDown(.changedHeld, by: "claude-haiku-5.5")))
        fixer.askCopilot = { _, _ in .success("```\nI use {{1}}, as {{2}} asked.\n```") }
        #expect(await fixer.fix(text, with: "claude-haiku-5.5") == .success("I use `retryCount`, as @sam asked."))
        #expect(asked.first?.1 == "claude-haiku-5.5")
        // The Copilot CLI gets the instructions, then the reply in its fence; Apple Intelligence, the two apart.
        #expect(asked.first?.0 == GrammarFix.request(for: text).prompt)
        #expect(await fixer.fix("i use `retryCount`", with: StorySummaries.appleIntelligenceModel) == .success("I use `retryCount`."))
        let request = GrammarFix.request(for: "i use `retryCount`")
        #expect(toldOnDevice.first?.0 == request.text)
        #expect(toldOnDevice.first?.1 == request.instructions)
    }

    /// An answer that's more than a correction, or that changed code, says which model, and what may help: Apple
    /// Intelligence answers the same again, so it offers a Copilot model, and a Copilot model, to try again too.
    @Test func fixGrammarSaysWhatItTurnedDown() async {
        let fixer = GrammarFixer(isDemo: false)
        fixer.onDeviceUnavailable = { nil }
        fixer.askOnDevice = { _, _, _ in .success("Also, I think we should keep it.\n\nRetries come and go, like waves upon the shore, each a chance to try once more.") }
        let poem = await fixer.fix("also i think we shoud keep it", with: StorySummaries.appleIntelligenceModel)
        #expect(poem == .failure(GrammarFixer.turnedDown(.changedMore, by: StorySummaries.appleIntelligenceModel)))
        let onDevice = GrammarFixer.turnedDown(.changedMore, by: StorySummaries.appleIntelligenceModel)
        #expect(onDevice.message == "Apple Intelligence did more than correct your reply, such as translate, rewrite or answer it, so it stays as it is. Choose a Copilot model instead.")
        #expect(onDevice.choosesModel)
        let copilot = GrammarFixer.turnedDown(.changedHeld, by: "claude-haiku-5.5")
        #expect(copilot.message == "\(CopilotModel.name(of: "claude-haiku-5.5")) changed your code, a link or a mention, so your reply stays as it is. Try again, or choose another model.")
    }

    /// Where Apple Intelligence can't run, it says so, and offers a Copilot model: what it can't do never goes to Copilot.
    @Test func fixGrammarSaysWhenAppleIntelligenceCantRun() async {
        let fixer = GrammarFixer(isDemo: false)
        var asked = 0
        fixer.askCopilot = { _, _ in
            asked += 1
            return .success("Never")
        }
        fixer.onDeviceUnavailable = { .notEnabled }
        let problem = await fixer.fix("i think so", with: StorySummaries.appleIntelligenceModel)
        #expect(problem == .failure(GrammarFixer.unavailable(.notEnabled)))
        #expect(GrammarFixer.unavailable(.notEnabled).message.contains("turned off"))
        #expect(GrammarFixer.unavailable(.notEnabled).choosesModel)
        #expect(asked == 0)
    }

    @Test func theDemosGrammarIsMadeUp() async {
        let fixer = GrammarFixer(isDemo: true)
        fixer.askCopilot = { _, _ in .failure(.noCLI) }
        #expect(await fixer.fix("i think teh fix is good", with: "claude-haiku-5.5") == .success("I think the fix is good."))
    }
}
