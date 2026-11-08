import SwiftUI

/// A mission's title as a field, for Rename…, as Finder renames: it takes the keyboard as it shows, holding the name, and
/// Return keeps what you typed, as clicking elsewhere does, while Escape doesn't. What keeping it does is its header's
/// (`MissionHeader`), which shows it while you rename.
package struct MissionNameField: View {
    @Binding private var draft: String
    private let keep: () -> Void
    private let cancel: () -> Void
    private let gone: () -> Void

    @FocusState private var isEditing: Bool
    @Environment(\.textScale) private var textScale

    /// - Parameters:
    ///   - keep: Return, or the field losing the keyboard: keeps what you typed.
    ///   - cancel: Escape: keeps nothing.
    ///   - gone: it left the window, such as when By Mission shows something else.
    package init(draft: Binding<String>, keep: @escaping () -> Void, cancel: @escaping () -> Void, gone: @escaping () -> Void) {
        _draft = draft
        self.keep = keep
        self.cancel = cancel
        self.gone = gone
    }

    package var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(size: 12, weight: .semibold)
            .focused($isEditing)
            .frame(minWidth: 140 * textScale, maxWidth: 320 * textScale)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor).opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
            .onSubmit(keep)
            .onExitCommand(perform: cancel)
            .onChange(of: isEditing) { _, editing in
                // Clicking elsewhere keeps it, as in Finder.
                if !editing { keep() }
            }
            .onAppear {
                Task { @MainActor in isEditing = true }
            }
            .onDisappear(perform: gone)
            .accessibilityLabel("Mission's Name")
            .accessibilityHint("Return keeps it, and Escape doesn't. An empty name gives it BriefBar's name again.")
    }
}
