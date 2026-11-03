import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// Under a pull request's heading, in its details: the Copilot session its work goes to, why it's its and how it stands, in
/// its state's color, "Copilot · ‘Retry backoff’ · on its branch · Finished 1d ago" (`PullRequestSessions`). A click shows
/// the session's page in the details; while it waits for your answer, it opens it in the Copilot app, where you answer it.
/// ⌄ opens it in Copilot or Terminal, and chooses another session for the pull request's work, or a new one. When two
/// sessions go with it as well as each other, it asks which, once. Without Send Work to Copilot, it shows only the sessions
/// Show Links links to it, and chooses nothing; with neither, nothing.
struct PullRequestSessionLine: View {
    let item: PRSnapshot

    @EnvironmentObject private var sessions: PullRequestSessions
    @EnvironmentObject private var services: AppServices

    var body: some View {
        if let session = sessions.session(for: item.key), PullRequestSessionLine.shows(session) {
            SessionLineContent(item: item, session: session, links: services.links)
        }
    }

    /// Whether there's anything to say: a session, a question, or, while you can choose one, that its work goes to a new
    /// session.
    static func shows(_ session: PullRequestSession) -> Bool {
        switch session.pick {
        case .session: return true
        case .ask: return true
        case .newSession: return session.canChoose
        }
    }

    /// How a session stands: what it does, in its state's color, and since when.
    struct Standing: Equatable {
        /// "Waiting for your answer", "Working", "Finished", "Busy"; empty when there's nothing more to say than when it
        /// was last active.
        var text: String
        var state: ItemState?
        var date: Date?

        /// "finished 1d ago", "working", "active 3h ago", for a sentence: with since when, unless it needs you, works or
        /// has just ended, which its state says.
        func phrase(now: Date) -> String {
            let ago = date.map { WorkItemDetailsPanel.ago($0, now: now) }
            guard !text.isEmpty else { return ago.map { "active \($0)" } ?? "" }
            let lowered = text.prefix(1).lowercased() + text.dropFirst()
            guard state == nil, let ago, text != "Busy" else { return lowered }
            return "\(lowered) \(ago)"
        }
    }

    /// How a session stands (`Standing`): as the source that lists it tells it through Show Links; a task's as BriefBar
    /// follows it; else whether the Copilot app runs a turn in it, and when it was last active. Busy, while a task of
    /// BriefBar's works in its checkout for another session.
    static func standing(of choice: SessionChoice, links: Links, entries: [CopilotTaskEntry]) -> Standing {
        if choice.isFolderBusy, !choice.isBusy { return Standing(text: "Busy", state: nil, date: nil) }
        if choice.run != nil, let entry = entries.first(where: { $0.id == choice.id }) {
            let phase = entry.status.phase
            return Standing(text: phase.title, state: phase.state, date: entry.status.since ?? entry.startedAt)
        }
        if links.isOn, let ref = ItemRef.session(choice.id), links.isDescribed(ref) {
            let item = links.describe(ref)
            if let status = item.status, !status.isEmpty {
                return Standing(text: status, state: item.state, date: item.date ?? choice.lastActive)
            }
        }
        if choice.appSession?.isRunning == true { return Standing(text: "Running", state: .running, date: choice.lastActive) }
        return Standing(text: "", state: nil, date: choice.lastActive)
    }

    /// "‘Retry backoff’ — on its branch · finished 1d ago", for a menu.
    static func menuTitle(
        of choice: SessionChoice, in session: PullRequestSession, links: Links, entries: [CopilotTaskEntry], now: Date
    ) -> String {
        let name = PullRequestSession.name(of: choice)
        // The app's sessions can have names a paragraph long.
        var title = "‘\(name.count > 60 ? String(name.prefix(59)) + "…" : name)’"
        var parts: [String] = []
        if let why = why(choice, in: session) { parts.append(why) }
        let standing = standing(of: choice, links: links, entries: entries).phrase(now: now)
        if !standing.isEmpty { parts.append(standing) }
        if choice.isOpenInApp, !choice.isUnavailable { parts.append("open in Copilot") }
        if !parts.isEmpty { title += " — " + parts.joined(separator: " · ") }
        return title
    }

