import AppKit
import BriefBarCore
import SwiftUI

/// Summarize with the selected provider, in Where It Stands' header, only when asked.
struct SummarizeButton: View {
    let subject: ItemRef
    @ObservedObject var summaries: StorySummaries

    var body: some View {
        if summaries.isHidden(subject) {
            Button {
                summaries.show(subject)
            } label: {
                Label("Show Summary", systemImage: "sparkles")
                    .font(size: 11.5)
                    .fixedSize()
            }
            .buttonStyle(.borderless)
            .help("Shows the summary you closed, as it was written")
        } else if summaries.state(for: subject) == nil, summaries.hasSomethingToSum(subject) {
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
                .font(size: 11.5)
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

/// What the selected model summed up, at the top of Where It Stands: where it stands in a line and what's next, for
/// whom, in the colors of what a model wrote, with the rest on request; while it writes, a way to stop it; when it
/// couldn't, why, and what would help. One whose rows changed since says it's out of date, and what changed.
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
    /// Who it waits on, as the line above it says: then what's next shows only with the rest, unless it's yours and the
    /// line doesn't say anything waits on you.
    var waitsAbove: [ItemStory.Wait] = []

    @EnvironmentObject private var services: AppServices
    @Environment(\.interfaceOptions) private var options
    @LocalState private var showsAll = false
    @LocalState private var choosesModel = false

    package init(
        subject: ItemRef, summaries: StorySummaries, rows: [String], style: Style = .section, waitsAbove: [ItemStory.Wait] = []
    ) {
        self.subject = subject
        self.summaries = summaries
        self.rows = rows
        self.style = style
        self.waitsAbove = waitsAbove
    }

    /// Whether its next step shows only with the rest: another's, or yours, under a line that says what waits on you.
    static func foldsNext(_ summary: StorySummary, under waits: [ItemStory.Wait]) -> Bool {
        guard !waits.isEmpty, summary.next != nil else { return false }
        let isYours = summary.nextFor?.caseInsensitiveCompare("you") == .orderedSame
        return !isYours || waits.contains { $0.who == .you }
    }

    private var isRow: Bool { style == .row }

    package var body: some View {
        content
            .onChange(of: writtenAt) { _, written in
                guard written != nil else { return }
                // A new one starts short.
                showsAll = false
            }
    }

    @ViewBuilder
    private var content: some View {
        switch summaries.shownState(for: subject) {
        case nil:
            EmptyView()
        case .writing:
            card {
                header { Text(Self.title(for: summaries.model)) } trailing: { EmptyView() }
            } content: {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Self.writingText(summaries)
                    Spacer(minLength: 8)
                    Button("Stop") { summaries.cancel(subject) }
                        .buttonStyle(.borderless)
                }
                .font(size: 12)
            }
        case .written(let summary, let at, let inputs, let model):
            written(summary, at: at, inputs: inputs, model: model)
        case .failed(let problem, _):
            failed(problem)
        }
    }

    private var writtenAt: Date? {
        if case .written(_, let at, _, _)? = summaries.state(for: subject) { return at }
        return nil
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

    private func written(_ summary: StorySummary, at: Date, inputs: [StorySummaries.Input], model: String) -> some View {
        let changed = summaries.whatChanged(subject)
        let isStale = changed != nil
        let written = "Written by \(summaries.attribution(for: model)) at "
            + "\(at.formatted(date: .omitted, time: .shortened)), from \(StorySummaries.source(of: inputs))."
        return card {
            // Narrower, it says less, but always when it was written and whether it's out of date.
            ViewThatFits(in: .horizontal) {
                header { caption(Self.title(for: model), at: at, changed: changed, written: written) } trailing: { closeButton }
                header { caption("Summary", at: at, changed: changed, written: written) } trailing: { closeButton }
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.headline)
                    .font(size: isRow ? 12.5 : 13, weight: .medium)
                    .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                let foldsNext = Self.foldsNext(summary, under: waitsAbove)
                if let next = summary.next, !foldsNext || showsAll {
                    (Text(summary.nextLabel).fontWeight(.semibold) + Text(" " + next))
                        .font(size: isRow ? 11.5 : 12)
                        .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let paragraph = summary.paragraph, showsAll {
                    Text(paragraph)
                        .font(size: 12)
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // Its way on: the rest of it, and, once it's out of date, a new one.
                let hasMore = summary.paragraph != nil || (foldsNext && summary.next != nil)
                if hasMore || isStale {
                    HStack(spacing: 14) {
                        if hasMore {
                            Button(showsAll ? "Show Less" : "Show More") {
                                withAnimation(.easeOut(duration: 0.15)) { showsAll.toggle() }
                            }
                            .accessibilityHint(showsAll ? "Hides the rest of the summary" : "Shows the rest of the summary")
                        }
                        if isStale { againButton }
                    }
                    .buttonStyle(.borderless)
                    .font(size: 11.5)
                }
            }
        }
        .contextMenu {
            Button("Summarize Again") { summaries.summarize(subject) }
            Button("Copy Summary") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary.plainText, forType: .string)
            }
            Button("Hide Summary") { summaries.hide(subject) }
        }
    }

    private func failed(_ problem: StorySummaries.Problem) -> some View {
        card {
            header { Text("Summary") } trailing: { closeButton }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Label(problem.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(problem.detail ?? "")
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
                }
                .buttonStyle(.borderless)
            }
            .font(size: 12)
        }
    }

