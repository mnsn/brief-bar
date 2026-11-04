import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// A pull request's merge conflicts, in its details, while Azure DevOps says it has some: the files that conflict with its
/// target branch, and how, each saying what each branch did to it, read as the details show it
/// (`PullRequestConflictsStore`). A file opens its changes in the details, as its row in Files does. Under them, while Send
/// Work to Copilot is on, what Copilot does about them, in a sentence, then ✨ Explain, which asks the session that worked
/// on the pull request why they conflict, and, on your own, **Resolve**, which has Copilot merge the target branch in and
/// resolve them, each in a small composer in place. ↗ opens the pull request in Azure DevOps, to resolve them there.
struct PullRequestConflictsSection: View {
    @ObservedObject var details: PullRequestDetailsStore
    let item: PRSnapshot
    /// The pull request as the list read it last: open, and its merge conflicts.
    let pullRequest: PullRequest
    /// The composer in place that's open in the details, one at a time in them, so Esc, Return and the keyboard's focus are
    /// its own; and what you wrote in each. What one sends is called off as it closes or another opens, and with the rest of
    /// the details' as their parts go, for a file's page or with them (`PullRequestDetailsContent`); not as this section
    /// goes on its own, while Azure DevOps works the merge out again.
    @Binding var composing: CopilotComposing?
    let drafts: CopilotDrafts

    @EnvironmentObject private var conflicts: PullRequestConflictsStore
    @EnvironmentObject private var code: PullRequestCodeStore
    @EnvironmentObject private var store: PRStore
    @Environment(\.shownSection) private var section
    @Environment(\.shownWindow) private var window

    /// What they're read again for, while they show: a push or another target, and a window showing them on screen again,
    /// after none did.
    private struct Reading: Equatable {
        var visibilityChanges: Int
        var head: PullRequestFilesStore.Head
    }

    /// The window's page it's on: nil outside one, where nothing is read.
    private var page: String? {
        guard let section, let window else { return nil }
        return PullRequestCodeStore.page(section, window: window)
    }

    var body: some View {
        let state = conflicts.state(of: pullRequest.key)
        VStack(alignment: .leading, spacing: 8) {
            header(state)
            switch state {
            case .read(let read)?:
                list(read)
            case .failed(let error)?:
                unreadable(error)
            case .reading?, nil:
                placeholder
            }
            // What Copilot does about them, Explain and Resolve.
            ConflictsCopilotActions(item: item, now: store.now, composing: $composing, drafts: drafts)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: Reading(visibilityChanges: code.visibilityChanges, head: PullRequestFilesStore.Head(pullRequest))) {
            // Asked for again every half minute while they show, for what couldn't be read, which the store reads again
            // then.
            while !Task.isCancelled {
                conflicts.show(pullRequest, on: page)
                try? await Task.sleep(for: .seconds(PullRequestCodeStore.retryInterval))
            }
        }
        // Read, and kept, while they show: in the panel's details, or on a pull request's page.
        .task(id: item.key) {
            let hold = code.hold(item.key)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
            }
            code.release(hold)
        }
    }

    // MARK: Header

    private func header(_ state: PullRequestConflictsStore.State?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            let count: Int? = if case .read(let read)? = state, !read.files.isEmpty { read.files.count } else { nil }
            PageSectionHeader(title: "Merge Conflicts", count: count)
            Spacer(minLength: 8)
            Button {
                AzureDevOps.open(item.pageURL())
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(size: 11.5, weight: .medium)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open the pull request in Azure DevOps, to resolve its conflicts there")
            .accessibilityLabel("Resolve in Azure DevOps")
        }
    }

    // MARK: The list

    @ViewBuilder
    private func list(_ read: MergeConflicts) -> some View {
        if read.files.isEmpty {
            notice(
                "Azure DevOps doesn't list which files conflict yet. It shows them on the pull request, where you can resolve them.",
                symbol: "questionmark.circle", again: nil
            )
        } else {
            Text(summary(read))
                .font(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(read.files.enumerated()), id: \.element.id) { index, conflict in
                    if index > 0 {
                        Divider()
                            .opacity(0.6)
                            .padding(.leading, 32)
                    }
                    ConflictRow(conflict: conflict, item: item, pullRequest: pullRequest) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            details.open(file: conflict.pathInPullRequest, from: .section(.conflicts), scope: .whole)
                        }
                    }
                }
            }
            .padding(.vertical, 3)
            .background(GlassCard(cornerRadius: 12, raised: true))
        }
    }

    /// "3 files conflict with main." With some resolved in Azure DevOps, which hasn't committed them, and more than BriefBar
    /// reads, it says so.
    private func summary(_ read: MergeConflicts) -> String {
        let count = read.files.count
        let target = pullRequest.targetBranch.isEmpty ? "the target branch" : pullRequest.targetBranch
        let conflict = count == 1 ? "1 file conflicts" : "\(count) files conflict"
        // When there may be more than it read, as many as it did at least.
        var parts = [read.isComplete
            ? "\(conflict) with \(target)." : "At least \(conflict) with \(target): these are the first Azure DevOps lists."]
        let resolved = count - read.unresolved.count
        if resolved > 0 {
            parts.append(resolved == 1
                ? "1 is resolved in Azure DevOps, which hasn't committed it yet."
                : "\(resolved) are resolved in Azure DevOps, which hasn't committed them yet.")
        }
        return parts.joined(separator: " ")
    }

    /// Why they can't show, with Try Again when that may help.
    private func unreadable(_ error: ADOError) -> some View {
        let why = switch error {
        case .notFound: "Azure DevOps doesn't list them for this pull request."
        case .forbidden: "You don't have access to them."
        default: error.description
        }
        return notice(
            "BriefBar can't list the files that conflict. " + why, symbol: "eye.slash",
            again: PullRequestConflictsStore.mayPass(error) ? { conflicts.show(pullRequest, on: page, again: true) } : nil
        )
    }

    /// A sentence with its symbol, and Try Again when that may help.
    private func notice(_ text: String, symbol: String, again: (() -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(size: 10.5, weight: .medium)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let again {
                Button(action: again) {
                    Image(systemName: "arrow.clockwise")
                        .font(size: 11, weight: .medium)
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Read them again")
                .accessibilityLabel("Try Again")
            }
        }
        .font(size: 12)
        .foregroundStyle(.secondary)
    }

    /// A few rows' worth, until they're read.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach([0.5, 0.38], id: \.self) { width in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 12, height: 12)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 260 * width, height: 9)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassCard(cornerRadius: 12, raised: true))
        .accessibilityElement()
        .accessibilityLabel("Reading the files that conflict")
    }
}

