import BriefBarCore
import BriefBarUI
import Combine
import SwiftUI

/// The Overview at the top of every list: it opens the window that has the Overview, at the Overview, and counts what
/// needs you on that window's pages, as the window's sidebar does. Lists leave it out while no window has one.
@MainActor
final class OverviewLink: ObservableObject {
    private unowned let model: AppModel
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
    }

    /// The window it opens: the first with several pages, which is the first with an Overview.
    var window: SectionLayout.Item? {
        WindowPages.overviewWindow(in: model.visibleItems(.windows))
    }

    /// How many things need you on that window's pages.
    var needsYou: Int {
        window.map { model.states(of: $0.sections).needsYou } ?? 0
    }

    /// Follows the sources of that window's pages, for the count: after the windows, or the sources that are on,
    /// changed.
    func update() {
        cancellables.removeAll()
        var seen = Set<SourceID>()
        for source in (window?.sections ?? []).compactMap(model.source(for:)) where seen.insert(source.id).inserted {
            source.segmentsChanged
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in MainActor.assumeIsolated { self?.objectWillChange.send() } }
                .store(in: &cancellables)
        }
        objectWillChange.send()
    }

    func open() {
        model.openOverview()
    }
}

/// The Overview's line at the top of a list: its symbol and name, how many things need you, and a ›, which opens
/// BriefBar's window at the Overview.
struct OverviewLinkView: View {
    @ObservedObject var link: OverviewLink

    @LocalState private var isHovered = false

    var body: some View {
        if link.window != nil {
            let needsYou = link.needsYou
            let count = needsYou > 0 ? "\(needsYou) \(ItemState.needsYou.countLabel)" : nil
            VStack(spacing: 0) {
                Button {
                    link.open()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: AppSymbols.app)
                            .font(size: 12, weight: .semibold)
                            .foregroundStyle(.tint)
                        Text("Overview")
                            .font(size: 12, weight: .semibold)
                        Spacer(minLength: 8)
                        if let count {
                            Text(count)
                                .font(size: 11).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(size: 10, weight: .bold)
                            .foregroundStyle(isHovered ? HierarchicalShapeStyle.secondary : .tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(isHovered ? 0.07 : 0))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help("Open the Overview in BriefBar's window: what every source has for you, by state")
                .accessibilityLabel("Overview")
                .accessibilityValue(count ?? "Nothing needs you")
                .accessibilityHint("Opens BriefBar's window at the Overview")
                Divider()
            }
        }
    }
}
