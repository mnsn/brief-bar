import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

// Your own part in a pull request's comment threads, with Make Changes in Azure DevOps on: Reply, and the thread's status,
// in the row with Copilot's Explain and Fix (`ThreadCopilotActions`); your reply in place, with Fix Grammar; and what went
// wrong, in a sentence on the thread. What they change, and how, is `ThreadChanges`'.

// MARK: - The buttons

/// Reply, and the thread's status: Resolve on an open thread, or Reactivate on a resolved one, with the statuses Azure
/// DevOps' own menu offers one ▾ away. A status changes at once: it's set back the same way, so nothing asks first. While a
/// change is sent, what it is, in their place.
struct ThreadReplyButtons: View {
    let thread: PullRequestPanel.Thread
    let item: PRSnapshot
    @Binding var composing: CopilotComposing?
    /// Keeps the thread where it is in the details as you change it.
    let hold: (PullRequestPanel.Thread) -> Void

    @EnvironmentObject private var changes: ThreadChanges
    @Environment(\.threadChangesPreview) private var preview
    @FocusState private var isReplyFocused: Bool

    private var key: ThreadChanges.Key { ThreadChanges.Key(pullRequest: item.key, thread: thread.id) }
    private var state: ThreadChanges.State? { preview?.states[thread.id] ?? changes.state(of: key) }

    var body: some View {
        Group {
            if case .sending(let sending)? = state {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(Self.sendingTitle(sending))
                }
                .font(size: 11.5, weight: .medium)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 6) {
                    Button {
                        ThreadReplyArea.open(thread, composing: $composing, hold: hold)
                    } label: {
                        Label(changes.draft(key).isEmpty ? "Reply" : "Reply (Draft)", systemImage: "arrowshape.turn.up.left")
                    }
                    .focused($isReplyFocused)
                    .help(changes.draft(key).isEmpty
                        ? "Reply in this thread in Azure DevOps, as you"
                        : "Go on with the reply you started, to send it in Azure DevOps, as you")
                    ThreadStatusButton(thread: thread) { status in
                        hold(thread)
                        Task { await changes.setStatus(status, of: thread.thread, in: item.key) }
                    }
                }
            }
        }
        // Back from your reply, once it's sent or closed: the keyboard's focus is where it was.
        .onAppear {
            guard changes.takeFocus(key) else { return }
            Task { @MainActor in isReplyFocused = true }
        }
    }

    /// "Replying…", "Resolving…", "Setting to Won't Fix…".
    static func sendingTitle(_ sending: ThreadChanges.Sending) -> String {
        switch sending {
        case .reply: "Replying…"
        case .status(.fixed): "Resolving…"
        case .status(.active): "Reactivating…"
        case .status(let status): "Setting to \(status.title)…"
        }
    }
}

/// Where Reply and its status would be, on a pull request whose threads can't be changed though Make Changes in Azure
/// DevOps is on, as one that's completed or abandoned, or that left your lists while its details show it: a lock, which
/// says why in its tooltip and to VoiceOver.
struct ThreadReadOnlyMark: View {
    let reason: String

    var body: some View {
        Image(systemName: "lock")
            .font(size: 11, weight: .medium)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .help(reason)
            .accessibilityElement()
            .accessibilityLabel("Read Only")
            .accessibilityValue(reason)
    }
}

/// A thread's status: Resolve on an open thread, Reactivate on a resolved one; ▾ has every status Azure DevOps' own menu
/// offers, the one it has checked.
struct ThreadStatusButton: View {
    let thread: PullRequestPanel.Thread
    let set: (ThreadStatus) -> Void

