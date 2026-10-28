import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// The window that sends a work item, or a pull request's comments, build or conflicts, to Copilot: the prompt, which
/// you can change, the model, and where it goes: a new session, in a worktree of the repository it goes in, or a session
/// that's there already, such as BriefBar's earlier task's or the Copilot app's session that opened the pull request. A
/// window of its own, since popovers and widgets can't hold a sheet.
@MainActor
final class CopilotComposer: NSObject, NSWindowDelegate {
    static let shared = CopilotComposer()
    private var window: NSWindow?

    func show(item: TaskWorkItem, options: CopilotRunOptions, store: CopilotTasksStore) {
        show(subject: .workItem(item), prompt: nil, options: options, continuing: nil, store: store)
    }

    /// - Parameters:
    ///   - prompt: a pull request's, written for it, for a worktree of BriefBar's; nil for a work item's, from the template
    ///     in Settings.
    ///   - sessionPrompt: a pull request's, for a session that works wherever it is, such as one of the Copilot app's.
    ///   - createdAt: when the pull request was created.
    ///   - continuing: an earlier run whose session it goes on with, unless you choose another.
    ///   - handOff: what a pull request's prompt takes off Needs You once it's sent, as it was written.
    func show(
        subject: TaskSubject, prompt: String?, sessionPrompt: String? = nil, createdAt: Date? = nil, options: CopilotRunOptions,
        continuing: CopilotRun?, handOff: CommentHandOff? = nil, store: CopilotTasksStore
    ) {
        let view = CopilotComposerView(
            subject: subject, options: options, template: store.settings.copilotPromptTemplate, prompt: prompt,
            sessionPrompt: sessionPrompt, createdAt: createdAt, continuing: continuing, handOff: handOff
        ) { [weak self] in
            self?.window?.close()
        }
        .environmentObject(store)
        .environmentObject(store.settings)
        let host = NSHostingController(rootView: AnyView(view))
        host.sizingOptions = [.preferredContentSize]
        let window = window ?? {
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            return window
        }()
        window.contentViewController = host
        window.title = "Send to Copilot"
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { window = nil }
    }
}

struct CopilotComposerView: View {
    /// How a task goes to a session that's there already.
    enum Delivery: Hashable {
        /// The prompt copied, and the session opened in the Copilot app, for you to paste and send.
        case app
        /// The Copilot CLI goes on with it now, on its own.
        case cli
    }

    let subject: TaskSubject
    /// The run it goes on with unless you choose otherwise: a pull request's last task's.
    let continuing: CopilotRun?
    /// What the prompt takes off Needs You once it's sent: the comments it quoted when it was written, in the threads it
    /// still quotes when you send it.
    let handOff: CommentHandOff?
    /// A work item's prompt for a new session, with placeholders, from Settings.
    let template: String
    /// A pull request's prompts: for a worktree of BriefBar's, and for a session that works wherever it is.
    let worktreePrompt: String?
    let sessionPrompt: String?
    /// When the pull request was created: a session that mentions it and was there before likely opened it.
    let createdAt: Date?
    let close: () -> Void

    @EnvironmentObject private var store: CopilotTasksStore
    @EnvironmentObject private var settings: AppSettings

    @LocalState private var prompt: String
    /// The prompt as it was last filled in, to tell whether you changed it.
    @LocalState private var filledIn: String
    @LocalState private var model: String
    @LocalState private var effort: String?
    @LocalState private var repository: GitRepository?
    @LocalState private var repositoryProblem: String?
    @LocalState private var isChecking = false
    @LocalState private var hasAppeared = false
    /// The sessions it can go to instead of a new one, as BriefBar found them.
    @LocalState private var choices: [SessionChoice] = []
    /// Still finding sessions, or which of them mention it.
    @LocalState private var isLooking = false
    /// Where it goes: nil for a new session.
    @LocalState private var target: SessionChoice?
    /// You chose where it goes: what BriefBar finds later doesn't change it.
    @LocalState private var choseTarget = false
    @LocalState private var delivery: Delivery
    /// Why the Copilot CLI can't go on with the session from here, once checked.
    @LocalState private var cliProblem: String?
    /// Why the session can't open in the Copilot app: no app opens its links, or it didn't open.
    @LocalState private var appProblem: String?
    /// The session whose folder is being checked for the CLI.
    @LocalState private var checkingSession: String?

