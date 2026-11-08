import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI

// What asks Copilot about one thing in a pull request's details, in place: a status line that says what Copilot does about
// it, and a small composer under it. For a comment thread's Explain and Fix, and Fix All, now; built to serve a failed
// build and conflicts the same way.

/// What a line that says what Copilot does about something can do, from its ⋯ menu, its context menu and VoiceOver's
/// actions, as what it says allows (`CopilotTasksStore.canStop`, `canTryAgain`, `canClear`): stop what Copilot is at; send
/// a fix that failed or stopped again, with the same words; or let the line go, as Dismiss does for an answer.
struct CopilotLineActions {
    var stop: (() -> Void)?
    var tryAgain: (() -> Void)?
    var clear: (() -> Void)?

    var isEmpty: Bool { stop == nil && tryAgain == nil && clear == nil }

    /// "Stop, Try Again or Clear", for the menu's tooltip.
    var names: String {
        let names = [stop.map { _ in "Stop" }, tryAgain.map { _ in "Try Again" }, clear.map { _ in "Clear" }].compactMap { $0 }
        return names.count > 1 ? names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1] : names.first ?? ""
    }

    @ViewBuilder
    var items: some View {
        if let stop { Button("Stop", action: stop) }
        if let tryAgain { Button("Try Again", action: tryAgain) }
        if let clear { Button("Clear", action: clear) }
    }
}

/// What Copilot does about something, in a sentence, in its state's color, with since when: "Copilot is fixing this in
/// ‘Retry backoff’ · 2m", and under it what it's at, such as the step it runs, or what Copilot said as it ended, such as why
/// it couldn't. A click opens where it works, when something can; ⋯ has what can be done about it (`actions`); what's after
/// it, such as Stop for a question, is the caller's.
struct CopilotWorkLine<Trailing: View>: View {
    /// Its symbol, in its state's color.
    let symbol: String
    let text: String
    /// Its state, for its color: none for what's neither working, done, failing nor yours.
    let state: ItemState?
    /// Since when: how long it's worked, or how long ago it ended.
    let since: Date?
    let now: Date
    /// What it's at, under it, on one line, such as the step it runs.
    var subtitle: String?
    /// More, under it, on up to three lines, and whole in its tooltip: what Copilot said when it ended, such as why it
    /// couldn't, with its bold and code as written.
    var detail: String?
    /// What a click does, and its tooltip.
    var open: (perform: () -> Void, help: String)?
    /// What its menu can do about it, as its state allows.
    var actions = CopilotLineActions()
    @ViewBuilder var trailing: () -> Trailing

    @LocalState private var isHovered = false
    @Environment(\.textScale) private var textScale

    private var color: Color { state?.textColor ?? .secondary }

    /// What it says under it: nothing blank.
    private var shownDetail: String? {
        guard let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else { return nil }
        return detail
    }

