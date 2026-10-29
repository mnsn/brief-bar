import AppKit
import BriefBarCore
import SwiftUI

/// ✨ Summarize, with Apple Intelligence or Copilot, as you chose, in Where It Stands' header, while summaries and Show
/// Links are on, there's something to sum up and no summary shows or is about to be written as it opened: asks for a few
/// lines on where the thing and what's linked to it stand.
struct SummarizeButton: View {
    let subject: ItemRef
    @ObservedObject var summaries: StorySummaries

    var body: some View {
        if summaries.isHidden(subject) {
            Button {
                summaries.show(subject)
            } label: {
                Label("Show Summary", systemImage: "sparkles")
                    .font(.system(size: 11.5))
                    .fixedSize()
            }
            .buttonStyle(.borderless)
            .help("Shows the summary you closed, as it was written")
        } else if summaries.state(for: subject) == nil, !summaries.isPending(subject), summaries.hasSomethingToSum(subject) {
            ViewThatFits(in: .horizontal) {
                button(summaries.actionTitle)
                button("Summarize")
            }
        }
    }

    private func button(_ title: String) -> some View {
        Button {
            summaries.summarize(subject)
        } label: {
            Label(title, systemImage: "sparkles")
                .font(.system(size: 11.5))
                .fixedSize()
        }
        .buttonStyle(.borderless)
        .help(Self.help(for: subject, model: summaries.name(of: summaries.model), onDevice: summaries.usesOnDeviceModel))
        .accessibilityLabel(summaries.actionTitle)
    }

    /// "Sends this work item and what's linked to it to GitHub Copilot (Claude Haiku 5.5): 1 request on your Copilot plan."
    static func help(for subject: ItemRef, model: String, onDevice: Bool = false) -> String {
        let what = switch subject.kind {
        case .workItem: "work item"
        case .pullRequest, .gitHubPullRequest: "pull request"
        case .session: "Copilot session"
        }
        if onDevice {
            return "Summarizes this \(what) and what's linked to it with Apple Intelligence on this Mac. Nothing is sent to Copilot; no Copilot requests."
        }
        return "Sends this \(what) and what's linked to it to GitHub Copilot (\(model)): 1 request on your Copilot plan."
    }
}