    /// ✕, which closes it, kept to show again for nothing; or one that couldn't be written, forgotten.
    private var closeButton: some View {
        Button {
            summaries.hide(subject)
        } label: {
            Image(systemName: "xmark")
                .font(size: 10, weight: .semibold)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Close the summary")
        .accessibilityLabel("Close Summary")
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

    /// Summarize Again, while it's out of date.
    private var againButton: some View {
        Button("Summarize Again") { summaries.summarize(subject) }
            .fixedSize()
            .help(SummarizeButton.help(for: subject, model: summaries.name(of: summaries.model), onDevice: summaries.usesOnDeviceModel))
    }

    /// The card's first line: ✨, its caption, gray, and what it does on its right.
    private func header<Caption: View, Trailing: View>(
        @ViewBuilder caption: () -> Caption, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(size: 11, weight: .semibold)
                .foregroundStyle(options.quietAppearance ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(BriefContainer<EmptyView>.gradient))
                .accessibilityHidden(true)
            caption()
                .font(size: 11, weight: .semibold)
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

/// Summaries, off by default, with the selected provider's privacy, cost and availability.
package struct StorySummariesSetting: View {
    @ObservedObject private var summaries: StorySummaries
    @ObservedObject private var links: Links
    @LocalState private var unavailableReason: String?

    package init(summaries: StorySummaries, links: Links) {
        self.summaries = summaries
        self.links = links
    }

    package static let title = "Summaries"
    package static let explanation = """
        Adds ✨ Summarize to Where It Stands, and to pull requests' and Copilot sessions' rows (point at one, or \
        right-click it) and pages. Choose Apple Intelligence on this Mac or a model through Copilot. Nothing runs until you click it.
        """
    package static func lines(onDevice: Bool) -> [(label: String, symbol: String, text: String)] { [
        (onDevice ? "Uses" : "Sends", "arrow.up.doc", """
            what's known of the work item, pull request or session and what's linked to it: descriptions and latest \
            comments, reviews, builds and their errors, and Copilot's notes. Never anything from Teams.
            """),
        ("Where", onDevice ? "desktopcomputer" : "network", onDevice ? """
            on this Mac with Apple Intelligence, never Private Cloud Compute or Copilot. Needs macOS 26 or later and \
            Apple Intelligence enabled and ready. BriefBar keeps summaries in memory only.
            """ : """
            GitHub Copilot, through the Copilot CLI, which keeps a copy in its session history as “BriefBar summary”. \
            BriefBar keeps summaries in memory only.
            """),
        ("Costs", "creditcard", onDevice ? "no Copilot requests or subscription needed."
            : "one request on your Copilot plan per summary, at the model's rate."),
        ("Can do", "lock.shield", "only write. It gets no tools: no commands, files or web."),
    ] }

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(Self.title, isOn: Binding(get: { summaries.isOn }, set: { summaries.setOn($0) }))
                Text(Self.explanation)
                    .font(style: .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.lines(onDevice: summaries.usesOnDeviceModel), id: \.label) { line in
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
            .font(style: .callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if summaries.isAvailable, summaries.usesOnDeviceModel, let unavailableReason {
                Label(unavailableReason + " Choose a Copilot model to use it instead; BriefBar never switches automatically.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(style: .callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if summaries.isAvailable, !summaries.usesOnDeviceModel, summaries.hasCLI == false {
                Label("Copilot CLI not found. Install it, or open the GitHub Copilot app once.", systemImage: "exclamationmark.triangle.fill")
                    .font(style: .callout)
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