/// A file that conflicts: its name and folder, and what each branch did to it. A click opens its changes in the details;
/// for a folder on the pull request's branch, which has none of its own, or a file in a folder that's a file on the other
/// branch, which may be on the target's side alone, the pull request's files in Azure DevOps, there.
private struct ConflictRow: View {
    let conflict: MergeConflict
    let item: PRSnapshot
    let pullRequest: PullRequest
    let open: () -> Void

    @Environment(\.textScale) private var textScale
    @LocalState private var isHovered = false

    /// "Changed on both branches", and, once someone resolved it in Azure DevOps, that it isn't committed.
    private var how: String {
        let how = conflict.how(source: pullRequest.sourceBranch, target: pullRequest.targetBranch)
        return conflict.isResolved ? how + " · resolved in Azure DevOps, not committed yet" : how
    }

    /// A folder on the pull request's branch.
    private var isFolder: Bool { conflict.isFolderInPullRequest }
    /// What opens in Azure DevOps, rather than in the details.
    private var opensInAzureDevOps: Bool { conflict.showsInAzureDevOps }

    private func activate() {
        if opensInAzureDevOps { openInAzureDevOps() } else { open() }
    }

    private func openInAzureDevOps() {
        AzureDevOps.open(Self.filePage(conflict.pathInPullRequest, of: item))
    }

