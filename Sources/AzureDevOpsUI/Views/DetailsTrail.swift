import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The way to what the details show, in their header, as a trail of crumbs: "!4102 › 5160", "Bug 5110 › !4091 ›
/// Rounding.cs". Each but the last goes back to what it names; the last is where they are.
struct DetailsTrail: View {
    struct Crumb {
        var title: String
        var help: String
        /// Back to what it names; nil for the last, where the details are.
        var action: (() -> Void)?

        init(title: String, help: String, action: (() -> Void)? = nil) {
            self.title = title
            self.help = help
            self.action = action
        }
    }

    let crumbs: [Crumb]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(size: 8.5, weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if let action = crumb.action {
                    Button(action: action) {
                        Text(crumb.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(crumb.help)
                    .layoutPriority(index == 0 ? 1 : 0)
                } else {
                    Text(crumb.title)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(crumb.help)
                        .layoutPriority(1)
                }
            }
        }
        .font(size: 12, weight: .medium).monospacedDigit()
    }

    /// The last page's crumb, where the details are; or, while it's a pull request's page showing one of its files, its
    /// crumb going back to that pull request's details, and the file's.
    @MainActor
    static func lastPage(_ linked: LinkedItem, details: PullRequestDetailsStore, ref: ItemRef) -> [Crumb] {
        guard details.showsFile(of: ref), let file = details.file else {
            return [Crumb(title: ItemPageView.crumb(of: linked), help: linked.menuTitle)]
        }
        return [
            Crumb(title: ItemPageView.crumb(of: linked), help: "Back to \(linked.menuTitle)") {
                withAnimation(.easeOut(duration: 0.15)) { details.closeFile() }
            },
            Crumb(title: file.name, help: file.path),
        ]
    }
}

/// Draws `content` again whenever `object` changes: for what a view keeps in its own state but shows from, such as the
/// store of the pull request a page over the details shows, whose header says where the page is.
struct Observing<Object: ObservableObject, Content: View>: View {
    @ObservedObject var object: Object
    @ViewBuilder var content: () -> Content

    init(_ object: Object, @ViewBuilder content: @escaping () -> Content) {
        self.object = object
        self.content = content
    }

    var body: some View {
        content()
    }
}
