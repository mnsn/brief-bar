import AppKit
import BriefBarCore
import BriefBarUI
import Combine
import SwiftUI

/// A list by state: the things of several sections, from any source, together under Needs You, Something's Wrong,
/// Running and Done or Ready, each as its own section's list shows it, with its actions.
@MainActor
final class StateListModel: ObservableObject {
    @Published private(set) var groups: [StateListGroup] = []
    /// The few things worth reading first, each in a sentence, at the top.
    @Published private(set) var brief: [BriefLine] = []
    /// What keeps a section from showing what it should, as its source says it.
    @Published private(set) var problems: [String] = []
    /// The sections it shows: those whose things can be in a state, so not the sprint.
    private(set) var sections: [SectionID] = []
    /// While nothing shows it, it only notes that it needs to look again.
    var isShowing = false {
        didSet {
            if isShowing && needsRefresh { refresh() }
        }
    }

    private unowned let model: AppModel
    private var cancellables: Set<AnyCancellable> = []
    private var needsRefresh = true

    init(model: AppModel) {
        self.model = model
    }

    func update(sections: [SectionID]) {
        self.sections = sections.filter { model.info(for: $0)?.states.isEmpty == false }
        cancellables.removeAll()
        var seen = Set<SourceID>()
        for source in self.sections.compactMap(model.source(for:)) where seen.insert(source.id).inserted {
            source.stateRowsChanged
                .merge(with: source.segmentsChanged)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in MainActor.assumeIsolated { self?.changed() } }
                .store(in: &cancellables)
        }
        changed()
    }

    private func changed() {
        needsRefresh = true
        if isShowing { refresh() }
    }

    func refresh() {
        needsRefresh = false
        groups = StateList.groups(sections.flatMap { section in
            (model.source(for: section)?.stateRows(for: section) ?? []).map { StateListEntry(section: section, row: $0) }
        })
        // Worded on screen only: never while the list is closed.
        brief = Briefing.pick(sections.flatMap { model.source(for: $0)?.briefLines(for: $0) ?? [] })
        model.briefWriter.write(brief)
        var problems: [String] = []
        for section in sections {
            if let problem = model.source(for: section)?.segment(for: section).problem, !problems.contains(problem) {
                problems.append(problem)
            }
        }
        self.problems = problems
    }
}

struct StateListView: View {
    @ObservedObject var list: StateListModel
    let model: AppModel
    let width: CGFloat

    @LocalState private var contentHeight: CGFloat = 0

    private static let maxListHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .padding(8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .panelListHeight(contentHeight, max: Self.maxListHeight)
            Divider()
            footer
        }
        .panelFrame(width: width)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(list.problems, id: \.self) { problem in
                Button {
                    if let source = problemSource(problem) { model.openSettings(.source(source)) }
                } label: {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.multicolor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .help("Open its settings")
            }
            if !list.brief.isEmpty {
                BriefPanel(lines: list.brief, writer: model.briefWriter)
                    .padding(.bottom, 2)
            }
            if list.groups.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.green)
                    Text("Nothing needs you")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            ForEach(list.groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.state.title) (\(group.entries.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(group.state.color)
                        .padding(.horizontal, 8)
                    ForEach(group.entries) { entry in
                        HStack(alignment: .top, spacing: 0) {
                            mark(entry.section)
                            entry.row.view
                                .environment(\.shownSection, entry.section)
                        }
                    }
                }
            }
        }
    }

    /// Which source a row is from: its section's symbol, in its color.
    private func mark(_ section: SectionID) -> some View {
        let info = model.info(for: section)
        let name = model.source(for: section).map { source in
            source.sections.count > 1 ? "\(source.name): \(info?.title ?? "")" : source.name
        } ?? ""
        return Image(systemName: info?.symbol ?? "circle")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(info?.tint ?? .secondary)
            .frame(width: 14)
            .padding(.top, 12)
            .help(name)
            .accessibilityLabel(name)
    }

    /// The source a problem's sentence names.
    private func problemSource(_ problem: String) -> SourceID? {
        list.sections.first { model.source(for: $0)?.segment(for: $0).problem == problem }?.source
    }

    private var footer: some View {
        HStack {
            Spacer()
            Menu {
                SourceMenuItems(parts: model.sourceParts(of: list.sections))
                Divider()
                Button("Arrange the Menu Bar…") { model.openSettings(.layout(.menuBar)) }
                Divider()
                AppMenuItems(source: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// The brief across sources: a few lines, each opening its thing, worded by Apple Intelligence on this Mac when it can,
/// or else in BriefBar's own words, without ✨.
struct BriefPanel: View {
    let lines: [BriefLine]
    @ObservedObject var writer: BriefWriter

    private static let gradient = LinearGradient(
        colors: [Color(red: 0.98, green: 0.55, blue: 0.20), Color(red: 0.93, green: 0.30, blue: 0.55),
                 Color(red: 0.55, green: 0.35, blue: 0.95), Color(red: 0.25, green: 0.55, blue: 1.0)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        let texts = lines.map { writer.text(for: $0) }
        let isWritten = texts.contains { $0.isWritten }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                if isWritten {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Self.gradient)
                }
                Text("Brief")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(zip(lines, texts)), id: \.0.id) { line, text in
                Button {
                    line.open()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(line.state.color)
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                        Text(text.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to open it")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isWritten ? AnyShapeStyle(Self.gradient.opacity(0.09)) : AnyShapeStyle(Color.primary.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isWritten ? AnyShapeStyle(Self.gradient.opacity(0.35)) : AnyShapeStyle(Color.primary.opacity(0.1)), lineWidth: 1)
        )
        .padding(.horizontal, 4)
        .help(isWritten ? "Written on this Mac by Apple Intelligence" : "In BriefBar's own words")
    }
}

/// Each source's own menu items, in the menu of a list or a widget that shows several sections: right there for one
/// source, in a submenu each for several.
struct SourceMenuItems: View {
    let parts: [(section: SectionID, source: any BriefBarSource)]

    var body: some View {
        if parts.count == 1, let part = parts.first {
            part.source.widgetMenu(for: part.section)
        } else {
            ForEach(parts, id: \.section) { part in
                Menu(part.source.name) {
                    part.source.widgetMenu(for: part.section)
                }
            }
        }
    }
}
