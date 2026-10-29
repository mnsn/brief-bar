import AppKit
import BriefBarCore
import SwiftUI

/// ✨ Summarize, in Where It Stands' header, while Summarize with Copilot and Show Links are on: asks Copilot for a short
/// summary of the thing and what's linked to it. Never by itself.
struct SummarizeButton: View {
    let subject: ItemRef
    @ObservedObject var summaries: StorySummaries

    var body: some View {
        if summaries.isAvailable {
            let isWriting = if case .writing? = summaries.state(for: subject) { true } else { false }
            Button {
                summaries.summarize(subject)
            } label: {
                Label("Summarize", systemImage: "sparkles")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.borderless)
            .disabled(isWriting)
            .help("Ask Copilot for a short summary of this and what's linked to it, with \(summaries.name(of: summaries.model))")
        }
    }
}

/// What Copilot summed up, at the top of Where It Stands: where it stands in a line, what's next, and a short paragraph,
/// in the colors of what a model wrote; while it writes, a way to stop it; when it couldn't, why. A summary whose rows
/// changed since says it's out of date.
struct SummaryCard: View {
    let subject: ItemRef
    @ObservedObject var summaries: StorySummaries
    /// Re-checks whether it's out of date as the rows change.
    let rows: [String]

    @Environment(\.interfaceOptions) private var options

    var body: some View {
        switch summaries.state(for: subject) {
        case nil:
            EmptyView()
        case .writing:
            container(caption: "Summary") {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Copilot is writing a summary…")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Cancel") { summaries.cancel(subject) }
                        .buttonStyle(.borderless)
                }
                .font(.system(size: 12))
            }
        case .written(let summary, let at, _, let model):
            container(caption: "Summary · \(summaries.name(of: model)) · \(Self.ago(at))", actions: true) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.headline)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let next = summary.next {
                        (Text(summary.nextFor.map { "Next for \($0): " } ?? "Next: ").fontWeight(.semibold) + Text(next))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let paragraph = summary.paragraph {
                        ClampedText(text: paragraph, lines: 3)
                            .foregroundStyle(.secondary)
                    }
                    if summaries.isOutOfDate(subject) {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .accessibilityHidden(true)
                            Text("Out of date: something changed since")
                            Button("Summarize Again") { summaries.summarize(subject) }
                                .buttonStyle(.borderless)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let problem, _):
            container(caption: "Summary", actions: true) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(problem.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(problem.detail ?? "")
                    Spacer(minLength: 8)
                    Button("Try Again") { summaries.summarize(subject) }
                        .buttonStyle(.borderless)
                }
                .font(.system(size: 12))
            }
        }
    }

    /// A card in the colors of what a model wrote, with its caption, and ↻ and ✕ when it's done.
    private func container<Content: View>(
        caption: String, actions: Bool = false, @ViewBuilder content: () -> Content
    ) -> some View {
        let colorful = !options.quietAppearance
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colorful ? AnyShapeStyle(BriefContainer<EmptyView>.gradient) : AnyShapeStyle(Color.secondary))
                    .accessibilityHidden(true)
                Text(caption)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if actions {
                    Button {
                        summaries.summarize(subject)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Summarize again")
                    .accessibilityLabel("Summarize Again")
                    Button {
                        summaries.dismiss(subject)
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Close the summary")
                    .accessibilityLabel("Close Summary")
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorful ? AnyShapeStyle(BriefContainer<EmptyView>.gradient.opacity(0.09)) : AnyShapeStyle(Color.primary.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    colorful ? AnyShapeStyle(BriefContainer<EmptyView>.gradient.opacity(0.35)) : AnyShapeStyle(Color.primary.opacity(0.1)),
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Summary by Copilot")
    }

    /// "just now", "2m ago".
    static func ago(_ date: Date) -> String {
        let elapsed = Elapsed.short(since: date, now: Date())
        return elapsed == "now" ? "just now" : "\(elapsed) ago"
    }
}

// MARK: - The setting

/// Summarize with Copilot, off by default: in Settings, under Show Links, with what it does, what it sends where, and the
/// model it asks.
package struct StorySummariesSetting: View {
    @ObservedObject private var summaries: StorySummaries
    @ObservedObject private var links: Links

    package init(summaries: StorySummaries, links: Links) {
        self.summaries = summaries
        self.links = links
    }

    package static let title = "Summarize with Copilot"
    package static let explanation = """
        Adds ✨ Summarize to a work item's Where It Stands. When you click it, and never by itself, the Copilot CLI writes a \
        short summary of the work item and what's linked to it, from what its details show: its description and latest \
        comments, its pull requests' reviews, builds and errors, and what Copilot wrote of its sessions. That goes to \
        GitHub Copilot's model, so it leaves your Mac; nothing from Teams ever does. Copilot gets no tools for it, so it can \
        only write. Each summary counts toward your Copilot plan, a little with a small model, and BriefBar keeps it in \
        memory only. It needs Show Links and the Copilot CLI.
        """

    package var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(Self.title, isOn: Binding(get: { summaries.isOn }, set: { summaries.setOn($0) }))
                .disabled(!links.isOn && !summaries.isOn)
            Text(Self.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !links.isOn {
                Text("Turn on Show Links first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if summaries.isOn {
                Picker("Model", selection: Binding(get: { summaries.model }, set: { summaries.setModel($0) })) {
                    ForEach(choices) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .padding(.top, 4)
            }
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
