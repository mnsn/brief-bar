import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI

// A comment of yours, with Make Changes in Azure DevOps on: what confirms you delete it, under what it says; and the Mac's own
// spell checking in what you write to people, your reply and your comment as you edit it. Edit and Delete are on the comment
// (`PullRequestCommentsSection`), and your edit is your reply's composer (`ThreadReplyComposer`).

// MARK: - Deleting your comment

/// What confirms you delete a comment of yours, under what it says: that Azure DevOps deletes it, as you, and that it can't be
/// undone, with Cancel, which Esc presses, and Delete. It's the details' one composer in place, so Esc closes it rather than
/// the details; VoiceOver goes to it, and hears it, as it opens.
struct CommentDeleteConfirmation: View {
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
                    .help("Delete your comment in Azure DevOps, as you: it can't be undone")
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
        // SwiftUI turns spell checking on with autocorrection, which `SpellCheckingProbe` turns off again.
        autocorrectionDisabled(false)
            .background(SpellCheckingProbe())
    }
}

/// Behind a `TextEditor`, as big as it is: finds the editor's text view, the one there, and turns off what `spellChecked()`
/// leaves out. SwiftUI turns autocorrection on again each time it updates the editor, as you type, so it's turned off again,
/// at once, as it is (`NSKeyValueObservation`).
private struct SpellCheckingProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.find()
    }

    final class ProbeView: NSView {
        private weak var textView: NSTextView?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            find()
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
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isGrammarCheckingEnabled = false
            textView.isContinuousSpellCheckingEnabled = true
            observation = textView.observe(\.isAutomaticSpellingCorrectionEnabled) { textView, _ in
                MainActor.assumeIsolated {
                    if textView.isAutomaticSpellingCorrectionEnabled { textView.isAutomaticSpellingCorrectionEnabled = false }
                }
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
