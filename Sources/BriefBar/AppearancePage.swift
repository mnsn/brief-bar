import BriefBarCore
import BriefBarUI
import SwiftUI

struct AppearancePage: View {
    @ObservedObject var services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance")
                .font(style: .title2, weight: .semibold)
            Text("Choose a simpler presentation, one option at a time. Every option starts off, and text starts at its usual size. Sources, permissions and saved layouts stay as they are.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Section {
                    TextSizeSetting(services: services)
                }
                Section {
                    ForEach(InterfaceOption.allCases, id: \.self) { option in
                        Toggle(isOn: Binding(
                            get: { services.interfaceOptions[option] },
                            set: { services.setInterfaceOption(option, enabled: $0) }
                        )) {
                            Text(option.title)
                            Text(option.explanation)
                        }
                        .toggleStyle(.switch)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// How big text is on windows' pages, from its usual size up to half as big again.
private struct TextSizeSetting: View {
    @ObservedObject var services: AppServices

    var body: some View {
        let percent = services.textSize.percent
        LabeledContent {
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
        } label: {
            Text("Text Size in Windows") + Text("  \(percent)%").foregroundStyle(.secondary)
            Text("Bigger text on the pages of BriefBar's windows. The menu bar's lists and the widgets keep their size. In a window, hold ⌘ and scroll up or down to change it.")
        }
    }
}

private extension InterfaceOption {
    var title: String {
        switch self {
        case .compactBriefs: "Compact Briefs"
        case .quietAppearance: "Quieter Colors and Surfaces"
        case .readableRows: "Aligned, Easier-to-Read Rows"
        case .compactMenuBar: "Compact Menu Bar"
        case .clearerStates: "Clearer States and Counts"
        case .visibleActions: "Visible Row and Widget Actions"
        case .simpleLayoutControls: "Simple Layout Choices"
        }
    }

    var explanation: String {
        switch self {
        case .compactBriefs:
            "Show two highlights after the first group, with more on request. In chats, show the summary instead of repeating the message preview."
        case .quietAppearance:
            "Use neutral navigation, avatars and backgrounds. Keep color on important status symbols rather than whole lines of text."
        case .readableRows:
            "Align titles across sources and enlarge reasons and previews. Widgets grow slightly to keep complete rows."
        case .compactMenuBar:
            "Temporarily combine visible menu-bar sections into one icon and attention count, with a warning for failures or missing access. Turn off to restore your arrangement."
        case .clearerStates:
            "Separate Ready to Merge from Finished. Sidebar badges and list headers count attention; remaining sprint work is labeled separately."
        case .visibleActions:
            "Show row action menus and widget View All buttons. Keep each source's existing open/read behavior, without approving or completing work."
        case .simpleLayoutControls:
            "Start layout settings with Together, Separate and Custom choices. Custom keeps the full arrangement editor."
        }
    }
}
