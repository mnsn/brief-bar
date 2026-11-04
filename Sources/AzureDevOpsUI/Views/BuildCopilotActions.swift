import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

// Copilot in a pull request's builds, while Send Work to Copilot is on: on a failed build that's open in its details, what
// Copilot does about it, then ✨ Explain the Failure and Fix, each with a composer in place, as a comment has; on a build's
// row while it's closed, the same in a line. What they share with comments and conflicts is in CopilotActions.swift.

extension Check.State {
    /// It passes, or needn't: passed, passed and has to run again, or doesn't apply. Copilot's fix of a build that passes
    /// since, as when it ran again or after a push, is over.
    var needsNoFix: Bool {
        switch self {
        case .passed, .expired, .notApplicable: true
        case .failed, .running, .queued, .notRun, .pending: false
        }
    }
}

extension CopilotWork {
    /// Whether it shows on a build: while Copilot is at it, or the build doesn't pass. A rerun, or a push, that passes ends
    /// it; so does a run that failed after what Copilot pushed, which the build is to fix again.
    func shows(onBuild check: Check?) -> Bool {
        if isActive { return true }
        guard let check else { return true }
        if check.state.needsNoFix { return false }
        if purpose == .pushAndReply, case .done = state, check.state == .failed, let failedAt = check.completedAt, failedAt > since {
            return false
        }
        return true
    }
}

/// What Copilot does, and what a session said, about one of a pull request's builds: for its row and its open run alike.
@MainActor
enum BuildCopilot {
    /// What Copilot does about it, while it shows on the build (`CopilotWork.shows(onBuild:)`).
    static func work(
        on line: PullRequestPanel.CheckLine, of key: PRKey, copilot: CopilotTasksStore, preview: CopilotActionsPreview?
    ) -> CopilotWork? {
        guard let part = line.check?.part else { return nil }
        let work = preview.map { preview in preview.work(on: part) { copilot.work(on: part, of: key) } } ?? copilot.work(on: part, of: key)
        guard let work, work.shows(onBuild: line.check) else { return nil }
        return work
    }

    /// What a session said of a run of it with Explain: one about another run isn't this one's.
    static func question(
        about line: PullRequestPanel.CheckLine, run: Int?, of key: PRKey, questions: CopilotQuestions, preview: CopilotActionsPreview?
    ) -> CopilotQuestions.Question? {
        guard let part = line.check?.part else { return nil }
        let question = preview?.question(about: part) ?? questions.question(about: part, of: key)
        guard let question, question.run == nil || run == nil || question.run == run else { return nil }
        return question
    }

    /// Its line: "Copilot is fixing this build in the ‘Fix the Build’ task · 9m", with the step it's at, or what Copilot
    /// said as it ended under it; a click opens where it works, when something can.
    static func workLine(_ work: CopilotWork, names: CopilotSessionNames, now: Date, navigation: ItemNavigation?) -> some View {
        let look = work.look
        return CopilotWorkLine(
            symbol: look.symbol, text: names.sentence(work), state: look.state, since: work.since, now: now, subtitle: work.step,
            detail: work.said, open: names.opener(work.session, isTask: work.isTask, navigation: navigation)
        )
    }

    /// While a session explains why it failed: "Copilot is explaining the failure in ‘Retry backoff’ · 12s", what you
    /// asked, and Stop.
    static func askingLine(
        _ question: CopilotQuestions.Question, names: CopilotSessionNames, now: Date, stop: @escaping () -> Void
    ) -> some View {
        let asked = question.asked.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "You asked: \($0)" }
        return CopilotWorkLine(
            symbol: "sparkles", text: "Copilot is explaining the failure in \(names.place(question.session))", state: .running,
            since: question.askedAt, now: now, subtitle: asked
        ) {
            Button("Stop", action: stop)
                .buttonStyle(.borderless)
                .font(size: 11.5, weight: .medium)
                .fixedSize()
                .help("Stop asking: nothing changes in the session")
        }
    }
}

