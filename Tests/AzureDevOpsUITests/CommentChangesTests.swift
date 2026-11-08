import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// Your own comments in pull requests' threads, edited or deleted, with Make Changes in Azure DevOps on: only yours, only
/// while it's on and the pull request open, only when you click, as you; once, though you click twice, in two windows, or
/// try again after an answer that didn't say; and what shows at once, and is read again. With the demo's made-up pull
/// requests, read as a list that reads Azure DevOps would, and a stand-in for Azure DevOps that answers as it does.
@MainActor
@Suite struct CommentChangesTests {
    /// What the stand-in for Azure DevOps was sent, and answers: the comment as it keeps it once edited, without when it was
    /// published, which the thread says; and nothing for a deletion, as its reference says.
    final class AzureDevOps {
        var sent: [ADOWrite] = []
        var fails: ADOError?

        func send(_ write: ADOWrite) throws -> ADOWrite.Answer {
            sent.append(write)
            if let fails { throw fails }
            switch write {
            case .editComment(_, let comment, let markdown):
                return .comment(try ADOJSON.decoder().decode(ADOComment.self, from: JSONSerialization.data(withJSONObject: [
                    "id": comment, "parentCommentId": 0, "content": markdown, "commentType": "text",
                    "lastContentUpdatedDate": "2030-01-01T10:00:00Z",
                    "author": ["id": DemoData.me.id, "displayName": DemoData.me.name, "uniqueName": "robin@contoso.example"],
                ] as [String: Any])))
            case .deleteComment:
                return .done
            case .reply(_, let markdown, _):
                // Your reply, which you may delete then.
                return .comment(try ADOJSON.decoder().decode(ADOComment.self, from: JSONSerialization.data(withJSONObject: [
                    "id": 3, "parentCommentId": 1, "content": markdown, "commentType": "text", "publishedDate": "2030-01-01T10:00:00Z",
                    "author": ["id": DemoData.me.id, "displayName": DemoData.me.name, "uniqueName": "robin@contoso.example"],
                ] as [String: Any])))
            case .setStatus(let address, let status):
                // A status set meanwhile, as from its thread's menu.
                return .thread(try ADOJSON.decoder().decode(ADOThread.self, from: JSONSerialization.data(withJSONObject: [
                    "id": address.id, "status": status.rawValue,
                ] as [String: Any])))
            case .addTag, .removeTag:
                // Comments' changes never send one (TagChangesTests).
                throw ADOError.http(400)
            }
        }
    }

    /// The pull requests read again after a change, and with what.
    final class Reads: Sendable {
        let made = Mutex<[ThreadChange?]>([])
        var count: Int { made.withLock { $0.count } }
        var changes: [ThreadChange?] { made.withLock { $0 } }
    }

    /// The demo's pull request that Sam replied on, on its thread 11: your comment 1, then Sam's 2.
    private let key = PRKey(DemoData.organization, 4102)

