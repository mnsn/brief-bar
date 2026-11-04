import AzureDevOpsCore
import CopilotTasks
import Foundation

extension SentPrompt {
    /// The Copilot demo's session on !4102's branch, ‘Retry backoff’ (scripts/make-copilot-demo-data.swift).
    static let demoSession = "2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a14"

    /// The demo's prompts to the Copilot app's sessions about pull requests, as they stand: Priya's suggested change
    /// on !4102, applied as it's written in ‘Retry backoff’, done and not pushed. Made up, as the demo's tasks are: nothing's
    /// sent, and no log is read.
    static func demo(now: Date) -> [(prompt: SentPrompt, turn: SessionTurn?)] {
        let about = About(pullRequest: PRKey(DemoData.organization, 4102), purpose: .fix, parts: [.thread(18)])
        guard let prompt = SentPrompt(about, session: demoSession, sentAt: now.addingTimeInterval(-46 * 60), copied: false, ended: .finished)
        else { return [] }
        let turn = SessionTurn(
            phase: .finished(summary: "Added MaxDelay to RetryOptions as Priya suggested, 30 seconds by default, and capped the backoff with it. The tests pass."),
            since: now.addingTimeInterval(-39 * 60)
        )
        return [(prompt, turn)]
    }
}
