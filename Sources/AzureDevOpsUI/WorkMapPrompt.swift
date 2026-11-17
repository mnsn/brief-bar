import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation

/// ✨ Ask Copilot's prompt on My Work's Map: what's on a band or a graph, by links, with what waits for what there now, and what
/// to do: work out the rest, the steps with no pull request or work item yet too, and tell BriefBar with its tools.
enum WorkMapPrompt {
    /// What the page knows of a card: "!4113", "Task 5103"; its title; its link.
    struct Described {
        var label: String
        var title: String?
        var link: URL?
    }

    static func prompt(_ question: WorkMapQuestion, describe: (ItemRef) -> Described?) -> String {
        // A step by its ID, as tell_dependencies takes it, with its name.
        func step(_ id: UUID) -> String {
            let name = question.steps.first { $0.id == id }?.name
            return "step:" + id.uuidString.lowercased() + (name.map { " (“\($0)”)" } ?? "")
        }
        func name(_ node: MapNodeID) -> String {
            switch node {
            case .card(let ref): describe(ref)?.label ?? ref.shortOrderLabel
            case .step(let id): step(id)
            }
        }
        let items = question.items.map { item in
            switch item {
            case .card(let card):
                let described = describe(card.ref)
                let words = [described?.label ?? card.ref.shortOrderLabel, described?.title].compactMap { $0 }.joined(separator: " ")
                let link = described?.link.map { " — \($0.absoluteString)" } ?? ""
                return "- \(words)\(link)\(item.isDone ? " (done)" : "")"
            case .step(let found):
                return "- \(step(found.id)) — a step, \(found.isDone ? "done" : "to do")"
            }
        }
        let waits = question.items.compactMap { item -> String? in
            let earlier = question.waits[item.id] ?? []
            guard !earlier.isEmpty else { return nil }
            return "- \(name(item.id)) waits for \(list(earlier.map(name)))"
        }
        let known = waits.isEmpty
            ? "BriefBar knows of nothing here that waits for anything yet."
            : "What BriefBar has them wait for now:\n" + waits.joined(separator: "\n")
        return """
            Work out what waits for what in “\(question.title)”, for the Map on My Work in BriefBar, and tell BriefBar.

            What's there now: pull requests, work items, and steps, work with no pull request or work item yet:
            \(items.joined(separator: "\n"))

            \(known)

            Read the pull requests, the work items and the code where you need to, then work out:
            - which of them must wait for which, beyond what's above, and what above is wrong;
            - what's left to do that has no pull request or work item yet, as steps: such as API tests, end-to-end tests, \
            testing in dev, monitoring and alerts, enabling it in staging and in production, and announcing it.

            Then tell BriefBar with its tell_dependencies tool: dependencies to add, remove for what's wrong, and steps, naming \
            each pull request and work item by its link, each step above by its step: and ID, and each new step as step: and \
            its name, which adds it, even where another mission has a step of that name, and which the rest of the same call \
            can name so. Read work_map first for the steps and lines BriefBar keeps. Say only what holds each: BriefBar draws \
            a line only from the nearest of what holds it. If you don't have BriefBar's tools, answer with the list instead, a line each, as “X waits for Y”, for me to \
            add. Change nothing in Azure DevOps or in the code for this.
            """
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