    var body: some View {
        let current = thread.thread.threadStatus
        Menu {
            ThreadStatusMenuItems(current: current, set: set)
        } label: {
            Label(Self.title(thread), systemImage: thread.isResolved ? "arrow.uturn.backward" : "checkmark")
        } primaryAction: {
            set(Self.primary(thread))
        }
        .fixedSize()
        .help(thread.isResolved
            ? "Reactivate this thread in Azure DevOps, as you; its menu sets another status"
            : "Resolve this thread in Azure DevOps, as you; its menu sets another status, such as Won't Fix or Closed")
        .accessibilityLabel(Self.title(thread))
        .accessibilityHint("Sets the thread's status in Azure DevOps. Its menu has the other statuses.")
    }

    /// Resolve, or Reactivate on a resolved thread.
    static func primary(_ thread: PullRequestPanel.Thread) -> ThreadStatus {
        thread.isResolved ? .active : .fixed
    }

    static func title(_ thread: PullRequestPanel.Thread) -> String {
        thread.isResolved ? "Reactivate" : "Resolve"
    }
}

/// The statuses a thread can be set to, as Azure DevOps' own menu offers them, the one it has checked: in its status
/// button's menu, and in its card's.
struct ThreadStatusMenuItems: View {
    let current: ThreadStatus?
    let set: (ThreadStatus) -> Void

    var body: some View {
        ForEach(ThreadStatus.choices(for: current), id: \.self) { status in
            Button {
                if status != current { set(status) }
            } label: {
                CheckedMenuLabel(title: status.title, isChecked: status == current)
            }
        }
    }
}

// MARK: - Under the buttons

/// Under a thread's buttons, with Make Changes in Azure DevOps on: your reply, while it's open, in their place; or else
/// what went wrong with a change, in a sentence, with what may help.
struct ThreadReplyArea: View {
    let thread: PullRequestPanel.Thread
    let item: PRSnapshot
    let pullRequest: PullRequest?
    @Binding var composing: CopilotComposing?
    let hold: (PullRequestPanel.Thread) -> Void

    @EnvironmentObject private var changes: ThreadChanges
    @EnvironmentObject private var store: PRStore
    @Environment(\.threadChangesPreview) private var preview

    private var key: ThreadChanges.Key { ThreadChanges.Key(pullRequest: item.key, thread: thread.id) }
    private var state: ThreadChanges.State? { preview?.states[thread.id] ?? changes.state(of: key) }

