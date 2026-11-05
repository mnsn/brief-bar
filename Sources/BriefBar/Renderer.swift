import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI

/// `--render <dir>`: draws, in light and dark, the menu bar with each item's list open, the widgets, the window
/// at each page, each source's other pictures, the desktop of the README's tour, and the Settings window. Useful for
/// checking layouts without screen-recording permission, and for the README's pictures. With `--demo`, from made-up
/// data.
@MainActor
enum Renderer {
    /// How many pictures a process draws with `--part`. SwiftUI keeps every view graph of a process in one table, which
    /// can't grow past a limit, so `make screenshots` draws them a hundred to a process, however many there are.
    static let picturesPerPart = 100
    /// What `--part` exits with once it drew its part, when another part follows.
    static let anotherPartFollows: Int32 = 3

    /// - Parameter part: With `--part`, only that hundred of the pictures, in the order it draws them all: the first is 1.
    static func run(directory: String, demo: Bool, part: Int? = nil) -> Int32 {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            fputs("Can't create \(directory): \(error.localizedDescription)\n", stderr)
            return 1
        }
        Snapshot.useOverlayScrollers()
        // Apple Intelligence, when it words anything, says the same in each process that draws a part, and every time.
        OnDeviceModel.useLikeliestWords()
        _ = NSApplication.shared

