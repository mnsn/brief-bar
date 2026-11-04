import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

// What asks Copilot about something of a pull request, a comment thread, a build or its conflicts, while Send Work to Copilot
// is on, built to be shared by each: the names of the sessions it goes to, what Copilot does about it in a sentence, which
// composer is open, what a session explained, the composer in place itself, where it goes, and the bar at the details' foot
// once fixes are done.

/// The names of the sessions Copilot's work on a pull request goes to, for its sentences and menus: as the pull request's
/// session line knows them, as BriefBar's tasks are called, or as Show Links names them.
@MainActor
struct CopilotSessionNames {
    let session: PullRequestSession?
    let copilot: CopilotTasksStore
    let links: Links

    /// A session the pull request's line knows, by its ID.
    func choice(_ id: String) -> SessionChoice? {
        guard let session else { return nil }
        if session.session?.id == id { return session.session }
        return (session.candidates + [session.guess].compactMap { $0 } + session.others).first { $0.id == id }
    }

    /// "Retry backoff", "Fix Comments"; nil when BriefBar doesn't know it.
    func name(_ id: String) -> String? {
        if let choice = choice(id) { return PullRequestSession.name(of: choice) }
        if let entry = copilot.entries.first(where: { $0.id == id }) {
            if let action = entry.action { return action.title }
            if let workItem = entry.workItem { return "Work Item \(workItem.id)" }
        }
        if links.isOn, let ref = ItemRef.session(id), links.isDescribed(ref) { return links.describe(ref).title }
        return nil
    }

    func sentence(_ work: CopilotWork) -> String {
        work.sentence(name: name(work.session), forkOf: work.forkedFrom.flatMap(name))
    }

    /// Where a session is, in a sentence's middle, by its ID: "‘Retry backoff’"; a task of BriefBar's as one, "the ‘Fix the
    /// Build’ task"; "its session" when BriefBar doesn't know it.
    func place(_ id: String) -> String {
        CopilotWork.place(name(id), isFork: false, forkOf: nil, isTask: isTask(id))
    }

    /// Where fixes are, in a sentence's middle: in a session, "‘Retry backoff’", or a fork of one, "a fork of the ‘Fix the
    /// Build’ task".
    func place(of fixes: ReadyFixes) -> String {
        CopilotWork.place(name(fixes.session), isFork: fixes.forkedFrom != nil, forkOf: fixes.forkedFrom.flatMap(name), isTask: fixes.isTask)
    }

    /// What VoiceOver hears as Copilot's work on something ends: its sentence, and the first line of what Copilot said.
    func announcement(_ work: CopilotWork) -> String {
        let sentence = SpokenText.unquoted(sentence(work))
        guard let said = CopilotTasksStore.firstLine(work.said) else { return sentence }
        return "\(sentence). \(said)"
    }

    /// What a click on a session's line does: shows its page in the details while Show Links describes it; opens one of the
    /// Copilot app's sessions in the app. Nothing for a task BriefBar runs with the CLI, which its task's row goes on with.
    func opener(_ id: String, isTask: Bool, navigation: ItemNavigation?) -> (perform: () -> Void, help: String)? {
        guard let ref = ItemRef.session(id) else { return nil }
        if links.isOn, links.isDescribed(ref), let navigation { return ({ _ = navigation.open(ref) }, "Shows its session's page") }
        if !isTask { return ({ CopilotTasksStore.openInAppOrSay(id) }, "Opens its session in the Copilot app") }
        return nil
    }

    /// A session to start the Send to Copilot window with: as the line knows it, or as BriefBar keeps its task.
    func start(_ id: String) -> SessionChoice? {
        if let choice = choice(id) { return choice }
        guard let entry = copilot.entries.first(where: { $0.id == id }), let run = entry.run else { return nil }
        return SessionChoice(
            kind: .task(run), name: copilot.name(of: entry), place: run.onPullRequest?.repository, lastActive: entry.status.since ?? entry.startedAt,
            reasons: [.earlierTask]
        )
    }

    /// Whether a session is a task BriefBar runs with the Copilot CLI, which its task's row goes on with.
    func isTask(_ id: String) -> Bool {
        copilot.entries.contains { $0.id == id && $0.run?.isAppSession != true }
    }
}

extension CopilotWork {
    /// Its symbol, and its state's color: working, done, failing, or yours, as when its session asks you something.
    var look: (symbol: String, state: ItemState?) {
        switch state {
        case .waiting(copied: true): ("doc.on.clipboard", .needsYou)
        case .waiting(copied: false): ("paperplane", .running)
        case .working: (purpose == .explain ? "sparkles" : purpose == .pushAndReply ? "arrow.up.circle" : "arrow.triangle.2.circlepath", .running)
        case .needsYou: ("questionmark.circle.fill", .needsYou)
        case .done: ("checkmark.circle.fill", .done)
        case .failed: ("exclamationmark.triangle.fill", .failing)
        case .stopped: ("stop.circle", nil)
        case .unknown(let copied): (copied ? "doc.on.clipboard" : "paperplane", nil)
        }
    }

    /// The step it's at, under its sentence, while Copilot says.
    var step: String? {
        if case .working(let step) = state { return step }
        return nil
    }

    /// What Copilot said when it ended, under its line: what it did, or why it couldn't.
    var said: String? {
        switch state {
        case .done(let summary): summary
        case .failed(let reason): reason
        case .waiting, .working, .needsYou, .stopped, .unknown: nil
        }
    }

    /// Copilot is at it, or waits for you, rather than done with it.
    static func isOngoing(_ state: State) -> Bool {
        switch state {
        case .waiting, .working, .needsYou: true
        case .done, .failed, .stopped, .unknown: false
        }
    }
}

extension CopilotQuestions.Question {
    /// What the session answered, once it did, for a fix or another question to build on.
    var answer: CopilotAnswer? {
        if case .answered(let text) = state { return CopilotAnswer(question: asked, answer: text) }
        return nil
    }
}

