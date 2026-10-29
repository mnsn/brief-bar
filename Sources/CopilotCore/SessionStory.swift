import BriefBarCore
import Foundation

/// A Copilot session's story, for the things it's linked to: where it stands, in BriefBar's words, a few facts, and
/// what it recorded of its work (`SessionAccount`).
public enum SessionStory {
    /// From the session, as the list shows it, and what it recorded. Without the session, as for a task Azure DevOps
    /// sent to Copilot, which says where that stands itself: what Copilot recorded only, without a sentence. Nil when
    /// there's neither.
    public static func make(snapshot: SessionSnapshot?, account: ItemStory.Account?) -> ItemStory? {
        let account = account.flatMap { $0.isEmpty ? nil : $0 }
        guard let snapshot else { return account.map { ItemStory(sentence: "", account: $0) } }
        return ItemStory(
            sentence: snapshot.storySentence, date: snapshot.since, facts: facts(of: snapshot), more: more(of: snapshot),
            account: account, waits: waits(of: snapshot)
        )
    }

    /// You, while it waits for you; Copilot, while it works.
    static func waits(of snapshot: SessionSnapshot) -> [ItemStory.Wait] {
        switch snapshot.phase {
        case .needsYou:
            let what = switch snapshot.reason {
            case .planApproval: "to review the plan"
            case .permission: "to answer a permission request"
            default: "to answer"
            }
            return [ItemStory.Wait(.you, "you, \(what) in session “\(snapshot.displayName)”", about: ItemRef.session(snapshot.id))]
        case .running:
            return [ItemStory.Wait(.copilot, "Copilot, in session “\(snapshot.displayName)”", about: ItemRef.session(snapshot.id))]
        case .done, .stopped, .idle: return []
        }
    }

    /// What it asks you to choose from, when it asks.
    static func facts(of snapshot: SessionSnapshot) -> [ItemStory.Fact] {
        let choices = StoryText.line(snapshot.choices.joined(separator: " · "), limit: 240)
        return choices.isEmpty ? [] : [ItemStory.Fact("Choices", choices)]
    }

    /// Where it works, its mode, and, while it's at work or waits for you, how much of its context it uses: those that are
    /// known.
    static func more(of snapshot: SessionSnapshot) -> [ItemStory.Fact] {
        var facts: [ItemStory.Fact] = []
        func add(_ label: String, _ value: String?) {
            let value = StoryText.line(value ?? "", limit: 240)
            if !value.isEmpty { facts.append(ItemStory.Fact(label, value)) }
        }
        add("Where", [snapshot.projectName, snapshot.branch].compactMap { $0 }.joined(separator: " · "))
        add("Mode", snapshot.mode?.capitalized)
        if let usage = snapshot.contextUsage, usage.limit > 0, isGoingOn(snapshot.reason) {
            add("Context", "\(usage.percent)% used")
        }
        return facts
    }

    /// Whether it's at work, or waits for you: not once it ended.
    static func isGoingOn(_ reason: StatusReason) -> Bool {
        switch reason {
        case .question, .planApproval, .permission, .working, .starting: return true
        case .finished, .interrupted, .failed, .unresponsive, .idle: return false
        }
    }
}

extension SessionSnapshot {
    /// Where it stands, in BriefBar's words, without its name, which its row shows: "Asks: Should dark mode follow the
    /// system appearance?", "Working: Run the cart tests", "Finished". Its detail on one line, cut short if it's long.
    public var storySentence: String {
        let detail = self.detail.map { StoryText.line($0, limit: 160) }.flatMap { $0.isEmpty ? nil : $0 }
        switch reason {
        case .question: return detail.map { "Asks: \($0)" } ?? "Waiting for your answer"
        case .planApproval: return "Has a plan for you to review" + (detail.map { ": \($0)" } ?? "")
        case .permission: return "Needs your permission" + (detail.map { " to run \($0)" } ?? "")
        case .working, .starting: return "Working" + (detail.map { ": \($0)" } ?? "")
        case .finished: return "Finished"
        case .interrupted: return "Interrupted"
        case .failed: return "Stopped with an error" + (detail.map { ": \($0)" } ?? "")
        case .unresponsive: return "Stopped responding"
        case .idle: return "Idle"
        }
    }
}