/// What the selected model summed up, at the top of Where It Stands and under a page's heading: where it stands in a
/// line, what's next and for whom, and what's been done and what's left, all of it, in the colors of what a model wrote;
/// while it's written again, the one before, dimmed, with a way to stop; when it couldn't be, why, and what would help.
/// One whose rows changed since says it's out of date, and what changed.
package struct SummaryCard: View {
    /// Where it shows: at the top of Where It Stands, or under a pull request's or a session's row in a list, where it's
    /// smaller and quieter.
    package enum Style {
        case section, row
    }

    let subject: ItemRef
    @ObservedObject var summaries: StorySummaries
    /// Re-checks whether it's out of date as the rows change.
    let rows: [String]
    var style: Style = .section

    @EnvironmentObject private var services: AppServices
    @Environment(\.interfaceOptions) private var options
    @LocalState private var choosesModel = false

    package init(subject: ItemRef, summaries: StorySummaries, rows: [String], style: Style = .section) {
        self.subject = subject
        self.summaries = summaries
        self.rows = rows
        self.style = style
    }

    private var isRow: Bool { style == .row }

    package var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch summaries.shownState(for: subject) {
        case nil:
            // About to be written as it opened: the card shows already, as it will be, with Not Now.
            if summaries.isPending(subject) { placeholder(isWriting: false) }
        case .writing:
            // Written again, the one it replaces shows meanwhile.
            if case .written(let summary, let at, let inputs, let model)? = summaries.previous(for: subject) {
                written(summary, at: at, inputs: inputs, model: model, showing: .updating)
            } else {
                placeholder(isWriting: true)
            }
        case .written(let summary, let at, let inputs, let model):
            written(summary, at: at, inputs: inputs, model: model, showing: .current)
        case .failed(let problem, _):
            // Written again and couldn't be: the one before stays, as it was, with why at its foot.
            if case .written(let summary, let at, let inputs, let model)? = summaries.previous(for: subject) {
                written(summary, at: at, inputs: inputs, model: model, showing: .notUpdated(problem))
            } else {
                failed(problem)
            }
        }
    }

    /// How a written one shows.
    private enum Showing {
        /// As written, or out of date since.
        case current
        /// Dimmed, while another is written in its place.
        case updating
        /// As written, when another couldn't be written in its place.
        case notUpdated(StorySummaries.Problem)
    }

    static func title(for model: String) -> String {
        model == StorySummaries.appleIntelligenceModel ? "Summary by Apple Intelligence" : "Summary by Copilot"
    }

    /// The model and whether it runs locally or uses a Copilot request.
    static func writing(_ summaries: StorySummaries) -> String {
        "Summarizing with \(summaries.name(of: summaries.model)) · \(summaries.requestDescription)"
    }

    /// `writing`, shortened where needed, with the model in its tooltip.
    static func writingText(_ summaries: StorySummaries) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(writing(summaries))
                .fixedSize()
            Text("Summarizing · \(summaries.requestDescription)")
                .fixedSize()
                .help("With \(summaries.attribution(for: summaries.model))")
        }
        .foregroundStyle(.secondary)
    }

    /// "Summarizing in a moment · 1 request", or "· on this Mac": what opening it is about to do, and cost, while Not Now
    /// can still keep it.
    static func pendingText(_ summaries: StorySummaries) -> String {
        "Summarizing in a moment · \(summaries.requestDescription)"
    }

    /// The card before there's a summary in it, about as tall as it will be, so nothing under it moves twice: what it's
    /// about to cost, with Not Now; then, as it's written, with which model, with Stop, in the same place.
    private func placeholder(isWriting: Bool) -> some View {
        card {
            header { Text(Self.title(for: summaries.model)) } trailing: {
                Group {
                    if isWriting {
                        Button("Stop") { summaries.cancel(subject) }
                            .help(summaries.usesOnDeviceModel ? "Stop writing it" : "Stop writing it: 1 request may be used already")
                    } else {
                        Button("Not Now") { summaries.notNow(subject) }
                            .help("Don't write it this time: ✨ \(summaries.actionTitle) writes it when you want")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .font(.system(size: 11.5))
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Self.lines
                HStack(spacing: 6) {
                    if isWriting {
                        ProgressView()
                            .controlSize(.mini)
                        Self.writingText(summaries)
                    } else {
                        Text(Self.pendingText(summaries))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11.5))
            }
        }
    }

    /// Gray bars where its headline, next step and the rest will be.
    private static var lines: some View {
        let widths: [(fraction: CGFloat, height: CGFloat)] = [
            (0.82, 11), (0.58, 8), (1, 8), (0.97, 8), (0.93, 8), (0.98, 8), (0.52, 8),
        ]
        return GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 7) {
                ForEach(widths.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: proxy.size.width * widths[index].fraction, height: widths[index].height)
                }
            }
        }
        .frame(height: widths.reduce(0) { $0 + $1.height } + CGFloat(widths.count - 1) * 7)
        .accessibilityHidden(true)
    }

    /// A written one: as written, and what changed since, once it's out of date; dimmed while another is written in its
    /// place, which you can stop; or, when that one couldn't be written, as it was, with why at its foot.
    private func written(
        _ summary: StorySummary, at: Date, inputs: [StorySummaries.Input], model: String, showing: Showing
    ) -> some View {
        let isUpdating = if case .updating = showing { true } else { false }
        let changed = isUpdating ? nil : summaries.whatChanged(subject)
        let failure: StorySummaries.Problem? = if case .notUpdated(let problem) = showing { problem } else { nil }
        // Out of date reads gray but plain; being replaced, grayer.
        let isStale = changed != nil || failure != nil
        let strong: AnyShapeStyle = isUpdating ? AnyShapeStyle(.secondary) : isStale ? AnyShapeStyle(.primary.opacity(0.75)) : AnyShapeStyle(.primary)
        let rest: AnyShapeStyle = isUpdating ? AnyShapeStyle(.secondary) : isStale ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(.primary.opacity(0.85))
        let cost = model == StorySummaries.appleIntelligenceModel ? "." : ": 1 request."
        let written = "Written by \(summaries.attribution(for: model)) at "
            + "\(at.formatted(date: .omitted, time: .shortened)), from \(StorySummaries.source(of: inputs))" + cost
        return card {
            if isUpdating {
                header {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Updating · \(summaries.requestDescription)")
                            .lineLimit(1)
                            .help(Self.writing(summaries))
                    }
                } trailing: {
                    Button("Stop") { summaries.cancel(subject) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                        .font(.system(size: 11.5))
                        .help("Stop, and keep the summary from \(at.formatted(date: .omitted, time: .shortened))")
                }
            } else {
                // Narrower, it says less, but always when it was written and whether it's out of date.
                ViewThatFits(in: .horizontal) {
                    header { caption(Self.title(for: model), at: at, changed: changed, written: written) } trailing: { refreshAndClose }
                    header { caption("Summary", at: at, changed: changed, written: written) } trailing: { refreshAndClose }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.headline)
                    .font(.system(size: isRow ? 12.5 : 13, weight: .semibold))
                    .foregroundStyle(strong)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let next = summary.next {
                    (Text(summary.nextLabel).fontWeight(.semibold) + Text(" " + next))
                        .font(.system(size: isRow ? 11.5 : 12))
                        .foregroundStyle(strong)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // All of it: it's what explains where things stand, so it never hides behind Show More.
                if let paragraph = summary.paragraph {
                    Text(paragraph)
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .foregroundStyle(rest)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
                if let failure {
                    notUpdated(failure)
                } else if let changed {
                    // What changed since, and a new one.
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Since then: \(changed).")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        againButton
                    }
                    .font(.system(size: 11.5))
                    .padding(.top, 2)
                }
            }
        }
        .contextMenu {
            if !isUpdating {
                Button("Summarize Again") { summaries.summarize(subject) }
            }
            Button("Copy Summary") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary.plainText, forType: .string)
            }
            if !isUpdating {
                Button("Hide Summary") { summaries.hide(subject) }
            }
        }
    }

    /// Why another couldn't be written in its place, and what would help, at its foot.
    private func notUpdated(_ problem: StorySummaries.Problem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Couldn't update: \(problem.message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
                .fixedSize(horizontal: false, vertical: true)
                .help(problem.detail ?? "")
            fixes(for: problem)
        }
        .font(.system(size: 11.5))
        .padding(.top, 2)
    }

    /// What would help when one couldn't be written: choosing another model, when the one chosen isn't on your plan;
    /// and trying again.
    private func fixes(for problem: StorySummaries.Problem) -> some View {
        HStack(spacing: 14) {
            if problem.fix == .chooseModel {
                Button("Choose Model…") { choosesModel = true }
                    .popover(isPresented: $choosesModel, arrowEdge: .bottom) {
                        StorySummariesSetting(summaries: summaries, links: services.links)
                            .padding(16)
                            .frame(width: 420)
                    }
            }
            Button("Try Again") { summaries.summarize(subject) }
                .help(SummarizeButton.help(for: subject, model: summaries.name(of: summaries.model), onDevice: summaries.usesOnDeviceModel))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.tint)
    }

    private func failed(_ problem: StorySummaries.Problem) -> some View {
        card {
            header { Text("Summary") } trailing: { closeButton }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't summarize: \(problem.message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(problem.detail ?? "")
                fixes(for: problem)
            }
            .font(.system(size: 12))
        }
    }

    /// ↻, which writes it again, and ✕, which closes it.
    private var refreshAndClose: some View {
        HStack(spacing: 0) {
            Button {
                summaries.summarize(subject)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(SummarizeButton.help(for: subject, model: summaries.name(of: summaries.model), onDevice: summaries.usesOnDeviceModel))
            .accessibilityLabel("Summarize Again")
            closeButton
        }
    }

    /// ✕, which closes it, kept to show again for nothing; or one that couldn't be written, forgotten.
    private var closeButton: some View {
        Button {
            summaries.hide(subject)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Hide Summary: Show Summary brings it back")
        .accessibilityLabel("Hide Summary")
    }

    /// "Summary by Copilot · 2m ago · Out of date": the time each minute, never cut short, and what changed in a tooltip;
    /// who wrote it, when and from what in another.
    private func caption(_ title: String, at: Date, changed: String?, written: String) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .lineLimit(1)
            TimelineView(.periodic(from: at, by: 60)) { context in
                Text(" · " + Self.ago(at, now: context.date))
                    .fixedSize()
            }
            if let changed {
                Text(" · ")
                    .fixedSize()
                Text("Out of date")
                    .fontWeight(.bold)
                    .fixedSize()
                    .help("Since it was written: \(changed).")
            }
        }
        .help(written)
    }

    /// Summarize Again, while it's out of date: in the tint, as a link.
    private var againButton: some View {
        Button("Summarize Again") { summaries.summarize(subject) }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .fixedSize()
            .help(SummarizeButton.help(for: subject, model: summaries.name(of: summaries.model), onDevice: summaries.usesOnDeviceModel))
    }

    /// The card's first line: ✨, its caption, gray, and what it does on its right.
    private func header<Caption: View, Trailing: View>(
        @ViewBuilder caption: () -> Caption, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(options.quietAppearance ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(BriefContainer<EmptyView>.gradient))
                .accessibilityHidden(true)
            caption()
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            trailing()
        }
        .frame(minHeight: 22)
    }

    /// A card in the colors of what a model wrote: its header, then what it says.
    private func card<Header: View, Content: View>(
        @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content
    ) -> some View {
        let colorful = !options.quietAppearance
        let radius: CGFloat = isRow ? 10 : 12
        return VStack(alignment: .leading, spacing: isRow ? 5 : 7) {
            header()
            content()
        }
        .padding(.horizontal, isRow ? 10 : 12)
        .padding(.vertical, isRow ? 7 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(colorful ? AnyShapeStyle(BriefContainer<EmptyView>.gradient.opacity(isRow ? 0.07 : 0.09)) : AnyShapeStyle(Color.primary.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    colorful ? AnyShapeStyle(BriefContainer<EmptyView>.gradient.opacity(isRow ? 0.28 : 0.35)) : AnyShapeStyle(Color.primary.opacity(0.1)),
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Summary")
    }

    /// "just now", "2m ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let elapsed = Elapsed.short(since: date, now: now)
        return elapsed == "now" ? "just now" : "\(elapsed) ago"
    }
}

// MARK: - The setting

/// A thing the details or a page shows, and how many times you'd acted on its summary as it opened
/// (`StorySummaries.timesActed(on:)`): what they write by themselves as it opens never undoes what you did meanwhile.
struct OpenedSubject: Equatable {
    var subject: ItemRef
    var acted: Int
}

/// Where a summary could be, while summaries are off: a line that says what it would do, **Turn On…**, which
/// shows its setting, what it sends and what it costs, to turn it on there, and ✕, which hides the line for good. Nothing
/// while Show Links is off: Where It Stands says how to turn that on first.
package struct SummaryOffer: View {
    private let subject: ItemRef
    @ObservedObject private var summaries: StorySummaries
    @ObservedObject private var links: Links
    private let defaults: UserDefaults

    @LocalState private var hidden: Bool?
    @LocalState private var showsSetting = false
    @Environment(\.interfaceOptions) private var options

    /// The preferences' key for the line, once you dismissed it.
    package static let hiddenKey = "summaries.copilot.offerHidden"
    /// "Apple Intelligence can tell you where this stands, in a few lines.", or Copilot, as the model chosen.
    package static func text(_ summaries: StorySummaries) -> String {
        "\(summaries.usesOnDeviceModel ? "Apple Intelligence" : "Copilot") can tell you where this stands, in a few lines."
    }

    package init(subject: ItemRef, summaries: StorySummaries, links: Links, defaults: UserDefaults) {
        self.subject = subject
        self.summaries = summaries
        self.links = links
        self.defaults = defaults
    }

    package var body: some View {
        // It stays while its setting shows, so turning it on there doesn't take the setting away.
        if links.isOn, !summaries.isOn || showsSetting, !(hidden ?? defaults.bool(forKey: Self.hiddenKey)) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(options.quietAppearance ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(BriefContainer<EmptyView>.gradient))
                    .accessibilityHidden(true)
                Text(Self.text(summaries))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn On…") { showsSetting = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .fixedSize()
                    .help("Shows the setting for summaries: what they use, where, and what they cost")
                    .popover(isPresented: $showsSetting, arrowEdge: .bottom) {
                        StorySummariesSetting(summaries: summaries, links: links)
                            .padding(16)
                            .frame(width: 420)
                    }
                Spacer(minLength: 4)
                Button {
                    defaults.set(true, forKey: Self.hiddenKey)
                    hidden = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Don't show this again: Summaries are in Settings › General")
                .accessibilityLabel("Dismiss")
            }
            .font(.system(size: 12))
            .accessibilityElement(children: .contain)
        }
    }
}

