import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

// Your own part in a pull request's comment threads, with Make Changes in Azure DevOps on: Reply, and the thread's status,
// in the row with Copilot's Explain and Fix (`ThreadCopilotActions`); your reply in place, with Fix Grammar, and your comment
// as you edit it, the same way; and what went wrong, in a sentence on the thread. What they change, and how, is
// `ThreadChanges`'.

// MARK: - The buttons

/// Reply, and the thread's status: Resolve on an open thread, or Reactivate on a resolved one, with the statuses Azure
/// DevOps' own menu offers one ▾ away. A status changes at once: it's set back the same way, so nothing asks first. While a
/// change is sent, what it is, in their place.
struct ThreadReplyButtons: View {
    let thread: PullRequestPanel.Thread
    let item: PRSnapshot
    @Binding var composing: CopilotComposing?
    /// Reply takes the keyboard's focus back as they show again, once your reply closed (`ThreadCard`).
    @Binding var refocuses: Bool
    /// Keeps the thread where it is in the details as you change it.
    let hold: (PullRequestPanel.Thread) -> Void

    @EnvironmentObject private var changes: ThreadChanges
    @Environment(\.threadChangesPreview) private var preview
    @FocusState private var isReplyFocused: Bool

    private var key: ThreadChanges.Key { ThreadChanges.Key(pullRequest: item.key, thread: thread.id) }
    private var state: ThreadChanges.State? { preview?.states[thread.id] ?? changes.state(of: key) }

