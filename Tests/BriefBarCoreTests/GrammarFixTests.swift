import Foundation
import Testing
@testable import BriefBarCore

/// Fix Grammar: what it asks a model, what it holds back from it, and what it makes of the answer.
@Suite struct GrammarFixTests {
    /// Code, links, pictures, web addresses and mentions go to the model as markers, and nothing else does.
    @Test func holdsBackCodeLinksAndMentions() {
        let text = "pls use `retryCount` in [the docs](https://example.invalid/docs) and ask @sam.rivera, see https://example.invalid/a?b=1. "
            + "Mail sam@contoso.example, or ping @<6B3C1F2A-0000-4000-8000-000000000001> ![chart](chart.png) <br/>"
        let request = GrammarFix.request(for: text)
        #expect(request.held == [
            "`retryCount`", "[the docs](https://example.invalid/docs)", "@sam.rivera", "https://example.invalid/a?b=1",
            "@<6B3C1F2A-0000-4000-8000-000000000001>", "![chart](chart.png)", "<br/>",
        ])
        #expect(request.text == """
            <text>
            pls use {{1}} in {{2}} and ask {{3}}, see {{4}}. Mail sam@contoso.example, or ping {{5}} {{6}} {{7}}
            </text>
            """)
        #expect(request.prompt == GrammarFix.instructions + "\n\n" + request.text)
    }

    @Test func holdsBackAFencedCodeBlockWhole() {
        let text = "this fails:\n```swift\nlet x = retrys + 1\n```\nany idea why"
        let request = GrammarFix.request(for: text)
        #expect(request.held == ["```swift\nlet x = retrys + 1\n```"])
        #expect(request.text == "<text>\nthis fails:\n{{1}}\nany idea why\n</text>")
        // One that never closes, to the end.
        #expect(GrammarFix.request(for: "see\n~~~\nlet a = 1\nlet b").held == ["~~~\nlet a = 1\nlet b"])
    }

    /// Markers the text has of its own aren't taken for its markers.
    @Test func picksMarkersTheTextDoesntHave() {
        let request = GrammarFix.request(for: "use {{name}} with `code`")
        #expect(request.held == ["`code`"])
        #expect(request.text == "<text>\nuse {{name}} with [[1]]\n</text>")
        let answer = "<text>\nUse {{name}} with [[1]].\n</text>"
        #expect(GrammarFix.corrected(answer, for: request) == .success("Use {{name}} with `code`."))
    }

    /// What the model answers, without the tags or the quotes around it, and with what it held back put back as it was.
    @Test func putsBackWhatItHeldBack() {
        let request = GrammarFix.request(for: "i use `retryCount` per @sam")
        #expect(GrammarFix.corrected("<text>\nI use {{1}}, per {{2}}.\n</text>", for: request) == .success("I use `retryCount`, per @sam."))
        #expect(GrammarFix.corrected("I use {{1}}, per {{2}}.", for: request) == .success("I use `retryCount`, per @sam."))
        #expect(GrammarFix.corrected("\"I use {{1}}, per {{2}}.\"", for: request) == .success("I use `retryCount`, per @sam."))
        #expect(GrammarFix.corrected("```\nI use {{1}}, per {{2}}.\n```", for: request) == .success("I use `retryCount`, per @sam."))
    }

    /// An answer that lost, repeated, moved or made up a marker would change code, a link or a mention: it's turned down.
    @Test func turnsDownAnAnswerThatChangedWhatItHeldBack() {
        let request = GrammarFix.request(for: "i use `retryCount` per @sam")
        for answer in ["I use retryCount, per {{2}}.", "I use {{1}}, per {{2}} and {{2}}.", "Per {{2}}, I use {{1}}.", "I use {{1}}, per {{2}} {{3}}."] {
            #expect(GrammarFix.corrected(answer, for: request) == .failure(.changedHeld), "\(answer)")
        }
        #expect(GrammarFix.corrected("  \n", for: request) == .failure(.empty))
        #expect(GrammarFix.corrected("<text>\n</text>", for: request) == .failure(.empty))
    }

    @Test func tellsTheModelToCorrectOnlyInTheTextsOwnLanguage() {
        let instructions = GrammarFix.instructions
        #expect(instructions.contains("spelling, grammar and punctuation, and nothing else"))
        #expect(instructions.contains("never translate"))
        #expect(instructions.contains("{{1}}"))
        #expect(instructions.contains("Markdown"))
    }

    // MARK: What changed

    /// The corrected text in runs, what changed apart, a word at a time, without the spaces around a change.
    @Test func showsWhatChangedWordByWord() {
        let pieces = GrammarFix.changes(from: "i think teh fix is good", to: "I think the fix is good.")
        #expect(pieces == [
            .init("I", isChanged: true), .init(" think ", isChanged: false), .init("the", isChanged: true),
            .init(" fix is good", isChanged: false), .init(".", isChanged: true),
        ])
        #expect(pieces.map(\.text).joined() == "I think the fix is good.")
        #expect(GrammarFix.changeCount(pieces) == 3)
    }

    /// A word taken out shows on the word after it, or else on the one before.
    @Test func showsAWordTakenOut() {
        #expect(GrammarFix.changes(from: "it is is fine", to: "it is fine") == [
            .init("it is ", isChanged: false), .init("fine", isChanged: true),
        ])
        #expect(GrammarFix.changes(from: "it is fine fine", to: "it is fine") == [
            .init("it is ", isChanged: false), .init("fine", isChanged: true),
        ])
    }

    @Test func nothingChangedIsOneRun() {
        let pieces = GrammarFix.changes(from: "It reads right.", to: "It reads right.")
        #expect(pieces == [.init("It reads right.", isChanged: false)])
        #expect(GrammarFix.changeCount(pieces) == 0)
    }

    @Test func toldApartWordsSpacesAndPunctuation() {
        #expect(GrammarFix.tokens("Don't stop,  ok?") == ["Don't", " ", "stop", ",", "  ", "ok", "?"])
    }

    // MARK: The demo's

    /// The demo makes its corrections up, as a model's would be, and keeps what a model doesn't see.
    @Test func makesUpTheDemosCorrections() {
        #expect(GrammarFix.madeUp("i think teh backoff should cap at 30 seconds , its in `RetryOptions`")
            == "I think the backoff should cap at 30 seconds, its in `RetryOptions`.")
        #expect(GrammarFix.madeUp("Done. thanks @sam") == "Done. Thanks @sam.")
        #expect(GrammarFix.madeUp("It reads right.") == "It reads right.")
    }
}
