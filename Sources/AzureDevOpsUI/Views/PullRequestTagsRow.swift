import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// A pull request's tags, under its heading in its details: capsules, as a work item's details show its own. With Make
/// Changes in Azure DevOps on, while it's open, ✕ on each takes it off, with Undo after, and Add Tag opens a field that adds
/// one, with suggestions as you type: ↑ and ↓ choose one, Tab completes it, Return adds it, or what you typed, and Esc closes
/// the field. The field is the details' one composer in place (`CopilotComposing.tags`). What went wrong shows under them, in
/// a sentence. Nothing shows while the pull request has none and they can't be changed, nor while they're unknown, as for one
/// sent to you until they're read.
struct PullRequestTagsRow: View {
    let item: PRSnapshot
    /// The pull request as its details show it, which keep it as it was once it left your lists, but for its tags
    /// (`PullRequestDetailsStore.followTags`).
    let record: PRRecord?
    @Binding var composing: CopilotComposing?

    @EnvironmentObject private var changes: TagChanges
    @EnvironmentObject private var store: PRStore
    @Environment(\.tagsPreview) private var preview
    @Environment(\.textScale) private var textScale
    @Environment(\.detailsScroll) private var scroll
    @Environment(\.isRendering) private var isRendering

    /// What you typed in the field.
    @LocalState private var typed = ""
    /// The row of the suggestions that ↑ and ↓ chose, which Tab completes and Return adds: the best match as you type; nil
    /// while nothing's typed and you chose none.
    @LocalState private var highlighted: Int?
    /// What VoiceOver last heard was chosen: a suggestion, or what you typed, as a new tag, which it doesn't hear again as it
    /// grows.
    @LocalState private var announced: TagChoices.Choice?
    /// Add Tag takes the keyboard's focus back as the field closes, and once the tag whose ✕ had it is taken off.
    @LocalState private var refocusesAdd = false
    @FocusState private var focus: Focus?

    /// What has the keyboard's focus in the tags.
    private enum Focus: Hashable {
        case field, add
        case remove(String)
    }

    private var key: PRKey { item.key }
    private var state: TagChanges.State? { preview?.state ?? changes.state(of: key) }
    private var removed: PullRequestTag? { preview?.removed ?? changes.undoable(on: key, tags: record?.tags) }
    private var canChange: Bool { preview?.canChange ?? changes.canChange(record) }
    private var isOpen: Bool { composing == .tags && canChange }

    /// The change being sent, while one is.
    private var sending: TagChanges.Change? {
        if case .sending(let change)? = state { change } else { nil }
    }

    /// The change that didn't happen, or may not have, and why, until it's dismissed or another goes.
    private var failure: (problem: ADOWriteProblem, change: TagChanges.Change)? {
        if case .failed(let problem, let change)? = state { (problem, change) } else { nil }
    }

    var body: some View {
        if let tags = record?.tags, !tags.isEmpty || canChange || failure != nil {
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    Image(systemName: "tag")
                        .font(size: 10.5, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(height: chipHeight)
                        .help(readOnlyReason.map { "Tags: \($0)" } ?? "Tags")
                        .accessibilityHidden(true)
                    ForEach(tags, id: \.key) { tag in
                        capsule(tag)
                    }
                    if canChange {
                        if isOpen {
                            field
                        } else {
                            addButton
                        }
                    }
                }
                if isOpen {
                    suggestions
                }
                if let failure {
                    // Also once they can't be changed, as when the pull request left your lists as you clicked: but with
                    // nothing to try again.
                    ThreadChangeProblemLine(
                        problem: failure.problem, kind: failure.change.kind,
                        retry: canChange ? retry(failure.problem, failure.change) : nil, signIn: signIn(failure.problem)
                    ) {
                        changes.dismiss(key)
                    }
                } else if let removed, canChange, sending == nil {
                    removedLine(removed)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tags.isEmpty ? "Tags: none" : "Tags")
            .accessibilityHint(readOnlyReason ?? "")
            // Some room under the suggestions, which scrolling to them keeps above what's at the details' foot.
            .padding(.bottom, isOpen ? 8 : 0)
            .id(Self.scrollID)
            .onAppear {
                guard let preview, let typed = preview.typed else { return }
                composing = .tags
                self.typed = typed
                highlighted = preview.highlighted
            }
            // The field and its suggestions in view as they show, however far down the details are scrolled, and above
            // what's at their foot, such as the fixes ready to push: in `--render`'s pictures too.
            .onChange(of: isOpen, initial: true) { _, open in if open { scrollIntoView() } }
            .onChange(of: isOpen ? choices.rows.count : nil) { _, count in if count != nil { scrollIntoView() } }
            // Turned off, or the pull request closed, while the field was open: it closes.
            .onChange(of: canChange) { _, can in
                if !can, composing == .tags { composing = nil }
            }
        }
    }

