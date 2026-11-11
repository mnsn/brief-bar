import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// The window that sends a work item, or a pull request's comments, build or conflicts, to Copilot: the prompt, which
/// you can change, the model, and where it goes: a new session, in a worktree of the repository it goes in, or a session
/// that's there already, such as BriefBar's earlier task's or the Copilot app's session that opened the pull request. A
/// window of its own, since popovers and widgets can't hold a sheet, translucent as BriefBar's window is, under a title bar
/// it draws through.
@MainActor
final class CopilotComposer: NSObject, NSWindowDelegate {
    static let shared = CopilotComposer()
    private var window: NSWindow?
    /// The task the window shows now: only it closes the window, once it's sent.
    private var shown: UUID?
    /// Its prompt on its way to a session that's there already (`CopilotTasksStore.deliver`), which stops once the window
    /// closes or shows another task.
    private var sending: Task<Void, Never>?

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
    ///   - start: where it goes to begin with, as a composer in place chose it, rather than BriefBar's suggestion.
    ///   - parts: what of the pull request it takes on, its threads, builds or conflicts, for each to say what became of it.
    ///   - fixes: a Push & Reply that fixes the threads it takes on first, as a comment's fix sent with Push and Reply on.
    func show(
        subject: TaskSubject, prompt: String?, sessionPrompt: String? = nil, createdAt: Date? = nil, options: CopilotRunOptions,
        continuing: CopilotRun?, handOff: CommentHandOff? = nil, session start: ComposerStart? = nil, parts: [PullRequestPart] = [],
        fixes: Bool = false, store: CopilotTasksStore
    ) {
        // Another task in its place stops the last one's prompt, which may be on its way to a session.
        stopSending()
        let task = UUID()
        shown = task
        let view = CopilotComposerView(
            subject: subject, options: options, template: store.settings.copilotPromptTemplate, prompt: prompt,
            sessionPrompt: sessionPrompt, createdAt: createdAt, continuing: continuing, handOff: handOff, start: start, parts: parts,
            fixes: fixes, asksForStage: store.asksForStage, sending: { [weak self] sending in
                guard self?.shown == task else { return sending.cancel() }
                self?.sending = sending
            }
        ) { [weak self] in
            guard let self, self.shown == task else { return }
            self.window?.close()
        }
        .environmentObject(store)
        .environmentObject(store.settings)
        // As Settings › Appearance says, such as with quieter colors.
        let host = NSHostingController(rootView: store.services.map { AnyView(view.interfaceOptions(from: $0)) } ?? AnyView(view))
        host.sizingOptions = [.preferredContentSize]
        // The view goes under the title bar, which it leaves room for: the window is as tall as the view.
        host.safeAreaRegions = []
        let window = window ?? {
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            // The window says what it is at its top, under the title bar.
            window.titleVisibility = .hidden
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
        MainActor.assumeIsolated {
            stopSending()
            shown = nil
            window = nil
        }
    }

    /// Stops a prompt on its way to a session: one that no extension took yet is taken back, and nothing's copied or
    /// opened for it.
    private func stopSending() {
        sending?.cancel()
        sending = nil
    }
}

/// Where the Send to Copilot window's prompt goes to begin with, for one opened from a composer in place: a session that's
/// there already, or a fork of it, or a new session.
enum ComposerStart {
    case session(SessionChoice, forking: Bool)
    case newSession
}

struct CopilotComposerView: View {
    /// How a task goes to a session that's there already: where Copilot takes it up, and whether in the session itself or
    /// in a fork of it, a new session with its history.
    struct Delivery: Hashable {
        enum Place: Hashable {
            /// In the Copilot app: BriefBar's extension in the session sends it the prompt, or BriefBar copies it for you
            /// to paste there.
            case app
            /// The Copilot CLI goes on with it now, on its own.
            case cli
        }

        var place: Place
        /// To a fork of the session rather than the session itself.
        var forks = false

        /// Send to Session.
        static let session = Delivery(place: .app)
        /// Send to a Fork.
        static let fork = Delivery(place: .app, forks: true)
        /// Run with the CLI.
        static let cli = Delivery(place: .cli)
        /// Fork with the CLI: one of BriefBar's own sessions, into a worktree of its own.
        static let cliFork = Delivery(place: .cli, forks: true)
    }

    let subject: TaskSubject
    /// The run it goes on with unless you choose otherwise: a pull request's last task's.
    let continuing: CopilotRun?
    /// What the prompt takes off Needs You once it's sent: the comments it quoted when it was written, in the threads it
    /// still quotes when you send it.
    let handOff: CommentHandOff?
    /// What of the pull request it takes on, its threads, builds or conflicts: what each says Copilot does about it.
    let parts: [PullRequestPart]
    /// A Push & Reply that fixes the threads it takes on first, as a comment's fix sent with Push and Reply on: it goes
    /// wherever a fix goes, rather than only on with the session whose changes it ships.
    let fixes: Bool
    /// A work item's prompt for a new session, with placeholders, from Settings.
    let template: String
    /// Its prompt ends asking the session to tell BriefBar the pull request's stage once it pushed, as Pull Request Order
    /// does while it's on (`PromptTemplate.stageLine`), unless it's a review.
    let asksForStage: Bool
    /// A pull request's prompts: for a worktree of BriefBar's, and for a session that works wherever it is.
    let worktreePrompt: String?
    let sessionPrompt: String?
    /// When the pull request was created: a session that mentions it and was there before likely opened it.
    let createdAt: Date?
    /// Hands the window its prompt's way to a session that's there already, to stop once the window closes.
    let sending: (Task<Void, Never>) -> Void
    let close: () -> Void

