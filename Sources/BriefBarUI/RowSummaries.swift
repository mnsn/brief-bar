import AppKit
import BriefBarCore
import SwiftUI

// On-demand summaries on pull requests' and sessions' rows in the lists: ✨ in its time's place while you point at it,
// Summarize in its menus, and the summary in a few lines under it, as a chat's summary shows, until you hide it. Only
// while summaries and Show Links are on; never in a widget.

private struct OffersSummariesKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether rows offer Summarize: not in a desktop widget.
    package var offersSummaries: Bool {
        get { self[OffersSummariesKey.self] }
        set { self[OffersSummariesKey.self] = newValue }
    }
}

/// The summary under a row, in the row's own sizes: ✨ and its headline, then what's next and for whom, then the first
/// three lines of the rest, all of it on request; while it's written, that it is, with Stop; when it couldn't be, why, with Try
/// Again.
package struct RowSummary: View {
    private let subject: ItemRef?

    @EnvironmentObject private var services: AppServices
    @Environment(\.offersSummaries) private var offersSummaries

    package init(subject: ItemRef?) {
        self.subject = subject
    }

    package var body: some View {
        if offersSummaries, let subject {
            RowSummaryContent(subject: subject, summaries: services.summaries, links: services.links, stories: services.stories)
        }
    }
}

private struct RowSummaryContent: View {
    let subject: ItemRef
    @ObservedObject var summaries: StorySummaries
    let links: Links
    let stories: ItemStories

    @Environment(\.interfaceOptions) private var options
    @Environment(\.textScale) private var textScale
    @LocalState private var showsMore = false
    @LocalState private var isHovered = false
    /// How tall its paragraph is as it shows, and all of it.
    @LocalState private var paragraphHeight: (shown: CGFloat, full: CGFloat) = (0, 0)

    /// Under the sparkles, where the headline starts: their column, as big as the text, then 5 points.
    private var indent: CGFloat { 12 * textScale + 5 }
    /// How many lines of what's been done and what's left show at first.
    static let paragraphLines = 3

    var body: some View {
        if summaries.isAvailable, let state = summaries.shownState(for: subject) {
            line(state)
                .padding(.top, 3)
                // While it shows, what it summed up as it is now, as Where It Stands reads it, to tell when it's out of
                // date: such as a vote that doesn't change the row.
                .onAppear(perform: refresh)
                .background {
                    TimelineView(.periodic(from: .distantPast, by: ItemStories.freshFor)) { context in
                        Color.clear.onChange(of: context.date) { refresh() }
                    }
                }
        }
    }

    private func refresh() {
        stories.request(links.describe(subject))
        for connection in links.connections(of: subject) { stories.request(connection.item) }
    }

    @ViewBuilder
    private func line(_ state: StorySummaries.State) -> some View {
        switch state {
        case .writing:
            // Written again, the one it replaces shows meanwhile, dimmed, with Stop.
            if case .written(let summary, let at, let inputs, let model)? = summaries.previous(for: subject) {
                written(summary, at: at, inputs: inputs, model: model, isUpdating: true)
            } else {
                writingLine
            }
        case .written(let summary, let at, let inputs, let model):
            written(summary, at: at, inputs: inputs, model: model)
        case .failed(let problem, _):
            // Written again and couldn't be: the one before stays, with why at its foot.
            if case .written(let summary, let at, let inputs, let model)? = summaries.previous(for: subject) {
                written(summary, at: at, inputs: inputs, model: model, failure: problem)
            } else {
                failedLine(problem)
            }
        }
    }

