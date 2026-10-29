import BriefBarCore
import SwiftUI

// Summarize with Copilot on a pull request's or a Copilot session's row in the lists, on demand: ✨ in its time's place
// while you point at it, Summarize with Copilot in its menus, and the summary under it until you close it. Only while
// Summarize with Copilot and Show Links are on; never in a widget, whose rows pass no subject.

private struct OffersSummariesKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether rows offer Summarize with Copilot: not in a desktop widget.
    package var offersSummaries: Bool {
        get { self[OffersSummariesKey.self] }
        set { self[OffersSummariesKey.self] = newValue }
    }
}

/// The summary under a row, as Where It Stands has it, smaller: being written, written, or why it couldn't be.
package struct RowSummary: View {
    private let subject: ItemRef?

    @EnvironmentObject private var services: AppServices
    @Environment(\.offersSummaries) private var offersSummaries

    package init(subject: ItemRef?) {
        self.subject = subject
    }

    package var body: some View {
        if offersSummaries, let subject {
            RowSummaryContent(subject: subject, summaries: services.summaries)
        }
    }
}

private struct RowSummaryContent: View {
    let subject: ItemRef
    @ObservedObject var summaries: StorySummaries

    var body: some View {
        if summaries.isAvailable, summaries.state(for: subject) != nil {
            SummaryCard(subject: subject, summaries: summaries, rows: [], style: .row)
        }
    }
}

/// Summarize with Copilot in a row's menus: to write one, or, once there's one, to write it again or close it.
package struct SummarizeMenuItems: View {
    private let subject: ItemRef?

    @EnvironmentObject private var services: AppServices
    @Environment(\.offersSummaries) private var offersSummaries

    package init(_ subject: ItemRef?) {
        self.subject = subject
    }

    package var body: some View {
        if offersSummaries, let subject {
            SummarizeMenuContent(subject: subject, summaries: services.summaries)
        }
    }
}

private struct SummarizeMenuContent: View {
    let subject: ItemRef
    @ObservedObject var summaries: StorySummaries

    var body: some View {
        if summaries.canSummarize(subject) {
            switch summaries.state(for: subject) {
            case nil:
                Button("Summarize with Copilot") { summaries.summarize(subject) }
            case .writing:
                Button("Stop Summarizing") { summaries.cancel(subject) }
            case .written, .failed:
                Button("Summarize Again") { summaries.summarize(subject) }
                Button("Close Summary") { summaries.dismiss(subject) }
            }
        }
    }
}

/// A row's time, "41m", whose place ✨ takes while you point at a row that has no summary yet (`rowSummarizeButton`).
package struct RowTime: View {
    private let text: String
    private let subject: ItemRef?
    private let isHovered: Bool

    @EnvironmentObject private var services: AppServices

    package init(_ text: String, subject: ItemRef?, isHovered: Bool) {
        self.text = text
        self.subject = subject
        self.isHovered = isHovered
    }

    package var body: some View {
        RowTimeContent(text: text, subject: subject, isHovered: isHovered, summaries: services.summaries)
    }
}

private struct RowTimeContent: View {
    let text: String
    let subject: ItemRef?
    let isHovered: Bool
    @ObservedObject var summaries: StorySummaries

    @Environment(\.interfaceOptions) private var options
    @Environment(\.offersSummaries) private var offersSummaries

    /// ✨ shows instead while you point at it, when it can be summed up and nothing is yet; with actions that show, it's
    /// among them instead.
    private var showsButton: Bool {
        guard isHovered, offersSummaries, !options.visibleActions, let subject else { return false }
        return summaries.state(for: subject) == nil && summaries.canSummarize(subject)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            .opacity(showsButton ? 0 : 1)
            .anchorPreference(key: RowSummarizeSpot.self, value: .bounds) { showsButton ? $0 : nil }
    }
}

/// Where a row keeps ✨: its time's place, while `RowTime` gives it up.
private struct RowSummarizeSpot: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// ✨ Summarize with Copilot where the row's `RowTime` is, while it gives its place up.
    package func rowSummarizeButton(_ subject: ItemRef?) -> some View {
        overlayPreferenceValue(RowSummarizeSpot.self) { spot in
            if let spot, let subject {
                GeometryReader { proxy in
                    RowSummarizeButton(subject: subject)
                        .position(x: proxy[spot].midX, y: proxy[spot].midY)
                }
            }
        }
    }
}

private struct RowSummarizeButton: View {
    let subject: ItemRef

    @EnvironmentObject private var services: AppServices
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        let summaries = services.summaries
        Button {
            summaries.summarize(subject)
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(options.quietAppearance ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(BriefContainer<EmptyView>.gradient))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(SummarizeButton.help(for: subject, model: summaries.name(of: summaries.model)))
        .accessibilityLabel("Summarize with Copilot")
    }
}