    private func live(makesChanges: Bool = true) -> (store: PRStore, changes: ThreadChanges, azure: AzureDevOps, reads: Reads) {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.makesChanges = makesChanges
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .live)
        settings.useSeenState(DemoData.seenState(now: store.now))
        store.receive(DemoData.snapshot(now: store.now))
        let reads = Reads()
        store.readAfterChange = { _, change in
            reads.made.withLock { $0.append(change) }
            return nil
        }
        let changes = ThreadChanges(store: store, settings: settings)
        let azure = AzureDevOps()
        changes.send = { write, _ in try azure.send(write) }
        return (store, changes, azure, reads)
    }

    private func thread(_ store: PRStore, _ id: Int = 11) throws -> ReviewThread {
        try #require(store.record(for: key)?.details?.threads.first { $0.id == id })
    }

    private func address(_ store: PRStore, _ thread: Int = 11) throws -> ThreadAddress {
        ThreadAddress(try #require(store.record(for: key)).pullRequest, thread: thread)
    }

    /// Yours, the first comment, and Sam's.
    private func comments(_ store: PRStore) throws -> (mine: ReviewComment, sams: ReviewComment) {
        let comments = try thread(store).comments
        return (try #require(comments.first { $0.author == DemoData.me }), try #require(comments.first { $0.author != DemoData.me }))
    }

    /// The pull request's threads with another, as a refresh would read them.
    private func receive(_ store: PRStore, with extra: ReviewThread) throws {
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        snapshot.records[index].details?.threads.append(extra)
        store.receive(snapshot)
    }

    private func waitForReads(_ reads: Reads, _ count: Int) async {
        for _ in 0..<1_000 where reads.count < count { await Task.yield() }
    }

    // MARK: Whose

    /// Only your own comments, and not a code change's, can be changed, and only while the setting's on and the pull request
    /// open: nothing goes otherwise.
    @Test func onlyYourOwnCommentsCanBeChanged() async throws {
        let (store, changes, azure, _) = live()
        let record = try #require(store.record(for: key))
        let (mine, sams) = try comments(store)
        #expect(changes.canChange(mine, of: record.pullRequest))
        #expect(!changes.canChange(sams, of: record.pullRequest))
        #expect(await changes.edit("Capped it.", of: sams, in: try thread(store), of: key) == false)
        #expect(await changes.delete(sams, in: try thread(store), of: key) == false)

        // A code change's, though yours.
        let code = ReviewComment(id: 3, author: DemoData.me, text: "Updated the code", publishedAt: store.now, commentType: "codeChange")
        try receive(store, with: ReviewThread(id: 70, comments: [code]))
        #expect(!changes.canChange(code, of: record.pullRequest))
        #expect(await changes.delete(code, in: try thread(store, 70), of: key) == false)
        #expect(azure.sent.isEmpty)
        // As the list read them again, now.
        #expect(try thread(store).comments.map(\.markdown) == [mine.markdown, sams.markdown])

        changes.settings.makesChanges = false
        #expect(!changes.canChange(mine, of: record.pullRequest))
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key) == false)
        #expect(await changes.delete(mine, in: try thread(store), of: key) == false)
        #expect(azure.sent.isEmpty)
    }

    /// Nor for a pull request that's completed or abandoned, which says so on the thread, or one that left your lists.
    @Test func nothingGoesForAPullRequestThatsClosedOrNotListed() async throws {
        let (store, changes, azure, _) = live()
        let (mine, _) = try comments(store)
        let original = try thread(store)
        let done = try #require(store.records.first { $0.pullRequest.status != .active })
        #expect(!changes.canChange(mine, of: done.pullRequest))
        #expect(await changes.edit("Late.", of: mine, in: original, of: done.id) == false)
        #expect(changes.state(of: ThreadChanges.Key(pullRequest: done.id, thread: 11)) == .failed(.closed, .edit(comment: mine.id)))

        let shown = try #require(store.record(for: key))
        var snapshot = DemoData.snapshot(now: store.now)
        snapshot.records.removeAll { $0.id == key }
        store.receive(snapshot)
        #expect(!changes.canChange(mine, of: shown.pullRequest))
        #expect(await changes.delete(mine, in: original, of: key) == false)
        #expect(changes.state(of: ThreadChanges.Key(pullRequest: key, thread: 11)) == .failed(.notListed, .delete(comment: mine.id)))
        #expect(azure.sent.isEmpty)
    }

    // MARK: Editing

    /// An edit goes once, as you wrote it, but for the lines that say nothing before it and the spaces after it; it shows at
    /// once, edited, as Azure DevOps answered, what you wrote goes, and the pull request is read again.
    @Test func anEditGoesOnceAndShowsAtOnce() async throws {
        let (store, changes, azure, reads) = live()
        let record = try #require(store.record(for: key))
        let (mine, sams) = try comments(store)
        let draft = ThreadChanges.CommentKey(thread: ThreadChanges.Key(pullRequest: key, thread: 11), comment: mine.id)
        let started = changes.startEditing(mine, in: try thread(store), of: record.pullRequest)
        #expect(started.text == mine.markdown)
        changes.keepEdit("Exponential, from 200 ms", for: draft, from: started.base)
        #expect(changes.startEditing(mine, in: try thread(store), of: record.pullRequest).text == "Exponential, from 200 ms")

        let edited = "Exponential backoff, from 200 ms, doubling up to 30 seconds."
        #expect(await changes.edit("\n \n" + edited + "  \n", from: started.base, of: mine, in: try thread(store), of: key))
        #expect(azure.sent == [.editComment(try address(store), comment: mine.id, markdown: edited)])
        let shown = try thread(store)
        #expect(shown.comments.map(\.id) == [mine.id, sams.id])
        #expect(shown.comments[0].markdown == edited)
        #expect(shown.comments[0].publishedAt == mine.publishedAt)
        #expect(shown.comments[0].editedAt != nil)
        #expect(shown.comments[1] == sams)
        #expect(changes.edit(draft) == nil)
        #expect(changes.state(of: draft.thread) == nil)
        await waitForReads(reads, 1)
        #expect(reads.changes.compactMap { $0?.edited.map(\.id) } == [[mine.id]])
    }

    /// Saved as it was, it goes nowhere.
    @Test func anEditThatSaysWhatTheCommentSaysGoesNowhere() async throws {
        let (store, changes, azure, reads) = live()
        let (mine, _) = try comments(store)
        #expect(await changes.edit(mine.markdown + "\n", of: mine, in: try thread(store), of: key))
        #expect(azure.sent.isEmpty)
        #expect(reads.count == 0)
        #expect(await changes.edit("  \n", of: mine, in: try thread(store), of: key) == false)
        #expect(azure.sent.isEmpty)
    }

    /// The mentions your comment had, shown as names as you edit it, go as mentions again.
    @Test func anEditKeepsWhomTheCommentMentions() async throws {
        let (store, changes, azure, _) = live()
        let record = try #require(store.record(for: key))
        let sam = try comments(store).sams.author
        let content = "Thanks @<\(sam.id.uppercased())>, capped it."
        let mine = ReviewComment(id: 2, author: DemoData.me, text: "Thanks @Sam Rivera, capped it.", publishedAt: store.now, content: content)
        try receive(store, with: ReviewThread(id: 70, comments: [
            ReviewComment(id: 1, author: sam, text: "Cap it?", publishedAt: store.now.addingTimeInterval(-60)), mine,
        ]))
        #expect(changes.startEditing(mine, in: try thread(store, 70), of: record.pullRequest).text == "Thanks @\(sam.name), capped it.")
        #expect(await changes.edit("Thanks @\(sam.name), capped it at 30 seconds.", of: mine, in: try thread(store, 70), of: key))
        #expect(azure.sent == [.editComment(try address(store, 70), comment: 2, markdown: "Thanks @<\(sam.id.uppercased())>, capped it at 30 seconds.")])
    }

    /// Opening your comment to edit it keeps nothing until you change it: as its field opens with what it says, nothing's a
    /// draft. What you change is kept with what the comment said as you began, though the comment says something else since,
    /// as edited elsewhere: opened again, it has what you wrote, and tells it changed. Saved then, nothing goes, which would
    /// replace what it says now unseen, unless you chose to replace what it says now (Save Anyway); and Start Over begins
    /// again from what it says now, which forgets what you wrote.
    @Test func anEditBegunBeforeTheCommentChangedReplacesItOnlyOnceYouSaySo() async throws {
        let (store, changes, azure, reads) = live()
        let record = try #require(store.record(for: key))
        let (mine, _) = try comments(store)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        let draft = ThreadChanges.CommentKey(thread: threadKey, comment: mine.id)
        let started = changes.startEditing(mine, in: try thread(store), of: record.pullRequest)
        changes.keepEdit(started.text, for: draft, from: started.base)
        #expect(changes.edit(draft) == nil)
        changes.keepEdit("Exponential, from 200 ms.", for: draft, from: started.base)
        #expect(changes.edit(draft) == "Exponential, from 200 ms.")
        // Back to what it said: nothing to keep.
        changes.keepEdit(started.text, for: draft, from: started.base)
        #expect(changes.edit(draft) == nil)
        changes.keepEdit("Exponential, from 200 ms.", for: draft, from: started.base)
        #expect(!changes.changedSince(started.base, now: mine, editing: "Exponential, from 200 ms.", on: threadKey))

        // Edited elsewhere, as the list reads it.
        let elsewhere = "Exponential, from 200 ms, capped at 30 seconds."
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        let at = try #require(snapshot.records[index].details?.threads[0].comments.firstIndex { $0.id == mine.id })
        snapshot.records[index].details?.threads[0].comments[at].text = elsewhere
        snapshot.records[index].details?.threads[0].comments[at].markdown = elsewhere
        store.receive(snapshot)
        let now = try comments(store).mine
        #expect(now.markdown == elsewhere)
        // Opened again: what you wrote, which it tells was begun before.
        let reopened = changes.startEditing(now, in: try thread(store), of: record.pullRequest)
        #expect(reopened == ThreadChanges.EditDraft(text: "Exponential, from 200 ms.", base: started.base))
        #expect(changes.changedSince(reopened.base, now: now, editing: reopened.text, on: threadKey))
        // Not once it says what you wrote, nor what you began with.
        #expect(!changes.changedSince(reopened.base, now: now, editing: elsewhere, on: threadKey))
        #expect(!changes.changedSince(reopened.base, now: mine, editing: reopened.text, on: threadKey))

        // Saved, nothing goes, and what you wrote is kept.
        #expect(await changes.edit(reopened.text, from: reopened.base, of: now, in: try thread(store), of: key) == false)
        #expect(azure.sent.isEmpty)
        #expect(reads.count == 0)
        #expect(changes.edit(draft) == "Exponential, from 200 ms.")
        #expect(changes.state(of: threadKey) == nil)
        #expect(try comments(store).mine.markdown == elsewhere)
        // Saved as it was when you began, or as it is now: nothing goes either, and there's nothing to save.
        #expect(await changes.edit(started.text, from: started.base, of: now, in: try thread(store), of: key))
        #expect(await changes.edit(elsewhere, from: started.base, of: now, in: try thread(store), of: key))
        #expect(azure.sent.isEmpty)
        // Save Anyway, chosen as it said something else, replaces nothing.
        #expect(await changes.edit("Capped at 30 seconds.", from: started.base, replacing: "Something else", of: now,
                                   in: try thread(store), of: key) == false)
        #expect(azure.sent.isEmpty)
        // Save Anyway, chosen as it says this: it goes, in place of what it says now.
        #expect(await changes.edit("Capped at 30 seconds.", from: started.base, replacing: now.kept, of: now, in: try thread(store), of: key))
        #expect(azure.sent == [.editComment(try address(store), comment: mine.id, markdown: "Capped at 30 seconds.")])
        #expect(try comments(store).mine.markdown == "Capped at 30 seconds.")
    }

    /// Start Over begins your edit again from what the comment says now, and forgets what you wrote.
    @Test func startOverBeginsAgainFromWhatTheCommentSaysNow() throws {
        let (store, changes, _, _) = live()
        let record = try #require(store.record(for: key))
        let (mine, _) = try comments(store)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        let draft = ThreadChanges.CommentKey(thread: threadKey, comment: mine.id)
        let started = changes.startEditing(mine, in: try thread(store), of: record.pullRequest)
        changes.keepEdit("Exponential, from 200 ms.", for: draft, from: started.base)
        var now = mine
        now.text = "Capped at 30 seconds."
        now.markdown = "Capped at 30 seconds."
        let again = changes.startOver(now, in: try thread(store), of: record.pullRequest)
        #expect(again.text == "Capped at 30 seconds.")
        #expect(again.base.content == "Capped at 30 seconds.")
        #expect(changes.edit(draft) == nil)
        #expect(!changes.changedSince(again.base, now: now, editing: again.text, on: threadKey))
    }

    /// An edit of yours that may have gone, as one Azure DevOps didn't answer in time, which the list shows the comment says,
    /// is yours, not a change elsewhere: what you write after it goes, without your saying so.
    @Test func yourOwnEditThatMayHaveGoneIsntAChangeElsewhere() async throws {
        let (store, changes, azure, _) = live()
        let record = try #require(store.record(for: key))
        let (mine, _) = try comments(store)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        let started = changes.startEditing(mine, in: try thread(store), of: record.pullRequest)
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.edit("Capped it.", from: started.base, of: mine, in: try thread(store), of: key) == false)
        azure.fails = nil

        // It went, as the list reads it.
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        let at = try #require(snapshot.records[index].details?.threads[0].comments.firstIndex { $0.id == mine.id })
        snapshot.records[index].details?.threads[0].comments[at].text = "Capped it."
        snapshot.records[index].details?.threads[0].comments[at].markdown = "Capped it."
        store.receive(snapshot)
        let now = try comments(store).mine
        #expect(!changes.changedSince(started.base, now: now, editing: "Capped it at 30 seconds.", on: threadKey))
        #expect(await changes.edit("Capped it at 30 seconds.", from: started.base, of: now, in: try thread(store), of: key))
        #expect(azure.sent.map(\.kind) == [.editComment, .editComment])
        // Someone else's, though: it changed since.
        var theirs = now
        theirs.text = "Capped it at a minute."
        theirs.markdown = "Capped it at a minute."
        #expect(changes.changedSince(started.base, now: theirs, editing: "Capped it at 30 seconds.", on: threadKey))
    }

    /// VoiceOver hears that a comment you edit changed since you began once for each version of it, though each edit that
    /// shows it says so, in one window or two; a Save refused for a version it heard of says only that your edit wasn't
    /// saved, and one refused for a version it didn't, both; and an edit opened again hears it again, once.
    @Test func voiceOverHearsEachVersionOfAChangedCommentOnce() throws {
        final class Spoken {
            var said: [String] = []
        }
        let (store, changes, _, _) = live()
        let spoken = Spoken()
        changes.speak = { spoken.said.append($0) }
        var now = try comments(store).mine
        let draft = ThreadChanges.CommentKey(thread: ThreadChanges.Key(pullRequest: key, thread: 11), comment: now.id)
        now.text = "Capped it at a minute."
        now.markdown = now.text
        changes.sayChanged(now, on: draft)
        changes.sayChanged(now, on: draft)
        changes.sayChanged(now, on: draft, unsaved: true)
        var later = now
        later.text = "Capped it at two minutes."
        later.markdown = later.text
        changes.sayChanged(later, on: draft, unsaved: true)
        changes.sayChanged(later, on: draft)
        changes.hearChangesAgain(draft)
        changes.sayChanged(later, on: draft)
        let changed = ThreadChanges.changedSentence, unsaved = ThreadChanges.unsavedSentence, choices = ThreadChanges.changedChoices
        #expect(spoken.said == [
            changed + " " + choices,
            unsaved,
            changed + " " + unsaved + " " + choices,
            changed + " " + choices,
        ])
    }

    /// An edit that may have gone, checked by reading its thread again, finds the comment as you began; but a refresh that
    /// came while it was read brought it edited elsewhere: nothing goes, which would replace what BriefBar has read unseen,
    /// and the list keeps what the refresh brought.
    @Test func anEditCheckedWhileARefreshBroughtAnotherVersionSendsNothing() async throws {
        let (store, changes, azure, _) = live()
        let record = try #require(store.record(for: key))
        let (mine, _) = try comments(store)
        let started = changes.startEditing(mine, in: try thread(store), of: record.pullRequest)
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.edit("Capped it.", from: started.base, of: mine, in: try thread(store), of: key) == false)
        azure.fails = nil

        let elsewhere = "Capped it at a minute."
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        let at = try #require(snapshot.records[index].details?.threads.firstIndex { $0.id == 11 })
        let comment = try #require(snapshot.records[index].details?.threads[at].comments.firstIndex { $0.id == mine.id })
        snapshot.records[index].details?.threads[at].comments[comment].text = elsewhere
        snapshot.records[index].details?.threads[at].comments[comment].markdown = elsewhere
        let refreshed = snapshot, read = [try thread(store)]
        changes.readThreads = { _ in
            store.receive(refreshed)
            return read
        }
        #expect(await changes.edit("Capped it.", from: started.base, of: mine, in: try thread(store), of: key) == false)
        #expect(azure.sent.count == 1)
        #expect(try comments(store).mine.markdown == elsewhere)
        #expect(changes.changedSince(started.base, now: try comments(store).mine, editing: "Capped it.",
                                     on: ThreadChanges.Key(pullRequest: key, thread: 11)))
    }

    /// An edit that may have gone, checked by reading its thread again, finds the comment says something else, which you
    /// haven't seen: nothing goes, and it shows what the thread has, for your edit to say what it says now.
    @Test func anEditCheckedAfterTheCommentChangedElsewhereSendsNothing() async throws {
        let (store, changes, azure, _) = live()
        let record = try #require(store.record(for: key))
        let (mine, _) = try comments(store)
        let started = changes.startEditing(mine, in: try thread(store), of: record.pullRequest)
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.edit("Capped it.", from: started.base, of: mine, in: try thread(store), of: key) == false)
        azure.fails = nil

        var read = try thread(store)
        read.comments[0].text = "Capped it at a minute."
        read.comments[0].markdown = "Capped it at a minute."
        let threads = [read]
        changes.readThreads = { _ in threads }
        #expect(await changes.edit("Capped it.", from: started.base, of: mine, in: try thread(store), of: key) == false)
        #expect(azure.sent.count == 1)
        #expect(try comments(store).mine.markdown == "Capped it at a minute.")
        #expect(changes.changedSince(started.base, now: try comments(store).mine, editing: "Capped it.",
                                     on: ThreadChanges.Key(pullRequest: key, thread: 11)))
    }

    /// Your edit's names go back as the mentions they showed as you began, though the comment changed elsewhere since and
    /// doesn't mention them anymore, once you chose to replace what it says now.
    @Test func anEditsNamesGoBackAsTheMentionsTheyShowedAsYouBegan() async throws {
        let (store, changes, azure, _) = live()
        let record = try #require(store.record(for: key))
        let sam = try comments(store).sams.author
        let samsComment = ReviewComment(id: 1, author: sam, text: "Cap it?", publishedAt: store.now.addingTimeInterval(-60))
        let content = "Thanks @<\(sam.id.uppercased())>, capped it."
        let mine = ReviewComment(id: 2, author: DemoData.me, text: "Thanks @Sam Rivera, capped it.", publishedAt: store.now, content: content)
        try receive(store, with: ReviewThread(id: 70, comments: [samsComment, mine]))
        let started = changes.startEditing(mine, in: try thread(store, 70), of: record.pullRequest)
        #expect(started.text == "Thanks @\(sam.name), capped it.")

        // Edited elsewhere: it mentions nobody now.
        var now = mine
        now.content = "Capped it."
        now.markdown = "Capped it."
        now.text = "Capped it."
        now.mentions = []
        try receive(store, with: ReviewThread(id: 70, comments: [samsComment, now]))
        #expect(await changes.edit("Thanks @\(sam.name), capped it at 30 seconds.", from: started.base, replacing: now.kept, of: now,
                                   in: try thread(store, 70), of: key))
        #expect(azure.sent == [.editComment(try address(store, 70), comment: 2, markdown: "Thanks @<\(sam.id.uppercased())>, capped it at 30 seconds.")])
    }

    // MARK: Deleting

    /// A deletion goes once: the comment leaves its thread at once, and the pull request is read again.
    @Test func aDeletionGoesOnceAndTheCommentLeaves() async throws {
        let (store, changes, azure, reads) = live()
        let (mine, sams) = try comments(store)
        #expect(await changes.delete(mine, in: try thread(store), of: key))
        #expect(azure.sent == [.deleteComment(try address(store), comment: mine.id)])
        #expect(try thread(store).comments == [sams])
        #expect(changes.state(of: ThreadChanges.Key(pullRequest: key, thread: 11)) == nil)
        await waitForReads(reads, 1)
        #expect(reads.changes == [ThreadChange(thread: 11, deleted: [mine.id])])
    }

    /// A thread whose last comment you delete leaves the details, as Azure DevOps deletes it then.
    @Test func aThreadLeavesWithItsLastComment() async throws {
        let (store, changes, azure, _) = live()
        let only = ReviewComment(id: 1, author: DemoData.me, text: "Should this be async?", publishedAt: store.now)
        try receive(store, with: ReviewThread(id: 70, comments: [only]))
        #expect(await changes.delete(only, in: try thread(store, 70), of: key))
        #expect(azure.sent == [.deleteComment(try address(store, 70), comment: 1)])
        #expect(store.record(for: key)?.details?.threads.contains { $0.id == 70 } == false)
        #expect(try thread(store).comments.count == 2)
    }

    // MARK: Once

    /// Clicked twice, or in two windows, which share what's on its way: while one change to a thread goes, no other does, an
    /// edit, a deletion or a reply.
    @Test(.timeLimit(.minutes(1)))
    func aChangeGoesOnceWhileItsThreadIsBusy() async throws {
        let (store, changes, azure, _) = live()
        let (mine, _) = try comments(store)
        var waiting: CheckedContinuation<Void, Never>?
        changes.send = { write, _ in
            await withCheckedContinuation { waiting = $0 }
            return try azure.send(write)
        }
        let original = try thread(store)
        let editing = Task { await changes.edit("Capped it.", of: mine, in: original, of: key) }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        #expect(changes.state(of: threadKey) == .sending(.edit(comment: mine.id)))
        #expect(await changes.edit("Capped it.", of: mine, in: original, of: key) == false)
        #expect(await changes.delete(mine, in: original, of: key) == false)
        #expect(await changes.reply("Done.", to: original, of: key) == false)
        try #require(waiting).resume()
        #expect(await editing.value)
        #expect(azure.sent.map(\.kind) == [.editComment])
    }

    /// A thread takes one change at a time: while a status you set, or that another window sent, is on its way, your
    /// deletion sends nothing, and the comment stays, which the delete confirmation shows by waiting to delete it
    /// (`CommentDeleteConfirmation.isBusy`); once the status is done, it goes.
    @Test(.timeLimit(.minutes(1)))
    func aDeletionWaitsForAStatusOnItsWay() async throws {
        let (store, changes, azure, _) = live()
        let (mine, _) = try comments(store)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        var waiting: CheckedContinuation<Void, Never>?
        var holds = true
        changes.send = { write, _ in
            if holds {
                holds = false
                await withCheckedContinuation { waiting = $0 }
            }
            return try azure.send(write)
        }
        let original = try thread(store)
        let setting = Task { await changes.setStatus(.fixed, of: original, in: key) }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
        #expect(changes.isSending(threadKey))
        #expect(await changes.delete(mine, in: original, of: key) == false)
        #expect(changes.state(of: threadKey) == .sending(.status(.fixed)))
        #expect(azure.sent.isEmpty)
        #expect(try thread(store).comments.contains { $0.id == mine.id })

        try #require(waiting).resume()
        await setting.value
        #expect(!changes.isSending(threadKey))
        #expect(await changes.delete(mine, in: try thread(store), of: key))
        #expect(azure.sent.map(\.kind) == [.setStatus, .deleteComment])
    }

    /// An edit Azure DevOps didn't answer in time may have been saved: the pull request is read again, and the same edit isn't
    /// sent again until its thread, read again for it, says the comment doesn't say it. Not while the thread can't be read,
    /// which keeps what you wrote; and not once it says it.
    @Test func anEditThatMayHaveGoneIsCheckedBeforeItGoesAgain() async throws {
        let (store, changes, azure, _) = live()
        let (mine, _) = try comments(store)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        let draft = ThreadChanges.CommentKey(thread: threadKey, comment: mine.id)
        var readAgain: [PRKey] = []
        changes.readAgain = { readAgain.append($0) }
        let record = try #require(store.record(for: key))
        changes.keepEdit("Capped it.", for: draft, from: changes.startEditing(mine, in: try thread(store), of: record.pullRequest).base)
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.unanswered, .edit(comment: mine.id)))
        #expect(readAgain == [key])
        #expect(changes.edit(draft) == "Capped it.")
        azure.fails = nil

        var reads = 0
        changes.readThreads = { _ in
            reads += 1
            return nil
        }
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key) == false)
        #expect(reads == 1)
        #expect(azure.sent.count == 1)
        #expect(changes.state(of: threadKey) == .failed(.unconfirmed, .edit(comment: mine.id)))
        #expect(changes.edit(draft) == "Capped it.")

        // Read, it says it: it was saved, and goes no more.
        var read = try thread(store)
        read.comments[0].content = "Capped it."
        let saved = [read]
        changes.readThreads = { _ in
            reads += 1
            return saved
        }
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key))
        #expect(reads == 2)
        #expect(azure.sent.count == 1)
        #expect(changes.edit(draft) == nil)
        #expect(changes.state(of: threadKey) == nil)
        // Another edit goes without reading it first: it can't be the one that may have gone.
        #expect(await changes.edit("Capped it at 30 seconds.", of: mine, in: try thread(store), of: key))
        #expect(reads == 2)
        #expect(azure.sent.count == 2)
    }

    /// An edit found saved, after an answer that didn't say, shows over an edit of the comment before it, which the list
    /// keeps showing until a snapshot has it: the snapshot that has the later one doesn't, and would never.
    @Test func anEditFoundSavedShowsOverTheEditBeforeIt() async throws {
        let (store, changes, azure, _) = live()
        let (mine, _) = try comments(store)
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key))
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.edit("Capped it at 30 seconds.", of: try comments(store).mine, in: try thread(store), of: key) == false)
        azure.fails = nil

        // Azure DevOps made it, as the list reads it, from a snapshot that never had the edit before it.
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        let at = try #require(snapshot.records[index].details?.threads[0].comments.firstIndex { $0.id == mine.id })
        snapshot.records[index].details?.threads[0].comments[at].text = "Capped it at 30 seconds."
        snapshot.records[index].details?.threads[0].comments[at].markdown = "Capped it at 30 seconds."
        store.receive(snapshot)
        let read = try #require(snapshot.records[index].details?.threads.first { $0.id == 11 })
        changes.readThreads = { _ in [read] }
        #expect(await changes.edit("Capped it at 30 seconds.", of: try comments(store).mine, in: try thread(store), of: key))
        #expect(azure.sent.map(\.kind) == [.editComment, .editComment])
        #expect(try comments(store).mine.markdown == "Capped it at 30 seconds.")
        // And stays so, as the list reads it again.
        store.receive(snapshot)
        #expect(try comments(store).mine.markdown == "Capped it at 30 seconds.")
    }

    /// An edit's answer that comes after the list read a later edit of the comment, made elsewhere meanwhile, doesn't put
    /// back what it said, then or as the list reads it again: Azure DevOps dates each edit, and the later one stays.
    @Test(.timeLimit(.minutes(1)))
    func anEditsAnswerAfterALaterEditDoesntPutItBack() async throws {
        let (store, changes, azure, _) = live()
        let (mine, _) = try comments(store)
        var waiting: CheckedContinuation<Void, Never>?
        changes.send = { write, _ in
            await withCheckedContinuation { waiting = $0 }
            return try azure.send(write)
        }
        let original = try thread(store)
        let editing = Task { await changes.edit("Capped it.", of: mine, in: original, of: key) }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }

        // Edited elsewhere after it was saved, as Azure DevOps dates it, and read so before its answer comes.
        let elsewhere = "Capped it at 30 seconds, from Azure DevOps."
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        let at = try #require(snapshot.records[index].details?.threads[0].comments.firstIndex { $0.id == mine.id })
        snapshot.records[index].details?.threads[0].comments[at].text = elsewhere
        snapshot.records[index].details?.threads[0].comments[at].markdown = elsewhere
        // The stand-in dates its edit at 10:00.
        snapshot.records[index].details?.threads[0].comments[at].editedAt = try Date("2030-01-01T11:00:00Z", strategy: .iso8601)
        store.receive(snapshot)
        try #require(waiting).resume()
        #expect(await editing.value)
        #expect(try comments(store).mine.markdown == elsewhere)
        store.receive(snapshot)
        #expect(try comments(store).mine.markdown == elsewhere)
    }

    /// A reply of yours you deleted, found deleted after an answer that didn't say, leaves the thread, though the list kept
    /// showing it until a snapshot had it, which none will now.
    @Test func aDeletionFoundDoneTakesTheReplyTheListShows() async throws {
        let (store, changes, azure, _) = live()
        #expect(await changes.reply("Capped it.", to: try thread(store), of: key))
        let reply = try #require(try thread(store).comments.last)
        #expect(reply.markdown == "Capped it.")
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.delete(reply, in: try thread(store), of: key) == false)
        azure.fails = nil

        // Deleted, as the list reads it: the thread as it was before the reply.
        let snapshot = DemoData.snapshot(now: store.now)
        store.receive(snapshot)
        let read = try #require(snapshot.records.first { $0.id == key }?.details?.threads.first { $0.id == 11 })
        changes.readThreads = { _ in [read] }
        #expect(await changes.delete(reply, in: try thread(store), of: key))
        #expect(azure.sent.map(\.kind) == [.reply, .deleteComment])
        #expect(try thread(store).comments.contains { $0.id == reply.id } == false)
        store.receive(snapshot)
        #expect(try thread(store).comments.contains { $0.id == reply.id } == false)
    }

    /// An edit or a deletion that may have gone, checked by reading its thread again, sends nothing once its pull request left
    /// your lists, or closed, while the thread was read, though the thread says it didn't go.
    @Test func aChangeCheckedAfterItsPullRequestLeftYourListsSendsNothing() async throws {
        let (store, changes, azure, _) = live()
        let (mine, _) = try comments(store)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key) == false)
        #expect(await changes.delete(mine, in: try thread(store), of: key) == false)
        azure.fails = nil
        let original = try thread(store)
        var snapshot = DemoData.snapshot(now: store.now)
        snapshot.records.removeAll { $0.id == key }
        let without = snapshot
        changes.readThreads = { [weak store] _ in
            // It leaves your lists as its thread is read, which hasn't either.
            store?.receive(without)
            return [original]
        }
        #expect(await changes.edit("Capped it.", of: mine, in: original, of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.notListed, .edit(comment: mine.id)))
        store.receive(DemoData.snapshot(now: store.now))
        #expect(await changes.delete(mine, in: original, of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.notListed, .delete(comment: mine.id)))
        #expect(azure.sent.map(\.kind) == [.editComment, .deleteComment])
    }

    /// Read, a comment that doesn't say the edit that may have gone gets it, once.
    @Test func anEditThatDidntGoIsSentOnceItsThreadSaysSo() async throws {
        let (store, changes, azure, _) = live()
        let (mine, _) = try comments(store)
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key) == false)
        azure.fails = nil
        var reads = 0
        let unchanged = [try thread(store)]
        changes.readThreads = { _ in
            reads += 1
            return unchanged
        }
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key))
        #expect(reads == 1)
        #expect(azure.sent.map(\.kind) == [.editComment, .editComment])
        #expect(try thread(store).comments[0].markdown == "Capped it.")
    }

    /// A deletion Azure DevOps didn't answer in time may have gone: it isn't sent again until its thread, read again, still
    /// has the comment.
    @Test func aDeletionThatMayHaveGoneIsCheckedBeforeItGoesAgain() async throws {
        let (store, changes, azure, _) = live()
        let (mine, sams) = try comments(store)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.delete(mine, in: try thread(store), of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.unanswered, .delete(comment: mine.id)))
        azure.fails = nil

        var reads = 0
        changes.readThreads = { _ in
            reads += 1
            return nil
        }
        #expect(await changes.delete(mine, in: try thread(store), of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.unconfirmed, .delete(comment: mine.id)))
        #expect(azure.sent.count == 1)

        // Still there: it goes, once.
        let still = [try thread(store)]
        changes.readThreads = { _ in
            reads += 1
            return still
        }
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.delete(mine, in: try thread(store), of: key) == false)
        #expect(reads == 2)
        #expect(azure.sent.count == 2)
        azure.fails = nil

        // Gone: it was deleted, and goes no more.
        var read = try thread(store)
        read.comments.removeAll { $0.id == mine.id }
        let deleted = [read]
        changes.readThreads = { _ in
            reads += 1
            return deleted
        }
        #expect(await changes.delete(mine, in: try thread(store), of: key))
        #expect(reads == 3)
        #expect(azure.sent.count == 2)
        #expect(changes.state(of: threadKey) == nil)
        #expect(try thread(store).comments.contains(sams))
    }

    // MARK: Turned off, and someone else

    /// Turned off while an edit waits to go, as for a token, it never goes; nothing says it failed, and nothing is read.
    @Test func turnedOffWhileAnEditWaitsNothingGoes() async throws {
        let (store, changes, azure, reads) = live()
        let (mine, _) = try comments(store)
        var readAgain: [PRKey] = []
        changes.readAgain = { readAgain.append($0) }
        var waiting: CheckedContinuation<Void, Never>?
        changes.send = { write, _ in
            await withCheckedContinuation { waiting = $0 }
            try Task.checkCancellation()
            return try azure.send(write)
        }
        let original = try thread(store)
        let editing = Task { await changes.edit("Capped it.", of: mine, in: original, of: key) }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
        changes.settings.makesChanges = false
        try #require(waiting).resume()
        #expect(await editing.value == false)
        #expect(azure.sent.isEmpty)
        #expect(changes.state(of: ThreadChanges.Key(pullRequest: key, thread: 11)) == nil)
        #expect(try thread(store).comments[0] == mine)
        #expect(readAgain.isEmpty)
        #expect(reads.count == 0)
    }

    /// One on its way as the setting goes off settles all the same: on again before it has, its thread shows it on its way
    /// and takes no other change; then what Azure DevOps answered shows, nothing says it failed, and the thread takes changes
    /// again.
    @Test(.timeLimit(.minutes(1)))
    func turnedOffAsADeletionGoesItSettles() async throws {
        let (store, changes, azure, _) = live()
        let (mine, sams) = try comments(store)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        var waiting: CheckedContinuation<Void, Never>?
        var held = false
        changes.send = { write, _ in
            if !held {
                held = true
                await withCheckedContinuation { waiting = $0 }
            }
            return try azure.send(write)
        }
        let original = try thread(store)
        let deleting = Task { await changes.delete(mine, in: original, of: key) }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
        changes.settings.makesChanges = false
        changes.settings.makesChanges = true
        #expect(changes.state(of: threadKey) == .sending(.delete(comment: mine.id)))
        #expect(await changes.edit("Capped it.", of: mine, in: original, of: key) == false)
        #expect(azure.sent.isEmpty)

        try #require(waiting).resume()
        #expect(await deleting.value == false)
        #expect(try thread(store).comments == [sams])
        #expect(changes.state(of: threadKey) == nil)
        #expect(azure.sent.map(\.kind) == [.deleteComment])
    }

    /// An edit that may have gone though it didn't say so, as the setting went off, is read again once it has settled; and
    /// on again, the same edit is checked before it goes, though what you wrote went with the setting.
    @Test(.timeLimit(.minutes(1)))
    func turnedOffAsAnEditThatMayHaveGoneGoesItsCheckedOnceItSettles() async throws {
        let (store, changes, azure, _) = live()
        let (mine, _) = try comments(store)
        let draft = ThreadChanges.CommentKey(thread: ThreadChanges.Key(pullRequest: key, thread: 11), comment: mine.id)
        var readAgain: [PRKey] = []
        changes.readAgain = { readAgain.append($0) }
        var waiting: CheckedContinuation<Void, Never>?
        changes.send = { write, _ in
            await withCheckedContinuation { waiting = $0 }
            return try azure.send(write)
        }
        let original = try thread(store)
        changes.keepEdit("Capped it.", for: draft, from: changes.startEditing(mine, in: original, of: try #require(store.record(for: key)).pullRequest).base)
        let editing = Task { await changes.edit("Capped it.", of: mine, in: original, of: key) }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
        changes.settings.makesChanges = false
        #expect(readAgain.isEmpty)
        #expect(changes.edit(draft) == nil)
        azure.fails = .network(ADOClient.unansweredMessage)
        try #require(waiting).resume()
        #expect(await editing.value == false)
        #expect(readAgain == [key])
        #expect(changes.state(of: draft.thread) == nil)

        azure.fails = nil
        changes.send = { write, _ in try azure.send(write) }
        changes.settings.makesChanges = true
        var read = try thread(store)
        read.comments[0].content = "Capped it."
        let saved = [read]
        var reads = 0
        changes.readThreads = { _ in
            reads += 1
            return saved
        }
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key))
        #expect(reads == 1)
        #expect(azure.sent.count == 1)
    }

    /// A change goes as whom the list was read as when you clicked: someone else signed in since, the client sends nothing,
    /// and the thread says so; and someone else signing in forgets what may have gone, and what was on its way does nothing
    /// as it settles.
    @Test(.timeLimit(.minutes(1)))
    func aChangeGoesOnlyAsYou() async throws {
        let (store, changes, azure, _) = live()
        let (mine, _) = try comments(store)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        var accounts: [String?] = []
        changes.send = { write, account in
            accounts.append(account)
            return try azure.send(write)
        }
        changes.accountChanged("home/robin")
        azure.fails = .otherAccount
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.otherAccount, .edit(comment: mine.id)))
        #expect(await changes.delete(mine, in: try thread(store), of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.otherAccount, .delete(comment: mine.id)))
        #expect(accounts == ["home/robin", "home/robin"])
        #expect(try thread(store).comments[0] == mine)

        // An edit that may have gone, forgotten as Sam signs in: theirs isn't checked against it.
        azure.fails = .network(ADOClient.unansweredMessage)
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key) == false)
        azure.fails = nil
        changes.accountChanged("home/sam")
        var reads = 0
        changes.readThreads = { _ in
            reads += 1
            return nil
        }
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key))
        #expect(reads == 0)

        // One on its way as someone else signs in was the last one's: it does nothing as it settles.
        var waiting: CheckedContinuation<Void, Never>?
        changes.send = { write, _ in
            await withCheckedContinuation { waiting = $0 }
            return try azure.send(write)
        }
        let shown = try thread(store)
        let deleting = Task { await changes.delete(try #require(shown.comments.first), in: shown, of: key) }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
        changes.accountChanged("home/alex")
        try #require(waiting).resume()
        #expect(try await deleting.value == false)
        #expect(try thread(store).comments.count == 2)
        #expect(changes.state(of: threadKey) == nil)
    }

    // MARK: What it says

    /// What didn't happen says why on the thread: no permission, offline, asked to slow down, until when, or a comment
    /// Azure DevOps doesn't have anymore, which is read again, to show it gone.
    @Test func saysWhyAChangeToACommentDidntGo() async throws {
        let (store, changes, azure, _) = live()
        let (mine, _) = try comments(store)
        let threadKey = ThreadChanges.Key(pullRequest: key, thread: 11)
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        changes.now = { at }
        var readAgain: [PRKey] = []
        changes.readAgain = { readAgain.append($0) }

        azure.fails = .forbidden
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.notAllowed, .edit(comment: mine.id)))
        #expect(ADOWriteProblem.notAllowed.sentence(.editComment) == "Azure DevOps says you may not edit this comment.")
        azure.fails = .throttled(retryAfter: 300)
        #expect(await changes.delete(mine, in: try thread(store), of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.slowedDown(until: at.addingTimeInterval(300)), .delete(comment: mine.id)))
        #expect(readAgain.isEmpty)

        azure.fails = .offline
        #expect(await changes.edit("Capped it.", of: mine, in: try thread(store), of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.offline, .edit(comment: mine.id)))
        #expect(readAgain == [key])
        azure.fails = .notFound
        #expect(await changes.delete(mine, in: try thread(store), of: key) == false)
        #expect(changes.state(of: threadKey) == .failed(.gone, .delete(comment: mine.id)))
        #expect(readAgain == [key, key])
        #expect(try thread(store).comments[0] == mine)
    }

    // MARK: Kept until read

    /// An edit takes the place of the edits of its comment before it, and a deletion, of them and of the reply that added it,
    /// so that none puts back what it said; an edit of your reply shows while the reply does, and each is done with once a
    /// snapshot has it.
    @Test func editsAndDeletionsTakeThePlaceOfTheChangesBefore() throws {
        let now = Date()
        let me = DemoData.me
        let reply = ThreadChange(thread: 11, comments: [ReviewComment(id: 3, author: me, text: "Capped", publishedAt: now)])
        let first = ThreadChange(thread: 11, edited: [ReviewComment(id: 3, author: me, text: "Capped it", publishedAt: now)])
        let second = ThreadChange(thread: 11, edited: [ReviewComment(id: 3, author: me, text: "Capped it at 30s", publishedAt: now)])
        let elsewhere = ThreadChange(thread: 12, edited: [ReviewComment(id: 3, author: me, text: "Other", publishedAt: now)])
        let made = PRStore.adding(second, to: PRStore.adding(first, to: [reply, elsewhere]))
        #expect(made == [reply, elsewhere, second])
        let deleted = ThreadChange(thread: 11, deleted: [3])
        #expect(PRStore.adding(deleted, to: made) == [elsewhere, deleted])

        let records = DemoData.records(now: now)
        // Read before the reply: both show, the reply edited.
        #expect(PRStore.pending([key: [reply, second]], in: records) == [key: [reply, second]])
        let shown = PRStore.applying([key: [reply, second]], to: records)
        #expect(shown.first { $0.id == key }?.details?.threads.first { $0.id == 11 }?.comments.last?.markdown == "Capped it at 30s")
        // Read with the reply as it went: the edit is left.
        let replied = PRStore.applying([key: [reply]], to: records)
        #expect(PRStore.pending([key: [reply, second]], in: replied) == [key: [second]])
        // Read edited: done with.
        #expect(PRStore.pending([key: [reply, second]], in: shown).isEmpty)
        // A deletion is done with once the comment's gone.
        #expect(PRStore.pending([key: [deleted]], in: records).isEmpty)
        #expect(PRStore.pending([key: [deleted]], in: replied) == [key: [deleted]])
    }

    // MARK: The demo

    /// The demo sends nothing: your comments' edits and deletions are made up, in its made-up data, and stay while it runs.
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
        let (mine, sams) = try comments(store)
        #expect(changes.canChange(mine, of: store.record(for: key)?.pullRequest))
        #expect(await changes.edit("Capped it at 30 seconds.", of: mine, in: try thread(store), of: key))
        #expect(try thread(store).comments[0].markdown == "Capped it at 30 seconds.")
        #expect(try thread(store).comments[0].editedAt != nil)
        store.receive(DemoData.snapshot(now: store.now))
        #expect(try thread(store).comments[0].markdown == "Capped it at 30 seconds.")
        #expect(await changes.delete(try thread(store).comments[0], in: try thread(store), of: key))
        #expect(try thread(store).comments.map(\.id) == [sams.id])
        #expect(sent == 0)
    }
}
