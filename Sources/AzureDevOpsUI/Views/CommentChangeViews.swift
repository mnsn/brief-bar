import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

// A comment of yours, with Make Changes in Azure DevOps on: what confirms you delete it, under what it says; and the Mac's own
// spell checking in what you write to people, your reply and your comment as you edit it. Edit and Delete are on the comment
// (`PullRequestCommentsSection`), and your edit is your reply's composer (`ThreadReplyComposer`).

// MARK: - Deleting your comment

/// What confirms you delete a comment of yours, under what it says: that Azure DevOps deletes it, as you, and that it can't be
/// undone, with Cancel, which Esc presses, and Delete, which waits while another change to its thread is on its way, as one
/// another window sent, since its thread takes one at a time. It's the details' one composer in place, so Esc closes it
/// rather than the details; VoiceOver goes to it, and hears it, as it opens.
struct CommentDeleteConfirmation: View {
    /// Another change to its thread is on its way.
    var isBusy = false
    let cancel: () -> Void
    let delete: () -> Void

    @Environment(\.isRendering) private var isRendering
    @AccessibilityFocusState private var isFocused: Bool

    static let question = "Delete this comment?"
    static let warning = "Azure DevOps deletes it, as you, and it can't be undone."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "trash")
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(ItemState.failing.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.question)
                        .font(size: 12, weight: .semibold)
                    Text(Self.warning)
                        .font(size: 11.5)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityFocused($isFocused)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(action: cancel) { ControlLabel("Cancel") }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .help("Keep your comment (Esc)")
                Button(role: .destructive, action: delete) { ControlLabel("Delete") }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isBusy)
                    .help(isBusy
                        ? "Another change to this thread is on its way: you can delete your comment once it's done"
                        : "Delete your comment in Azure DevOps, as you: it can't be undone")
            }
            .controlSize(.small)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ItemState.failing.color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ItemState.failing.color.opacity(0.25), lineWidth: 1))
        // Esc closes it, not the details it's in.
        .preference(key: InlineComposerOpen.self, value: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Delete Your Comment")
        .onAppear {
            guard !isRendering else { return }
            isFocused = true
            SpokenText.announce(Self.question + " " + Self.warning)
        }
    }
}

// MARK: - Your edit, of a comment that changed since

/// In your edit of a comment of yours that changed since you began, in Azure DevOps or another window, unseen, as your edit
/// hides what it says: that it did, and all of what it says now, which is what Save Anyway replaces, with Start Over (⌥⌘R),
/// which puts that in your edit in place of what you wrote, and Save Anyway (⌥⌘Return), which replaces it with your edit.
/// Save is dimmed then (`ThreadChanges.changedSince`).
struct CommentChangedNotice: View {
    /// The comment as it is now.
    let now: ReviewComment
    /// Your edit is on its way.
    let isSending: Bool
    /// Your edit can be saved now: it says something, and isn't on its way, nor being fixed.
    let canSave: Bool
    let startOver: () -> Void
    let saveAnyway: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(size: 11, weight: .semibold)
                    .foregroundStyle(ItemState.needsYou.color)
                    .accessibilityHidden(true)
                Text(ThreadChanges.changedSentence)
                    .font(size: 12, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("It says now:")
                    .font(size: 11)
                    .foregroundStyle(.secondary)
                // All of it: Save Anyway replaces all of it.
                CommentBody(markdown: now.markdown, isQuiet: false)
                    .equatable()
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.18)).frame(width: 2.5)
                    }
            }
            .accessibilityElement(children: .combine)
            Text(ThreadChanges.changedChoices)
                .font(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(action: startOver) { ControlLabel("Start Over") }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .help("Put what your comment says now in your edit, in place of what you wrote (⌥⌘R)")
                    .disabled(isSending)
                Button(action: saveAnyway) { ControlLabel("Save Anyway") }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .help("Replace what your comment says now with your edit, in Azure DevOps, as you (⌥⌘Return)")
                    .disabled(!canSave)
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ItemState.needsYou.color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ItemState.needsYou.color.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Comment Changed")
    }
}

// MARK: - For --render

