import AppKit
import BriefBarCore
import Testing
@testable import BriefBarUI

@MainActor
@Suite struct MenuBarItemContentTests {
    private let chats = CountNoun("chat", "chats")
    private let pullRequests = CountNoun("pull request", "pull requests")
    private let sessions = CountNoun("Copilot session", "Copilot sessions")

    private func segment(_ summary: String, _ states: StateCounts, problem: String? = nil) -> MenuBarSegment {
        MenuBarSegment(
            glyph: nil, title: NSAttributedString(string: summary), summary: summary, count: states.needsYou,
            needsAttention: states.needsYou > 0, states: states, problem: problem
        )
    }

    @Test func addsUpItsSectionsByStateAndSaysWhatsInEach() {
        let item = MenuBarItemContent(
            segments: [
                segment("Teams: 2 unread chats", StateCounts(needsYou: 2)),
                segment("Azure DevOps: 4 need you", StateCounts(needsYou: 4, failing: 2, done: 2)),
                segment("Copilot: 3 need you", StateCounts(needsYou: 3, failing: 1, running: 2, done: 1)),
            ],
            counted: [chats, pullRequests, sessions], byState: [.needsYou, .failing, .done]
        )
        #expect(item.totals == StateCounts(needsYou: 9, failing: 3, running: 2, done: 3))
        #expect(item.summary == """
            Needs you: 2 chats, 4 pull requests, 3 Copilot sessions
            Something's wrong: 2 pull requests, 1 Copilot session
            Done or ready: 2 pull requests, 1 Copilot session
            """)

        // One symbol and count for each state it shows: running isn't one of them.
        let button = NSButton(frame: .zero)
        MenuBarDrawing.configure(button, item: item)
        let text = button.attributedTitle.string
        #expect(text.components(separatedBy: "\u{2009}").dropFirst().map { $0.filter(\.isNumber) } == ["9", "3", "3"])
        #expect(button.image == nil)
    }

    @Test func saysWhatKeepsASectionFromShowingAndDrawsBriefBarsSymbolForNothing() {
        let button = NSButton(frame: .zero)
        let quiet = MenuBarItemContent(
            segments: [segment("Teams", StateCounts()), segment("Copilot", StateCounts(running: 1))],
            counted: [chats, sessions], byState: [.needsYou, .failing, .done]
        )
        #expect(quiet.summary == "Nothing needs you")
        MenuBarDrawing.configure(button, item: quiet)
        #expect(button.image != nil)
        #expect(button.attributedTitle.length == 0)

        let blocked = MenuBarItemContent(
            segments: [segment("Teams", StateCounts(), problem: "Teams: Full Disk Access is off"), segment("ADO", StateCounts(needsYou: 1))],
            counted: [chats, pullRequests], byState: [.needsYou]
        )
        #expect(blocked.summary == "Needs you: 1 pull request\nTeams: Full Disk Access is off")
        MenuBarDrawing.configure(button, item: blocked)
        #expect(button.image == nil)
        // The count, then the small ⚠ last.
        let title = button.attributedTitle
        #expect(title.string.filter(\.isNumber) == "1")
        #expect(title.attribute(.attachment, at: title.length - 1, effectiveRange: nil) != nil)
    }

    @Test func showsOneSectionOrSeveralSideBySideAsTheirSourcesDrawThem() {
        let one = MenuBarItemContent(segments: [segment("Teams: 2 unread chats", StateCounts(needsYou: 2))], counted: [chats],
                                     byState: [.needsYou])
        #expect(one.byState == nil)
        #expect(one.summary == "Teams: 2 unread chats")

        let two = MenuBarItemContent(segments: [segment("A", StateCounts(needsYou: 1)), segment("B", StateCounts(done: 1))])
        #expect(two.byState == nil)
        #expect(two.summary == "A\nB")
        let button = NSButton(frame: .zero)
        MenuBarDrawing.configure(button, item: two)
        #expect(button.attributedTitle.string == "A\u{2002}B")
    }
}