/// What Copilot does about one of a pull request's builds, on its row, in a line, while the build is closed, or open
/// before its run is read: that a session is explaining why it failed, with Stop; that it answered, or couldn't, with
/// Show, which opens the build to it; and what Copilot does about the build, in a sentence in its state's color, with since
/// when, and the step it's at or what it said: "Copilot is fixing this build in the ‘Fix the Build’ task · 9m". Open, the
/// build says them with its run (`BuildCopilotActions`). VoiceOver hears what became of them as it happens, either way.
struct BuildWorkLine: View {
    let line: PullRequestPanel.CheckLine
    let item: PRSnapshot
    let now: Date
    /// The build is open, its run read, and says them there.
    let isOpen: Bool
    /// Opens the build, at what a session said.
    let show: () -> Void

    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var sessions: PullRequestSessions
    @EnvironmentObject private var questions: CopilotQuestions
    @Environment(\.itemNavigation) private var navigation
    @Environment(\.copilotActionsPreview) private var preview

    private var names: CopilotSessionNames {
        CopilotSessionNames(session: sessions.session(for: item.key), copilot: copilot, links: sessions.links)
    }

    var body: some View {
        let work = BuildCopilot.work(on: line, of: item.key, copilot: copilot, preview: preview)
        let question = copilot.isOn ? BuildCopilot.question(about: line, run: line.buildId, of: item.key, questions: questions, preview: preview) : nil
        let shown = isOpen ? nil : Shown(work: work, question: question)
        VStack(alignment: .leading, spacing: 6) {
            if let shown {
                if let question = shown.question {
                    questionLine(question)
                }
                if let work = shown.work {
                    BuildCopilot.workLine(work, names: names, now: now, navigation: navigation)
                }
            }
        }
        // Under its name and status.
        .padding(.leading, 24)
        .padding(.top, shown?.isEmpty == false ? 6 : 0)
        // VoiceOver hears what became of them as it happens, wherever they are: not what shows as they're read.
        .onChange(of: work?.state) { old, state in
            guard let old, CopilotWork.isOngoing(old), let work, let state else { return }
            switch state {
            case .done, .failed, .stopped, .needsYou:
                SpokenText.announce("\(line.run.name): \(names.announcement(work))")
            case .waiting, .working, .unknown:
                break
            }
        }
        .onChange(of: question?.state) { old, state in
            guard old == .asking, let question else { return }
            switch state {
            case .answered?:
                SpokenText.announce("\(line.run.name): \(SpokenText.unquoted(names.place(question.session))) answered")
            case .failed(let failure)?:
                SpokenText.announce("\(line.run.name): couldn't explain it. \(failure.message(model: nil))")
            case .asking?, nil:
                break
            }
        }
    }

    /// What its line shows, as the build's run would: a session explaining it, then nothing else; what it answered, or why it
    /// couldn't, when that's newer than what Copilot does about it; and what Copilot does about it.
    private struct Shown {
        var question: CopilotQuestions.Question?
        var work: CopilotWork?

        init(work: CopilotWork?, question: CopilotQuestions.Question?) {
            if let question, question.isAsking {
                self.question = question
                return
            }
            if let question, work.map({ (question.endedAt ?? question.askedAt) > $0.since }) ?? true {
                self.question = question
            }
            self.work = work
        }

        var isEmpty: Bool { question == nil && work == nil }
    }

    @ViewBuilder
    private func questionLine(_ question: CopilotQuestions.Question) -> some View {
        switch question.state {
        case .asking:
            BuildCopilot.askingLine(question, names: names, now: now) {
                if let part = line.check?.part { questions.stop(about: part, of: item.key) }
            }
        case .answered:
            CopilotWorkLine(
                symbol: "sparkles", text: "Answer from \(names.place(question.session))", state: nil, since: question.endedAt ?? question.askedAt,
                now: now
            ) {
                showButton(help: "Show the answer, with the build's run")
            }
        case .failed(let failure):
            CopilotWorkLine(
                symbol: "exclamationmark.triangle.fill", text: "Couldn't explain it: " + failure.message(model: nil), state: .failing,
                since: question.endedAt, now: now, detail: failure.detail
            ) {
                showButton(help: "Show the build's run, to ask again")
            }
        }
    }

