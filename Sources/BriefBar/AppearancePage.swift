import BriefBarCore
import BriefBarUI
import SwiftUI

struct AppearancePage: View {
    @ObservedObject var services: AppServices

    var body: some View {
        Form {
            Section {
                SettingsPageHeader(.appearance)
            }
            Section {
                TextSizeSetting(services: services)
            }
            Section {
                ForEach(InterfaceOption.allCases, id: \.self) { option in
                    SettingToggle(option.title, caption: option.caption, info: option.explanation, isOn: Binding(
                        get: { services.interfaceOptions[option] },
                        set: { services.setInterfaceOption(option, enabled: $0) }
                    ))
                }
            } header: {
                Text("Simpler Presentation")
            } footer: {
                // The first three are those a new install starts with on (`NewInstall`), as `InterfaceOption` lists them.
                Text("A new install starts with the first three on, and an update keeps your choices. Sources, permissions and saved layouts stay as they are.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsForm()
    }
}

/// How big text is on windows' pages, from its usual size up to half as big again.
private struct TextSizeSetting: View {
    @ObservedObject var services: AppServices

    var body: some View {
        let percent = services.textSize.percent
        LabeledContent {
            HStack(spacing: 10) {
                SettingInfoButton(title: "Text Size in Windows", text: """
                    Bigger text on the pages of BriefBar's windows. The menu bar's lists and the widgets keep their size. In a \
                    window, hold ⌘ and scroll up or down to change it.
                    """)
                slider(percent)
            }
        } label: {
            let size = Text("  \(percent)%").foregroundStyle(.secondary)
            Text("Text Size in Windows\(size)")
            Text("Bigger text on the pages of BriefBar's windows; lists and widgets keep theirs.")
        }
    }

    private func slider(_ percent: Int) -> some View {
        Slider(
            value: Binding(
                get: { Double(percent) },
                set: { services.setTextSize(TextSize(percent: Int($0.rounded()))) }
            ),
            in: Double(TextSize.percentages.first ?? 100)...Double(TextSize.percentages.last ?? 100),
            step: 10
        ) {
            Text("Text Size in Windows")
        } minimumValueLabel: {
            Image(systemName: "textformat.size.smaller")
                .accessibilityLabel("Smaller")
        } maximumValueLabel: {
            Image(systemName: "textformat.size.larger")
                .accessibilityLabel("Bigger")
        }
        .labelsHidden()
        .accessibilityValue("\(percent) percent")
        .frame(width: 180)
    }
}

private extension InterfaceOption {
    var title: String {
        switch self {
        case .clearerStates: "Clearer States and Counts"
        case .readableRows: "Aligned, Easier-to-Read Rows"
        case .simpleLayoutControls: "Simple Layout Choices"
        case .compactBriefs: "Compact Briefs"
        case .quietAppearance: "Quieter Colors and Surfaces"
        case .compactMenuBar: "Compact Menu Bar"
        case .visibleActions: "Visible Row and Widget Actions"
        }
    }

    /// What it does for you, in a line.
    var caption: String {
        switch self {
        case .clearerStates: "Shows Ready to Merge apart from Finished, and counts only what needs you or failed."
        case .readableRows: "Lines up titles across sources, and makes reasons and previews larger."
        case .simpleLayoutControls: "Starts Menu Bar, Widgets and Windows with Together, Separate and Custom."
        case .compactBriefs: "Shortens the brief to two highlights, and shows a chat's summary in place of its preview."
        case .quietAppearance: "Keeps color for status symbols, with neutral navigation, avatars and backgrounds."
        case .compactMenuBar: "Shows one menu-bar icon that counts what needs you or failed, and keeps your arrangement."
        case .visibleActions: "Adds a ⋯ menu to each row, and View All to widgets."
        }
    }

    /// The rest, behind ⓘ.
    var explanation: String {
        switch self {
        case .clearerStates:
            """
            Separates Ready to Merge from Finished in the Overview. The window's sidebar badges, a list's tabs and its headers \
            count only what needs you or is failing, and the sprint's remaining work is labeled "left".
            """
        case .readableRows:
            """
            Aligns the titles of rows across sources, and makes their reasons and previews larger. Widgets grow a little to \
            keep their rows whole.
            """
        case .simpleLayoutControls:
            """
            Starts the Menu Bar, Widgets and Windows pages with three choices: Together puts every section in one, Separate \
            gives each its own, and Custom opens the full editor, to move or hide sections one at a time.
            """
        case .compactBriefs:
            """
            Moves the brief below the first group and shows two of its highlights, with Show All for the rest. A chat with a \
            summary shows it in place of the message preview it would repeat, without hiding its unread count or changing \
            whether previews show.
            """
        case .quietAppearance:
            """
            Uses neutral navigation, avatars and backgrounds, with less decorative color. Color stays on important status \
            symbols rather than on whole lines of text, so they keep their meaning.
            """
        case .compactMenuBar:
            """
            Combines the sections that show in the menu bar into one BriefBar icon, while it's on. Its count adds up what \
            needs you and what failed, and a warning flags failures or missing access; choose All Activity or a source from \
            its list. It never changes your saved items or shows hidden sections: turn it off, and your arrangement is back.
            """
        case .visibleActions:
            """
            Adds a ⋯ menu to each row, with its actions and where each one goes. Widgets get View All, or, for a section \
            you've hidden from windows, Show in a Window…, which opens its layout settings. Opening something still marks \
            it read or seen as its source always did, and nothing approves or completes work for you.
            """
        }
    }
}
