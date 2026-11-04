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
        PageContent(ref: ref, links: services.links, stories: services.stories)
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
            PageSummary(ref: ref)
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
        .tellsStory(of: ref)
        // Once it's shown a moment, its summary, unless one that's current is there, as for a work item's details.
        .writesSummary(of: ref)
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
                let since = Text(date.map { (sentence.isEmpty ? "" : " · ") + StoryTime.ago($0) } ?? "").foregroundStyle(.secondary)
                Text("\(WhereItStandsSection.sentenceText(sentence, state: item.state))\(since)")
                    .font(size: 12.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                StoryActions(item: item)
                    .glassButtonStyle()
                PageSummarizeButton(ref: ref)
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

extension View {
    /// Keeps what's known of a thing beyond its row as it is now, while this shows: asks its source as it shows, whenever
    /// its row changes, and each minute, for what changes without its row changing, such as a vote or a checkpoint. A page
    /// shows it, and its summary tells from it whether it's out of date.
    package func tellsStory(of ref: ItemRef) -> some View {
        modifier(StoryTeller(ref: ref))
    }
}

private struct StoryTeller: ViewModifier {
    let ref: ItemRef

    @EnvironmentObject private var services: AppServices

    func body(content: Content) -> some View {
        content.modifier(StoryTelling(ref: ref, links: services.links, stories: services.stories))
    }
}

private struct StoryTelling: ViewModifier {
    let ref: ItemRef
    @ObservedObject var links: Links
    let stories: ItemStories

    func body(content: Content) -> some View {
        let item = links.describe(ref)
        content
            .onChange(of: ItemStories.version(of: item), initial: true) {
                stories.request(item)
            }
            .background {
                TimelineView(.periodic(from: .distantPast, by: ItemStories.freshFor)) { context in
                    Color.clear.onChange(of: context.date) { stories.request(links.describe(ref)) }
                }
            }
    }
}