    var body: some View {
        let canChange = preview?.readOnly == nil && changes.canChange(pullRequest)
        VStack(alignment: .leading, spacing: 0) {
            if canChange, composing == .reply(to: thread.id) {
                ThreadReplyComposer(thread: thread, item: item, hold: hold) {
                    if composing == .reply(to: thread.id) { composing = nil }
                }
                // A new one for each thread, with its own words.
                .id(thread.id)
            } else if case .failed(let problem, let sending)? = state {
                // Also once it can't be changed, as the pull request left your lists as you sent: but nothing to try again.
                ThreadChangeProblemLine(
                    problem: problem, kind: sending.kind, retry: canChange ? retry(sending) : nil, signIn: signIn(problem)
                ) {
                    changes.dismiss(key)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, showsSomething ? 10 : 0)
        .onAppear {
            if preview?.replies[thread.id] != nil { composing = .reply(to: thread.id) }
        }
        // Turned off, or the pull request closed, while your reply was open: it's closed, so Explain and Fix show again.
        .onChange(of: changes.canChange(pullRequest)) { _, can in
            if !can, composing == .reply(to: thread.id) { composing = nil }
        }
    }

    private var showsSomething: Bool {
        if changes.canChange(pullRequest), composing == .reply(to: thread.id) { return true }
        if case .failed? = state { return true }
        return false
    }

    /// Opens your reply on a thread, closing any other composer in the details, and keeps the thread where it is.
    static func open(_ thread: PullRequestPanel.Thread, composing: Binding<CopilotComposing?>, hold: (PullRequestPanel.Thread) -> Void) {
        hold(thread)
        composing.wrappedValue = .reply(to: thread.id)
    }

    /// What tries again: a status, again; a reply, its composer, with what you wrote.
    private func retry(_ sending: ThreadChanges.Sending) -> (title: String, action: () -> Void) {
        switch sending {
        case .reply:
            return ("Reply…", { Self.open(thread, composing: $composing, hold: hold) })
        case .status(let status):
            return ("Try Again", {
                hold(thread)
                Task { await changes.setStatus(status, of: thread.thread, in: item.key) }
            })
        }
    }

    private func signIn(_ problem: ADOWriteProblem) -> (() -> Void)? {
        guard problem == .signedOut || problem == .otherAccount, store.mode == .live else { return nil }
        return { store.signIn() }
    }
}

/// What went wrong with a change to a thread, in a sentence, in a failing state's color: with what may help, such as
/// trying again or signing in, and ✕.
struct ThreadChangeProblemLine: View {
    let problem: ADOWriteProblem
    let kind: ADOWrite.Kind
    let retry: (title: String, action: () -> Void)?
    var signIn: (() -> Void)?
    let dismiss: () -> Void

    @Environment(\.textScale) private var textScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(size: 11, weight: .semibold)
                .foregroundStyle(ItemState.failing.color)
                .accessibilityHidden(true)
            Text(problem.sentence(kind))
                .font(size: 11.5, weight: .medium)
                .foregroundStyle(ItemState.failing.textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let signIn {
                Button("Sign In…", action: signIn)
                    .buttonStyle(.borderless)
                    .font(size: 11.5, weight: .medium)
                    .fixedSize()
                    .help("Sign in to the Azure CLI, in Terminal")
            }
            if let retry {
                Button(retry.title, action: retry.action)
                    .buttonStyle(.borderless)
                    .font(size: 11.5, weight: .medium)
                    .fixedSize()
            }
            CopilotDismissButton(action: dismiss)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ItemState.failing.color.opacity(0.08)))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Your reply

/// Your reply on a thread, in place, under it, as Copilot's composers are: a field for Markdown, which ⌘Return sends, as
/// you, in Azure DevOps, and ⇧⌘Return sends and resolves the thread, or reactivates a resolved one; Fix Grammar, one ▾ from
/// its model; ✕ or Esc closes it, keeping what you wrote until you send it. As it opens, the details scroll to show it all.
/// Nothing goes until you click.
struct ThreadReplyComposer: View {
    let thread: PullRequestPanel.Thread
    let item: PRSnapshot
    let hold: (PullRequestPanel.Thread) -> Void
    /// It's closed: with ✕ or Esc, or once it's sent.
    let close: () -> Void

    @EnvironmentObject private var changes: ThreadChanges
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var store: PRStore
    @Environment(\.threadChangesPreview) private var preview
    @Environment(\.isRendering) private var isRendering
    @Environment(\.detailsScroll) private var scroll
    @Environment(\.textScale) private var textScale

    @LocalState private var text = ""
    @LocalState private var hasAppeared = false
    /// Fix Grammar, while it runs.
    @LocalState private var fixing: Task<Void, Never>?
    /// What Fix Grammar suggests, to use or not.
    @LocalState private var suggestion: GrammarSuggestion?
    /// What you had before you used a suggestion, while your reply is as it left it.
    @LocalState private var undo: GrammarSuggestion?
    @LocalState private var grammarProblem: GrammarFixer.Problem?
    @FocusState private var isFocused: Bool

    private var key: ThreadChanges.Key { ThreadChanges.Key(pullRequest: item.key, thread: thread.id) }
    private var state: ThreadChanges.State? { preview?.states[thread.id] ?? changes.state(of: key) }

    private var isSending: Bool {
        if case .sending? = state { return true }
        return false
    }

    private var isFixing: Bool { fixing != nil }
    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { !isBlank && !isSending && !isFixing }

    /// What the second button does to the thread as it replies: resolves an open one, or reactivates a resolved one, as
    /// Azure DevOps' own does.
    private var then: ThreadStatus { ThreadStatusButton.primary(thread) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.bottom, 2)
            header
            editor
            if let suggestion {
                GrammarSuggestionView(suggestion: suggestion, model: modelName(suggestion.model)) {
                    use(suggestion)
                } dismiss: {
                    self.suggestion = nil
                }
            } else if let undo {
                undoLine(undo)
            } else if let grammarProblem {
                grammarProblemLine(grammarProblem)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    grammarButton
                    Spacer(minLength: 4)
                    sendButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    grammarButton
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        sendButtons
                    }
                }
            }
            notes
        }
        // Esc closes it, not the details it's in.
        .preference(key: InlineComposerOpen.self, value: true)
        .id(Self.scrollID)
        .onChange(of: text) {
            if preview == nil { changes.keep(text, for: key) }
            // Changed after you used a suggestion: Undo would take what you wrote since too.
            if let undo, text != undo.corrected { self.undo = nil }
            // Changed while a suggestion shows: it corrects what you wrote before, and would take what you wrote since.
            if let suggestion, text != suggestion.original { self.suggestion = nil }
        }
        .onAppear(perform: appear)
        // Fix Grammar is this reply's own: it stops as the reply closes. What it sends isn't: a reply you sent goes on.
        // Off screen, as a file's page scrolls it away while keeping what it holds: Fix Grammar stops, and nothing waits on it
        // as it comes back.
        .onDisappear {
            fixing?.cancel()
            fixing = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply")
    }

    /// The composer, for the details to scroll to as it opens: one is open at a time.
    static let scrollID = "thread-reply-composer"

    private func appear() {
        guard !hasAppeared else { return }
        hasAppeared = true
        if let preview = preview?.replies[thread.id] {
            text = preview.text
            suggestion = preview.suggestion
            undo = preview.undo
            grammarProblem = preview.grammarProblem
        } else {
            text = changes.draft(key)
            guard !isRendering else { return }
            isFocused = true
        }
        // All of it in view, once it's laid out, however far down it opened: in `--render`'s pictures too, once the details
        // went to its thread, as at the largest text, where it opens below what shows.
        guard let scroll else { return }
        let isRendering = isRendering
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(isRendering ? 200 : 80))
            withAnimation(isRendering ? nil : .easeOut(duration: 0.2)) { scroll.scrollTo(Self.scrollID) }
        }
    }

    // MARK: Its parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(size: 11.5, weight: .semibold)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Reply")
                .font(size: 12.5, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            Button(action: closeKeepingFocus) {
                Image(systemName: "xmark")
                    .font(size: 10, weight: .semibold)
                    .frame(width: 18 * textScale, height: 18 * textScale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc): what you wrote stays, until you send it")
            .accessibilityLabel("Close Reply")
        }
    }

    /// A field for Markdown as tall as what's in it, from three lines to ten, then it scrolls. Return starts a new line.
    private var editor: some View {
        let line = 15.5 * textScale
        return Text(verbatim: text.isEmpty ? " " : text + " ")
            .font(size: 12.5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 3 * line, maxHeight: 10 * line, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .overlay(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(size: 12.5)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .disabled(isSending || isFixing)
                    .accessibilityLabel("Your reply, in Markdown")
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Write your reply, in Markdown")
                        .font(size: 12.5)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isFocused ? 0.6 : 0.2), lineWidth: isFocused ? 1.5 : 1)
            )
    }

    /// Reply & Resolve, or Reply & Reactivate on a resolved thread, then Reply, which ⌘Return presses.
    private var sendButtons: some View {
        HStack(spacing: 6) {
            if case .sending(let sending)? = state {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(ThreadReplyButtons.sendingTitle(sending))
                }
                .font(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
            } else {
                Button("Reply & \(ThreadStatusButton.title(thread))") { send(then: then) }
                    .font(size: 12, weight: .medium)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help(thread.isResolved
                        ? "Reply, then reactivate the thread, in Azure DevOps, as you (⇧⌘Return)"
                        : "Reply, then resolve the thread, in Azure DevOps, as you (⇧⌘Return)")
                    .disabled(!canSend)
                Button("Reply") { send(then: nil) }
                    // As big as the text on windows' pages, which a control's own font isn't.
                    .font(size: 12, weight: .semibold)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Reply in Azure DevOps, as you (⌘Return)")
                    .disabled(!canSend)
            }
        }
        .controlSize(.small)
        .fixedSize()
    }

    /// What it does, or why it didn't: what went wrong with your reply, with Sign In when that's why, or what the demo
    /// does; and, with a Copilot model, what Fix Grammar costs, and where your reply goes.
    @ViewBuilder
    private var notes: some View {
        let isDemo = store.mode == .demo
        let problem: ADOWriteProblem? = if case .failed(let problem, let sending)? = state, sending.kind == .reply { problem } else { nil }
        VStack(alignment: .leading, spacing: 3) {
            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    note(problem.sentence(.reply), symbol: "exclamationmark.triangle.fill", isWarning: true)
                    if problem == .signedOut || problem == .otherAccount, !isDemo {
                        Button("Sign In…") { store.signIn() }
                            .buttonStyle(.borderless)
                            .font(size: 11, weight: .medium)
                            .fixedSize()
                            .help("Sign in to the Azure CLI, in Terminal: what you wrote stays here")
                    }
                }
            } else {
                note(isDemo ? "Markdown. The demo changes only its made-up pull requests: nothing goes to Azure DevOps."
                    : "Markdown. ⌘Return replies in Azure DevOps, as you.", symbol: "info.circle")
            }
            if settings.grammarModel != StorySummaries.appleIntelligenceModel {
                note(
                    "Fix Grammar uses \(modelName(settings.grammarModel)): each fix is one premium request, and sends your reply to "
                        + "GitHub Copilot through the Copilot CLI.",
                    symbol: "network"
                )
            }
        }
    }

    private func note(_ text: String, symbol: String, isWarning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(size: 10)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(size: 11)
        .foregroundStyle(isWarning ? AnyShapeStyle(ItemState.needsYou.textColor) : AnyShapeStyle(.secondary))
    }

    // MARK: Sending

    private func send(then status: ThreadStatus?) {
        guard canSend else {
            NSSound.beep()
            return
        }
        let markdown = text
        hold(thread)
        changes.dismiss(key)
        Task {
            guard await changes.reply(markdown, then: status, to: thread.thread, of: item.key) else { return }
            changes.focusAfter(key)
            close()
        }
    }

    /// Closes it, keeping what you wrote, and the keyboard's focus goes back to Reply.
    private func closeKeepingFocus() {
        fixing?.cancel()
        fixing = nil
        changes.focusAfter(key)
        close()
    }

    // MARK: Fix Grammar

    /// Fix Grammar, with the model you chose for it; ▾ chooses another: Apple Intelligence on this Mac, or one through
    /// Copilot, with the choices summaries offer. While it runs, Stop.
    @ViewBuilder
    private var grammarButton: some View {
        if isFixing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Fixing with \(modelName(settings.grammarModel))…")
                    .font(size: 11.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Stop") {
                    fixing?.cancel()
                    fixing = nil
                }
                .buttonStyle(.borderless)
                .font(size: 11.5, weight: .medium)
                .help("Stop Fix Grammar: your reply stays as it is")
            }
        } else {
            Menu {
                GrammarModelMenuItems(model: settings.grammarModel, models: models, canRunOnDevice: canRunOnDevice) { model in
                    settings.grammarModel = model
                    grammarProblem = nil
                }
            } label: {
                Label("Fix Grammar", systemImage: "text.badge.checkmark")
            } primaryAction: {
                fixGrammar()
            }
            .font(size: 11.5, weight: .medium)
            .controlSize(.small)
            .fixedSize()
            .disabled(isBlank || isSending)
            .help(grammarHelp)
            .accessibilityHint("Its menu chooses the model: Apple Intelligence on this Mac, or one through Copilot.")
        }
    }

    private var grammarHelp: String {
        let model = settings.grammarModel
        let does = "Correct the spelling, grammar and punctuation of your reply, keeping your words, code, links and mentions"
        if model == StorySummaries.appleIntelligenceModel { return does + ", with Apple Intelligence, on this Mac. Its menu chooses another model." }
        return does + ", with \(modelName(model)) through GitHub Copilot: one premium request, which sends your reply to GitHub Copilot. Its menu chooses another model."
    }

    /// Apple Intelligence, then the Copilot models summaries offer.
    private var models: [StorySummaries.Model] {
        services.summaries.models.contains { $0.id == StorySummaries.appleIntelligenceModel }
            ? services.summaries.models : [StorySummaries.appleIntelligence] + services.summaries.models
    }

    private var canRunOnDevice: Bool { changes.grammar.onDeviceUnavailable() == nil }

    private func modelName(_ model: String) -> String {
        models.first { $0.id == model }?.name ?? services.summaries.name(of: model)
    }

    private func fixGrammar() {
        let original = text
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isFixing else { return }
        let model = settings.grammarModel
        suggestion = nil
        undo = nil
        grammarProblem = nil
        fixing = Task {
            let result = await changes.grammar.fix(original, with: model)
            guard !Task.isCancelled else { return }
            fixing = nil
            switch result {
            case .success(let corrected):
                let found = GrammarSuggestion(original: original, corrected: corrected, model: model)
                suggestion = found
                let count = GrammarFix.changeCount(GrammarFix.changes(from: original, to: corrected))
                SpokenText.announce(count == 0 ? "Nothing to correct" : count == 1 ? "1 correction suggested" : "\(count) corrections suggested")
            case .failure(let problem):
                grammarProblem = problem
                SpokenText.announce(problem.message)
            }
        }
    }

    private func use(_ suggestion: GrammarSuggestion) {
        undo = suggestion
        self.suggestion = nil
        text = suggestion.corrected
        SpokenText.announce("Used the correction")
        isFocused = true
    }

    /// "Corrected with Apple Intelligence · Undo", while your reply is as it left it.
    private func undoLine(_ undo: GrammarSuggestion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "text.badge.checkmark")
                .font(size: 10.5, weight: .medium)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Corrected with \(modelName(undo.model))")
                .font(size: 11.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Undo") {
                text = undo.original
                self.undo = nil
                SpokenText.announce("Put back what you wrote")
            }
            .buttonStyle(.borderless)
            .font(size: 11.5, weight: .medium)
            .help("Put back what you wrote before the correction")
            Spacer(minLength: 0)
        }
    }

    /// Why Fix Grammar didn't correct it, with the models to choose instead, under it, when another may.
    private func grammarProblemLine(_ problem: GrammarFixer.Problem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(size: 10.5, weight: .semibold)
                .foregroundStyle(ItemState.needsYou.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(problem.message)
                    .font(size: 11.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(problem.detail ?? problem.message)
                if problem.choosesModel {
                    Menu("Choose a Model") {
                        GrammarModelMenuItems(model: settings.grammarModel, models: models, canRunOnDevice: canRunOnDevice) { model in
                            settings.grammarModel = model
                            grammarProblem = nil
                        }
                    }
                    .font(size: 11.5, weight: .medium)
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("Choose the model Fix Grammar uses: a Copilot model costs one premium request each time, and gets your reply")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CopilotDismissButton { grammarProblem = nil }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ItemState.needsYou.color.opacity(0.08)))
    }
}

