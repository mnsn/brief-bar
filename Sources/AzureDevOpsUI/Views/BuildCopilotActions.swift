import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

// Copilot in a pull request's builds, while Send Work to Copilot is on: on a failed build that's open in its details,
// ✨ Explain the Failure and Fix, each with a composer in place, as a comment has; and on each build's row, what Copilot does
// about it, in a sentence. What they share with comments and conflicts is in CopilotActions.swift.

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
    /// Whether it shows on a build's row: while Copilot is at it, or the build doesn't pass. A rerun, or a push, that passes
    /// ends it.
    func shows(onBuild state: Check.State?) -> Bool {
        isActive || state?.needsNoFix != true
    }
}

/// What Copilot does about one of a pull request's builds, on its row, in a sentence in its state's color, with since when
/// and the step it's at: "Copilot is fixing this build in ‘Fix the Build’ · 9m", "Fixed in ‘Fix the Build’, not pushed". A
/// click opens where it works, when something can. Once the build passes, as when it ran again or after a push, it's over,
/// unless Copilot is still at it.
struct BuildWorkLine: View {
    let line: PullRequestPanel.CheckLine
    let item: PRSnapshot
    let now: Date

    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var sessions: PullRequestSessions
    @Environment(\.itemNavigation) private var navigation
    @Environment(\.copilotActionsPreview) private var preview

    private var part: PullRequestPart? { line.check?.part }

    private var names: CopilotSessionNames {
        CopilotSessionNames(session: sessions.session(for: item.key), copilot: copilot, links: sessions.links)
    }

    private var work: CopilotWork? {
        guard let part else { return nil }
        let work = preview.map { preview in preview.work(on: part) { copilot.work(on: part, of: item.key) } } ?? copilot.work(on: part, of: item.key)
        guard let work, work.shows(onBuild: line.check?.state) else { return nil }
        return work
    }

    var body: some View {
        let work = work
        Group {
            if let work {
                let look = work.look
                CopilotWorkLine(
                    symbol: look.symbol, text: names.sentence(work), state: look.state, since: work.since, now: now, subtitle: work.step,
                    detail: work.said, open: names.opener(work.session, isTask: work.isTask, navigation: navigation)
                )
                // Under its name and status.
                .padding(.leading, 24)
                .padding(.top, 6)
            }
        }
        // VoiceOver hears what became of it as it happens, wherever it is: not what shows as it's read.
        .onChange(of: work?.state) { old, state in
            guard let old, CopilotWork.isOngoing(old), let work, let state else { return }
            switch state {
            case .done, .failed, .stopped, .needsYou:
                SpokenText.announce("\(line.run.name): \(SpokenText.unquoted(names.sentence(work)))")
            case .waiting, .working, .unknown:
                break
            }
        }
    }
}

/// Copilot's part in a failed build that's open in a pull request's details, while Send Work to Copilot is on: what a
/// session said of it with Explain, then ✨ Explain the Failure, or Ask More once it answered, and Fix, before what else it
/// can do (`trailing`), such as Open Run; each opens a small composer in place under them, one at a time in the builds and
/// checks. Explain asks the session that worked on the build, or the pull request's, why it failed, and whether it's the
/// change's doing, a flaky test or the build's infrastructure; Fix has Copilot reproduce it and fix it, as you say, without
/// committing, pushing or touching pipelines.
struct BuildCopilotActions<Trailing: View>: View {
    let line: PullRequestPanel.CheckLine
    let item: PRSnapshot
    let investigation: BuildInvestigation
    let now: Date
    /// The composer in place that's open in the builds and checks.
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

    /// The session that worked on it last, which Explain and Fix go to first.
    private var worked: String? {
        guard let part else { return nil }
        if let preview { return preview.work(on: part) { copilot.work(on: part, of: item.key) }?.session }
        return copilot.work(on: part, of: item.key)?.session
    }

    /// What a session said of this run of it with Explain: one about another run of it isn't this one's.
    private var question: CopilotQuestions.Question? {
        guard let part else { return nil }
        let question = preview?.question(about: part) ?? questions.question(about: part, of: item.key)
        guard let question, question.run == nil || question.run == investigation.run.id else { return nil }
        return question
    }

    /// No Copilot session goes with the pull request, as its line found them: Explain has nobody to ask.
    private var hasNobodyToAsk: Bool {
        guard preview == nil, let session = sessions.session(for: item.key) else { return false }
        return CopilotDestinations.make(session, worked: worked, ask: .explain).all.isEmpty
    }

    var body: some View {
        let question = question
        VStack(alignment: .leading, spacing: 8) {
            if copilot.isOn, let question {
                questionView(question)
            }
            if copilot.isOn, let copied {
                CopilotCopiedNote(note: copied) { self.copied = nil }
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                if canAct, asking == nil {
                    buttons(hasAnswer: question?.answer != nil)
                }
                trailing()
            }
            .controlSize(.small)
            // A small button's own size, which follows the window's text size, as what's beside them does.
            .font(size: 11)
            if canAct, let asking, let part {
                BuildComposer(
                    ask: asking, line: line, part: part, investigation: investigation, item: item, worked: worked, drafts: drafts,
                    answer: question?.answer, preview: preview?.composer(about: part), fixInstead: canFix ? { open(.fix) } : nil
                ) { result in
                    if case .copied(let note)? = result { copied = note }
                    close(asking)
                }
                // A new composer for each, with its own words and where it goes.
                .id(asking)
            }
        }
        .onAppear {
            if let part, let composer = preview?.composer(about: part) { composing = CopilotComposing(part: part, ask: composer.ask) }
        }
        // VoiceOver hears what became of it as it happens, wherever it is: not what shows as it's read.
        .onChange(of: question?.state) { old, state in if old == .asking { announce(state) } }
    }

    @ViewBuilder
    private func buttons(hasAnswer: Bool) -> some View {
        let nobody = hasNobodyToAsk
        Button {
            open(.explain)
        } label: {
            Label(hasAnswer ? "Ask More" : CopilotAsk.explain.title(about: part), systemImage: CopilotAsk.explain.symbol)
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

    private func explainHelp(nobody: Bool, hasAnswer: Bool) -> String {
        if nobody {
            return "No Copilot session goes with this pull request to ask why it failed" + (canFix ? ". Fix starts one." : ".")
        }
        if hasAnswer { return "Ask the session more about this failure, with what it answered in mind" }
        return "Ask the Copilot session that worked on it why this build failed, and whether it's this change, a flaky test or the build's infrastructure"
    }

    /// Opens its composer, closing any other in the builds and checks, whose words stay for when it opens again.
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
        let place = CopilotWork.place(names.name(question.session), isFork: false, forkOf: nil)
        switch question.state {
        case .asking:
            CopilotWorkLine(
                symbol: "sparkles", text: "Copilot is explaining the failure in \(place)", state: .running, since: question.askedAt, now: now,
                subtitle: question.asked.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "You asked: \($0)" }
            ) {
                Button("Stop") {
                    if let part { questions.stop(about: part, of: item.key) }
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

    /// What VoiceOver hears as Explain ends: who answered, or why it couldn't.
    private func announce(_ state: CopilotQuestions.Question.State?) {
        guard let question else { return }
        switch state {
        case .answered?:
            let place = CopilotWork.place(names.name(question.session), isFork: false, forkOf: nil)
            SpokenText.announce("\(line.run.name): \(SpokenText.unquoted(place)) answered")
        case .failed(let failure)?:
            SpokenText.announce("\(line.run.name): couldn't explain it. \(failure.message(model: nil))")
        case .asking?, nil:
            break
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