extension SpokenText {
    /// Says it to VoiceOver, wherever the keyboard is, as what you asked Copilot ends.
    static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

extension Check {
    /// The build it is, for what Copilot takes on: by the pipeline it runs; nil for another check, or a build whose policy
    /// doesn't say its pipeline.
    var part: PullRequestPart? {
        guard kind == .build, let definitionId else { return nil }
        return .build(definitionId)
    }
}

extension PRRecord {
    /// What of it is still to fix, for fixes done and not pushed to count: its open threads, the builds that don't pass,
    /// and its conflicts while it has them. A build that passes, as when it ran again or after a push, needs no fix.
    var partsToFix: [PullRequestPart] {
        var parts = (details?.threads ?? []).filter { !$0.isResolved }.map { PullRequestPart.thread($0.id) }
        for check in details?.checks ?? [] {
            // One that failed, then expired, is still to fix (`Check.needsNoFix`). Another policy that runs the same
            // pipeline may pass while this one doesn't: one that doesn't is enough.
            guard let part = check.part, !parts.contains(part), !check.needsNoFix else { continue }
            parts.append(part)
        }
        if pullRequest.hasConflicts { parts.append(.conflicts) }
        return parts
    }
}

extension PullRequestDetailsStore.Place {
    /// Where something of a pull request is in its details: a thread; the row of the build that runs a pipeline, which
    /// opens; or its merge conflicts, which their top stands for once it has none (`anchor(in:files:)`).
    static func of(_ part: PullRequestPart, in panel: PullRequestPanel) -> Self {
        switch part {
        case .thread(let id): .thread(id)
        case .build(let pipeline): panel.checks.first { $0.check?.part == .build(pipeline) }.map(Self.of) ?? .section(.checks)
        case .conflicts: .section(.conflicts)
        }
    }
}

extension PullRequestAction {
    /// What a fix sent for it doesn't do, for its composer's note: "no commit, push or reply"; for conflicts, what it may
    /// do, and what's left for Push & Reply.
    var leavesOut: String {
        switch self {
        case .fixComments: "no commit, push or reply"
        case .fixBuild: "no commit, push or pipeline change"
        case .resolveConflicts: "it may commit the merge, but only Push & Reply pushes it"
        case .review: "no change"
        case .pushAndReply: "nothing else"
        }
    }
}

// MARK: - Which composer is open

/// Which composer in place is open in a part of a pull request's details: one at a time, so Esc, Return and the keyboard's
/// focus are its own.
struct CopilotComposing: Hashable {
    /// What it's about; nil for Fix All.
    var part: PullRequestPart?
    var ask: CopilotAsk
    /// Which row it's on, where more than one is about the same part: a build's, since two of a pull request's policies can
    /// run the same pipeline, and each has its own composer, words and send, though Copilot's work is the pipeline's.
    var row: String?

    static let fixAll = CopilotComposing(part: nil, ask: .fixAll)
}

/// What you wrote in each composer in place in a part of a pull request's details, kept as you open another, until you send
/// it; and what each sends, until it's done. Not observed: what you type redraws its own composer only.
@MainActor
final class CopilotDrafts {
    var texts: [CopilotComposing: String] = [:]
    /// What a composer sends, until it's done: called off as it closes or another opens (`callOff`), and as its page goes
    /// (`callOffAll`), when a prompt no session took yet is taken back; not as its card scrolls out of sight, as a lazy
    /// stack's do.
    var sends: [CopilotComposing: Task<Void, Never>] = [:]
    /// What asks a session about something as a prompt, Ask in the Session's, until it's done: called off as its page goes.
    var asks = Asks()

    /// What asks a session about something as a prompt, by what it's about, and, where more than one row is about it, as two
    /// policies' runs of a pipeline are, the row it's on (`CopilotComposing.row`): `asks[part]`, `asks[part, row: id]`.
    struct Asks {
        private struct Key: Hashable {
            var part: PullRequestPart
            var row: String?
        }

        private var tasks: [Key: Task<Void, Never>] = [:]

        subscript(part: PullRequestPart, row row: String? = nil) -> Task<Void, Never>? {
            get { tasks[Key(part: part, row: row)] }
            set { tasks[Key(part: part, row: row)] = newValue }
        }

        var all: [Task<Void, Never>] { Array(tasks.values) }
    }

    func callOff(_ composer: CopilotComposing) {
        sends.removeValue(forKey: composer)?.cancel()
    }

    func callOffAll() {
        for task in Array(sends.values) + asks.all { task.cancel() }
        sends = [:]
        asks = Asks()
    }
}

// MARK: - What a session explained

/// What a session said with Explain, under what it's about, as BriefBar shows what a model wrote: "Answer from
/// ‘Retry backoff’ · 2m ago", what you asked, the answer in full, formatted as Copilot wrote it, Copy, ↗ to the session,
/// and ✕ to dismiss it. Ask More and Fix, under it, build on it.
struct CopilotAnswerCard: View {
    let answer: String
    let asked: String?
    /// "‘Retry backoff’".
    let place: String
    let answeredAt: Date
    let now: Date
    let open: (perform: () -> Void, help: String)?
    let dismiss: () -> Void

    @Environment(\.textScale) private var textScale
    @Environment(\.interfaceOptions) private var options

    /// What you asked, when you asked something.
    private var question: String? {
        guard let asked = asked?.trimmingCharacters(in: .whitespacesAndNewlines), !asked.isEmpty else { return nil }
        return asked
    }

