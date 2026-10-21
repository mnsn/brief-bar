import AppKit
import AzureDevOpsCore
import BriefBarCore
import SwiftUI

// Colors and symbols for the Sprint and Pipelines pages, and the small pieces they share with the Pull
// Requests page: avatars, chips and rings. The cards and the window's look are BriefBar's (WindowStyle).

/// Azure DevOps' three sections, as pages in a window, parts of a widget, or popovers.
enum AzureDevOpsPage: String, CaseIterable {
    case pullRequests, sprint, pipelines

    init?(_ section: SectionID) {
        guard let page = Self.allCases.first(where: { $0.section == section }) else { return nil }
        self = page
    }

    var section: SectionID {
        switch self {
        case .pullRequests: return .azureDevOpsPullRequests
        case .sprint: return .azureDevOpsSprint
        case .pipelines: return .azureDevOpsPipelines
        }
    }

    var title: String {
        switch self {
        case .pullRequests: return "Pull Requests"
        case .sprint: return "Sprint"
        case .pipelines: return "Pipelines"
        }
    }

    var symbol: String {
        switch self {
        case .pullRequests: return "arrow.triangle.pull"
        case .sprint: return "rectangle.split.3x1.fill"
        case .pipelines: return "point.3.connected.trianglepath.dotted"
        }
    }

    /// The tile behind the page's symbol in a window's sidebar.
    var color: Color {
        switch self {
        case .pullRequests: return Color(red: 0.33, green: 0.45, blue: 0.96)
        case .sprint: return Color(red: 0.13, green: 0.66, blue: 0.58)
        case .pipelines: return Color(red: 0.58, green: 0.38, blue: 0.94)
        }
    }
}

extension SprintBoard.Column {
    var title: String {
        switch self {
        case .toDo: return "To Do"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        }
    }

    var color: Color {
        switch self {
        case .toDo: return Color(nsColor: .systemGray)
        case .inProgress: return .blue
        case .done: return .green
        }
    }

    var symbol: String {
        switch self {
        case .toDo: return "circle.dashed"
        case .inProgress: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        }
    }
}

extension WorkItem {
    /// The state's color: the column's, and orange for resolved, as Azure DevOps does.
    var stateColor: Color {
        category == .resolved ? .orange : (category.column ?? .toDo).color
    }

    var stateSymbol: String {
        category == .resolved ? "checkmark.circle" : (category.column ?? .toDo).symbol
    }

    /// The type's color, close to Azure DevOps's own, so cards are recognizable at a glance.
    var typeColor: Color {
        switch type.lowercased() {
        case "bug": return Color(red: 0.84, green: 0.20, blue: 0.25)
        case "task": return Color(red: 0.95, green: 0.72, blue: 0.10)
        case "feature": return Color(red: 0.55, green: 0.30, blue: 0.75)
        case "epic": return Color(red: 1.0, green: 0.50, blue: 0.0)
        case "issue", "impediment": return Color(red: 0.70, green: 0.30, blue: 0.60)
        default: return Color(red: 0.0, green: 0.60, blue: 0.82)
        }
    }

    var typeSymbol: String {
        switch type.lowercased() {
        case "bug": return "ladybug.fill"
        case "task": return "checklist"
        case "feature": return "trophy.fill"
        case "epic": return "crown.fill"
        case "user story", "product backlog item", "requirement": return "book.pages.fill"
        default: return "doc.text.fill"
        }
    }

    /// "3h", "1.5h".
    var remainingText: String? {
        guard let hours = remainingWork, hours > 0, !isDone else { return nil }
        return hours.rounded() == hours ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }
}

/// Hours of work: "22 h", "1.5 h".
enum Hours {
    static func text(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value)) h" : String(format: "%.1f h", value)
    }
}

extension PipelineRun.Status {
    var title: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .partiallySucceeded: return "Succeeded with issues"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }

    var color: Color {
        switch self {
        case .queued: return Color(nsColor: .systemGray)
        case .running: return .blue
        case .succeeded: return .green
        case .partiallySucceeded: return .orange
        case .failed: return .red
        case .canceled: return Color(nsColor: .systemGray)
        }
    }

    /// Drawn white on a circle of the status's color.
    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark"
        case .partiallySucceeded: return "exclamationmark"
        case .failed: return "xmark"
        case .canceled: return "slash.circle"
        }
    }
}

