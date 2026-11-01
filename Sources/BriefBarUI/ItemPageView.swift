import AppKit
import BriefBarCore
import SwiftUI

/// A pull request's or a Copilot session's page, where a work item's details show: what it is and where it stands, how
/// it's linked to what you opened it from, its facts and pipelines, what else is linked to it, with Summarize for it,
/// and Copilot's notes.
package struct ItemPageView: View {
    private let ref: ItemRef

    @EnvironmentObject private var services: AppServices

    package init(ref: ItemRef) {
        self.ref = ref
    }

    package var body: some View {
        PageContent(ref: ref, links: services.links, stories: services.stories, summaries: services.summaries, defaults: services.defaults)
    }

    /// What a page is called where it's named, for VoiceOver: "Pull request 4091", "Copilot session Save items for later".
    package static func spokenName(of item: LinkedItem) -> String {
        let kind = PageContent.kind(of: item)
        let name = kind.prefix(1) + kind.dropFirst().lowercased()
        switch item.ref.kind {
        case .pullRequest, .gitHubPullRequest: return "\(name) \(item.ref.id)"
        case .session: return item.sent != nil ? String(name) : "\(name) \(item.label)"
        case .workItem: return "\(name) \(item.label)"
        }
    }

    /// Its crumb in the details' header: "!4091", a session's name, or "✈ 5112" for a task sent to Copilot from 5112.
    package static func crumb(of item: LinkedItem) -> String {
        switch item.ref.kind {
        case .pullRequest, .gitHubPullRequest, .workItem: return item.label
        case .session:
            guard let sent = item.sent else { return item.label }
            return sent.label.map { "✈ \($0)" } ?? "Sent to Copilot"
        }
    }
}

private struct PageContent: View {
    let ref: ItemRef
    @ObservedObject var links: Links
    @ObservedObject var stories: ItemStories
    @ObservedObject var summaries: StorySummaries
    let defaults: UserDefaults

    @Environment(\.itemNavigation) private var navigation
    @Environment(\.isRendering) private var isRendering
    @AccessibilityFocusState private var isTitleFocused: Bool
    /// What it shows, and how many times you'd acted on its summary as it opened.
    @LocalState private var opened: OpenedSubject?

    /// What shows under it: the work item, and the pages you came through.
    private var trail: [ItemRef] {
        guard let navigation, let index = navigation.trail.lastIndex(of: ref) else { return [] }
        return Array(navigation.trail[..<index])
    }

