import BriefBarCore
import Foundation
import Testing
@testable import CopilotCore

/// A made-up Copilot folder with a session in it: its checkpoints, as Copilot writes them, and its log.
private struct SessionFolder {
    static let id = "0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01"
    let root: URL
    var paths: CopilotPaths { CopilotPaths(root: root) }
    var checkpoints: URL { paths.sessionDirectory(Self.id).appendingPathComponent("checkpoints", isDirectory: true) }

    /// `checkpoints/index.md`, with a row for each checkpoint.
    func index(_ rows: [(number: Int, title: String, file: String)], in folder: URL? = nil) throws {
        let folder = folder ?? checkpoints
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let table = rows.map { "| \($0.number) | \($0.title) | \($0.file) |" }.joined(separator: "\n")
        try """
            # Checkpoint History

            Checkpoints are listed in chronological order. Checkpoint 1 is the oldest, higher numbers are more recent.

            | # | Title | File |
            |---|-------|------|
            \(table)

            """.write(to: folder.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }

    /// A checkpoint's file, written at `modified`.
    func checkpoint(_ name: String, _ text: String, modified: Date = t(100), in folder: URL? = nil) throws {
        let url = (folder ?? checkpoints).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func log(_ lines: [String]) throws {
        try writeLog(lines, to: paths.eventsFile(Self.id))
    }

    func read(maxMilestones: Int = 8) -> ItemStory.Account? {
        SessionAccount.read(paths: paths, id: Self.id, maxMilestones: maxMilestones)
    }
}

/// A checkpoint as Copilot writes one, made up: Markdown in tags, a section each.
private let sample = """
    <overview>
    The user asked for a **Save for later** button in the cart. Saved items are kept in a `saved_items` table, behind a small API, and show under the cart.
    - Signed-in shoppers only
    - Guests are asked to [sign in](https://example.com/sign-in)
    </overview>

    <history>
    1. **Planned the change**
       - Read `CartService` and the cart page
    2. **Added the table and the API**
    </history>

    <work_done>
    **Cart service**
    - Added the `saved_items` table and its [migration](https://example.com/migrations/42)
      - Indexed by shopper
    * Added **GET /cart/saved**

    **Cart page**
    1. Showed saved items under the cart

    ```sh
    - not an item
    ```
    </work_done>

    <technical_details>
    - Saved items keep the price they were saved at
    </technical_details>

    <important_files>
    - `src/cart/savedItems.ts`
    </important_files>

    <next_steps>
    1. Move a saved item back to the cart
       - Reuse `CartItemRow`
    2. **Test saving with an empty cart**
    - [ ] Ask Sam about guests
    </next_steps>
    """

@Suite struct SessionAccountTests {
    @Test func readsTheCheckpointsTitlesAndTheLatestOnesOverviewWorkAndNextSteps() throws {
        try withTemporaryDirectory { root in
            let session = SessionFolder(root: root)
            try session.index([
                (1, "Planning saved items for the cart", "001-planning-saved-items-for-the-c.md"),
                (2, "Saved items `table` and API added", "002-saved-items-table-and-api-a.md"),
            ])
            try session.checkpoint("001-planning-saved-items-for-the-c.md", "<overview>\nAn older overview\n</overview>", modified: t(50))
            try session.checkpoint("002-saved-items-table-and-api-a.md", sample, modified: t(100))

            #expect(session.read() == ItemStory.Account(
                source: "Copilot's checkpoints", date: t(100),
                milestones: ["Planning saved items for the cart", "Saved items table and API added"],
                overview: """
                    The user asked for a Save for later button in the cart. Saved items are kept in a saved_items table, \
                    behind a small API, and show under the cart.
                    Signed-in shoppers only
                    Guests are asked to sign in
                    """,
                done: ["Added the saved_items table and its migration", "Added GET /cart/saved", "Showed saved items under the cart"],
                next: ["Move a saved item back to the cart", "Test saving with an empty cart", "Ask Sam about guests"]
            ))
        }
    }

