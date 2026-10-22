import AppKit
import BriefBarCore
import SwiftUI

/// How every source's things look by state: as Azure DevOps' and Copilot's own groups draw them, so a merged item
/// reads the same as the items you know.
extension ItemState {
    /// A group's heading.
    package var title: String {
        switch self {
        case .needsYou: return "Needs You"
        case .failing: return "Something's Wrong"
        case .running: return "Running"
        case .done: return "Done or Ready"
        }
    }

    /// Starts a line of an item's tooltip: "Needs you: 2 chats, 3 pull requests".
    package var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .failing: return "Something's wrong"
        case .running: return "Running"
        case .done: return "Done or ready"
        }
    }

    /// After a count, as in "11 need you · 4 went wrong · 2 running · 3 done or ready".
    package var countLabel: String {
        switch self {
        case .needsYou: return "need you"
        case .failing: return "went wrong"
        case .running: return "running"
        case .done: return "done or ready"
        }
    }

    /// What it counts, for Settings.
    package var explanation: String {
        switch self {
        case .needsYou: return "Unread chats, pull requests that need you, and Copilot's questions, plans and permission prompts"
        case .failing: return "Failing pull requests, failed pipelines, and Copilot sessions that stopped"
        case .running: return "Copilot sessions at work, and pipelines that are running"
        case .done: return "Pull requests ready to complete, and finished Copilot sessions"
        }
    }

    package var symbol: String {
        switch self {
        case .needsYou: return "hand.raised.fill"
        case .failing: return "xmark.circle.fill"
        case .running: return "bolt.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    package var nsColor: NSColor {
        switch self {
        case .needsYou: return .systemOrange
        case .failing: return .systemRed
        case .running: return .systemBlue
        case .done: return .systemGreen
        }
    }

    package var color: Color { Color(nsColor: nsColor) }
}

/// BriefBar's own symbols.
package enum AppSymbols {
    /// BriefBar's own symbol, in the menu bar and in Settings.
    package static let app = "rectangle.stack"
}
