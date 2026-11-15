import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

// How a pipeline's run looks, on the Pipelines page and in a pull request's details: its result, its stages, and where
// it failed.

/// A run's result: a white symbol on a circle of its color.
struct RunStatusBadge: View {
    let status: PipelineRun.Status?
    var size: CGFloat = 34
    @Environment(\.textScale) private var textScale

    var body: some View {
        let color = status?.color ?? Color(nsColor: .systemGray)
        ZStack {
            Circle().fill(color.gradient)
            Image(systemName: status?.symbol ?? "questionmark")
                .font(size: size * 0.42, weight: .bold)
                .foregroundStyle(.white)
        }
        .frame(width: size * textScale, height: size * textScale)
        .shadow(color: color.opacity(0.35), radius: 4, y: 1)
        .accessibilityLabel(status?.title ?? "No runs")
    }
}

/// A run's stages, in order, joined by lines, on as many lines as they need, rather than cut off at the card's edge.
struct StageFlow: View {
    let stages: [PipelineStage]
    let now: Date

    var body: some View {
        StageChainLayout {
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                if index > 0 {
                    Rectangle()
                        .fill(stages[index - 1].state == .succeeded ? Color.green.opacity(0.5) : Color.primary.opacity(0.15))
                        .layoutValue(key: StageJoin.self, value: true)
                }
                StagePill(stage: stage, now: now)
            }
        }
        .padding(.vertical, 1)
    }
}

/// Marks the line between two stages, which `StageChainLayout` draws only where both are on one line.
private struct StageJoin: LayoutValueKey {
    static let defaultValue = false
}

/// Stages side by side, as many to a line as fit, each joined to the one before it on its line: a stage that starts a
/// line has no join before it, so that no line leads off to nothing. A stage wider than a line cuts its name short.
private struct StageChainLayout: Layout {
    var joinWidth: CGFloat = 14
    var joinThickness: CGFloat = 1.5
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each subview's frame: a stage's where it goes; a join's between its two stages, centered on their line, or empty,
    /// so that it draws nothing, before a stage that starts a line.
    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var lines: [(y: CGFloat, height: CGFloat)] = []
        var joins: [(index: Int, line: Int)] = []
        var pendingJoin: Int?
        var x: CGFloat = 0
        var widest: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            if subview[StageJoin.self] {
                pendingJoin = index
                continue
            }
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            let join = pendingJoin.map { _ in joinWidth } ?? 0
            if lines.isEmpty {
                lines.append((0, 0))
            } else if x + join + size.width > width {
                let last = lines[lines.count - 1]
                lines.append((last.y + last.height + lineSpacing, 0))
                x = 0
            } else if let pendingJoin {
                frames[pendingJoin] = CGRect(x: x, y: 0, width: joinWidth, height: joinThickness)
                joins.append((pendingJoin, lines.count - 1))
                x += joinWidth
            }
            pendingJoin = nil
            let line = lines.count - 1
            frames[index] = CGRect(origin: CGPoint(x: x, y: lines[line].y), size: size)
            lines[line].height = max(lines[line].height, size.height)
            x += size.width
            widest = max(widest, x)
        }
        for join in joins {
            frames[join.index].origin.y = lines[join.line].y + (lines[join.line].height - joinThickness) / 2
        }
        return (frames, CGSize(width: widest, height: lines.last.map { $0.y + $0.height } ?? 0))
    }
}

struct StagePill: View {
    let stage: PipelineStage
    let now: Date

    var body: some View {
        let quiet = stage.state == .pending || stage.state == .skipped || stage.state == .canceled
        // As wide as it needs, or, alone on a line narrower than that, its name cut short: the tooltip says it all.
        HStack(spacing: 5) {
            Image(systemName: stage.state.symbol)
                .font(size: 11.5, weight: .semibold)
                .foregroundStyle(stage.state.color)
            Text(stage.name)
                .font(size: 11.5, weight: .medium)
                .foregroundStyle(quiet ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let duration {
                Text(duration)
                    .font(size: 10.5).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(stage.state.color.opacity(quiet ? 0.07 : 0.13)))
        .overlay(Capsule().strokeBorder(stage.state.color.opacity(quiet ? 0.18 : 0.30), lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .help("\(stage.name): \(stage.state.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.name): \(stage.state.title)" + (stage.startedAt == nil ? "" : duration.map { ", \($0)" } ?? ""))
    }

    private var duration: String? {
        guard let start = stage.startedAt else { return stage.state == .waiting ? "Waiting" : nil }
        return RunDuration.short((stage.finishedAt ?? now).timeIntervalSince(start))
    }
}

/// Where a run failed, and the first error there.
struct FailureNote: View {
    let failure: PipelineFailure

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(size: 11)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text("\(Text(failure.step).fontWeight(.semibold))\(failure.message.map { ": " + $0 } ?? " failed")")
                .font(size: 11.5)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.08)))
    }
}
