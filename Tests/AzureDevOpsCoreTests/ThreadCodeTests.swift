import Foundation
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// What a pull request's details show of the code its comment threads are on, and how they list the threads: by file, as
/// a change lists its files, each saying who it waits on, long ones folded.
@Suite struct ThreadCodeTests {
    private let me = People.me

    // MARK: Rows

    @Test func anExcerptsRowsAreItsLinesWithNotesWhereLinesAreLeftOut() {
        let excerpt = ThreadExcerpt(
            threadId: 11, path: "/src/Cart.cs", side: .right,
            lines: [
                .init(kind: .unchanged, text: "let a = 1", oldNumber: 40, newNumber: 41),
                .init(kind: .removed, text: "let b = 2", oldNumber: 41, newNumber: nil, omittedAfter: 12),
                .init(kind: .removed, text: "let c = 3", oldNumber: 54, newNumber: nil),
                .init(kind: .added, text: "let b = 4", oldNumber: nil, newNumber: 42, isCommented: true, omittedAfter: 1),
                .init(kind: .unchanged, text: "}", oldNumber: 56, newNumber: 44),
            ],
            reachesStart: false, reachesEnd: false, hiddenCommentedLines: 3, iteration: 2, latestIteration: 2
        )
        #expect(ThreadCode.rows(of: excerpt) == [
            CodeRow(.gap, "3 more lines it's on, above"),
            CodeRow(.line(.unchanged), "let a = 1", old: 40, new: 41),
            CodeRow(.line(.removed), "let b = 2", old: 41),
            CodeRow(.gap, "12 lines left out"),
            CodeRow(.line(.removed), "let c = 3", old: 54),
            CodeRow(.line(.added), "let b = 4", new: 42, isMarked: true),
            CodeRow(.gap, "1 line left out"),
            CodeRow(.line(.unchanged), "}", old: 56, new: 44),
        ])
        var one = excerpt
        one.hiddenCommentedLines = 1
        #expect(ThreadCode.rows(of: one).first == CodeRow(.gap, "1 more line it's on, above"))
    }

    /// VoiceOver says what the gutter shows of each row, which its text, as copied, doesn't have.
    @Test func voiceOverSaysEachRowsNumbersHowItChangedAndItsText() {
        #expect(ThreadCode.spoken(CodeRow(.line(.added), "    delay *= 2;", new: 88, isMarked: true)) == "Line 88, added, commented: delay *= 2;")
        // Without its indentation, tabs too, which VoiceOver would only say.
        #expect(ThreadCode.spoken(CodeRow(.line(.removed), "\tthrow;", old: 46)) == "Line 46 before the change, removed: throw;")
        #expect(ThreadCode.spoken(CodeRow(.line(.unchanged), "}", old: 89, new: 90)) == "Line 90, 89 before the change: }")
        #expect(ThreadCode.spoken(CodeRow(.line(.unchanged), "}", old: 90, new: 90)) == "Line 90: }")
        #expect(ThreadCode.spoken(CodeRow(.line(.unchanged), "   ", old: 12, new: 12)) == "Line 12: blank")
        #expect(ThreadCode.spoken(CodeRow(.gap, "12 lines left out")) == "12 lines left out")
        #expect(ThreadCode.spoken(CodeRow(.gap, "3 more lines it's on, above")) == "3 more lines it's on, above")
    }

    @Test func codeLosesTheIndentationAllItsLinesShare() {
        let rows = [
            CodeRow(.gap, "2 lines"),
            CodeRow(.line(.unchanged), "        if (ok)", old: 1, new: 1),
            CodeRow(.line(.unchanged), "", old: 2, new: 2),
            CodeRow(.line(.unchanged), "  ", old: 3, new: 3),
            CodeRow(.line(.added), "            return;", new: 4, isMarked: true),
            CodeRow(.line(.removed), "        \t}", old: 4),
        ]
        #expect(ThreadCode.outdented(rows).map(\.text) == ["2 lines", "if (ok)", "", "", "    return;", "\t}"])
        #expect(ThreadCode.outdented(rows)[4] == CodeRow(.line(.added), "    return;", new: 4, isMarked: true))
        // Tabs and spaces only where every line has them.
        let mixed = [CodeRow(.line(.unchanged), "\t\tone"), CodeRow(.line(.unchanged), "\t  two")]
        #expect(ThreadCode.outdented(mixed).map(\.text) == ["\tone", "  two"])
        let flush = [CodeRow(.line(.unchanged), "one"), CodeRow(.line(.unchanged), "    two")]
        #expect(ThreadCode.outdented(flush) == flush)
        #expect(ThreadCode.outdented([]) == [])
    }

    // MARK: Lines

    @Test func aThreadsLinesAreWhereItWasMade() {
        // Without its location, as the demo's: its line, after the change.
        let demo = ReviewThread(id: 1, filePath: "/src/Cart.cs", line: 88, comments: [])
        #expect(ThreadCode.span(of: demo)?.lines == 88...88)
        #expect(ThreadCode.span(of: demo)?.side == .right)
        #expect(ThreadCode.expectedRows(of: demo) == 7)

        // On lines removed: before the change.
        let removed = ReviewThread(id: 2, filePath: "/src/Cart.cs", line: 12, comments: [], location: .init(
            path: "/src/Cart.cs", left: .init(lines: 12...14), madeOn: .init(base: 1)
        ))
        #expect(ThreadCode.span(of: removed)?.lines == 12...14)
        #expect(ThreadCode.span(of: removed)?.side == .left)
        #expect(ThreadCode.expectedRows(of: removed) == 9)

        // Followed to a later diff by a push: where it was made.
        let followed = ReviewThread(id: 3, filePath: "/src/Cart.cs", line: 30, comments: [], location: .init(
            path: "/src/Cart.cs", right: .init(lines: 30...31), madeOn: .init(base: 1),
            tracking: .init(to: .init(first: 1, second: 2), originalRight: .init(lines: 20...21))
        ))
        #expect(ThreadCode.span(of: followed)?.lines == 20...21)

        // On a long stretch: as many lines as its code shows.
        let long = ReviewThread(id: 4, filePath: "/src/Cart.cs", line: 1, comments: [], location: .init(
            path: "/src/Cart.cs", right: .init(lines: 1...100)
        ))
        #expect(ThreadCode.expectedRows(of: long) == ThreadExcerpt.maxCommentedLines + 6)

        // On the pull request, or on a whole file: no code.
        let general = ReviewThread(id: 5, comments: [])
        let wholeFile = ReviewThread(id: 6, filePath: "/src/Cart.cs", comments: [], location: .init(path: "/src/Cart.cs"))
        for thread in [general, wholeFile] {
            #expect(!ThreadCode.isOnLines(thread))
            #expect(ThreadCode.expectedRows(of: thread) == nil)
        }
        #expect(ThreadCode.isOnLines(demo) && ThreadCode.isOnLines(removed))

        #expect(ThreadCode.linesName(88...88) == "Line 88")
        #expect(ThreadCode.linesName(86...88) == "Lines 86–88")
    }

    /// The trail names a thread by where its card shows it, where it was made, rather than where a push moved it since.
    @Test func aThreadIsNamedWhereItsCodeShowsIt() {
        let followed = ReviewThread(id: 3, filePath: "/src/Cart.cs", line: 30, comments: [], location: .init(
            path: "/src/Cart.cs", right: .init(lines: 30...31), madeOn: .init(base: 1),
            tracking: .init(to: .init(first: 1, second: 2), originalRight: .init(lines: 20...21))
        ))
        #expect(ThreadCode.place(of: followed) == "Cart.cs:20")
        #expect(ThreadCode.placeHelp(of: followed) == "/src/Cart.cs, lines 20 to 21")
        // Where it is now, as the list says it.
        #expect(PullRequestPanel.Thread(thread: followed, waitsOnYou: false, isNew: false).place == "Cart.cs:30")

        let removed = ReviewThread(id: 2, filePath: "/src/Cart.cs", line: 46, comments: [], location: .init(
            path: "/src/Cart.cs", left: .init(lines: 46...49), madeOn: .init(base: 1)
        ))
        #expect(ThreadCode.place(of: removed) == "Cart.cs:46")
        #expect(ThreadCode.placeHelp(of: removed) == "/src/Cart.cs, lines 46 to 49 before the change")
        let demo = ReviewThread(id: 1, filePath: "/src/Cart.cs", line: 88, comments: [])
        #expect(ThreadCode.place(of: demo) == "Cart.cs:88")
        #expect(ThreadCode.placeHelp(of: demo) == "/src/Cart.cs, line 88")
        let wholeFile = ReviewThread(id: 6, filePath: "/src/Cart.cs", comments: [], location: .init(path: "/src/Cart.cs"))
        #expect(ThreadCode.place(of: wholeFile) == "Cart.cs")
        #expect(ThreadCode.placeHelp(of: wholeFile) == "/src/Cart.cs")
        let general = ReviewThread(id: 5, comments: [])
        #expect(ThreadCode.place(of: general) == nil)
        #expect(ThreadCode.placeHelp(of: general) == "A comment on the whole pull request")
    }

    // MARK: Problems

    @Test func whyCodeCantShowIsSaidBriefly() {
        #expect(ThreadCode.sentence(for: .notOnLines) == nil)
        #expect(ThreadCode.sentence(for: .binary) == "The file isn't text.")
        #expect(ThreadCode.sentence(for: .tooLarge) == "The file is too long to show here.")
        #expect(ThreadCode.sentence(for: .unreadable(.notFound)) == "Azure DevOps doesn't have this version of the file.")
        #expect(ThreadCode.sentence(for: .unreadable(.offline)) == "You're offline.")

        // Reading again may show it only when Azure DevOps couldn't be reached or asked to wait.
        let otherDirectory = ADOError.otherDirectory(organization: "contoso", tenant: "00000000-0000-0000-0000-00000000abcd")
        for problem: ThreadExcerpt.Problem in [.unreadable(.offline), .unreadable(.throttled(retryAfter: 60)), .unreadable(.http(503)),
                                               .unreadable(.network("The request timed out.")), .unreadable(.unauthorized),
                                               .unreadable(otherDirectory)] {
            #expect(ThreadCode.mayPass(problem))
        }
        for problem: ThreadExcerpt.Problem in [.binary, .tooLarge, .linesNotFound, .noIterations, .tooManyFiles, .notOnLines,
                                               .unreadable(.notFound), .unreadable(.forbidden), .unreadable(.decoding("?"))] {
            #expect(!ThreadCode.mayPass(problem))
        }
    }

    @Test func aFileThatChangedSinceOpensAtWhatChanged() throws {
        let pr = makePR(4102)
        let record = PRRecord(pullRequest: pr, role: .author, details: makeDetails(for: pr), me: me.id)
        let item = try #require(PRClassifier.snapshot(for: record, seenCutoff: t(-day), dismissedCutoff: t(-day), now: t(0)))
        let excerpt = ThreadExcerpt(
            threadId: 11, path: "/src/Payments Client.cs", side: .right, lines: [], reachesStart: true, reachesEnd: true,
            iteration: 1, latestIteration: 3, changedSince: true
        )
        #expect(item.filePageURL(path: excerpt.path, since: excerpt).absoluteString
            == "https://dev.azure.com/contoso/Shop/_git/shop-web/pullrequest/4102?_a=files&path=%2Fsrc%2FPayments%20Client.cs&iteration=3&base=1")
    }

    // MARK: By file

    private func panel(_ threads: [ReviewThread], author: Person = People.me, seen: Date = t(-3 * day)) throws -> PullRequestPanel {
        let pr = makePR(author: author, reviewers: author == me ? [] : [Reviewer(person: me, vote: .none)])
        let record = PRRecord(pullRequest: pr, role: author == me ? .author : .reviewer, details: makeDetails(for: pr, threads: threads),
                              me: me.id)
        let item = try #require(PRClassifier.snapshot(for: record, seenCutoff: seen, dismissedCutoff: t(-3 * day), now: t(0)))
        return PullRequestPanel(item, record: record)
    }

    @Test func threadsGoByFileAsTheChangeListsItsFilesWithTheOnesOnThePullRequestApart() throws {
        let threads = [
            ReviewThread(id: 1, filePath: "/tests/CartTests.cs", line: 5, comments: [comment(1, People.sam, at: t(-5 * hour))]),
            ReviewThread(id: 2, filePath: "/src/Cart.cs", line: 40, comments: [comment(1, People.sam, at: t(-4 * hour))]),
            // A reply to you: it waits on you, below the other on its file.
            ReviewThread(id: 3, filePath: "/src/Cart.cs", line: 60, comments: [
                comment(1, me, "Is a minute enough?", at: t(-6 * hour)), comment(2, People.sam, "Make it two.", at: t(-2 * hour)),
            ]),
            ReviewThread(id: 4, filePath: "/src/Cart.cs", line: 12, comments: [comment(1, People.priya, at: t(-3 * hour))]),
            ReviewThread(id: 5, comments: [comment(1, People.alex, at: t(-hour))]),
            ReviewThread(id: 6, filePath: "/src/Checkout/Total.cs", line: 3, comments: [comment(1, People.alex, at: t(-hour))]),
            ReviewThread(id: 7, filePath: "/README.md", line: 1, comments: [comment(1, People.alex, at: t(-hour))]),
            // On the whole file: before those on its lines.
            ReviewThread(id: 8, filePath: "/src/Cart.cs", comments: [comment(1, People.alex, at: t(-hour))]),
            ReviewThread(id: 9, status: "fixed", filePath: "/src/Cart.cs", line: 2, comments: [comment(1, People.alex, at: t(-4 * day))]),
            ReviewThread(id: 10, status: "closed", comments: [comment(1, People.alex, at: t(-4 * day))]),
        ]
        // Alex's: only Sam's reply to you waits on you.
        let byFile = try panel(threads, author: People.alex).threads.openByFile
        // Folders before files, folder by folder.
        #expect(byFile.map(\.path) == [nil, "/src/Checkout/Total.cs", "/src/Cart.cs", "/tests/CartTests.cs", "/README.md"])
        #expect(byFile.map { $0.threads.map(\.id) } == [[5], [6], [3, 8, 4, 2], [1], [7]])
        #expect(byFile[2].name == "Cart.cs" && byFile[2].folder == "src")
        #expect(byFile[1].folder == "src/Checkout")
        #expect(byFile[4].folder == nil && byFile[0].name == nil && byFile[0].folder == nil)
        #expect(Set(byFile.map(\.id)).count == byFile.count)

        let resolved = try panel(threads, author: People.alex).threads.resolvedByFile
        #expect(resolved.map(\.path) == [nil, "/src/Cart.cs"])
        #expect(resolved.map { $0.threads.map(\.id) } == [[10], [9]])
    }

    @Test func filesAreListedFolderByFolder() {
        let paths = ["/src/b.cs", "/src/A.cs", "/src/a/z.cs", "/Z.md", "/src/file10.cs", "/src/file9.cs", "/docs/x.md", "/a.md"]
        #expect(paths.sorted(by: PullRequestPanel.listsFirst)
            == ["/docs/x.md", "/src/a/z.cs", "/src/A.cs", "/src/b.cs", "/src/file9.cs", "/src/file10.cs", "/a.md", "/Z.md"])
        #expect(!PullRequestPanel.listsFirst("/src/a.cs", "/src/a.cs"))
        #expect(PullRequestPanel.listsFirst("/src/A.cs", "/src/a.cs") != PullRequestPanel.listsFirst("/src/a.cs", "/src/A.cs"))

        // Every pair the same way both ways round, and in a chain, as sorting needs: names with "ß", case and numbers too,
        // and two that look the same, "é" in one character and in two, which Git tells apart.
        let names = ["/src/Maß.cs", "/src/Mast.cs", "/src/Masse.cs", "/src/Massnahme.cs", "/src/MASS.cs", "/src/mass2.cs",
                     "/src/mass10.cs", "/src/mass02.cs", "/src/Straße/a.cs", "/src/strasse.cs", "/src/Ärger.cs", "/src/Arger.cs",
                     "/src/caf\u{E9}.cs", "/src/cafe\u{301}.cs", "/src/Caf\u{E9}.cs", "src/mass2.cs"]
        for a in names {
            for b in names where !a.utf8.elementsEqual(b.utf8) {
                #expect(!(PullRequestPanel.listsFirst(a, b) && PullRequestPanel.listsFirst(b, a)), "\(a) and \(b)")
                #expect(PullRequestPanel.listsFirst(a, b) || PullRequestPanel.listsFirst(b, a), "\(a) and \(b)")
                for c in names where PullRequestPanel.listsFirst(a, b) && PullRequestPanel.listsFirst(b, c) {
                    #expect(PullRequestPanel.listsFirst(a, c), "\(a), \(b) and \(c)")
                }
            }
        }
    }

    /// Two paths that look the same to Swift, but not to Git, such as "é" in one character and in two, are two files, each
    /// with its threads, always in the same order.
    @Test func filesThatLookTheSameButArentStayApart() throws {
        let composed = "/src/caf\u{E9}.cs"
        let decomposed = "/src/cafe\u{301}.cs"
        #expect(composed == decomposed)
        let threads = [
            ReviewThread(id: 1, filePath: composed, line: 3, comments: [comment(1, People.sam, at: t(-2 * hour))]),
            ReviewThread(id: 2, filePath: decomposed, line: 3, comments: [comment(1, People.sam, at: t(-hour))]),
            ReviewThread(id: 3, filePath: composed, line: 9, comments: [comment(1, People.sam, at: t(-hour))]),
        ]
        let byFile = try panel(threads, author: People.alex).threads.openByFile
        #expect(byFile.count == 2)
        // By their bytes: "e" and the accent after it before "é" in one character.
        #expect(byFile.map { $0.threads.map(\.id) } == [[2], [1, 3]])
        #expect(byFile.first?.path.map { $0.utf8.elementsEqual(decomposed.utf8) } == true)
        #expect(Set(byFile.map(\.id)).count == 2)
        // However the threads come.
        #expect(try panel(threads.reversed(), author: People.alex).threads.openByFile.map { $0.threads.map(\.id) } == [[2], [1, 3]])
    }

    // MARK: Who it waits on

    @Test func anOpenThreadSaysWhoItWaitsOn() throws {
        let team = Reviewer(person: Person(id: "66666666-6666-6666-6666-666666666666", name: "[Shop]\\Checkout Team"), vote: .none,
                            isGroup: true)
        let mine = makePR(author: me, reviewers: [Reviewer(person: People.sam, vote: .none), team])
        let samsPR = makePR(author: People.sam, reviewers: [Reviewer(person: me, vote: .none)])
        func thread(_ comments: [ReviewComment], status: String = "active") -> PullRequestPanel.Thread {
            PullRequestPanel.Thread(thread: ReviewThread(id: 1, status: status, comments: comments), waitsOnYou: false, isNew: false)
        }
        // On Sam's pull request, you asked: Sam answers.
        #expect(thread([comment(1, me, at: t(-hour))]).waitingOn(in: samsPR, me: me.id) == "Sam")
        // On yours, you answered Priya: she answers.
        let answered = thread([comment(1, People.priya, at: t(-2 * hour)), comment(2, me, at: t(-hour))])
        #expect(answered.waitingOn(in: mine, me: me.id) == "Priya")
        // On Sam's, Priya asked: Sam answers; Sam answered Priya: she does.
        #expect(thread([comment(1, People.priya, at: t(-hour))]).waitingOn(in: samsPR, me: me.id) == "Sam")
        let samAnswered = thread([comment(1, People.priya, at: t(-2 * hour)), comment(2, People.sam, at: t(-hour))])
        #expect(samAnswered.waitingOn(in: samsPR, me: me.id) == "Priya")
        // Whom the latest comment mentions, a team too.
        let mentioned = thread([comment(1, me, "@Alex could you check the cache?", at: t(-hour), mentions: [People.alex])])
        #expect(mentioned.waitingOn(in: makePR(author: me, reviewers: [Reviewer(person: People.alex, vote: .none)]), me: me.id) == "Alex")
        let teamMentioned = thread([comment(1, me, at: t(-hour), mentions: [team.person])])
        #expect(teamMentioned.waitingOn(in: mine, me: me.id) == "Checkout Team")
        // A bot's comment on Sam's: Sam answers.
        #expect(thread([comment(1, People.bot, at: t(-hour))]).waitingOn(in: samsPR, me: me.id) == "Sam")
        // On Sam's, Priya asks you, and you removed it from Needs You: it's your turn, not Sam's, though it doesn't wait
        // on you here anymore; and so it is when she asks you and Alex.
        let asksYou = thread([comment(1, People.priya, "@Robin could you check?", at: t(-hour), mentions: [me])])
        #expect(asksYou.waitingOn(in: samsPR, me: me.id) == nil)
        let asksYouAndAlex = thread([comment(1, People.priya, at: t(-hour), mentions: [People.alex, me])])
        #expect(asksYouAndAlex.waitingOn(in: samsPR, me: me.id.uppercased()) == nil)
        // She asks someone BriefBar can't name: not Sam either. With Sam too, Sam.
        let jordan = Person(id: "77777777-7777-7777-7777-777777777777", name: "Jordan Lee")
        #expect(thread([comment(1, People.priya, at: t(-hour), mentions: [jordan])]).waitingOn(in: samsPR, me: me.id) == nil)
        let asksJordanAndSam = thread([comment(1, People.priya, at: t(-hour), mentions: [jordan, People.sam])])
        #expect(asksJordanAndSam.waitingOn(in: samsPR, me: me.id) == "Sam")
        // A mention of herself asks no one: Sam answers, as when she mentions nobody.
        #expect(thread([comment(1, People.priya, at: t(-hour), mentions: [People.priya])]).waitingOn(in: samsPR, me: me.id) == "Sam")

        // Your turn, though it doesn't wait on you anymore, such as one you removed from Needs You: nobody else's.
        #expect(thread([comment(1, People.priya, at: t(-hour))]).waitingOn(in: mine, me: me.id) == nil)
        // Only you spoke, on yours; a resolved one; one that waits on you, which says so itself.
        #expect(thread([comment(1, me, at: t(-hour))]).waitingOn(in: mine, me: me.id) == nil)
        #expect(thread([comment(1, me, at: t(-hour))], status: "fixed").waitingOn(in: samsPR, me: me.id) == nil)
        var waits = thread([comment(1, People.sam, at: t(-hour))])
        waits.waitsOnYou = true
        #expect(waits.waitingOn(in: mine, me: me.id) == nil)
    }

    // MARK: Folding

    @Test func aLongThreadShowsItsFirstAndLatestComments() {
        func thread(_ count: Int) -> PullRequestPanel.Thread {
            PullRequestPanel.Thread(
                thread: ReviewThread(id: 1, comments: (1...count).map { comment($0, People.sam, at: t(Double($0) * minute)) }),
                waitsOnYou: false, isNew: false
            )
        }
        #expect(thread(1).foldedComments == 0)
        #expect(thread(3).foldedComments == 0)
        #expect(thread(4).foldedComments == 2)
        #expect(thread(9).foldedComments == 7)
    }
}
