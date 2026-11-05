import BriefBarCore
import SwiftUI

// A page's summary, as a pull request's or a Copilot session's page has it under its heading, and a pull request's
// details: ✨ Summarize in the heading, the card under it, and writing it as the page opens, as a work item's details do.

/// ✨ Summarize, in a page's heading, while summaries and Show Links are on, there's something to sum up, and no summary
/// shows or is about to be written as it opened; or Show Summary, once you closed it. There's something to sum up of a
/// pull request or a session its source says what it is, and of a work item once something's linked to it, as a
/// summary's written as it opens.
package struct PageSummarizeButton: View {
    private let ref: ItemRef

    @EnvironmentObject private var services: AppServices

    package init(ref: ItemRef) {
        self.ref = ref
    }

    package var body: some View {
        Content(ref: ref, links: services.links, summaries: services.summaries)
    }

    private struct Content: View {
        let ref: ItemRef
        // Whether there's something to sum up changes with Show Links and what's linked, which `StorySummaries` passes
        // on only once a summary's written.
        @ObservedObject var links: Links
        @ObservedObject var summaries: StorySummaries

        var body: some View {
            if summaries.isHidden(ref) {
                Button {
                    summaries.show(ref)
                } label: {
                    ControlLabel("Show Summary", systemImage: "sparkles")
                }
                .glassButtonStyle()
                .help("Shows the summary you closed, as it was written")
            } else if canSummarize, summaries.state(for: ref) == nil, !summaries.isPending(ref) {
                // Just "Summarize" where the whole of it doesn't fit.
                ViewThatFits(in: .horizontal) {
                    summarize(summaries.actionTitle)
                    summarize("Summarize")
                }
            }
        }

        private var canSummarize: Bool {
            ref.kind == .workItem ? summaries.hasSomethingToSum(ref) : summaries.canSummarize(ref)
        }

        private func summarize(_ title: String) -> some View {
            Button {
                summaries.summarize(ref)
            } label: {
                ControlLabel(title, systemImage: "sparkles")
                    .fixedSize()
            }
            .glassButtonStyle()
            .help(SummarizeButton.help(for: ref, model: summaries.name(of: summaries.model), onDevice: summaries.usesOnDeviceModel))
            .accessibilityLabel(summaries.actionTitle)
        }
    }
}

/// A page's summary, of it and what's linked to it, under its heading: while summaries are off, what one would do,
/// first, so turning them on there doesn't move it; then its card. Each is a part of the page of its own, spaced as the
/// page spaces its parts.
package struct PageSummary: View {
    private let ref: ItemRef

    @EnvironmentObject private var services: AppServices

    package init(ref: ItemRef) {
        self.ref = ref
    }

    package var body: some View {
        Content(ref: ref, links: services.links, summaries: services.summaries, defaults: services.defaults)
    }

    private struct Content: View {
        let ref: ItemRef
        @ObservedObject var links: Links
        @ObservedObject var summaries: StorySummaries
        let defaults: UserDefaults

        var body: some View {
            if links.isDescribed(ref) {
                SummaryOffer(subject: ref, summaries: summaries, links: links, defaults: defaults)
            }
            SummaryCard(subject: ref, summaries: summaries, rows: [])
        }
    }
}

extension View {
    /// Writes the summary of what a page shows, once it has shown a moment, unless one that's current is there, as a work
    /// item's details do: as it opens, as summaries are turned on, and as a source says what it is; never once you acted
    /// on it since it opened. What's under its card moves smoothly as the card comes, fills and goes.
    package func writesSummary(of ref: ItemRef) -> some View {
        modifier(SummaryWriter(ref: ref))
    }
}

private struct SummaryWriter: ViewModifier {
    let ref: ItemRef

    @EnvironmentObject private var services: AppServices

    func body(content: Content) -> some View {
        content.modifier(SummaryWriting(ref: ref, links: services.links, summaries: services.summaries))
    }
}

private struct SummaryWriting: ViewModifier {
    let ref: ItemRef
    @ObservedObject var links: Links
    @ObservedObject var summaries: StorySummaries

    @Environment(\.isRendering) private var isRendering
    /// What it shows, and how many times you'd acted on its summary as it opened.
    @LocalState private var opened: OpenedSubject?

    func body(content: Content) -> some View {
        content
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
    }

    /// How many times you'd acted on its summary as it opened (`StorySummaries.timesActed(on:)`), remembered for as long
    /// as it shows.
    private func visit(_ ref: ItemRef) -> Int {
        if let opened, opened.subject == ref { return opened.acted }
        let acted = summaries.timesActed(on: ref)
        opened = OpenedSubject(subject: ref, acted: acted)
        return acted
    }
}
