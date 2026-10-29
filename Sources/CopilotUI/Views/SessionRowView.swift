import BriefBarCore
import BriefBarUI
import CopilotCore
import SwiftUI

/// One session: status icon, name, state line, optional detail, how long it's been in that state, and,
/// if turned on, how full its context window is. A task BriefBar sent to the Copilot CLI has ✈︎ before its name, opens
/// what it's for, and has its own menu. With Nest Sessions Under Their Parents, a session is indented under the one
/// that started it, or, where it isn't, has a ↳ tag that names that session and opens it.
struct SessionRowView: View {
    let session: SessionSnapshot
    let now: Date
    var compact = false
    /// Whether the list shows sessions nested under the sessions that started them: not one that mixes sources.
    var nests = true
    var action: () -> Void

    /// How far each level of nesting indents a row, and how many levels it goes at most.
    static let indentStep: CGFloat = 16
    static let maxIndentLevels = 3

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: SessionStore
    @LocalState private var isHovered = false
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        let task = store.task(for: session.id)
        Button(action: action) {
            HStack(alignment: .top, spacing: options.readableRows ? 10 : 9) {
                Image(systemName: session.rowSymbol)
                    .font(.system(size: compact ? 15 : 17))
                    .foregroundStyle(session.rowColor)
                    .frame(width: options.rowIconWidth, height: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if task != nil {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        Text(session.displayName)
                            .font(.system(size: 13, weight: session.phase == .idle ? .regular : .semibold))
                            .foregroundStyle(session.phase == .idle ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        if let contextUsage {
                            ContextUsageView(usage: contextUsage)
                        }
                        Text(Elapsed.short(since: session.since, now: now))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if compact {
                        if let taggedParent {
                            // With the detail if both fit, or else instead of it, the tag's name cut short if need be.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) {
                                    compactText(compactLine)
                                    parentTag(taggedParent)
                                }
                                HStack(spacing: 6) {
                                    compactText(session.headline)
                                        .layoutPriority(1)
                                    parentTag(taggedParent, truncates: true)
                                }
                            }
                        } else {
                            compactText(compactLine)
                        }
                    } else {
                        if let taggedParent {
                            // On the status line if it fits there in full, or else on a line of its own.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) {
                                    subtitle
                                    parentTag(taggedParent)
                                    links
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        subtitle
                                        links
                                    }
                                    parentTag(taggedParent)
                                }
                            }
                        } else {
                            HStack(spacing: 6) {
                                subtitle
                                links
                            }
                        }
                        if let detail = session.detail {
                            Text(detail)
                                .font(.system(size: options.rowDetailSize))
                                .foregroundStyle(.secondary)
                                .lineLimit(session.phase == .needsYou ? 3 : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 5 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, indent)
        .onHover { isHovered = $0 }
        .contextMenu {
            if let task {
                Button(task.openTitle, action: action)
                task.menu()
            } else if session.answerIn != nil {
                Button(openTitle(task), action: action)
                Button("Open This Session") { store.openItself(session) }
            } else {
                Button("Open in GitHub Copilot", action: action)
            }
            if let parent = otherParent {
                Button("Open “\(parent.name)”") { store.openParent(of: session) }
            }
            if let ref = ItemRef.session(session.id) {
                LinkMenuItems(ref)
            }
        }
        .help(helpText(task))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.displayName), \(session.headline)")
        .accessibilityValue(
            [session.detail, contextUsage.map(ContextUsageView.description), otherParent.map { "Started by “\($0.name)”" }]
                .compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityHint(
            task.map { "Opens its \($0.opens.lowercased())" }
                ?? session.answerIn.map { "Opens “\($0.name)”, where you answer it" }
                ?? "Opens the session in GitHub Copilot"
        )
        .accessibilityActions {
            if let parent = otherParent {
                Button("Open “\(parent.name)”") { store.openParent(of: session) }
            }
        }
        .rowActions(for: session.displayName, openTitle: openTitle(task), open: action) {
            if let task {
                task.menu()
            } else if session.answerIn != nil {
                Button("Open This Session") { store.openItself(session) }
            }
            if let parent = otherParent {
                Button("Open “\(parent.name)”") { store.openParent(of: session) }
            }
            if let ref = ItemRef.session(session.id) {
                LinkMenuItems(ref)
            }
        }
    }

    /// How far it's indented under the session that started it, where the list nests it.
    private var indent: CGFloat {
        nests ? CGFloat(min(session.depth, Self.maxIndentLevels)) * Self.indentStep : 0
    }

    /// What it's doing and where, colored by its state.
    private var subtitle: some View {
        Text(session.subtitle)
            .font(.system(size: options.rowReasonSize, weight: .medium))
            .foregroundStyle(options.quietAppearance || session.phase == .idle ? Color.secondary : session.rowColor)
            .lineLimit(1)
    }

    /// What Show Links links it to.
    @ViewBuilder
    private var links: some View {
        if let ref = ItemRef.session(session.id) {
            LinkCapsules(ref)
        }
    }

    private func compactText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: options.rowDetailSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func parentTag(_ parent: RelatedSession, truncates: Bool = false) -> some View {
        ParentTag(parent: parent, truncates: truncates) { store.openParent(of: session) }
    }

    /// The session that started it, unless that's where you answer its question, which the row names and opens already.
    private var otherParent: RelatedSession? {
        guard let parent = session.parent, parent.id != session.answerIn?.id else { return nil }
        return parent
    }

    /// The session that started it, as a ↳ tag, where the list doesn't show the row under it: in another group, or in a
    /// list that mixes sources.
    private var taggedParent: RelatedSession? {
        guard let parent = otherParent, !nests || session.depth == 0 else { return nil }
        return parent
    }

    /// What clicking the row does: open the task's page, or the session where you answer what it waits on.
    private func openTitle(_ task: SentTask?) -> String {
        if let task { return task.openTitle }
        if let answerIn = session.answerIn { return "Answer in “\(answerIn.name)”" }
        return "Open in Copilot"
    }

    /// The session's context usage, when the setting is on and the app has measured it.
    private var contextUsage: ContextUsage? {
        settings.showContextUsage ? session.contextUsage : nil
    }

    private var compactLine: String {
        guard let detail = session.detail else { return session.subtitle }
        return "\(session.headline) · \(detail)"
    }

    private func helpText(_ task: SentTask?) -> String {
        var lines = [session.displayName, session.subtitle]
        if let detail = session.detail { lines.append(detail) }
        if !session.choices.isEmpty { lines.append("Options: " + session.choices.joined(separator: " | ")) }
        if let contextUsage { lines.append(ContextUsageView.description(contextUsage)) }
        if let parent = otherParent {
            lines.append("Started by “\(parent.name)”" + (taggedParent == nil ? "" : ", which its ↳ tag opens"))
        }
        if let task {
            lines.append("Sent from BriefBar: the Copilot CLI works on it on its own, outside the Copilot app")
            lines.append("Click to open its \(task.opens.lowercased()), or right-click for its menu")
        } else if let answerIn = session.answerIn {
            lines.append("“\(answerIn.name)”, which coordinates it, asks you this for it")
            lines.append("Click to answer in “\(answerIn.name)”, or right-click to open this session")
        } else {
            if !session.asksFor.isEmpty {
                let names = ListFormatter.localizedString(byJoining: session.asksFor.map { "“\($0.name)”" })
                lines.append("Asks you for \(names), which it coordinates")
            }
            lines.append("Click to open in GitHub Copilot")
        }
        return lines.joined(separator: "\n")
    }
}

/// The session that started a session, as a small tag on the session's row: ↳ and its name, which opens it.
struct ParentTag: View {
    let parent: RelatedSession
    /// Whether its name is cut short to fit, as far as needed, rather than kept to its full width.
    var truncates = false
    let open: () -> Void

