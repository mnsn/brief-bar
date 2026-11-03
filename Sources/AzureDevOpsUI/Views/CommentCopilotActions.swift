import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

// Copilot in a pull request's comments, while Send Work to Copilot is on: on each open thread, ✨ Explain and Fix, with what
// Copilot does about it in a sentence above them; Fix All at the top of the comments; and, once fixes are done, a bar at the
// details' foot to push them and reply.

/// The names of the sessions Copilot's work on a pull request's comments goes to, for its sentences and menus: as the pull
/// request's session line knows them, as BriefBar's tasks are called, or as Show Links names them.
@MainActor
struct CommentSessionNames {
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

    func sentence(_ work: CommentWork) -> String {
        work.sentence(name: name(work.session), forkOf: work.forkedFrom.flatMap(name))
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
}

extension CommentWork {
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
        }
    }

    /// The step it's at, under its sentence, while Copilot says.
    var step: String? {
        if case .working(let step) = state { return step }
        return nil
    }

    /// What Copilot said when it ended, for the line's tooltip.
    var said: String? {
        switch state {
        case .done(let summary): summary
        case .failed(let reason): reason
        case .waiting, .working, .needsYou, .stopped: nil
        }
    }
}

extension CommentQuestions.Question {
    /// What the session answered, once it did, for a fix or another question to build on.
    var answer: ThreadAnswer? {
        if case .answered(let text) = state { return ThreadAnswer(question: asked, answer: text) }
        return nil
    }
}

/// Which composer in place is open in a pull request's comments: one at a time, so Esc, Return and the keyboard's focus are
/// its own.
struct CommentComposing: Hashable {
    /// The thread; nil for Fix All.
    var thread: Int?
    var ask: CommentAsk

    static let fixAll = CommentComposing(thread: nil, ask: .fixAll)
}

/// What you wrote in each composer in place in a pull request's comments, kept as you open another, until you send it. Not
/// observed: what you type redraws its own composer only.
@MainActor
final class CommentDrafts {
    var texts: [CommentComposing: String] = [:]
}

// MARK: - A thread's

/// Copilot's part in a comment thread, at its foot, while Send Work to Copilot is on: what Copilot does about it, in a
/// sentence; what a session said of it with Explain; and, on an open thread, ✨ Explain, or Ask More once it answered, and
/// Fix side by side, each opening a small composer in place, one at a time in the comments.
struct ThreadCopilotActions: View {
    let thread: PullRequestPanel.Thread
    let item: PRSnapshot
    let now: Date
    /// The composer in place that's open in the comments.
    @Binding var composing: CommentComposing?
    let drafts: CommentDrafts

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var sessions: PullRequestSessions
    @EnvironmentObject private var questions: CommentQuestions
    @EnvironmentObject private var code: PullRequestCodeStore
    @Environment(\.itemNavigation) private var navigation
    @Environment(\.commentActionsPreview) private var preview
    @Environment(\.textScale) private var textScale

    /// What BriefBar said once it copied a prompt for you to paste, until you close it.
    @LocalState private var copied: String?
    @LocalState private var isAskingInSession = false
    /// Explain or Fix, for the keyboard's focus to go back to once its composer closes.
    @FocusState private var focused: CommentAsk?

    private var record: PRRecord? { store.record(for: item.key) }

    /// The composer in place that's open on it, if one is.
    private var asking: CommentAsk? { composing?.thread == thread.id ? composing?.ask : nil }

    /// Whether you can ask Copilot about it now: it's open, on an open pull request, with Send Work to Copilot on; in the
    /// demo too, which answers Explain with made-up answers.
    private var canAct: Bool {
        guard copilot.isOn, copilot.canSend || copilot.mode == .demo, !thread.isResolved, let record else { return false }
        return record.pullRequest.status == .active
    }

    /// Fix is for your own pull requests, as Fix Comments is.
    private var canFix: Bool { record?.role == .author }

    private var names: CommentSessionNames {
        CommentSessionNames(session: sessions.session(for: item.key), copilot: copilot, links: sessions.links)
    }

    private var work: CommentWork? {
        if let preview, preview.quiet.contains(thread.id) { return nil }
        return preview?.work[thread.id] ?? copilot.commentWork(on: thread.id, of: item.key)
    }

    private var question: CommentQuestions.Question? {
        preview?.question(on: thread.id) ?? questions.question(on: thread.id, of: item.key)
    }

    /// No Copilot session goes with the pull request, as its line found them: Explain has nobody to ask.
    private var hasNobodyToAsk: Bool {
        guard preview == nil, let session = sessions.session(for: item.key) else { return false }
        return CommentDestinations.make(session, worked: work?.session, ask: .explain).all.isEmpty
    }