    /// As tall as a capsule, at the text size on windows' pages.
    private var chipHeight: CGFloat { 18 * textScale }

    /// The tags, for the details to scroll to as the field opens: one pull request's show at a time.
    static let scrollID = "pull-request-tags"

    /// All of them in view, the field and its suggestions with them, once they're laid out.
    private func scrollIntoView() {
        guard let scroll else { return }
        let isRendering = isRendering
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(isRendering ? 200 : 80))
            withAnimation(isRendering ? nil : .easeOut(duration: 0.2)) { scroll.scrollTo(Self.scrollID) }
        }
    }

    /// Why the tags can't be changed here, when they can't: for their glyph's tooltip, and VoiceOver.
    private var readOnlyReason: String? {
        guard !canChange, let record else { return nil }
        // As the list has it now, while it has it: its details keep one that left your lists as it was.
        let listed = store.record(for: key)
        if (listed ?? record).pullRequest.status != .active {
            return "Azure DevOps takes no change to a completed or abandoned pull request."
        }
        if listed == nil { return "This pull request is no longer in your lists, so its tags can't be changed here." }
        if !changes.settings.makesChanges {
            return "Turn on Make Changes in Azure DevOps, in Settings › Pull Requests, to add and remove them here."
        }
        return nil
    }

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
                            // As tall as the capsule, for a target bigger than the glyph.
                            .frame(width: 15 * textScale, height: chipHeight)
                            .contentShape(Rectangle())
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
        .padding(.trailing, canChange ? 2 : 7)
        .frame(height: chipHeight)
        .background(Capsule().fill(Color.secondary.opacity(0.14)))
        .opacity(isRemoving ? 0.55 : 1)
        .help(tag.name)
        .accessibilityElement(children: .contain)
    }

    /// Add Tag, after the tags: it opens the field.
    private var addButton: some View {
        Button(action: open) {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(size: 9, weight: .bold)
                Text("Add Tag")
                    .font(size: 10.5, weight: .semibold)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(minHeight: chipHeight)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.secondary)
        .focused($focus, equals: .add)
        .disabled(sending != nil)
        .help(store.mode == .demo
            ? "Add a tag to this made-up pull request"
            : "Add a tag to this pull request in Azure DevOps, as you")
        .accessibilityLabel("Add a Tag")
        .accessibilityHint("Opens a field with suggestions as you type.")
        .onAppear {
            guard refocusesAdd else { return }
            refocusesAdd = false
            Task { @MainActor in focus = .add }
        }
    }

    // MARK: The field

    /// What you type a tag's name in, with ✕, which Esc presses: Tab completes the suggestion ↑ and ↓ chose, without sending
    /// anything, and Return adds it, or what you typed. While it's being added, a spinner.
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
                .onKeyPress(.return) { addChosen() }
                .onKeyPress(.tab, phases: .down) { press in
                    press.modifiers.contains(.shift) ? .ignored : completeChosen()
                }
                .accessibilityLabel("New Tag")
                .accessibilityHint(
                    "Suggestions follow as you type. Up and down arrows choose one, Tab completes it, and Return adds it. Escape closes."
                )
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
            // Each time it opens, VoiceOver hears what's chosen anew, a new tag too, whatever it heard as it was open last.
            announced = nil
            guard preview == nil else { return }
            Task { @MainActor in focus = .field }
        }
        .onChange(of: choices) { old, new in
            // As you type, the best match is chosen; as the tags are read again while you don't, the same one, while it's
            // offered; and nothing for a tag the pull request has, so Return doesn't add another (`TagChoices.chosen`).
            // VoiceOver hears which as it changes, and when the pull request has the tag typed.
            highlighted = new.chosen(highlighted, before: old)
            if let already = new.alreadyOn, already != old.alreadyOn, preview == nil {
                announced = nil
                SpokenText.announce("It has the tag \(already) already")
            } else {
                announceChosen(new)
            }
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
                ? "Tab completes it, and Return adds it to this made-up pull request: nothing goes to Azure DevOps. Esc closes."
                : "Tab completes it, and Return adds it in Azure DevOps, as you. Esc closes.")
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

    /// ↑ or ↓: the next row. With something typed, one is always chosen, what you typed as a new tag among them; with
    /// nothing typed, or a tag the pull request has, up from the first chooses none.
    private func move(by step: Int) {
        let choices = choices
        let rows = choices.rows
        guard !rows.isEmpty else { return }
        let lowest = PullRequestTag.name(typed) == nil || choices.alreadyOn != nil ? -1 : 0
        let next = min(max((highlighted ?? -1) + step, lowest), rows.count - 1)
        highlighted = next < 0 ? nil : next
        announceChosen(choices, always: true)
    }

    /// Says which row is chosen, and how many there are, for VoiceOver: what Return would add. As you type, only as another
    /// suggestion is chosen, or as what's chosen goes from a suggestion to what you typed, as a new tag, or back: not as a
    /// new tag grows, key by key. ↑ and ↓ say it each time (`always`).
    private func announceChosen(_ choices: TagChoices, always: Bool = false) {
        guard preview == nil else { return }
        let chosen = choices.choice(at: highlighted)
        guard always || chosen != announced else { return }
        announced = chosen
        guard let chosen, let highlighted else {
            if always { SpokenText.announce("No tag chosen") }
            return
        }
        let rows = choices.rows
        let count = rows.count == 1 ? "1 choice" : "\(rows.count) choices"
        SpokenText.announce("\(rows[highlighted]), \(chosen == .newTag ? "new tag" : "suggested"). \(count)")
    }

    /// Tab: what you typed, completed to the suggestion chosen, without sending anything. With nothing to complete, Tab
    /// moves on, as it does anywhere.
    private func completeChosen() -> KeyPress.Result {
        let choices = choices
        guard let highlighted, choices.suggestions.indices.contains(highlighted) else { return .ignored }
        let name = choices.suggestions[highlighted]
        guard typed != name else { return .ignored }
        typed = name
        return .handled
    }

    /// Return: adds the row chosen, or what you typed; with neither, it beeps.
    private func addChosen() -> KeyPress.Result {
        let rows = choices.rows
        if let highlighted, rows.indices.contains(highlighted) {
            add(rows[highlighted])
        } else if let name = PullRequestTag.name(typed) {
            add(name)
        } else {
            NSSound.beep()
        }
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

    /// Takes a tag off. The keyboard's focus, when its ✕ had it, goes to the next tag's ✕, while it's there, or else to Add
    /// Tag, or to the field while it's open, in Add Tag's place.
    private func remove(_ tag: PullRequestTag) {
        guard preview == nil else { return }
        let hadFocus = focus == .remove(tag.key)
        var following: PullRequestTag?
        if let tags = record?.tags, let index = tags.firstIndex(where: { $0.key == tag.key }) {
            following = tags.dropFirst(index + 1).first ?? tags.prefix(index).last
        }
        changes.dismiss(key)
        Task {
            await changes.remove(tag, from: key)
            let left = store.record(for: key)?.tags
            guard hadFocus, left?.contains(where: { $0.key == tag.key }) != true else { return }
            if let following, left?.contains(where: { $0.key == following.key }) == true {
                focus = .remove(following.key)
            } else {
                focus = composing == .tags ? .field : .add
            }
        }
    }

    /// What tries a change that didn't happen again: only when trying again may help, not when Azure DevOps refused it, nor
    /// for a pull request or a tag that isn't there.
    private func retry(_ problem: ADOWriteProblem, _ change: TagChanges.Change) -> (title: String, action: () -> Void)? {
        switch problem {
        case .notAllowed, .closed, .gone, .refused, .notListed: return nil
        default: break
        }
        guard preview == nil else { return ("Try Again", {}) }
        return ("Try Again", { Task { await changes.retry(change, on: key) } })
    }

    /// The tag you just took off, with Undo, which adds it back, and ✕.
    private func removedLine(_ tag: PullRequestTag) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Removed the tag \(tag.name).")
                .font(size: 11.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo") {
                guard preview == nil else { return }
                Task { await changes.undoRemoval(on: key) }
            }
            .buttonStyle(.borderless)
            .font(size: 11.5, weight: .medium)
            .fixedSize()
            .help(store.mode == .demo ? "Add the tag back" : "Add the tag back in Azure DevOps, as you")
            .accessibilityLabel("Undo: Add the Tag \(tag.name) Back")
            CopilotDismissButton { changes.dismissRemoval(on: key) }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .contain)
    }

    private func signIn(_ problem: ADOWriteProblem) -> (() -> Void)? {
        guard problem == .signedOut || problem == .otherAccount, store.mode == .live else { return nil }
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
    /// The tag just taken off, which Undo adds back.
    var removed: PullRequestTag?
    /// Whether they show Add Tag and ✕; nil for as Make Changes in Azure DevOps says.
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