    /// Why a session goes with the pull request, in a few words: why it's its, for its own; else its likeliest reason;
    /// "may have opened it" for the guess.
    static func why(_ choice: SessionChoice, in session: PullRequestSession) -> String? {
        if case .session(let picked, let basis) = session.pick, picked.id == choice.id { return basis.phrase }
        if choice.id == session.guess?.id { return "mentions it, may have opened it" }
        if choice.run != nil, choice.reasons.contains(.earlierTask) { return "an earlier task" }
        guard let best = choice.reasons.min() else { return nil }
        return best.phrase
    }

    /// The symbol of a session: a task BriefBar sent, or one of the Copilot app's.
    static func symbol(of choice: SessionChoice) -> String {
        choice.run != nil && choice.run?.isAppSession != true ? "paperplane.fill" : "waveform.path.ecg"
    }
}

/// The line, or its question, for what was found.
private struct SessionLineContent: View {
    let item: PRSnapshot
    let session: PullRequestSession
    @ObservedObject var links: Links

    var body: some View {
        switch session.pick {
        case .session(let choice, _):
            SessionLineRow(item: item, session: session, choice: choice, links: links)
        case .ask(let choices):
            if session.canChoose {
                SessionQuestion(item: item, session: session, choices: choices, links: links)
            } else {
                SessionLineRow(item: item, session: session, choice: nil, links: links)
            }
        case .newSession:
            SessionLineRow(item: item, session: session, choice: nil, links: links)
        }
    }
}

/// "Copilot · ‘Retry backoff’ · on its branch · Finished 1d ago  ⌄", in a card; or that its work goes to a new session; or,
/// without Send Work to Copilot, how many sessions Show Links links to it.
private struct SessionLineRow: View {
    let item: PRSnapshot
    let session: PullRequestSession
    /// The session it shows; nil for a new session, or several that Show Links links.
    let choice: SessionChoice?
    @ObservedObject var links: Links

    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var store: PRStore
    @Environment(\.itemNavigation) private var navigation
    @LocalState private var isHovered = false

    private var standing: PullRequestSessionLine.Standing {
        guard let choice else { return PullRequestSessionLine.Standing(text: "", state: nil, date: nil) }
        return PullRequestSessionLine.standing(of: choice, links: links, entries: copilot.entries)
    }

    /// It waits for your answer, or your approval, which only the Copilot app takes.
    private var waitsForYou: Bool { standing.state == .needsYou }

    private var name: String {
        if let choice { return "‘\(PullRequestSession.name(of: choice))’" }
        if case .ask(let choices) = session.pick { return "\(choices.count) sessions" }
        return "New session"
    }

    private var why: String? {
        if let choice { return PullRequestSessionLine.why(choice, in: session) }
        if case .ask = session.pick { return "linked to it" }
        if case .newSession(chosenByYou: true) = session.pick { return PullRequestSession.Basis.chosenByYou.phrase }
        return "none goes with it yet"
    }

