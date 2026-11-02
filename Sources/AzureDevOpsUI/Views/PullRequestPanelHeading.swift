import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The top of a pull request's details: what it is and where, its title, where it stands in a sentence and since when,
/// its branch and who wrote it, and ✨ Summarize, as a pull request's page has them.
struct PullRequestPanelHeading: View {
    let item: PRSnapshot
    let panel: PullRequestPanel
    /// The list still has it; once it doesn't, such as a review that merged, this is how it was last.
    var isListed = true
    /// How it's linked to what it opened from, as a page over a work item's details or another pull request's.
    var linked: ItemStory.Fact? = nil

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PRStore
    @AccessibilityFocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: item.group == .done ? "arrow.triangle.merge" : "arrow.triangle.pull")
                    .foregroundStyle(item.rowColor)
                // Each on one line, whatever the room: the repository gives way first.
                Text("Pull Request")
                    .fixedSize()
                Text(verbatim: "!\(item.key.number)")
                    .monospacedDigit()
                    .fixedSize()
                Text("·")
                    .fixedSize()
                Text(item.repository)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(size: 12, weight: .medium)
            .foregroundStyle(.secondary)
            .help("\(item.repository), in \(item.project)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Pull request \(item.key.number) in \(item.repository)"))
            Text(item.title)
                .font(size: 17, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isTitleFocused)
            standing
            if !isListed {
                Label("It's no longer in your lists: this is how it was when it left them.", systemImage: "clock.arrow.circlepath")
                    .font(size: 11.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            facts
            PageSummarizeButton(ref: item.key.linkRef)
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .onAppear { isTitleFocused = true }
    }

    /// Where it stands, as its row says it, its opening words in its state's color, and since when.
    private var standing: some View {
        let state = item.group.state(showToReview: settings.showToReview)
        let since = panel.since.map { (panel.sentence.isEmpty ? "" : " · ") + WorkItemDetailsPanel.ago($0, now: store.now) } ?? ""
        return (WhereItStandsSection.sentenceText(panel.sentence, state: state) + Text(since).foregroundStyle(.secondary))
            .font(size: 12.5)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// Its branch, who wrote it, how its merge stands, and, as a page, how it's linked to what it opened from.
    private var facts: some View {
        FlowLayout(spacing: 12, lineSpacing: 5) {
            if let branch = panel.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Merges \(branch.replacingOccurrences(of: " → ", with: " into "))")
            }
            HStack(spacing: 5) {
                Avatar(name: item.author, size: 16, isMe: panel.isYours)
                Text(panel.isYours ? "By you" : "By \(item.author)")
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(panel.isYours ? "By you" : "By \(item.author)")
            if let merge = panel.merge {
                Label(merge, systemImage: "arrow.triangle.merge")
                    .lineLimit(1)
            }
            if let linked {
                Label(linked.value, systemImage: "link")
                    .lineLimit(1)
                    .help("\(linked.label): \(linked.value)")
                    .accessibilityLabel("\(linked.label): \(linked.value)")
            }
        }
        .font(size: 11.5)
        .foregroundStyle(.secondary)
    }
}
