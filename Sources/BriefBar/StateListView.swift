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
    /// Every thing in a state, each in a sentence, which the brief picks from.
    private(set) var lines: [BriefLine] = []
    /// What keeps a section from showing what it should, as its source says it.
    @Published private(set) var problems: [String] = []
    /// The sections it shows: those whose things can be in a state, so not the sprint.
    private(set) var sections: [SectionID] = []
    /// While nothing shows it, it only notes that it needs to look again, and the model isn't asked for its brief.
    var isShowing = false {
        didSet {
            guard isShowing != oldValue else { return }
            if !isShowing {
                if wordsBrief { model.briefWriter.stop(self) }
            } else if needsRefresh {
                refresh()
            } else if wordsBrief {
                model.briefWriter.write(brief, for: self)
            }
        }
    }

    private unowned let model: AppModel
    /// Asks Apple Intelligence to word the brief: a list's and a window's do, while they're on screen; a widget, which
    /// is always there, only shows what they had worded.
    private let wordsBrief: Bool
    private var cancellables: Set<AnyCancellable> = []
    private var optionsCancellable: AnyCancellable?
    private var needsRefresh = true

    init(model: AppModel, wordsBrief: Bool = true) {
        self.model = model
        self.wordsBrief = wordsBrief
        optionsCancellable = model.services.$interfaceOptions
            .map(\.clearerStates)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.changed() } }
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
        }, separateReady: model.services.interfaceOptions.clearerStates)
        // Worded on screen only: never while the list is closed.
        lines = sections.flatMap { model.source(for: $0)?.briefLines(for: $0) ?? [] }
        brief = Briefing.pick(lines)
        if wordsBrief, isShowing {
            model.briefWriter.write(brief, for: self)
        }
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
    /// The gear menu at the bottom, which a window's page leaves to the window's sidebar.
    var showsFooter = true

    @LocalState private var contentHeight: CGFloat = 0
    @Environment(\.interfaceOptions) private var options

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
            if showsFooter {
                Divider()
                footer
            }
        }
        .panelFrame(width: width)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            StateListProblems(list: list, model: model)
            if !options.compactBriefs, !list.brief.isEmpty {
                BriefPanel(lines: list.brief, writer: model.briefWriter)
                    .padding(.bottom, 2)
            }
            if list.groups.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(size: 22)
                        .foregroundStyle(.green)
                    Text("Nothing needs you")
                        .font(size: 13, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            ForEach(list.groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.title) (\(group.entries.count))")
                        .font(size: 11, weight: .semibold)
                        .foregroundStyle(options.quietAppearance ? Color.primary : group.state.color)
                        .padding(.horizontal, 8)
                    ForEach(group.entries) { entry in
                        HStack(alignment: .top, spacing: 0) {
                            SourceMark(section: entry.section, model: model)
                            entry.row.view
                                .environment(\.shownSection, entry.section)
                        }
                    }
                }
                if options.compactBriefs, group.id == list.groups.first?.id, !list.brief.isEmpty {
                    BriefPanel(lines: list.brief, writer: model.briefWriter)
                        .padding(.vertical, 4)
                }
            }
        }
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
                    .frame(minWidth: options.visibleActions ? 28 : nil, minHeight: options.visibleActions ? 28 : nil)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
        .font(size: 12)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A window's first page: everything on its other pages by state, with the brief, as the sources' own pages look.
struct OverviewPage: View {
    @ObservedObject var list: StateListModel
    let model: AppModel
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Overview", subtitle: subtitle) { EmptyView() }
            PageScroll {
                VStack(alignment: .leading, spacing: 18) {
                    StateListProblems(list: list, model: model)
                    if !options.compactBriefs, !list.brief.isEmpty {
                        BriefPanel(lines: list.brief, writer: model.briefWriter)
                            .padding(.horizontal, -4)
                    }
                    if list.groups.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "checkmark.circle")
                                .font(size: 30, weight: .light)
                                .foregroundStyle(.green)
                            Text("Nothing needs you")
                                .font(size: 15, weight: .semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    ForEach(list.groups) { group in
                        section(group)
                        if options.compactBriefs, group.id == list.groups.first?.id, !list.brief.isEmpty {
                            BriefPanel(lines: list.brief, writer: model.briefWriter)
                                .padding(.horizontal, -4)
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let parts = list.groups.map { "\($0.entries.count) \($0.countLabel)" }
        return parts.isEmpty ? "Nothing needs you" : parts.joined(separator: " · ")
    }

    private func section(_ group: StateListGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: group.symbol)
                    .foregroundStyle(group.state.color)
                Text(group.title)
                    .foregroundStyle(.primary)
                Text("\(group.entries.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            .font(size: 12, weight: .semibold)
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider().padding(.leading, 58).padding(.trailing, 12)
                    }
                    HStack(alignment: .top, spacing: 0) {
                        SourceMark(section: entry.section, model: model)
                        entry.row.view
                            .environment(\.shownSection, entry.section)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                }
            }
            .padding(.vertical, 4)
            .background(GlassCard(cornerRadius: 18))
        }
    }
}

/// Which source a row is from, in a list that mixes them: its section's symbol, in its color.
struct SourceMark: View {
    let section: SectionID
    let model: AppModel
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        let info = model.info(for: section)
        let name = model.source(for: section).map { source in
            source.sections.count > 1 ? "\(source.name): \(info?.title ?? "")" : source.name
        } ?? ""
        Image(systemName: info?.symbol ?? "circle")
            .font(size: 10, weight: .semibold)
            .foregroundStyle(options.quietAppearance ? .secondary : info?.tint ?? .secondary)
            .frame(width: 14)
            .padding(.top, 12)
            .help(name)
            .accessibilityLabel(name)
    }
}

/// What keeps a section of a list by state from showing what it should, each opening its source's settings.
struct StateListProblems: View {
    @ObservedObject var list: StateListModel
    let model: AppModel

    var body: some View {
        ForEach(list.problems, id: \.self) { problem in
            Button {
                if let source = list.sections.first(where: { model.source(for: $0)?.segment(for: $0).problem == problem })?.source {
                    model.openSettings(.source(source))
                }
            } label: {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(size: 12)
                    .symbolRenderingMode(.multicolor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .help("Open its settings")
        }
    }
}

/// The brief across sources: a few lines, each opening its thing, worded by Apple Intelligence on this Mac when it can,
/// or else in BriefBar's own words, without ✨.
struct BriefPanel: View {
    let lines: [BriefLine]
    @ObservedObject var writer: BriefWriter

    var body: some View {
        let texts = lines.map { writer.text(for: $0) }
        let isWritten = texts.contains { $0.isWritten }
        let pairs = Array(zip(lines, texts))
        BriefContainer(count: lines.count, isWritten: isWritten) { collapsed in
            ForEach(collapsed ? Array(pairs.prefix(2)) : pairs, id: \.0.id) { line, text in
                Button {
                    line.open()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(line.state.color)
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                        Text(text.text)
                            .font(size: 12)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(collapsed ? 2 : nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? text.text : "Click to open it")
            }
        }
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