    /// The longest name it shows in full; its tooltip has all of it.
    static let nameLimit = 24

    var body: some View {
        Button(action: open) {
            Text(verbatim: "↳ " + Self.shortName(parent.name))
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.secondary.opacity(0.14)))
                .contentShape(Capsule())
                .fixedSize(horizontal: !truncates, vertical: true)
        }
        .buttonStyle(.plain)
        .help("Started by “\(parent.name)”: click to open it")
    }

    static func shortName(_ name: String) -> String {
        guard name.count > nameLimit else { return name }
        return String(name.prefix(nameLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// How full a session's context window is: a ring and a percentage. It turns orange as the
/// conversation nears the size at which Copilot compacts it (about 80% of the window).
struct ContextUsageView: View {
    let usage: ContextUsage

    static let warningFraction = 0.7

    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: usage.fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 9, height: 9)
            Text("\(usage.percent)%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(color)
        }
        .fixedSize()
    }

    private var color: Color {
        usage.fraction >= Self.warningFraction ? .orange : .secondary
    }

    static func description(_ usage: ContextUsage) -> String {
        let tokens = usage.tokens.formatted(.number.notation(.compactName))
        let limit = usage.limit.formatted(.number.notation(.compactName))
        return "Context: \(usage.percent)% full (\(tokens) of \(limit) tokens)"
    }
}

/// Small "icon count" chips for the non-empty phases.
struct CountChips: View {
    let counts: PhaseCounts
    var phases: [DisplayPhase] = [.needsYou, .running, .done, .stopped]
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        if options.clearerStates {
            AttentionSummary(states: counts.states)
        } else {
            HStack(spacing: 8) {
                ForEach(phases, id: \.self) { phase in
                    if counts[phase] > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: phase.symbol)
                                .foregroundStyle(phase.color)
                            Text("\(counts[phase])")
                                .monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .help("\(counts[phase]) \(phase.title.lowercased())")
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