    var body: some View {
        let item = links.describe(ref)
        let story = stories.story(for: ref)
        VStack(alignment: .leading, spacing: 20) {
            heading(item, story: story)
            // Its summary, of it and what's linked to it, under what it is; while summaries are off, what one would do,
            // first, so turning them on there doesn't move it.
            if links.isDescribed(ref) {
                SummaryOffer(subject: ref, summaries: summaries, links: links, defaults: defaults)
            }
            SummaryCard(subject: ref, summaries: summaries, rows: [])
            StoryDetails(
                item: item, story: story, isTelling: stories.isTelling(ref) && !stories.hasTold(ref), mode: .page,
                linkFact: linkFact
            )
            WhereItStandsSection(subject: ref, excluding: Set(trail), title: "Also Linked", hidesWhenEmpty: true, showsSummary: false)
            if let account = story?.account, !account.isEmpty {
                StoryNotesSection(item: item, account: account)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Its own story, as it is now, as the page shows and whenever its row changes.
        .onChange(of: ItemStories.version(of: item), initial: true) {
            stories.request(item)
        }
        // And each minute while it shows, for what changes without its row changing, such as a vote or a checkpoint.
        .background {
            TimelineView(.periodic(from: .distantPast, by: ItemStories.freshFor)) { context in
                Color.clear.onChange(of: context.date) { stories.request(links.describe(ref)) }
            }
        }
        // Once it's shown a moment, its summary, unless one that's current is there, as for a work item's details: as it
        // opens, as summaries are turned on, and as a source says what it is; never once you acted on it since it opened.
        .task(id: "\(ref)|\(summaries.isOn)|\(summaries.writesWhenOpened)|\(summaries.isChoosing)|\(summaries.model)|\(summaries.knowsModel)|\(summaries.canSummarize(ref))") {
            guard links.isOn, !isRendering else { return }
            // Which model it'd be written with, first, so its card never says the wrong one: this starts again once
            // it's known, its id saying so.
            if !summaries.knowsModel {
                await summaries.lookForCLI()
                return
            }
            let acted = visit(ref)
            // Its card shows already, as it will be, with Not Now, until it's written or this stops waiting.
            let wait = summaries.expect(ref, unlessActedSince: acted)
            defer { summaries.stopExpecting(ref, wait) }
            try? await Task.sleep(for: StorySummaries.openedFor)
            guard !Task.isCancelled else { return }
            await summaries.opened(ref, unlessActedSince: acted)
        }
        // The card coming, filling and going moves what's under it smoothly.
        .animation(.easeOut(duration: 0.2), value: summaries.shownState(for: ref))
        .animation(.easeOut(duration: 0.2), value: summaries.isPending(ref))
        .onAppear { isTitleFocused = true }
    }

    /// How many times you'd acted on its summary as it opened (`StorySummaries.timesActed(on:)`), remembered for as long
    /// as it shows.
    private func visit(_ ref: ItemRef) -> Int {
        if let opened, opened.subject == ref { return opened.acted }
        let acted = summaries.timesActed(on: ref)
        opened = OpenedSubject(subject: ref, acted: acted)
        return acted
    }

    /// How it's linked to what you opened it from.
    private var linkFact: ItemStory.Fact? {
        guard let previous = trail.last,
              let connection = links.connections(of: previous).first(where: { $0.item.ref == ref })
        else { return nil }
        return WhereItStandsSection.linkFact(connection, from: links.describe(previous))
    }

    private func heading(_ item: LinkedItem, story: ItemStory?) -> some View {
        let sentence = WhereItStandsSection.sentence(
            story?.sentence.isEmpty == false ? story?.sentence ?? "" : item.status ?? "", on: ref
        )
        let date = story?.date ?? item.date
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(of: item))
                    .foregroundStyle(item.state?.color ?? item.color)
                Text(Self.kind(of: item))
                if item.ref.kind != .session {
                    Text(item.label)
                        .monospacedDigit()
                }
                if let place = item.place, !place.isEmpty {
                    Text("·")
                    Text(place)
                        .lineLimit(1)
                }
            }
            .font(size: 12, weight: .medium)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.description(of: item))
            Text(item.ref.kind == .session ? item.label : item.title)
                .font(size: 17, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isTitleFocused)
            if !sentence.isEmpty || date != nil {
                (WhereItStandsSection.sentenceText(sentence, state: item.state)
                    + Text(date.map { (sentence.isEmpty ? "" : " · ") + StoryTime.ago($0) } ?? "").foregroundStyle(.secondary))
                    .font(size: 12.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                StoryActions(item: item)
                    .glassButtonStyle()
                if summaries.isHidden(ref) {
                    Button {
                        summaries.show(ref)
                    } label: {
                        Label("Show Summary", systemImage: "sparkles")
                    }
                    .glassButtonStyle()
                    .help("Shows the summary you closed, as it was written")
                } else if summaries.canSummarize(ref), summaries.state(for: ref) == nil, !summaries.isPending(ref) {
                    // Just "Summarize" where the whole of it doesn't fit.
                    ViewThatFits(in: .horizontal) {
                        summarize(summaries.actionTitle)
                        summarize("Summarize")
                    }
                }
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }

    private func summarize(_ title: String) -> some View {
        Button {
            summaries.summarize(ref)
        } label: {
            Label(title, systemImage: "sparkles")
                .fixedSize()
        }
        .glassButtonStyle()
        .help(SummarizeButton.help(for: ref, model: summaries.name(of: summaries.model), onDevice: summaries.usesOnDeviceModel))
        .accessibilityLabel(summaries.actionTitle)
    }

    /// "Pull Request", "Copilot Session", "Sent to Copilot".
    static func kind(of item: LinkedItem) -> String {
        item.sent != nil ? "Sent to Copilot" : item.ref.kind.title
    }

    /// "Pull request 4091 in payments-api", for VoiceOver.
    static func description(of item: LinkedItem) -> String {
        var text = kind(of: item).prefix(1) + kind(of: item).dropFirst().lowercased()
        if item.ref.kind.isPullRequest { text += " " + item.ref.id }
        if let place = item.place, !place.isEmpty { text += " in " + place }
        return String(text)
    }

    static func symbol(of item: LinkedItem) -> String {
        switch item.ref.kind {
        case .pullRequest, .gitHubPullRequest: return "arrow.triangle.pull"
        case .session: return item.sent != nil ? "paperplane.fill" : "waveform.path.ecg"
        case .workItem: return "doc.text"
        }
    }
}
