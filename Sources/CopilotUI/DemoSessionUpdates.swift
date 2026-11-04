import BriefBarCore
import Foundation

/// What the Copilot demo's sessions tell BriefBar, as if they had, with Updates from Copilot Sessions, which the demo has
/// on (scripts/make-copilot-demo-data.swift), kept in memory:
/// - "Fix flaky checkout test", at work, is on the sprint's 5105, "Test saving with an empty cart": its capsule shows on the
///   task's line in the Sprint, and the task's details list it.
/// - "Add dark mode to settings", which asks you something, is on !4093, the account page's, which it opened; and "Add dark
///   mode to emails", at work, on !4118, which it opened: By Mission's Map says so at their lanes in "Roll out dark mode",
///   and their nodes have the mark of a session at work on them.
enum DemoSessionUpdates {
    /// The Azure DevOps demo's organization (`DemoData.organization`).
    static let organization = "contoso"
    static let checkout = ItemRef.session("3c7e9d21-8b4a-4f10-a6e2-5d1c0b9a8e04")!
    static let settings = ItemRef.session("0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01")!
    static let emails = ItemRef.session("f2c6b8d4-0e3a-4d71-b9a5-7e1c3d5f9a12")!

    static func reports(now: Date) -> [SessionReport] {
        func report(_ session: ItemRef, _ refs: [ItemRef], minutesAgo: Double) -> SessionReport {
            var report = SessionReport(session: session)
            report.setWorkingOn(refs, at: now.addingTimeInterval(-minutesAgo * 60))
            return report
        }
        return [
            report(checkout, [.workItem(organization: organization, id: 5105)], minutesAgo: 6),
            report(settings, [.pullRequest(organization: organization, number: 4093)], minutesAgo: 8),
            report(emails, [.pullRequest(organization: organization, number: 4118)], minutesAgo: 4),
        ]
    }
}
