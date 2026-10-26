import BriefBarCore
import BriefBarUI
import SwiftUI

struct AppearancePage: View {
    @ObservedObject var services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance")
                .font(.title2.weight(.semibold))
            Text("Choose a simpler presentation, one option at a time. Every option starts off. Sources, permissions and saved layouts stay as they are.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
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
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
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