/// For `--render`, which can't draw a menu, as macOS draws it in a window of its own: one open, as macOS draws it, with these
/// items, the first chosen. Its text is a menu's, whatever the size of the text on windows' pages, as a menu's is.
struct MenuPicture: View {
    let items: [String]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Text(item)
                    .font(size: 13)
                    .foregroundStyle(index == 0 ? Color.white : Color.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(index == 0 ? Color.accentColor : Color.clear))
            }
        }
        .padding(5)
        .frame(width: 140)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: colorScheme == .dark ? .underPageBackgroundColor : .windowBackgroundColor))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.22), radius: 10, y: 4)
        )
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .environment(\.textScale, 1)
        .fixedSize()
    }
}

// MARK: - Spell checking

extension View {
    /// The Mac's own spell checking as you type, in a `TextEditor`: it underlines what it doesn't know, in the system's
    /// languages, and the right-click menu suggests words. It corrects nothing by itself, though, nor makes quotes curly or
    /// dashes long, nor replaces text, which would change code, links and mentions as you type; and it leaves grammar to Fix
    /// Grammar. The editor, its focus, its size and its shortcuts are as they were.
    func spellChecked() -> some View {
        modifier(SpellChecked())
    }
}

/// Spell checking in a `TextEditor`, once `SpellCheckingProbe` found its text view, and keeps what corrects or substitutes text
/// off there: SwiftUI turns spell checking on only with autocorrection, which the probe turns off again. Until then, and if it
/// never finds it, nothing is checked, nor corrected, as you type.
private struct SpellChecked: ViewModifier {
    @LocalState private var isAttached = false

    func body(content: Content) -> some View {
        content
            .autocorrectionDisabled(!isAttached)
            .background(SpellCheckingProbe { isAttached = true })
    }
}

/// Behind a `TextEditor`, as big as it is: finds the editor's text view, the one there, and keeps off there what
/// `spellChecked()` leaves out (`kept`). SwiftUI turns autocorrection on again each time it updates the editor, as you type,
/// and the editor's right-click menu's Substitutions turn any of them on, which key-value observing tells at once; AppKit
/// gives the text view the system's settings of autocorrection, text replacement, smart quotes and dashes as they change,
/// without telling key-value observers, which `NSSpellChecker`'s notifications do (`systemSettingChanges`). Each time,
/// they're turned off again. Once it found the text view, it says so (`attached`); when it finds none in a moment, the log
/// says so, with nothing of what's written there.
struct SpellCheckingProbe: NSViewRepresentable {
    let attached: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.attached = attached
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.attached = attached
        view.find()
    }

    final class ProbeView: NSView {
        /// What corrects, replaces or substitutes text by itself, or checks its grammar: kept off.
        static let kept: [ReferenceWritableKeyPath<NSTextView, Bool>] = [
            \.isAutomaticSpellingCorrectionEnabled, \.isAutomaticTextReplacementEnabled, \.isAutomaticQuoteSubstitutionEnabled,
            \.isAutomaticDashSubstitutionEnabled, \.isGrammarCheckingEnabled,
        ]

        /// What AppKit posts as the system's settings change, after it gives each text view the new one.
        static let systemSettingChanges: [Notification.Name] = [
            NSSpellChecker.didChangeAutomaticSpellingCorrectionNotification, NSSpellChecker.didChangeAutomaticTextReplacementNotification,
            NSSpellChecker.didChangeAutomaticQuoteSubstitutionNotification, NSSpellChecker.didChangeAutomaticDashSubstitutionNotification,
        ]

        /// How long it looks for its editor's text view before the log says it found none.
        static let patience: Duration = .seconds(1)

        /// The editor's text view, once it found it.
        private(set) weak var textView: NSTextView?
        /// It looked for its editor's text view for a while, in a window, and found none.
        private(set) var foundNone = false
        var attached: (() -> Void)?
        private var observations: [NSKeyValueObservation] = []
        private var isLooking = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            find()
            awaitTextView()
        }

        override func layout() {
            super.layout()
            find()
        }

        /// It's behind the editor, and takes no click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The editor's text view, once SwiftUI has laid it out, and this view, behind it.
        func find() {
            guard textView == nil, window != nil else { return }
            Task { @MainActor [weak self] in self?.attach() }
        }

        /// The log says so when it finds no text view in a moment, in a window, once.
        private func awaitTextView() {
            guard window != nil, textView == nil, !isLooking, !foundNone else { return }
            isLooking = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.patience)
                guard let self else { return }
                isLooking = false
                guard window != nil, textView == nil else { return }
                foundNone = true
                Log.app.error("Spell checking found no text view behind an editor: it's off there, and substitutions follow the system")
            }
        }

        private func attach() {
            guard textView == nil, window != nil, bounds.width > 0, bounds.height > 0 else { return }
            let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var ancestor = superview
            while let view = ancestor {
                if let found = Self.textViews(in: view).first(where: { Self.frame(of: $0).contains(center) }) {
                    configure(found)
                    return
                }
                ancestor = view.superview
            }
        }

        private func configure(_ textView: NSTextView) {
            self.textView = textView
            textView.isContinuousSpellCheckingEnabled = true
            Self.keepOff(textView)
            observations = Self.kept.map { keyPath in
                textView.observe(keyPath) { textView, _ in
                    MainActor.assumeIsolated { Self.keepOff(textView) }
                }
            }
            for name in Self.systemSettingChanges {
                NotificationCenter.default.addObserver(self, selector: #selector(systemSettingChanged), name: name, object: nil)
            }
            attached?()
        }

        /// A system setting changed, which AppKit gives the text view as it posts this, unheard by key-value observing: once
        /// it has, it's turned off again.
        @objc private func systemSettingChanged(_ notification: Notification) {
            Task { @MainActor [weak self] in
                guard let textView = self?.textView else { return }
                Self.keepOff(textView)
            }
        }

        /// What corrects, replaces or substitutes text by itself, or checks its grammar, off: each only when it's on, so that
        /// turning one off again tells key-value observers nothing more.
        static func keepOff(_ textView: NSTextView) {
            for keyPath in kept where textView[keyPath: keyPath] {
                textView[keyPath: keyPath] = false
            }
        }

        /// Where a text view shows, in its window: its scroll view's frame, or its own.
        private static func frame(of textView: NSTextView) -> NSRect {
            let shown: NSView = textView.enclosingScrollView ?? textView
            return shown.convert(shown.bounds, to: nil)
        }

        private static func textViews(in view: NSView) -> [NSTextView] {
            var found: [NSTextView] = []
            if let textView = view as? NSTextView { found.append(textView) }
            for subview in view.subviews { found += textViews(in: subview) }
            return found
        }
    }
}

