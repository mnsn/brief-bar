import AppKit
import BriefBarCore
import SwiftUI

/// A pull request's or a Copilot session's page, where a work item's details show: what it is and where it stands, how
/// it's linked to what you opened it from, its facts and pipelines, what else is linked to it, with Summarize with Copilot
/// for it, and Copilot's notes.
package struct ItemPageView: View {
    private let ref: ItemRef

    @EnvironmentObject private var services: AppServices

    package init(ref: ItemRef) {
        self.ref = ref
    }

    package var body: some View {
        PageContent(ref: ref, links: services.links, stories: services.stories, summaries: services.summaries)
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

    @Environment(\.itemNavigation) private var navigation
    @AccessibilityFocusState private var isTitleFocused: Bool

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
            // Its summary, of it and what's linked to it, under what it is.
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
        .onAppear { isTitleFocused = true }
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
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.description(of: item))
            Text(item.ref.kind == .session ? item.label : item.title)
                .font(.system(size: 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isTitleFocused)
            if !sentence.isEmpty || date != nil {
                (WhereItStandsSection.sentenceText(sentence, state: item.state)
                    + Text(date.map { (sentence.isEmpty ? "" : " · ") + StoryTime.ago($0) } ?? "").foregroundStyle(.secondary))
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                StoryActions(item: item)
                    .glassButtonStyle()
                if summaries.canSummarize(ref), summaries.state(for: ref) == nil {
                    Button {
                        summaries.summarize(ref)
                    } label: {
                        Label("Summarize with Copilot", systemImage: "sparkles")
                    }
                    .glassButtonStyle()
                    .help(SummarizeButton.help(for: ref, model: summaries.name(of: summaries.model)))
                }
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
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
