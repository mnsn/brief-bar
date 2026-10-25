import AppKit
import GitHubCore
import SwiftUI

extension GitHubPRGroup {
    var title: String {
        switch self {
        case .toReview: return "To Review"
        case .changesRequested: return "Changes Requested"
        case .failing: return "Failing"
        case .ready: return "Ready to Merge"
        case .waiting: return "Waiting"
        }
    }

    /// For sentences such as "2 to review".
    var countLabel: String {
        switch self {
        case .toReview: return "to review"
        case .changesRequested: return "with changes requested"
        case .failing: return "failing"
        case .ready: return "ready"
        case .waiting: return "waiting"
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .toReview: return .systemOrange
        case .changesRequested: return .systemOrange
        case .failing: return .systemRed
        case .ready: return .systemGreen
        case .waiting: return .systemBlue
        }
    }

    /// For count chips in the menu bar and the panel's header.
    var symbol: String {
        switch self {
        case .toReview: return "eye.circle.fill"
        case .changesRequested: return "hand.raised.fill"
        case .failing: return "xmark.circle.fill"
        case .ready: return "checkmark.circle.fill"
        case .waiting: return "clock.fill"
        }
    }
}

extension GitHubPRReason {
    var symbol: String {
        switch self {
        case .reviewRequested: return "eye.circle.fill"
        case .changesRequested: return "arrow.uturn.backward.circle.fill"
        case .checksFailed: return "xmark.circle.fill"
        case .conflicts: return "exclamationmark.triangle.fill"
        case .approved: return "checkmark.circle.fill"
        case .checksRunning: return "hourglass.circle.fill"
        case .draft: return "pencil.circle.fill"
        case .waitingForReview: return "clock.fill"
        }
    }
}