// MARK: - The keyboard's focus

/// What of yours on a thread takes the keyboard's focus back once a composer of yours on it closes as the one open, as its
/// control shows again or is still there: Reply after your reply, sent or closed (`ThreadReplyArea`), and once a comment you
/// deleted is done with, its ⋯ gone with it; a comment's ⋯ after your edit of it, saved or canceled, and after you kept it
/// rather than delete it. Nothing once another composer opened meanwhile, though it closed since: the keyboard's focus is
/// where you took it. In the thread's card alone (`ThreadCard`).
struct ThreadRefocus: Equatable {
    /// Reply takes it back (`ThreadReplyButtons`).
    var reply = false
    /// The comment whose ⋯ takes it back.
    var comment: Int?
    /// The comment of yours being deleted, since you confirmed it, while no composer opened: Reply takes it back once it's
    /// done with.
    var deleting: Int?

    /// `composer`, your edit of a comment on `thread`, or what confirms you delete it, closed as the one open: the comment's
    /// ⋯ takes it back. Nothing for another composer.
    mutating func closed(_ composer: CopilotComposing, on thread: Int) {
        guard let id = composer.comment(on: thread) else { return }
        self = ThreadRefocus(comment: id)
    }

    /// You confirmed you delete a comment of yours: it's being deleted.
    mutating func deleting(_ comment: Int) {
        self = ThreadRefocus(deleting: comment)
    }

    /// A comment of yours you deleted, deleted or not, is done with: Reply takes it back, once Reply is there again after it
    /// was being deleted, unless a composer opened since you confirmed it, which forgot it (`opened()`).
    mutating func deleted(_ comment: Int) {
        guard deleting == comment else { return }
        self = ThreadRefocus(reply: true)
    }

    /// A composer opened: what closed before doesn't take the keyboard's focus back as its control shows again.
    mutating func opened() {
        self = ThreadRefocus()
    }
}