/// What Fix Grammar suggested: your reply as you wrote it, corrected, and the model.
struct GrammarSuggestion: Equatable {
    var original: String
    var corrected: String
    var model: String
}

/// The models Fix Grammar can correct a reply with, the one it uses checked: Apple Intelligence on this Mac, free, nothing
/// leaving it; or one through Copilot, one premium request each time, which gets your reply's text.
struct GrammarModelMenuItems: View {
    let model: String
    let models: [StorySummaries.Model]
    let canRunOnDevice: Bool
    let choose: (String) -> Void

    var body: some View {
        Section("On this Mac: free, and nothing leaves it") {
            ForEach(models.filter { $0.id == StorySummaries.appleIntelligenceModel }) { choice in
                Button {
                    choose(choice.id)
                } label: {
                    CheckedMenuLabel(title: StorySummariesSetting.choiceTitle(choice, canRunOnDevice: canRunOnDevice), isChecked: choice.id == model)
                }
            }
        }
        Section("Through Copilot: one premium request each, which gets your reply") {
            ForEach(models.filter { $0.id != StorySummaries.appleIntelligenceModel }) { choice in
                Button {
                    choose(choice.id)
                } label: {
                    CheckedMenuLabel(title: StorySummariesSetting.choiceTitle(choice), isChecked: choice.id == model)
                }
            }
        }
    }
}