    private func showButton(help: String) -> some View {
        Button("Show", action: show)
            .buttonStyle(.borderless)
            .font(size: 11.5, weight: .medium)
            .fixedSize()
            .help(help)
    }
}

/// Copilot's part in a failed build that's open in a pull request's details, while Send Work to Copilot is on, as a comment
/// thread has it: what a session said of it with Explain; what Copilot does about it, in a sentence; then ✨ Explain the
/// Failure, or Ask More once it answered, and Fix, each opening a small composer in their place, one at a time in the
/// details; then what else it can do, under them (`trailing`), such as Open Run. Explain asks the session that worked on
/// the build, or the pull request's, why it failed, and whether it's the change's doing, a flaky test or the build's
/// infrastructure; Fix has Copilot reproduce it and fix it, as you say, without committing, pushing or touching pipelines.
struct BuildCopilotActions<Trailing: View>: View {
    let line: PullRequestPanel.CheckLine
    let item: PRSnapshot
    let investigation: BuildInvestigation
    let now: Date
    /// The composer in place that's open in the details.
    @Binding var composing: CopilotComposing?
    let drafts: CopilotDrafts
    @ViewBuilder var trailing: () -> Trailing

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var sessions: PullRequestSessions
    @EnvironmentObject private var questions: CopilotQuestions
    @Environment(\.itemNavigation) private var navigation
    @Environment(\.copilotActionsPreview) private var preview

    /// What BriefBar said once it copied a prompt for you to paste, until you close it.
    @LocalState private var copied: String?
    @LocalState private var isAskingInSession = false
    /// Explain or Fix, for the keyboard's focus to go back to once its composer closes.
    @FocusState private var focused: CopilotAsk?

    private var record: PRRecord? { store.record(for: item.key) }
    private var part: PullRequestPart? { line.check?.part }

    /// The composer in place that's open on it, if one is.
    private var asking: CopilotAsk? {
        guard let part, composing?.part == part else { return nil }
        return composing?.ask
    }

    /// Whether you can ask Copilot about it now: it failed, its run was read, on an open pull request, with Send Work to
    /// Copilot on; in the demo too, which answers Explain with made-up answers.
    private var canAct: Bool {
        guard part != nil, copilot.isOn, copilot.canSend || copilot.mode == .demo, investigation.run.status == .failed, let record else {
            return false
        }
        return record.pullRequest.status == .active
    }

    /// Fix is for your own pull requests, as Fix the Build is.
    private var canFix: Bool { record?.role == .author }

    private var names: CopilotSessionNames {
        CopilotSessionNames(session: sessions.session(for: item.key), copilot: copilot, links: sessions.links)
    }

    /// What Copilot does about it, while it shows on the build.
    private var work: CopilotWork? {
        BuildCopilot.work(on: line, of: item.key, copilot: copilot, preview: preview)
    }

    /// What a session said of this run of it with Explain.
    private var question: CopilotQuestions.Question? {
        BuildCopilot.question(about: line, run: investigation.run.id, of: item.key, questions: questions, preview: preview)
    }

    /// No Copilot session goes with the pull request, as its line found them: Explain has nobody to ask.
    private var hasNobodyToAsk: Bool {
        guard preview == nil, let session = sessions.session(for: item.key) else { return false }
        return CopilotDestinations.make(session, worked: work?.session, ask: .explain).all.isEmpty
    }

