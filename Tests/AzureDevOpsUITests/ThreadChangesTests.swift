import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
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
        changes.send = { try azure.send($0) }
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

    /// A reply goes once, as you wrote it, in reply to the thread's first comment; it shows at once, as Azure DevOps answered,
    /// what you wrote goes, and the thread doesn't wait on you anymore.
    @Test func aReplyGoesOnceAndShowsAtOnce() async throws {
        let (store, changes, azure) = live()
        #expect(store.items.first { $0.key == key }?.group == .needsYou)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        changes.keep("Capped it at 30 seconds.", for: threadKey)
        let record = try #require(store.record(for: key))

        #expect(await changes.reply("  Capped it at 30 seconds.\n", to: try thread(store), of: key))
        #expect(azure.sent == [.reply(ThreadAddress(record.pullRequest, thread: 11), markdown: "Capped it at 30 seconds.", parentCommentId: 1)])
        let replied = try thread(store)
        #expect(replied.comments.map(\.id) == [1, 2, 3])
        #expect(replied.comments.last?.markdown == "Capped it at 30 seconds.")
        #expect(changes.draft(threadKey).isEmpty)
        #expect(changes.state(of: threadKey) == nil)
        // Answered: it doesn't wait on you.
        #expect(store.items.first { $0.key == key }?.group != .needsYou)
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

    /// A reply that fails keeps what you wrote, and the thread says why; one that may have gone isn't sent again as it is.
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

        // Gone after all, though Azure DevOps didn't answer in time: as the list reads it again, your last word there is the
        // same reply, which isn't sent twice.
        azure.fails = nil
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        snapshot.records[index].details?.threads[0].comments.append(
            ReviewComment(id: 3, author: DemoData.me, text: "Capped it.", publishedAt: store.now)
        )
        store.receive(snapshot)
        let sent = azure.sent.count
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key))
        #expect(azure.sent.count == sent)
        #expect(changes.draft(threadKey).isEmpty)
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
        changes.send = { _ in
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

    // MARK: Fix Grammar

    @Test func fixGrammarCorrectsWithTheModelYouChose() async {
        let fixer = GrammarFixer(isDemo: false)
        var asked: [(String, String)] = []
        fixer.askCopilot = { prompt, model in
            asked.append((prompt, model))
            return .success("<text>\nI use {{1}}, as @sam asked.\n</text>")
        }
        fixer.askOnDevice = { _, _ in .success("I use {{1}}.") }
        let fixed = await fixer.fix("i use `retryCount` as @sam asked", with: "claude-haiku-5.5")
        #expect(fixed == .failure(GrammarFixer.Problem(
            message: "The model changed your code, a link or a mention, so your reply stays as it is. Try again, or choose another model.",
            choosesModel: true
        )))
        fixer.askCopilot = { _, _ in .success("<text>\nI use {{1}}, as {{2}} asked.\n</text>") }
        #expect(await fixer.fix("i use `retryCount` as @sam asked", with: "claude-haiku-5.5") == .success("I use `retryCount`, as @sam asked."))
        #expect(asked.first?.1 == "claude-haiku-5.5")
        #expect(asked.first?.0.hasPrefix(GrammarFix.instructions) == true)
        #expect(await fixer.fix("i use `retryCount`", with: StorySummaries.appleIntelligenceModel) == .success("I use `retryCount`."))
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