    /// The latest checkpoint is the one with the highest number, whatever the order of the rows; the titles show oldest
    /// first, only the latest ones when there are many, and all of them count.
    @Test func readsTheHighestNumberedCheckpoint() throws {
        try withTemporaryDirectory { root in
            let session = SessionFolder(root: root)
            try session.index([
                (2, "Second", "002-second.md"),
                (10, "Tenth", "010-tenth.md"),
                (9, "Ninth", "009-ninth.md"),
                (1, "First", "001-first.md"),
            ])
            for (name, overview) in [("001-first.md", "First"), ("002-second.md", "Second"), ("009-ninth.md", "Ninth"), ("010-tenth.md", "Tenth")] {
                try session.checkpoint(name, "<overview>\n\(overview) overview\n</overview>")
            }
            let account = try #require(session.read(maxMilestones: 3))
            #expect(account.overview == "Tenth overview")
            #expect(account.milestones == ["Second", "Ninth", "Tenth"])
            #expect(account.milestoneCount == 4)
            #expect(session.read(maxMilestones: 0)?.milestones == [])
        }
    }

    /// The index names each checkpoint's file, and any program running as you can write it: a name that isn't a single
    /// safe one is never opened, though its checkpoint's title shows.
    @Test func opensNoFileTheIndexNamesUnlessItsNameIsSafe() throws {
        try withTemporaryDirectory { root in
            let session = SessionFolder(root: root)
            try session.index([
                (1, "Safe", "001-safe.md"),
                (2, "Up a folder", "../x.md"),
                (3, "Anywhere", "/etc/x.md"),
                (4, "Hidden", ".hidden.md"),
                (5, "In a folder", "a/b.md"),
                (6, "The index", "index.md"),
            ])
            try session.checkpoint("001-safe.md", "<overview>\nThe safe one\n</overview>")
            try session.checkpoint("../x.md", "<overview>\nUp a folder\n</overview>", modified: t(200))
            try session.checkpoint(".hidden.md", "<overview>\nHidden\n</overview>", modified: t(200))
            try session.checkpoint("a/b.md", "<overview>\nIn a folder\n</overview>", modified: t(200))

            let account = try #require(session.read())
            #expect(account.overview == "The safe one")
            #expect(account.date == t(100))
            #expect(account.milestones == ["Safe", "Up a folder", "Anywhere", "Hidden", "In a folder", "The index"])

            for safe in ["001-safe.md", "a.md", "A_b-c.1.md", String(repeating: "a", count: 197) + ".md"] {
                #expect(SessionAccount.isSafeFileName(safe), "\(safe)")
            }
            for unsafe in [
                "../x.md", "/etc/x.md", ".hidden.md", "a/b.md", "index.md", "Index.md", "", ".md", "-a.md", "a.txt", "a.md/",
                "a .md", "é.md", "a\\b.md", String(repeating: "a", count: 198) + ".md",
            ] {
                #expect(!SessionAccount.isSafeFileName(unsafe), "\(unsafe)")
            }
        }
    }

    /// A session's folder is one any program running as you can write to, and BriefBar may have Full Disk Access: a link
    /// there could point it at any file, so none is followed.
    @Test func followsNoLink() throws {
        try withTemporaryDirectory { root in
            let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
            let session = SessionFolder(root: root)
            try session.index([(1, "Elsewhere", "001-elsewhere.md")], in: elsewhere)
            try session.checkpoint("001-elsewhere.md", sample, in: elsewhere)

            // The checkpoint: its title shows, from the index, but nothing of the file it links to.
            try session.index([(1, "Linked", "001-elsewhere.md")])
            try FileManager.default.createSymbolicLink(
                at: session.checkpoints.appendingPathComponent("001-elsewhere.md"),
                withDestinationURL: elsewhere.appendingPathComponent("001-elsewhere.md")
            )
            #expect(session.read() == ItemStory.Account(source: "Copilot's checkpoints", milestones: ["Linked"]))

            // The checkpoints' folder: nothing in it.
            try FileManager.default.removeItem(at: session.checkpoints)
            try FileManager.default.createSymbolicLink(at: session.checkpoints, withDestinationURL: elsewhere)
            #expect(session.read() == nil)
        }
    }

