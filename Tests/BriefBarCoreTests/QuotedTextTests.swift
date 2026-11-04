import Foundation
import Testing
@testable import BriefBarCore

/// What a prompt for Copilot quotes stays quoted: in a fence nothing in it closes, and, in a command, as a word a shell runs
/// nothing of.
@Suite struct QuotedTextTests {
    /// Backticks a model may read as one run, with a character between them that has no width, get a longer fence all the
    /// same; one that's seen, such as a space, ends the run.
    @Test func aFenceOutlastsBackticksWithUnseenCharactersBetweenThem() {
        #expect(QuotedText.fence(for: "plain") == "```")
        #expect(QuotedText.fence(for: "a ````` b") == "``````")
        // A joiner, a zero-width space, an accent, an emoji's variation selector and one past emoji's.
        for between in ["\u{200D}", "\u{200B}", "\u{301}", "\u{FE0F}", "\u{E0100}"] {
            #expect(QuotedText.fence(for: "``" + between + "``") == "`````", "\(between.unicodeScalars.map(\.value))")
        }
        #expect(QuotedText.fence(for: "`` ``") == "```")
        #expect(QuotedText.fence(for: "``a``") == "```")
        // The joiner stays, as emoji have it, inside the longer fence.
        #expect(QuotedText.fenced("``\u{200D}``") == ["`````", "``\u{200D}``", "`````"])
    }

    /// A shell reads the word back as the text it was, and runs nothing in it: `$(…)`, backticks, a quote, `;`, `|`, `&`, a
    /// variable, braces, a glob, a tilde or a comment, in sh and in zsh. An ordinary branch's name stays as it is.
    @Test(.timeLimit(.minutes(1)))
    func aShellReadsAWordAsTheTextItWas() async throws {
        #expect(QuotedText.shellWord("users/robin/fix-total_2.1+x@y,z:w") == "users/robin/fix-total_2.1+x@y,z:w")
        #expect(QuotedText.shellWord("fix$(echo ran)") == "'fix$(echo ran)'")
        #expect(QuotedText.shellWord("it's") == #"'it'\''s'"#)
        #expect(QuotedText.shellWord("") == "''")
        let texts = [
            "fix$(echo ran)", "a`echo ran`b", "it's", "x;echo ran|cat&", "$HOME", "{a,b}", "*", "~", "#x", #"a\nb"#, "ünï", "!x",
            "=ls", "a b", #""q""#, "a>b<c", "users/robin/fix-total",
        ]
        for shell in ["/bin/sh", "/bin/zsh"] {
            for text in texts {
                let result = try await ProcessRunner().run(
                    URL(fileURLWithPath: shell), arguments: ["-c", "printf '%s' " + QuotedText.shellWord(text)],
                    environment: ["PATH": "/usr/bin:/bin"], timeout: 10
                )
                #expect(result.status == 0, "\(shell): \(text)")
                #expect(String(decoding: result.stdout, as: UTF8.self) == text, "\(shell): \(text)")
            }
        }
    }
}
