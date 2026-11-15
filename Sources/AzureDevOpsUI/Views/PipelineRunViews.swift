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

/// A run's stages, in order, joined by lines, on as many lines as they need, rather than cut off at the card's edge: a
/// line that goes on to the next ends with its join.
struct StageFlow: View {
    let stages: [PipelineStage]
    let now: Date

    var body: some View {
        FlowLayout(spacing: 0, lineSpacing: 6) {
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                HStack(spacing: 0) {
                    StagePill(stage: stage, now: now)
                    if index < stages.count - 1 {
                        Rectangle()
                            .fill(stage.state == .succeeded ? Color.green.opacity(0.5) : Color.primary.opacity(0.15))
                            .frame(width: 14, height: 1.5)
                    }
                }
            }
        }
        .padding(.vertical, 1)
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