    /// What it said after its latest checkpoint, the summary it finished with or its last message, whichever came later;
    /// nothing it said before.
    @Test func addsWhatItSaidAfterTheLatestCheckpoint() throws {
        try withTemporaryDirectory { root in
            let session = SessionFolder(root: root)
            try session.index([(1, "Saved items added", "001-saved-items-added.md")])
            try session.checkpoint("001-saved-items-added.md", "<overview>\nSaved items show under the cart.\n</overview>", modified: t(100))

            try session.log([Line.userMessage(at: t(1)), Line.message("Before the checkpoint", at: t(50))])
            #expect(session.read()?.lastMessage == nil)

            try session.log([
                Line.userMessage(at: t(1)),
                Line.message("Moving on to **the tests**.", at: t(150)),
                Line.taskComplete("Saved items are done, with tests.", at: t(160)),
            ])
            #expect(session.read()?.lastMessage == "Saved items are done, with tests.")

            try session.log([
                Line.userMessage(at: t(1)),
                Line.taskComplete("Saved items are done, with tests.", at: t(160)),
                Line.message("Done. I also opened [a pull request](https://example.com/pr/1).", at: t(170)),
            ])
            let account = try #require(session.read())
            #expect(account.lastMessage == "Done. I also opened a pull request.")
            #expect(account.date == t(100))
        }
    }

    @Test func withoutCheckpointsTellsTheSummaryOrTheLastMessage() throws {
        try withTemporaryDirectory { root in
            let session = SessionFolder(root: root)
            #expect(session.read() == nil)

            try session.log([Line.userMessage(at: t(1)), Line.taskComplete("Replaced all four `README` screenshots.", at: t(10))])
            #expect(session.read() == ItemStory.Account(
                source: "Copilot's summary", date: t(10), overview: "Replaced all four README screenshots."
            ))