    var body: some View {
        Button(action: activate) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: conflict.isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(size: 11.5, weight: .semibold)
                    .foregroundStyle(conflict.isResolved ? ItemState.done.color : ItemState.failing.color)
                    .frame(width: 14 * textScale)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(conflict.name)
                            .font(size: 12.5, weight: .medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        if let folder = conflict.folder {
                            Text(folder)
                                .font(size: 11.5)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Text(how)
                        .font(size: 11.5)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: opensInAzureDevOps ? "arrow.up.forward.app" : "chevron.right")
                    .font(size: opensInAzureDevOps ? 10.5 : 9, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
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
        .help(conflict.path + " · " + how + clickHelp)
        .contextMenu {
            if !opensInAzureDevOps {
                Button("Show Its Changes", action: open)
            }
            Button("Open in Azure DevOps", action: openInAzureDevOps)
            Button("Copy Path") { PullRequestDetailsPanel.copy(conflict.path) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isFolder ? "Opens this folder's files in Azure DevOps"
            : opensInAzureDevOps ? "Opens it in the pull request's files in Azure DevOps" : "Shows what this pull request changed in it")
        .accessibilityAddTraits(.isButton)
    }

    /// What a click does, under where it is and how it conflicts.
    private var clickHelp: String {
        if isFolder { return "\nA folder on this pull request's branch: click to see its files in Azure DevOps" }
        if opensInAzureDevOps { return "\nIt may be on one branch alone: click to see it in Azure DevOps" }
        return "\nClick to see what this pull request changed in it"
    }

    /// "OrderService.cs, in src/Orders, changed on both branches".
    private var accessibilityLabel: String {
        [conflict.name, conflict.folder.map { "in \($0)" } ?? "at the top", how].joined(separator: ", ")
    }

    /// The pull request's Files page in Azure DevOps, at a file.
    static func filePage(_ path: String, of item: PRSnapshot) -> URL {
        var components = URLComponents(url: item.pageURL(), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "_a", value: "files"), URLQueryItem(name: "path", value: path)]
        return components?.url ?? item.pageURL()
    }
}

// MARK: - Copilot

/// Copilot's part in a pull request's merge conflicts, under them, while Send Work to Copilot is on: what Copilot does about
/// them, in a sentence; what a session said of them with Explain; and ✨ Explain, or Ask More once it answered, and, on your
/// own pull request, Resolve, side by side, each opening a small composer in place.
private struct ConflictsCopilotActions: View {
    let item: PRSnapshot
    let now: Date
    /// The composer in place that's open on them.
    @Binding var composing: CopilotComposing?
    let drafts: CopilotDrafts

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var sessions: PullRequestSessions
    @EnvironmentObject private var questions: CopilotQuestions
    @EnvironmentObject private var conflicts: PullRequestConflictsStore
    @Environment(\.itemNavigation) private var navigation
    @Environment(\.copilotActionsPreview) private var preview

    /// What BriefBar said once it copied a prompt for you to paste, or why nothing went, until you close it.
    @LocalState private var copied: String?
    @LocalState private var isAskingInSession = false
    /// Explain or Resolve, for the keyboard's focus to go back to once its composer closes.
    @FocusState private var focused: CopilotAsk?

    private let part = PullRequestPart.conflicts

    private var record: PRRecord? { store.record(for: item.key) }

    /// The composer in place that's open on them, if one is.
    private var asking: CopilotAsk? { composing?.part == part ? composing?.ask : nil }

    /// Whether you can ask Copilot about them now: the pull request is open, with conflicts, and Send Work to Copilot is on;
    /// in the demo too, which answers Explain with made-up answers.
    private var canAct: Bool {
        guard copilot.isOn, copilot.canSend || copilot.mode == .demo, let record else { return false }
        return record.pullRequest.status == .active && record.pullRequest.hasConflicts
    }

    /// Resolve is for your own pull requests, as Resolve Conflicts is.
    private var canResolve: Bool { record?.role == .author }

    private var names: CopilotSessionNames {
        CopilotSessionNames(session: sessions.session(for: item.key), copilot: copilot, links: sessions.links)
    }

    private var work: CopilotWork? {
        guard let preview else { return copilot.work(on: part, of: item.key) }
        return preview.work(on: part) { copilot.work(on: part, of: item.key) }
    }

    private var question: CopilotQuestions.Question? {
        if let preview = preview?.question(about: part) { return preview }
        // Not one asked before a push or a retarget, which the list's next read dismisses: they conflict otherwise now.
        guard let question = questions.question(about: part, of: item.key) else { return nil }
        if let asked = question.head, let record, PullRequestFilesStore.Head(record.pullRequest) != asked { return nil }
        return question
    }

    /// No Copilot session goes with the pull request, as its line found them: Explain has nobody to ask.
    private var hasNobodyToAsk: Bool {
        guard preview == nil, let session = sessions.session(for: item.key) else { return false }
        return CopilotDestinations.make(session, worked: work?.session, ask: .explain).all.isEmpty
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
                    CopilotCopiedNote(note: copied) { self.copied = nil }
                }
                if canAct {
                    if let asking {
                        ConflictsComposer(
                            ask: asking, item: item, worked: work?.session, drafts: drafts, answer: question?.answer,
                            answeredAbout: question?.head, preview: preview?.composer(about: part),
                            fixInstead: canResolve ? { open(.fix) } : nil
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
            .padding(.top, 2)
            .onAppear {
                if let composer = preview?.composer(about: part) { composing = CopilotComposing(part: part, ask: composer.ask) }
            }
            // VoiceOver hears what became of them as it happens, wherever it is: not what shows as it's read.
            .onChange(of: question?.state) { old, state in if old == .asking { announce(state) } }
            .onChange(of: work?.state) { old, state in if let old, CopilotWork.isOngoing(old) { announce(state) } }
        }
    }

    private func buttons(hasAnswer: Bool) -> some View {
        let nobody = hasNobodyToAsk
        let target = record?.pullRequest.targetBranch ?? "the target branch"
        return HStack(spacing: 6) {
            Button {
                open(.explain)
            } label: {
                Label(hasAnswer ? "Ask More" : "Explain", systemImage: CopilotAsk.explain.symbol)
            }
            .focused($focused, equals: .explain)
            .disabled(nobody)
            .help(explainHelp(nobody: nobody, hasAnswer: hasAnswer, target: target))
            if canResolve {
                Button {
                    open(.fix)
                } label: {
                    Label("Resolve", systemImage: CopilotAsk.fix.symbol)
                }
                .focused($focused, equals: .fix)
                .help("Have Copilot merge \(target) in and resolve the conflicts, as you say"
                    + (hasAnswer ? ", with what the session answered" : "") + ": it may commit the merge, but doesn't push")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(size: 11.5, weight: .medium)
    }

    private func explainHelp(nobody: Bool, hasAnswer: Bool, target: String) -> String {
        if nobody {
            return "No Copilot session goes with this pull request to ask why its files conflict" + (canResolve ? ". Resolve starts one." : ".")
        }
        if hasAnswer { return "Ask the session more about the conflicts, with what it answered in mind" }
        return "Ask the Copilot session that worked on this pull request why its files conflict with \(target), and how to resolve them"
    }

    /// Opens its composer, closing the other, whose words stay for when it opens again.
    private func open(_ ask: CopilotAsk) {
        copied = nil
        composing = CopilotComposing(part: part, ask: ask)
    }

    /// Closes its composer, unless another opened meanwhile, and gives the keyboard's focus back to its button.
    private func close(_ ask: CopilotAsk) {
        guard composing == CopilotComposing(part: part, ask: ask) else { return }
        composing = nil
        Task { @MainActor in focused = ask }
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
        let place = names.place(question.session)
        switch question.state {
        case .asking:
            CopilotWorkLine(
                symbol: "sparkles", text: "Copilot is explaining the conflicts in \(place)", state: .running, since: question.askedAt,
                now: now, subtitle: question.asked.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "You asked: \($0)" }
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
                symbol: "exclamationmark.triangle.fill", text: "Couldn't explain them: " + failure.message(model: nil), state: .failing,
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
                    .help("Send the question to the session as a prompt, as Resolve sends its prompts: it goes in the session's history, and changes nothing")
                }
                CopilotDismissButton { questions.dismiss(about: part, of: item.key) }
            }
        }
    }

    /// Asks the session as a prompt it takes up itself, for when it can't be asked aside: in its own history, where it reads
    /// the code and the target branch too, but changes nothing.
    private func askInSession(_ choice: SessionChoice, question: CopilotQuestions.Question) {
        guard record != nil else { return }
        isAskingInSession = true
        let part = part
        let conflicts = conflicts
        let store = store
        let key = item.key
        drafts.asks[part]?.cancel()
        drafts.asks[part] = Task {
            // As the pull request is once the read under way ends, pushed to or retargeted meanwhile or not.
            let current = await conflicts.forPrompt(key) { store.record(for: key) }
            guard !Task.isCancelled else { return }
            guard let current else {
                drafts.asks[part] = nil
                isAskingInSession = false
                return
            }
            let sending = CopilotSending(item: item, record: current.record, store: store, copilot: copilot, session: sessions.session(for: key))
            let prompt = PullRequestPrompt.askAboutConflicts(
                current.record, conflicts: current.conflicts, question: question.asked, earlier: question.earlier
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

    /// What VoiceOver hears as Explain ends: who answered, or why it couldn't. Once, though the conflicts show in more than
    /// one place.
    private func announce(_ state: CopilotQuestions.Question.State?) {
        guard let question else { return }
        let said: String
        switch state {
        case .answered?:
            said = "\(SpokenText.unquoted(names.place(question.session))) answered"
        case .failed(let failure)?:
            said = "couldn't explain them. \(failure.message(model: nil))"
        case .asking?, nil:
            return
        }
        SpokenText.announce(
            "The conflicts: \(said)", once: .init(pullRequest: item.key, part: part, said: said, since: question.endedAt ?? question.askedAt)
        )
    }

    /// What VoiceOver hears as Copilot's work on them ends, or waits for you. Once, though the conflicts show in more than
    /// one place.
    private func announce(_ state: CopilotWork.State?) {
        guard let work, let state else { return }
        switch state {
        case .done, .failed, .stopped, .needsYou:
            let said = names.announcement(work)
            SpokenText.announce("The conflicts: \(said)", once: .init(pullRequest: item.key, part: part, said: said, since: work.since))
        case .waiting, .working, .unknown:
            break
        }
    }
}

/// The composer in place for what you ask about a pull request's merge conflicts (`CopilotPartComposer`): Explain, which
/// asks a session why they conflict, or Resolve, which has Copilot merge the target branch in and resolve them, in a box of
/// its own under them. Its prompts list the files that conflict, and how, once they're read: sent while they're read, it
/// waits for them.
private struct ConflictsComposer: View {
    let ask: CopilotAsk
    let item: PRSnapshot
    /// The session that worked on them, by its ID, which it goes to first.
    let worked: String?
    /// What you wrote in it before, kept as you open another.
    let drafts: CopilotDrafts
    /// What a session answered about them with Explain, while it shows: Ask More follows up on it, and Resolve builds on it.
    var answer: CopilotAnswer?
    /// The branches it was about: once they move while a send waits for the files, it's left out.
    var answeredAbout: PullRequestFilesStore.Head?
    /// For `--render`: what it shows.
    var preview: CopilotActionsPreview.Composer?
    /// Explain had no session to ask: Resolve opens instead.
    var fixInstead: (() -> Void)?
    /// It's done: sent, copied for you to paste, or closed.
    let done: (CopilotSending.Outcome?) -> Void

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var conflicts: PullRequestConflictsStore

    /// What it asks, and the prompts it sends, for the pull request as it is when it's sent, with the files that conflict
    /// as they're read for it then.
    private var asking: CopilotAsking {
        let store = store
        let conflicts = conflicts
        let key = item.key
        let sent = Sent()
        // The files are read before it's sent, while they're being read: its prompts list them once they are, for the pull
        // request as it is then, pushed to or retargeted meanwhile or not.
        var prepare: (@MainActor () async -> Void)?
        if conflicts.state(of: key) == .reading {
            prepare = { sent.current = await conflicts.forPrompt(key) { store.record(for: key) } }
        }
        // Without a read under way, as it is when it's sent.
        let current = { () -> (record: PRRecord, conflicts: MergeConflicts?)? in
            sent.current ?? store.record(for: key).map { ($0, conflicts.conflicts(for: $0.pullRequest)) }
        }
        return CopilotAsking(
            ask: ask, part: .conflicts, action: .resolveConflicts, prepare: prepare,
            head: { current().map { PullRequestFilesStore.Head($0.record.pullRequest) } }, answeredAbout: answeredAbout,
            fix: { how, answer in
                guard let now = current() else {
                    return CopilotSending.Fix(prompts: ("", ""), action: .resolveConflicts, parts: [], handOff: nil)
                }
                return CopilotSending.Fix(
                    prompts: (
                        PullRequestPrompt.resolveConflicts(now.record, workplace: .worktree, conflicts: now.conflicts, note: how, answer: answer),
                        PullRequestPrompt.resolveConflicts(now.record, workplace: .agent, conflicts: now.conflicts, note: how, answer: answer)
                    ),
                    action: .resolveConflicts, parts: [.conflicts], handOff: nil
                )
            },
            question: { asked, earlier in
                guard let now = current() else { return "" }
                return PullRequestPrompt.explainConflicts(now.record, conflicts: now.conflicts, question: asked, earlier: earlier)
            }
        )
    }

    /// What a send's wait for the files found: the pull request then, and the files read for it.
    @MainActor
    private final class Sent {
        var current: (record: PRRecord, conflicts: MergeConflicts?)?
    }

    var body: some View {
        CopilotPartComposer(
            asking: asking, item: item, worked: worked, drafts: drafts, answer: answer, preview: preview, fixInstead: fixInstead,
            isFramed: true
        ) { outcome in
            done(outcome)
        }
    }
}
