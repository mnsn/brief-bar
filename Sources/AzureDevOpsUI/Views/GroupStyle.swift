import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import AppKit
import SwiftUI

extension PRGroup {
    var title: String {
        switch self {
        case .needsYou: return "Needs You"
        case .answered: return "Answered"
        case .failing: return "Failing"
        case .ready: return "Ready to Complete"
        case .toReview: return "To Review"
        case .waiting: return "Waiting"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    /// For counts: "2 failing", "1 ready to complete".
    var countLabel: String {
        switch self {
        case .needsYou: return "need you"
        case .toReview: return "to review"
        default: return title.lowercased()
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .needsYou: return .systemOrange
        case .answered: return .systemGreen
        case .failing: return .systemRed
        case .ready: return .systemGreen
        case .toReview: return .systemTeal
        case .waiting: return .systemBlue
        case .done: return .systemPurple
        case .idle: return .secondaryLabelColor
        }
    }

    /// Symbol for count chips in the menu bar, the panel header and the widget.
    var symbol: String {
        switch self {
        case .needsYou: return "hand.raised.fill"
        case .answered: return "checkmark.bubble.fill"
        case .failing: return "xmark.circle.fill"
        case .ready: return "checkmark.circle.fill"
        case .toReview: return "eye.circle.fill"
        case .waiting: return "clock.fill"
        case .done: return "arrow.triangle.merge"
        case .idle: return "moon.zzz.fill"
        }
    }
}

extension PRReason {
    var symbol: String {
        switch self {
        case .mentioned: return "at.circle.fill"
        case .sentInChat: return "paperplane.circle.fill"
        case .replied: return "arrowshape.turn.up.left.circle.fill"
        case .commented: return "text.bubble.fill"
        case .reviewRequested, .reviewPending: return "eye.circle.fill"
        case .newCommits: return "arrow.triangle.2.circlepath.circle.fill"
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .rejected: return "hand.thumbsdown.circle.fill"
        case .answered: return "checkmark.bubble.fill"
        case .buildFailed: return "xmark.circle.fill"
        case .checkFailed: return "xmark.octagon.fill"
        case .conflicts: return "arrow.triangle.branch"
        case .mergeFailed: return "exclamationmark.circle.fill"
        case .buildExpired: return "clock.badge.exclamationmark.fill"
        case .failedAfterMerge: return "arrow.triangle.merge"
        case .readyToComplete: return "checkmark.circle.fill"
        case .autoComplete: return "checkmark.seal.fill"
        case .waitingForReviewers: return "person.2.circle.fill"
        case .checksRunning: return "hourglass.circle.fill"
        case .requirementsPending: return "checklist"
        case .waitingForAuthor: return "clock.circle.fill"
        case .completed: return "arrow.triangle.merge"
        case .waitingForApproval: return "hand.raised.circle.fill"
        case .abandoned: return "xmark.bin.fill"
        case .draft: return "pencil.circle.fill"
        case .inactive: return "moon.zzz.fill"
        case .youApproved: return "checkmark.circle"
        case .declined: return "person.crop.circle.badge.xmark"
        }
    }

    /// Glyphs without a filled, circled version: rows draw them on a filled circle, like the others.
    var needsBadge: Bool {
        switch self {
        case .conflicts, .requirementsPending, .completed, .failedAfterMerge: return true
        default: return false
        }
    }
}

extension PRSnapshot {
    /// Symbol and tint for a row; idle rows are greyed out.
    var rowSymbol: String { reason.symbol }
    var rowColor: Color { group == .idle ? .secondary : group.color }

    var subtitle: String {
        [headline, repository].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension PROrder {
    /// In the menu that sorts the list.
    var title: String {
        switch self {
        case .status: return "By Status"
        case .newestFirst: return "Newest First"
        case .oldestFirst: return "Oldest First"
        }
    }
}

extension PRReadiness.Item {
    /// As a pipeline's run shows where it stands: ✓ done, ✕ failing, ✋ waiting on you, ↻ running, and a clock while it
    /// waits on someone else; open comments that don't hold the pull request up, a speech bubble.
    var symbol: String {
        guard isRequired else { return "text.bubble" }
        switch state {
        case .done?: return "checkmark.circle.fill"
        case .failing?: return "xmark.circle.fill"
        case .needsYou?: return "hand.raised.fill"
        case .running?: return "arrow.triangle.2.circlepath"
        case nil: return "clock"
        }
    }

    var color: Color { isRequired ? state?.color ?? .secondary : .secondary }

    /// "Build failed (shop-web CI · Run unit tests: 2 tests failed)", for a tooltip or VoiceOver.
    var described: String {
        guard let detail, !detail.isEmpty else { return label }
        return "\(label) (\(detail))"
    }
}

extension PRReadiness {
    /// What's left and what's done, a line each, for a row's tooltip: "Left to complete it: 1 of 2 approvals (Approved by
    /// Priya Shah); Resolve 1 comment", "Done: Build passed (payments-api CI)".
    var lines: [String] {
        let blocking = items.filter { $0.isRequired && !$0.isDone }
        let optional = items.filter { !$0.isRequired && !$0.isDone }
        let done = items.filter(\.isDone)
        var lines = [blocking.isEmpty
            ? "Nothing left to complete it" + (isCurrent ? "" : ", as last read")
            : "Left to complete it: " + blocking.map(\.described).joined(separator: "; ")]
        if !optional.isEmpty { lines.append("Not required: " + optional.map(\.described).joined(separator: "; ")) }
        if !done.isEmpty { lines.append("Done: " + done.map(\.described).joined(separator: "; ")) }
        if !isCurrent { lines.append("It changed since its policies were read: they're read again at the next refresh") }
        return lines
    }
}
