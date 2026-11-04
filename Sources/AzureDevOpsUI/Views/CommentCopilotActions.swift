import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

// Copilot in a pull request's comments, while Send Work to Copilot is on: on each open thread, ✨ Explain and Fix, with what
// Copilot does about it in a sentence above them; and Fix All at the top of the comments. What they share with a build's and
// conflicts' is in CopilotActions.swift.

// MARK: - A thread's

/// Copilot's part in a comment thread, at its foot, while Send Work to Copilot is on: what Copilot does about it, in a
/// sentence; what a session said of it with Explain; and, on an open thread, ✨ Explain, or Ask More once it answered, and
/// Fix side by side, each opening a small composer in place, one at a time in the comments. Your own actions on it, Reply and
/// its status, share their row, which shows for them alone too (`yours`).
struct ThreadCopilotActions: View {
    let thread: PullRequestPanel.Thread
    let item: PRSnapshot
    let now: Date
    /// The composer in place that's open in the comments.
    @Binding var composing: CopilotComposing?
    let drafts: CopilotDrafts
    /// Your own actions on it, Reply and its status, while you can make changes in Azure DevOps (`ThreadReplyButtons`), at
    /// the row's end; nil while you can't.
    var yours: AnyView?

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var sessions: PullRequestSessions
    @EnvironmentObject private var questions: CopilotQuestions
    @EnvironmentObject private var code: PullRequestCodeStore
    @Environment(\.itemNavigation) private var navigation
    @Environment(\.copilotActionsPreview) private var preview
    /// The window's page it's on, which the code of its thread is read only while the window shows on screen.
    @Environment(\.shownSection) private var section
    @Environment(\.shownWindow) private var window

    /// What BriefBar said once it copied a prompt for you to paste, until you close it.
    @LocalState private var copied: String?
    @LocalState private var isAskingInSession = false
    /// What it tells the code store it is, for its thread's code to be read for Ask in the Session.
    @LocalState private var viewer = UUID()
    /// Explain or Fix, for the keyboard's focus to go back to once its composer closes.
    @FocusState private var focused: CopilotAsk?

    private var record: PRRecord? { store.record(for: item.key) }
    private var part: PullRequestPart { .thread(thread.id) }

    /// The window's page it's on: nil outside one, where nothing is read.
    private var page: String? {
        guard let section, let window else { return nil }
        return PullRequestCodeStore.page(section, window: window)
    }

    /// The composer in place that's open on it, if one is.
    private var asking: CopilotAsk? { composing?.part == part ? composing?.ask : nil }

    /// Whether you can ask Copilot about it now: it's open, on an open pull request, with Send Work to Copilot on; in the
    /// demo too, which answers Explain with made-up answers.
    private var canAct: Bool {
        guard copilot.isOn, copilot.canSend || copilot.mode == .demo, !thread.isResolved, let record else { return false }
        return record.pullRequest.status == .active
    }

    /// Fix is for your own pull requests, as Fix Comments is.
    private var canFix: Bool { record?.role == .author }

    private var names: CopilotSessionNames {
        CopilotSessionNames(session: sessions.session(for: item.key), copilot: copilot, links: sessions.links)
    }

    private var work: CopilotWork? {
        guard let preview else { return copilot.work(on: part, of: item.key) }
        return preview.work(on: part) { copilot.work(on: part, of: item.key) }
    }

    private var question: CopilotQuestions.Question? {
        preview?.question(about: part) ?? questions.question(about: part, of: item.key)
    }

    /// No Copilot session goes with the pull request, as its line found them: Explain has nobody to ask.
    private var hasNobodyToAsk: Bool {
        guard preview == nil, let session = sessions.session(for: item.key) else { return false }
        return CopilotDestinations.make(session, worked: work?.session, ask: .explain).all.isEmpty
    }