    /// The most other sessions the menu lists.
    static let otherLimit = 30

    /// - Parameters:
    ///   - template: the prompt, with placeholders, from Settings, for a work item.
    ///   - prompt: a pull request's prompt, written for it, for a worktree of BriefBar's.
    ///   - sessionPrompt: a pull request's prompt for a session that works wherever it is.
    init(
        subject: TaskSubject, options: CopilotRunOptions, template: String, prompt: String? = nil, sessionPrompt: String? = nil,
        createdAt: Date? = nil, continuing: CopilotRun? = nil, handOff: CommentHandOff? = nil, close: @escaping () -> Void
    ) {
        self.subject = subject
        self.continuing = continuing
        self.handOff = handOff
        self.template = template
        self.createdAt = createdAt
        self.close = close
        let prompts: (worktree: String?, session: String?)
        switch subject {
        case .workItem: prompts = (nil, nil)
        case .pullRequest: prompts = (prompt ?? "", sessionPrompt)
        }
        worktreePrompt = prompts.worktree
        self.sessionPrompt = prompts.session
        // Until the sessions are found: the last task's, as it was kept, with the prompt for where it works, and opened in
        // the Copilot app if it's one of the app's sessions.
        let initial = continuing.map { run in
            SessionChoice(kind: .task(run), name: run.action?.title ?? "Its last task", place: nil, lastActive: run.startedAt, reasons: [.earlierTask])
        }
        let filledIn = CopilotComposerView.writtenPrompt(
            for: initial, subject: subject, template: template, worktreePrompt: prompts.worktree, sessionPrompt: prompts.session,
            baseBranch: nil
        )
        _target = LocalState(wrappedValue: initial)
        _delivery = LocalState(wrappedValue: initial?.opensInApp == true ? .app : .cli)
        _prompt = LocalState(wrappedValue: filledIn)
        _filledIn = LocalState(wrappedValue: filledIn)
        _model = LocalState(wrappedValue: options.model)
        _effort = LocalState(wrappedValue: options.effort)
    }

    /// The prompt BriefBar writes for where Copilot works. A work item's: the one in Settings for a new session, in a new
    /// worktree, with its base branch once known; or BriefBar's own for a session that's there already, which checks where
    /// it works first. A pull request's: for a worktree of BriefBar's, detached at its latest commit, for a new session or
    /// an earlier task's in such a worktree; or for wherever the session works otherwise, as the Copilot app's sessions
    /// and the work item's task that opened it do.
    static func writtenPrompt(
        for choice: SessionChoice?, subject: TaskSubject, template: String, worktreePrompt: String?, sessionPrompt: String?,
        baseBranch: String?
    ) -> String {
        switch subject {
        case .workItem(let item):
            guard choice != nil else { return PromptTemplate.render(template, item: item, baseBranch: baseBranch) }
            return PromptTemplate.render(PromptTemplate.existingSession, item: item)
        case .pullRequest:
            let worktree = worktreePrompt ?? ""
            guard let choice, let sessionPrompt else { return worktree }
            if let run = choice.run, run.worksInPullRequestWorktree { return worktree }
            return sessionPrompt
        }
    }

    init(item: TaskWorkItem, options: CopilotRunOptions, template: String, close: @escaping () -> Void) {
        self.init(subject: .workItem(item), options: options, template: template, close: close)
    }

    private var workItem: TaskWorkItem? {
        if case .workItem(let item) = subject { return item }
        return nil
    }

    private var pullRequest: (TaskPullRequest, PullRequestAction)? {
        if case .pullRequest(let pullRequest, let action) = subject { return (pullRequest, action) }
        return nil
    }

    /// Push & Reply ships what an earlier run changed: only in its session, and its worktree.
    private var mustContinue: Bool { pullRequest?.1 == .pushAndReply }

