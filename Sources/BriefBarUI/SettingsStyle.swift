import AppKit
import BriefBarCore
import SwiftUI

// The Settings window's look, which every page and every source's settings share: a page is one grouped form, its header
// first, so that its text, its boxes and its buttons share the form's edges; a setting is a row with its name, one line
// on what it does for you, ⓘ for the rest, and its control on the right; and a setting that reads or sends more than its
// source's consent covered says what, as you turn it on, before it's on.

/// A page's symbol, as the window's sidebar shows a page's: white, on a tile of its color; or, with Quieter Colors and
/// Surfaces, the symbol alone.
package struct SymbolTile: View {
    let symbol: String
    let tint: Color
    let size: CGFloat
    let isSelected: Bool

    @Environment(\.interfaceOptions) private var options

    /// - Parameter isSelected: its page is the one that shows, which the symbol alone shows in the accent color.
    package init(symbol: String, tint: Color, size: CGFloat = 26, isSelected: Bool = false) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
        self.isSelected = isSelected
    }

    package var body: some View {
        Group {
            if options.quietAppearance {
                Image(systemName: symbol)
                    .font(size: size * 15 / 26, weight: .medium)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 7 / 26, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: size * 7 / 26, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
                    Image(systemName: symbol)
                        .font(size: size * 12 / 26, weight: .semibold)
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A Settings page's header, the first box of its form: its symbol on its tile, its name, and what it's for, in a line;
/// with what goes on its right, such as a source's state.
package struct SettingsPageHeader<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let trailing: Trailing

    package init(symbol: String, tint: Color, title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    package var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(style: .title2, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
    }
}

extension SettingsPageHeader where Trailing == EmptyView {
    package init(symbol: String, tint: Color, title: String, subtitle: String) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

extension View {
    /// A Settings page's form, or a source's settings in one: grouped, on the window's background, as tall as what it
    /// shows, which the page scrolls.
    package func settingsForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.inSettingsForm, true)
    }
}

// MARK: - A setting

/// A setting's row: its name, and what it does for you in a line under it; ⓘ, with the rest, when there's more to say; and
/// its control on the right.
package struct SettingRow<Control: View>: View {
    let title: String
    let caption: String?
    let info: String?
    let keepsControlBeside: Bool
    let control: Control

    /// - Parameters:
    ///   - caption: what it does for you, in a line of about 90 characters at most.
    ///   - info: the rest, behind ⓘ.
    ///   - keepsControlBeside: whether its control stays beside its name however wide it is, the caption wrapping to
    ///     make room, where a form would put a wide one under it: for rows that should look alike, and for rows outside
    ///     a form, as in a box that asks before a setting turns on.
    package init(
        _ title: String, caption: String?, info: String? = nil, keepsControlBeside: Bool = false,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.caption = caption
        self.info = info
        self.keepsControlBeside = keepsControlBeside
        self.control = control()
    }

    package var body: some View {
        if keepsControlBeside {
            ControlBesideLayout(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let caption {
                        Text(caption)
                            .font(style: .subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                controls
            }
        } else {
            LabeledContent {
                controls
            } label: {
                Text(title)
                if let caption {
                    Text(caption)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if let info {
                SettingInfoButton(title: title, text: info)
            }
            control
        }
    }
}

/// A row's label and its control as a form lays out a row whose control fits beside it: the control on the right, at its
/// own size, its text on the line of the label's name, and as far past the label's top as it's taller, which a form's row
/// lets it be; the label takes the rest of the width, wrapping in it.
private struct ControlBesideLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let control = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width + spacing + control.width
        let label = labelProposal(width: width, control: control)
        return CGSize(
            width: width,
            height: max(subviews[0].sizeThatFits(label).height, controlTop(subviews, label: label) + control.height)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let control = subviews[1].sizeThatFits(.unspecified)
        let label = labelProposal(width: bounds.width, control: control)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: label)
        subviews[1].place(
            at: CGPoint(x: bounds.maxX - control.width, y: bounds.minY + controlTop(subviews, label: label)),
            anchor: .topLeading, proposal: .unspecified
        )
    }

    private func labelProposal(width: CGFloat, control: CGSize) -> ProposedViewSize {
        ProposedViewSize(width: max(0, width - spacing - control.width), height: nil)
    }

    /// Where the control's top goes, below the label's: above it, for one taller than the label's first line.
    private func controlTop(_ subviews: Subviews, label: ProposedViewSize) -> CGFloat {
        subviews[0].dimensions(in: label)[.firstTextBaseline] - subviews[1].dimensions(in: .unspecified)[.firstTextBaseline]
    }
}

/// A switch, as a setting's row.
package struct SettingToggle: View {
    let title: String
    let caption: String?
    let info: String?
    @Binding var isOn: Bool

    package init(_ title: String, caption: String?, info: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        self.info = info
        _isOn = isOn
    }

    package var body: some View {
        SettingRow(title, caption: caption, info: info) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// ⓘ beside a setting: what it does, in full, in a popover.
package struct SettingInfoButton: View {
    let title: String
    let text: String

    @LocalState private var isShown = false

    package init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    package var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(style: .body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        // What a setting does is worth reading while it can't be changed, as while its source is off.
        .environment(\.isEnabled, true)
        .help("About \(title)")
        .accessibilityLabel("About \(title)")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            SettingInfo(title: title, text: text)
        }
    }
}

/// What ⓘ shows: the setting's name and all it says about it, scrolling when it's long.
package struct SettingInfo: View {
    let title: String
    let text: String

    package init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    /// Wider than a line, a paragraph this long would be taller than a popover had better be.
    private static let longText = 700

    package var body: some View {
        if text.count > Self.longText {
            ScrollView { content }
                .frame(width: 420, height: 440)
        } else {
            content
                .frame(width: 380)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(style: .headline)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Consent

/// What something reads, where it connects or sends what, and what it needs: a source's, before you turn it on; agents';
/// or a setting's, as you turn it on.
package struct DescriptionBox: View {
    package struct Entry {
        package var title: String
        package var symbol: String
        package var text: String

        package init(title: String, symbol: String, text: String) {
            self.title = title
            self.symbol = symbol
            self.text = text
        }
    }

    let entries: [Entry]
    let footer: AnyView?

    package init(entries: [Entry]) {
        self.entries = entries
        footer = nil
    }

    /// - Parameter footer: what to choose in the box, under what it says, such as the model that decides where it sends
    ///   what: as rows, as a form has them.
    package init<Footer: View>(entries: [Entry], @ViewBuilder footer: () -> Footer) {
        self.entries = entries
        self.footer = AnyView(footer())
    }

    package init(description: SourceDescription) {
        self.init(entries: [
            Entry(title: "What BriefBar reads", symbol: "doc.text.magnifyingglass", text: description.reads),
            Entry(title: "Network", symbol: "network", text: description.network),
            Entry(title: "What it needs", symbol: "lock.shield", text: description.needs),
        ])
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(entries.indices, id: \.self) { index in
                entry(entries[index])
            }
            if let footer {
                Divider()
                footer
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func entry(_ entry: Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(style: .headline)
                Text(entry.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A switch for a setting that reads or sends more than its source's consent covered: turned on, it first says what, in a
/// box under it, with Turn On and Cancel, and it's on only once you click Turn On. Turned off, it's off at once.
package struct ConsentToggle<Extra: View>: View {
    let title: String
    let caption: String?
    let info: String?
    let entries: [DescriptionBox.Entry]
    @Binding var isOn: Bool
    let extra: Extra

    @LocalState private var asking = false
    @Environment(\.consentShown) private var consentShown
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameters:
    ///   - entries: what it reads and sends, which the box says.
    ///   - extra: what to choose in the box too, such as the model that decides where it sends what.
    package init(
        _ title: String, caption: String?, info: String? = nil, entries: [DescriptionBox.Entry], isOn: Binding<Bool>,
        @ViewBuilder extra: () -> Extra
    ) {
        self.title = title
        self.caption = caption
        self.info = info
        self.entries = entries
        _isOn = isOn
        self.extra = extra()
    }

    package var body: some View {
        // Only while it can be changed: one that can't be meanwhile, as Summaries once Show Links is off, stops asking,
        // rather than read on over a Turn On and a Cancel that can't be clicked.
        let isAsking = isEnabled && !isOn && (asking || consentShown == title)
        SettingRow(title, caption: caption, info: info) {
            Toggle(title, isOn: Binding(get: { isOn || isAsking }, set: { on in
                if on {
                    if !isOn { asking = true }
                } else {
                    asking = false
                    isOn = false
                }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            // Shown on while it asks, but not yet on.
            .accessibilityValue(Text("Waiting for you to confirm"), isEnabled: isAsking)
        }
        .onChange(of: isEnabled) { _, isEnabled in
            if !isEnabled { asking = false }
        }
        if isAsking {
            ConsentBox(title: title, entries: entries, extra: extra) {
                isOn = true
                asking = false
            } cancel: {
                asking = false
            }
        }
    }
}

extension ConsentToggle where Extra == EmptyView {
    package init(_ title: String, caption: String?, info: String? = nil, entries: [DescriptionBox.Entry], isOn: Binding<Bool>) {
        self.init(title, caption: caption, info: info, entries: entries, isOn: isOn) { EmptyView() }
    }
}

private struct ConsentShownKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// For `--render`: the setting, by its name, whose box shows as if you had just turned it on.
    package var consentShown: String? {
        get { self[ConsentShownKey.self] }
        set { self[ConsentShownKey.self] = newValue }
    }
}

/// What a setting reads and sends, as you turn it on, with Turn On and Cancel.
package struct ConsentBox<Extra: View>: View {
    let title: String
    let entries: [DescriptionBox.Entry]
    let extra: Extra
    let turnOn: () -> Void
    let cancel: () -> Void

    package init(
        title: String, entries: [DescriptionBox.Entry], extra: Extra, turnOn: @escaping () -> Void, cancel: @escaping () -> Void
    ) {
        self.title = title
        self.entries = entries
        self.extra = extra
        self.turnOn = turnOn
        self.cancel = cancel
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if Extra.self == EmptyView.self {
                DescriptionBox(entries: entries)
            } else {
                DescriptionBox(entries: entries) { extra }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Turn On", action: turnOn)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Turn On \(title)")
            }
        }
        .padding(.vertical, 6)
    }
}