    var body: some View {
        let question = question
        let work = work
        VStack(alignment: .leading, spacing: 8) {
            if copilot.isOn {
                if let question {
                    questionView(question)
                }
                // Not while a session explains it, as on a comment.
                if let work, question?.isAsking != true {
                    BuildCopilot.workLine(work, names: names, now: now, navigation: navigation)
                }
                if let copied {
                    CopilotCopiedNote(note: copied) { self.copied = nil }
                }
                if canAct {
                    if let asking, let part {
                        BuildComposer(
                            ask: asking, line: line, part: part, investigation: investigation, item: item, worked: work?.session,
                            drafts: drafts, answer: question?.answer, preview: preview?.composer(about: part),
                            fixInstead: canFix ? { open(.fix) } : nil
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
            // Its run, under what Copilot can do about it, where it stays as a composer opens.
            FlowLayout(spacing: 8, lineSpacing: 8) {
                trailing()
            }
            .controlSize(.small)
            // A small button's own size, which follows the window's text size, as what's beside them does.
            .font(size: 11)
        }
        .onAppear {
            if let part, let composer = preview?.composer(about: part) { composing = CopilotComposing(part: part, ask: composer.ask) }
        }
    }

    private func buttons(hasAnswer: Bool) -> some View {
        let nobody = hasNobodyToAsk
        let explainTitle: String = hasAnswer ? "Ask More" : CopilotAsk.explain.title(about: part)
        return HStack(spacing: 8) {
            Button {
                open(.explain)
            } label: {
                Label(explainTitle, systemImage: CopilotAsk.explain.symbol)
            }
            .glassButtonStyle()
            .focused($focused, equals: .explain)
            .disabled(nobody)
            .help(explainHelp(nobody: nobody, hasAnswer: hasAnswer))
            if canFix {
                Button {
                    open(.fix)
                } label: {
                    Label("Fix", systemImage: CopilotAsk.fix.symbol)
                }
                .glassButtonStyle()
                .focused($focused, equals: .fix)
                .help(hasAnswer
                    ? "Have Copilot reproduce the failure and fix it, as you say, with what the session answered: it doesn't commit, push or touch pipelines"
                    : "Have Copilot reproduce the failure and fix it, as you say: it doesn't commit, push or touch pipelines")
            }
        }
        .controlSize(.small)
        .font(size: 11)
    }

    private func explainHelp(nobody: Bool, hasAnswer: Bool) -> String {
        if nobody {
            return "No Copilot session goes with this pull request to ask why it failed" + (canFix ? ". Fix starts one." : ".")
        }
        if hasAnswer { return "Ask the session more about this failure, with what it answered in mind" }
        return "Ask the Copilot session that worked on it why this build failed, and whether it's this change, a flaky test or the build's infrastructure"
    }

    /// Opens its composer, closing any other in the details, whose words stay for when it opens again.
    private func open(_ ask: CopilotAsk) {
        guard let part else { return }
        copied = nil
        composing = CopilotComposing(part: part, ask: ask)
    }

    /// Closes its composer, unless another opened meanwhile, and gives the keyboard's focus back to its button.
    private func close(_ ask: CopilotAsk) {
        guard let part, composing == CopilotComposing(part: part, ask: ask) else { return }
        composing = nil
        Task { @MainActor in focused = ask }
    }

    @ViewBuilder
    private func questionView(_ question: CopilotQuestions.Question) -> some View {
        let place = names.place(question.session)
        switch question.state {
        case .asking:
            BuildCopilot.askingLine(question, names: names, now: now) {
                if let part { questions.stop(about: part, of: item.key) }
            }
        case .answered(let answer):
            CopilotAnswerCard(
                answer: answer, asked: question.asked, place: place, answeredAt: question.endedAt ?? question.askedAt, now: now,
                open: names.opener(question.session, isTask: names.isTask(question.session), navigation: navigation)
            ) {
                if let part { questions.dismiss(about: part, of: item.key) }
            }
        case .failed(let failure):
            CopilotWorkLine(
                symbol: "exclamationmark.triangle.fill", text: "Couldn't explain it: " + failure.message(model: nil), state: .failing,
                since: question.endedAt, now: now, detail: failure.detail
            ) {
                if ThreadCopilotActions.asksInSessionInstead(failure), let choice = names.choice(question.session), copilot.canSend {
                    Button(isAskingInSession ? "Asking…" : "Ask in the Session") {
                        askInSession(choice, question: question)
                    }
                    .buttonStyle(.borderless)
                    .font(size: 11.5, weight: .medium)
                    .fixedSize()
                    .disabled(isAskingInSession)
                    .help("Send the question to the session as a prompt, as Fix sends its prompts: it goes in the session's history, and changes nothing")
                }
                CopilotDismissButton { if let part { questions.dismiss(about: part, of: item.key) } }
            }
        }
    }

    private func askInSession(_ choice: SessionChoice, question: CopilotQuestions.Question) {
        guard let record, let part else { return }
        let sending = CopilotSending(item: item, record: record, store: store, copilot: copilot, session: sessions.session(for: item.key))
        let prompt = PullRequestPrompt.askAboutBuild(
            record, build: FailedBuildReport(investigation, name: line.run.name), question: question.asked, earlier: question.earlier
        )
        isAskingInSession = true
        drafts.asks[part]?.cancel()
        drafts.asks[part] = Task {
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
}

/// The composer in place for what you ask about a failed build (`CopilotPartComposer`): Explain the Failure, which asks a
/// session aside why it failed, and Fix, which has Copilot reproduce it and fix it, as you say. Both quote what was read of
/// its run as it opened (`FailedBuildReport`): where it failed, its errors, the tests that failed with what each said, the
/// end of the failed step's log, and whether it's the change's doing.
struct BuildComposer: View {
    let ask: CopilotAsk
    let line: PullRequestPanel.CheckLine
    let part: PullRequestPart
    let investigation: BuildInvestigation
    let item: PRSnapshot
    /// The session that worked on the build, by its ID, which it goes to first.
    let worked: String?
    let drafts: CopilotDrafts
    /// What a session answered about it with Explain, while it shows: Ask More follows up on it, and Fix builds on it.
    var answer: CopilotAnswer?
    /// For `--render`: what it shows.
    var preview: CopilotActionsPreview.Composer?
    /// Explain had no session to ask: Fix opens instead.
    var fixInstead: (() -> Void)?
    /// It's done: sent, copied for you to paste, or closed.
    let done: (CopilotSending.Outcome?) -> Void

    @EnvironmentObject private var store: PRStore

    /// What it asks, and the prompts it sends, about this run.
    private var asking: CopilotAsking {
        let record = store.record(for: item.key)
        let report = FailedBuildReport(investigation, name: line.run.name)
        let part = part
        return CopilotAsking(
            ask: ask, part: part, action: .fixBuild, run: investigation.run.id,
            fix: { how, answer in
                guard let record else { return CopilotSending.Fix(prompts: ("", ""), action: .fixBuild, parts: [], handOff: nil) }
                return CopilotSending.Fix(
                    prompts: (
                        PullRequestPrompt.fixBuild(record, failures: [report], workplace: .worktree, how: how, answer: answer, alone: true),
                        PullRequestPrompt.fixBuild(record, failures: [report], workplace: .agent, how: how, answer: answer, alone: true)
                    ),
                    action: .fixBuild, parts: [part], handOff: nil
                )
            },
            question: { asked, earlier in
                guard let record else { return "" }
                return PullRequestPrompt.explainBuild(record, build: report, question: asked, earlier: earlier)
            }
        )
    }

    var body: some View {
        CopilotPartComposer(
            asking: asking, item: item, worked: worked, drafts: drafts, answer: answer, preview: preview, fixInstead: fixInstead, done: done
        )
    }
}
