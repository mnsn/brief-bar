import BriefBarCore
import Foundation

/// What BriefBar can tell about a work item beyond its row, from the sprint and, once you opened it, from its details:
/// where it stands, who has it, how its tasks and hours stand, and, for a summary of it, its description and its latest
/// comments, in plain text.
public enum WorkItemStory {
    /// - Parameters:
    ///   - details: what was read when you opened it, if it was.
    ///   - tasks: its tasks in the sprint, for a story or a bug.
    public static func make(_ item: WorkItem, details: WorkItemDetails? = nil, tasks: [WorkItem] = []) -> ItemStory {
        // Only its own details count.
        let current = details?.key == item.key ? details : nil
        var facts = [ItemStory.Fact("Assigned to", item.assignedTo?.name ?? "Unassigned")]
        var more = [ItemStory.Fact("Type", item.type)]
        if !tasks.isEmpty {
            facts.append(ItemStory.Fact("Tasks", "\(tasks.filter(\.isDone).count) of \(tasks.count) done"))
        }
        if let remaining = remaining(item, tasks: tasks) {
            facts.append(ItemStory.Fact("Work", "\(hours(remaining)) left"))
        }
        if let iteration = current?.iterationPath?.split(separator: "\\").last {
            more.append(ItemStory.Fact("Iteration", String(iteration)))
        }
        var notes: [ItemStory.Fact] = []
        for text in current?.texts ?? [] {
            let plain = StoryText.paragraph(text.text.plainText, limit: 1_500)
            if !plain.isEmpty { notes.append(ItemStory.Fact(text.title, plain)) }
        }
        let comments = (current?.comments ?? []).prefix(5).compactMap(comment)
        if !comments.isEmpty { notes.append(ItemStory.Fact("Latest comments", comments.joined(separator: "\n"))) }
        let reason = current?.reason.flatMap { $0.caseInsensitiveCompare(item.state) == .orderedSame ? nil : $0 }
        return ItemStory(
            sentence: [item.state, reason].compactMap { $0 }.joined(separator: ": "), date: item.changedAt, facts: facts, more: more,
            notes: notes
        )
    }

    /// Its own hours left, or its tasks' that aren't done.
    static func remaining(_ item: WorkItem, tasks: [WorkItem]) -> Double? {
        if let own = item.remainingWork, own > 0, !item.isDone { return own }
        let left = tasks.filter { !$0.isDone }.compactMap(\.remainingWork).reduce(0, +)
        return left > 0 ? left : nil
    }

    /// "3 h", "2.5 h".
    static func hours(_ value: Double) -> String {
        Int(exactly: value).map { "\($0) h" } ?? String(format: "%.1f h", value)
    }

    /// "Sam Rivera: Can we keep them for 30 days?", the newest first; nil for one that says nothing.
    static func comment(_ comment: WorkItemDetails.Comment) -> String? {
        let text = StoryText.line(comment.text.plainText, limit: 400)
        guard !text.isEmpty else { return nil }
        return "\(comment.author?.name ?? "Someone"): \(text)"
    }
}