            // Its last message, when it came after the summary and says something else.
            try session.log([
                Line.userMessage(at: t(1)),
                Line.message("Replaced all four README screenshots.", at: t(9)),
                Line.taskComplete("Replaced all four README screenshots.", at: t(10)),
                Line.message("Replaced all four README screenshots.", at: t(11)),
            ])
            #expect(session.read() == ItemStory.Account(
                source: "Copilot's summary", date: t(11), overview: "Replaced all four README screenshots."
            ))
            try session.log([
                Line.userMessage(at: t(1)),
                Line.taskComplete("Replaced all four README screenshots.", at: t(10)),
                Line.message("The dark ones are new too.", at: t(12)),
            ])
            #expect(session.read() == ItemStory.Account(
                source: "Copilot's summary", date: t(12), overview: "Replaced all four README screenshots.",
                lastMessage: "The dark ones are new too."
            ))

            try session.log([Line.userMessage(at: t(1)), Line.message("Use an actor: it keeps the state on one queue.", at: t(5))])
            #expect(session.read() == ItemStory.Account(
                source: "Copilot's last message", date: t(5), overview: "Use an actor: it keeps the state on one queue."
            ))

            try session.log([Line.userMessage(at: t(1)), Line.assistantMessage(at: t(2), subagent: true)])
            #expect(session.read() == nil)
        }
    }

    /// Only a session's ID, a UUID, names a folder to read.
    @Test func readsNothingForAnIDThatIsntASessions() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            let folder = paths.sessionDirectory("s1").appendingPathComponent("checkpoints", isDirectory: true)
            let session = SessionFolder(root: root)
            try session.index([(1, "Not a session", "001-not-a-session.md")], in: folder)
            try session.checkpoint("001-not-a-session.md", sample, in: folder)
            try writeLog([Line.taskComplete("Not a session", at: t(1))], to: paths.eventsFile("s1"))
            #expect(SessionAccount.read(paths: paths, id: "s1") == nil)
            #expect(SessionAccount.read(paths: paths, id: "../s1") == nil)
            #expect(SessionAccount.read(paths: paths, id: "") == nil)
        }
    }

    /// Text that's long is cut short: an overview, a line of what's done or next, a title, what it said last.
    @Test func cutsLongTextShort() throws {
        try withTemporaryDirectory { root in
            let session = SessionFolder(root: root)
            let long = (1...200).map { "word\($0)" }.joined(separator: " ")
            try session.index([(1, long, "001-long.md")])
            try session.checkpoint("001-long.md", """
                <overview>
                \(long)
                </overview>
                <work_done>
                - \(long)
                </work_done>
                <next_steps>
                \((1...9).map { "\($0). Step \($0)" }.joined(separator: "\n"))
                </next_steps>
                """)
            try session.log([Line.userMessage(at: t(1)), Line.message(long, at: t(200))])

            let account = try #require(session.read())
            #expect(account.overview?.count ?? 0 <= 700)
            #expect(account.overview?.hasSuffix("…") == true)
            #expect(account.done.count == 1)
            #expect(account.done.allSatisfy { $0.count <= 200 && $0.hasSuffix("…") })
            #expect(account.milestones.allSatisfy { $0.count <= 200 && $0.hasSuffix("…") })
            #expect(account.next == ["Step 1", "Step 2", "Step 3", "Step 4", "Step 5"])
            #expect(account.lastMessage?.count ?? 0 <= 600)
            #expect(account.lastMessage?.hasSuffix("…") == true)
        }
    }

    /// The format is undocumented, so each part of it may be missing, or not as expected.
    @Test func readsWhatsThereOfACheckpoint() throws {
        // Sections that aren't closed end where the next starts, or with the text.
        let sections = SessionAccount.sections("<overview>\nOpen\n<work_done>\n- Done\n</work_done>\n<next_steps>\n1. Next")
        #expect(sections["overview"] == ["Open"])
        #expect(sections["work_done"] == ["- Done"])
        #expect(sections["next_steps"] == ["1. Next"])
        #expect(SessionAccount.sections("No tags at all").isEmpty)

        // What's done, as bold headers alone when there's no list; never what's next.
        let headers: [Substring] = ["**Cart service**", "Added the table", "**Cart page**:", "  **Indented**"]
        #expect(SessionAccount.items(headers, headers: true) == ["Cart service", "Cart page"])
        #expect(SessionAccount.items(headers, headers: false) == [])

        // A cut index loses its first line; a title may hold an escaped pipe, and a row may lack its file.
        let index = """
            | 7 | Cut short | 007-cut.md |
            | 8 | Use a \\| in a title | 008-use.md |
            | 9 |  |
            |---|---|---|
            | x | Not a number | x.md |
            """
        #expect(SessionAccount.checkpoints(inIndex: index, isCut: true) == [
            SessionAccount.Checkpoint(number: 8, title: "Use a | in a title", file: "008-use.md"),
            SessionAccount.Checkpoint(number: 9, title: "Checkpoint 9", file: nil),
        ])
        #expect(SessionAccount.checkpoints(inIndex: index).map(\.number) == [7, 8, 9])
        #expect(SessionAccount.checkpoints(inIndex: "").isEmpty)

        // Plain text: without formatting, code fences or rules, one blank line between paragraphs.
        #expect(SessionAccount.plain("## Done\n\nRan `make test`.\n\n```\nmake test\n```\n---\n\n1. **All** passed", limit: 700)
            == "Done\n\nRan make test.\n\nmake test\n\nAll passed")
    }
}
