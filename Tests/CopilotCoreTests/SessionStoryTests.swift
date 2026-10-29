import BriefBarCore
import Foundation
import Testing
@testable import CopilotCore

@Suite struct SessionStoryTests {
    private func session(
        _ reason: StatusReason, detail: String? = nil, choices: [String] = [], projectName: String? = nil, branch: String? = nil,
        mode: String? = nil, contextUsage: ContextUsage? = nil, since: Date? = t(30)
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: "0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01", name: "Add dark mode to settings", projectName: projectName, branch: branch,
            isChat: false, mode: mode, phase: .idle, reason: reason, headline: reason.headline, detail: detail, choices: choices,
            since: since, contextUsage: contextUsage
        )
    }

    /// Where it stands, without its name, which its row shows: what it waits for you on, what it does, or how it ended.
    @Test func saysWhereASessionStandsWithoutItsName() {
        func sentence(_ reason: StatusReason, _ detail: String? = nil) -> String {
            session(reason, detail: detail).storySentence
        }
        #expect(sentence(.question, "Should dark mode follow the system appearance?") == "Asks: Should dark mode follow the system appearance?")
        #expect(sentence(.question) == "Waiting for your answer")
        #expect(sentence(.planApproval, "Replace cookie sessions with OAuth 2.1.") == "Has a plan for you to review: Replace cookie sessions with OAuth 2.1.")
        #expect(sentence(.planApproval) == "Has a plan for you to review")
        #expect(sentence(.permission, "git push origin main") == "Needs your permission to run git push origin main")
        #expect(sentence(.permission) == "Needs your permission")
        #expect(sentence(.working, "Run the cart tests") == "Working: Run the cart tests")
        #expect(sentence(.working) == "Working")
        #expect(sentence(.starting) == "Working")
        #expect(sentence(.finished, "Replaced all four README screenshots.") == "Finished")
        #expect(sentence(.interrupted) == "Interrupted")
        #expect(sentence(.failed, "Lost the connection.\nTry again.") == "Stopped with an error: Lost the connection. Try again.")
        #expect(sentence(.failed, "  ") == "Stopped with an error")
        #expect(sentence(.unresponsive) == "Stopped responding")
        #expect(sentence(.idle) == "Idle")

        let long = sentence(.question, String(repeating: "Is it this? ", count: 30))
        #expect(long.hasPrefix("Asks: Is it this?"))
        #expect(long.hasSuffix("…"))
        #expect(long.count <= "Asks: ".count + 160)
    }

    /// What it asks you to choose from; and, saying less, where it works, its mode, and, while it's at work or waits for
    /// you, its context, each only when it's known.
    @Test func listsWhatsKnownOfASessionInOrder() throws {
        let asking = session(
            .question, detail: "Should dark mode follow the system appearance?", choices: ["Yes, follow the system", "No, add a switch"],
            projectName: "shop-web", branch: "dark-mode", mode: "autopilot", contextUsage: ContextUsage(tokens: 124_000, limit: 200_000)
        )
        let story = try #require(SessionStory.make(snapshot: asking, account: nil))
        #expect(story == ItemStory(
            sentence: "Asks: Should dark mode follow the system appearance?", date: t(30),
            facts: [ItemStory.Fact("Choices", "Yes, follow the system · No, add a switch")],
            more: [
                ItemStory.Fact("Where", "shop-web · dark-mode"),
                ItemStory.Fact("Mode", "Autopilot"),
                ItemStory.Fact("Context", "62% used"),
            ]
        ))

        #expect(SessionStory.make(snapshot: session(.working, branch: ""), account: nil)?.facts == [])
        #expect(SessionStory.make(snapshot: session(.working, branch: ""), account: nil)?.more == [])
        let finished = SessionStory.make(snapshot: session(.finished, mode: "plan", contextUsage: ContextUsage(tokens: 10, limit: 100)), account: nil)
        #expect(finished?.facts == [])
        // How full its context is matters only while it works or waits for you.
        #expect(finished?.more == [ItemStory.Fact("Mode", "Plan")])
        let unmeasured = session(.idle, contextUsage: ContextUsage(tokens: 10, limit: 0))
        #expect(SessionStory.make(snapshot: unmeasured, account: nil)?.more == [])
    }

    /// What it recorded comes with it, when it says something. Without the session, as for a task Azure DevOps sent to
    /// Copilot, only that: Azure DevOps says where the task stands, and the two are told together.
    @Test func tellsWhatTheSessionRecorded() throws {
        let account = ItemStory.Account(
            source: "Copilot's notes", date: t(20), milestones: ["Coupon rounding traced to truncation"],
            overview: "Coupon totals truncate instead of rounding."
        )
        let finished = try #require(SessionStory.make(snapshot: session(.finished), account: account))
        #expect(finished.sentence == "Finished")
        #expect(finished.date == t(30))
        #expect(finished.account == account)
        #expect(SessionStory.make(snapshot: session(.finished), account: ItemStory.Account(source: "Copilot's summary"))?.account == nil)

        #expect(SessionStory.make(snapshot: nil, account: nil) == nil)
        #expect(SessionStory.make(snapshot: nil, account: ItemStory.Account(source: "Copilot's summary")) == nil)
        let recorded = try #require(SessionStory.make(snapshot: nil, account: account))
        #expect(recorded == ItemStory(sentence: "", account: account))

        let sent = ItemStory(sentence: "Finished: Coupon totals now round half up.", date: t(40), facts: [ItemStory.Fact("Model", "Standard")])
        for merged in [sent.merged(with: recorded), recorded.merged(with: sent)] {
            #expect(merged.sentence == sent.sentence)
            #expect(merged.facts == sent.facts)
            #expect(merged.account == account)
            #expect(merged.date == t(40))
        }
    }
}
