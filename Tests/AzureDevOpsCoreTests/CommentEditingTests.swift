import Foundation
import Testing
@testable import AzureDevOpsCore

/// A comment of yours as you edit it: its mentions as the names the details show, and back as they were, so that editing it
/// keeps whom it mentions, and what you leave as it was goes as it was.
@Suite struct CommentEditingTests {
    private let sam = People.sam.id, priya = People.priya.id
    private var names: [String: String] { [sam: "Sam Rivera", priya: "Priya Shah", People.alex.id: "Sam"] }

    @Test func showsMentionsAsNamesAndPutsThemBack() {
        let content = "Thanks @<\(sam.uppercased())>, capped it. @<\(priya)> could you look too?"
        let editing = CommentEditing(content: content, names: names)
        #expect(editing.text == "Thanks @Sam Rivera, capped it. @Priya Shah could you look too?")
        // Left as it is, it goes as it was, the mentions' IDs as the comment had them.
        #expect(editing.content(of: editing.text) == content)
        // Edited, the names it showed are mentions again, wherever they are; another name isn't one.
        #expect(editing.content(of: "@Priya Shah, @Sam Rivera's right: capped at 30 seconds. @Alex Kim too.")
            == "@<\(priya)>, @<\(sam.uppercased())>'s right: capped at 30 seconds. @Alex Kim too.")
        // A name only as part of a longer word isn't the mention.
        #expect(editing.content(of: "@Sam Riveras") == "@Sam Riveras")
    }

    /// A mention whose name isn't known, or that another of its mentions shares, stays as Azure DevOps keeps it.
    @Test func keepsAMentionItCantNameAsItIs() {
        let unknown = "5c1a0000-0000-0000-0000-00000000abcd"
        let content = "@<\(unknown)> and @<\(sam)>"
        let editing = CommentEditing(content: content, names: names)
        #expect(editing.text == "@<\(unknown)> and @Sam Rivera")
        #expect(editing.content(of: editing.text) == content)

        let twins = CommentEditing(content: "@<\(sam)> @<\(priya)>", names: [sam: "Sam", priya: "Sam"])
        #expect(twins.text == "@<\(sam)> @<\(priya)>")
        #expect(twins.content(of: twins.text) == twins.content)
    }

    /// A name the comment says as text too, or that would take another name's place on the way back, isn't shown as a name:
    /// what you leave as it was always goes as it was.
    @Test func whatYouLeaveAsItWasGoesAsItWas() {
        // "@Sam Rivera" is text here, not the mention.
        let said = "@Sam Rivera wrote this, as @<\(sam)> knows"
        let editing = CommentEditing(content: said, names: names)
        #expect(editing.text == said)
        #expect(editing.content(of: editing.text) == said)

        // Alex, named "Sam", mentioned before "Rivera" as text, would come back as Sam Rivera's mention.
        let alex = People.alex.id
        let ambiguous = "@<\(alex)> Rivera, and @<\(sam)>"
        let shown = CommentEditing(content: ambiguous, names: names)
        #expect(shown.content(of: shown.text) == ambiguous)

        // Nothing to name.
        let plain = CommentEditing(content: "  Capped it.\n\n- one\n", names: names)
        #expect(plain.text == "  Capped it.\n\n- one\n")
        #expect(plain.content(of: "Capped it at 30 seconds.") == "Capped it at 30 seconds.")
    }

    /// From a thread's comment: its mentions named by the pull request's people and the thread's.
    @Test func namesMentionsAsTheDetailsDo() {
        let pullRequest = makePR(7, reviewers: [Reviewer(person: People.priya, vote: .none)])
        let mine = ReviewComment(
            id: 2, author: People.me, text: "Thanks", publishedAt: t(0), content: "Thanks @<\(sam)> and @<\(priya)>"
        )
        let thread = ReviewThread(id: 12, comments: [comment(1, People.sam, "Cap it?", at: t(-hour)), mine])
        #expect(CommentEditing(mine, in: thread, of: pullRequest).text == "Thanks @Sam Rivera and @Priya Shah")
        // One made up, as the demo's, says what it shows.
        let madeUp = comment(3, People.me, "Done, @Sam Rivera", at: t(0))
        #expect(CommentEditing(madeUp, in: thread, of: pullRequest).text == "Done, @Sam Rivera")
    }
}