    private var writingLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            SummaryCard.writingText(summaries)
            Button("Stop") { summaries.cancel(subject) }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
        }
        .font(size: options.rowDetailSize)
    }

    private func failedLine(_ problem: StorySummaries.Problem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Couldn't summarize: \(problem.message)")
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(problem.detail ?? "")
            Button("Try Again") { summaries.summarize(subject) }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .fixedSize()
                .help(SummarizeButton.help(for: subject, model: summaries.name(of: summaries.model), onDevice: summaries.usesOnDeviceModel))
            Spacer(minLength: 4)
            Button("Close") { summaries.dismiss(subject) }
                .buttonStyle(.borderless)
                .fixedSize()
        }
        .font(size: options.rowDetailSize)
    }

    /// A written one; while another is written in its place, dimmed, with Stop; or, when that one couldn't be written, as
    /// it was, with why at its foot.
    private func written(
        _ summary: StorySummary, at: Date, inputs: [StorySummaries.Input], model: String, isUpdating: Bool = false,
        failure: StorySummaries.Problem? = nil
    ) -> some View {
        let changed = isUpdating || failure != nil ? nil : summaries.whatChanged(subject)
        // Lighter while another's written in its place, or once it's out of date; not just for one that couldn't be.
        let isDimmed = isUpdating || changed != nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "sparkles")
                    .font(size: options.rowReasonSize - 1, weight: .semibold)
                    .foregroundStyle(options.quietAppearance ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(BriefContainer<EmptyView>.gradient))
                    .frame(width: indent - 5, alignment: .leading)
                    .accessibilityHidden(true)
                Text(summary.headline)
                    .font(size: options.rowReasonSize, weight: .medium)
                    .foregroundStyle(isDimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary.opacity(0.85)))
                    // Never cut short, nor what's next: a sentence each, and what the rest is cut to make room for.
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                // Room for ✕; its time is in its tooltip, so that it isn't read as the row's.
                Spacer(minLength: 24)
            }
            // While another is written in its place, that it is, with Stop, over the end of its first line; or, while you
            // point at it, ✕; neither makes it any taller.
            .overlay(alignment: .topTrailing) {
                if isUpdating {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Button("Stop") { summaries.cancel(subject) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tint)
                            .font(size: 11)
                            .help("Stop, and keep the summary from \(at.formatted(date: .omitted, time: .shortened))")
                    }
                    .help(SummaryCard.writing(summaries))
                } else if isHovered {
                    Button {
                        summaries.hide(subject)
                    } label: {
                        Image(systemName: "xmark")
                            .font(size: 9.5, weight: .semibold)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Hide the summary: Show Summary, in its menu, shows it again")
                    .offset(y: -3)
                }
            }
            // Show More at the end of the rest, while there's more of it: its points, three lines of them at first; Show
            // Less once they're all there.
            let hasMore = showsMore || paragraphHeight.full > paragraphHeight.shown + 1
            let more = summary.paragraph == nil || !hasMore ? nil : Button(showsMore ? "Show Less" : "Show More") {
                withAnimation(.easeOut(duration: 0.15)) { showsMore.toggle() }
            }
            .buttonStyle(.borderless)
            .font(size: 11)
            // In the tint, as an inline link is, so it isn't read as the end of the sentence.
            .foregroundStyle(.tint)
            .fixedSize()
            if let next = summary.next {
                Text("\(Text(summary.nextLabel).fontWeight(.semibold)) \(next)")
                    .font(size: options.rowDetailSize)
                    .foregroundStyle(isDimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary.opacity(0.85)))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, indent)
            }
            if let paragraph = summary.paragraph {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    // Quieter than what's next, and than the row: it's what explains the rest.
                    Text(SummaryMarkdown.joined(paragraph))
                        .font(size: options.rowDetailSize)
                        .foregroundStyle(.secondary)
                        .lineLimit(showsMore ? nil : Self.paragraphLines)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paragraphHeight.shown = $0 }
                        // All of it, unseen, to tell whether three lines cut it short.
                        .background(alignment: .topLeading) {
                            Text(SummaryMarkdown.joined(paragraph))
                                .font(size: options.rowDetailSize)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paragraphHeight.full = $0 }
                        }
                    if let more { more }
                }
                .padding(.leading, indent)
                .padding(.top, 2)
            }
            if let failure {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Couldn't update: \(failure.message)")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(failure.detail ?? "")
                    Button("Try Again") { summaries.summarize(subject) }
                        .foregroundStyle(.tint)
                        .fixedSize()
                        .help(SummarizeButton.help(for: subject, model: summaries.name(of: summaries.model), onDevice: summaries.usesOnDeviceModel))
                }
                .buttonStyle(.borderless)
                .font(size: 11)
                .padding(.leading, indent)
            } else if let changed {
                HStack(spacing: 12) {
                    Text("\(Text("Out of date").fontWeight(.semibold)): \(changed)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Since it was written: \(changed).")
                    Button("Summarize Again") { summaries.summarize(subject) }
                        .foregroundStyle(.tint)
                        .help(SummarizeButton.help(for: subject, model: summaries.name(of: summaries.model), onDevice: summaries.usesOnDeviceModel))
                }
                .buttonStyle(.borderless)
                .font(size: 11)
                .padding(.leading, indent)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help("Written by \(summaries.attribution(for: model)) at \(at.formatted(date: .omitted, time: .shortened)), "
              + "from \(StorySummaries.source(of: inputs)).")
        // While another is written, Stop is what's done to it, as on its card.
        .contextMenu {
            if !isUpdating {
                Button("Summarize Again") { summaries.summarize(subject) }
            }
            Button("Copy Summary") {
                ThisMac.copy(summary.plainText)
            }
            if !isUpdating {
                Button("Hide Summary") { summaries.hide(subject) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SummaryCard.title(for: model))
        .accessibilityActions {
            if !isUpdating {
                Button("Hide Summary") { summaries.hide(subject) }
            }
        }
    }
}

/// Summarize in a row's menus, in a group of its own: to write one; once there's one, to hide it or show
/// it again for nothing, or to write it again; while it's written, to stop.
package struct SummarizeMenuItems: View {
    private let subject: ItemRef?
    private let divided: Bool

    @EnvironmentObject private var services: AppServices
    @Environment(\.offersSummaries) private var offersSummaries

    /// - Parameter divided: whether a line sets them apart, in a menu; not among accessibility actions.
    package init(_ subject: ItemRef?, divided: Bool = true) {
        self.subject = subject
        self.divided = divided
    }

    package var body: some View {
        if offersSummaries, let subject {
            SummarizeMenuContent(subject: subject, divided: divided, summaries: services.summaries)
        }
    }
}

private struct SummarizeMenuContent: View {
    let subject: ItemRef
    let divided: Bool
    @ObservedObject var summaries: StorySummaries

    var body: some View {
        if summaries.canSummarize(subject) {
            if divided { Divider() }
            switch summaries.state(for: subject) {
            case nil:
                Button(summaries.actionTitle) { summaries.summarize(subject) }
            case .writing:
                Button("Stop Summarizing") { summaries.cancel(subject) }
            case .written:
                if summaries.isHidden(subject) {
                    Button("Show Summary") { summaries.show(subject) }
                } else {
                    Button("Hide Summary") { summaries.hide(subject) }
                }
                Button("Summarize Again") { summaries.summarize(subject) }
            case .failed:
                Button("Try Again") { summaries.summarize(subject) }
                // One that couldn't be written again closes as the one before it, kept to show again.
                if summaries.previous(for: subject) != nil {
                    Button("Hide Summary") { summaries.hide(subject) }
                } else {
                    Button("Close Summary") { summaries.dismiss(subject) }
                }
            }
            if divided { Divider() }
        }
    }
}

/// A row's time, "41m", whose place ✨ takes while you point at a row that has no summary yet, and a spinner while one is
/// written, which takes a second click there rather than the row (`rowSummarizeButton`).
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

    /// ✨ shows instead while you point at it, when it can be summed up and nothing is yet, unless the row's actions show;
    /// and a spinner while one is written.
    private var givesUpItsPlace: Bool {
        guard offersSummaries, let subject, summaries.canSummarize(subject) else { return false }
        switch summaries.state(for: subject) {
        case .writing?: return true
        case nil: return isHovered && !options.visibleActions
        default: return false
        }
    }

    var body: some View {
        Text(text)
            .font(size: 11).monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .opacity(givesUpItsPlace ? 0 : 1)
            .anchorPreference(key: RowSummarizeSpot.self, value: .bounds) { givesUpItsPlace ? $0 : nil }
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
    /// ✨ Summarize, or a spinner while it's written, where the row's `RowTime` is, while it gives its
    /// place up.
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

    var body: some View {
        RowSummarizeButtonContent(subject: subject, summaries: services.summaries)
    }
}

private struct RowSummarizeButtonContent: View {
    let subject: ItemRef
    @ObservedObject var summaries: StorySummaries

    @Environment(\.interfaceOptions) private var options

    var body: some View {
        if case .writing? = summaries.state(for: subject) {
            // A second click lands here, not on the row.
            ProgressView()
                .controlSize(.mini)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .onTapGesture {}
                .help(SummaryCard.writing(summaries))
                .accessibilityHidden(true)
        } else {
            Button {
                summaries.summarize(subject)
            } label: {
                Image(systemName: "sparkles")
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(options.quietAppearance ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(BriefContainer<EmptyView>.gradient))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(SummarizeButton.help(for: subject, model: summaries.name(of: summaries.model), onDevice: summaries.usesOnDeviceModel))
            .accessibilityLabel(summaries.actionTitle)
        }
    }
}