    /// Runs with the CLI, rather than handing the prompt to the Copilot app: a new session, or the CLI going on with one.
    private var runsHere: Bool { target == nil || delivery == .cli }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Session").foregroundStyle(.secondary)
                    sessionRow
                }
                if target != nil {
                    GridRow {
                        Text("Send").foregroundStyle(.secondary)
                        deliveryRow
                    }
                }
                if let (pullRequest, _) = pullRequest {
                    GridRow {
                        Text("Repository").foregroundStyle(.secondary)
                        Text("\(pullRequest.organization) / \(pullRequest.project) / \(pullRequest.repository)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if target == nil {
                    GridRow {
                        Text(pullRequest == nil ? "Repository" : "Local Clone").foregroundStyle(.secondary)
                        repositoryRow
                    }
                }
                if runsHere {
                    GridRow {
                        Text("Model").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            CopilotModelMenu(model: $model)
                            CopilotEffortPicker(effort: $effort)
                        }
                    }
                }
            }
            promptEditor
            footer
        }
        .padding(20)
        .frame(width: 620)
        .onAppear(perform: setUp)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pullRequest.map { "\($0.1.title) with Copilot" } ?? "Send to Copilot")
                .font(.system(size: 20, weight: .bold))
            HStack(spacing: 6) {
                Text(verbatim: workItem.map { "\($0.type) \($0.id)" } ?? pullRequest.map { "!\($0.0.id)" } ?? "")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(workItem?.title ?? pullRequest?.0.title ?? "")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if isBusy {
                Label("Copilot is already working on this \(workItem != nil ? "work item" : "pull request").", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Copilot works on it already, in a task BriefBar sent.
    private var isBusy: Bool {
        if let workItem {
            return store.entries.first { $0.workItem?.matches(workItem.reference) == true }?.status.phase.isActive == true
        }
        if let (pullRequest, _) = self.pullRequest {
            return store.latest(forPullRequest: PRKey(pullRequest.organization, pullRequest.id))?.status.phase.isActive == true
        }
        return false
    }

    // MARK: Where it goes

    private var sessionRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Menu {
                    sessionMenu
                } label: {
                    Label(target?.name ?? "New Session", systemImage: symbol(of: target))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: 400, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(mustContinue || !store.canSend || !store.isOn)
                .help(mustContinue ? "Push & Reply ships what its last task changed, in that task's session" : "Choose where it goes")
                if isLooking {
                    ProgressView().controlSize(.small)
                        .help("Looking for Copilot sessions that go with it")
                }
            }
            Text(sessionCaption)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var sessionMenu: some View {
        Button {
            select(nil, byYou: true)
        } label: {
            menuLabel("New Session", detail: pullRequest == nil ? "in a new worktree" : "in a worktree at its latest commit", selected: target == nil)
        }
        let tasks = choices.filter { $0.run != nil }
        if !tasks.isEmpty {
            Section("BriefBar's Tasks") {
                ForEach(tasks) { menuItem($0) }
            }
        }
        let related = choices.filter { $0.appSession != nil && !$0.reasons.isEmpty }
        if !related.isEmpty {
            Section(pullRequest != nil ? "Copilot Sessions on This Pull Request" : "Copilot Sessions on This Work Item") {
                ForEach(related) { menuItem($0) }
            }
        }
        let others = Array(choices.filter { $0.appSession != nil && $0.reasons.isEmpty }.prefix(Self.otherLimit))
        if !others.isEmpty {
            Divider()
            Menu("Other Copilot Sessions") {
                ForEach(others) { menuItem($0) }
            }
        }
        if isLooking {
            Text("Looking for more…")
        }
    }

    private func menuItem(_ choice: SessionChoice) -> some View {
        Button {
            select(choice, byYou: true)
        } label: {
            menuLabel(choice.name, detail: detail(of: choice), selected: target?.id == choice.id)
        }
        .disabled(choice.isBusy)
    }

    @ViewBuilder private func menuLabel(_ title: String, detail: String?, selected: Bool) -> some View {
        // The app's sessions can have names a paragraph long.
        let name = title.count > 70 ? String(title.prefix(69)) + "…" : title
        let text = [name, detail].compactMap { $0 }.joined(separator: " — ")
        if selected {
            Label(text, systemImage: "checkmark")
        } else {
            Text(text)
        }
    }

    private func symbol(of choice: SessionChoice?) -> String {
        guard let choice else { return "plus.circle" }
        return choice.appSession != nil ? "waveform.path.ecg" : "paperplane"
    }

    /// "on its branch · Spectre · users/robin/fix · 7m ago", "Fix Comments, done · 3h ago".
    private func detail(of choice: SessionChoice) -> String {
        var parts: [String] = []
        if choice.isBusy { parts.append("working") }
        if let run = choice.run {
            if !choice.isBusy, let entry = store.entries.first(where: { $0.id == run.id }) {
                parts.append(entry.status.phase.title.lowercased())
            }
            if choice.reasons.contains(.openedIt) { parts.append("opened it") }
        } else {
            parts += choice.reasons.prefix(2).map(\.phrase)
            if let place = choice.place { parts.append(place) }
        }
        if choice.isOpenInApp { parts.append("open in Copilot") }
        let ago = Elapsed.short(since: choice.lastActive, now: Date())
        if !ago.isEmpty { parts.append(ago == "now" ? "just now" : "\(ago) ago") }
        return parts.joined(separator: " · ")
    }

    /// What it is, under the menu. Why the CLI can't go on with it is under Send.
    private var sessionCaption: String {
        guard let target else {
            return pullRequest == nil
                ? "Copilot starts a new session, in a new worktree of the repository."
                : "Copilot starts a new session, in a new worktree at the pull request's latest commit."
        }
        if target.isBusy { return "Copilot is still working in it." }
        switch target.kind {
        case .task(let run):
            let what = run.isAppSession == true ? "The Copilot app's session"
                : target.reasons.contains(.openedIt) ? "The session of the task that opened it" : "BriefBar's earlier task's session"
            return "\(what), in \(UserPath.abbreviate(run.worktree.path))."
        case .app(let session):
            var parts = ["In the Copilot app"]
            if let place = target.place { parts.append(place) }
            parts += target.reasons.prefix(3).map(\.phrase)
            if session.isRunning { parts.append("working") }
            return parts.joined(separator: " · ") + "."
        }
    }

    private var deliveryRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Picker("Send", selection: $delivery) {
                Text("Open in Copilot").tag(Delivery.app)
                Text("Run with the CLI").tag(Delivery.cli)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(cliProblem != nil || appProblem != nil || checkingSession != nil || target?.isBusy == true)
            .help("Open in Copilot copies the prompt and opens the session in the Copilot app, to paste and send. Run with the CLI goes on with it now, on its own.")
            ForEach([cliProblem, appProblem].compactMap { $0 }, id: \.self) { problem in
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var repositoryRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(store.knownRepositories, id: \.self) { url in
                    Button(url.lastPathComponent) { check(url) }
                }
                if !store.knownRepositories.isEmpty { Divider() }
                Button(pullRequest == nil ? "Choose Folder…" : "Choose Local Clone…", action: chooseFolder)
            } label: {
                Label(repository?.name ?? (pullRequest == nil ? "Choose a Repository" : "Choose Local Clone…"), systemImage: "folder")
            }
            .fixedSize()
            .disabled(isChecking || !store.canSend || !store.isOn)
            if isChecking {
                ProgressView().controlSize(.small)
            } else if let repositoryProblem {
                Label(repositoryProblem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let repository {
                Text("\(UserPath.abbreviate(repository.root.path)), from origin/\(pullRequest?.0.sourceBranch ?? repository.baseBranch)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if pullRequest != nil {
                Text("Choose its folder on this Mac once. BriefBar will remember it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Prompt").font(.headline)
                Spacer()
                Button("Reset") { prompt = filledIn }
                    .buttonStyle(.borderless)
                    .disabled(prompt == filledIn)
                    .help(workItem != nil && target == nil ? "Go back to the prompt in Settings" : "Go back to the prompt BriefBar wrote")
            }
            TextEditor(text: $prompt)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 250)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Text(store.canSend ? footnote : "The demo doesn't send anything.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)
            Button(runsHere ? "Send" : "Open in Copilot", action: send)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSend)
        }
    }

    /// What Copilot does, and where.
    private var footnote: String {
        if !runsHere {
            return "BriefBar copies the prompt and opens the session in the Copilot app: paste it there, and send it. Copilot works on it in that session, with its own model, mode and permissions, where you can follow it."
        }
        let place: String
        switch target?.kind {
        case nil: place = "in a new worktree"
        case .task(let run)?: place = run.isAppSession == true ? "in its session, in the folder it works in" : "in the same session and worktree as before"
        case .app?: place = "in its session, in the folder it works in"
        }
        var text: String
        switch pullRequest?.1 {
        case nil:
            text = "Copilot works on its own on this Mac, \(place), with your tools, MCP servers and instructions. It pushes a branch and opens a pull request, as you."
        case .pushAndReply?:
            text = "Copilot works on its own on this Mac, \(place), with your tools, MCP servers and instructions. It commits, pushes the pull request's branch, and replies on its threads, as you."
        case .review?:
            text = "Copilot works on its own on this Mac, \(place), at the pull request's latest commit, with your tools, MCP servers and instructions. It changes nothing, and posts nothing."
        case .some:
            text = "Copilot works on its own on this Mac, \(place), at the pull request's latest commit, with your tools, MCP servers and instructions. It doesn't push or reply: check its changes, then choose Push & Reply."
        }
        if target?.appSession != nil || target?.run?.isAppSession == true {
            text += " Don't open the session in the Copilot app until Copilot is done: the app wouldn't see what it did."
        }
        return text
    }

    private var canSend: Bool {
        guard store.canSend, store.isOn, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let hasModel = !model.trimmingCharacters(in: .whitespaces).isEmpty
        guard let target else {
            return !mustContinue && !isBusy && repository != nil && !isChecking && hasModel
        }
        guard !target.isBusy else { return false }
        switch delivery {
        case .app: return appProblem == nil
        case .cli: return !isBusy && hasModel && cliProblem == nil && checkingSession == nil
        }
    }

    // MARK: Finding sessions

    private func setUp() {
        guard !hasAppeared, store.canSend, store.isOn else { return }
        hasAppeared = true
        if !store.canOpenInApp { appProblem = CopilotTasksStore.cantOpenInApp }
        checkSession()
        switch subject {
        case .workItem(let item):
            if let folder = store.repository(for: item) ?? store.knownRepositories.first { check(folder) }
        case .pullRequest(let pullRequest, _):
            // For a new session, should you choose one.
            isChecking = true
            Task {
                do {
                    repository = try await store.repository(for: pullRequest, using: store.git())
                } catch {
                    repositoryProblem = String(describing: error)
                }
                isChecking = false
            }
        }
        findSessions()
    }

    /// The sessions it can go to: BriefBar's tasks and the Copilot app's sessions first, then which of the app's mention
    /// it, which takes longer. What's suggested goes in unless you've chosen.
    private func findSessions() {
        isLooking = true
        Task {
            var found = await store.sessionChoices(for: subject)
            choices = found
            update()
            let mentioned = await store.sessionsMentioning(subject, among: found, since: createdAt)
            if !mentioned.isEmpty {
                for index in found.indices where mentioned.contains(found[index].id) && !found[index].reasons.contains(.mentionsIt) {
                    found[index].reasons.append(.mentionsIt)
                }
                choices = found.filter { $0.run != nil } + CopilotTasksStore.sorted(found.filter { $0.appSession != nil }, createdAt: createdAt)
                update()
            }
            isLooking = false
        }
    }

    /// Keeps the chosen session as it was found, and goes to the suggested one until you choose. Push & Reply stays with
    /// its last task's session.
    private func update() {
        if let current = target, let found = choices.first(where: { $0.id == current.id }), found != current {
            target = found
            checkSession()
        }
        guard !choseTarget, !mustContinue else { return }
        let suggested = CopilotTasksStore.suggestedChoice(choices, for: subject, continuable: continuing, createdAt: createdAt)
        if suggested?.id != target?.id { select(suggested, byYou: false) }
    }

    private func select(_ choice: SessionChoice?, byYou: Bool) {
        if byYou { choseTarget = true }
        target = choice
        delivery = choice?.opensInApp == true ? .app : .cli
        refreshPrompt()
        checkSession()
    }

    /// The prompt BriefBar writes for where Copilot works now (`writtenPrompt`), unless you changed the one it wrote.
    private func refreshPrompt() {
        let written = Self.writtenPrompt(
            for: target, subject: subject, template: template, worktreePrompt: worktreePrompt, sessionPrompt: sessionPrompt,
            baseBranch: repository?.baseBranch
        )
        guard prompt == filledIn, written != filledIn else { return }
        filledIn = written
        prompt = written
    }

    /// Goes the way that works when only one does: in the Copilot app when the CLI can't go on with the session, with the
    /// CLI when nothing opens the app's sessions.
    private func fixDelivery() {
        if delivery == .cli, cliProblem != nil, appProblem == nil { delivery = .app }
        if delivery == .app, appProblem != nil, cliProblem == nil { delivery = .cli }
    }

    /// Whether the CLI can go on with the chosen session from here: not while Copilot works in it or the Copilot app has it
    /// open, and for one of the app's, only in a repository, the pull request's clone for one.
    private func checkSession() {
        cliProblem = nil
        checkingSession = nil
        guard let choice = target else { return }
        if choice.isBusy {
            cliProblem = "Copilot is still working in it."
        } else if choice.isOpenInApp {
            cliProblem = "The Copilot app has it open: Copilot can go on with it only there, where its history is."
        } else if let session = choice.appSession {
            checkingSession = session.id
            Task {
                let problem = await store.cliProblem(for: session, subject: subject)
                guard checkingSession == session.id, target?.id == session.id else { return }
                checkingSession = nil
                cliProblem = problem
                fixDelivery()
            }
        }
        fixDelivery()
    }

    // MARK: A new session's repository

    /// Checks that a folder is in a git repository, and fills the base branch into a prompt you haven't changed.
    private func check(_ folder: URL) {
        guard store.canSend, store.isOn, !isChecking else { return }
        isChecking = true
        repositoryProblem = nil
        Task {
            do {
                let git = await store.git()
                let found: GitRepository
                if let (pullRequest, _) = pullRequest {
                    found = try await store.checkRepository(at: folder, for: pullRequest, using: git)
                } else {
                    found = try await git.repository(at: folder)
                }
                repository = found
                refreshPrompt()
            } catch {
                repository = nil
                repositoryProblem = String(describing: error)
            }
            isChecking = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = workItem.map { "Choose the repository that work item \($0.id)'s change goes in." }
            ?? pullRequest.map {
                "Choose your local clone of \($0.0.organization)/\($0.0.project)/\($0.0.repository). BriefBar will remember it for this repository's pull requests."
            } ?? ""
        if let current = repository?.root { panel.directoryURL = current.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        check(url)
    }

    // MARK: Sending

    private func send() {
        guard canSend else { return }
        let options = CopilotRunOptions(model: model.trimmingCharacters(in: .whitespaces), effort: effort)
        guard let target else {
            guard let folder = repository?.root else { return }
            store.send(subject, prompt: prompt, options: options, repository: folder, handOff: handOff)
            close()
            return
        }
        // Copilot started working in it since the window opened.
        if store.isWorking(inSession: target.id) {
            self.target?.isBusy = true
            checkSession()
            return
        }
        switch delivery {
        case .app:
            // It stays open, with what went wrong, until the session opens: only then are the comments handed off.
            if let problem = store.openInCopilot(target, prompt: prompt, handOff: handOff) {
                appProblem = problem
                fixDelivery()
                return
            }
        case .cli:
            switch target.kind {
            case .task(let run):
                store.send(subject, prompt: prompt, options: options, repository: run.repository, continuing: run, handOff: handOff)
            case .app(let session):
                guard let run = store.appRun(for: session, subject: subject, options: options) else {
                    cliProblem = "BriefBar can't tell which folder it works in."
                    fixDelivery()
                    return
                }
                store.send(subject, prompt: prompt, options: options, repository: run.repository, continuing: run, handOff: handOff)
            }
        }
        close()
    }
}

/// The model: one of the suggestions, or any other your plan offers, by its ID.
struct CopilotModelMenu: View {
    @Binding var model: String

    var body: some View {
        Menu {
            ForEach(CopilotModel.suggestions) { choice in
                Button {
                    model = choice.id
                } label: {
                    if choice.id == model {
                        Label(choice.name, systemImage: "checkmark")
                    } else {
                        Text(choice.name)
                    }
                }
            }
            if !model.isEmpty, !CopilotModel.suggestions.contains(where: { $0.id == model }) {
                Divider()
                Button {} label: { Label(model, systemImage: "checkmark") }
            }
            Divider()
            Button("Other Model…") {
                if let other = Self.askForModel(current: model) { model = other }
            }
        } label: {
            Text(model.isEmpty ? "Choose a Model" : CopilotModel.name(of: model))
        }
        .fixedSize()
    }

    private static func askForModel(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Use Another Model"
        alert.informativeText = "Enter the model's ID, as the Copilot CLI's /model command lists it, such as gpt-6-luna."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let model = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }
}

/// How hard the model thinks; Default leaves it to the model.
struct CopilotEffortPicker: View {
    @Binding var effort: String?

    var body: some View {
        Picker("Effort", selection: $effort) {
            Text("Default Effort").tag(String?.none)
            ForEach(CopilotModel.efforts, id: \.self) { effort in
                Text(CopilotModel.effortName(effort)).tag(Optional(effort))
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("Reasoning effort: how hard the model thinks. Not every model takes every one.")
    }
}