extension PipelineStage.State {
    var color: Color {
        switch self {
        case .pending, .skipped, .canceled: return Color(nsColor: .systemGray)
        case .waiting: return .orange
        case .running: return .blue
        case .succeeded: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }

    var symbol: String {
        switch self {
        case .pending: return "circle"
        case .waiting: return "hand.raised.circle.fill"
        case .running: return "circle.dotted.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .canceled: return "slash.circle"
        case .skipped: return "minus.circle"
        }
    }

    var title: String {
        switch self {
        case .pending: return "Not started"
        case .waiting: return "Waiting for approval"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .warning: return "Succeeded with issues"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        case .skipped: return "Skipped"
        }
    }
}

extension PipelineStatus {
    var color: Color { latest?.status.color ?? Color(nsColor: .systemGray) }

    /// The headline's color: the status's, but orange while a stage waits for approval.
    var headlineColor: Color {
        latest?.status == .running && stages.contains(where: { $0.state == .waiting }) && !stages.contains(where: { $0.state == .running })
            ? .orange : color
    }
}

/// A person's initials on a circle of a color that's always the same for them; a dashed circle for nobody.
struct Avatar: View {
    let name: String?
    var size: CGFloat = 20
    /// Rings the avatar in the accent color: it's you.
    var isMe = false

    private static let palette: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 0.98), Color(red: 0.62, green: 0.42, blue: 0.95), Color(red: 0.93, green: 0.40, blue: 0.62),
        Color(red: 0.97, green: 0.56, blue: 0.27), Color(red: 0.20, green: 0.70, blue: 0.68), Color(red: 0.35, green: 0.70, blue: 0.40),
        Color(red: 0.48, green: 0.50, blue: 0.85), Color(red: 0.80, green: 0.50, blue: 0.30),
    ]

    var body: some View {
        ZStack {
            if let name, !name.isEmpty {
                Circle().fill(Self.color(for: name).gradient)
                Text(Self.initials(name))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if isMe {
                Circle().strokeBorder(Color.accentColor, lineWidth: 1.5).padding(-2.5)
            }
        }
        .help(name ?? "Unassigned")
        .accessibilityLabel(name ?? "Unassigned")
    }

    /// "SR" for "Sam Rivera" and "Rivera, Sam"; parts that aren't words, such as "(Contractor)", don't count.
    static func initials(_ name: String) -> String {
        var words: [Substring]
        if let comma = name.firstIndex(of: ",") {
            words = name[name.index(after: comma)...].split(separator: " ") + name[..<comma].split(separator: " ")
        } else {
            words = name.split(separator: " ")
        }
        words = words.filter { $0.first?.isLetter == true }
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return String(letters).uppercased()
    }

    /// The same color for the same name, every time (Swift's `hashValue` changes between launches).
    static func color(for name: String) -> Color {
        let sum = name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return palette[Int(sum % UInt32(palette.count))]
    }
}

/// A small capsule of text, tinted.
struct Chip: View {
    let text: String
    var color: Color = .secondary
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

/// A thin bar showing how much of something is done.
struct ProgressCapsule: View {
    let value: Double
    var color: Color = .accentColor
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(value > 0 ? height : 0, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Done, in progress and to do, side by side in one bar, each as long as its share.
struct SegmentedProgress: View {
    let done: Int
    let inProgress: Int
    let toDo: Int
    var height: CGFloat = 5

    var body: some View {
        let total = max(done + inProgress + toDo, 1)
        GeometryReader { geometry in
            let parts = [(done, SprintBoard.Column.done.color), (inProgress, SprintBoard.Column.inProgress.color)]
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if part.0 > 0 {
                        Capsule()
                            .fill(part.1.gradient)
                            .frame(width: max(height, (geometry.size.width - 4) * CGFloat(part.0) / CGFloat(total)))
                    }
                }
                Capsule()
                    .fill(Color.primary.opacity(0.10))
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) done, \(inProgress) in progress, \(toDo) to do")
    }
}

/// A ring that fills clockwise from the top, with something in the middle.
struct ProgressRing<Label: View>: View {
    let value: Double
    let colors: [Color]
    var size: CGFloat = 58
    var lineWidth: CGFloat = 7
    @ViewBuilder var label: () -> Label

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.09), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0.001), 1))
                .stroke(
                    AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(value, 0.05))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            label()
        }
        .frame(width: size, height: size)
    }
}

/// A work item's type, as a colored circle with its glyph.
struct TypeBadge: View {
    let item: WorkItem
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().fill(item.typeColor.gradient)
            Image(systemName: item.typeSymbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .help(item.type)
        .accessibilityLabel(item.type)
    }
}
