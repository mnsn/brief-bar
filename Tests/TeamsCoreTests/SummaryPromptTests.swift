import Foundation
import Testing
@testable import TeamsCore
@testable import NotificationCenterDB
import BriefBarCore

@Suite struct SummaryPromptTests {
    private func message(_ text: String, sender: String?, at seconds: TimeInterval, kind: ConversationKind = .group) -> ChatMessage {
        ChatMessage(conversationID: Chat.launchCrew, kind: kind, messageID: messageID(t(seconds)), notificationKey: "n\(seconds)",
                    deliveredAt: t(seconds), chatName: "Launch crew", sender: sender, text: text)
    }

    private func conversation(unread: [ChatMessage], latest: [ChatMessage] = [], kind: ConversationKind = .group) -> ConversationSummary {
        ConversationSummary(id: Chat.launchCrew, kind: kind, group: kind.chatGroup ?? .groups, name: "Launch crew",
                            unread: unread, latestMessages: latest.isEmpty ? unread : latest,
                            lastActivity: (latest.last ?? unread.last)?.deliveredAt ?? t(0), link: nil)
    }

    @Test func listsTheUnreadMessagesWithTheirSenders() {
        let prompt = SummaryPrompt.prompt(for: conversation(unread: [
            message("Staging is green", sender: "Jordan Lee", at: 1),
            message("Shipping at 5\nunless someone objects", sender: "Maya Chen", at: 2),
        ]))
        #expect(prompt == """
            Chat: Launch crew (a group chat)
            Messages, oldest first:
            Jordan Lee: Staging is green
            Maya Chen: Shipping at 5 unless someone objects
            """)
    }

    @Test func usesTheLatestMessagesWhenNothingIsUnread() {
        let read = message("Thanks!", sender: "Avery Quinn", at: 1, kind: .oneOnOne)
        let prompt = SummaryPrompt.prompt(for: conversation(unread: [], latest: [read], kind: .oneOnOne))
        #expect(prompt.hasSuffix("Avery Quinn: Thanks!"))
        #expect(prompt.contains("(a 1:1 chat)"))
    }

    @Test func keepsTheNewestMessagesWithinTheLimit() {
        let messages = (0..<50).map { message("Message number \($0) " + String(repeating: "x", count: 100), sender: "Sam", at: Double($0)) }
        let prompt = SummaryPrompt.prompt(for: conversation(unread: messages), limit: 1_000)
        #expect(prompt.count < 1_200)
        #expect(prompt.contains("Message number 49"))
        #expect(!prompt.contains("Message number 0 "))
        let lines = prompt.split(separator: "\n").dropFirst(2)
        #expect(lines.first?.contains("Message number 4") == true)
        #expect(lines.last?.contains("Message number 49") == true)
    }

    @Test func shortensVeryLongMessages() {
        let prompt = SummaryPrompt.prompt(for: conversation(unread: [message(String(repeating: "y", count: 5_000), sender: "Sam", at: 1)]))
        #expect(prompt.count < 700)
        #expect(prompt.hasSuffix("…"))
    }

    @Test func changesItsKeyWithEachNewMessage() {
        let first = conversation(unread: [message("One", sender: "Sam", at: 1)])
        let second = conversation(unread: [message("One", sender: "Sam", at: 1), message("Two", sender: "Sam", at: 2)])
        #expect(SummaryPrompt.key(for: first) != SummaryPrompt.key(for: second))
        #expect(SummaryPrompt.key(for: first) == SummaryPrompt.key(for: conversation(unread: [message("One", sender: "Sam", at: 1)])))
    }

    @Test(arguments: [
        ("\"Staging is green.\"", "Staging is green."),
        ("  Shipping at 5.\n\n Objections welcome. ", "Shipping at 5. Objections welcome."),
        ("“Quoted”", "Quoted"),
        ("Plain", "Plain"),
    ])
    func tidiesTheAnswer(_ response: String, _ expected: String) {
        #expect(SummaryPrompt.clean(response) == expected)
    }
}