/// Summaries, off by default: in Settings, under Show Links, with when they're written, what they use, where, what they
/// cost and what the model can do with it, and the model: Apple Intelligence on this Mac, or one through Copilot. While
/// Show Links is off, it can't be changed.
package struct StorySummariesSetting: View {
    @ObservedObject private var summaries: StorySummaries
    @ObservedObject private var links: Links
    @LocalState private var unavailableReason: String?

    package init(summaries: StorySummaries, links: Links) {
        self.summaries = summaries
        self.links = links
    }

    package static let title = "Summaries"
    /// What it does, and when it runs, as you chose.
    package static func explanation(writesWhenOpened: Bool) -> String {
        "Writes a few lines on where a work item, pull request or Copilot session stands, from what's known of it and "
            + "what's linked to it: at the top of its details or page, and under its row in a list when you ask (point at "
            + "the row and click ✨, or right-click it). Choose Apple Intelligence on this Mac or a model through Copilot. "
            + (writesWhenOpened ? "Nothing runs until you open one or ask." : "Nothing runs until you ask.")
    }
    /// What it uses, where, what it costs, as you chose where and when it writes, and what the model can do with it, a
    /// line each.
    package static func lines(onDevice: Bool, writesWhenOpened: Bool) -> [(label: String, symbol: String, text: String)] {
        let when = writesWhenOpened
            ? "each time one's written: as you open one that has none, or one that's out of date and ten minutes old, or when you ask."
            : "each time you ask."
        return [
            (onDevice ? "Uses" : "Sends", "arrow.up.doc", """
                what's known of the work item, pull request or session and what's linked to it: descriptions, comments and \
                review threads, builds and their errors, Copilot's notes, and what you asked in each session and what \
                Copilot answered. Never anything from Teams.
                """),
            ("Where", onDevice ? "desktopcomputer" : "network", onDevice ? """
                on this Mac with Apple Intelligence, never Private Cloud Compute or Copilot. Needs macOS 26 or later and \
                Apple Intelligence enabled and ready. BriefBar keeps summaries in memory only.
                """ : """
                GitHub Copilot, through the Copilot CLI, which keeps each one in its session history, as a session named \
                “BriefBar summary”. BriefBar keeps summaries in memory only.
                """),
            ("Costs", "creditcard", onDevice
                ? "no Copilot requests or subscription needed."
                : "one request on your Copilot plan, at the model's rate, \(when) One that's still current shows again for nothing."),
            ("Can do", "lock.shield", "only write. It gets no tools: no commands, files or web."),
        ]
    }
    /// When it writes one, as the setting says it.
    package static let whenOpened = "As you open one"
    package static let whenAsked = "Only when you ask"

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(Self.title, isOn: Binding(get: { summaries.isOn }, set: { summaries.setOn($0) }))
                Text(Self.explanation(writesWhenOpened: summaries.writesWhenOpened))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // When it writes them, which is what it costs, where it's chosen first.
                HStack(spacing: 6) {
                    Text("Writes")
                    Picker("Writes", selection: Binding(get: { summaries.writesWhenOpened }, set: { summaries.setWritesWhenOpened($0) })) {
                        Text(Self.whenOpened).tag(true)
                        Text(Self.whenAsked).tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("As you open a work item's details, or a pull request's or a Copilot session's page, unless one that's current is there; or only when you click ✨")
                }
                .font(.callout)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.lines(onDevice: summaries.usesOnDeviceModel, writesWhenOpened: summaries.writesWhenOpened), id: \.label) { line in
                    labeled(line.label, symbol: line.symbol) {
                        Text(line.text)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                labeled("Model", symbol: "cpu") {
                    Picker("Model", selection: Binding(get: { summaries.model }, set: { summaries.setModel($0) })) {
                        ForEach(choices) { model in
                            Text(model.id == StorySummaries.appleIntelligenceModel
                                 ? "\(model.name) (on this Mac)" : model.name).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if summaries.isAvailable, summaries.usesOnDeviceModel, let unavailableReason {
                Label(unavailableReason + " Choose a Copilot model to use it instead; BriefBar never switches automatically.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if summaries.isAvailable, !summaries.usesOnDeviceModel, summaries.hasCLI == false {
                Label("Copilot CLI not found. Install it, or open the GitHub Copilot app once.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 20)
        .disabled(!links.isOn)
        .opacity(links.isOn ? 1 : 0.45)
        .task(id: [summaries.isAvailable ? "on" : "off", summaries.model]) {
            refreshOnDeviceAvailability()
            await summaries.lookForCLI()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshOnDeviceAvailability()
        }
    }

    private func refreshOnDeviceAvailability() {
        unavailableReason = summaries.isAvailable && summaries.usesOnDeviceModel ? OnDeviceModel.unavailableReason : nil
    }

    /// A line with its label, after its symbol, as Settings' descriptions have them.
    private func labeled<Content: View>(_ label: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(label)
                .fontWeight(.semibold)
                .frame(width: 56, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    /// The models to choose from, with the one chosen even when it isn't among them.
    private var choices: [StorySummaries.Model] {
        var choices = summaries.models
        if !choices.contains(where: { $0.id == summaries.model }) {
            choices.append(StorySummaries.Model(id: summaries.model, name: summaries.model))
        }
        return choices
    }
}