    var body: some View {
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
                    ControlLabel(changes.draft(key).isEmpty ? "Reply" : "Reply (Draft)", systemImage: "arrowshape.turn.up.left")
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
            // Back from your reply, once it's sent or closed: the keyboard's focus is where it was, once Reply is there
            // again, not what says it's being sent; or, as you deleted a comment of yours, which takes its ⋯ with it, though
            // Reply never went.
            .onAppear(perform: refocus)
            .onChange(of: refocuses) { refocus() }
        }
    }

    /// The keyboard's focus to Reply, when it takes it back.
    private func refocus() {
        guard refocuses else { return }
        refocuses = false
        Task { @MainActor in isReplyFocused = true }
    }

    /// "Replying…", "Resolving…", "Setting to Won't Fix…", "Saving…", "Deleting…".
    static func sendingTitle(_ sending: ThreadChanges.Sending) -> String {
        switch sending {
        case .reply: "Replying…"
        case .status(.fixed): "Resolving…"
        case .status(.active): "Reactivating…"
        case .status(let status): "Setting to \(status.title)…"
        case .edit: "Saving…"
        case .delete: "Deleting…"
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
/// offers, the one it has checked. Its title as big as the text on windows' pages (`SplitMenuButton`).
struct ThreadStatusButton: View {
    let thread: PullRequestPanel.Thread
    let set: (ThreadStatus) -> Void

    var body: some View {
        let current = thread.thread.threadStatus
        SplitMenuButton(
            Self.title(thread), systemImage: thread.isResolved ? "arrow.uturn.backward" : "checkmark",
            help: thread.isResolved
                ? "Reactivate this thread in Azure DevOps, as you; its menu sets another status"
                : "Resolve this thread in Azure DevOps, as you; its menu sets another status, such as Won't Fix or Closed",
            hint: "Sets the thread's status in Azure DevOps. Its menu has the other statuses.",
            entries: ThreadStatus.choices(for: current).map { status in
                .item(status.title, isChecked: status == current) { if status != current { set(status) } }
            }
        ) {
            set(Self.primary(thread))
        }
        .fixedSize()
    }

    /// Resolve, or Reactivate on a resolved thread.
    static func primary(_ thread: PullRequestPanel.Thread) -> ThreadStatus {
        thread.isResolved ? .active : .fixed
    }

    static func title(_ thread: PullRequestPanel.Thread) -> String {
        thread.isResolved ? "Reactivate" : "Resolve"
    }
}

/// The statuses a thread can be set to, as Azure DevOps' own menu offers them, the one it has checked: in its card's menu,
/// as its status button's has them.
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
    /// Reply takes the keyboard's focus back as its buttons show again (`ThreadCard`).
    @Binding var refocuses: Bool
    let hold: (PullRequestPanel.Thread) -> Void

    @EnvironmentObject private var changes: ThreadChanges
    @EnvironmentObject private var store: PRStore
    @Environment(\.threadChangesPreview) private var preview

    private var key: ThreadChanges.Key { ThreadChanges.Key(pullRequest: item.key, thread: thread.id) }
    private var state: ThreadChanges.State? { preview?.states[thread.id] ?? changes.state(of: key) }

    var body: some View {
        let canChange = preview?.readOnly == nil && changes.canChange(pullRequest)
        let isReplying = canChange && composing == .reply(to: thread.id)
        VStack(alignment: .leading, spacing: 8) {
            if case .failed(let problem, let sending)? = state,
               !Self.showsInItsComposer(sending, composing: composing, thread: thread, canChange: canChange) {
                // A status that didn't change says so above your reply too, while it's open, as one set from the card's
                // menu: a reply's own says so in its field. Also once it can't be changed, as the pull request left your
                // lists as you sent: but nothing to try again.
                ThreadChangeProblemLine(
                    problem: problem, kind: sending.kind, retry: canChange ? retry(sending) : nil, signIn: signIn(problem)
                ) {
                    changes.dismiss(key)
                }
            } else if isReplying, case .sending(.status(let status))? = state {
                // A status on its way, from the card's menu, while your reply hides the buttons that would say so.
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(ThreadReplyButtons.sendingTitle(.status(status)))
                }
                .font(size: 11.5, weight: .medium)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            if isReplying {
                ThreadReplyComposer(thread: thread, item: item, hold: hold) {
                    // Closed with ✕ or Esc, or sent, while it's still the composer open: Reply takes the keyboard's focus
                    // back. Not for a reply that went once you'd moved on to another, which keeps it.
                    guard composing == .reply(to: thread.id) else { return }
                    composing = nil
                    refocuses = true
                }
                // A new one for each thread, with its own words.
                .id(thread.id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, showsSomething ? 10 : 0)
        .onAppear {
            if preview?.replies[thread.id] != nil { composing = .reply(to: thread.id) }
        }
        // Turned off, or the pull request closed, while your reply, or your edit of a comment, was open: it's closed, so
        // Explain and Fix show again.
        .onChange(of: changes.canChange(pullRequest)) { _, can in
            if !can, composing?.isYours(on: thread.id) == true { composing = nil }
        }
    }

    private var showsSomething: Bool {
        let canChange = preview?.readOnly == nil && changes.canChange(pullRequest)
        if canChange, composing == .reply(to: thread.id) { return true }
        if case .failed(_, let sending)? = state {
            return !Self.showsInItsComposer(sending, composing: composing, thread: thread, canChange: canChange)
        }
        return false
    }

    /// Whether what went wrong with a change shows in its own composer, open, rather than on the thread: your reply's in your
    /// reply, and your edit's in your edit, while the thread still has the comment it's in.
    static func showsInItsComposer(
        _ sending: ThreadChanges.Sending, composing: CopilotComposing?, thread: PullRequestPanel.Thread, canChange: Bool
    ) -> Bool {
        guard canChange else { return false }
        switch sending {
        case .reply: return composing == .reply(to: thread.id)
        case .edit(let comment): return composing == .edit(comment, in: thread.id) && thread.comments.contains { $0.id == comment }
        case .status, .delete: return false
        }
    }

    /// Opens your reply on a thread, closing any other composer in the details, and keeps the thread where it is.
    static func open(_ thread: PullRequestPanel.Thread, composing: Binding<CopilotComposing?>, hold: (PullRequestPanel.Thread) -> Void) {
        hold(thread)
        composing.wrappedValue = .reply(to: thread.id)
    }

    /// What tries again: a status, again; a reply, its composer, with what you wrote; an edit, the same; and a deletion,
    /// again, while the comment's there.
    private func retry(_ sending: ThreadChanges.Sending) -> (title: String, action: () -> Void)? {
        switch sending {
        case .reply:
            return ("Reply…", { Self.open(thread, composing: $composing, hold: hold) })
        case .status(let status):
            return ("Try Again", {
                hold(thread)
                Task { await changes.setStatus(status, of: thread.thread, in: item.key) }
            })
        case .edit(let comment):
            guard thread.comments.contains(where: { $0.id == comment }) else { return nil }
            return ("Edit…", {
                hold(thread)
                composing = .edit(comment, in: thread.id)
            })
        case .delete(let id):
            guard let comment = thread.comments.first(where: { $0.id == id }) else { return nil }
            return ("Try Again", {
                hold(thread)
                Task { await changes.delete(comment, in: thread.thread, of: item.key) }
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

// MARK: - Your reply, and your comment as you edit it

/// Your reply on a thread, in place, under it, as Copilot's composers are: a field for Markdown, which ⌘Return sends, as
/// you, in Azure DevOps, and ⇧⌘Return sends and resolves the thread, or reactivates a resolved one; Fix Grammar, one ▾ from
/// its model; ✕ or Esc closes it, keeping what you wrote until you send it. As it opens, the details scroll to show it all.
/// Nothing goes until you click. Editing a comment of yours (`editing`), it's the same, in place of what the comment says,
/// with what it says, but for Save, which ⌘Return presses, and Cancel, which keeps the comment as it was and forgets what
/// you wrote; ✕ or Esc keeps it, until you save it or cancel. When the comment changed since you began, as in Azure DevOps
/// or another window, it says so, with what it says now, Start Over and Save Anyway (`CommentChangedNotice`): Save alone
/// sends nothing then. The Mac checks your spelling as you type, but corrects nothing by itself (`spellChecked()`).
struct ThreadReplyComposer: View {
    let thread: PullRequestPanel.Thread
    let item: PRSnapshot
    let hold: (PullRequestPanel.Thread) -> Void
    /// A comment of yours, as you edit it, rather than your reply.
    var editing: Editing?
    /// It's closed: with ✕ or Esc, or once it's sent; or, editing a comment, saved or canceled. Reply takes the keyboard's
    /// focus back then, unless another composer opened meanwhile, as while your reply was on its way (`ThreadReplyArea`).
    let close: () -> Void

    /// A comment of yours you edit, on its pull request, whose people name its mentions as you do (`ThreadChanges.startEditing`).
    struct Editing {
        var comment: ReviewComment
        var pullRequest: PullRequest
    }

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
    /// Editing a comment, what it said as you began, whose names go back as the mentions they showed as you save it, though
    /// it changes elsewhere meanwhile.
    @LocalState private var editBase: CommentEditing?
    /// Editing a comment that changed since you began, what it said as you chose Save Anyway, which you replace then, and
    /// then only.
    @LocalState private var replacing: String?
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

    /// The comment you edit, by its thread and its ID; nil for your reply.
    private var commentKey: ThreadChanges.CommentKey? {
        editing.map { ThreadChanges.CommentKey(thread: key, comment: $0.comment.id) }
    }

    /// What it writes: "reply", or "comment".
    private var noun: String { editing == nil ? "reply" : "comment" }

    /// Whether a change it shows is its own: your reply, or your edit of the comment.
    private func isOwn(_ sending: ThreadChanges.Sending) -> Bool {
        guard let editing else { return sending.kind == .reply }
        return sending == .edit(comment: editing.comment.id)
    }

    /// Editing a comment that changed since you began, unseen, as in Azure DevOps or another window, the comment as it is
    /// now: your edit says so, and Save sends nothing (`ThreadChanges.changedSince`).
    private var changedSince: ReviewComment? {
        guard let editing, let editBase,
              changes.changedSince(editBase, now: editing.comment, editing: text, replacing: replacing, on: key)
        else { return nil }
        return editing.comment
    }

    /// What `--render` shows in it.
    private var previewed: ThreadChangesPreview.Reply? {
        guard let editing else { return preview?.replies[thread.id] }
        return preview?.edits[PreviewComment(thread: thread.id, comment: editing.comment.id)]
    }

    private var isFixing: Bool { fixing != nil }
    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { !isBlank && !isSending && !isFixing }

    /// What the second button does to the thread as it replies: resolves an open one, or reactivates a resolved one, as
    /// Azure DevOps' own does.
    private var then: ThreadStatus { ThreadStatusButton.primary(thread) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editing == nil {
                Divider()
                    .padding(.bottom, 2)
            }
            header
            editor
            if let changedSince {
                CommentChangedNotice(now: changedSince, isSending: isSending, startOver: startOver) {
                    replacing = changedSince.kept
                    save(replacing: changedSince.kept)
                }
            }
            if let suggestion {
                GrammarSuggestionView(suggestion: suggestion, model: modelName(suggestion.model), isEdit: editing != nil) {
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
                    buttons
                }
                VStack(alignment: .leading, spacing: 6) {
                    grammarButton
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        buttons
                    }
                }
            }
            notes
        }
        // Esc closes it, not the details it's in.
        .preference(key: InlineComposerOpen.self, value: true)
        .id(Self.scrollID)
        .onChange(of: text) {
            if preview == nil {
                if let commentKey {
                    if let editBase { changes.keepEdit(text, for: commentKey, from: editBase) }
                } else {
                    changes.keep(text, for: key)
                }
            }
            // Changed after you used a suggestion: Undo would take what you wrote since too.
            if let undo, text != undo.corrected { self.undo = nil }
            // Changed while a suggestion shows: it corrects what you wrote before, and would take what you wrote since.
            if let suggestion, text != suggestion.original { self.suggestion = nil }
        }
        .onAppear(perform: appear)
        // VoiceOver hears it as it changes, as when a refresh brings what someone saved meanwhile.
        .onChange(of: changedSince?.kept) { old, now in
            if now != nil, old == nil { SpokenText.announce(ThreadChanges.changedSentence + " " + ThreadChanges.changedChoices) }
        }
        // Fix Grammar is this reply's own: it stops as the reply closes. What it sends isn't: a reply you sent goes on.
        // Off screen, as a file's page scrolls it away while keeping what it holds: Fix Grammar stops, and nothing waits on it
        // as it comes back.
        .onDisappear {
            fixing?.cancel()
            fixing = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(editing == nil ? "Reply" : "Edit Your Comment")
    }

    /// The composer, for the details to scroll to as it opens: one is open at a time.
    static let scrollID = "thread-reply-composer"

    private func appear() {
        guard !hasAppeared else { return }
        hasAppeared = true
        if let preview = previewed {
            text = preview.text
            suggestion = preview.suggestion
            undo = preview.undo
            grammarProblem = preview.grammarProblem
            if let editing { editBase = CommentEditing(content: preview.began ?? editing.comment.kept, names: [:]) }
        } else if let editing {
            let started = changes.startEditing(editing.comment, in: thread.thread, of: editing.pullRequest)
            editBase = started.base
            text = started.text
            isFocused = !isRendering
            // Opened again on what you wrote before it changed: VoiceOver hears so too.
            if changes.changedSince(started.base, now: editing.comment, editing: started.text, on: key) {
                SpokenText.announce(ThreadChanges.changedSentence + " " + ThreadChanges.changedChoices)
            }
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
            Image(systemName: editing == nil ? "arrowshape.turn.up.left" : "pencil")
                .font(size: 11.5, weight: .semibold)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(editing == nil ? "Reply" : "Edit Your Comment")
                .font(size: 12.5, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            closeButton
        }
    }

    /// ✕, which Esc presses: your reply, or your edit, closes, and what you wrote stays.
    private var closeButton: some View {
        Button(action: closeKeepingFocus) {
            Image(systemName: "xmark")
                .font(size: 10, weight: .semibold)
                .frame(width: 18 * textScale, height: 18 * textScale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .help(editing == nil
            ? "Close (Esc): what you wrote stays, until you send it"
            : "Close (Esc): what you wrote stays, until you save it or cancel")
        .accessibilityLabel(editing == nil ? "Close Reply" : "Close Your Edit")
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
                    .spellChecked()
                    .focused($isFocused)
                    .disabled(isSending || isFixing)
                    .accessibilityLabel("Your \(noun), in Markdown")
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Write your \(noun), in Markdown")
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

    /// Its buttons at the end: Reply's, or, editing a comment, Cancel and Save.
    @ViewBuilder
    private var buttons: some View {
        if editing == nil { sendButtons } else { saveButtons }
    }

    /// Cancel, then Save, which ⌘Return presses. Esc presses ✕, which keeps what you wrote.
    private var saveButtons: some View {
        HStack(spacing: 6) {
            if case .sending(let sending)? = state {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(ThreadReplyButtons.sendingTitle(sending))
                }
                .font(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
            } else {
                Button(action: cancel) { ControlLabel("Cancel") }
                    .buttonStyle(.bordered)
                    .help("Keep your comment as it was, and forget what you wrote")
                Button { save() } label: { ControlLabel("Save") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Save your comment as you edited it, in Azure DevOps, as you (⌘Return)")
                    .disabled(!canSend)
            }
        }
        .controlSize(.small)
        .fixedSize()
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
                Button { send(then: then) } label: { ControlLabel("Reply & \(ThreadStatusButton.title(thread))") }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help(thread.isResolved
                        ? "Reply, then reactivate the thread, in Azure DevOps, as you (⇧⌘Return)"
                        : "Reply, then resolve the thread, in Azure DevOps, as you (⇧⌘Return)")
                    .disabled(!canSend)
                Button { send(then: nil) } label: { ControlLabel("Reply") }
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
        let problem: ADOWriteProblem? = if case .failed(let problem, let sending)? = state, isOwn(sending) { problem } else { nil }
        VStack(alignment: .leading, spacing: 3) {
            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    note(problem.sentence(editing == nil ? .reply : .editComment), symbol: "exclamationmark.triangle.fill", isWarning: true)
                    if problem == .signedOut || problem == .otherAccount, !isDemo {
                        Button("Sign In…") { store.signIn() }
                            .buttonStyle(.borderless)
                            .font(size: 11, weight: .medium)
                            .fixedSize()
                            .help("Sign in to the Azure CLI, in Terminal: what you wrote stays here")
                    }
                }
            } else if isDemo {
                note("Markdown. The demo changes only its made-up pull requests: nothing goes to Azure DevOps.", symbol: "info.circle")
            } else {
                note(editing == nil ? "Markdown. ⌘Return replies in Azure DevOps, as you." : "Markdown. ⌘Return saves it in Azure DevOps, as you.",
                     symbol: "info.circle")
            }
            if settings.grammarModel != StorySummaries.appleIntelligenceModel {
                note(
                    "Fix Grammar uses \(modelName(settings.grammarModel)): each fix is one premium request, and sends your \(noun) to "
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
            close()
        }
    }

    /// Saves your comment as you edited it, its names as the mentions they showed as you began; in place of what it says now,
    /// once you chose Save Anyway, only while it says what it did then.
    private func save(replacing chosen: String? = nil) {
        guard canSend, let editing, let editBase else {
            NSSound.beep()
            return
        }
        let markdown = text, replacing = chosen ?? replacing
        hold(thread)
        changes.dismiss(key)
        Task {
            guard await changes.edit(markdown, from: editBase, replacing: replacing, of: editing.comment, in: thread.thread, of: item.key)
            else { return }
            close()
        }
    }

    /// Your edit begun again from what the comment says now, as it changed since you began: what you wrote goes, and so does
    /// what Fix Grammar suggested for it.
    private func startOver() {
        guard let editing else { return }
        fixing?.cancel()
        fixing = nil
        suggestion = nil
        undo = nil
        grammarProblem = nil
        replacing = nil
        let started = changes.startOver(editing.comment, in: thread.thread, of: editing.pullRequest)
        editBase = started.base
        text = started.text
        isFocused = true
        SpokenText.announce("Started over from what your comment says now")
    }

    /// Closes your edit: your comment stays as it was, and what you wrote goes, with what went wrong with it.
    private func cancel() {
        fixing?.cancel()
        fixing = nil
        if let commentKey, preview == nil {
            changes.forgetEdit(commentKey)
            if case .failed(_, let sending)? = changes.state(of: key), isOwn(sending) { changes.dismiss(key) }
        }
        close()
    }

    /// Closes it, keeping what you wrote, and the keyboard's focus goes back to Reply, or the comment's ⋯.
    private func closeKeepingFocus() {
        fixing?.cancel()
        fixing = nil
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
                .help("Stop Fix Grammar: your \(noun) stays as it is")
            }
        } else {
            SplitMenuButton(
                "Fix Grammar", systemImage: "text.badge.checkmark", help: grammarHelp,
                hint: "Its menu chooses the model: Apple Intelligence on this Mac, or one through Copilot.",
                entries: GrammarModelMenuItems.entries(model: settings.grammarModel, models: models, canRunOnDevice: canRunOnDevice) { model in
                    settings.grammarModel = model
                    grammarProblem = nil
                }
            ) {
                fixGrammar()
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(isBlank || isSending)
        }
    }

    private var grammarHelp: String {
        let model = settings.grammarModel
        let does = "Correct the spelling, grammar and punctuation of your \(noun), keeping your words, code, links and mentions"
        if model == StorySummaries.appleIntelligenceModel { return does + ", with Apple Intelligence, on this Mac. Its menu chooses another model." }
        return does + ", with \(modelName(model)) through GitHub Copilot: one premium request, which sends your \(noun) to GitHub Copilot. Its menu chooses another model."
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
                    Menu {
                        GrammarModelMenuItems(model: settings.grammarModel, models: models, canRunOnDevice: canRunOnDevice) { model in
                            settings.grammarModel = model
                            grammarProblem = nil
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("Choose a Model")
                            MenuChevron()
                        }
                        .font(size: 13, weight: .medium)
                        .contentShape(Rectangle())
                    }
                    .labelMenuStyle()
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
/// leaving it; or one through Copilot, one premium request each time, which gets your reply's text. In Choose a Model's
/// menu, and, as `entries`, Fix Grammar's.
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

    /// The same, for Fix Grammar's own menu (`SplitMenuButton`).
    static func entries(
        model: String, models: [StorySummaries.Model], canRunOnDevice: Bool, choose: @escaping (String) -> Void
    ) -> [SplitMenuButton.Entry] {
        let onDevice = models.filter { $0.id == StorySummaries.appleIntelligenceModel }
        let throughCopilot = models.filter { $0.id != StorySummaries.appleIntelligenceModel }
        return [.header("On this Mac: free, and nothing leaves it")]
            + onDevice.map { choice in
                .item(StorySummariesSetting.choiceTitle(choice, canRunOnDevice: canRunOnDevice), isChecked: choice.id == model) {
                    choose(choice.id)
                }
            }
            + [.header("Through Copilot: one premium request each, which gets your reply")]
            + throughCopilot.map { choice in
                .item(StorySummariesSetting.choiceTitle(choice), isChecked: choice.id == model) { choose(choice.id) }
            }
    }
}

/// Fix Grammar's suggestion, under your reply: the reply corrected, what it changes marked, to use or not. Nothing changes
/// in your reply until you use it, and nothing is sent until you reply.
struct GrammarSuggestionView: View {
    let suggestion: GrammarSuggestion
    /// The model's name: "Apple Intelligence".
    let model: String
    /// It's in your edit of a comment, rather than your reply.
    var isEdit = false
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
                    Button(action: use) { ControlLabel("Use It") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Put the correction in your \(isEdit ? "comment" : "reply"): Undo puts back what you wrote")
                    Text(isEdit ? "Nothing changes until you save." : "Nothing goes until you reply.")
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
/// anything: a reply open, with your words, Fix Grammar's suggestion or Undo; a comment of yours as you edit it, delete it,
/// or with its menu open; and a change being sent, or that failed.
struct ThreadChangesPreview {
    struct Reply {
        var text: String
        var suggestion: GrammarSuggestion?
        var undo: GrammarSuggestion?
        var grammarProblem: GrammarFixer.Problem?
        /// Editing a comment that changed since: what it said as you began.
        var began: String?
    }

    /// The replies open, by thread.
    var replies: [Int: Reply] = [:]
    /// Your comments as you edit them, by thread and comment.
    var edits: [PreviewComment: Reply] = [:]
    /// A comment of yours you confirm you delete.
    var deleting: PreviewComment?
    /// A comment of yours with its ⋯ menu open.
    var menu: PreviewComment?
    /// What threads' changes are doing, or why they didn't happen, by thread.
    var states: [Int: ThreadChanges.State] = [:]
    /// Why its threads can't be changed, as for a pull request that left your lists: each shows a lock where Reply would be.
    var readOnly: String?
}

/// A comment in a thread, by their IDs, for `ThreadChangesPreview`.
struct PreviewComment: Hashable {
    var thread: Int
    var comment: Int
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
