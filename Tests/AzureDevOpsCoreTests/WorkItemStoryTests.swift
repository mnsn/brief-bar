import BriefBarCore
import Foundation
import Testing
@testable import AzureDevOpsCore

/// What's known of a work item beyond its row, for a summary of it: who has it, how its tasks and hours stand, and its
/// description and latest comments as plain text.
@Suite struct WorkItemStoryTests {
    private let robin = Person(id: "a001", name: "Robin Diaz")
    private let sam = Person(id: "b001", name: "Sam Rivera")

    private func item(_ id: Int, _ type: String, _ state: String, who: Person? = nil, hours: Double? = nil, parent: Int? = nil) -> WorkItem {
        WorkItem(
            id: id, organization: "contoso", project: "Storefront", type: type, title: "Item \(id)", state: state,
            category: WorkItem.Category(category: nil, state: state), assignedTo: who, parentId: parent, remainingWork: hours,
            changedAt: Date(timeIntervalSince1970: 1_792_000_000)
        )
    }

    @Test func aStorySaysWhoHasItAndHowItsTasksStand() {
        let story = item(5101, "User Story", "Active", who: robin)
        let tasks = [
            item(5102, "Task", "Closed", who: robin, hours: 4, parent: 5101), item(5103, "Task", "Active", who: robin, hours: 3, parent: 5101),
            item(5104, "Task", "New", hours: 2.5, parent: 5101),
        ]
        let told = WorkItemStory.make(story, tasks: tasks, taskRuns: [5103: "Working: Run the cart tests"])
        #expect(told.sentence == "Active")
        #expect(told.facts == [
            ItemStory.Fact("Assigned to", "Robin Diaz"), ItemStory.Fact("Tasks", "1 of 3 done"),
            // The hours of the tasks that aren't done.
            ItemStory.Fact("Work", "5.5 h left"),
            // Each task, in work order, with the work sent to Copilot for it.
            ItemStory.Fact("Task 5103", "Item 5103: Active · Robin Diaz · 3 h left · Copilot: Working: Run the cart tests"),
            ItemStory.Fact("Task 5104", "Item 5104: New · Unassigned · 2.5 h left"),
            ItemStory.Fact("Task 5102", "Item 5102: Closed · Robin Diaz"),
        ])
        #expect(told.more == [ItemStory.Fact("Type", "User Story")])
        #expect(told.notes.isEmpty)
        #expect(told.date == Date(timeIntervalSince1970: 1_792_000_000))
    }

    @Test func itsOwnDetailsAddItsTextsAndLatestCommentsAsNotes() {
        let task = item(5103, "Task", "Active", hours: 3)
        let details = WorkItemDetails(
            item: task, reason: "Work started", iterationPath: "Storefront\\Sprint 42",
            texts: [WorkItemDetails.LongText(id: "System.Description", title: "Description", text: RichText(html: "<p>Show <b>saved</b> items.</p><ul><li>Newest first</li></ul>"))],
            comments: [
                WorkItemDetails.Comment(id: 2, author: sam, createdAt: nil, text: RichText(markdown: "Use the **48 pt** thumbnails.")),
                WorkItemDetails.Comment(id: 1, author: nil, createdAt: nil, text: RichText(markdown: "Started.")),
            ],
            readAt: Date()
        )
        let told = WorkItemStory.make(task, details: details)
        // Why it's in its state is a note, as its details are: its sentence is the same without them.
        #expect(told.sentence == "Active")
        #expect(told.notes.first == ItemStory.Fact("Why it's Active", "Work started"))
        #expect(told.facts.contains(ItemStory.Fact("Assigned to", "Unassigned")))
        #expect(told.facts.contains(ItemStory.Fact("Work", "3 h left")))
        #expect(told.more.contains(ItemStory.Fact("Iteration", "Sprint 42")))
        #expect(told.notes[1].label == "Description")
        #expect(told.notes[1].value.contains("Show saved items.") == true)
        #expect(told.notes[1].value.contains("Newest first") == true)
        #expect(told.notes.last == ItemStory.Fact("Latest comments", "Sam Rivera: Use the 48 pt thumbnails.\nSomeone: Started."))
        // Another work item's details don't count.
        let other = WorkItemStory.make(item(5104, "Task", "New"), details: details)
        #expect(other.notes.isEmpty)
        #expect(other.sentence == "New")
    }
}