    /// Its sentence in full, which two lines may cut short, then the rest.
    private var help: String {
        [text, subtitle, detail, open?.help].compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let open {
                Button(action: open.perform) { label(opens: true) }
                    .buttonStyle(.plain)
                    .onHover { isHovered = $0 }
                    .help(help)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken)
                    .accessibilityHint(open.help)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityActions { actions.items }
            } else {
                label(opens: false)
                    .help(help)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken)
                    .accessibilityActions { actions.items }
            }
            trailing()
            if !actions.isEmpty {
                Menu {
                    actions.items
                } label: {
                    Image(systemName: "ellipsis")
                        .font(size: 11, weight: .semibold)
                        .frame(width: 18 * textScale, height: 18 * textScale)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(actions.names)
                .accessibilityLabel("Copilot's Work")
                .accessibilityHint(actions.names)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((state?.color ?? Color.primary).opacity(isHovered && open != nil ? 0.13 : 0.08))
        )
        .modifier(LineMenu(actions: actions))
        .accessibilityElement(children: .contain)
    }

    /// Its context menu, while it has something to do: one without would take the place of what it's in's.
    private struct LineMenu: ViewModifier {
        let actions: CopilotLineActions

        func body(content: Content) -> some View {
            if actions.isEmpty {
                content
            } else {
                content.contextMenu { actions.items }
            }
        }
    }

    private func label(opens: Bool) -> some View {
        // Read here, not in the alignment's closure, which runs apart from the view.
        let scale = textScale
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(size: 11, weight: .semibold)
                .foregroundStyle(state?.color ?? .secondary)
                .frame(width: 14 * scale)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 * scale }
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(size: 11.5, weight: .medium)
                    .foregroundStyle(color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let detail = shownDetail {
                    Text(SummaryMarkdown.joined(detail))
                        .font(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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

    /// "Copilot is fixing this in Retry backoff, for 2 minutes, Run PaymentsClientTests": the time in words, the names
    /// without their quotes, as VoiceOver says them, and the first line of what Copilot said.
    private var spoken: String {
        var parts = [SpokenText.unquoted(text)]
        if let since {
            let elapsed = Elapsed.spoken(since: since, now: now)
            parts.append(state == .running ? "for " + elapsed : elapsed + " ago")
        }
        if let subtitle { parts.append(subtitle) }
        if let said = CopilotTasksStore.firstLine(shownDetail) { parts.append(said) }
        return parts.joined(separator: ", ")
    }
}

/// Text as VoiceOver says it.
enum SpokenText {
    /// Without the quotes around the names it quotes, "‘Retry backoff’", which it would read out: an apostrophe in a name,
    /// "‘Sam’s fix’", stays.
    static func unquoted(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var isQuoting = false
        for (index, character) in characters.enumerated() {
            if character == "‘" {
                isQuoting = true
                continue
            }
            if character == "’", isQuoting, index + 1 == characters.count || !characters[index + 1].isLetter {
                isQuoting = false
                continue
            }
            result.append(character)
        }
        return result
    }
}

extension CopilotWorkLine where Trailing == EmptyView {
    init(
        symbol: String, text: String, state: ItemState?, since: Date?, now: Date, subtitle: String? = nil, detail: String? = nil,
        open: (perform: () -> Void, help: String)? = nil, actions: CopilotLineActions = CopilotLineActions()
    ) {
        self.init(
            symbol: symbol, text: text, state: state, since: since, now: now, subtitle: subtitle, detail: detail, open: open,
            actions: actions
        ) { EmptyView() }
    }
}

/// A small composer in place, under what it's about: a field for what you want in your words, where it goes, one ▾ away,
/// with **Edit the Whole Prompt…** last there, which opens the Send to Copilot window for everything else, and the button
/// that sends it, which Return does too, so a plain one takes two clicks. ✕ or Esc closes it. As it opens, the details
/// scroll to show it all. What it sends, and how, is the caller's.
struct CopilotAskComposer<Destinations: View, Options: View>: View {
    let symbol: String
    /// "Explain", "Fix", "Fix All".
    let title: String
    /// What the field asks for: "What do you want to know? (optional)", "Tell Copilot how (optional)".
    let placeholder: String
    @Binding var text: String
    /// Where it goes, as ▾ says it, "In ‘Retry backoff’", "Ask ‘Retry backoff’", and its symbol.
    let destination: String
    var destinationSymbol = "arrow.turn.down.right"
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
    /// In a box of its own; else in what it's about, such as a thread's card, under a hairline.
    var isFramed = true
    let close: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.isRendering) private var isRendering
    @Environment(\.detailsScroll) private var scroll
    @Environment(\.textScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isFramed {
                Divider()
                    .padding(.bottom, 2)
            }
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
                        .frame(width: 18 * textScale, height: 18 * textScale)
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
                // Return sends it, once it can go: until then, a beep, and the note under it says why.
                .onSubmit { if canSend, !isSending { send() } else { NSSound.beep() } }
                .disabled(isSending)
                .accessibilityLabel(placeholder)
            options()
            // Where it goes, then the button: on one line while they fit, else the button under it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    destinationMenu
                    Spacer(minLength: 4)
                    sendButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    destinationMenu
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        sendButton
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
        .padding(isFramed ? 10 : 0)
        .background {
            if isFramed { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.06)) }
        }
        .overlay {
            if isFramed {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
            }
        }
        // Esc closes it, not the details it's in.
        .preference(key: InlineComposerOpen.self, value: true)
        .id(inlineComposerID)
        .onAppear {
            guard !isRendering else { return }
            isFocused = true
            // All of it in view, once it's laid out, however far down it opened.
            guard let scroll else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(inlineComposerID) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var destinationMenu: some View {
        ComposerCapsuleMenu(symbol: destinationSymbol, title: destination) {
            destinations()
            if let editWholePrompt {
                Divider()
                Button("Edit the Whole Prompt…", action: editWholePrompt)
            }
        }
        .help(editWholePrompt == nil ? destinationHelp : destinationHelp + ", or edit the whole prompt, and the model, in the Send to Copilot window")
        .accessibilityLabel("Where It Goes")
        .accessibilityValue(destination)
        .disabled(isSending)
    }

    private var sendButton: some View {
        Button(action: send) {
            if isSending {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    ControlLabel("Sending…")
                }
            } else {
                ControlLabel(sendTitle)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize()
        .disabled(!canSend || isSending)
    }
}

/// The composer in place, for the details to scroll to as it opens: one is open at a time.
private let inlineComposerID = "copilot-ask-composer"

extension CopilotAskComposer where Options == EmptyView {
    init(
        symbol: String, title: String, placeholder: String, text: Binding<String>, destination: String,
        destinationSymbol: String = "arrow.turn.down.right", destinationHelp: String = "Choose where it goes",
        @ViewBuilder destinations: @escaping () -> Destinations, note: String?, noteIsWarning: Bool = false, sendTitle: String,
        canSend: Bool, isSending: Bool, send: @escaping () -> Void, editWholePrompt: (() -> Void)? = nil, isFramed: Bool = true,
        close: @escaping () -> Void
    ) {
        self.init(
            symbol: symbol, title: title, placeholder: placeholder, text: text, destination: destination,
            destinationSymbol: destinationSymbol, destinationHelp: destinationHelp, destinations: destinations, options: { EmptyView() },
            note: note, noteIsWarning: noteIsWarning, sendTitle: sendTitle, canSend: canSend, isSending: isSending, send: send,
            editWholePrompt: editWholePrompt, isFramed: isFramed, close: close
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

/// The details' scrolling, for what opens in them to scroll itself into view.
private struct DetailsScrollKey: EnvironmentKey {
    static var defaultValue: ScrollViewProxy? { nil }
}

extension EnvironmentValues {
    var detailsScroll: ScrollViewProxy? {
        get { self[DetailsScrollKey.self] }
        set { self[DetailsScrollKey.self] = newValue }
    }
}
