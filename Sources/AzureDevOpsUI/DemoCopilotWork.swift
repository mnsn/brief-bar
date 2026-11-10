import AzureDevOpsCore
import BriefBarUI
import CopilotTasks
import Foundation

extension SentPrompt {
    /// The Copilot demo's session on !4102's branch, ‘Retry backoff’ (scripts/make-copilot-demo-data.swift).
    static let demoSession = "2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a14"
    /// Its name, as the demo's Copilot app shows it.
    static let demoSessionName = "Retry backoff"
    /// The made-up request whose made-up report said how the demo's prompt ended.
    static let demoReport = "7d1c5e0a-4b2f-4c3d-9e8f-0a1b2c3d4e5f"

    /// The demo's prompts to the Copilot app's sessions about pull requests, as they stand: Priya's suggested change
    /// on !4102, applied as it's written in ‘Retry backoff’, done and not pushed. Made up, as the demo's tasks are: nothing's
    /// sent, and no report or log is read.
    static func demo(now: Date) -> [(prompt: SentPrompt, turn: SessionTurn?)] {
        let about = About(pullRequest: PRKey(DemoData.organization, 4102), purpose: .fix, parts: [.thread(18)])
        guard let prompt = SentPrompt(
            about, session: demoSession, sentAt: now.addingTimeInterval(-46 * 60), copied: false, ended: .finished, report: demoReport
        ) else { return [] }
        let turn = SessionTurn(
            phase: .finished(summary: "Added MaxDelay to RetryOptions as Priya suggested, 30 seconds by default, and capped the backoff with it. The tests pass."),
            since: now.addingTimeInterval(-39 * 60)
        )
        return [(prompt, turn)]
    }
}

extension CopilotTasksStore {
    /// The demo's made-up notifications of how its made-up prompts' turns ended (`SentPrompt.demo`), for the Notifications
    /// page, each as of when it ended, as their extensions would have reported them. None outside the demo, or while Send
    /// Work to Copilot is off, which shows none of them.
    func demoNotifications(now: Date = Date()) -> [(notification: BriefBarNotification, date: Date)] {
        guard mode == .demo, isOn else { return [] }
        return SentPrompt.demo(now: now).compactMap { prompt, turn in
            guard let requestId = prompt.report, let turn, turn.isOver, let since = turn.since else { return nil }
            let summary: String? = if case .finished(let summary) = turn.phase { summary } else { nil }
            let report = OutboxReport(
                requestId: requestId, sessionId: prompt.session, pid: 1, startedAt: prompt.sentAt, name: SentPrompt.demoSessionName,
                state: .finished, since: since, said: summary
            )
            let notification = Self.promptNotification(prompt, requestId: requestId, report: report, pullRequest: knownPullRequest(prompt.pullRequest))
            return (notification, since)
        }
    }
}