    @EnvironmentObject private var store: CopilotTasksStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.isRendering) private var isRendering

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
    /// Whether to look for the sessions again once the look under way ends: you chose in the details meanwhile.
    @LocalState private var looksAgain = false
    /// Where it goes: nil for a new session.
    @LocalState private var target: SessionChoice?
    /// You chose where it goes: what BriefBar finds later doesn't change it.
    @LocalState private var choseTarget = false
    @LocalState private var delivery: Delivery
    /// Why the Copilot CLI can't go on with the session from here, once checked.
    @LocalState private var cliProblem: String?
    /// Why the session can't open in the Copilot app: no app opens its links, or it didn't open.
    @LocalState private var appProblem: String?
    /// How the prompt would reach the chosen session through BriefBar's extension in it, once looked at.
    @LocalState private var reach: SessionReach?
    /// BriefBar is sending the prompt to the session now, or forking it.
    @LocalState private var isDelivering = false
    /// Why nothing went to the session, the last time you sent it.
    @LocalState private var deliveryProblem: String?
    /// Why BriefBar couldn't send it itself, once it copied the prompt for you to paste: the window stays open to say so.
    @LocalState private var fallback: SessionFallback?
    /// The session whose folder is being checked for the CLI.
    @LocalState private var checkingSession: String?
    /// You're writing in the prompt: its card shows it.
    @FocusState private var isEditingPrompt: Bool

    /// The most other sessions the menu lists.
    static let otherLimit = 30

    /// - Parameters:
    ///   - template: the prompt, with placeholders, from Settings, for a work item.
    ///   - prompt: a pull request's prompt, written for it, for a worktree of BriefBar's.
    ///   - sessionPrompt: a pull request's prompt for a session that works wherever it is.
    ///   - session: where it goes to begin with, rather than `continuing`'s session, and how the prompt would reach it: for
    ///     `--render`, which finds nothing.
    ///   - start: where it goes to begin with, as a composer in place chose it, which BriefBar's suggestions don't change.
    ///   - parts: what of the pull request it takes on, its threads, builds or conflicts.
    ///   - fixes: a Push & Reply that fixes the threads it takes on first, as a comment's fix sent with Push and Reply on.
    ///   - asksForStage: Pull Request Order is on: its prompt ends asking for the stage, unless it's a review's.
    init(
        subject: TaskSubject, options: CopilotRunOptions, template: String, prompt: String? = nil, sessionPrompt: String? = nil,
        createdAt: Date? = nil, continuing: CopilotRun? = nil, handOff: CommentHandOff? = nil,
        session: (choice: SessionChoice, reach: SessionReach?)? = nil, start: ComposerStart? = nil, parts: [PullRequestPart] = [],
        fixes: Bool = false, asksForStage: Bool = false, sending: @escaping (Task<Void, Never>) -> Void = { _ in },
        close: @escaping () -> Void
    ) {
        self.subject = subject
        self.asksForStage = asksForStage
        self.continuing = continuing
        self.handOff = handOff
        self.parts = parts
        self.fixes = fixes
        self.template = template
        self.createdAt = createdAt
        self.sending = sending
        self.close = close
        let prompts: (worktree: String?, session: String?)
        switch subject {
        case .workItem: prompts = (nil, nil)
        case .pullRequest: prompts = (prompt ?? "", sessionPrompt)
        }
        worktreePrompt = prompts.worktree
        self.sessionPrompt = prompts.session
        // Until the sessions are found: where a composer in place chose; else the last task's, as it was kept, with the
        // prompt for where it works, and sent to it in the Copilot app if it's one of the app's sessions.
        var initial = session?.choice ?? continuing.map { run in
            SessionChoice(
                kind: .task(run), name: run.action?.title(taken: run.taken) ?? "Its last task", place: nil, lastActive: run.startedAt,
                reasons: [.earlierTask]
            )
        }
        var delivery: Delivery = initial?.opensInApp == true ? .session : .cli
        switch start {
        case .session(let choice, let forking)?:
            initial = choice
            if forking {
                delivery = CopilotDestinations.forksWithTheCLI(choice) ? .cliFork : .fork
            } else {
                delivery = choice.opensInApp ? .session : .cli
            }
        case .newSession?:
            initial = nil
            delivery = .cli
        case nil:
            break
        }
        let filledIn = CopilotComposerView.writtenPrompt(
            for: initial, subject: subject, template: template, worktreePrompt: prompts.worktree, sessionPrompt: prompts.session,
            baseBranch: nil, forks: delivery.forks, asksForStage: asksForStage
        )
        _target = LocalState(wrappedValue: initial)
        _choseTarget = LocalState(wrappedValue: start != nil)
        _delivery = LocalState(wrappedValue: delivery)
        _reach = LocalState(wrappedValue: session?.reach)
        _prompt = LocalState(wrappedValue: filledIn)
        _filledIn = LocalState(wrappedValue: filledIn)
        _model = LocalState(wrappedValue: options.model)
        _effort = LocalState(wrappedValue: options.effort)
    }

    /// The prompt BriefBar writes for where Copilot works. A work item's: the one in Settings for a new session, in a new
    /// worktree, with its base branch once known; or BriefBar's own for a session that's there already, which checks where
    /// it works first. A pull request's: for a worktree of BriefBar's, detached at its latest commit, for a new session or
    /// an earlier task's in such a worktree; or for wherever the session works otherwise, as the Copilot app's sessions
    /// and the work item's task that opened it do. Each but a review's ends asking the session to tell BriefBar the pull
    /// request's stage once it pushed, while Pull Request Order is on.
    /// - Parameters:
    ///   - forks: it goes to a fork of the session, which works in a checkout of its own, wherever that is.
    ///   - asksForStage: Pull Request Order is on.
    static func writtenPrompt(
        for choice: SessionChoice?, subject: TaskSubject, template: String, worktreePrompt: String?, sessionPrompt: String?,
        baseBranch: String?, forks: Bool = false, asksForStage: Bool = false
    ) -> String {
        func written() -> String {
            switch subject {
            case .workItem(let item):
                guard choice != nil else { return PromptTemplate.render(template, item: item, baseBranch: baseBranch) }
                return PromptTemplate.render(PromptTemplate.existingSession, item: item)
            case .pullRequest:
                let worktree = worktreePrompt ?? ""
                guard let choice, let sessionPrompt else { return worktree }
                if let run = choice.run, run.worksInPullRequestWorktree, !forks { return worktree }
                return sessionPrompt
            }
        }
        return PromptTemplate.ending(written(), asksForStage: asksForStage && subject.asksForStage)
    }