    var body: some View {
        let work = work
        let question = question
        let hasLines = copilot.isOn && (question != nil || work != nil || copied != nil)
        // Your reply, open on it, takes the row's place, as a composer of Copilot's does.
        let isReplying = composing == .reply(to: thread.id)
        let showsRow = !isReplying && (canAct || yours != nil)
        if hasLines || (canAct && asking != nil) || showsRow {
            VStack(alignment: .leading, spacing: 8) {
                if copilot.isOn {
                    if let question {
                        questionView(question)
                    }
                    if let work, question?.isAsking != true {
                        workLine(work)
                    }
                    if let copied {
                        CopilotCopiedNote(note: copied) { self.copied = nil }
                    }
                }
                if canAct, let asking {
                    CommentComposer(
                        ask: asking, thread: thread.thread, item: item, worked: work?.session, drafts: drafts, answer: question?.answer,
                        preview: preview?.composer(about: part), fixInstead: canFix ? { open(.fix) } : nil
                    ) { result in
                        if case .copied(let note)? = result { copied = note }
                        close(asking)
                    }
                    // A new composer for each, with its own words and where it goes.
                    .id(asking)
                } else if showsRow {
                    buttons(hasAnswer: question?.answer != nil, showsCopilot: canAct)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .onAppear {
                if let composer = preview?.composer(about: part) { composing = CopilotComposing(part: part, ask: composer.ask) }
            }
            // VoiceOver hears what became of it as it happens, wherever it is: not what shows as it's read.
            .onChange(of: question?.state) { old, state in if old == .asking { announce(state) } }
            .onChange(of: work?.state) { old, state in if let old, CopilotWork.isOngoing(old) { announce(state) } }
        }
    }

    /// Explain and Fix, while you can ask Copilot about it, then your own actions on it, at the row's end: on one line while
    /// they fit, else yours under Copilot's.
    private func buttons(hasAnswer: Bool, showsCopilot: Bool) -> some View {
        let nobody = hasNobodyToAsk
        let explainTitle: String = hasAnswer ? "Ask More" : "Explain"
        let copilotButtons = HStack(spacing: 6) {
            if showsCopilot {
                Button {
                    open(.explain)
                } label: {
                    Label(explainTitle, systemImage: CopilotAsk.explain.symbol)
                }
                .focused($focused, equals: .explain)
                .disabled(nobody)
                .help(explainHelp(nobody: nobody, hasAnswer: hasAnswer))
                if canFix {
                    Button {
                        open(.fix)
                    } label: {
                        Label("Fix", systemImage: CopilotAsk.fix.symbol)
                    }
                    .focused($focused, equals: .fix)
                    .help(fixHelp(hasAnswer: hasAnswer))
                }
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                copilotButtons
                if let yours {
                    Spacer(minLength: 8)
                    yours
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if showsCopilot { copilotButtons }
                if let yours {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        yours
                    }
                }
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
    private func open(_ ask: CopilotAsk) {
        copied = nil
        composing = CopilotComposing(part: part, ask: ask)
    }

    /// Closes its composer, unless another opened meanwhile, and gives the keyboard's focus back to its button.
    private func close(_ ask: CopilotAsk) {
        guard composing == CopilotComposing(part: part, ask: ask) else { return }
        composing = nil
        Task { @MainActor in focused = ask == .fixAll ? nil : ask }
    }

    private func workLine(_ work: CopilotWork) -> some View {
        let look = work.look
        return CopilotWorkLine(
            symbol: look.symbol, text: names.sentence(work), state: look.state, since: work.since, now: now, subtitle: work.step,
            detail: work.said, open: names.opener(work.session, isTask: work.isTask, navigation: navigation)
        )
    }

    @ViewBuilder
    private func questionView(_ question: CopilotQuestions.Question) -> some View {
        let name = names.name(question.session)
        let place = CopilotWork.place(name, isFork: false, forkOf: nil)
        switch question.state {
        case .asking:
            CopilotWorkLine(
                symbol: "sparkles", text: "Copilot is explaining this in \(place)", state: .running, since: question.askedAt, now: now,
                subtitle: question.asked.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "You asked: \($0)" }
            ) {
                Button("Stop") {
                    questions.stop(about: part, of: item.key)
                }
                .buttonStyle(.borderless)
                .font(size: 11.5, weight: .medium)
                .fixedSize()
                .help("Stop asking: nothing changes in the session")
            }
        case .answered(let answer):
            CopilotAnswerCard(
                answer: answer, asked: question.asked, place: place, answeredAt: question.endedAt ?? question.askedAt, now: now,
                open: names.opener(question.session, isTask: names.isTask(question.session), navigation: navigation)
            ) {
                questions.dismiss(about: part, of: item.key)
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
                CopilotDismissButton { questions.dismiss(about: part, of: item.key) }
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

    private func askInSession(_ choice: SessionChoice, question: CopilotQuestions.Question) {
        guard let record else { return }
        let sending = CopilotSending(item: item, record: record, store: store, copilot: copilot, session: sessions.session(for: item.key))
        isAskingInSession = true
        let part = part
        let viewer = viewer
        let page = page
        drafts.asks[part]?.cancel()
        drafts.asks[part] = Task {
            let excerpt = await code.excerpt(of: thread.thread, in: record.pullRequest, by: viewer, on: page)
            // Read for this question alone.
            code.hide(thread.id, of: record.pullRequest.key, by: viewer)
            guard !Task.isCancelled else { return }
            let prompt = PullRequestPrompt.askAboutThread(
                record, thread: thread.thread, code: excerpt, question: question.asked, earlier: question.earlier
            )
            let outcome = await sending.explainAsPrompt(prompt, about: part, to: choice)
            guard !Task.isCancelled else { return }
            drafts.asks[part] = nil
            isAskingInSession = false
            switch outcome {
            case .sent:
                questions.dismiss(about: part, of: item.key)
            case .copied(let note):
                questions.dismiss(about: part, of: item.key)
                copied = note
            case .notSent(let why):
                copied = why
            case .needsWindow:
                break
            }
        }
    }

    /// What VoiceOver hears as Explain ends: who answered, or why it couldn't.
    private func announce(_ state: CopilotQuestions.Question.State?) {
        guard let question else { return }
        switch state {
        case .answered?:
            let place = CopilotWork.place(names.name(question.session), isFork: false, forkOf: nil)
            SpokenText.announce("\(spokenThread): \(SpokenText.unquoted(place)) answered")
        case .failed(let failure)?:
            SpokenText.announce("\(spokenThread): couldn't explain it. \(failure.message(model: nil))")
        case .asking?, nil:
            break
        }
    }

    /// What VoiceOver hears as Copilot's work on it ends, or waits for you.
    private func announce(_ state: CopilotWork.State?) {
        guard let work, let state else { return }
        switch state {
        case .done, .failed, .stopped, .needsYou:
            SpokenText.announce("\(spokenThread): \(SpokenText.unquoted(names.sentence(work)))")
        case .waiting, .working, .unknown:
            break
        }
    }

    /// "The comment on PaymentsClient.cs", for an announcement to say which.
    private var spokenThread: String {
        thread.thread.filePath.map { "The comment on " + ($0 as NSString).lastPathComponent } ?? "The comment on the pull request"
    }
}

// MARK: - The composer in place

/// The composer in place for what you ask about a pull request's comments (`CopilotPartComposer`): Explain or Fix on a
/// thread, or Fix All. On a thread, it has the code the thread is on read, for its prompts to quote, as a thread that comes on
/// screen does; and Fix can apply a suggested change as it's written.
struct CommentComposer: View {
    let ask: CopilotAsk
    /// The thread; nil for Fix All.
    let thread: ReviewThread?
    let item: PRSnapshot
    /// The session that worked on the thread, by its ID, which it goes to first.
    let worked: String?
    /// What you wrote in it before, kept as you open another.
    let drafts: CopilotDrafts
    /// What a session answered about the thread with Explain, while it shows: Ask More follows up on it, and Fix builds on it.
    var answer: CopilotAnswer?
    /// For `--render`: what it shows.
    var preview: CopilotActionsPreview.Composer?
    /// Explain had no session to ask: Fix opens instead.
    var fixInstead: (() -> Void)?
    /// It's done: sent, copied for you to paste, or closed.
    let done: (CopilotSending.Outcome?) -> Void

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var sessions: PullRequestSessions
    @EnvironmentObject private var code: PullRequestCodeStore
    /// The window's page it's on, which the code of its thread is read only while the window shows on screen.
    @Environment(\.shownSection) private var section
    @Environment(\.shownWindow) private var window

    @LocalState private var appliesSuggestion = false
    @LocalState private var hasAppeared = false
    /// What it tells the code store it is, as a view that shows its thread's code does, for the code to be read for it.
    @LocalState private var viewer = UUID()

    /// What its thread's code is read again for, while it shows: a window showing it on screen again, after none did, or
    /// a push.
    private struct CodeReading: Equatable {
        var visibilityChanges: Int
        var ask: PullRequestCodeStore.Ask?
    }

    /// The window's page it's on: nil outside one, where nothing is read.
    private var page: String? {
        guard let section, let window else { return nil }
        return PullRequestCodeStore.page(section, window: window)
    }

    /// What its thread's code is asked for as, as the pull request is now.
    private var codeAsk: PullRequestCodeStore.Ask? {
        guard let thread, let record else { return nil }
        return PullRequestCodeStore.Ask(thread, record.pullRequest)
    }

    private var record: PRRecord? { store.record(for: item.key) }

    private var suggestion: CommentSuggestion? {
        guard ask == .fix, let thread else { return nil }
        return CommentSuggestion.latest(in: thread, me: record?.me)
    }

    /// Fix All's title, which says what it takes on (`CopilotAsk.fixAllTitle`).
    private var fixAllTitle: String {
        guard let record else { return CopilotAsk.fixAll.title(about: nil) }
        let open = (record.details?.threads ?? []).filter { !$0.isResolved }.count
        return CopilotAsk.fixAllTitle(waiting: PullRequestPrompt.waitingThreads(record).count, open: open)
    }

    /// The code its thread is on, once it's read.
    private var excerpt: ThreadExcerpt? {
        guard let thread, case .read(let excerpt)? = code.state(of: thread.id, in: item.key) else { return nil }
        return excerpt
    }

    /// What it asks, and the prompts it sends: the thread's, or Fix Comments' for Fix All.
    private var asking: CopilotAsking {
        let item = item
        let record = record
        let thread = ask == .fixAll ? nil : thread
        let suggestion = appliesSuggestion ? suggestion : nil
        let store = store
        let copilot = copilot
        let session = sessions.session(for: item.key)
        let code = code
        let viewer = viewer
        let page = page
        // The code's read before it's sent, while it's read, or isn't yet: its prompts quote it once it's read.
        var prepare: (@MainActor () async -> Void)?
        if let thread, let record, self.excerpt == nil, ThreadCode.isOnLines(thread) {
            prepare = { _ = await code.excerpt(of: thread, in: record.pullRequest, by: viewer, on: page) }
        }
        // As read when it's sent, after that.
        let readExcerpt = { () -> ThreadExcerpt? in
            guard let thread, case .read(let excerpt)? = code.state(of: thread.id, in: item.key) else { return nil }
            return excerpt
        }
        return CopilotAsking(
            ask: ask, part: thread.map { .thread($0.id) }, action: .fixComments,
            title: ask == .fixAll ? fixAllTitle : nil, sendTitle: ask == .fixAll ? fixAllTitle : nil, prepare: prepare,
            fix: { how, answer in
                guard let record else {
                    return CopilotSending.Fix(prompts: ("", ""), action: .fixComments, parts: [], handOff: nil)
                }
                return CopilotSending(item: item, record: record, store: store, copilot: copilot, session: session)
                    .commentFix(thread, how: how, suggestion: suggestion, answer: answer, excerpt: readExcerpt())
            },
            question: { asked, earlier in
                guard let record, let thread else { return "" }
                return PullRequestPrompt.explainThread(record, thread: thread, code: readExcerpt(), question: asked, earlier: earlier)
            }
        )
    }

    var body: some View {
        CopilotPartComposer(
            asking: asking, item: item, worked: worked, drafts: drafts, answer: answer, preview: preview, fixInstead: fixInstead,
            // In a thread's card, under a hairline; Fix All's under the comments' heading, in a box of its own.
            isFramed: ask == .fixAll
        ) {
            if let suggestion {
                Toggle(isOn: $appliesSuggestion) {
                    Text("Apply \(suggestion.author.name)'s suggestion as written")
                        .font(size: 11.5)
                }
                .toggleStyle(.checkbox)
                .help("Copilot replaces the lines the thread is on with the change \(suggestion.author.name) suggested, as it's written, then builds and tests")
            }
        } done: { outcome in
            done(outcome)
        }
        // The code it's on, for the prompt, read as a thread that comes on screen reads it, where the thread doesn't show its
        // own, as on its file's page: only while its window shows on screen, and again once it shows after it hid.
        .task(id: CodeReading(visibilityChanges: code.visibilityChanges, ask: codeAsk)) {
            guard preview == nil, let thread, let record else { return }
            code.show(thread, of: record.pullRequest, by: viewer, on: page)
        }
        .onDisappear {
            if let thread { code.hide(thread.id, of: item.key, by: viewer) }
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            if let preview {
                appliesSuggestion = preview.appliesSuggestion
                return
            }
            // A suggestion that's the thread's last word is what it asks for: Fix applies it, unless you say otherwise.
            if let suggestion, suggestion.commentId == thread?.comments.last?.id { appliesSuggestion = true }
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
    @Binding var composing: CopilotComposing?
    let drafts: CopilotDrafts

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @Environment(\.copilotActionsPreview) private var preview
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
        guard let record else { return CopilotAsk.fixAll.title(about: nil) }
        return CopilotAsk.fixAllTitle(waiting: PullRequestPrompt.waitingThreads(record).count, open: count ?? 0)
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
                        Label(title, systemImage: CopilotAsk.fixAll.symbol)
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
                CopilotCopiedNote(note: copied) { self.copied = nil }
            }
        }
        .onAppear { if preview?.fixAll != nil { composing = .fixAll } }
    }
}