        // Never the app's own preferences: a copy of them in memory, or the demo's.
        let model = AppModel(demo: demo, rendering: true)
        model.placeSections()
        // BRIEFBAR_RENDER_TEXT_SIZE=150: windows' pages with bigger text, as Settings › Appearance chooses.
        if let percent = Attribution.environment["BRIEFBAR_RENDER_TEXT_SIZE"].flatMap({ Int($0) }) {
            model.services.setTextSize(TextSize(percent: percent))
        }
        let sources = model.onSources
        var loaded = false
        // In the demo, a summary under a pull request's row and under a session's, kept aside for their own pictures; and
        // one of each pull request and session linked to the sprint, for their pages' pictures only.
        var rowSummaries: [(ItemRef, StorySummaries.State)] = []
        var pageSummaries: [(ItemRef, StorySummaries.State)] = []
        Task {
            for source in sources { await source.loadForRendering() }
            // What's known of everything linked, for the details' pictures; and, in the demo, a made-up summary of each work
            // item with something to sum up.
            let links = model.services.links
            await model.services.stories.tell(links.linked(Set(ItemRef.Kind.allCases)).sorted().map(links.describe))
            if demo {
                let summaries = model.services.summaries
                // Written by the model they'd have, once it's known.
                await summaries.lookForCLI()
                for workItem in links.linked([.workItem]).sorted() where summaries.hasSomethingToSum(workItem) {
                    await summaries.summarizeAndWait(workItem)
                }
                // The demo's pull request that Sam replied on, and its session that waits for your answer: at the top of their
                // pages.
                let replied = ItemRef.pullRequest(organization: "contoso", number: 4102)
                let asking = ItemRef.session("0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01")
                for ref in [replied, asking].compactMap({ $0 }) where summaries.canSummarize(ref) {
                    await summaries.summarizeAndWait(ref)
                    if let state = summaries.state(for: ref) { rowSummaries.append((ref, state)) }
                    summaries.useForRendering(ref, state: nil)
                }
                for ref in links.linked([.pullRequest, .session]).sorted() where summaries.canSummarize(ref) {
                    await summaries.summarizeAndWait(ref)
                    if let state = summaries.state(for: ref) { pageSummaries.append((ref, state)) }
                    summaries.useForRendering(ref, state: nil)
                }
            }
            loaded = true
        }
        while !loaded {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        // Each picture is drawn only when it's in this process's part. Everything else, which sets up what the pictures
        // after it show, happens in every process, as it would in one that draws them all.
        let pictures = Pictures(output: output, part: part.map { ($0 - 1) * picturesPerPart + 1...$0 * picturesPerPart })
        func write(_ image: @autoclosure () -> NSBitmapImageRep?, _ name: String) {
            pictures.write(name, image)
        }

        // Examples, drawn from copies of the layouts, so nothing is saved.
        let shown = model.sections(.menuBar)
        let items = model.visibleItems(.menuBar)
        // Azure DevOps and Copilot sharing an item, when both are on.
        var combined = model.layout(.menuBar)
        combined.place(shown)
        combined.combine(.copilotSessions, with: .azureDevOpsPullRequests)
        let combinedItems = combined.visibleItems(showing: shown)
        let combinedIndex = combinedItems.firstIndex { $0.sections.count > 1 }
        // Every section in one item, side by side, then added up by state, as Settings suggests.
        var all = model.layout(.menuBar)
        all.combineAll(items.flatMap(\.sections))
        let allItems = all.visibleItems(showing: shown)
        let merged = allItems.first.map { [$0.id: MenuBarItemOptions(byState: true)] } ?? [:]
        // And with everything in one list by state.
        let byState = allItems.first.map { [$0.id: MenuBarItemOptions(byState: true, listByState: true)] } ?? [:]
        // The Menu Bar settings' example: Azure DevOps with Copilot, and Group Chats hidden.
        var example = combined
        example.hide(.teamsGroupChats)
        // A widget for each section that has one, and one for all that show.
        let widgetSections = model.sections(.widgets)
        let shownWidgetSections = model.visibleItems(.widgets).flatMap(\.sections)
        let windowSections = model.sections(.windows)

        for dark in [false, true] {
            guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { continue }
            let suffix = dark ? "dark" : "light"

            /// The list that pressing an item opens, and what each item shows.
            func openedList(
                of items: [SectionLayout.Item], pressed index: Int, at section: SectionID? = nil,
                options: [String: MenuBarItemOptions] = [:]
            ) -> (items: [MenuBarItemContent], view: some View) {
                func itemOptions(_ item: SectionLayout.Item) -> MenuBarItemOptions {
                    options[item.id] ?? model.options(forMenuBarItem: item.id)
                }
                let contents = items.map { model.menuBarContent(sections: $0.sections, options: itemOptions($0)) }
                let panel = ItemPanelModel(model: model)
                panel.sections = items[index].sections
                panel.selected = section
                panel.usesCompactMenuBar = model.services.interfaceOptions.compactMenuBar
                panel.listByState = itemOptions(items[index]).listByState && items[index].sections.count > 1
                if panel.listByState || panel.usesCompactMenuBar {
                    panel.stateList.update(sections: items[index].sections)
                }
                if panel.listByState {
                    panel.stateList.isShowing = true
                    // With BRIEFBAR_RENDER_SUMMARIES=1, the brief as Apple Intelligence words it, when it can.
                    let deadline = Date().addingTimeInterval(60)
                    while model.briefWriter.isEnabled, model.briefWriter.isAvailable,
                          !model.briefWriter.isDone(with: panel.stateList.brief), Date() < deadline {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    }
                }
                let view = ItemPanelView(panel: panel)
                    .environmentObject(model.services)
                    .environmentObject(model.services.loginItem)
                    .background(Color(nsColor: .windowBackgroundColor))
                return (contents, view)
            }
            func picture(
                of items: [SectionLayout.Item], pressed index: Int, at section: SectionID? = nil, name: String,
                options: [String: MenuBarItemOptions] = [:]
            ) {
                let opened = openedList(of: items, pressed: index, at: section, options: options)
                write(Snapshot.render(opened.view, appearance: appearance).flatMap {
                    MenuBarPicture.draw(panel: $0, items: opened.items, pressed: index, appearance: appearance)
                }, "\(name)-\(suffix)")
            }
            for (index, item) in items.enumerated() {
                picture(of: items, pressed: index, name: "menubar-\(item.id)")
            }
            if let combinedIndex {
                picture(of: combinedItems, pressed: combinedIndex, name: "menubar-combined")
            }
            if allItems.count == 1, allItems[0].sections.count > 1 {
                // Opened at each tab, which all keep the widest panel's width.
                for section in allItems[0].sections {
                    picture(of: allItems, pressed: 0, at: section, name: "menubar-all-\(section.rawValue)")
                }
                picture(of: allItems, pressed: 0, name: "menubar-merged", options: merged)
                picture(of: allItems, pressed: 0, name: "menubar-by-state", options: byState)
            }

            func widgetView(_ sections: [SectionID], size: WidgetSize) -> some View {
                let content = WidgetContent(id: "render", model: model)
                content.sections = sections
                content.options = WidgetOptions(size: size)
                return WidgetView(content: content)
                    .environmentObject(model.services)
                    .environmentObject(model.services.loginItem)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(16)
            }
            func widget(_ sections: [SectionID], size: WidgetSize, name: String) {
                let view = widgetView(sections, size: size)
                write(Snapshot.render(view, appearance: appearance), "\(name)-\(suffix)")
            }
            for size in WidgetSize.allCases {
                for section in widgetSections {
                    widget([section], size: size, name: "widget-\(section.rawValue)-\(size.rawValue)")
                }
                // The Overview widget, of every source that's on.
                if !model.overviewSections.isEmpty {
                    let content = OverviewWidgetContent(model: model)
                    content.options = OverviewWidgetOptions(isShown: true, size: size)
                    content.list.update(sections: model.overviewSections)
                    content.list.isShowing = true
                    let view = OverviewWidgetView(content: content, list: content.list, writer: model.briefWriter)
                        .interfaceOptions(from: model.services)
                        .environmentObject(model.services)
                        .environmentObject(model.services.loginItem)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(16)
                    write(Snapshot.render(view, appearance: appearance), "widget-overview-\(size.rawValue)-\(suffix)")
                }
                if shownWidgetSections.count > 1 {
                    widget(shownWidgetSections, size: size, name: "widget-all-\(size.rawValue)")
                }
            }

            // The desktop the README's tour plays on: every section in one item, its list open by state, beside a widget
            // with every section; then with the list closed; and bare, for the tour's window to open over.
            if allItems.count == 1, allItems[0].sections.count > 1, shownWidgetSections.count > 1 {
                let opened = openedList(of: allItems, pressed: 0, options: byState)
                let widgetShown = widgetView(shownWidgetSections, size: .medium)
                let size = NSSize(width: 1_020, height: 728)
                // The widget, drawn once, for the first of these pictures that needs it.
                var drawnWidget: NSBitmapImageRep??
                func widgetImage() -> NSBitmapImageRep? {
                    if let drawnWidget { return drawnWidget }
                    let image = Snapshot.render(widgetShown, appearance: appearance)
                    drawnWidget = image
                    return image
                }
                write(Snapshot.render(opened.view, appearance: appearance).flatMap { panel in
                    MenuBarPicture.desktop(size: size, items: opened.items, open: (0, panel), widget: widgetImage(), appearance: appearance)
                }, "desktop-\(suffix)")
                write(MenuBarPicture.desktop(size: size, items: opened.items, widget: widgetImage(), appearance: appearance),
                      "desktop-closed-\(suffix)")
                write(MenuBarPicture.desktop(size: size, items: opened.items, appearance: appearance), "desktop-bare-\(suffix)")
            }

            // A window with one page: no sidebar.
            if let section = windowSections.first {
                let content = WindowContent(id: "render-alone", model: model)
                content.update(sections: [section])
                let view = WindowView(content: content)
                    .environment(\.isRendering, true)
                    .environmentObject(model.services)
                    .environmentObject(model.services.loginItem)
                    .frame(width: 560, height: 640)
                write(Snapshot.render(view, appearance: appearance), "window-alone-\(suffix)")
            }
            // One window with every page, open at each, the Overview first.
            if !windowSections.isEmpty {
                let content = WindowContent(id: "render", model: model)
                content.update(sections: windowSections)
                if content.pages.first == WindowContent.overview {
                    content.select(WindowContent.overview, notify: false)
                    content.overviewList.isShowing = true
                    let deadline = Date().addingTimeInterval(60)
                    while model.briefWriter.isEnabled, !model.briefWriter.isDone(with: content.overviewList.brief), Date() < deadline {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    }
                    let view = WindowView(content: content)
                        .environment(\.isRendering, true)
                        .environmentObject(model.services)
                        .environmentObject(model.services.loginItem)
                        .frame(width: 980, height: 680)
                    write(Snapshot.render(view, appearance: appearance), "window-overview-\(suffix)")
                }
                for section in windowSections {
                    content.select(section, notify: false)
                    let view = WindowView(content: content)
                        .environment(\.isRendering, true)
                        .environmentObject(model.services)
                        .environmentObject(model.services.loginItem)
                        .frame(width: 980, height: 680)
                    write(Snapshot.render(view, appearance: appearance), "window-\(section.rawValue)-\(suffix)")
                }
            }
            // A pull request's and a session's summary under its row, on their pages.
            if !rowSummaries.isEmpty {
                let summaries = model.services.summaries
                for (ref, state) in rowSummaries { summaries.useForRendering(ref, state: state) }
                let content = WindowContent(id: "render-rows", model: model)
                content.update(sections: windowSections)
                func rows(_ pictures: [(SectionID, String)]) {
                    for (section, name) in pictures where windowSections.contains(section) {
                        content.select(section, notify: false)
                        let view = WindowView(content: content)
                            .environment(\.isRendering, true)
                            .environmentObject(model.services)
                            .environmentObject(model.services.loginItem)
                            .frame(width: 980, height: 680)
                        write(Snapshot.render(view, appearance: appearance), "rows-summary-\(name)-\(suffix)")
                    }
                }
                rows([(.azureDevOpsPullRequests, "pull-requests"), (.copilotSessions, "sessions")])
                // Written again, with the one before meanwhile, under a pull request's row; and under a session's, the one
                // before when that couldn't be.
                for (ref, state) in rowSummaries {
                    let again: StorySummaries.State = ref.kind == .pullRequest
                        ? .writing(since: Date()) : .failed(StorySummaries.Problem("Copilot took too long to answer."), at: Date())
                    summaries.useForRendering(ref, state: again, previous: state)
                }
                rows([(.azureDevOpsPullRequests, "updating-pull-requests"), (.copilotSessions, "not-updated-sessions")])
                for (ref, _) in rowSummaries { summaries.useForRendering(ref, state: nil) }
            }
            // The Notifications page, in the window that has it, while it lists something, as the demo's does.
            if let window = model.overviewLink.window, model.hasNotificationsPage(window: window.id) {
                let content = WindowContent(id: window.id, model: model)
                content.update(sections: window.sections)
                content.select(WindowContent.notifications, notify: false)
                let view = WindowView(content: content)
                    .environment(\.isRendering, true)
                    .environmentObject(model.services)
                    .environmentObject(model.services.loginItem)
                    .frame(width: 980, height: 680)
                write(Snapshot.render(view, appearance: appearance), "window-notifications-\(suffix)")
            }

            // The pages show their summaries; the lists' pictures, drawn already, don't.
            for (ref, state) in pageSummaries { model.services.summaries.useForRendering(ref, state: state) }
            for source in sources {
                for rendering in source.extraRenderings() {
                    write(Snapshot.render(rendering.view, appearance: appearance), "\(source.id.rawValue)-\(rendering.name)-\(suffix)")
                }
            }
            for (ref, _) in pageSummaries { model.services.summaries.useForRendering(ref, state: nil) }

            func page(_ destination: SettingsDestination, name: String) {
                let navigation = SettingsNavigation()
                navigation.destination = destination
                let view = SettingsView(model: model, navigation: navigation)
                    .environment(\.isRendering, true)
                    .environmentObject(model.services)
                    .environmentObject(model.services.loginItem)
                    .background(Color(nsColor: .windowBackgroundColor))
                write(Snapshot.render(view, appearance: appearance), "settings-\(name)-\(suffix)")
            }
            let pages: [(String, SettingsDestination)] = [("general", .general), ("appearance", .appearance)]
                + Surface.allCases.map { ($0.title.lowercased().replacingOccurrences(of: " ", with: "-"), .layout($0)) }
                + model.sources.map { ($0.id.rawValue, .source($0.id)) }
                + [("pull-requests", .pullRequests), ("agents", .agents)]
            for (name, destination) in pages {
                page(destination, name: name)
            }
            /// A page whole, without the sidebar, as tall as it is: what scrolls below the window's picture of it too.
            func wholePage(_ content: some View, name: String) {
                let view = content
                    .padding(24)
                    .frame(width: SettingsView.pageWidth, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .interfaceOptions(from: model.services)
                    .environmentObject(model.services)
                    .environmentObject(model.services.loginItem)
                    .background(Color(nsColor: .windowBackgroundColor))
                write(Snapshot.render(view, appearance: appearance), "settings-\(name)-whole-\(suffix)")
            }
            // General, the sources' pages and the settings about pull requests, whole.
            let wholePages: [(String, SettingsDestination)] = [("general", .general)]
                + model.sources.map { ($0.id.rawValue, .source($0.id)) }
                + [("pull-requests", .pullRequests)]
            for (name, destination) in wholePages {
                wholePage(SettingsPage(model: model, destination: destination) { _ in }, name: name)
            }
            // And the settings about pull requests while Azure DevOps and GitHub are off, with Pull Request Order off: Azure
            // DevOps' disabled, each group saying why. Neither is changed.
            let orderOff = PullRequestOrder(defaults: MemoryDefaults(), isDemo: false)
            let sourcesOff = PullRequestsSettingsPage(model: model, order: orderOff, state: { _ in .off }) { _ in }
            wholePage(sourcesOff, name: "pull-requests-off")
            // The Notifications page's setting, below what the picture of General shows.
            let notificationsSetting = NotificationsSetting(recent: model.services.recentNotifications)
                .padding(24)
                .frame(width: 600, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
            write(Snapshot.render(notificationsSetting, appearance: appearance), "settings-notifications-\(suffix)")
            // Show Links and Summaries, below it too, for each provider.
            let linksSettings = VStack(alignment: .leading, spacing: 20) {
                LinksSetting(links: model.services.links)
                StorySummariesSetting(summaries: model.services.summaries, links: model.services.links)
            }
            .padding(24)
            .frame(width: 600, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            write(Snapshot.render(linksSettings, appearance: appearance), "settings-links-\(suffix)")
            if demo {
                let cloudSummaries = StorySummaries(
                    defaults: MemoryDefaults(), links: model.services.links, stories: model.services.stories, isDemo: true
                )
                cloudSummaries.models = model.services.summaries.models
                cloudSummaries.setModel("claude-haiku-5.5")
                let cloudSettings = StorySummariesSetting(summaries: cloudSummaries, links: model.services.links)
                    .padding(24)
                    .frame(width: 600, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor))
                write(Snapshot.render(cloudSettings, appearance: appearance), "settings-summaries-copilot-\(suffix)")
                // What it costs when it's written only when you ask; and the setting as Turn On… shows it, on its own.
                cloudSummaries.setWritesWhenOpened(false)
                write(Snapshot.render(cloudSettings, appearance: appearance), "settings-summaries-copilot-asked-\(suffix)")
                let turnOn = StorySummariesSetting(summaries: model.services.summaries, links: model.services.links, isNested: false)
                    .padding(16)
                    .frame(width: 460, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor))
                write(Snapshot.render(turnOn, appearance: appearance), "summary-turn-on-\(suffix)")
            }
            // And with Show Links off, when Summaries can't be changed.
            let linksOff = Links(defaults: MemoryDefaults(), isDemo: false)
            let summariesOff = StorySummaries(defaults: MemoryDefaults(), links: linksOff, stories: ItemStories(links: linksOff), isDemo: true)
            summariesOff.models = model.services.summaries.models
            let linksOffSettings = VStack(alignment: .leading, spacing: 20) {
                LinksSetting(links: linksOff)
                StorySummariesSetting(summaries: summariesOff, links: linksOff)
            }
            .padding(24)
            .frame(width: 600, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            write(Snapshot.render(linksOffSettings, appearance: appearance), "settings-links-off-\(suffix)")
            // A summary as it's written, once it is, when it's out of date and when it fails, in the demo; and Where It Stands
            // without one, with ✨ Summarize.
            let summaries = model.services.summaries
            let summarized = model.services.links.linked([.workItem]).sorted().first { subject in
                if case .written? = summaries.state(for: subject) { return true }
                return false
            }
            if demo, let subject = summarized, case .written(let summary, let at, var inputs, let modelID)? = summaries.state(for: subject) {
                let written = summaries.state(for: subject)
                func card(_ name: String, width: CGFloat = 420) {
                    let view = SummaryCard(subject: subject, summaries: summaries, rows: [])
                        .interfaceOptions(from: model.services)
                        .environmentObject(model.services)
                        .padding(16)
                        .frame(width: width, alignment: .leading)
                        .background(Color(nsColor: .windowBackgroundColor))
                    write(Snapshot.render(view, appearance: appearance), "summary-\(name)-\(suffix)")
                }
                card("written")
                // About to be written as it opened, then being written, at about the height it will be.
                summaries.useForRendering(subject, state: nil)
                if let wait = summaries.expect(subject, unlessActedSince: nil) {
                    card("pending")
                    summaries.stopExpecting(subject, wait)
                }
                summaries.useForRendering(subject, state: .writing(since: Date()))
                card("writing")
                // Written again: the one before shows meanwhile; and when that one couldn't be written, as it was.
                summaries.useForRendering(subject, state: .writing(since: Date()), previous: written)
                card("updating")
                summaries.useForRendering(subject, state: .failed(StorySummaries.Problem("Copilot took too long to answer."), at: Date()),
                                          previous: written)
                card("not-updated")
                summaries.useForRendering(subject, state: .failed(StorySummaries.Problem(
                    "Claude Haiku 5.5 isn't on your Copilot plan.",
                    detail: "Error: Model \"claude-haiku-5.5\" from --model flag is not available.", fix: .chooseModel
                ), at: Date()))
                card("failed")
                // One of what it summed up said something else then.
                if let index = inputs.firstIndex(where: { $0.ref.kind == .pullRequest }) { inputs[index].row += "\nthen" }
                summaries.useForRendering(subject, state: .written(summary, at: at.addingTimeInterval(-40 * 60), inputs: inputs, model: modelID))
                card("out-of-date")
                card("out-of-date-narrow", width: 330)
                summaries.useForRendering(subject, state: nil)
                let standing = WhereItStandsSection(subject: subject)
                    .environment(\.isRendering, true)
                    .interfaceOptions(from: model.services)
                    .environmentObject(model.services)
                    .padding(16)
                    .frame(width: 420, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor))
                write(Snapshot.render(standing, appearance: appearance), "summary-none-\(suffix)")
                summaries.useForRendering(subject, state: written)
                // While summaries are off, the line that offers them, where its card would be.
                let off = StorySummaries(defaults: MemoryDefaults(), links: model.services.links, stories: model.services.stories, isDemo: false)
                let offer = SummaryOffer(subject: subject, summaries: off, links: model.services.links, defaults: MemoryDefaults())
                    .interfaceOptions(from: model.services)
                    .environmentObject(model.services)
                    .padding(16)
                    .frame(width: 420, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor))
                write(Snapshot.render(offer, appearance: appearance), "summary-offer-\(suffix)")
            }
            let saved = model.layout(.menuBar)
            let savedOptions = model.menuBarItemOptions
            model.useForRendering(example)
            page(.layout(.menuBar), name: "menu-bar-example")
            if allItems.count == 1, allItems[0].sections.count > 1 {
                model.useForRendering(all)
                model.useForRendering(byState)
                page(.layout(.menuBar), name: "menu-bar-merged")
            }
            model.useForRendering(saved)
            model.useForRendering(savedOptions)
            if model.agents.state == .off {
                model.agents.useForRendering(on: true)
                page(.agents, name: "agents-on")
                // With Send Prompts to Copilot Sessions and Updates from Copilot Sessions on, in one picture, as the
                // pictures of one render already come close to what SwiftUI can hold.
                model.agents.useForRendering(on: true, sessionPrompts: true, sessionUpdates: true)
                page(.agents, name: "agents-on-session-prompts")
                model.agents.useForRenderingLeftovers()
                page(.agents, name: "agents-off-leftovers")
                model.agents.useForRendering(on: false)
            }

            if demo {
                let savedInterface = model.services.interfaceOptions
                let savedTextSize = model.services.textSize
                func interfaceExample(_ enabled: Set<InterfaceOption>, name: String) {
                    for option in InterfaceOption.allCases {
                        model.services.setInterfaceOption(option, enabled: enabled.contains(option))
                    }
                    if !windowSections.isEmpty {
                        let content = WindowContent(id: "render-interface", model: model)
                        content.update(sections: windowSections)
                        content.select(WindowContent.overview, notify: false)
                        content.overviewList.isShowing = true
                        let view = WindowView(content: content)
                            .environment(\.isRendering, true)
                            .environmentObject(model.services)
                            .environmentObject(model.services.loginItem)
                            .frame(width: 980, height: 680)
                        write(Snapshot.render(view, appearance: appearance), "interface-\(name)-window-\(suffix)")
                    }
                    if enabled.contains(.compactMenuBar), let first = model.presentedMenuBarItems.first {
                        picture(of: [first], pressed: 0, name: "interface-\(name)-menubar")
                    }
                    if enabled.contains(.readableRows) || enabled.contains(.visibleActions) {
                        widget(shownWidgetSections, size: .medium, name: "interface-\(name)-widget")
                    }
                    if enabled.contains(.simpleLayoutControls) {
                        page(.layout(.menuBar), name: "interface-\(name)-layout")
                    }
                }
                for option in InterfaceOption.allCases {
                    interfaceExample([option], name: option.rawValue)
                }
                // The largest text, on its own and with every option.
                model.services.setTextSize(TextSize(percent: TextSize.percentages.last ?? 100))
                interfaceExample([], name: "textSize")
                interfaceExample(Set(InterfaceOption.allCases), name: "all")
                page(.appearance, name: "appearance-enabled")
                for option in InterfaceOption.allCases {
                    model.services.setInterfaceOption(option, enabled: savedInterface[option])
                }
                model.services.setTextSize(savedTextSize)
            }
        }
        pictures.written.forEach { print($0) }
        if let part, pictures.endsBeforePart {
            let parts = (pictures.count + picturesPerPart - 1) / picturesPerPart
            fputs("There's no part \(part): BriefBar draws \(pictures.count) pictures, in \(parts) parts.\n", stderr)
            return 1
        }
        if pictures.written.isEmpty { return 1 }
        return pictures.hasPicturesAfterPart ? anotherPartFollows : 0
    }
}