    init(item: TaskWorkItem, options: CopilotRunOptions, template: String, asksForStage: Bool = false, close: @escaping () -> Void) {
        self.init(subject: .workItem(item), options: options, template: template, asksForStage: asksForStage, close: close)
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
    private var mustContinue: Bool { Self.mustContinue(pullRequest?.1, fixes: fixes) }

    /// Whether a task must go on with the session whose changes it ships, as Push & Reply does: not one that fixes the
    /// threads it takes on first, which ships what it changes itself, wherever a fix goes.
    static func mustContinue(_ action: PullRequestAction?, fixes: Bool) -> Bool {
        action == .pushAndReply && !fixes
    }

    /// A Push & Reply that replies on no thread, as of a build's fix alone: it only pushes, and says so.
    private var onlyPushes: Bool {
        pullRequest?.1 == .pushAndReply && !fixes
            && PullRequestAction.pushAndReply.title(taking: parts) != PullRequestAction.pushAndReply.title
    }

    /// Send to a Fork is there for the session: the Copilot app can fork it, and it isn't for Push & Reply, which ships what
    /// its last task changed only in that task's session and worktree. A fork would push a copy of those changes from a
    /// worktree of its own, and leave them uncommitted where they are.
    static func offersFork(_ target: SessionChoice?, mustContinue: Bool) -> Bool {
        target?.canFork == true && !mustContinue
    }

    /// Fork with the CLI is there for the session: one of BriefBar's own, and not for Push & Reply, which ships what its last
    /// task changed only in that task's session and worktree.
    static func offersCLIFork(_ target: SessionChoice?, mustContinue: Bool) -> Bool {
        target.map(CopilotDestinations.forksWithTheCLI) == true && !mustContinue
    }

    /// Runs with the CLI, rather than going to the session in the Copilot app: a new session, or the CLI going on with one.
    private var runsHere: Bool { target == nil || delivery.place == .cli }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if isBusy {
                busyNote
            }
            destination
                // Where it goes stays as it was while BriefBar sends it, and once it copied it for you to paste.
                .disabled(isDelivering || fallback != nil)
            promptSection
            footer
        }
        .padding(.horizontal, 24)
        // Below the title bar's buttons, which the window draws its top under.
        .padding(.top, 36)
        .padding(.bottom, 22)
        .frame(width: 640)
        .background(WindowBackdrop())
        .onAppear(perform: setUp)
        // After the change: a published value emits before it's set.
        .onReceive(store.objectWillChange.receive(on: DispatchQueue.main)) { _ in refreshAvailability() }
        // The session you choose for the pull request in its details, until you choose here or change the prompt.
        .onChange(of: settings.copilotPullRequestSessions) { old, new in
            guard case .pullRequest(let pullRequest, _) = subject else { return }
            let key = PRKey(pullRequest.organization, pullRequest.id)
            guard old.last(where: { $0.isFor(key) }) != new.last(where: { $0.isFor(key) }) else { return }
            choseInDetails()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await recheckSession()
            }
        }
    }

    /// What it does, in Copilot's colors, and what it's for. Dragging it moves the window.
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ComposerTile(
                symbol: onlyPushes ? "arrow.up.circle.fill" : fixes ? PullRequestAction.fixComments.symbol : pullRequest?.1.symbol ?? "paperplane.fill",
                fill: .copilot, size: 44
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(pullRequest.map { "\($0.1.title(taking: parts, fixing: fixes)) with Copilot" } ?? "Send to Copilot")
                    .font(size: 20, weight: .bold)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let workItem {
                        ComposerBadge(symbol: WorkItem.typeSymbol(of: workItem.type), color: WorkItem.typeColor(of: workItem.type))
                    } else {
                        ComposerBadge(symbol: "arrow.triangle.pull", color: AzureDevOpsPage.pullRequests.color)
                    }
                    Text(verbatim: workItem.map { "\($0.type) \($0.id)" } ?? pullRequest.map { "!\($0.0.id)" } ?? "")
                        .font(size: 12, weight: .semibold).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text(workItem?.title ?? pullRequest?.0.title ?? "")
                        .font(size: 12.5)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let (pullRequest, _) = pullRequest {
                    let repository = "\(pullRequest.organization) / \(pullRequest.project) / \(pullRequest.repository)"
                    Text("\(repository)  ·  \(pullRequest.sourceBranch) → \(pullRequest.targetBranch)")
                        .font(size: 11.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Its repository, and the branch it merges into its target")
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var busyNote: some View {
        Label("Copilot is already working on this \(workItem != nil ? "work item" : "pull request").", systemImage: "exclamationmark.triangle.fill")
            .font(size: 12, weight: .medium)
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
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

    /// The session it goes to, and how, or the repository a new session works in: rows of a card.
    private var destination: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposerSectionTitle(title: "Where It Goes")
            VStack(spacing: 0) {
                sessionRow
                Divider()
                    .padding(.leading, 50)
                    .padding(.trailing, 10)
                if target != nil {
                    deliveryRow
                } else {
                    repositoryRow
                }
            }
            .padding(4)
            .background(GlassCard(cornerRadius: 14))
        }
    }

    private var sessionRow: some View {
        ComposerMenuRow(
            title: target?.name ?? "New Session", caption: sessionCaption,
            progress: isLooking ? "Looking for Copilot sessions that go with it" : nil,
            isEnabled: !mustContinue && store.canSend && store.isOn
        ) {
            sessionTile
        } items: {
            sessionMenu
        }
        .help(mustContinue ? "Push & Reply ships what its last task changed, in that task's session" : "Choose where it goes")
        .accessibilityLabel("Session")
        .accessibilityValue(target?.name ?? "New Session")
    }

    /// A new session's, BriefBar's earlier task's, or the Copilot app's session's, as their pages' tiles.
    @ViewBuilder private var sessionTile: some View {
        switch target?.kind {
        case nil: ComposerTile(symbol: "plus", fill: .tint(ComposerColors.newSession))
        case .task?: ComposerTile(symbol: "paperplane.fill", fill: .tint(ComposerColors.task))
        case .app?: ComposerTile(symbol: "waveform.path.ecg", fill: .tint(ComposerColors.appSession))
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
        .disabled(choice.isUnavailable)
    }

    private func menuLabel(_ title: String, detail: String?, selected: Bool) -> some View {
        // The app's sessions can have names a paragraph long.
        let name = title.count > 70 ? String(title.prefix(69)) + "…" : title
        return CheckedMenuLabel(title: [name, detail].compactMap { $0 }.joined(separator: " — "), isChecked: selected)
    }

    /// "on its branch · Spectre · users/robin/fix · 7m ago", "Fix Comments, done · 3h ago".
    private func detail(of choice: SessionChoice) -> String {
        var parts: [String] = []
        if choice.isBusy { parts.append("working") } else if choice.isFolderBusy { parts.append("its checkout is busy") }
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
        if target.isFolderBusy { return "Copilot is working in its checkout for another task BriefBar sent." }
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

    /// How it goes to the session, side by side: to the session in the Copilot app, to a fork of it, or with the CLI here;
    /// each there while it can be used, with what keeps the others from it, and what BriefBar does when it can't send it
    /// itself.
    private var deliveryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ComposerChoice(symbol: "paperplane", title: "Send to Session", detail: sendDetail, isSelected: delivery == .session) {
                    choose(.session)
                }
                .disabled(!canUseApp)
                if Self.offersFork(target, mustContinue: mustContinue) {
                    ComposerChoice(symbol: "arrow.triangle.branch", title: "Send to a Fork", detail: forkDetail, isSelected: delivery == .fork) {
                        choose(.fork)
                    }
                    .disabled(!canUseApp)
                }
                ComposerChoice(
                    symbol: "terminal", title: "Run with the CLI", detail: "Copilot goes on with the session now, on its own.",
                    isSelected: delivery == .cli, isChecking: checkingSession != nil
                ) {
                    choose(.cli)
                }
                .disabled(cliProblem != nil || checkingSession != nil || target?.isUnavailable == true)
                if Self.offersCLIFork(target, mustContinue: mustContinue) {
                    ComposerChoice(
                        symbol: "arrow.triangle.branch", title: "Fork with the CLI",
                        detail: "Copilot works in a fork, with its history, in a worktree of its own.", isSelected: delivery == .cliFork
                    ) {
                        choose(.cliFork)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ForEach(notes, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "info.circle")
                    Text(note)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(size: 11.5)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .help("Send to Session sends the prompt to the session in the Copilot app, and Send to a Fork to a fork of it. Run with the CLI goes on with it now, on its own.")
    }

    /// Sending to the session, or to a fork, can be chosen: the session is free, and the Copilot app opens its sessions.
    private var canUseApp: Bool {
        appProblem == nil && target?.isUnavailable != true
    }

    private func choose(_ way: Delivery) {
        go(way)
        deliveryProblem = nil
    }

    /// Goes this way from now on: a fork works in a checkout of its own, wherever that is, which its prompt says.
    private func go(_ way: Delivery) {
        let forked = delivery.forks
        delivery = way
        if way.forks != forked { refreshPrompt() }
    }

    /// What keeps a way of sending from working as it says, under the choices: why BriefBar can't send it to the session
    /// itself, when that's the way chosen; why the CLI can't go on with it; and why the session can't open, or didn't go.
    private var notes: [String] {
        var notes: [String] = []
        // Once BriefBar copied it, the note by Send says why.
        if !runsHere, fallback == nil, let why = reach?.whyNot(forking: delivery.forks) { notes.append(why) }
        notes += [cliProblem, appProblem, deliveryProblem].compactMap { $0 }
        return notes
    }

    /// What Send to Session does, as things stand: a Push & Reply doesn't go while a turn runs in the session, which could
    /// change what BriefBar checked it would push (`CopilotTasksStore.turnProblem`).
    private var sendDetail: String {
        switch reach {
        case .listening?:
            guard target?.appSession?.isRunning == true else { return "Copilot takes the prompt in the session now." }
            return pullRequest?.1 == .pushAndReply
                ? "Copilot is running a turn in it: send this once that's done, so BriefBar checks what it would push."
                : "Copilot takes the prompt once it's done what it's doing."
        case .loads?:
            return "Opens the session in Copilot, and sends the prompt there."
        case .noListener(inApp: false)?:
            return "Copies the prompt, to paste in the CLI's terminal."
        case .noListener?, .notInApp?, .off?:
            return "Copies the prompt and opens the session, to paste."
        case nil:
            return "Sends the prompt to the session in the Copilot app."
        }
    }

    /// What Send to a Fork does, as things stand.
    private var forkDetail: String { Self.forkDetail(reach) }

    /// What Send to a Fork does, as BriefBar can reach the session: in a CLI's terminal, it copies the prompt alone, since
    /// the CLI's own /fork takes a name for the fork rather than a prompt.
    static func forkDetail(_ reach: SessionReach?) -> String {
        if reach == .noListener(inApp: false) { return "Copies the prompt: /fork in the CLI's terminal, then paste it." }
        return reach?.sends(forking: true) == false
            ? "Copies /fork and the prompt, and opens the session, to paste."
            : "Copilot takes the prompt in a fork, with its own worktree."
    }

    /// The repository a new session's worktree goes in: one it went in before, or a folder you choose.
    private var repositoryRow: some View {
        ComposerMenuRow(
            title: repository?.name ?? (pullRequest == nil ? "Choose a Repository" : "Choose a Local Clone"), caption: repositoryCaption,
            isPlaceholder: repository == nil, isWarning: repositoryProblem != nil && !isChecking,
            progress: isChecking ? "Checking the repository" : nil, isEnabled: !isChecking && store.canSend && store.isOn
        ) {
            ComposerTile(symbol: "folder.fill", fill: .tint(ComposerColors.repository))
        } items: {
            ForEach(store.knownRepositories, id: \.self) { url in
                Button(url.lastPathComponent) { check(url) }
            }
            if !store.knownRepositories.isEmpty { Divider() }
            Button(pullRequest == nil ? "Choose Folder…" : "Choose Local Clone…", action: chooseFolder)
        }
        .help(pullRequest == nil ? "Choose the repository its change goes in" : "Choose your local clone of its repository")
        .accessibilityLabel(pullRequest == nil ? "Repository" : "Local Clone")
        .accessibilityValue(repository?.name ?? "None")
    }

    /// Where the repository is and the branch Copilot starts from; what's wrong with the folder you chose; or why to
    /// choose one.
    private var repositoryCaption: String? {
        if isChecking { return "Checking…" }
        if let repositoryProblem { return repositoryProblem }
        if let repository {
            return "\(UserPath.abbreviate(repository.root.path)), from origin/\(pullRequest?.0.sourceBranch ?? repository.baseBranch)"
        }
        return pullRequest == nil
            ? "The repository its change goes in."
            : "Choose its folder on this Mac once. BriefBar will remember it."
    }

    // MARK: The prompt

    /// The prompt, which you can change and copy, where it came from, and the model that works on it, on a card below it.
    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ComposerSectionTitle(title: "Prompt")
                Text(promptOrigin)
                    .font(size: 11.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    prompt = filledIn
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .font(size: 11.5, weight: .medium)
                // Only once you've changed it, in the same place, so nothing moves.
                .opacity(prompt == filledIn ? 0 : 1)
                .disabled(prompt == filledIn || isDelivering || fallback != nil)
                .accessibilityHidden(prompt == filledIn)
                .help(workItem != nil && target == nil ? "Go back to the prompt in Settings" : "Go back to the prompt BriefBar wrote")
                ComposerCopyButton(text: prompt)
                    // A little apart from Reset, beside it once you change the prompt.
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                TextEditor(text: $prompt)
                    .font(size: 13)
                    .scrollContentBackground(.hidden)
                    .focused($isEditingPrompt)
                    // As it was sent: what changes while it's on its way, or once BriefBar copied it, wouldn't go.
                    .disabled(isDelivering || fallback != nil)
                    .padding(.horizontal, 9)
                    .padding(.top, 9)
                    .padding(.bottom, 4)
                    .frame(height: 252)
                    .accessibilityLabel("Prompt")
                Divider()
                    .opacity(0.6)
                HStack(spacing: 6) {
                    if runsHere {
                        CopilotModelMenu(model: $model, isCapsule: true)
                        CopilotEffortPicker(effort: $effort, isCapsule: true)
                    } else {
                        Label("The session's own model", systemImage: "sparkles")
                            .font(size: 11.5)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                            .help("In the Copilot app, Copilot works with the session's own model, mode and permissions")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(GlassCard(cornerRadius: 14, raised: true))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isEditingPrompt ? 0.55 : 0), lineWidth: 1.5)
            )
        }
    }

    /// "From your template in Settings", "Written by BriefBar", or "Edited".
    private var promptOrigin: String {
        if prompt != filledIn { return "Edited" }
        return workItem != nil && target == nil ? "From your template in Settings" : "Written by BriefBar"
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: fallback == nil ? "info.circle" : "exclamationmark.circle")
                // The README's picture says what sending does, as it would outside the demo.
                Text(store.canSend || isRendering ? footnote : "The demo doesn't send anything.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(size: 11)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
            if fallback == nil {
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
            Button(action: fallback == nil ? send : close) {
                if isDelivering {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(delivery.forks ? "Forking…" : "Sending…")
                    }
                } else {
                    Label(sendTitle, systemImage: sendSymbol)
                        .labelStyle(.titleAndIcon)
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(fallback == nil && !canSend)
        }
    }

    /// "Send"; "Open in Copilot" when BriefBar would copy it for you to paste; or "Done" once it did so unexpectedly.
    private var sendTitle: String {
        if fallback != nil { return "Done" }
        return runsHere || reach?.sends(forking: delivery.forks) != false ? "Send" : "Open in Copilot"
    }

    private var sendSymbol: String {
        if fallback != nil { return "checkmark" }
        return runsHere || reach?.sends(forking: delivery.forks) != false ? "paperplane.fill" : "arrow.up.forward.app"
    }

    /// What Copilot does, and where; or what BriefBar did, once it couldn't send it itself.
    private var footnote: String {
        if let fallback { return Self.fallbackNote(fallback) }
        // With Push and Reply on: what else goes, which you haven't pushed.
        let also = Self.alsoPushes(subject, fixes: fixes, to: target, delivery: delivery, taking: parts, store: store).map { " " + $0 } ?? ""
        if !runsHere { return appFootnote + also }
        let place: String
        switch target?.kind {
        case nil: place = "in a new worktree"
        case _ where delivery == .cliFork: place = "in a fork of the session, with its history, in a worktree of its own"
        case .task(let run)?: place = run.isAppSession == true ? "in its session, in the folder it works in" : "in the same session and worktree as before"
        case .app?: place = "in its session, in the folder it works in"
        }
        var text: String
        switch pullRequest?.1 {
        case nil:
            text = "Copilot works on its own on this Mac, \(place), with your tools, MCP servers and instructions. It pushes a branch and opens a pull request, as you."
        case .pushAndReply? where fixes:
            text = "Copilot works on its own on this Mac, \(place), with your tools, MCP servers and instructions. It addresses the comments, then commits, pushes the pull request's branch, and replies on their threads, as you.\(also)"
        case .pushAndReply? where onlyPushes:
            text = "Copilot works on its own on this Mac, \(place), with your tools, MCP servers and instructions. It commits and pushes the pull request's branch, as you, and replies on none of its threads."
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

    /// For a comment's fix sent with Push and Reply on, what else it pushes where the window sends it, which you haven't
    /// pushed, as the composer it came from says for where that sends it (`CopilotTasksStore.alsoPushes`): nil for anything
    /// else, and in a new worktree.
    static func alsoPushes(
        _ subject: TaskSubject, fixes: Bool, to target: SessionChoice?, delivery: Delivery, taking parts: [PullRequestPart],
        store: CopilotTasksStore
    ) -> String? {
        guard fixes, case .pullRequest(let pullRequest, .pushAndReply) = subject, let target else { return nil }
        let key = PRKey(pullRequest.organization, pullRequest.id)
        return store.alsoPushes(key, among: store.partsToFix(key), in: target, forkedWithTheCLI: delivery == .cliFork, taking: parts)
    }

    /// What happens in the Copilot app, as things stand: BriefBar sends it, to the session or a fork of it, or copies it
    /// for you to paste.
    private var appFootnote: String {
        let works = "Copilot works on it there, with the session's own model, mode and permissions, where you can follow it."
        if reach?.sends(forking: delivery.forks) == false {
            if reach == .noListener(inApp: false) {
                let then = delivery.forks ? "fork it with /fork, then paste the prompt in the fork" : "paste it"
                return "BriefBar copies the prompt and brings up the terminal where a Copilot CLI has the session open. Find the session's window or tab there, \(then), and send it."
            }
            return delivery.forks
                ? "BriefBar copies /fork and the prompt, and opens the session in the Copilot app: paste it there, and send it. The app forks the session, and sends the fork the prompt."
                : "BriefBar copies the prompt and opens the session in the Copilot app: paste it there, and send it. \(works)"
        }
        if delivery.forks {
            return "The Copilot app forks the session, with its history and the changes it hasn't committed, into a worktree of its own, and BriefBar sends the fork the prompt, as yours. The session itself only notes the fork. Copilot works on it in the fork, with the session's own model, mode and permissions."
        }
        let sends = reach == .loads
            ? "BriefBar opens the session in the Copilot app, which loads it, and sends it the prompt, as yours."
            : "BriefBar sends the prompt to the session in the Copilot app, as yours, and opens it."
        return "\(sends) \(works)"
    }

    /// Why BriefBar couldn't send it itself, and what it did instead: what it copied, and where to paste it. BriefBar brings
    /// up a CLI's terminal, but not necessarily the session's window or tab in it, so you find that yourself.
    static func fallbackNote(_ fallback: SessionFallback) -> String {
        var reason = fallback.reason
        if let last = reason.last, !".!?".contains(last) { reason += "." }
        let session = fallback.fork == nil ? "session" : "fork"
        var text: String
        switch fallback.place {
        case .app:
            let copied = fallback.pastesFork ? "/fork and the prompt" : "the prompt"
            text = "\(reason) BriefBar copied \(copied) and opened the \(session) in the Copilot app: paste it there, and send it."
        case .terminal:
            let then = fallback.forksFirst ? "fork it with /fork, then paste the prompt in the fork" : "paste it"
            text = "\(reason) BriefBar copied the prompt and brought up the terminal where a Copilot CLI has the \(session) open. Find the \(session)'s window or tab there, \(then), and send it."
        }
        if let uncertainty = fallback.uncertainty { text += " " + uncertainty }
        return text
    }

    private var canSend: Bool {
        guard store.canSend, store.isOn, !isDelivering, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let hasModel = !model.trimmingCharacters(in: .whitespaces).isEmpty
        guard let target else {
            return !mustContinue && !isBusy && repository != nil && !isChecking && hasModel
        }
        // A fork works in a worktree of its own, so the session's own checkout and state don't matter, nor whether Copilot
        // works in it now.
        if delivery == .cliFork { return hasModel && Self.offersCLIFork(target, mustContinue: mustContinue) }
        guard !target.isUnavailable else { return false }
        switch delivery.place {
        case .app: return appProblem == nil && (!delivery.forks || Self.offersFork(target, mustContinue: mustContinue))
        case .cli: return !isBusy && hasModel && cliProblem == nil && checkingSession == nil
        }
    }

    // MARK: Finding sessions

    private func setUp() {
        // The demo's made-up clone, as BriefBar would find yours once you chose it: the demo sends nothing.
        if store.mode == .demo, !hasAppeared {
            hasAppeared = true
            repository = CopilotTasksStore.demoRepository(for: subject)
            refreshPrompt()
            return
        }
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

    /// You chose where the pull request's work goes in its details, or left it to BriefBar again: it goes there, until you
    /// choose here or change the prompt (`update`), once the sessions are found again, as one may have started since the
    /// window looked for them.
    private func choseInDetails() {
        if isLooking {
            looksAgain = true
        } else {
            findSessions()
        }
    }

    /// The sessions it can go to: BriefBar's tasks and the Copilot app's sessions first, then which of the app's mention
    /// it, which takes longer. What's suggested goes in unless you've chosen.
    private func findSessions() {
        isLooking = true
        Task {
            let found = await store.sessionChoices(for: subject)
            choices = found
            update()
            let mentioned = await store.sessionsMentioning(subject, among: found, since: createdAt)
            if !mentioned.isEmpty {
                // On the sessions as they are by now, which kept up with BriefBar's tasks while the logs were read.
                choices = store.marking(mentioned, in: choices, createdAt: createdAt)
                update()
            }
            isLooking = false
            if looksAgain {
                looksAgain = false
                findSessions()
            }
        }
    }

    /// Keeps up with BriefBar's tasks while the window is open: a session frees up once the task working in it, or in its
    /// folder, is done, and one a task starts in is taken. Where it goes, and the prompt, stay as they are.
    private func refreshAvailability() {
        guard hasAppeared, !choices.isEmpty else { return }
        let refreshed = store.availability(of: choices)
        guard refreshed != choices else { return }
        choices = refreshed
        update()
    }

    /// Keeps the chosen session as it was found, and goes to the suggested one until you choose one or change the prompt.
    /// Push & Reply stays with its last task's session. Not while BriefBar sends it, or once it copied it: the window shows
    /// what went, and where.
    private func update() {
        guard !isDelivering, fallback == nil else { return }
        if let current = target, let found = choices.first(where: { $0.id == current.id }), found != current {
            target = found
            // While it couldn't be used, neither could the way to send it be chosen, but for a fork with the CLI, which it
            // didn't keep from: it's back to the usual one.
            if current.isUnavailable, !found.isUnavailable, delivery != .cliFork { go(found.opensInApp ? .session : .cli) }
            checkSession()
        }
        guard Self.followsSuggestions(choseTarget: choseTarget, mustContinue: mustContinue, promptChanged: prompt != filledIn) else {
            return
        }
        let suggested = store.suggestedChoice(choices, for: subject)
        if suggested?.id != target?.id { select(suggested, byYou: false) }
    }

    /// Whether a session BriefBar suggests later, as it finds them, takes the place of the one chosen now. Not once you
    /// chose one; not for Push & Reply, which ships its last task's changes in its session; and not once you changed the
    /// prompt, which you wrote for where it goes now.
    static func followsSuggestions(choseTarget: Bool, mustContinue: Bool, promptChanged: Bool) -> Bool {
        !choseTarget && !mustContinue && !promptChanged
    }

    private func select(_ choice: SessionChoice?, byYou: Bool) {
        if byYou { choseTarget = true }
        target = choice
        // Whether the Copilot app's sessions open at all, rather than why the last one didn't: it can be tried again.
        appProblem = store.canOpenInApp ? nil : CopilotTasksStore.cantOpenInApp
        delivery = choice?.opensInApp == true ? .session : .cli
        reach = nil
        deliveryProblem = nil
        refreshPrompt()
        checkSession()
    }

    /// The prompt BriefBar writes for where Copilot works now (`writtenPrompt`). Reset goes back to it from now on; the
    /// prompt itself changes only if you hadn't changed the one it wrote before.
    private func refreshPrompt() {
        let written = Self.writtenPrompt(
            for: target, subject: subject, template: template, worktreePrompt: worktreePrompt, sessionPrompt: sessionPrompt,
            baseBranch: repository?.baseBranch, forks: delivery.forks, asksForStage: asksForStage
        )
        (prompt, filledIn) = Self.rewritten(prompt: prompt, filledIn: filledIn, written: written)
    }

    /// The prompt and what Reset goes back to, once BriefBar writes `written`: Reset always goes back to what it wrote
    /// last, and the prompt follows only if you hadn't changed it.
    static func rewritten(prompt: String, filledIn: String, written: String) -> (prompt: String, filledIn: String) {
        (prompt == filledIn ? written : prompt, written)
    }

    /// Goes the way that works when only one does: in the Copilot app when the CLI can't go on with the session, with the
    /// CLI when nothing opens the app's sessions; and to the session itself when it can't go to a fork (`offersFork`).
    private func fixDelivery() {
        if delivery == .cliFork {
            if !Self.offersCLIFork(target, mustContinue: mustContinue) { go(.cli) }
            return
        }
        if delivery.forks, !Self.offersFork(target, mustContinue: mustContinue) { go(.session) }
        if delivery.place == .cli, cliProblem != nil, appProblem == nil { delivery = .session }
        if delivery.place == .app, appProblem != nil, cliProblem == nil { delivery = .cli }
    }

    /// Whether the CLI can go on with the chosen session from here: not while Copilot works in it or in its checkout, or the
    /// Copilot app has it open; not while another of the app's sessions runs a turn in that checkout; and only in a
    /// repository, the pull request's clone for one (`CopilotTasksStore.cliProblem`), as things are now, not as the window
    /// found them. An earlier task's session too: it may have gone on with one of the app's sessions, or another of them
    /// may work in its worktree. And how a prompt would reach it in the Copilot app (`checkReach`).
    private func checkSession() {
        cliProblem = nil
        checkingSession = nil
        guard let choice = target else { return }
        checkReach(choice)
        if choice.isBusy {
            cliProblem = "Copilot is still working in it."
        } else if choice.isFolderBusy {
            cliProblem = "Copilot is working in its checkout for another task BriefBar sent."
        } else {
            checkingSession = choice.id
            Task {
                let problem = await store.cliProblem(for: choice, subject: subject)
                guard checkingSession == choice.id, target?.id == choice.id else { return }
                checkingSession = nil
                cliProblem = problem
                fixDelivery()
            }
        }
        fixDelivery()
    }

    /// Whether BriefBar can send the prompt to the session itself, through its extension in it, and how
    /// (`CopilotTasksStore.reach`): what the window says before you send it. Nothing's read while Send Work to Copilot is
    /// off, or in the demo.
    private func checkReach(_ choice: SessionChoice) {
        guard store.canSend, store.isOn else { return }
        Task {
            let found = await store.reach(of: choice)
            guard target?.id == choice.id, found != reach else { return }
            reach = found
        }
    }

    /// Looks again, every few seconds while the window is open, as what the CLI needs can change by itself: the Copilot
    /// app opens or closes the session, or another of its sessions starts or ends a turn in the same checkout. Its
    /// repository doesn't change meanwhile: once it passed, it isn't checked again. What the window shows changes only
    /// once something did, so nothing flickers; as when it opened, it goes in the Copilot app once the CLI can't go on
    /// with it, which Send then says, and stays so once the CLI can again, until you choose. How a prompt would reach the
    /// session in the app changes as the app opens it, and as BriefBar's extension in it starts or ends.
    private func recheckSession() async {
        guard store.canSend, store.isOn, let choice = target, !choice.isUnavailable, checkingSession == nil else { return }
        let found = await store.reach(of: choice)
        if target?.id == choice.id, found != reach { reach = found }
        let problem = await store.cliProblem(for: choice, subject: subject, checksRepository: cliProblem != nil)
        guard target?.id == choice.id, checkingSession == nil, problem != cliProblem else { return }
        cliProblem = problem
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
        guard ThisMac.ask(panel) == .OK, let url = panel.url else { return }
        check(url)
    }

    // MARK: Sending

    /// What it takes on, going to `session`, as the prompt you send still lists it: a thread whose entry you took out isn't;
    /// its builds and conflicts are. A Push & Reply also takes on the builds and conflicts whose fixes are done and not
    /// pushed in the session it goes on with, which its push takes along, though it replies on none of them
    /// (`CopilotTasksStore.unpushedParts`), so that each says it's pushed, however it was sent; not one that fixes the
    /// threads it takes on first, which says it fixed those, and which the session's fixes go along with all the same
    /// (`CopilotTasksStore.work(on:of:for:)`).
    private func sentParts(to session: String?) -> [PullRequestPart] {
        var parts = Self.sentParts(self.parts, in: prompt)
        if case .pullRequest(let pullRequest, .pushAndReply) = subject, !fixes, let session {
            for part in store.unpushedParts(of: PRKey(pullRequest.organization, pullRequest.id), in: session) where !parts.contains(part) {
                parts.append(part)
            }
        }
        return parts
    }

    /// Of `parts`, those a prompt takes on as you send it: the threads whose entries it still lists, and the rest.
    static func sentParts(_ parts: [PullRequestPart], in prompt: String) -> [PullRequestPart] {
        let listed = Set(PullRequestPrompt.threadsListed(in: prompt, among: parts.compactMap(\.thread)))
        return parts.filter { part in part.thread.map(listed.contains) ?? true }
    }

    /// What a prompt sent to one of the Copilot app's sessions, or to a fork of it, is about, for each to say what became of
    /// it: a fix of some of its threads, builds or conflicts, or Push & Reply, even of none of them, which pushes what the
    /// session changed, for the fixes there to say they're pushed, and which may fix the threads it takes on first.
    private func aboutParts(to session: String?) -> SentPrompt.About? {
        let parts = sentParts(to: session)
        guard case .pullRequest(let pullRequest, let action) = subject, !parts.isEmpty || action == .pushAndReply else { return nil }
        let purpose: SentPrompt.Purpose
        switch action {
        case .fixComments, .fixBuild, .resolveConflicts: purpose = .fix
        case .pushAndReply: purpose = .pushAndReply
        case .review: return nil
        }
        return SentPrompt.About(
            pullRequest: PRKey(pullRequest.organization, pullRequest.id), purpose: purpose, parts: parts, target: pullRequest.targetBranch,
            fixes: fixes
        )
    }

    private func send() {
        guard canSend else { return }
        // The prompt names the branch the pull request merged into as the window wrote it, which BriefBar checks what the
        // session would push against: once the list has read another, it doesn't go; nor once the pull request was
        // completed or abandoned, as a comment's composer has it.
        if let problem = store.windowProblem(subject) {
            deliveryProblem = problem
            return
        }
        let options = CopilotRunOptions(model: model.trimmingCharacters(in: .whitespaces), effort: effort)
        guard let target else {
            guard let folder = repository?.root else { return }
            store.send(subject, prompt: prompt, options: options, repository: folder, parts: sentParts(to: nil), handOff: handOff, fixing: fixes)
            close()
            return
        }
        // A fork of one of BriefBar's own sessions, which works in a worktree of its own, however the session stands.
        if delivery == .cliFork, case .task(let run) = target.kind {
            store.send(
                subject, prompt: prompt, options: options, repository: run.repository, forking: run, parts: sentParts(to: nil), handOff: handOff,
                fixing: fixes
            )
            close()
            return
        }
        // Copilot started working in it, or in its checkout, since the window opened.
        if store.busyReason(for: target) != nil {
            self.target?.isBusy = store.isWorking(inSession: target.id)
            self.target?.isFolderBusy = !(self.target?.isBusy ?? false)
            checkSession()
            return
        }
        switch delivery.place {
        case .app:
            return deliver(to: target)
        case .cli:
            switch target.kind {
            case .task(let run):
                store.send(
                    subject, prompt: prompt, options: options, repository: run.repository, continuing: run, parts: sentParts(to: run.id),
                    handOff: handOff, fixing: fixes
                )
            case .app(let session):
                guard let run = store.appRun(for: session, subject: subject, options: options) else {
                    cliProblem = "BriefBar can't tell which folder it works in."
                    fixDelivery()
                    return
                }
                store.send(
                    subject, prompt: prompt, options: options, repository: run.repository, continuing: run, parts: sentParts(to: session.id),
                    handOff: handOff, fixing: fixes
                )
            }
        }
        close()
    }

    /// Sends it to the session in the Copilot app, or to a fork of it (`CopilotTasksStore.deliver`). The window closes once
    /// it's sent, or once BriefBar copied it for you to paste and opened the session in the app, as the window said it
    /// would; it stays to say why when BriefBar copied it unexpectedly, or nothing went, and where to paste it when a CLI
    /// has the session open in a terminal. Closing the window, or showing another task in it, stops it
    /// (`CopilotComposer.stopSending`).
    private func deliver(to target: SessionChoice) {
        isDelivering = true
        deliveryProblem = nil
        let text = prompt
        let forking = delivery.forks
        // What the window said it would do as you sent it.
        let saidItWouldCopy = reach?.sends(forking: forking) == false
        // A fork is a session of its own, whose fixes aren't the session's.
        let about = aboutParts(to: forking ? nil : target.id)
        // Push & Reply goes only once what the session's folder would push is checked.
        let pushing: TaskPullRequest? = if case .pullRequest(let pullRequest, .pushAndReply) = subject { pullRequest } else { nil }
        sending(Task {
            let result = await store.deliver(text, to: target, forking: forking, handOff: handOff, about: about, checkingPush: pushing)
            // The window closed, or shows another task: it was stopped.
            guard !Task.isCancelled else { return }
            isDelivering = false
            switch result {
            case .sent, .forkedAndSent:
                close()
            case .fellBack(let fallback):
                // In a terminal, the window stays to say where to paste it: BriefBar can't bring up the session's own tab.
                if fallback.wasForeseen, saidItWouldCopy, fallback.place == .app { close() } else { self.fallback = fallback }
            case .notSent(let why):
                if why == CopilotTasksStore.cantOpenInApp {
                    appProblem = why
                    fixDelivery()
                } else {
                    deliveryProblem = why
                }
            }
        })
    }
}

/// The model: one of the suggestions, or any other your plan offers, by its ID.
struct CopilotModelMenu: View {
    @Binding var model: String
    /// A capsule, as the composer's prompt has it, rather than a pop-up button, as Settings has.
    var isCapsule = false

    var body: some View {
        if isCapsule {
            ComposerCapsuleMenu(symbol: "sparkles", title: title) { items }
                .help("The model Copilot works with")
        } else {
            Menu {
                items
            } label: {
                Text(title)
            }
            .fixedSize()
        }
    }

    private var title: String {
        model.isEmpty ? "Choose a Model" : CopilotModel.name(of: model)
    }

    @ViewBuilder private var items: some View {
        ForEach(CopilotModel.suggestions) { choice in
            Button {
                model = choice.id
            } label: {
                CheckedMenuLabel(title: choice.name, isChecked: choice.id == model)
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
        guard ThisMac.ask(alert) == .alertFirstButtonReturn else { return nil }
        let model = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }
}

/// How hard the model thinks; Default leaves it to the model.
struct CopilotEffortPicker: View {
    @Binding var effort: String?
    /// A capsule, as the composer's prompt has it, rather than a pop-up button, as Settings has.
    var isCapsule = false

    private static let help = "Reasoning effort: how hard the model thinks. Not every model takes every one."

    var body: some View {
        if isCapsule {
            ComposerCapsuleMenu(symbol: "brain", title: effort.map(CopilotModel.effortName) ?? "Default Effort") {
                Button {
                    effort = nil
                } label: {
                    CheckedMenuLabel(title: "Default Effort", isChecked: effort == nil)
                }
                ForEach(CopilotModel.efforts, id: \.self) { choice in
                    Button {
                        effort = choice
                    } label: {
                        CheckedMenuLabel(title: CopilotModel.effortName(choice), isChecked: effort == choice)
                    }
                }
            }
            .help(Self.help)
        } else {
            Picker("Effort", selection: $effort) {
                Text("Default Effort").tag(String?.none)
                ForEach(CopilotModel.efforts, id: \.self) { effort in
                    Text(CopilotModel.effortName(effort)).tag(Optional(effort))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(Self.help)
        }
    }
}
