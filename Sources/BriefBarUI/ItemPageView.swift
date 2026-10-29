import AppKit
import BriefBarCore
import SwiftUI

/// A pull request's or a Copilot session's page, where a work item's details show: what it is and where it stands,
/// everything its source knows of it, and what's linked to it, Where It Stands, with Summarize with Copilot for it.
package struct ItemPageView: View {
    private let ref: ItemRef

    @EnvironmentObject private var services: AppServices

    package init(ref: ItemRef) {
        self.ref = ref
    }

    package var body: some View {
        PageContent(ref: ref, links: services.links, stories: services.stories)
    }
}

private struct PageContent: View {
    let ref: ItemRef
    @ObservedObject var links: Links
    @ObservedObject var stories: ItemStories

    var body: some View {
        let item = links.describe(ref)
        let story = stories.story(for: ref)
        VStack(alignment: .leading, spacing: 20) {
            heading(item, story: story)
            StoryDetails(
                item: item, story: story, isTelling: stories.isTelling(ref) && !stories.hasTold(ref), reason: nil, mode: .page
            )
            WhereItStandsSection(subject: ref)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Its own story, as it is now, as the page shows and whenever its row changes.
        .onChange(of: ItemStories.version(of: item), initial: true) {
            stories.request(item)
        }
    }

    private func heading(_ item: LinkedItem, story: ItemStory?) -> some View {
        let sentence = story?.sentence.isEmpty == false ? story?.sentence ?? "" : item.status ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(of: item))
                    .foregroundStyle(item.state?.color ?? item.color)
                    .accessibilityHidden(true)
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
            Text(item.ref.kind == .session ? item.label : item.title)
                .font(.system(size: 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !sentence.isEmpty {
                let (lead, rest) = WhereItStandsSection.phrase(sentence)
                (Text(lead).foregroundStyle(item.state.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
                    + Text(rest.isEmpty ? "" : " " + rest).foregroundStyle(.secondary))
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            StoryActions(item: item)
                .glassButtonStyle()
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }

    /// "Pull Request", "Copilot Session", "Task Sent to Copilot".
    static func kind(of item: LinkedItem) -> String {
        item.sent != nil ? "Task Sent to Copilot" : item.ref.kind.title
    }

    static func symbol(of item: LinkedItem) -> String {
        switch item.ref.kind {
        case .pullRequest, .gitHubPullRequest: return "arrow.triangle.pull"
        case .session: return item.sent != nil ? "paperplane.fill" : "waveform.path.ecg"
        case .workItem: return "doc.text"
        }
    }
}
