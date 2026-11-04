import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// A pull request's tags, under its heading in its details: capsules, as a work item's details show its own. With Make
/// Changes in Azure DevOps on, while it's open, ✕ on each takes it off, and + opens a field that adds one, with suggestions as
/// you type: ↑ and ↓ choose one, Return or Tab adds it, or what you typed, and Esc closes the field. The field is the details'
/// one composer in place (`CopilotComposing.tags`). What went wrong shows under them, in a sentence. Nothing shows while the
/// pull request has none and they can't be changed, nor while they're unknown, as for one sent to you until they're read.
struct PullRequestTagsRow: View {
    let item: PRSnapshot
    let record: PRRecord?
    @Binding var composing: CopilotComposing?

    @EnvironmentObject private var changes: TagChanges
    @EnvironmentObject private var store: PRStore
    @Environment(\.tagsPreview) private var preview
    @Environment(\.textScale) private var textScale

    /// What you typed in the field.
    @LocalState private var typed = ""
    /// The row of the suggestions that ↑ and ↓ chose, which Return and Tab add; nil for what you typed.
    @LocalState private var highlighted: Int?
    /// + takes the keyboard's focus back as the field closes, and once the tag whose ✕ had it is taken off.
    @LocalState private var refocusesAdd = false
    @FocusState private var focus: Focus?

    /// What has the keyboard's focus in the tags.
    private enum Focus: Hashable {
        case field, add
        case remove(String)
    }

    private var key: PRKey { item.key }
    private var state: TagChanges.State? { preview?.state ?? changes.state(of: key) }
    private var canChange: Bool { preview?.canChange ?? changes.canChange(record) }
    private var isOpen: Bool { composing == .tags && canChange }

    /// The change being sent, while one is.
    private var sending: TagChanges.Change? {
        if case .sending(let change)? = state { change } else { nil }
    }

    var body: some View {
        if let tags = record?.tags, !tags.isEmpty || canChange {
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    Image(systemName: "tag")
                        .font(size: 10.5, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(height: chipHeight)
                        .help("Tags")
                        .accessibilityHidden(true)
                    ForEach(tags, id: \.key) { tag in
                        capsule(tag)
                    }
                    if canChange {
                        if isOpen {
                            field
                        } else {
                            addButton(isFirst: tags.isEmpty)
                        }
                    }
                }
                if isOpen {
                    suggestions
                }
                if case .failed(let problem, let change)? = state, canChange {
                    ThreadChangeProblemLine(problem: problem, kind: change.kind, retry: retry(change), signIn: signIn(problem)) {
                        changes.dismiss(key)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tags.isEmpty ? "Tags: none" : "Tags")
            .onAppear {
                guard let preview, let typed = preview.typed else { return }
                composing = .tags
                self.typed = typed
                highlighted = preview.highlighted
            }
            // Turned off, or the pull request closed, while the field was open: it closes.
            .onChange(of: canChange) { _, can in
                if !can, composing == .tags { composing = nil }
            }
        }
    }

    /// As tall as a capsule, at the text size on windows' pages.
    private var chipHeight: CGFloat { 18 * textScale }

    // MARK: The tags

    /// A tag, with ✕ while you may take it off; while it's being taken off, a spinner in its place.
    private func capsule(_ tag: PullRequestTag) -> some View {
        let isRemoving = sending == .remove(tag)
        return HStack(spacing: 3) {
            Text(tag.name)
                .font(size: 10.5, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)
            if canChange {
                if isRemoving {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12 * textScale, height: 12 * textScale)
                        .accessibilityLabel("Removing the tag \(tag.name)")
                } else {
                    Button {
                        remove(tag)
                    } label: {
                        Image(systemName: "xmark")
                            .font(size: 7.5, weight: .bold)
                            .frame(width: 12 * textScale, height: 12 * textScale)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.borderless)
                    .focused($focus, equals: .remove(tag.key))
                    .disabled(sending != nil)
                    .help("Remove the tag \(tag.name) in Azure DevOps, as you")
                    .accessibilityLabel("Remove the tag \(tag.name)")
                }
            }
        }
        .foregroundStyle(Color.secondary)
        .padding(.leading, 7)
        .padding(.trailing, canChange ? 4 : 7)
        .frame(height: chipHeight)
        .background(Capsule().fill(Color.secondary.opacity(0.14)))
        .opacity(isRemoving ? 0.55 : 1)
        .help(tag.name)
        .accessibilityElement(children: .contain)
    }