/// The pictures `--render` draws, numbered in the order it draws them, from 1. It draws and writes those of its part, or
/// all of them, each in an autorelease pool of its own: `--render` never goes back to an event loop, which is what empties
/// the main thread's pool, so without one, all that drawing and writing a picture autoreleased, such as its images and
/// their PNG data, stayed until BriefBar quit.
@MainActor
private final class Pictures {
    private let output: URL
    /// The numbers of those it draws, or nil for all.
    private let part: ClosedRange<Int>?
    /// How many it came to, drawn or not.
    private(set) var count = 0
    private(set) var written: [String] = []

    init(output: URL, part: ClosedRange<Int>?) {
        self.output = output
        self.part = part
    }

    /// Whether there are pictures after its part.
    var hasPicturesAfterPart: Bool {
        part.map { count > $0.upperBound } ?? false
    }

    /// Whether there were fewer pictures than its part starts at.
    var endsBeforePart: Bool {
        part.map { count < $0.lowerBound } ?? false
    }

    func write(_ name: String, _ image: () -> NSBitmapImageRep?) {
        count += 1
        guard part?.contains(count) ?? true else { return }
        autoreleasepool {
            if let image = image(), let file = Snapshot.write(image, to: output.appending(path: "\(name).png")) {
                written.append(file)
            }
        }
    }
}