/// Fix Grammar's suggestion, under your reply: the reply corrected, what it changes marked, to use or not. Nothing changes
/// in your reply until you use it, and nothing is sent until you reply.
struct GrammarSuggestionView: View {
    let suggestion: GrammarSuggestion
    /// The model's name: "Apple Intelligence".
    let model: String
    let use: () -> Void
    let dismiss: () -> Void

    var body: some View {
        let pieces = GrammarFix.changes(from: suggestion.original, to: suggestion.corrected)
        let count = GrammarFix.changeCount(pieces)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "text.badge.checkmark")
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(count == 0 ? "\(model) found nothing to correct" : "Suggested by \(model)")
                    .font(size: 11.5, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if count > 0 {
                    Text(count == 1 ? "1 change" : "\(count) changes")
                        .font(size: 11)
                        .foregroundStyle(.secondary)
                }
                CopilotDismissButton(action: dismiss)
            }
            if count > 0 {
                Text(Self.marked(pieces))
                    .font(size: 12.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityLabel("Suggested: \(suggestion.corrected)")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button("Use It", action: use)
                        .font(size: 12, weight: .semibold)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Put the correction in your reply: Undo puts back what you wrote")
                    Text("Nothing goes until you reply.")
                        .font(size: 11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// The correction, what it changes in the accent color, underlined.
    static func marked(_ pieces: [GrammarFix.Piece]) -> AttributedString {
        var text = AttributedString()
        for piece in pieces {
            var run = AttributedString(piece.text)
            if piece.isChanged {
                run.foregroundColor = .accentColor
                run.underlineStyle = .single
                run.backgroundColor = Color.accentColor.opacity(0.12)
            }
            text.append(run)
        }
        return text
    }
}

// MARK: - For --render

/// For `--render`: what threads' replies and statuses show, as you'd have them, to draw each state without sending
/// anything: a reply open, with your words, Fix Grammar's suggestion or Undo; and a change being sent, or that failed.
struct ThreadChangesPreview {
    struct Reply {
        var text: String
        var suggestion: GrammarSuggestion?
        var undo: GrammarSuggestion?
        var grammarProblem: GrammarFixer.Problem?
    }

    /// The replies open, by thread.
    var replies: [Int: Reply] = [:]
    /// What threads' changes are doing, or why they didn't happen, by thread.
    var states: [Int: ThreadChanges.State] = [:]
    /// Why its threads can't be changed, as for a pull request that left your lists: each shows a lock where Reply would be.
    var readOnly: String?
}

private struct ThreadChangesPreviewKey: EnvironmentKey {
    static var defaultValue: ThreadChangesPreview? { nil }
}

extension EnvironmentValues {
    var threadChangesPreview: ThreadChangesPreview? {
        get { self[ThreadChangesPreviewKey.self] }
        set { self[ThreadChangesPreviewKey.self] = newValue }
    }
}
