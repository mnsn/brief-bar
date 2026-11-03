import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI

// What asks Copilot about one thing in a pull request's details, in place: a status line that says what Copilot does about
// it, and a small composer under it. For a comment thread's Explain and Fix, and Fix All, now; built to serve a failed
// build and conflicts the same way.

/// What Copilot does about something, in a sentence, in its state's color, with since when: "Copilot is fixing this in
/// ‘Retry backoff’ · 2m". A click opens where it works, when something can; what's after it, such as ✕ to stop it, is the
/// caller's.
struct CopilotWorkLine<Trailing: View>: View {
    /// Its symbol, in its state's color.
    let symbol: String
    let text: String
    /// Its state, for its color: none for what's neither working, done, failing nor yours.
    let state: ItemState?
    /// Since when: how long it's worked, or how long ago it ended.
    let since: Date?
    let now: Date
    /// More, for its tooltip, such as what Copilot said when it ended.
    var detail: String?
    /// What a click does, and its tooltip.
    var open: (perform: () -> Void, help: String)?
    @ViewBuilder var trailing: () -> Trailing

    @LocalState private var isHovered = false

    private var color: Color { state?.textColor ?? .secondary }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let open {
                Button(action: open.perform) { label(opens: true) }
                    .buttonStyle(.plain)
                    .onHover { isHovered = $0 }
                    .help([detail, open.help].compactMap { $0 }.joined(separator: "\n"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken)
                    .accessibilityHint(open.help)
                    .accessibilityAddTraits(.isButton)
            } else {
                label(opens: false)
                    .help(detail ?? "")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken)
            }
            trailing()
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((state?.color ?? Color.primary).opacity(isHovered && open != nil ? 0.13 : 0.08))
        )
        .accessibilityElement(children: .contain)
    }

    private func label(opens: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(size: 11, weight: .semibold)
                .foregroundStyle(state?.color ?? .secondary)
                .frame(width: 14)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
            Text(text)
                .font(size: 11.5, weight: .medium)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let since {
                Text(Elapsed.short(since: since, now: now))
                    .font(size: 11, weight: .medium).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(since.formatted(date: .abbreviated, time: .shortened))
            }
            if opens {
                Image(systemName: "arrow.up.forward.app")
                    .font(size: 10.5, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// "Copilot is fixing this in ‘Retry backoff’, 2 minutes".
    private var spoken: String {
        guard let since else { return text }
        let ago = Elapsed.short(since: since, now: now)
        return ago.isEmpty ? text : "\(text), \(ago)"
    }
}

extension CopilotWorkLine where Trailing == EmptyView {
    init(
        symbol: String, text: String, state: ItemState?, since: Date?, now: Date, detail: String? = nil,
        open: (perform: () -> Void, help: String)? = nil
    ) {
        self.init(symbol: symbol, text: text, state: state, since: since, now: now, detail: detail, open: open) { EmptyView() }
    }
}

/// A small composer in place, under what it's about: a field for what you want in your words, where it goes, one ▾ away,
/// and the button that sends it, which Return does too, so a plain one takes two clicks. **Edit the Whole Prompt…** opens
/// the Send to Copilot window for everything else. ✕ or Esc closes it. What it sends, and how, is the caller's.
struct CopilotAskComposer<Destinations: View, Options: View>: View {
    let symbol: String
    /// "Explain", "Fix", "Fix All".
    let title: String
    /// What the field asks for: "What do you want to know?", "Tell Copilot how (optional)".
    let placeholder: String
    @Binding var text: String
    /// Where it goes, as ▾ says it: "In ‘Retry backoff’", "Ask ‘Retry backoff’".
    let destination: String
    var destinationHelp = "Choose where it goes"
    @ViewBuilder var destinations: () -> Destinations
    /// Ways to do it, under the field, such as applying a suggested change.
    @ViewBuilder var options: () -> Options
    /// What happens once it's sent, or why it can't be.
    let note: String?
    var noteIsWarning = false
    /// "Ask", "Fix", "Fix All".
    let sendTitle: String
    let canSend: Bool
    let isSending: Bool
    let send: () -> Void
    var editWholePrompt: (() -> Void)?
    let close: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.isRendering) private var isRendering

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .font(size: 11.5, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(size: 12.5, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(size: 10, weight: .semibold)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
                .accessibilityLabel("Close \(title)")
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(size: 12.5)
                .lineLimit(1...5)
                .focused($isFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(isFocused ? 0.6 : 0.2), lineWidth: isFocused ? 1.5 : 1)
                )
                .onSubmit { if canSend { send() } }
                .disabled(isSending)
                .accessibilityLabel(placeholder)
            options()
            // Where it goes, then the buttons: on one line while they fit, else the buttons under it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    destinationMenu
                    Spacer(minLength: 4)
                    buttons
                }
                VStack(alignment: .leading, spacing: 6) {
                    destinationMenu
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        buttons
                    }
                }
            }
            if let note {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: noteIsWarning ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(size: 10)
                        .accessibilityHidden(true)
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(size: 11)
                .foregroundStyle(noteIsWarning ? AnyShapeStyle(ItemState.needsYou.textColor) : AnyShapeStyle(.secondary))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
        // Esc closes it, not the details it's in.
        .preference(key: InlineComposerOpen.self, value: true)
        .onAppear { if !isRendering { isFocused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var destinationMenu: some View {
        ComposerCapsuleMenu(symbol: "arrow.turn.down.right", title: destination) { destinations() }
            .help(destinationHelp)
            .accessibilityLabel("Where It Goes")
            .accessibilityValue(destination)
            .disabled(isSending)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if let editWholePrompt {
                Button("Edit the Whole Prompt…", action: editWholePrompt)
                    .buttonStyle(.borderless)
                    .font(size: 11.5, weight: .medium)
                    .fixedSize()
                    .disabled(isSending)
                    .help("Open the Send to Copilot window, to change the whole prompt, the model or where it goes")
            }
            Button(action: send) {
                if isSending {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Sending…")
                    }
                } else {
                    Text(sendTitle)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
            .disabled(!canSend || isSending)
        }
    }
}

extension CopilotAskComposer where Options == EmptyView {
    init(
        symbol: String, title: String, placeholder: String, text: Binding<String>, destination: String, destinationHelp: String = "Choose where it goes",
        @ViewBuilder destinations: @escaping () -> Destinations, note: String?, noteIsWarning: Bool = false, sendTitle: String,
        canSend: Bool, isSending: Bool, send: @escaping () -> Void, editWholePrompt: (() -> Void)? = nil, close: @escaping () -> Void
    ) {
        self.init(
            symbol: symbol, title: title, placeholder: placeholder, text: text, destination: destination, destinationHelp: destinationHelp,
            destinations: destinations, options: { EmptyView() }, note: note, noteIsWarning: noteIsWarning, sendTitle: sendTitle,
            canSend: canSend, isSending: isSending, send: send, editWholePrompt: editWholePrompt, close: close
        )
    }
}

/// Whether a composer in place is open, which takes Esc from the details it's in: they close once it's closed.
struct InlineComposerOpen: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