    var body: some View {
        let colorful = !options.quietAppearance
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(colorful ? AnyShapeStyle(BriefContainer<EmptyView>.gradient) : AnyShapeStyle(Color.secondary))
                    .accessibilityHidden(true)
                // Whole, wrapping beside the buttons when it must, the time never cut short.
                Text("Answer from \(place) · \(WorkItemDetailsPanel.ago(answeredAt, now: now))")
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Answer from \(SpokenText.unquoted(place)), \(WorkItemDetailsPanel.ago(answeredAt, now: now))")
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                iconButton("doc.on.doc", help: "Copy the answer", label: "Copy the Answer") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                    SpokenText.announce("Copied the answer")
                }
                if let open {
                    iconButton("arrow.up.forward.app", help: open.help, label: "Open Its Session", action: open.perform)
                }
                iconButton("xmark", size: 9.5, weight: .semibold, help: "Dismiss the answer", label: "Dismiss the Answer", action: dismiss)
            }
            .frame(minHeight: 18 * textScale)
            if let question {
                Text("You asked: \(question)")
                    .font(size: 11.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Parsed once for what it says, as a comment is.
            CommentBody(markdown: answer, isQuiet: false)
                .equatable()
            Text("Asked aside: the session's history didn't change.")
                .font(size: 10.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorful ? AnyShapeStyle(BriefContainer<EmptyView>.gradient.opacity(0.07)) : AnyShapeStyle(Color.primary.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(colorful ? AnyShapeStyle(BriefContainer<EmptyView>.gradient.opacity(0.28)) : AnyShapeStyle(Color.primary.opacity(0.1)), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func iconButton(
        _ symbol: String, size: CGFloat = 10.5, weight: Font.Weight = .medium, help: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(size: size, weight: weight)
                .frame(width: 18 * textScale, height: 18 * textScale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// A note BriefBar left once it copied a prompt for you to paste, or why nothing went, until you dismiss it.
struct CopilotCopiedNote: View {
    let note: String
    let dismiss: () -> Void

    @Environment(\.textScale) private var textScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(size: 11, weight: .semibold)
                .foregroundStyle(ItemState.needsYou.color)
                .accessibilityHidden(true)
            Text(note)
                .font(size: 11.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopilotDismissButton(action: dismiss)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ItemState.needsYou.color.opacity(0.08)))
    }
}

/// ✕, to dismiss what Copilot's line or note says.
struct CopilotDismissButton: View {
    let action: () -> Void

    @Environment(\.textScale) private var textScale

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(size: 9.5, weight: .semibold)
                .frame(width: 18 * textScale, height: 18 * textScale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}

// MARK: - The composer in place

/// What a composer in place asks Copilot about, and how it writes the prompts it sends: one of a pull request's comment
/// threads, one of its builds or its conflicts, or, for Fix All, the comments that wait on you. Made anew as what it's
/// about changes, so its prompts are written as things are when you send it.
struct CopilotAsking {
    var ask: CopilotAsk
    /// What it's about, which its words, its draft and its question go by; nil for Fix All.
    var part: PullRequestPart?
    /// What a fix asks Copilot to do, which says what it may: Fix Comments, Fix the Build, Resolve Conflicts.
    var action: PullRequestAction
    /// "Explain", "Explain the Failure", "Fix", "Resolve", "Fix All", "Fix 1 Comment": Explain says "Ask More" once a session
    /// answered.
    var title: String
    /// Its button: "Ask", "Fix", "Resolve", "Fix All".
    var sendTitle: String
    var words: Words
    /// Reads what its prompts quote before it sends, while it isn't read, such as the code a comment is on: they quote it
    /// once it's read, and it says it's sending meanwhile.
    var prepare: (@MainActor () async -> Void)?
    /// A fix of it, as you say, with what a session answered with Explain when you include it.
    var fix: @MainActor (_ how: String, _ answer: CopilotAnswer?) -> CopilotSending.Fix
    /// Explain's question, asked aside: what you asked, following up on what the session answered before.
    var question: @MainActor (_ asked: String, _ earlier: CopilotAnswer?) -> String
    /// For a build, the run Explain asks about, and when the attempt of it that it asks about finished, as its check said.
    var run: Int?
    var attempt: Date?
    /// Which row it's on, where more than one is about the same part, as a build's (`CopilotComposing.row`).
    var row: String?
    /// For conflicts, the pull request's branches as what it asks is written for them, once it's prepared: a push or a
    /// retarget puts what a session answered out of date (`CopilotQuestions.dismissStale`).
    var head: (@MainActor () -> PullRequestFilesStore.Head?)?
    /// For conflicts, the branches the answer it may build on was about (`CopilotQuestions.Question.head`): once they moved
    /// while it waited, it's left out (`quoting`).
    var answeredAbout: PullRequestFilesStore.Head?

    /// The words a composer says what it does in.
    struct Words {
        /// What a fix does, for its note: "addresses this comment", "fixes this build", "resolves the conflicts".
        var does: String
        /// The same, after "to": "address this comment".
        var toDo: String
        /// What Explain asks, for its note: "why you got it", "why it failed".
        var why: String

        /// For what it's about; for Fix All, the comments that wait on you.
        init(_ part: PullRequestPart?) {
            switch part {
            case .thread?: self.init(does: "addresses this comment", toDo: "address this comment", why: "why you got it")
            case .build?: self.init(does: "fixes this build", toDo: "fix this build", why: "why it failed")
            case .conflicts?: self.init(does: "resolves the conflicts", toDo: "resolve the conflicts", why: "why they conflict")
            case nil: self.init(does: "addresses the comments that wait on you", toDo: "address the comments that wait on you", why: "why you got them")
            }
        }

        init(does: String, toDo: String, why: String) {
            self.does = does
            self.toDo = toDo
            self.why = why
        }
    }

    /// With its words and titles for what it's about.
    init(
        ask: CopilotAsk, part: PullRequestPart?, action: PullRequestAction, title: String? = nil, sendTitle: String? = nil,
        prepare: (@MainActor () async -> Void)? = nil, run: Int? = nil, attempt: Date? = nil, row: String? = nil,
        head: (@MainActor () -> PullRequestFilesStore.Head?)? = nil, answeredAbout: PullRequestFilesStore.Head? = nil,
        fix: @escaping @MainActor (_ how: String, _ answer: CopilotAnswer?) -> CopilotSending.Fix,
        question: @escaping @MainActor (_ asked: String, _ earlier: CopilotAnswer?) -> String
    ) {
        self.ask = ask
        self.part = part
        self.action = action
        self.title = title ?? ask.title(about: part)
        self.sendTitle = sendTitle ?? ask.sendTitle(about: part)
        words = Words(ask == .fixAll ? nil : part)
        self.prepare = prepare
        self.run = run
        self.attempt = attempt
        self.row = row
        self.head = head
        self.answeredAbout = answeredAbout
        self.fix = fix
        self.question = question
    }

    /// Where its words are kept as you open another.
    var draftKey: CopilotComposing { CopilotComposing(part: part, ask: ask, row: row) }

    /// What a send quotes of what a session answered, once it's prepared: nothing once the branches the answer was about
    /// moved while it waited, as its prompt is written for them as they are now (`head`), and it says it left it out.
    /// Builds' and comments' answers go as they are.
    @MainActor
    func quoting(_ answer: CopilotAnswer?) -> (answer: CopilotAnswer?, isLeftOut: Bool) {
        guard let answer, let asked = answeredAbout, let now = head?(), asked != now else { return (answer, false) }
        return (nil, true)
    }

    /// What its composer says once it left the answer out, with what to do: "… Resolve again to go without it."
    var answerLeftOut: String {
        "The answer was about the branches before they moved, so it's left out. \(sendTitle) again to go without it."
    }
}

/// The composer in place for what you ask Copilot about something of a pull request (`CopilotAsking`): your words, where it
/// goes, one ▾ away, preselecting the session that worked on it, else the pull request's, or a fork of it while it's busy,
/// and the button, which Return presses. It says how it would go, as the Send to Copilot window would send it, or why it
/// can't. Once a session answered Explain, Ask More follows up on that, and a fix builds on it. A comment's, a build's and
/// conflicts' each wrap it, with what they add, such as applying a suggested change.
struct CopilotPartComposer<Options: View>: View {
    let asking: CopilotAsking
    let item: PRSnapshot
    /// The session that worked on it, by its ID, which it goes to first.
    let worked: String?
    /// What you wrote in it before, kept as you open another.
    let drafts: CopilotDrafts
    /// What a session answered about it with Explain, while it shows: Ask More follows up on it, and a fix builds on it.
    var answer: CopilotAnswer?
    /// For `--render`: what it shows.
    var preview: CopilotActionsPreview.Composer?
    /// Explain had no session to ask: a fix opens instead.
    var fixInstead: (() -> Void)?
    /// In a box of its own; else in what it's about, such as a thread's card, under a hairline.
    var isFramed = true
    /// What it's about adds under the field, such as applying a suggested change.
    @ViewBuilder var options: () -> Options
    /// It's done: sent, copied for you to paste, or closed.
    let done: (CopilotSending.Outcome?) -> Void

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var sessions: PullRequestSessions
    @EnvironmentObject private var questions: CopilotQuestions
    /// `--render` draws it as it is outside the demo, which sends nothing.
    @Environment(\.isRendering) private var isRendering

    @LocalState private var text = ""
    @LocalState private var chosen: CopilotDestination?
    /// A fix quotes what a session answered with Explain, for what you say to point to.
    @LocalState private var includesAnswer = true
    @LocalState private var isSending = false
    @LocalState private var problem: String?
    /// How it would reach where it goes, once checked.
    @LocalState private var checked: Check?
    @LocalState private var hasAppeared = false

    /// What's known of how a prompt would reach where it goes.
    struct Check: Equatable {
        var destination: CopilotDestination
        var delivery: PullRequestSession.Delivery?
        var forkReach: SessionReach?
        var hasClone: Bool?
    }

    private var ask: CopilotAsk { asking.ask }
    private var record: PRRecord? { store.record(for: item.key) }
    private var session: PullRequestSession? { sessions.session(for: item.key) }
    private var names: CopilotSessionNames { CopilotSessionNames(session: session, copilot: copilot, links: sessions.links) }
    private var destinations: CopilotDestinations { CopilotDestinations.make(session, worked: worked, ask: ask) }
    private var target: CopilotDestination? { chosen ?? destinations.preselected }

    /// "Ask More" once a session answered Explain; else its own.
    private var title: String { ask == .explain && answer != nil ? "Ask More" : asking.title }

    var body: some View {
        let destinations = destinations
        let target = target
        let choice = destinations.choice(for: target)
        let note = problem.map { (text: Optional($0), isWarning: true) } ?? self.note(target, choice: choice)
        CopilotAskComposer(
            symbol: ask.symbol, title: title, placeholder: ask.placeholder(followingUp: ask == .explain && answer != nil), text: $text,
            destination: destinationTitle(target, choice: choice), destinationSymbol: Self.symbol(of: target, ask: ask),
            destinationHelp: ask == .explain ? "Choose the session to ask" : "Choose where Copilot works on it: in the session, a fork of it, or a new one",
            destinations: {
                CopilotDestinationMenu(destinations: destinations, chosen: target, ask: ask, names: names, session: session) {
                    chosen = $0
                    problem = nil
                }
            },
            options: { allOptions },
            note: note.text, noteIsWarning: note.isWarning,
            sendTitle: asking.sendTitle, canSend: canSend(target, choice: choice), isSending: isSending,
            send: { send(to: target, choice: choice) },
            editWholePrompt: ask == .explain ? nil : { openWindow(target, choice: choice) },
            isFramed: isFramed,
            close: { done(nil) }
        )
        .task(id: target) { await check(target, choice: choice) }
        .onChange(of: text) { if preview == nil { drafts.texts[asking.draftKey] = text } }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            if let preview {
                text = preview.text
                chosen = preview.destination
                return
            }
            text = drafts.texts[asking.draftKey] ?? ""
        }
    }

    @ViewBuilder
    private var allOptions: some View {
        options()
        if ask != .explain, answer != nil {
            Toggle(isOn: $includesAnswer) {
                Text("Include the answer above")
                    .font(size: 11.5)
            }
            .toggleStyle(.checkbox)
            .help("Copilot gets what the session answered, so what you say can point to it, such as “the second way”")
        }
        // Explain asks a session that knows the change: without one, a fix can still go.
        if ask == .explain, destinations.preselected == nil, !isAsking(session), let fixInstead {
            Button(CopilotAsk.fix.title(about: asking.part) + " Instead", action: fixInstead)
                .buttonStyle(.borderless)
                .font(size: 11.5, weight: .medium)
                .help("Have Copilot \(CopilotAsking.Words(asking.part).toDo) instead, as you say")
        }
    }

    /// Whether the pull request's sessions ask which is its.
    private func isAsking(_ session: PullRequestSession?) -> Bool {
        if case .ask? = session?.pick { return true }
        return false
    }

    // MARK: Where it goes

    /// "Ask ‘Retry backoff’", "In ‘Retry backoff’", "In a fork of ‘Retry backoff’", "In a new session", "Choose a Session":
    /// a name a paragraph long cut short in its middle, which ▾'s tooltip and menu say in full.
    private func destinationTitle(_ target: CopilotDestination?, choice: SessionChoice?) -> String {
        let name = CopilotWork.quoted(Self.short(choice.map(PullRequestSession.name) ?? "Session"), isTask: choice.map(Self.isTask) ?? false)
        switch target {
        case .session?: return ask == .explain ? "Ask \(name)" : "In \(name)"
        case .fork?: return "In a fork of \(name)"
        case .newSession?: return "In a new session"
        case nil: return "Choose a Session"
        }
    }

    /// A session's name, cut short in its middle past `nameLimit` characters.
    static func short(_ name: String) -> String {
        CopilotDestinationNames.short(name)
    }

    /// Whether a session is a task of BriefBar's, which sentences call one.
    static func isTask(_ choice: SessionChoice) -> Bool {
        choice.run.map { $0.isAppSession != true } ?? false
    }

    /// ▾'s symbol, for where it goes: a session, a fork of one, or a new one.
    static func symbol(of target: CopilotDestination?, ask: CopilotAsk) -> String {
        switch target {
        case .fork?: "arrow.triangle.branch"
        case .newSession?: "plus.circle"
        case .session?, nil: ask == .explain ? "bubble.left.and.text.bubble.right" : "arrow.turn.down.right"
        }
    }

    /// What happens once it's sent, as things stand, or why it can't be: and whether that's a warning.
    private func note(_ target: CopilotDestination?, choice: SessionChoice?) -> (text: String?, isWarning: Bool) {
        let name = choice.map { CopilotWork.quoted(PullRequestSession.name(of: $0), isTask: Self.isTask($0)) } ?? "the session"
        let isLive = copilot.mode == .live || isRendering
        let words = asking.words
        if ask == .explain {
            guard isLive else { return ("The demo makes its answer up, and runs nothing.", false) }
            guard target != nil else {
                if case .ask? = session?.pick {
                    return ("The sessions that go with this pull request go with it as well as each other: choose one to ask.", false)
                }
                return destinations.all.isEmpty
                    ? ("No Copilot session goes with this pull request yet, so none can say \(words.why).", true)
                    : ("No Copilot session goes with this pull request yet: choose one of the app's sessions to ask.", false)
            }
            return ("Asks a copy of \(name) that's deleted after, so nothing changes, and sends its conversation to GitHub Copilot: one premium request.", false)
        }
        guard isLive else { return ("The demo doesn't send anything.", false) }
        let leavesOut = asking.action.leavesOut
        switch target {
        case nil:
            return ("The sessions that go with this pull request go with it as well as each other: choose where it goes.", false)
        case .newSession?:
            if checked?.destination == target, checked?.hasClone == false {
                return ("Choose its local clone in the Send to Copilot window, which \(asking.sendTitle) opens.", false)
            }
            return ("A new session, in a worktree at the latest commit, \(words.does) with \(copilot.settings.copilotOptions.title): \(leavesOut).", false)
        case .fork?:
            guard let choice else { return (CopilotSending.gone, true) }
            if CopilotDestinations.forksWithTheCLI(choice) {
                return (
                    "The Copilot CLI forks \(name), with its history, into a worktree of its own, to \(words.toDo): \(leavesOut). The task stays as it is.",
                    false
                )
            }
            let reach = checked?.destination == target ? checked?.forkReach : nil
            if let why = reach?.whyNot(forking: true) {
                return ("BriefBar copies /fork and the prompt, and opens \(name) in the Copilot app, for you to paste. " + why, false)
            }
            return ("The Copilot app forks \(name), and BriefBar sends the fork the prompt, as yours: \(leavesOut). The session stays as it is.", false)
        case .session?:
            guard let choice else { return (CopilotSending.gone, true) }
            switch delivery(for: target, choice: choice) {
            case .cli:
                return ("Copilot goes on with \(name) with the CLI, on its own, then builds and tests: \(leavesOut).", false)
            case .app(let reach, let reason):
                var parts: [String]
                switch reach {
                case .listening?, .loads?, nil:
                    parts = ["Sends it to \(name) in the Copilot app, as yours: \(leavesOut)."]
                case .noListener?, .notInApp?, .off?:
                    parts = ["BriefBar copies it and opens \(name) in the Copilot app, for you to paste."]
                }
                if let why = reach?.whyNot(forking: false) { parts.append(why) }
                if let reason { parts.append(reason) }
                return (parts.joined(separator: " "), false)
            case .busy(let why):
                return ("\(name.prefix(1).uppercased() + name.dropFirst()) is busy: \(why)", true)
            case .unavailable(let why):
                return (why, true)
            }
        }
    }

    /// How it would reach a session: as checked; as the pull request's line says, for its own; or as BriefBar can tell
    /// without reading anything, until it's checked.
    private func delivery(for target: CopilotDestination?, choice: SessionChoice) -> PullRequestSession.Delivery {
        if checked?.destination == target, let delivery = checked?.delivery { return delivery }
        if session?.session?.id == choice.id, let delivery = session?.delivery { return delivery }
        return PullRequestSession.delivery(for: choice, cliProblem: nil, reach: nil, canOpenInApp: copilot.canOpenInApp)
    }

    private func canSend(_ target: CopilotDestination?, choice: SessionChoice?) -> Bool {
        guard let target, record != nil else { return false }
        if ask == .explain { return questions.canAsk && target.sessionID != nil && asking.part != nil }
        guard copilot.canSend || isRendering, copilot.isOn else { return false }
        switch target {
        case .newSession:
            return true
        case .fork:
            return choice.map { !$0.isUnavailable || CopilotDestinations.forksWithTheCLI($0) } ?? false
        case .session:
            guard let choice else { return false }
            switch delivery(for: target, choice: choice) {
            case .cli, .app: return !choice.isUnavailable
            case .busy, .unavailable: return false
            }
        }
    }

    /// How a prompt would reach where it goes, as things are now, without the checks a send makes: not in the demo, which
    /// reads nothing, nor for Explain, which asks aside.
    private func check(_ target: CopilotDestination?, choice: SessionChoice?) async {
        guard ask != .explain, copilot.mode == .live, copilot.isOn, let target, let record else { return }
        var found = Check(destination: target)
        switch target {
        case .session:
            guard let choice, session?.session?.id != choice.id || session?.delivery == nil else { return }
            found.delivery = await copilot.delivery(to: choice, for: PullRequestTasks.task(for: record), checksRepository: false)
        case .fork:
            guard let choice, !CopilotDestinations.forksWithTheCLI(choice) else { return }
            found.forkReach = await copilot.reach(of: choice)
        case .newSession:
            found.hasClone = await (try? copilot.repository(for: PullRequestTasks.task(for: record), using: copilot.git())) != nil
        }
        guard !Task.isCancelled, self.target == target else { return }
        checked = found
    }

    // MARK: Sending

    private func send(to target: CopilotDestination?, choice: SessionChoice?) {
        guard let target, let record, canSend(target, choice: choice) else { return }
        let key = asking.draftKey
        // Kept with the page's composers, to be called off as this one closes, however it does: a prompt no session took
        // yet is taken back, and nothing starts for a composer that's gone.
        drafts.callOff(key)
        let asking = asking
        let words = text
        if ask == .explain {
            guard let part = asking.part, let id = target.sessionID else { return }
            let earlier = answer
            isSending = asking.prepare != nil
            problem = nil
            drafts.sends[key] = Task {
                // What it quotes, once the read under way ends.
                await asking.prepare?()
                guard !Task.isCancelled else { return }
                drafts.sends[key] = nil
                isSending = false
                // Gone from your lists, completed or abandoned meanwhile: nothing is asked.
                guard CopilotSending.isOpen(item.key, in: store) else {
                    problem = CopilotSending.pullRequestGone
                    SpokenText.announce(CopilotSending.pullRequestGone)
                    return
                }
                // The branches moved while it waited: it doesn't follow up on what was answered about them as they were.
                guard !asking.quoting(earlier).isLeftOut else {
                    problem = asking.answerLeftOut
                    SpokenText.announce(asking.answerLeftOut)
                    return
                }
                questions.ask(
                    asking.question(words, earlier), asked: words, earlier: earlier, session: id, about: part, run: asking.run,
                    attempt: asking.attempt, head: asking.head?(), of: item.key
                )
                drafts.texts[key] = nil
                SpokenText.announce("Asking \(choice.map(PullRequestSession.name) ?? "the session")")
                done(.sent)
            }
            return
        }
        isSending = true
        problem = nil
        let sending = CopilotSending(item: item, record: record, store: store, copilot: copilot, session: session)
        let answer = includesAnswer ? answer : nil
        drafts.sends[key] = Task {
            await asking.prepare?()
            guard !Task.isCancelled else { return }
            // The branches moved while it waited: it doesn't build on what was answered about them as they were.
            guard !asking.quoting(answer).isLeftOut else {
                drafts.sends[key] = nil
                isSending = false
                problem = asking.answerLeftOut
                SpokenText.announce(asking.answerLeftOut)
                return
            }
            let fix = asking.fix(words, answer)
            let outcome = await sending.fix(fix, to: target, choice: choice)
            guard !Task.isCancelled else { return }
            drafts.sends[key] = nil
            isSending = false
            switch outcome {
            case .sent:
                drafts.texts[key] = nil
                SpokenText.announce("Sent to Copilot")
                done(outcome)
            case .copied(let note):
                drafts.texts[key] = nil
                SpokenText.announce(note)
                done(outcome)
            case .notSent(let why):
                problem = why
                SpokenText.announce(why)
            case .needsWindow:
                sending.openWindow(fix, destination: target, choice: choice)
                done(nil)
            }
        }
    }

    /// Edit the Whole Prompt…: the Send to Copilot window, with its prompts as they're written once what they quote is read,
    /// as a send waits for it, going where you chose.
    private func openWindow(_ target: CopilotDestination?, choice: SessionChoice?) {
        guard record != nil else { return }
        let key = asking.draftKey
        drafts.callOff(key)
        let asking = asking
        let words = text
        let answer = includesAnswer ? answer : nil
        isSending = asking.prepare != nil
        problem = nil
        drafts.sends[key] = Task {
            await asking.prepare?()
            guard !Task.isCancelled else { return }
            drafts.sends[key] = nil
            isSending = false
            guard let record = store.record(for: item.key), record.pullRequest.status == .active else {
                problem = CopilotSending.pullRequestGone
                SpokenText.announce(CopilotSending.pullRequestGone)
                return
            }
            guard !asking.quoting(answer).isLeftOut else {
                problem = asking.answerLeftOut
                SpokenText.announce(asking.answerLeftOut)
                return
            }
            let sending = CopilotSending(item: item, record: record, store: store, copilot: copilot, session: session)
            sending.openWindow(asking.fix(words, answer), destination: target, choice: choice)
            done(nil)
        }
    }
}

extension CopilotPartComposer where Options == EmptyView {
    init(
        asking: CopilotAsking, item: PRSnapshot, worked: String?, drafts: CopilotDrafts, answer: CopilotAnswer? = nil,
        preview: CopilotActionsPreview.Composer? = nil, fixInstead: (() -> Void)? = nil, isFramed: Bool = true,
        done: @escaping (CopilotSending.Outcome?) -> Void
    ) {
        self.init(
            asking: asking, item: item, worked: worked, drafts: drafts, answer: answer, preview: preview, fixInstead: fixInstead,
            isFramed: isFramed, options: { EmptyView() }, done: done
        )
    }
}

/// Session names as ▾ shows them.
enum CopilotDestinationNames {
    /// The most characters of a session's name ▾ shows.
    static let limit = 32

    /// A session's name, cut short in its middle past `limit` characters.
    static func short(_ name: String) -> String {
        guard name.count > limit else { return name }
        let half = (limit - 1) / 2
        return String(name.prefix(half)).trimmingCharacters(in: .whitespaces) + "…" + String(name.suffix(half)).trimmingCharacters(in: .whitespaces)
    }
}

/// What ▾ lists: the session that worked on it, or the pull request's, a fork of it and a new session for a fix; the other
/// sessions that go with the pull request, each with why and how it stands, and how a prompt would go there; and the
/// Copilot app's other sessions.
struct CopilotDestinationMenu: View {
    let destinations: CopilotDestinations
    let chosen: CopilotDestination?
    let ask: CopilotAsk
    let names: CopilotSessionNames
    let session: PullRequestSession?
    let choose: (CopilotDestination) -> Void

    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var store: PRStore

    var body: some View {
        Section(ask == .explain ? "Ask" : "Where Copilot Works on It") {
            ForEach(destinations.first) { entry in item(entry) }
        }
        if !destinations.more.isEmpty {
            Section("Other Sessions on This Pull Request") {
                ForEach(destinations.more) { entry in item(entry) }
            }
        }
        if !destinations.others.isEmpty {
            Menu("Other Copilot Sessions") {
                ForEach(destinations.others) { entry in item(entry) }
            }
        }
    }

    private func item(_ entry: CopilotDestinations.Entry) -> some View {
        Button {
            choose(entry.destination)
        } label: {
            CheckedMenuLabel(title: title(entry), isChecked: entry.destination == chosen)
        }
        .disabled(isUnavailable(entry))
    }

    private func isUnavailable(_ entry: CopilotDestinations.Entry) -> Bool {
        guard ask != .explain, let choice = entry.choice else { return false }
        if case .fork = entry.destination { return choice.isUnavailable && !CopilotDestinations.forksWithTheCLI(choice) }
        return choice.isUnavailable
    }

    /// "‘Retry backoff’ — on its branch · finished 1d ago · in Copilot", "A Fork of ‘Retry backoff’ — its history, in a
    /// worktree of its own", "New Session — in a worktree at its latest commit".
    private func title(_ entry: CopilotDestinations.Entry) -> String {
        switch entry.destination {
        case .newSession:
            return "New Session — in a worktree at its latest commit"
        case .fork:
            let name = entry.choice.map(PullRequestSession.name) ?? "Session"
            return "A Fork of ‘\(name.count > 50 ? String(name.prefix(49)) + "…" : name)’ — its history, in a worktree of its own"
        case .session:
            guard let choice = entry.choice else { return "Session" }
            var title = session.map {
                PullRequestSessionLine.menuTitle(of: choice, in: $0, links: names.links, entries: copilot.entries, now: store.now)
            } ?? "‘\(PullRequestSession.name(of: choice))’"
            if ask != .explain, let how = how(choice) { title += (title.contains(" — ") ? " · " : " — ") + how }
            return title
        }
    }

    /// How a fix would go there, in a word or two, unless its title says so already ("open in Copilot"): "with the CLI",
    /// "in Copilot", "to paste in Copilot", "busy".
    private func how(_ choice: SessionChoice) -> String? {
        let delivery = session?.session?.id == choice.id ? session?.delivery : nil
        switch delivery ?? PullRequestSession.delivery(for: choice, cliProblem: nil, reach: nil, canOpenInApp: copilot.canOpenInApp) {
        case .cli: return "with the CLI"
        case .app(let reach, _):
            if reach?.sends(forking: false) == false { return "to paste in Copilot" }
            return choice.isOpenInApp && !choice.isUnavailable ? nil : "in Copilot"
        case .busy: return "busy"
        case .unavailable: return "can't now"
        }
    }
}

// MARK: - Fixes ready to push

/// At the foot of a pull request's details, once fixes of its comments, builds or conflicts are done and not pushed: "2 fixes
/// ready in ‘Retry backoff’", which takes the details to the first of them, with **Push & Reply…**, which opens the Send to
/// Copilot window to commit them, push, and reply on the threads they fixed, in that session. While Send Work to Copilot is
/// on, on an open pull request of yours: the details', or the one a page over them shows, on the Pull Requests page or the
/// Sprint page. A fix of a build that passes since, as when it ran again or after a push, or of conflicts that are gone,
/// isn't counted.
struct ReadyFixesBar: View {
    let item: PRSnapshot
    /// The details that show it, which it takes to what they fixed.
    let details: PullRequestDetailsStore

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var sessions: PullRequestSessions
    @Environment(\.copilotActionsPreview) private var preview

    private var ready: [ReadyFixes] {
        if let ready = preview?.ready { return ready }
        guard copilot.isOn, let record = store.record(for: item.key), record.pullRequest.status == .active, record.role == .author else {
            return []
        }
        return copilot.readyFixes(of: item.key, among: record.partsToFix)
    }

    var body: some View {
        let ready = ready
        if let first = ready.first {
            let names = CopilotSessionNames(session: sessions.session(for: item.key), copilot: copilot, links: sessions.links)
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(size: 13, weight: .semibold)
                    .foregroundStyle(ItemState.done.color)
                    .accessibilityHidden(true)
                // To the first thing they fixed, pointed out for a moment.
                Button {
                    show(first)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sentence(first, names: names))
                            .font(size: 12.5, weight: .semibold)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.subtitle(more: ready.count - 1))
                            .font(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.showHelp(first.parts))
                .accessibilityElement(children: .combine)
                .accessibilityHint("Shows" + Self.showHelp(first.parts).dropFirst("Show".count))
                if ready.count > 1 {
                    Menu("Push & Reply") {
                        ForEach(ready) { group in
                            Button(sentence(group, names: names) + "…") { pushAndReply(group, names: names) }
                        }
                    }
                    .menuStyle(.button)
                    .font(size: 12, weight: .semibold)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Push the fixes of one session, and reply on the threads they addressed")
                } else {
                    Button("Push & Reply…") { pushAndReply(first, names: names) }
                        .font(size: 12, weight: .semibold)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .help(Self.pushHelp(first, from: names.place(of: first)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(ItemState.done.color.opacity(0.08))
            .overlay(alignment: .top) { Divider().opacity(0.6) }
            .accessibilityElement(children: .contain)
        }
    }

    /// The bar under a page over details, for the pull request it shows, with `details`, the page's: none for a page of
    /// anything else.
    @ViewBuilder
    static func under(_ page: ItemRef, details: PullRequestDetailsStore, items: [PRSnapshot]) -> some View {
        if let item = LinkedItemPage.pullRequest(page, in: items, kept: details) {
            ReadyFixesBar(item: item, details: details)
        }
    }

    /// "Not pushed yet", or, with fixes in other sessions too, "Not pushed, and more in another session".
    static func subtitle(more: Int) -> String {
        switch more {
        case ..<1: return "Not pushed yet"
        case 1: return "Not pushed, and more in another session"
        default: return "Not pushed, and more in \(more) other sessions"
        }
    }

    /// What its sentence's click does: "Show the comment it fixed", "Show the build it fixed", "Show what they fixed".
    static func showHelp(_ parts: [PullRequestPart]) -> String {
        guard parts.count == 1, let part = parts.first else {
            return parts.allSatisfy { $0.thread != nil } ? "Show the comments they fixed" : "Show what they fixed"
        }
        switch part {
        case .thread: return "Show the comment it fixed"
        case .build: return "Show the build it fixed"
        case .conflicts: return "Show the conflicts it resolved"
        }
    }

    /// Push & Reply…'s tooltip: replying on the threads only when they fixed some.
    static func pushHelp(_ group: ReadyFixes, from place: String) -> String {
        group.threads.isEmpty
            ? "Commit and push the fixes, as you, from \(place)"
            : "Commit and push the fixes, and reply on the threads they addressed, as you, from \(place)"
    }

    private func sentence(_ group: ReadyFixes, names: CopilotSessionNames) -> String {
        Self.sentence(group.parts, in: names.place(of: group))
    }

    /// What's ready, by what it fixed, and where: "2 fixes ready in ‘Retry backoff’", "1 fix and the conflicts' resolution
    /// ready in ‘Retry backoff’", "A build's fix ready in the ‘Fix the Build’ task".
    static func sentence(_ parts: [PullRequestPart], in place: String) -> String {
        let threads = parts.filter { $0.thread != nil }.count
        let builds = parts.filter { $0.build != nil }.count
        var what: [String] = []
        if threads > 0 { what.append(threads == 1 ? "1 fix" : "\(threads) fixes") }
        if builds > 0 { what.append(builds == 1 ? "a build's fix" : "\(builds) builds' fixes") }
        if parts.contains(.conflicts) { what.append("the conflicts' resolution") }
        let listed = what.count > 1 ? what.dropLast().joined(separator: ", ") + " and " + what[what.count - 1] : what.first ?? "Nothing"
        return listed.prefix(1).uppercased() + listed.dropFirst() + " ready in \(place)"
    }

    /// Takes the details to the first thing they fixed.
    private func show(_ group: ReadyFixes) {
        guard let part = group.parts.first else { return }
        details.go(to: .of(part, in: PullRequestPanel(item, record: store.record(for: item.key))))
    }

    private func pushAndReply(_ group: ReadyFixes, names: CopilotSessionNames) {
        store.composeCopilot(
            .pushAndReply, for: item, copilot: copilot, start: names.start(group.session).map { .session($0, forking: false) },
            parts: group.parts
        )
    }
}

// MARK: - For --render

/// For `--render`: what Copilot's actions on a pull request's comments, builds or conflicts show, as you'd have them, to draw
/// each state without sending or asking anything: a composer open, with your words, what Copilot does about something, what
/// it explained, Fix All's composer open, and the fixes ready to push.
struct CopilotActionsPreview {
    struct Composer {
        /// What it's about; nil for Fix All.
        var part: PullRequestPart?
        var ask: CopilotAsk
        var text: String
        var destination: CopilotDestination?
        var appliesSuggestion = false
    }

    var composers: [Composer] = []
    var work: [PullRequestPart: CopilotWork] = [:]
    /// What's drawn with no work, whatever the demo says.
    var quiet: Set<PullRequestPart> = []
    var questions: [PullRequestPart: CopilotQuestions.Question] = [:]
    var ready: [ReadyFixes]?

    func composer(about part: PullRequestPart) -> Composer? { composers.first { $0.part == part } }
    var fixAll: Composer? { composers.first { $0.part == nil } }
    func question(about part: PullRequestPart) -> CopilotQuestions.Question? { questions[part] }

    /// What Copilot does about something, as drawn: none when it's quiet, else what it says, or what the store says.
    func work(on part: PullRequestPart, else live: () -> CopilotWork?) -> CopilotWork? {
        if quiet.contains(part) { return nil }
        return work[part] ?? live()
    }
}

private struct CopilotActionsPreviewKey: EnvironmentKey {
    static var defaultValue: CopilotActionsPreview? { nil }
}

extension EnvironmentValues {
    var copilotActionsPreview: CopilotActionsPreview? {
        get { self[CopilotActionsPreviewKey.self] }
        set { self[CopilotActionsPreviewKey.self] = newValue }
    }
}