    private var symbolColor: Color {
        if let state = standing.state { return state.color }
        return choice == nil ? .secondary : ComposerColors.appSession
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let open = primaryAction {
                Button(action: open.perform) {
                    label
                }
                .buttonStyle(.plain)
                .help(help + "\n" + open.help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(open.help)
                .accessibilityAddTraits(.isButton)
            } else {
                label
                    .help(help)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
            }
            PullRequestSessionMenuButton(item: item, session: session, links: links)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(GlassCard(cornerRadius: 10, isHovered: isHovered && primaryAction != nil, raised: true))
        // Waiting for your answer, in the Copilot app: orange, as what needs you is.
        .overlay {
            if waitsForYou {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ItemState.needsYou.color.opacity(isHovered ? 0.14 : 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(ItemState.needsYou.color.opacity(0.45), lineWidth: 1)
                    )
                    .allowsHitTesting(false)
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: choice.map(PullRequestSessionLine.symbol) ?? (session.canChoose ? "plus.circle" : "waveform.path.ecg"))
                .font(size: 12, weight: .semibold)
                .foregroundStyle(symbolColor)
                .frame(width: 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            // The sentence on one line where it fits; else its name, then why and how it stands, rather than a phrase
            // broken in two.
            ViewThatFits(in: .horizontal) {
                line(tail.map { head + Text(" · ").foregroundStyle(.tertiary) + $0 } ?? head)
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 1) {
                    line(head)
                    if let tail { line(tail) }
                }
            }
            .font(size: 12.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Since when, as a row says it.
            if let date = standing.date {
                Text(Elapsed.short(since: date, now: store.now))
                    .font(size: 11, weight: .medium).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(date.formatted(date: .abbreviated, time: .shortened))
            }
            if waitsForYou {
                Image(systemName: "arrow.up.forward.app")
                    .font(size: 11.5, weight: .medium)
                    .foregroundStyle(ItemState.needsYou.color)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func line(_ text: Text) -> some View {
        text.fixedSize(horizontal: false, vertical: true)
    }

    /// "Copilot · ‘Retry backoff’".
    private var head: Text {
        Text("Copilot").fontWeight(.semibold).foregroundStyle(.secondary)
            + Text("\u{00A0}· ").foregroundStyle(.tertiary)
            + Text(name).fontWeight(.medium).foregroundStyle(choice == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }

    /// "on its branch · Finished", how it stands in its state's color; wrapping only between the two, and the dot staying
    /// with the first.
    private var tail: Text? {
        var parts: [Text] = []
        if let why { parts.append(Text(Self.unbroken(why)).foregroundStyle(.secondary)) }
        let standing = standing
        if !standing.text.isEmpty {
            let color = standing.state.map { AnyShapeStyle($0.textColor) } ?? AnyShapeStyle(.secondary)
            parts.append(Text(Self.unbroken(standing.text)).fontWeight(.medium).foregroundStyle(color))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text("\u{00A0}· ").foregroundStyle(.tertiary) + $1 }
    }

    /// A few words that don't break across lines.
    private static func unbroken(_ phrase: String) -> String {
        phrase.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// What a click does: opens it in the Copilot app while it waits for you there; else shows its page in the details,
    /// while Show Links is on; else opens one of the app's sessions there.
    private var primaryAction: (perform: () -> Void, help: String)? {
        guard let choice, let ref = ItemRef.session(choice.id) else { return nil }
        let described = links.isOn && links.isDescribed(ref) ? links.describe(ref) : nil
        let opensInApp = choice.appSession != nil || choice.run?.isAppSession == true
        if waitsForYou {
            return ({ PullRequestSessionMenu.openInCopilot(choice, links: links) }, "Opens it in the Copilot app, where you answer it")
        }
        if described != nil, let navigation {
            return ({ _ = navigation.open(ref) }, "Shows its page")
        }
        if opensInApp {
            return ({ PullRequestSessionMenu.openInCopilot(choice, links: links) }, "Opens it in the Copilot app")
        }
        return nil
    }

    private var help: String {
        var lines: [String] = []
        if let choice {
            lines.append(choice.name + (choice.place.map { ", in \($0)" } ?? ""))
            let reasons = choice.reasons.map(\.phrase)
            if !reasons.isEmpty { lines.append("Goes with it: " + reasons.joined(separator: ", ")) }
            lines.append(session.canChoose
                ? "BriefBar sends this pull request's work there unless you choose another in ⌄."
                : "Linked to it by Show Links. Turn on Send Work to Copilot to send its work there.")
            if let delivery = session.delivery { lines.append(PullRequestSessionMenu.sentence(delivery)) }
        } else if case .ask(let choices) = session.pick {
            lines.append("Show Links links \(choices.count) Copilot sessions to it: ⌄ lists them.")
        } else if case .newSession(chosenByYou: true) = session.pick {
            lines.append("You chose a new session for its work: Copilot starts one, in a worktree at its latest commit.")
        } else {
            lines.append("No Copilot session goes with it yet, so its work starts a new one, in a worktree at its latest commit. Choose one in ⌄.")
        }
        return lines.joined(separator: "\n")
    }

    /// "Copilot session Retry backoff, on its branch, finished 1d ago"; "Copilot: new session, none goes with it yet".
    private var accessibilityLabel: String {
        var parts = [choice == nil ? "Copilot: " + name.lowercased() : "Copilot session " + name.trimmingCharacters(in: CharacterSet(charactersIn: "‘’"))]
        if let why { parts.append(why) }
        let phrase = standing.phrase(now: store.now)
        if !phrase.isEmpty { parts.append(phrase) }
        return parts.joined(separator: ", ")
    }
}

/// When two or more sessions go with it as well as each other, in place of the line: which is it, each with why and how it
/// stands, a click on one sending its work there from now on, as **Use for This Pull Request** does; or a new session.
private struct SessionQuestion: View {
    let item: PRSnapshot
    let session: PullRequestSession
    let choices: [SessionChoice]
    @ObservedObject var links: Links

    @EnvironmentObject private var sessions: PullRequestSessions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .font(size: 12, weight: .semibold)
                    .foregroundStyle(ComposerColors.appSession)
                    .frame(width: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Which session is this pull request's?")
                        .font(size: 12.5, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(choices.count == 2 ? "Both" : "These") Copilot sessions go with it. Its work goes to the one you choose, until you choose another.")
                        .font(size: 11.5)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PullRequestSessionMenuButton(item: item, session: session, links: links)
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    if index > 0 {
                        Divider()
                            .opacity(0.6)
                            .padding(.leading, 34)
                    }
                    QuestionRow(choice: choice, session: session, links: links) {
                        sessions.use(choice, for: item.key)
                    }
                }
                Divider()
                    .opacity(0.6)
                    .padding(.leading, 34)
                QuestionRow(choice: nil, session: session, links: links) {
                    sessions.use(nil, for: item.key)
                }
            }
            .padding(.bottom, 3)
        }
        .background(GlassCard(cornerRadius: 12, raised: true))
        .accessibilityElement(children: .contain)
    }
}

/// One of the sessions the question offers, or a new session: a click chooses it.
private struct QuestionRow: View {
    /// Nil for a new session.
    let choice: SessionChoice?
    let session: PullRequestSession
    @ObservedObject var links: Links
    let choose: () -> Void

    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var store: PRStore
    @LocalState private var isHovered = false

    private var standing: PullRequestSessionLine.Standing {
        guard let choice else { return PullRequestSessionLine.Standing(text: "", state: nil, date: nil) }
        return PullRequestSessionLine.standing(of: choice, links: links, entries: copilot.entries)
    }

    private var name: String {
        choice.map { "‘\(PullRequestSession.name(of: $0))’" } ?? "New session"
    }

    /// "on its branch · finished 2d ago", how it stands in its state's color; where a new session works.
    private var detail: Text {
        guard let choice else { return Text("In a worktree at its latest commit").foregroundStyle(.secondary) }
        var parts: [Text] = []
        if let why = PullRequestSessionLine.why(choice, in: session) { parts.append(Text(why).foregroundStyle(.secondary)) }
        // Where it works, unless that's the pull request's branch.
        if let place = choice.place, !choice.reasons.contains(.onItsBranch) { parts.append(Text(place).foregroundStyle(.secondary)) }
        let phrase = standing.phrase(now: store.now)
        if !phrase.isEmpty {
            parts.append(Text(phrase).foregroundStyle(standing.state.map { AnyShapeStyle($0.textColor) } ?? AnyShapeStyle(.secondary)))
        }
        guard let first = parts.first else { return Text("") }
        return parts.dropFirst().reduce(first) { $0 + Text(" · ").foregroundStyle(.tertiary) + $1 }
    }

    /// The same, for VoiceOver.
    private var spokenDetail: String {
        guard let choice else { return "In a worktree at its latest commit" }
        var parts = [PullRequestSessionLine.why(choice, in: session)].compactMap { $0 }
        if let place = choice.place, !choice.reasons.contains(.onItsBranch) { parts.append(place) }
        let phrase = standing.phrase(now: store.now)
        if !phrase.isEmpty { parts.append(phrase) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: choice.map(PullRequestSessionLine.symbol) ?? "plus.circle")
                    .font(size: 12, weight: .semibold)
                    .foregroundStyle(standing.state?.color ?? (choice == nil ? .secondary : ComposerColors.appSession))
                    .frame(width: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(size: 12.5, weight: .medium)
                        .fixedSize(horizontal: false, vertical: true)
                    detail
                        .font(size: 11.5)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Use")
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(isHovered ? 0.2 : 0.12)))
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
                    .padding(.horizontal, 3)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(choice == nil ? "Send its work to a new session" : "Send its work to this session from now on")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name.trimmingCharacters(in: CharacterSet(charactersIn: "‘’")), spokenDetail].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(choice == nil ? "Sends its work to a new session" : "Sends its work to this session from now on")
        .accessibilityAddTraits(.isButton)
    }
}

/// ⌄ beside the line: its menu.
private struct PullRequestSessionMenuButton: View {
    let item: PRSnapshot
    let session: PullRequestSession
    @ObservedObject var links: Links

    @Environment(\.textScale) private var scale

    var body: some View {
        Menu {
            PullRequestSessionMenu(item: item, session: session, links: links)
        } label: {
            Image(systemName: "chevron.down")
                .font(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 22 * scale, height: 22 * scale)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(session.canChoose ? "Choose where this pull request's work goes" : "Its Copilot sessions")
        .accessibilityLabel(session.canChoose ? "Choose Its Session" : "Its Copilot Sessions")
    }
}

/// What ⌄ has: the session's page, opening it in Copilot, or going on with a task's in Terminal; then, while you can
/// choose, each session that goes with the pull request, with why and how it stands, **Use for This Pull Request** checking
/// the one its work goes to, the app's other sessions, and a new session; and going back to BriefBar's choice. Without Send
/// Work to Copilot, the other sessions Show Links links to it, to open. For a pull request's line, and for whatever else
/// says where its work goes.
struct PullRequestSessionMenu: View {
    let item: PRSnapshot
    let session: PullRequestSession
    @ObservedObject var links: Links

    @EnvironmentObject private var sessions: PullRequestSessions
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var store: PRStore
    @Environment(\.itemNavigation) private var navigation

    var body: some View {
        if let choice = session.session {
            // How work would get there, first, as the line's tooltip says it.
            if session.canChoose, let delivery = session.delivery {
                Text(Self.summary(delivery))
            }
            actions(for: choice)
        }
        if session.canChoose {
            Divider()
            Section("Use for This Pull Request") {
                ForEach(listed) { choice in
                    sessionItem(choice)
                }
                if !session.others.isEmpty {
                    Menu("Other Copilot Sessions") {
                        ForEach(session.others) { choice in
                            sessionItem(choice)
                        }
                    }
                }
                Button {
                    sessions.use(nil, for: item.key)
                } label: {
                    CheckedMenuLabel(title: "New Session — in a worktree at its latest commit", isChecked: session.pick == .newSession(chosenByYou: true))
                }
            }
            if copilot.settings.chosenSession(for: item.key) != nil {
                Divider()
                Button("Let BriefBar Choose") { sessions.letBriefBarChoose(for: item.key) }
            }
        } else {
            let others = session.candidates.filter { $0.id != session.session?.id }
            if !others.isEmpty, session.session != nil { Divider() }
            ForEach(others) { choice in
                Menu(title(choice)) {
                    actions(for: choice)
                }
            }
        }
    }

    /// The sessions that go with it, then the guess, which only mentions it.
    private var listed: [SessionChoice] {
        var listed = session.candidates
        if let guess = session.guess, !listed.contains(where: { $0.id == guess.id }) { listed.append(guess) }
        return listed
    }

    private func title(_ choice: SessionChoice) -> String {
        PullRequestSessionLine.menuTitle(of: choice, in: session, links: links, entries: copilot.entries, now: store.now)
    }

    private func sessionItem(_ choice: SessionChoice) -> some View {
        Button {
            sessions.use(choice, for: item.key)
        } label: {
            CheckedMenuLabel(title: title(choice), isChecked: session.session?.id == choice.id && !isAsking)
        }
    }

    private var isAsking: Bool {
        if case .ask = session.pick { return true }
        return false
    }

    /// Its page, while Show Links is on; and opening it in the Copilot app, or, for a task BriefBar runs with the Copilot
    /// CLI, going on with it in Terminal, not while Copilot works in it.
    @ViewBuilder
    private func actions(for choice: SessionChoice) -> some View {
        if links.isOn, let ref = ItemRef.session(choice.id), links.isDescribed(ref), let navigation {
            Button("Show Details") { _ = navigation.open(ref) }
        }
        if let run = choice.run, run.isAppSession != true {
            let entry = copilot.entries.first { $0.id == run.id }
            Button("Continue in Terminal") {
                if let entry { copilot.continueInTerminal(entry) }
            }
            // Not while Copilot works in it, or in its checkout for another task, as the line says Busy then.
            .disabled(entry == nil || entry?.status.phase.isActive == true || choice.isUnavailable || !copilot.canSend)
        } else {
            Button("Open in Copilot") { Self.openInCopilot(choice, links: links) }
                .disabled(choice.isBusy)
        }
    }

    /// Opens a session in the Copilot app: as Copilot's list opens it, while it lists it, where its question is answered;
    /// else by its link.
    static func openInCopilot(_ choice: SessionChoice, links: Links) {
        if let ref = ItemRef.session(choice.id), links.isOn, links.isDescribed(ref), let open = links.describe(ref).open {
            open()
        } else {
            CopilotTasksStore.openInAppOrSay(choice.id)
        }
    }

    /// How work would reach a session, in a sentence.
    static func sentence(_ delivery: PullRequestSession.Delivery) -> String {
        switch delivery {
        case .cli: return "Work goes to it with the Copilot CLI, which goes on with it on its own."
        case .app(let reach, let reason):
            var parts: [String] = []
            switch reach {
            case .listening?: parts.append("Work goes to it in the Copilot app, where BriefBar's extension sends it the prompt, as yours.")
            case .loads?: parts.append("Work goes to it in the Copilot app, which loads it, and BriefBar's extension then sends it the prompt, as yours.")
            case nil: parts.append("Work goes to it in the Copilot app.")
            case .noListener?, .notInApp?, .off?: parts.append("Work opens it in the Copilot app, with the prompt copied for you to paste.")
            }
            if let why = reach?.whyNot(forking: false) { parts.append(why) }
            if let reason { parts.append(reason) }
            return parts.joined(separator: " ")
        case .busy(let reason): return "Busy: \(reason) Nothing more goes to it until then."
        case .unavailable(let reason): return "Work can't go to it now: \(reason)"
        }
    }

    /// The same, briefly, for the first line of its menu: "Work goes to it with the Copilot CLI".
    static func summary(_ delivery: PullRequestSession.Delivery) -> String {
        switch delivery {
        case .cli: return "Work goes to it with the Copilot CLI"
        case .app(let reach, _):
            switch reach {
            case .listening?: return "Work goes to it in Copilot: BriefBar sends the prompt"
            case .loads?: return "Work goes to it in Copilot: BriefBar sends the prompt once it loads"
            case nil: return "Work goes to it in the Copilot app"
            case .noListener?, .notInApp?, .off?: return "Work opens it in Copilot, with the prompt to paste"
            }
        case .busy(let reason):
            return "Busy: " + (reason.hasSuffix(".") ? String(reason.dropLast()) : reason)
        case .unavailable: return "Work can't go to it now"
        }
    }
}