    /// + after the tags, or "Add Tag" while there are none: it opens the field.
    private func addButton(isFirst: Bool) -> some View {
        Button(action: open) {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(size: 9, weight: .bold)
                if isFirst {
                    Text("Add Tag")
                        .font(size: 10.5, weight: .semibold)
                }
            }
            .padding(.horizontal, isFirst ? 7 : 5)
            .frame(minWidth: chipHeight, minHeight: chipHeight)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.secondary)
        .focused($focus, equals: .add)
        .disabled(sending != nil)
        .help(store.mode == .demo ? "Add a tag to this made-up pull request" : "Add a tag to this pull request in Azure DevOps, as you")
        .accessibilityLabel("Add a Tag")
        .onAppear {
            guard refocusesAdd else { return }
            refocusesAdd = false
            Task { @MainActor in focus = .add }
        }
    }

    // MARK: The field

    /// What you type a tag's name in, with ✕, which Esc presses: Return or Tab adds the suggestion ↑ and ↓ chose, or what you
    /// typed. While it's being added, a spinner.
    private var field: some View {
        let isAdding = if case .add? = sending { true } else { false }
        return HStack(spacing: 3) {
            TextField("Tag", text: $typed)
                .textFieldStyle(.plain)
                .font(size: 11)
                .frame(width: 130 * textScale)
                .focused($focus, equals: .field)
                .disabled(isAdding)
                .onKeyPress(.downArrow) {
                    move(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(by: -1)
                    return .handled
                }
                .onKeyPress(.return) { complete() }
                .onKeyPress(.tab, phases: .down) { press in
                    press.modifiers.contains(.shift) ? .ignored : complete(orMoveOn: true)
                }
                .accessibilityLabel("New Tag")
                .accessibilityHint("Suggestions follow as you type. Up and down arrows choose one; Return or Tab adds it, or what you typed. Escape closes.")
            if isAdding {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12 * textScale, height: 12 * textScale)
                    .accessibilityLabel("Adding the tag")
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(size: 7.5, weight: .bold)
                    .frame(width: 12 * textScale, height: 12 * textScale)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.secondary)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .accessibilityLabel("Close the Tag Field")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: chipHeight + 2)
        .background(Capsule().fill(Color(nsColor: .textBackgroundColor).opacity(0.8)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.2))
        // Esc closes it, not the details it's in.
        .preference(key: InlineComposerOpen.self, value: true)
        .onAppear {
            guard preview == nil else { return }
            Task { @MainActor in focus = .field }
        }
        .onChange(of: typed) {
            // What you typed chooses the best match; nothing typed, nothing chosen.
            highlighted = PullRequestTag.name(typed) == nil || choices.rows.isEmpty ? nil : 0
        }
    }

    /// The suggestions for what you typed, under the tags, the one ↑ and ↓ chose marked; then what you typed, as a new tag.
    private var suggestions: some View {
        let choices = choices
        let rows = choices.rows
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, name in
                let isNew = index >= choices.suggestions.count
                Button {
                    add(name)
                } label: {
                    suggestion(name, isNew: isNew, isHighlighted: index == highlighted)
                }
                .buttonStyle(.plain)
                .disabled(sending != nil)
                .accessibilityLabel(isNew ? "Add the new tag \(name)" : "Add the tag \(name)")
                .accessibilityAddTraits(index == highlighted ? .isSelected : [])
            }
            if let already = choices.alreadyOn {
                note("It has \(already) already.", symbol: "checkmark")
            } else if rows.isEmpty {
                note("Type a tag's name: an existing one, or a new one.", symbol: "keyboard")
            }
            Text(store.mode == .demo
                ? "Return or Tab adds it to this made-up pull request: nothing goes to Azure DevOps. Esc closes."
                : "Return or Tab adds it in Azure DevOps, as you. Esc closes.")
                .font(size: 10.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.top, rows.isEmpty && choices.alreadyOn == nil ? 0 : 3)
                .padding(.bottom, 1)
        }
        .padding(4)
        .frame(maxWidth: 300 * textScale, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested Tags")
    }

    /// A suggestion, what you typed in it in bold; or what you typed, as a new tag.
    private func suggestion(_ name: String, isNew: Bool, isHighlighted: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isNew ? "plus" : "tag")
                .font(size: 9.5, weight: .semibold)
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)
                .frame(width: 12 * textScale)
                .accessibilityHidden(true)
            Text(isNew ? AttributedString(name) : Self.marked(name, typed: typed))
                .font(size: 11.5)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if isNew {
                Text("New Tag")
                    .font(size: 10.5)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func note(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(size: 9.5)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(size: 11)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    /// A name, the first place what you typed is in it in bold, ignoring letter case.
    static func marked(_ name: String, typed: String) -> AttributedString {
        var text = AttributedString(name)
        guard let typed = PullRequestTag.name(typed),
              let range = name.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]),
              let marked = Range(range, in: text)
        else { return text }
        text[marked].inlinePresentationIntent = .stronglyEmphasized
        return text
    }

    /// What it offers for what you typed (`TagChoices`).
    private var choices: TagChoices {
        guard let record else { return TagChoices(typed: typed, used: [], seen: [], current: []) }
        return changes.choices(for: typed, on: record)
    }

    // MARK: Doing

    private func open() {
        changes.dismiss(key)
        typed = ""
        highlighted = nil
        composing = .tags
    }

    /// Closes the field, and the keyboard's focus goes back to +.
    private func close() {
        typed = ""
        highlighted = nil
        refocusesAdd = true
        if composing == .tags { composing = nil }
    }

    /// ↑ or ↓: the next suggestion, or, up from the first, what you typed.
    private func move(by step: Int) {
        let rows = choices.rows
        guard !rows.isEmpty else { return }
        let next: Int? = switch highlighted {
        case nil: step > 0 ? 0 : nil
        case let index?: index + step < 0 ? nil : min(index + step, rows.count - 1)
        }
        highlighted = next
        SpokenText.announce(next.map { rows[$0] } ?? (typed.isEmpty ? "Nothing typed" : typed))
    }

    /// Return or Tab: adds the suggestion chosen, or what you typed. With nothing typed or chosen, Tab moves on, as it does
    /// anywhere, and Return beeps.
    private func complete(orMoveOn movesOn: Bool = false) -> KeyPress.Result {
        let rows = choices.rows
        if let highlighted, rows.indices.contains(highlighted) {
            add(rows[highlighted])
            return .handled
        }
        if let name = PullRequestTag.name(typed) {
            add(name)
            return .handled
        }
        if movesOn { return .ignored }
        NSSound.beep()
        return .handled
    }

    /// Adds a tag; once it's added, the field is empty again, for another.
    private func add(_ name: String) {
        guard preview == nil else { return }
        guard !changes.isSending(key) else {
            NSSound.beep()
            return
        }
        changes.dismiss(key)
        Task {
            guard await changes.add(name, to: key) else { return }
            typed = ""
            highlighted = nil
            if composing == .tags { focus = .field }
        }
    }

    /// Takes a tag off. The keyboard's focus, when its ✕ had it, goes to the next tag's ✕, or else to +.
    private func remove(_ tag: PullRequestTag) {
        guard preview == nil else { return }
        let hadFocus = focus == .remove(tag.key)
        let following = record?.tags.flatMap { tags in
            tags.firstIndex { $0.key == tag.key }.map { index in tags.dropFirst(index + 1).first ?? tags.prefix(index).last }
        } ?? nil
        changes.dismiss(key)
        Task {
            await changes.remove(tag, from: key)
            guard hadFocus, record?.tags?.contains(where: { $0.key == tag.key }) != true else { return }
            focus = following.map { .remove($0.key) } ?? .add
        }
    }

    /// What tries a change that didn't happen again.
    private func retry(_ change: TagChanges.Change) -> (title: String, action: () -> Void)? {
        guard preview == nil else { return ("Try Again", {}) }
        return ("Try Again", { Task { await changes.retry(change, on: key) } })
    }

    private func signIn(_ problem: ADOWriteProblem) -> (() -> Void)? {
        guard problem == .signedOut, store.mode == .live else { return nil }
        return { store.signIn() }
    }
}

// MARK: - For --render

/// For `--render`: what a pull request's tags show, as you'd have them, to draw each state without sending anything: the
/// field open, with what you typed and the suggestion chosen; a change being sent, or that didn't happen; and whether they
/// can be changed.
struct TagsPreview {
    /// What you typed in the field, which is open; nil while it's closed.
    var typed: String?
    var highlighted: Int?
    var state: TagChanges.State?
    /// Whether they show + and ✕; nil for as Make Changes in Azure DevOps says.
    var canChange: Bool?
}

private struct TagsPreviewKey: EnvironmentKey {
    static var defaultValue: TagsPreview? { nil }
}

extension EnvironmentValues {
    var tagsPreview: TagsPreview? {
        get { self[TagsPreviewKey.self] }
        set { self[TagsPreviewKey.self] = newValue }
    }
}