    var body: some View {
        let work = work
        let question = question
        if copilot.isOn, work != nil || question != nil || copied != nil || canAct {
            VStack(alignment: .leading, spacing: 8) {
                if let question {
                    questionView(question)
                }
                if let work, question?.isAsking != true {
                    workLine(work)
                }
                if let copied {
                    copiedNote(copied)
                }
                if canAct {
                    if let asking {
                        CommentComposer(
                            ask: asking, thread: thread.thread, item: item, worked: work?.session, drafts: drafts, answer: question?.answer,
                            preview: preview?.composer(on: thread.id), fixInstead: canFix ? { open(.fix) } : nil
                        ) { result in
                            if case .copied(let note)? = result { copied = note }
                            close(asking)
                        }
                        // A new composer for each, with its own words and where it goes.
                        .id(asking)
                    } else {
                        buttons(hasAnswer: question?.answer != nil)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .onAppear {
                if let composer = preview?.composer(on: thread.id) { composing = CommentComposing(thread: thread.id, ask: composer.ask) }
            }
            // VoiceOver hears what became of it as it happens, wherever it is: not what shows as it's read.
            .onChange(of: question?.state) { old, state in if old == .asking { announce(state) } }
            .onChange(of: work?.state) { old, state in if let old, Self.isOngoing(old) { announce(state) } }
        }
    }

    private func buttons(hasAnswer: Bool) -> some View {
        let nobody = hasNobodyToAsk
        let explainTitle: String = hasAnswer ? "Ask More" : "Explain"
        return HStack(spacing: 6) {
            Button {
                open(.explain)
            } label: {
                Label(explainTitle, systemImage: CommentAsk.explain.symbol)
            }
            .focused($focused, equals: .explain)
            .disabled(nobody)
            .help(explainHelp(nobody: nobody, hasAnswer: hasAnswer))
            if canFix {
                Button {
                    open(.fix)
                } label: {
                    Label("Fix", systemImage: CommentAsk.fix.symbol)
                }
                .focused($focused, equals: .fix)
                .help(fixHelp(hasAnswer: hasAnswer))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(size: 11.5, weight: .medium)
    }

    private func explainHelp(nobody: Bool, hasAnswer: Bool) -> String {
        if nobody {
            let then: String = canFix ? ". Fix starts one." : "."
            return "No Copilot session goes with this pull request to ask why you got it" + then
        }
        if hasAnswer { return "Ask the session more about this comment, with what it answered in mind" }
        return "Ask the Copilot session that worked on it why you got this comment, what it wants, and how to address it"
    }

    private func fixHelp(hasAnswer: Bool) -> String {
        if hasAnswer {
            return "Have Copilot address this comment, as you say, with what the session answered: it doesn't commit, push or reply"
        }
        return "Have Copilot address this comment, as you say: it doesn't commit, push or reply"
    }

    /// Opens its composer, closing any other in the comments, whose words stay for when it opens again.
    private func open(_ ask: CommentAsk) {
        copied = nil
        composing = CommentComposing(thread: thread.id, ask: ask)
    }

    /// Closes its composer, unless another opened meanwhile, and gives the keyboard's focus back to its button.
    private func close(_ ask: CommentAsk) {
        guard composing == CommentComposing(thread: thread.id, ask: ask) else { return }
        composing = nil
        Task { @MainActor in focused = ask == .fixAll ? nil : ask }
    }

    private func workLine(_ work: CommentWork) -> some View {
        let look = work.look
        return CopilotWorkLine(
            symbol: look.symbol, text: names.sentence(work), state: look.state, since: work.since, now: now, subtitle: work.step,
            detail: work.said, open: names.opener(work.session, isTask: work.isTask, navigation: navigation)
        )
    }

    @ViewBuilder
    private func questionView(_ question: CommentQuestions.Question) -> some View {
        let name = names.name(question.session)
        let place = CommentWork.place(name, isFork: false, forkOf: nil)
        switch question.state {
        case .asking:
            CopilotWorkLine(
                symbol: "sparkles", text: "Copilot is explaining this in \(place)", state: .running, since: question.askedAt, now: now,
                subtitle: question.asked.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "You asked: \($0)" }
            ) {
                Button("Stop") {
                    questions.stop(on: thread.id, of: item.key)
                }
                .buttonStyle(.borderless)
                .font(size: 11.5, weight: .medium)
                .fixedSize()
                .help("Stop asking: nothing changes in the session")
            }
        case .answered(let answer):
            CommentAnswerCard(
                answer: answer, asked: question.asked, place: place, answeredAt: question.endedAt ?? question.askedAt, now: now,
                open: names.opener(question.session, isTask: copilot.entries.contains { $0.id == question.session && $0.run?.isAppSession != true }, navigation: navigation)
            ) {
                questions.dismiss(on: thread.id, of: item.key)
            }
        case .failed(let failure):
            CopilotWorkLine(
                symbol: "exclamationmark.triangle.fill", text: "Couldn't explain it: " + failure.message(model: nil), state: .failing,
                since: question.endedAt, now: now, detail: failure.detail
            ) {
                if Self.asksInSessionInstead(failure), let choice = names.choice(question.session), copilot.canSend {
                    Button(isAskingInSession ? "Asking…" : "Ask in the Session") {
                        askInSession(choice, question: question)
                    }
                    .buttonStyle(.borderless)
                    .font(size: 11.5, weight: .medium)
                    .fixedSize()
                    .disabled(isAskingInSession)
                    .help("Send the question to the session as a prompt, as Fix sends its prompts: it goes in the session's history, and changes nothing")
                }
                dismissButton { questions.dismiss(on: thread.id, of: item.key) }
            }
        }
    }

    /// Without a CLI that can ask a session aside, or one that has the session, the question can still go to the session
    /// as a prompt, as a fix goes.
    static func asksInSessionInstead(_ failure: SessionQuestions.Failure) -> Bool {
        switch failure {
        case .unsupported, .noSession, .noCLI: true
        default: false
        }
    }

    private func askInSession(_ choice: SessionChoice, question: CommentQuestions.Question) {
        guard let record else { return }
        let excerpt: ThreadExcerpt? = if case .read(let excerpt)? = code.state(of: thread.id, in: item.key) { excerpt } else { nil }
        let sending = CommentSending(item: item, record: record, store: store, copilot: copilot, session: sessions.session(for: item.key))
        isAskingInSession = true
        Task {
            let outcome = await sending.explainAsPrompt(
                thread.thread, question: question.asked, earlier: question.earlier, excerpt: excerpt, to: choice
            )
            isAskingInSession = false
            switch outcome {
            case .sent:
                questions.dismiss(on: thread.id, of: item.key)
            case .copied(let note):
                questions.dismiss(on: thread.id, of: item.key)
                copied = note
            case .notSent(let why):
                copied = why
            case .needsWindow:
                break
            }
        }
    }

    /// What VoiceOver hears as Explain ends: who answered, or why it couldn't.
    private func announce(_ state: CommentQuestions.Question.State?) {
        guard let question else { return }
        switch state {
        case .answered?:
            let place = CommentWork.place(names.name(question.session), isFork: false, forkOf: nil)
            Self.announce("\(spokenThread): \(SpokenText.unquoted(place)) answered")
        case .failed(let failure)?:
            Self.announce("\(spokenThread): couldn't explain it. \(failure.message(model: nil))")
        case .asking?, nil:
            break
        }
    }

    /// Copilot is at it, or waits for you, rather than done with it.
    static func isOngoing(_ state: CommentWork.State) -> Bool {
        switch state {
        case .waiting, .working, .needsYou: true
        case .done, .failed, .stopped: false
        }
    }

    /// What VoiceOver hears as Copilot's work on it ends, or waits for you.
    private func announce(_ state: CommentWork.State?) {
        guard let work, let state else { return }
        switch state {
        case .done, .failed, .stopped, .needsYou:
            Self.announce("\(spokenThread): \(SpokenText.unquoted(names.sentence(work)))")
        case .waiting, .working:
            break
        }
    }

    /// "The comment on PaymentsClient.cs", for an announcement to say which.
    private var spokenThread: String {
        thread.thread.filePath.map { "The comment on " + ($0 as NSString).lastPathComponent } ?? "The comment on the pull request"
    }

    static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    private func copiedNote(_ note: String) -> some View {
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
            dismissButton { copied = nil }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ItemState.needsYou.color.opacity(0.08)))
    }

    private func dismissButton(_ dismiss: @escaping () -> Void) -> some View {
        Button(action: dismiss) {
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

/// What a session said of a thread with Explain, under its comments, as BriefBar shows what a model wrote: "Answer from
/// ‘Retry backoff’ · 2m ago", what you asked, the answer in full, formatted as Copilot wrote it, Copy, ↗ to the session,
/// and ✕ to dismiss it. Ask More and Fix, under it, build on it.
private struct CommentAnswerCard: View {
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
                (Text("Answer from \(place)") + Text(" · " + WorkItemDetailsPanel.ago(answeredAt, now: now)))
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Answer from \(SpokenText.unquoted(place)), \(WorkItemDetailsPanel.ago(answeredAt, now: now))")
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                iconButton("doc.on.doc", help: "Copy the answer", label: "Copy the Answer") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                    ThreadCopilotActions.announce("Copied the answer")
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

// MARK: - The composer in place

/// The composer in place for what you ask about a pull request's comments: Explain or Fix on a thread, or Fix All. Your
/// words, where it goes, one ▾ away, preselecting the session that worked on the thread, else the pull request's, or a fork
/// of it while it's busy, and the button, which Return presses. It says how it would go, as the Send to Copilot window would
/// send it, or why it can't. Once a session answered Explain, Ask More follows up on that, and Fix builds on it.
struct CommentComposer: View {
    let ask: CommentAsk
    /// The thread; nil for Fix All.
    let thread: ReviewThread?
    let item: PRSnapshot
    /// The session that worked on the thread, by its ID, which it goes to first.
    let worked: String?
    /// What you wrote in it before, kept as you open another.
    let drafts: CommentDrafts
    /// What a session answered about the thread with Explain, while it shows: Ask More follows up on it, and Fix builds on it.
    var answer: ThreadAnswer?
    /// For `--render`: what it shows.
    var preview: CommentActionsPreview.Composer?
    /// Explain had no session to ask: Fix opens instead.
    var fixInstead: (() -> Void)?
    /// It's done: sent, copied for you to paste, or closed.
    let done: (CommentSending.Outcome?) -> Void

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var sessions: PullRequestSessions
    @EnvironmentObject private var questions: CommentQuestions
    @EnvironmentObject private var code: PullRequestCodeStore
    /// `--render` draws it as it is outside the demo, which sends nothing.
    @Environment(\.isRendering) private var isRendering

    @LocalState private var text = ""
    @LocalState private var chosen: CommentDestination?
    @LocalState private var appliesSuggestion = false
    /// A fix quotes what a session answered with Explain, for what you say to point to.
    @LocalState private var includesAnswer = true
    @LocalState private var isSending = false
    @LocalState private var problem: String?
    /// How it would reach where it goes, once checked.
    @LocalState private var checked: Check?
    @LocalState private var hasAppeared = false

    /// What's known of how a prompt would reach where it goes.
    struct Check: Equatable {
        var destination: CommentDestination
        var delivery: PullRequestSession.Delivery?
        var forkReach: SessionReach?
        var hasClone: Bool?
    }

    private var record: PRRecord? { store.record(for: item.key) }
    private var session: PullRequestSession? { sessions.session(for: item.key) }
    private var names: CommentSessionNames { CommentSessionNames(session: session, copilot: copilot, links: sessions.links) }
    private var destinations: CommentDestinations { CommentDestinations.make(session, worked: worked, ask: ask) }
    private var target: CommentDestination? { chosen ?? destinations.preselected }

    private var suggestion: CommentSuggestion? {
        guard ask == .fix, let thread else { return nil }
        return CommentSuggestion.latest(in: thread, me: record?.me)
    }

    /// Where its words are kept as you open another.
    private var draftKey: CommentComposing { CommentComposing(thread: thread?.id, ask: ask) }

    /// "Explain", "Ask More" once a session answered, "Fix", "Fix All" or "Fix 1 Comment".
    private var title: String {
        switch ask {
        case .explain: answer == nil ? ask.title : "Ask More"
        case .fix: ask.title
        case .fixAll: fixAllTitle
        }
    }

    /// Fix All's, which says what it takes on (`CommentAsk.fixAllTitle`).
    private var fixAllTitle: String {
        guard let record else { return CommentAsk.fixAll.title }
        let open = (record.details?.threads ?? []).filter { !$0.isResolved }.count
        return CommentAsk.fixAllTitle(waiting: PullRequestPrompt.waitingThreads(record).count, open: open)
    }

    var body: some View {
        let destinations = destinations
        let target = target
        let choice = destinations.choice(for: target)
        let note = problem.map { (text: Optional($0), isWarning: true) } ?? self.note(target, choice: choice)
        CopilotAskComposer(
            symbol: ask.symbol, title: title, placeholder: ask.placeholder(followingUp: ask == .explain && answer != nil), text: $text,
            destination: destinationTitle(target, choice: choice), destinationSymbol: Self.symbol(of: target, ask: ask),
            destinationHelp: ask == .explain ? "Choose the session to ask" : "Choose where Copilot fixes it: in the session, a fork of it, or a new one",
            destinations: {
                CommentDestinationMenu(destinations: destinations, chosen: target, ask: ask, names: names, session: session) {
                    chosen = $0
                    problem = nil
                }
            },
            options: { options(choice: choice) },
            note: note.text, noteIsWarning: note.isWarning,
            sendTitle: ask == .fixAll ? fixAllTitle : ask.sendTitle, canSend: canSend(target, choice: choice), isSending: isSending,
            send: { send(to: target, choice: choice) },
            editWholePrompt: ask == .explain ? nil : { openWindow(target, choice: choice) },
            // In a thread's card, under a hairline; Fix All's under the comments' heading, in a box of its own.
            isFramed: ask == .fixAll,
            close: { done(nil) }
        )
        .task(id: target) { await check(target, choice: choice) }
        .onChange(of: text) { if preview == nil { drafts.texts[draftKey] = text } }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            if let preview {
                text = preview.text
                chosen = preview.destination
                appliesSuggestion = preview.appliesSuggestion
                return
            }
            text = drafts.texts[draftKey] ?? ""
            // A suggestion that's the thread's last word is what it asks for: Fix applies it, unless you say otherwise.
            if let suggestion, suggestion.commentId == thread?.comments.last?.id { appliesSuggestion = true }
        }
    }

    @ViewBuilder
    private func options(choice: SessionChoice?) -> some View {
        if let suggestion {
            Toggle(isOn: $appliesSuggestion) {
                Text("Apply \(suggestion.author.name)'s suggestion as written")
                    .font(size: 11.5)
            }
            .toggleStyle(.checkbox)
            .help("Copilot replaces the lines the thread is on with the change \(suggestion.author.name) suggested, as it's written, then builds and tests")
        }
        if ask == .fix, answer != nil {
            Toggle(isOn: $includesAnswer) {
                Text("Include the answer above")
                    .font(size: 11.5)
            }
            .toggleStyle(.checkbox)
            .help("Copilot gets what the session answered, so what you say can point to it, such as “the second way”")
        }
        // Explain asks a session that knows the change: without one, Fix can still go.
        if ask == .explain, destinations.preselected == nil, !isAsking(session), let fixInstead {
            Button("Fix Instead", action: fixInstead)
                .buttonStyle(.borderless)
                .font(size: 11.5, weight: .medium)
                .help("Have Copilot address it instead, as you say")
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
    private func destinationTitle(_ target: CommentDestination?, choice: SessionChoice?) -> String {
        let name = "‘\(Self.short(choice.map(PullRequestSession.name) ?? "Session"))’"
        switch target {
        case .session?: return ask == .explain ? "Ask \(name)" : "In \(name)"
        case .fork?: return "In a fork of \(name)"
        case .newSession?: return "In a new session"
        case nil: return "Choose a Session"
        }
    }

    /// A session's name, cut short in its middle past `nameLimit` characters.
    static func short(_ name: String) -> String {
        guard name.count > nameLimit else { return name }
        let half = (nameLimit - 1) / 2
        return String(name.prefix(half)).trimmingCharacters(in: .whitespaces) + "…" + String(name.suffix(half)).trimmingCharacters(in: .whitespaces)
    }

    static let nameLimit = 32

    /// ▾'s symbol, for where it goes: a session, a fork of one, or a new one.
    static func symbol(of target: CommentDestination?, ask: CommentAsk) -> String {
        switch target {
        case .fork?: "arrow.triangle.branch"
        case .newSession?: "plus.circle"
        case .session?, nil: ask == .explain ? "bubble.left.and.text.bubble.right" : "arrow.turn.down.right"
        }
    }

    /// What happens once it's sent, as things stand, or why it can't be: and whether that's a warning.
    private func note(_ target: CommentDestination?, choice: SessionChoice?) -> (text: String?, isWarning: Bool) {
        let name = choice.map { "‘\(PullRequestSession.name(of: $0))’" } ?? "the session"
        let isLive = copilot.mode == .live || isRendering
        if ask == .explain {
            guard isLive else { return ("The demo makes its answer up, and runs nothing.", false) }
            guard target != nil else {
                if case .ask? = session?.pick {
                    return ("The sessions that go with this pull request go with it as well as each other: choose one to ask.", false)
                }
                return destinations.all.isEmpty
                    ? ("No Copilot session goes with this pull request yet, so none can say why you got it.", true)
                    : ("No Copilot session goes with this pull request yet: choose one of the app's sessions to ask.", false)
            }
            return ("Asks a copy of \(name) that's deleted after, so nothing changes, and sends its conversation to GitHub Copilot: one premium request.", false)
        }
        guard isLive else { return ("The demo doesn't send anything.", false) }
        let does = ask == .fixAll ? "the comments that wait on you" : "this comment"
        switch target {
        case nil:
            return ("The sessions that go with this pull request go with it as well as each other: choose where it goes.", false)
        case .newSession?:
            if checked?.destination == target, checked?.hasClone == false {
                return ("Choose its local clone in the Send to Copilot window, which \(ask.sendTitle) opens.", false)
            }
            return ("A new session, in a worktree at the latest commit, addresses \(does) with \(copilot.settings.copilotOptions.title): no commit, push or reply.", false)
        case .fork?:
            guard let choice else { return (CommentSending.gone, true) }
            if CommentDestinations.forksWithTheCLI(choice) {
                return ("The CLI forks \(name), with its history, into a worktree of its own, to address \(does): \(name) stays as it is.", false)
            }
            let reach = checked?.destination == target ? checked?.forkReach : nil
            if let why = reach?.whyNot(forking: true) {
                return ("BriefBar copies /fork and the prompt, and opens \(name) in the Copilot app, for you to paste. " + why, false)
            }
            return ("The Copilot app forks \(name), and BriefBar sends the fork the prompt, as yours: \(name) stays as it is.", false)
        case .session?:
            guard let choice else { return (CommentSending.gone, true) }
            switch delivery(for: target, choice: choice) {
            case .cli:
                return ("Copilot goes on with \(name) with the CLI, on its own, then builds and tests: no commit, push or reply.", false)
            case .app(let reach, let reason):
                var parts: [String]
                switch reach {
                case .listening?, .loads?, nil:
                    parts = ["Sends it to \(name) in the Copilot app, as yours: no commit, push or reply."]
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
    private func delivery(for target: CommentDestination?, choice: SessionChoice) -> PullRequestSession.Delivery {
        if checked?.destination == target, let delivery = checked?.delivery { return delivery }
        if session?.session?.id == choice.id, let delivery = session?.delivery { return delivery }
        return PullRequestSession.delivery(for: choice, cliProblem: nil, reach: nil, canOpenInApp: copilot.canOpenInApp)
    }

    private func canSend(_ target: CommentDestination?, choice: SessionChoice?) -> Bool {
        guard let target, record != nil else { return false }
        if ask == .explain { return questions.canAsk && target.sessionID != nil }
        guard copilot.canSend || isRendering, copilot.isOn else { return false }
        switch target {
        case .newSession:
            return true
        case .fork:
            return choice.map { !$0.isUnavailable || CommentDestinations.forksWithTheCLI($0) } ?? false
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
    private func check(_ target: CommentDestination?, choice: SessionChoice?) async {
        guard ask != .explain, copilot.mode == .live, copilot.isOn, let target, let record else { return }
        var found = Check(destination: target)
        switch target {
        case .session:
            guard let choice, session?.session?.id != choice.id || session?.delivery == nil else { return }
            found.delivery = await copilot.delivery(to: choice, for: PullRequestTasks.task(for: record), checksRepository: false)
        case .fork:
            guard let choice, !CommentDestinations.forksWithTheCLI(choice) else { return }
            found.forkReach = await copilot.reach(of: choice)
        case .newSession:
            found.hasClone = await (try? copilot.repository(for: PullRequestTasks.task(for: record), using: copilot.git())) != nil
        }
        guard !Task.isCancelled, self.target == target else { return }
        checked = found
    }

    // MARK: Sending

    private var excerpt: ThreadExcerpt? {
        guard let thread, case .read(let excerpt)? = code.state(of: thread.id, in: item.key) else { return nil }
        return excerpt
    }

    private func send(to target: CommentDestination?, choice: SessionChoice?) {
        guard let target, let record, canSend(target, choice: choice) else { return }
        if ask == .explain {
            guard let thread, let id = target.sessionID else { return }
            questions.ask(
                PullRequestPrompt.explainThread(record, thread: thread, code: excerpt, question: text, earlier: answer), asked: text,
                earlier: answer, session: id, on: thread.id, of: item.key
            )
            drafts.texts[draftKey] = nil
            ThreadCopilotActions.announce("Asking \(choice.map(PullRequestSession.name) ?? "the session")")
            done(.sent)
            return
        }
        isSending = true
        problem = nil
        let sending = CommentSending(item: item, record: record, store: store, copilot: copilot, session: session)
        let how = text
        let suggestion = appliesSuggestion ? suggestion : nil
        let answer = includesAnswer ? answer : nil
        let excerpt = excerpt
        let thread = ask == .fix ? thread : nil
        let key = draftKey
        Task {
            let outcome = await sending.fix(thread, how: how, suggestion: suggestion, answer: answer, excerpt: excerpt, to: target, choice: choice)
            isSending = false
            switch outcome {
            case .sent:
                drafts.texts[key] = nil
                ThreadCopilotActions.announce("Sent to Copilot")
                done(outcome)
            case .copied(let note):
                drafts.texts[key] = nil
                ThreadCopilotActions.announce(note)
                done(outcome)
            case .notSent(let why):
                problem = why
                ThreadCopilotActions.announce(why)
            case .needsWindow:
                sending.openWindow(thread, how: how, suggestion: suggestion, answer: answer, excerpt: excerpt, destination: target, choice: choice)
                done(nil)
            }
        }
    }

    private func openWindow(_ target: CommentDestination?, choice: SessionChoice?) {
        guard let record else { return }
        let sending = CommentSending(item: item, record: record, store: store, copilot: copilot, session: session)
        sending.openWindow(
            ask == .fix ? thread : nil, how: text, suggestion: appliesSuggestion ? suggestion : nil, answer: includesAnswer ? answer : nil,
            excerpt: excerpt, destination: target, choice: choice
        )
        done(nil)
    }
}

/// What ▾ lists: the session that worked on the thread, or the pull request's, a fork of it and a new session for a fix;
/// the other sessions that go with the pull request, each with why and how it stands, and how a prompt would go there; and
/// the Copilot app's other sessions.
private struct CommentDestinationMenu: View {
    let destinations: CommentDestinations
    let chosen: CommentDestination?
    let ask: CommentAsk
    let names: CommentSessionNames
    let session: PullRequestSession?
    let choose: (CommentDestination) -> Void

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

    private func item(_ entry: CommentDestinations.Entry) -> some View {
        Button {
            choose(entry.destination)
        } label: {
            CheckedMenuLabel(title: title(entry), isChecked: entry.destination == chosen)
        }
        .disabled(isUnavailable(entry))
    }

    private func isUnavailable(_ entry: CommentDestinations.Entry) -> Bool {
        guard ask != .explain, let choice = entry.choice else { return false }
        if case .fork = entry.destination { return choice.isUnavailable && !CommentDestinations.forksWithTheCLI(choice) }
        return choice.isUnavailable
    }

    /// "‘Retry backoff’ — on its branch · finished 1d ago · in Copilot", "A Fork of ‘Retry backoff’ — its history, in a
    /// worktree of its own", "New Session — in a worktree at its latest commit".
    private func title(_ entry: CommentDestinations.Entry) -> String {
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

// MARK: - The comments' header

/// The Comments header, with Fix All on your pull request while comments wait on you: Fix Comments, through the same
/// composer in place as a thread's Fix, under it. It says what it takes on: "Fix 1 Comment" while others wait on someone
/// else.
struct CommentsHeader: View {
    let item: PRSnapshot
    let count: Int?
    /// The composer in place that's open in the comments.
    @Binding var composing: CommentComposing?
    let drafts: CommentDrafts

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @Environment(\.commentActionsPreview) private var preview
    @Environment(\.textScale) private var textScale
    @LocalState private var copied: String?
    @FocusState private var isFocused: Bool

    private var record: PRRecord? { store.record(for: item.key) }
    private var isFixing: Bool { composing == .fixAll }

    /// Fix Comments applies: your open pull request, with threads that wait on you, and Send Work to Copilot on.
    private var canFixAll: Bool {
        guard copilot.isOn, copilot.canSend || copilot.mode == .demo, let record, record.pullRequest.status == .active else { return false }
        return PullRequestTasks.actions(for: record, canShip: false).contains(.fixComments)
    }

    /// "Fix All", or "Fix 1 Comment" while others wait on someone else.
    private var title: String {
        guard let record else { return CommentAsk.fixAll.title }
        return CommentAsk.fixAllTitle(waiting: PullRequestPrompt.waitingThreads(record).count, open: count ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PageSectionHeader(title: "Comments", count: count)
                Spacer(minLength: 8)
                if canFixAll, !isFixing {
                    Button {
                        copied = nil
                        composing = .fixAll
                    } label: {
                        Label(title, systemImage: CommentAsk.fixAll.symbol)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(size: 11.5, weight: .medium)
                    .focused($isFocused)
                    .help("Have Copilot address every comment that waits on you, as Fix Comments does: it doesn't commit, push or reply")
                }
            }
            if canFixAll, isFixing {
                CommentComposer(ask: .fixAll, thread: nil, item: item, worked: nil, drafts: drafts, preview: preview?.fixAll) { result in
                    if case .copied(let note)? = result { copied = note }
                    guard composing == .fixAll else { return }
                    composing = nil
                    Task { @MainActor in isFocused = true }
                }
            }
            if let copied {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(size: 11, weight: .semibold)
                        .foregroundStyle(ItemState.needsYou.color)
                        .accessibilityHidden(true)
                    Text(copied)
                        .font(size: 11.5)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        self.copied = nil
                    } label: {
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
        }
        .onAppear { if preview?.fixAll != nil { composing = .fixAll } }
    }
}

// MARK: - Fixes ready to push

/// At the foot of a pull request's details, once fixes of its comments are done and not pushed: "2 fixes ready in
/// ‘Retry backoff’", which takes the details to the threads they fixed, with **Push & Reply…**, which opens the Send to
/// Copilot window to commit them, push and reply, in that session. While Send Work to Copilot is on, on an open pull
/// request of yours.
struct ReadyFixesBar: View {
    let item: PRSnapshot

    @EnvironmentObject private var details: PullRequestDetailsStore
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var sessions: PullRequestSessions
    @Environment(\.commentActionsPreview) private var preview

    private var ready: [ReadyFixes] {
        if let ready = preview?.ready { return ready }
        guard copilot.isOn, let record = store.record(for: item.key), record.pullRequest.status == .active, record.role == .author else {
            return []
        }
        let open = (record.details?.threads ?? []).filter { !$0.isResolved }.map(\.id)
        return copilot.readyFixes(of: item.key, among: open)
    }

    var body: some View {
        let ready = ready
        if let first = ready.first {
            let names = CommentSessionNames(session: sessions.session(for: item.key), copilot: copilot, links: sessions.links)
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(size: 13, weight: .semibold)
                    .foregroundStyle(ItemState.done.color)
                    .accessibilityHidden(true)
                // To the first thread they fixed, pointed out for a moment.
                Button {
                    if let thread = first.threads.first { details.go(to: .thread(thread)) }
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
                .help(first.threads.count == 1 ? "Show the comment it fixed" : "Show the comments they fixed")
                .accessibilityElement(children: .combine)
                .accessibilityHint(first.threads.count == 1 ? "Shows the comment it fixed" : "Shows the first comment they fixed")
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
                    .help("Push and reply on the threads the fixes of one session addressed")
                } else {
                    Button("Push & Reply…") { pushAndReply(first, names: names) }
                        .font(size: 12, weight: .semibold)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .help("Commit and push the fixes, and reply on the threads they addressed, as you, from \(CommentWork.place(names.name(first.session), isFork: first.forkedFrom != nil, forkOf: first.forkedFrom.flatMap(names.name)))")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(ItemState.done.color.opacity(0.08))
            .accessibilityElement(children: .contain)
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

    /// "2 fixes ready in ‘Retry backoff’", "1 fix ready in a fork of ‘Retry backoff’".
    private func sentence(_ group: ReadyFixes, names: CommentSessionNames) -> String {
        let place = CommentWork.place(names.name(group.session), isFork: group.forkedFrom != nil, forkOf: group.forkedFrom.flatMap(names.name))
        return (group.threads.count == 1 ? "1 fix" : "\(group.threads.count) fixes") + " ready in \(place)"
    }

    private func pushAndReply(_ group: ReadyFixes, names: CommentSessionNames) {
        store.composeCopilot(
            .pushAndReply, for: item, copilot: copilot, start: names.start(group.session).map { .session($0, forking: false) },
            threads: group.threads
        )
    }
}

// MARK: - For --render

/// For `--render`: what the comments' Copilot actions show, as you'd have them, to draw each state without sending or
/// asking anything: a thread's composer open, with your words, what Copilot does about a thread, what it explained, Fix All's
/// composer open, and the fixes ready to push.
struct CommentActionsPreview {
    struct Composer {
        var thread: Int?
        var ask: CommentAsk
        var text: String
        var destination: CommentDestination?
        var appliesSuggestion = false
    }

    var composers: [Composer] = []
    var work: [Int: CommentWork] = [:]
    /// Threads drawn with no work, whatever the demo says.
    var quiet: Set<Int> = []
    var questions: [Int: CommentQuestions.Question] = [:]
    var ready: [ReadyFixes]?

    func composer(on thread: Int) -> Composer? { composers.first { $0.thread == thread } }
    var fixAll: Composer? { composers.first { $0.thread == nil } }
    func question(on thread: Int) -> CommentQuestions.Question? { questions[thread] }
}

private struct CommentActionsPreviewKey: EnvironmentKey {
    static var defaultValue: CommentActionsPreview? { nil }
}

extension EnvironmentValues {
    var commentActionsPreview: CommentActionsPreview? {
        get { self[CommentActionsPreviewKey.self] }
        set { self[CommentActionsPreviewKey.self] = newValue }
    }
}
