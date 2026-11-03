import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks
import NotificationCenterDB
import SwiftUI

/// Your Azure DevOps pull requests, by what they need: you, a fix, completing, or someone else; and, while you
/// show them, your team's sprint and the pipelines you follow. It reads Azure DevOps with the Azure CLI's sign-in,
/// one of the two sources that use the network (with GitHub), and posts notifications.
@MainActor
package final class AzureDevOpsSource: BriefBarSource {
    /// 2: the Sprint and Pipelines sections. 3: Send Work to Copilot. 4: the pipelines after your merges, the pull
    /// requests you watch, and pull requests sent to Copilot. 5: Show Links. 6: active PR validation runs. 7: the Copilot
    /// sessions a task can go to.
    /// 8: a work item's details, when you open one.
    /// 9: what a summary reads: pull requests' descriptions and comment threads, and work items'
    /// details.
    /// 10: Send to Session and Send to a Fork: what BriefBar's extension in the Copilot app's sessions says, and which
    /// session a fork came from.
    /// 11: the code that comments are on, as a pull request's details show them.
    /// 12: the Copilot sessions a pull request's work could go to, as its details show, and the one you choose for it.
    /// 13: asking a session about a comment, which sends its conversation, with the comment and its code, to GitHub Copilot;
    /// the forks BriefBar still has to delete; and following a prompt about comments in the Copilot app's session it went to.
    nonisolated package static let descriptionVersion = 13

    package let id = SourceID.azureDevOps
    package let name = "Azure DevOps"
    package let symbol = "arrow.triangle.pull"
    package let description = SourceDescription(
        version: AzureDevOpsSource.descriptionVersion,
        summary: "Your pull requests: which need you, which are failing and which are ready to complete; and your team's sprint and your pipelines",
        reads: "Your pull requests and the ones you review, in the organizations you choose, and the ones you watch, by their links, with their builds, policies and comment threads, from Azure DevOps; and, after you merge one, while Done keeps it, the runs of the pipelines that build its merge and of the ones those start, unless you turn Follow Pipelines After You Merge off. While its Sprint or Pipelines section is on screen: your team's current sprint, with its stories, bugs and tasks and who has them, and the recent runs of the pipelines you pin; for Pipelines, also the latest validation runs of each active pull request you authored, including their stages, failure details and commit information. When you open one of its work items: its fields, description and other text, the work items it links to, its attachments' names and its latest comments, which BriefBar keeps in memory only, and forgets a quarter of an hour after reading them unless they're still on screen. When you open a pull request's details: for each comment thread on lines of code, as it comes on screen, the file it's on, before and after the change the comment was made on, and which files each update of the pull request changed, which BriefBar keeps in memory only, while those details show. BriefBar keeps which pull requests you've seen, your organizations, the pull requests you watch, your team and your pipelines. When Apple Intelligence is on, a brief of what needs you is written on your Mac by Apple's on-device model. Only if you turn on Pull Requests Sent in Chats: the notifications every app posts to Notification Center, for links to pull requests, of which BriefBar keeps only the links, with who sent them, in which app and when, never the messages, and only in memory. Only if you turn on Send Work to Copilot: when you send a work item or a pull request, the git repository you choose, and Copilot's log of the session it starts or goes on with, until it ends, and, for a pull request's failed build, the run's timeline, for its errors; and, as the window that sends it opens, and as a pull request's details show and every ten seconds while they do, the Copilot app's sessions its work could go to, read-only from ~/.copilot: their names, projects and branches, the pull requests the app records with them and which run a turn now, from its database; the folder each works in, from its session state; which ones the app has open; and which of those active lately link to it in their logs. New: when you send a prompt about a pull request's comments to one of the Copilot app's sessions, or to a fork of it, or BriefBar copies it for you to paste there, every few seconds from then until Copilot is done with it, to say on each comment what became of it: that session's log and whether something has it open, which of the app's sessions run a turn now, from its database, and, for one copied as /fork, the fork the app records it made of the session, and when; and when you ask a session about a comment with Explain, the session's conversation, which the Copilot CLI copies into a fork it deletes after, goes to GitHub Copilot with the comment and its code, and the answer stays in memory only. Only if you also turn on Send Prompts to Copilot Sessions, in Settings › Agents: as that window, or a pull request's details, say how a prompt would reach a session, which sessions BriefBar's extension listens in, from files only you can read in BriefBar's own folder; and, when you send a prompt to a session or a fork of it, what the extension says became of it, from the same folder, which the prompt goes through too, until the extension is done with it; and, for a fork, which session the Copilot app records it came from, and when it was made. BriefBar keeps which work items and pull requests you sent, what for, where, with which model, and the pull request Copilot opened; the session you choose for a pull request's work, by its ID only; the comment threads each task or prompt took on, and which session a prompt about comments went to and when, by their IDs only; the IDs of the forks it made to ask a session about a comment, until it has deleted them; and, in a file only you can read, what Copilot printed when it ended. Only if you turn on Show Links: the work items linked to each of your pull requests, the pull requests linked to the sprint's work items while the sprint is on screen, and what the linked work items and pull requests that your lists don't show are; BriefBar keeps the links you add or hide, as references only, never titles. Only when a summary is written, or, for one ten minutes old or more, again as you open it, to tell whether it's still current: for the things it sums up, each pull request's description and comment threads, and each work item's details, as when you open one. With Apple Intelligence, what a summary is written from stays on this Mac; with a Copilot model, BriefBar sends it to GitHub Copilot through the Copilot CLI, which keeps a copy in its session history. BriefBar keeps none of it.",
        network: "Azure DevOps only: dev.azure.com, and app.vssps.visualstudio.com to find your organizations, with your Azure CLI sign-in. Every request is a GET, so it never changes anything there: about 10 to 25 small requests a minute, a few more while the Sprint or Pipelines section is on screen, two or three when you open a work item's details and when it changes while they show, a few for each comment thread on code that comes on screen in a pull request's details (its updates and the files they changed, read once, and the file before and after the change, each read once, up to 1 MB), a few more after you merge a pull request, while its pipelines run, and, with Show Links on, one for each pull request's work items every quarter of an hour, a few for the sprint's links while it's on screen, and, as a summary is written, or checked as you open one ten minutes old or more, up to two for each pull request it sums up and two or three for each work item whose details aren't on screen. When a summary is written with a Copilot model, the Copilot CLI sends what it covers to GitHub Copilot. When you ask a Copilot session about a comment, the Copilot CLI sends the session's conversation, with the comment and its code, to GitHub Copilot, as one premium request. When you send a work item or a pull request to Copilot, BriefBar itself still connects nowhere, but the programs it starts for you do: git fetches the repository, and the Copilot CLI uses GitHub Copilot and your MCP servers, pushes a branch, opens a pull request or replies on one, as you.",
        needs: "The Azure CLI, signed in with az login: BriefBar gets its tokens from it, so there's no personal access token, and runs it without any of BriefBar's own permissions. And permission to post notifications, which macOS asks for when you turn it on. Pull Requests Sent in Chats also needs Full Disk Access, which macOS grants once, to all of BriefBar. Send Work to Copilot needs the Copilot CLI, signed in, which BriefBar runs with your shell's environment and without any of BriefBar's own permissions.",
        requirements: [.azureCLI, .notifications]
    )
    /// Sprint and Pipelines start in windows only: they read Azure DevOps while they're on screen.
    package let sections = [
        SectionInfo(
            id: .azureDevOpsPullRequests, title: AzureDevOpsPage.pullRequests.title, symbol: AzureDevOpsPage.pullRequests.symbol,
            tint: AzureDevOpsPage.pullRequests.color, counted: CountNoun("pull request", "pull requests"),
            states: [.needsYou, .failing, .done], surfaces: [.menuBar, .widgets, .windows]
        ),
        SectionInfo(
            id: .azureDevOpsSprint, title: AzureDevOpsPage.sprint.title, symbol: AzureDevOpsPage.sprint.symbol,
            tint: AzureDevOpsPage.sprint.color, counted: CountNoun("work item", "work items"),
            surfaces: [.menuBar, .widgets, .windows], hiddenAtFirst: [.menuBar, .widgets]
        ),
        SectionInfo(
            id: .azureDevOpsPipelines, title: AzureDevOpsPage.pipelines.title, symbol: AzureDevOpsPage.pipelines.symbol,
            tint: AzureDevOpsPage.pipelines.color, counted: CountNoun("pipeline", "pipelines"), states: [.failing, .running],
            surfaces: [.menuBar, .widgets, .windows], hiddenAtFirst: [.menuBar, .widgets]
        ),
    ]
    package var panelWidth: CGFloat { MenuPanelView.width }

    private static let chatAccessReason = "For pull requests sent in chats, BriefBar looks for links to pull requests in the notifications that every app posts to Notification Center, and keeps only the links, in memory."

    private let services: AppServices
    let settings: AppSettings
    /// Notification Center, for pull requests sent in chats: only the app passes it, so `--render`, the demo and tests
    /// read nothing there.
    let chats: ChatReading
    /// Made when Azure DevOps starts, so its notifications count from then.
    private var store: PRStore?
    /// Made with it, sharing its client: they read only while their sections are on screen.
    private var sprint: SprintStore?
    private var pipelines: PipelinesStore?
    /// Sends work items to Copilot, when you ask, and follows them.
    private var copilot: CopilotTasksStore?
    /// Tells Show Links what Azure DevOps links, while it's on.
    private var workLinks: WorkLinksStore?
    /// The work item whose details show beside the sprint.
    private var details: WorkItemDetailsStore?
    /// The pull request whose details show beside the window's list, and where a pull request opens from anywhere else.
    private(set) var pullRequestDetails: PullRequestDetailsStore?
    /// The code that pull requests' comment threads are on, read as they come on screen in their details.
    private var pullRequestCode: PullRequestCodeStore?
    /// The Copilot session of the pull request whose details show.
    private var pullRequestSessions: PullRequestSessions?
    /// What you ask Copilot sessions about pull requests' comment threads with Explain, and their answers, in memory.
    private var commentQuestions: CommentQuestions?
    /// For `--render`: the Sprint page with a story's details, and with a task's.
    private var renderedDetails: [(name: String, details: WorkItemDetailsStore)] = []
    private let changes = PassthroughSubject<Void, Never>()
    /// What a list by state shows changed: any pull request or pipeline, not only the counts.
    private let rowChanges = PassthroughSubject<Void, Never>()
    private var cancellables: Set<AnyCancellable> = []
    /// Hears about the pull requests and pipelines an agent watches or pins through `--mcp`.
    private var agentChanges: AnyObject?

    package init(services: AppServices, chats: ChatReading = .inert) {
        self.services = services
        self.chats = chats
        settings = AppSettings(defaults: services.defaults)
    }

    /// The groups counted in the menu bar: what to act on. Waiting and Done only show in the list.
    static func shownGroups(showToReview: Bool) -> [PRGroup] {
        showToReview ? [.needsYou, .failing, .ready, .toReview] : [.needsYou, .failing, .ready]
    }

    private func environment<V: View>(_ view: V) -> AnyView {
        guard let store, let sprint, let pipelines, let copilot, let details, let pullRequestDetails, let pullRequestCode,
              let pullRequestSessions, let commentQuestions else {
            return AnyView(EmptyView())
        }
        return AnyView(view
            .interfaceOptions(from: services)
            .environmentObject(store)
            .environmentObject(sprint)
            .environmentObject(details)
            .environmentObject(pullRequestDetails)
            .environmentObject(pullRequestCode)
            .environmentObject(pullRequestSessions)
            .environmentObject(commentQuestions)
            .environmentObject(pipelines)
            .environmentObject(copilot)
            .environmentObject(settings)
            .environmentObject(services)
            .environmentObject(services.loginItem))
    }

    /// The pull requests' store, and the Sprint and Pipelines sections' stores, sharing its client.
    private func makeStores(notifier: Notifier?) -> PRStore {
        let store = PRStore(settings: settings, notifier: notifier, mode: services.isDemo ? .demo : .live, chats: chats)
        self.store = store
        let sprint = SprintStore(settings: settings, mode: store.mode, client: store.client)
        self.sprint = sprint
        let pipelines = PipelinesStore(settings: settings, mode: store.mode, client: store.client)
        self.pipelines = pipelines
        store.$authoredPullRequestList.removeDuplicates()
            .sink { [weak pipelines] list in
                MainActor.assumeIsolated { pipelines?.setPullRequests(list.pullRequests, account: list.account) }
            }
            .store(in: &cancellables)
        let copilot = CopilotTasksStore(settings: settings, mode: store.mode, notifier: notifier)
        copilot.services = services
        copilot.title = { [weak sprint] reference in sprint?.title(of: reference) }
        copilot.pullRequestTitle = { [weak store] reference in
            store?.items.first { $0.key.number == reference.id && $0.key.organization.caseInsensitiveCompare(reference.organization) == .orderedSame }?.title
        }
        copilot.handedOff = { [weak store] handOff, prompt in store?.sentToCopilot(handOff, prompt: prompt) }
        copilot.linkedSessions = { [weak links = services.links] ref in
            (links?.connections(of: ref) ?? []).filter { $0.item.ref.kind == .session }.map {
                LinkedSession(id: $0.item.ref.id, origins: $0.origins, isThrough: $0.via != nil)
            }
        }
        self.copilot = copilot
        workLinks = WorkLinksStore(
            links: services.links, stories: services.stories, store: store, sprint: sprint, copilot: copilot, settings: settings
        )
        let details = WorkItemDetailsStore(mode: store.mode, client: store.client, board: sprint.$board.eraseToAnyPublisher())
        details.hasPage = { [services] in services.hasPage(.azureDevOpsSprint) }
        details.openPage = { [services] in services.openWindow(.azureDevOpsSprint) }
        let pullRequestDetails = makePullRequestDetails(store: store)
        let pullRequestCode = PullRequestCodeStore(demo: store.mode == .demo, client: store.client)
        pullRequestCode.follow(pullRequestDetails)
        self.pullRequestCode = pullRequestCode
        // Someone else signed in to the Azure CLI: the details read as the last one go, and what was told of them.
        store.$authoredPullRequestList.map(\.account).removeDuplicates()
            .sink { [weak details, weak workLinks, weak pullRequestDetails] account in
                MainActor.assumeIsolated {
                    details?.accountChanged(account)
                    workLinks?.accountChanged(account)
                    pullRequestDetails?.accountChanged(account)
                }
            }
            .store(in: &cancellables)
        self.details = details
        self.pullRequestDetails = pullRequestDetails
        workLinks?.details = details
        let sessions = PullRequestSessions(copilot: copilot, links: services.links)
        sessions.record = { [weak store] key in store?.record(for: key) }
        pullRequestSessions = sessions
        commentQuestions = CommentQuestions(copilot: copilot)
        // A pull request that a task or a link names shows in its details, on the window's page, while the list has it.
        copilot.canShowPullRequest = { [weak store, weak pullRequestDetails] key in
            guard let store, let pullRequestDetails else { return false }
            return pullRequestDetails.hasPage() && store.items.contains { $0.key == key }
        }
        copilot.showPullRequest = { [weak pullRequestDetails] key in pullRequestDetails?.reveal(key) ?? false }
        workLinks?.showPullRequest = { [weak pullRequestDetails] key in pullRequestDetails?.reveal(key) ?? false }
        return store
    }

    /// The pull request whose details show beside the window's list, which follows the list as it refreshes, and sees what
    /// it shows as opening it does.
    private func makePullRequestDetails(store: PRStore) -> PullRequestDetailsStore {
        let details = PullRequestDetailsStore()
        details.use(store)
        details.hasPage = { [services] in services.hasPage(.azureDevOpsPullRequests) }
        details.openPage = { [services] in services.openWindow(.azureDevOpsPullRequests) }
        return details
    }

    // MARK: Lifecycle

    package func start() {
        guard store == nil else { return }
        if !services.isDemo {
            settings.startSeeing()
        }
        let store = makeStores(notifier: services.notifier)
        let access = services.fullDiskAccess
        store.showChatAccessSetup = { [weak access] in access?.show() }
        store.chatAccessChanged = { [weak self, weak access] status in
            MainActor.assumeIsolated {
                guard let self, let access, access.isRequested(by: self.id) else { return }
                access.report(granted: status == .granted)
            }
        }
        // Pull requests sent in chats read Notification Center: the access is needed only while that's on, and
        // only for its own database (not a copy that BRIEFBAR_CHAT_LINKS_DB names). The demo never reads it.
        if !services.isDemo, let database = chats.database, ChatLinkDatabase.isSystemDatabase(database) {
            settings.$chatLinksEnabled.removeDuplicates()
                .sink { [weak self] enabled in MainActor.assumeIsolated { self?.chatLinksChanged(enabled, database: database) } }
                .store(in: &cancellables)
        }
        // The access window saw it granted: read now rather than at the next check.
        access.$isGranted
            .removeDuplicates()
            .filter { $0 == true }
            .sink { [weak store] _ in MainActor.assumeIsolated { store?.refreshChats() } }
            .store(in: &cancellables)
        store.$counts.removeDuplicates().map { _ in () }
            .merge(with: settings.$showToReview.removeDuplicates().map { _ in () })
            .merge(with: store.$problem.map { _ in () })
            .merge(with: sprint?.$board.map { _ in () }.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher())
            .merge(with: pipelines?.$statuses.map { _ in () }.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.changes.send() } }
            .store(in: &cancellables)
        store.$items.map { _ in () }
            .merge(with: store.$problem.map { _ in () })
            .merge(with: settings.$showToReview.removeDuplicates().map { _ in () })
            // Whether the brief asks Apple Intelligence for its lines, at once when you change it.
            .merge(with: settings.$summaries.removeDuplicates().dropFirst().map { _ in () })
            .merge(with: pipelines?.$statuses.map { _ in () }.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.rowChanges.send() } }
            .store(in: &cancellables)

        // What agents changed while it was stopped too: the lists were read when the app started.
        if !services.isDemo {
            settings.reloadAgentChanges()
            agentChanges = AgentChanges.observe { [weak self] in self?.settings.reloadAgentChanges() }
        }

        store.start()
        sprint?.start()
        pipelines?.start()
        copilot?.start()
        workLinks?.start()
        // Your name, as your pull requests have it, for a summary to call you "you".
        services.summaries.setYourName(.azureDevOps) { [weak store] in store?.reader }
        // The tasks sent to Copilot, for its list to show with your sessions: as they go, and with the titles the lists
        // read.
        if let copilot, let sprint {
            copilot.objectWillChange.map { _ in () }
                .merge(with: store.$items.map { _ in () }, sprint.$board.map { _ in () })
                .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
                .sink { [weak self] in MainActor.assumeIsolated { self?.publishSentTasks() } }
                .store(in: &cancellables)
        }
        publishSentTasks()
        listDemoNotifications(from: store)
        changes.send()
    }

    /// Tells Copilot's list the tasks sent to Copilot, while Send Work to Copilot is on.
    private func publishSentTasks() {
        guard let copilot, copilot.isOn else {
            services.sentTasks.withdraw(.azureDevOps)
            return
        }
        services.sentTasks.publish(.azureDevOps, tasks: copilot.sentTasks())
    }

    /// The demo's made-up news on the Notifications page, as if BriefBar had been running for a while: what came over
    /// the last hour is new, the rest seen.
    private func listDemoNotifications(from store: PRStore) {
        guard services.isDemo else { return }
        let recent = services.recentNotifications
        let hourAgo = Date().addingTimeInterval(-3600)
        for (notification, date) in store.demoNotifications {
            recent.record([notification], at: date)
            if date < hourAgo { recent.markSeen(notification.id) }
        }
    }

    package func didTurnOn() {
        // You just turned it on, having read that it posts notifications: macOS asks now.
        if settings.notifications {
            services.notifier.requestAuthorization()
        }
        // And pull requests sent in chats, if they were on when you turned it off: the steps for Full Disk Access.
        if settings.chatLinksEnabled {
            store?.askForChatAccessIfMissing()
        }
    }

    package func stop() {
        cancellables.removeAll()
        agentChanges = nil
        store?.stop()
        sprint?.stop()
        pipelines?.stop()
        copilot?.stop()
        workLinks?.stop()
        details?.stop()
        pullRequestDetails?.stop()
        pullRequestCode?.stop()
        pullRequestSessions?.stopAll()
        commentQuestions?.stopAll()
        services.sentTasks.withdraw(.azureDevOps)
        services.summaries.setYourName(.azureDevOps, nil)
        store = nil
        sprint = nil
        pipelines = nil
        copilot = nil
        workLinks = nil
        details = nil
        pullRequestDetails = nil
        pullRequestCode = nil
        pullRequestSessions = nil
        commentQuestions = nil
        services.fullDiskAccess.unregister(.azureDevOps)
    }

    private func chatLinksChanged(_ enabled: Bool, database: URL) {
        let access = services.fullDiskAccess
        if enabled {
            access.register(.azureDevOps, name: "Azure DevOps", reason: Self.chatAccessReason) {
                DatabaseAccess.check(database) == .granted
            }
        } else if access.isRequested(by: id) {
            access.unregister(.azureDevOps)
            // You just turned it off: if nothing else reads Notification Center, BriefBar can be taken off the list.
            DispatchQueue.main.async { [weak access] in access?.offerRemoval() }
        }
    }

    package func deleteSavedData() {
        settings.forgetSeen()
        settings.forgetCopilotRuns()
        // The links you added or hid between pull requests, work items and sessions.
        services.links.forget(.azureDevOps)
        // What Copilot printed for each task: the demo never wrote any, and mustn't delete yours.
        if !services.isDemo {
            CopilotTasksStore.deleteOutput()
        }
    }

    // MARK: Menu bar

    package func segment(for section: SectionID) -> MenuBarSegment {
        switch section {
        case .azureDevOpsSprint: return sprintSegment()
        case .azureDevOpsPipelines: return pipelinesSegment()
        default: return pullRequestsSegment()
        }
    }

    /// How many of your stories and tasks are left in the sprint.
    private func sprintSegment() -> MenuBarSegment {
        let mine = sprint?.board?.myWork ?? []
        let title = NSMutableAttributedString()
        if !mine.isEmpty {
            title.append(NSAttributedString(string: " "))
            title.append(MenuBarDrawing.count(mine.count))
        }
        let summary = sprint?.board == nil ? "Sprint" : mine.isEmpty ? "Sprint: nothing left for you" : "Sprint: \(mine.count) of yours left"
        // What's left of the sprint isn't in any state: it doesn't add up with what needs you or what's done.
        return MenuBarSegment(glyph: AzureDevOpsPage.sprint.symbol, title: title, summary: summary, count: mine.count, needsAttention: false,
                              states: StateCounts())
    }

    /// How many pinned pipelines failed, and how many are running.
    private func pipelinesSegment() -> MenuBarSegment {
        let counts = pipelines?.counts ?? PipelineCounts([])
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        for (count, symbol, color) in [(counts.failed, "xmark.circle.fill", NSColor.systemRed), (counts.running, "arrow.triangle.2.circlepath.circle.fill", .systemBlue)] where count > 0 {
            title.append(NSAttributedString(string: " "))
            title.append(MenuBarDrawing.symbol(symbol, color: color, font: font, sizeDelta: -2, monochrome: true))
            title.append(MenuBarDrawing.count(count, font: font))
        }
        let spoken = [(counts.failed, "failed"), (counts.running, "running")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        let summary = spoken.isEmpty ? "Pipelines" : "Pipelines: " + spoken.joined(separator: ", ")
        return MenuBarSegment(
            glyph: AzureDevOpsPage.pipelines.symbol, title: title, summary: summary, count: counts.failed, needsAttention: counts.failed > 0,
            states: counts.states
        )
    }

    private func pullRequestsSegment() -> MenuBarSegment {
        let counts = store?.counts ?? GroupCounts()
        let needsSignIn = store?.problem?.needsSignIn == true
        let groups = Self.shownGroups(showToReview: settings.showToReview)
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        if needsSignIn {
            // A small orange person badge while you need to sign in.
            title.append(NSAttributedString(string: " "))
            title.append(MenuBarDrawing.symbol("person.crop.circle.badge.exclamationmark.fill", color: .systemOrange, font: font,
                                               sizeDelta: -2, monochrome: true))
        } else {
            for group in groups where counts[group] > 0 {
                title.append(NSAttributedString(string: " "))
                // Monochrome keeps the check and the cross cut out; one palette color fills them in.
                title.append(MenuBarDrawing.symbol(group.symbol, color: group.nsColor, font: font, sizeDelta: -2, monochrome: true))
                title.append(MenuBarDrawing.count(counts[group], font: font))
            }
        }
        let spoken = groups.filter { counts[$0] > 0 }.map { "\(counts[$0]) \($0.countLabel)" }
        let summary = needsSignIn
            ? "Azure DevOps: sign in to see your pull requests"
            : spoken.isEmpty ? "Azure DevOps: nothing needs you" : "Azure DevOps: " + spoken.joined(separator: ", ")
        return MenuBarSegment(
            glyph: symbol, title: title, summary: summary, count: counts.needsYou,
            needsAttention: counts.needsYou > 0 || needsSignIn,
            // Like the counts it draws: none until you've signed in.
            states: needsSignIn ? StateCounts() : counts.states(showToReview: settings.showToReview),
            problem: needsSignIn ? summary : nil
        )
    }

    package var segmentsChanged: AnyPublisher<Void, Never> {
        changes.eraseToAnyPublisher()
    }

    /// Pull requests that need you (and those to review, while the menu bar shows them), that are failing, or that are
    /// ready to complete; pinned pipelines that failed or are running. The sprint's work isn't in any state.
    package func stateRows(for section: SectionID) -> [StateRow] {
        switch section {
        case .azureDevOpsPullRequests:
            guard let store, store.problem?.needsSignIn != true else { return [] }
            let showToReview = settings.showToReview
            return store.items.compactMap { item in
                item.group.state(showToReview: showToReview).map { state in
                    StateRow(id: item.id, state: state, date: item.since, view: environment(PullRequestRow(item: item)),
                             isReady: item.group == .ready)
                }
            }
        case .azureDevOpsPipelines:
            return (pipelines?.statuses ?? []).compactMap { status in
                status.state.map { state in
                    StateRow(id: status.id, state: state, date: status.latest?.changedAt, view: environment(PipelineRow(status: status)))
                }
            }
        default:
            return []
        }
    }

    package var stateRowsChanged: AnyPublisher<Void, Never> {
        rowChanges.eraseToAnyPublisher()
    }

    /// The same pull requests and pipelines, each in a sentence, as Azure DevOps' own brief says them. Apple
    /// Intelligence condenses a comment only while Summaries is on. A pull request's opens as a click on its row does: its
    /// details, at what it's about, in BriefBar's window from its Overview, and from the menu bar and widgets once you chose
    /// to Open Pull Requests in BriefBar; or else in Azure DevOps.
    package func briefLines(for section: SectionID) -> [BriefLine] {
        switch section {
        case .azureDevOpsPullRequests:
            guard let store, store.problem?.needsSignIn != true else { return [] }
            let showToReview = settings.showToReview
            let summarizes = settings.summaries
            let details = pullRequestDetails
            return store.items.compactMap { snapshot in
                guard let state = snapshot.group.state(showToReview: showToReview) else { return nil }
                let item = Brief.item(snapshot, reader: store.reader)
                return BriefLine(
                    id: "azureDevOps/" + item.id, source: id, state: state, date: snapshot.since, sentence: item.sentence,
                    request: summarizes ? item.prompt.map { BriefRequest(prompt: $0, instructions: Brief.instructions) } : nil,
                    open: { [weak store, weak details] in
                        if let details { details.open(snapshot) } else { store?.open(snapshot) }
                    },
                    show: { [weak details] in details.map { $0.reveal(snapshot, at: $0.about(snapshot)) } ?? false }
                )
            }
        case .azureDevOpsPipelines:
            guard let pipelines else { return [] }
            return pipelines.statuses.compactMap { status in
                status.state.map { state in
                    BriefLine(
                        id: "pipelines/\(status.id)/\(status.latest.map { String($0.id) } ?? "")", source: id, state: state,
                        date: status.latest?.changedAt,
                        sentence: status.briefSentence,
                        open: { [weak pipelines] in
                            if let latest = status.latest { pipelines?.open(latest) } else { pipelines?.open(status.pipeline) }
                        }
                    )
                }
            }
        default:
            return []
        }
    }

    package func panel(for section: SectionID) -> AnyView {
        switch section {
        case .azureDevOpsSprint: return environment(WorkPanelView(page: .sprint))
        case .azureDevOpsPipelines: return environment(WorkPanelView(page: .pipelines))
        default: return environment(MenuPanelView())
        }
    }

    package func page(for section: SectionID) -> AnyView {
        let page: AnyView = switch section {
        case .azureDevOpsSprint: environment(SprintPage())
        case .azureDevOpsPipelines: environment(PipelinesPage())
        default: environment(PullRequestsPage())
        }
        return AnyView(page.environment(\.panelStyle, .page))
    }

    package func panelWillShow(_ section: SectionID) {
        store?.refreshIfStale()
    }

    package func sectionVisibilityChanged(_ section: SectionID, isShowing: Bool, by viewer: SectionViewer) {
        // A pull request's details show on a window's Pull Requests page, and over a work item's details on its Sprint
        // page: the code their comments are on is read only while the window they're in shows that page on screen.
        if viewer.kind == .window, section == .azureDevOpsPullRequests || section == .azureDevOpsSprint {
            pullRequestCode?.setVisible(isShowing, for: PullRequestCodeStore.page(section, window: viewer.id))
        }
        // The sprint and pipelines are read only while something shows them.
        switch section {
        case .azureDevOpsSprint:
            sprint?.setVisible(isShowing, for: viewer.name)
            // Only a window's page shows a work item's details.
            if viewer.kind == .window {
                details?.setVisible(isShowing, for: viewer.name)
            }
            return
        case .azureDevOpsPipelines:
            pipelines?.setVisible(isShowing, for: viewer.name)
            return
        default:
            break
        }
        // What a popover or a window's page shows in Answered counts as seen once none shows it; a widget or the
        // menu bar's count doesn't.
        guard viewer.kind == .popover || viewer.kind == .window else { return }
        if isShowing {
            store?.viewerDidOpen(viewer.name)
        } else {
            store?.viewerDidClose(viewer.name)
        }
    }

    // MARK: Widgets

    package func widget(for section: SectionID, size: WidgetSize, rows: Int) -> AnyView {
        switch section {
        case .azureDevOpsSprint: return environment(SprintWidgetSection(rows: rows))
        case .azureDevOpsPipelines: return environment(PipelinesWidgetSection(rows: rows))
        default: return environment(WidgetSectionView(size: size, rows: rows))
        }
    }

    package func widgetHeight(for section: SectionID, rows: Int) -> CGFloat {
        switch section {
        case .azureDevOpsSprint: return SprintWidgetSection.height(rows: rows, options: services.interfaceOptions)
        case .azureDevOpsPipelines: return PipelinesWidgetSection.height(rows: rows, options: services.interfaceOptions)
        default: return WidgetSectionView.height(rows: rows, options: services.interfaceOptions)
        }
    }

    package func widgetWidth(for section: SectionID, size: WidgetSize) -> CGFloat {
        size.width
    }

    package func widgetMenu(for section: SectionID) -> AnyView {
        environment(SourceMenuContent())
    }

    package func openNotification(_ userInfo: [String: String]) {
        openNotification(userInfo, inWindow: false)
    }

    package func openNotificationInWindow(_ userInfo: [String: String]) {
        openNotification(userInfo, inWindow: true)
    }

    /// A click on one of its notifications: a task's, with your Copilot sessions; a pull request's, in BriefBar's window, at
    /// the comment or the run it's about, from the window's Notifications page, and from Notification Center once you chose
    /// to Open Pull Requests in BriefBar, while its list has it; or else in Azure DevOps.
    private func openNotification(_ userInfo: [String: String], inWindow: Bool) {
        // A task that just started: with your Copilot sessions, in the menu bar or a window, when they show.
        if userInfo[CopilotTasksStore.taskKey] != nil {
            if services.showPanel(.copilotSessions) { return }
            if services.hasPage(.copilotSessions) {
                services.openWindow(.copilotSessions)
                return
            }
        }
        if let link = userInfo["url"].flatMap(URL.init(string:)) {
            if inWindow || settings.opensPullRequestsInBriefBar,
               pullRequestDetails?.reveal(notification: userInfo["pullRequest"], link: link) == true {
                return
            }
            store?.openFromNotification(key: userInfo["pullRequest"], url: link)
        } else if inWindow, services.hasPage(.azureDevOpsPullRequests) {
            services.openWindow(.azureDevOpsPullRequests)
        } else if !services.showPanel(.azureDevOpsPullRequests) {
            // Hidden from the menu bar: the pull requests in Azure DevOps instead.
            store?.openPullRequestsPage()
        }
    }

    // MARK: Settings

    package func settingsView() -> AnyView {
        environment(AzureDevOpsSettings())
    }

    package func statusView() -> AnyView? {
        guard store != nil else { return nil }
        return environment(SignInStatusView().environmentObject(services.notifier))
    }

    // MARK: Rendering

    package func loadForRendering() async {
        let store = makeStores(notifier: nil)
        await store.loadOnce()
        await sprint?.loadOnce()
        await loadDetailsForRendering(store: store)
        await loadCodeForRendering(store: store)
        await pipelines?.loadOnce()
        await workLinks?.loadOnce()
        // Before Copilot's list loads, which shows them with the sessions.
        publishSentTasks()
        // The Copilot sessions of the pull requests whose details are drawn, read once: the first of yours that needs you
        // and the first that's failing; and, in the demo, which makes them up and reads nothing, every one, for the one
        // whose sessions ask which is its and the one whose session waits for your answer. Show Links' sessions are told
        // later, and they follow.
        let drawn = Self.detailsDrawn(in: store.items)
        await pullRequestSessions?.prepare(services.isDemo ? store.items : [drawn.yours, drawn.failing].compactMap { $0 })
        listDemoNotifications(from: store)
        // Let the on-device model word the brief before drawing.
        await store.summarizer.complete(store.brief.compactMap(store.briefRequest), timeout: 45)
    }

    /// The Sprint page with the details of your first story, of your first task, and of the first bug, read once, each in
    /// its own store, so the window's own picture of the page shows none; and, in the demo, the page of the bug's first
    /// pull request, of the story's first Copilot session, and of a session linked to the bug's pull request, over that
    /// pull request's page.
    private func loadDetailsForRendering(store: PRStore) async {
        guard let sprint, let board = sprint.board else { return }
        let story = board.rows.compactMap(\.parent).first { $0.isAssigned(to: board.me) } ?? board.rows.compactMap(\.parent).first
        let task = board.myWork.first { $0.parentId != nil } ?? board.myWork.first
        let bug = board.rows.compactMap(\.parent).first { $0.type.caseInsensitiveCompare("Bug") == .orderedSame }
        renderedDetails = []
        var rendered = [("sprint-details", story), ("sprint-task-details", task), ("sprint-bug-details", bug)]
        if store.mode == .demo {
            rendered += [("sprint-pull-request-page", bug), ("sprint-session-page", story), ("sprint-deep-page", bug)]
        }
        for (name, item) in rendered {
            guard let item else { continue }
            let details = WorkItemDetailsStore(mode: store.mode, client: store.client, board: sprint.$board.eraseToAnyPublisher())
            await details.loadOnce(item)
            renderedDetails.append((name, details))
        }
    }

    /// The Sprint page with a work item's details, beside the board, and over it in a narrow window; the window that sends
    /// a work item to Copilot, for the first of your work items not sent yet, and Send Work to Copilot's settings, which
    /// Settings' picture is too short to show; and, with Show Links, the window that links the first of your pull requests
    /// with links.
    package func extraRenderings() -> [(name: String, view: AnyView)] {
        var renderings: [(name: String, view: AnyView)] = []
        for (name, details) in renderedDetails {
            // A page over the details, of what Show Links links to them, now that every source told it; or a page over
            // another.
            if let item = details.selected, details.pages.isEmpty, name.hasSuffix("-page") {
                let path: [ItemRef.Kind] = name.contains("deep") ? [.pullRequest, .session] : name.contains("pull-request") ? [.pullRequest] : [.session]
                var trail = [item.linkRef]
                for kind in path {
                    guard let from = trail.last,
                          let next = services.links.connections(of: from).first(where: { $0.item.ref.kind == kind && !trail.contains($0.item.ref) })
                    else { break }
                    details.open(page: next.item.ref)
                    trail.append(next.item.ref)
                }
            }
            // The page as wide as in a big window, in BriefBar's window as it opens, and in a narrow one; with Where It
            // Stands folded to who it waits on; and a pull request's page taller, for the README's trail to scroll
            // down, and in a narrow window, where its details cover the board.
            let variants: [String: Set<String>] = [
                "sprint-details": ["-medium", "-narrow", "-folded"], "sprint-pull-request-page": ["-medium", "-narrow", "-tall"],
            ]
            for (suffix, size) in [
                ("", CGSize(width: 1_000, height: 720)), ("-medium", CGSize(width: 740, height: 700)), ("-narrow", CGSize(width: 560, height: 720)),
                ("-folded", CGSize(width: 1_000, height: 720)), ("-tall", CGSize(width: 1_000, height: 1_000)),
            ] {
                guard suffix.isEmpty || variants[name, default: []].contains(suffix) else { continue }
                let page = SprintPage()
                    .environmentObject(details)
                    .environment(\.whereItStandsFolded, suffix == "-folded" ? true : nil)
                    .environment(\.panelStyle, .page)
                    .textSize(from: services)
                    .frame(width: size.width, height: size.height)
                    .background(WindowBackdrop())
                    .environment(\.isRendering, true)
                renderings.append((name: name + suffix, view: environment(page)))
            }
        }
        renderings += pullRequestDetailsRenderings()
        renderings += pullRequestThreadRenderings()
        renderings += commentActionRenderings()
        if let copilot, let item = sprint?.board?.myWork.first(where: { copilot.latest(for: $0) == nil }) {
            let composer = CopilotComposerView(item: item.copilotTask, options: settings.copilotOptions, template: settings.copilotPromptTemplate) {}
                .environment(\.isRendering, true)
            let options = Form { CopilotSetting() }
                .formStyle(.grouped)
                .environment(\.inSettingsForm, true)
                .frame(width: 600)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .windowBackgroundColor))
            renderings += [(name: "copilot-composer", view: environment(composer)), (name: "copilot-settings", view: environment(options))]
        }
        if copilot != nil, let composer = sessionComposer() {
            renderings.append((name: "copilot-composer-session", view: environment(composer.environment(\.isRendering, true))))
        }
        let links = services.links
        if let linked = store?.items.first(where: { !links.connections(of: $0.key.linkRef).isEmpty }) {
            let picker = LinkPickerView(subject: linked.key.linkRef, links: links) {}
                .background(Color(nsColor: .windowBackgroundColor))
            renderings.append((name: "link-picker", view: AnyView(picker)))
        }
        // The pull requests by when each was created, the oldest first, in the menu bar's list and on the window's page,
        // whatever order the settings have.
        if let store, !store.items.isEmpty {
            let panel = MenuPanelView(order: .oldestFirst)
                .background(Color(nsColor: .windowBackgroundColor))
            let page = PullRequestsPage(order: .oldestFirst)
                .environment(\.panelStyle, .page)
                .textSize(from: services)
                .frame(width: 780, height: 900)
                .background(WindowBackdrop())
                .environment(\.isRendering, true)
            renderings += [(name: "pull-requests-oldest-first", view: environment(panel)),
                           (name: "pull-requests-oldest-first-page", view: environment(page))]
        }
        return renderings
    }

    /// The window that sends the comments that wait on you to one of the Copilot app's sessions, which BriefBar's extension
    /// listens in, for the first of your pull requests with such comments: a made-up session on its branch.
    private func sessionComposer() -> CopilotComposerView? {
        guard let record = store?.records.first(where: { PullRequestTasks.actions(for: $0, canShip: false).contains(.fixComments) }) else {
            return nil
        }
        let pr = record.pullRequest
        let task = TaskPullRequest(
            organization: pr.key.organization, project: pr.projectName, repository: pr.repositoryName, id: pr.key.number,
            title: pr.title, url: pr.webURL, sourceBranch: pr.sourceBranch, targetBranch: pr.targetBranch,
            projectId: pr.projectId, repositoryId: pr.repositoryId
        )
        let session = AppSession(
            id: "7d3f9a12-4c8e-4b61-9f2a-5e0c1b8d6a31", name: pr.title, projectName: pr.repositoryName, branch: pr.sourceBranch,
            lastActive: Date().addingTimeInterval(-25 * 60)
        )
        let choice = SessionChoice(
            kind: .app(session), name: session.name, place: CopilotTasksStore.place(of: session), lastActive: session.lastActive,
            reasons: [.recordedByCopilot, .onItsBranch]
        )
        return CopilotComposerView(
            subject: .pullRequest(task, .fixComments), options: settings.copilotOptions, template: settings.copilotPromptTemplate,
            prompt: PullRequestPrompt.fixComments(record, workplace: .worktree),
            sessionPrompt: PullRequestPrompt.fixComments(record, workplace: .agent), createdAt: pr.createdAt,
            session: (choice, .listening(canFork: true))
        ) {}
    }

    /// The Pull Requests page with a pull request's details: the first of yours that needs you, beside the list as in a big
    /// window and in BriefBar's window as it opens, over it in a narrow one, all of it in a tall one, and with the page of
    /// the first work item linked to it over them; the first that's failing; and, for the line of its Copilot session, the
    /// first of yours with merge conflicts, whose two sessions ask which is its, and the one whose session waits for your
    /// answer. Each in a store of its own, so the window's own picture of the page shows none.
    private func pullRequestDetailsRenderings() -> [(name: String, view: AnyView)] {
        guard let store else { return [] }
        // The sessions as Show Links has them now that every source told it.
        pullRequestSessions?.updateAll()
        let (yours, failing) = Self.detailsDrawn(in: store.items)
        let asking = store.items.first { item in
            if case .ask? = pullRequestSessions?.session(for: item.key)?.pick { return true }
            return false
        }
        let waiting = store.items.first { item in
            guard let choice = pullRequestSessions?.session(for: item.key)?.session, let ref = ItemRef.session(choice.id) else { return false }
            return services.links.describe(ref).state == .needsYou
        }
        let wide = CGSize(width: 1_000, height: 720)
        let shown: [(name: String, item: PRSnapshot?, sizes: [(suffix: String, size: CGSize)], page: ItemRef.Kind?)] = [
            ("pull-requests-details", yours, [
                ("", wide), ("-medium", CGSize(width: 820, height: 680)), ("-narrow", CGSize(width: 560, height: 720)),
                ("-tall", CGSize(width: 1_000, height: 1_500)),
            ], nil),
            ("pull-requests-details-page", yours, [("", wide)], .workItem),
            ("pull-requests-failing-details", failing, [("", wide), ("-tall", CGSize(width: 1_000, height: 1_100))], nil),
            ("pull-requests-session-question", asking, [("", wide), ("-narrow", CGSize(width: 560, height: 720))], nil),
            ("pull-requests-session-waiting", waiting, [("", wide)], nil),
        ]
        var renderings: [(name: String, view: AnyView)] = []
        for (name, item, sizes, page) in shown {
            guard let item else { continue }
            let details = PullRequestDetailsStore()
            details.readRecord = { [weak store] key in store?.record(for: key) }
            details.itemsChanged(store.items)
            details.show(item)
            if let page {
                guard let linked = services.links.connections(of: item.key.linkRef).first(where: { $0.item.ref.kind == page }) else {
                    continue
                }
                details.open(page: linked.item.ref)
            }
            for (suffix, size) in sizes {
                let view = PullRequestsPage()
                    .environmentObject(details)
                    .environment(\.panelStyle, .page)
                    .textSize(from: services)
                    .frame(width: size.width, height: size.height)
                    .background(WindowBackdrop())
                    .environment(\.isRendering, true)
                renderings.append((name: name + suffix, view: environment(view)))
            }
        }
        return renderings
    }

    /// The pull requests whose details are drawn whatever their sessions: the first of yours that needs you, or else the
    /// first; and the first that's failing.
    private static func detailsDrawn(in items: [PRSnapshot]) -> (yours: PRSnapshot?, failing: PRSnapshot?) {
        (items.first { $0.group == .needsYou && $0.role == .author } ?? items.first, items.first { $0.group == .failing })
    }
}

// MARK: - The code of comment threads, for --render

extension AzureDevOpsSource {
    /// The pull requests whose details `--render` draws: the first of yours that needs you, and the first that's failing.
    private func renderedPullRequests(_ store: PRStore) -> [PRSnapshot] {
        let yours = store.items.first { $0.group == .needsYou && $0.role == .author } ?? store.items.first
        let failing = store.items.first { $0.group == .failing }
        return [yours, failing].compactMap { $0 }
    }

    /// Reads the code of their threads before `--render` draws them, as it would read as they came on screen in a window
    /// that shows them: the open ones', and, in the demo, the resolved ones' too, and those of every pull request whose page
    /// a work item's details can show.
    func loadCodeForRendering(store: PRStore) async {
        guard let code = pullRequestCode else { return }
        let items = store.mode == .demo ? store.items : renderedPullRequests(store)
        for item in items {
            guard let record = store.record(for: item.key),
                  let threads = record.details?.threads.filter({ !$0.isResolved || store.mode == .demo }),
                  threads.contains(where: ThreadCode.isOnLines)
            else { continue }
            // Held while `--render` draws.
            _ = code.hold(item.key)
            await code.readAll(threads, of: record.pullRequest)
        }
    }

    /// The Pull Requests page with the details of the first of your pull requests that needs you, taken to the first of
    /// its threads with code, as from elsewhere, and in a narrow window; and to the first of its resolved threads whose
    /// code changed since, which unfolds them.
    func pullRequestThreadRenderings() -> [(name: String, view: AnyView)] {
        guard let store, let code = pullRequestCode, let item = renderedPullRequests(store).first else { return [] }
        let threads = PullRequestPanel(item, record: store.record(for: item.key)).threads
        let open = (threads.waitingOnYou + threads.open).first { ThreadCode.isOnLines($0.thread) }
        let changed = threads.resolved.first { thread in
            if case .read(let excerpt)? = code.state(of: thread.id, in: item.key) { excerpt.changedSince == true } else { false }
        }
        let shown: [(name: String, thread: PullRequestPanel.Thread?, sizes: [(suffix: String, size: CGSize)])] = [
            ("pull-requests-details-thread", open, [("", CGSize(width: 1_000, height: 720)), ("-narrow", CGSize(width: 560, height: 720))]),
            ("pull-requests-details-resolved", changed, [("", CGSize(width: 1_000, height: 1_100))]),
        ]
        var renderings: [(name: String, view: AnyView)] = []
        for (name, thread, sizes) in shown {
            guard let thread else { continue }
            for (suffix, size) in sizes {
                // A store for each, since each scrolls its details to the thread once.
                let details = PullRequestDetailsStore()
                details.readRecord = { [weak store] key in store?.record(for: key) }
                details.itemsChanged(store.items)
                details.show(item, at: .thread(thread.id))
                let view = PullRequestsPage()
                    .environmentObject(details)
                    .environment(\.panelStyle, .page)
                    .textSize(from: services)
                    .frame(width: size.width, height: size.height)
                    .background(WindowBackdrop())
                    .environment(\.isRendering, true)
                renderings.append((name: name + suffix, view: environment(view)))
            }
        }
        return renderings
    }
}

// MARK: - Asking Copilot about comments, for --render

extension AzureDevOpsSource {
    /// The Pull Requests page with the details of the first of your pull requests that needs you, taken to its first thread
    /// that waits on you, with what you can ask Copilot about it, in each state: Explain and Fix on it, with what Copilot did
    /// about another thread above them, and the fixes ready to push at the foot; Explain's composer open, then asking, then
    /// answered; Fix's composer open, on it and on a thread with a suggested change; Copilot fixing it, in its session and in
    /// a fork of it; fixed; failing; and Fix All's composer open. In a narrow window too, for the first two. Each from made-up
    /// states, through `CommentActionsPreview`: nothing's sent or asked.
    func commentActionRenderings() -> [(name: String, view: AnyView)] {
        guard let store, store.mode == .demo, let item = renderedPullRequests(store).first, let record = store.record(for: item.key) else {
            return []
        }
        let threads = PullRequestPanel(item, record: record).threads
        guard let waiting = threads.waitingOnYou.first(where: { ThreadCode.isOnLines($0.thread) }) else { return [] }
        let suggested = threads.open.first { CommentSuggestion.latest(in: $0.thread, me: record.me) != nil }
        let now = Date()
        let session = SentPrompt.demoSession
        let fork = "5c1e7a90-3b2d-4f68-9a1c-2e8d7b6f4a05"
        func work(_ state: CommentWork.State, ago minutes: Double, forkedFrom: String? = nil) -> CommentWork {
            CommentWork(
                purpose: .fix, state: state, session: forkedFrom == nil ? session : fork, forkedFrom: forkedFrom, isTask: false,
                since: now.addingTimeInterval(-minutes * 60)
            )
        }
        let question = "Isn't 30 seconds too short when the provider is down for minutes?"
        let how = "Cap it with a MaxDelay on RetryOptions, as Priya suggests, 30 seconds by default"
        let ready = suggested.map { [ReadyFixes(session: session, forkedFrom: nil, isTask: false, threads: [waiting.id, $0.id], latest: now)] }
        var shown: [(name: String, thread: Int, preview: CommentActionsPreview, sizes: [(suffix: String, size: CGSize)])] = [
            ("pull-requests-comment-actions", waiting.id, CommentActionsPreview(), [("", CGSize(width: 1_000, height: 900)), ("-narrow", CGSize(width: 560, height: 900))]),
            ("pull-requests-comment-explain", waiting.id, CommentActionsPreview(composers: [
                .init(thread: waiting.id, ask: .explain, text: question, destination: .session(session)),
            ]), [("", CGSize(width: 1_000, height: 900)), ("-narrow", CGSize(width: 560, height: 900))]),
            ("pull-requests-comment-explaining", waiting.id, CommentActionsPreview(questions: [
                waiting.id: .init(session: session, asked: question, askedAt: now.addingTimeInterval(-40), state: .asking),
            ]), [("", CGSize(width: 1_000, height: 900))]),
            ("pull-requests-comment-answer", waiting.id, CommentActionsPreview(questions: [
                waiting.id: .init(
                    session: session, asked: question, askedAt: now.addingTimeInterval(-150),
                    state: .answered(DemoData.explanation(ofThread: waiting.id, pullRequest: item.key.number)), endedAt: now.addingTimeInterval(-90)
                ),
            ]), [("", CGSize(width: 1_000, height: 1_100))]),
            ("pull-requests-comment-fix", waiting.id, CommentActionsPreview(composers: [
                .init(thread: waiting.id, ask: .fix, text: how, destination: .session(session)),
            ]), [("", CGSize(width: 1_000, height: 900)), ("-narrow", CGSize(width: 560, height: 900))]),
            ("pull-requests-comment-fixing", waiting.id, CommentActionsPreview(work: [waiting.id: work(.working("Run PaymentsClientTests"), ago: 2)]),
             [("", CGSize(width: 1_000, height: 900))]),
            ("pull-requests-comment-fork", waiting.id, CommentActionsPreview(work: [waiting.id: work(.working(nil), ago: 2, forkedFrom: session)]),
             [("", CGSize(width: 1_000, height: 900))]),
            ("pull-requests-comment-fixed", waiting.id, CommentActionsPreview(
                work: [waiting.id: work(.done("Capped the backoff at RetryOptions.MaxDelay, 30 seconds by default. The tests pass."), ago: 1)],
                ready: ready
            ), [("", CGSize(width: 1_000, height: 900))]),
            ("pull-requests-comment-failed", waiting.id, CommentActionsPreview(
                work: [waiting.id: work(.failed("The build failed: CS0103 The name 'MaxDelay' does not exist in the current context."), ago: 3)]
            ), [("", CGSize(width: 1_000, height: 900))]),
        ]
        if let suggested {
            shown.append(("pull-requests-comment-suggestion", suggested.id, CommentActionsPreview(
                composers: [.init(thread: suggested.id, ask: .fix, text: "", destination: .session(session), appliesSuggestion: true)],
                quiet: [suggested.id], ready: []
            ), [("", CGSize(width: 1_000, height: 900))]))
        }
        var renderings: [(name: String, view: AnyView)] = []
        for (name, thread, preview, sizes) in shown {
            for (suffix, size) in sizes {
                renderings.append((name: name + suffix, view: environment(commentsPage(item, at: thread, preview: preview, size: size))))
            }
        }
        // Fix All's composer, under the comments' heading.
        let fixAll = CommentActionsPreview(composers: [.init(thread: nil, ask: .fixAll, text: "Keep the public API as it is", destination: .session(session))])
        let details = PullRequestDetailsStore()
        details.readRecord = { [weak store] key in store?.record(for: key) }
        details.itemsChanged(store.items)
        details.show(item, at: .section(.comments))
        renderings.append((name: "pull-requests-comments-fix-all", view: environment(page(details, preview: fixAll, size: CGSize(width: 1_000, height: 900)))))
        return renderings
    }

    /// The Pull Requests page with a pull request's details taken to one of its threads, in a store of its own, since each
    /// scrolls its details there once.
    private func commentsPage(_ item: PRSnapshot, at thread: Int, preview: CommentActionsPreview, size: CGSize) -> some View {
        let details = PullRequestDetailsStore()
        details.readRecord = { [weak store] key in store?.record(for: key) }
        details.itemsChanged(store?.items ?? [])
        details.show(item, at: .thread(thread))
        return page(details, preview: preview, size: size)
    }

    private func page(_ details: PullRequestDetailsStore, preview: CommentActionsPreview, size: CGSize) -> some View {
        PullRequestsPage()
            .environmentObject(details)
            .environment(\.commentActionsPreview, preview)
            .environment(\.panelStyle, .page)
            .textSize(from: services)
            .frame(width: size.width, height: size.height)
            .background(WindowBackdrop())
            .environment(\.isRendering, true)
    }
}

/// How the Azure CLI's sign-in and notifications stand, on Azure DevOps' page in Settings.
struct SignInStatusView: View {
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var notifier: Notifier

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(
                ok: store.problem?.offersSignIn != true, title: signInTitle, detail: signInDetail,
                action: store.problem?.offersSignIn == true
                    ? (store.problem == .cliNotFound ? "Install the Azure CLI…" : "Sign In…") : nil
            ) { store.signIn() }
            if settings.notifications && notifier.isAvailable {
                row(
                    ok: !store.notificationsBlocked,
                    title: store.notificationsBlocked ? "Notifications are off for BriefBar" : "Notifications are on",
                    detail: store.notificationsBlocked
                        ? "Allow them in System Settings, or turn Notifications off below."
                        : "For replies, mentions, reviews, failing builds and pull requests that are ready.",
                    action: store.notificationsBlocked ? "Open System Settings…" : nil
                ) { Notifier.openSystemSettings() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { notifier.refreshStatus() }
    }

    private var signInTitle: String {
        guard let problem = store.problem, problem.offersSignIn else {
            return store.hasLoaded ? "Signed in with the Azure CLI" : "Checking the Azure CLI's sign-in…"
        }
        if problem == .cliNotFound { return "The Azure CLI isn't installed" }
        return problem.needsSignIn ? "Not signed in to the Azure CLI" : "Not signed in to every organization's directory"
    }

    private var signInDetail: String {
        guard let problem = store.problem, problem.offersSignIn else { return "It renews itself, usually for months." }
        // Which organizations, without their directory's ID.
        return problem.needsSignIn ? "BriefBar reads Azure DevOps with the Azure CLI's sign-in." : problem.message
    }

    private func row(ok: Bool, title: String, detail: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(style: .headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action {
                Button(action, action: perform)
            }
        }
    }
}

/// The Sprint or Pipelines section in a menu-bar item's popover: its widget's rows, every one of them, under a title that
/// opens its page in BriefBar's window, where there's room for the whole board. The sprint's footer opens its task
/// board in Azure DevOps.
struct WorkPanelView: View {
    let page: AzureDevOpsPage
    @EnvironmentObject private var sprint: SprintStore
    @EnvironmentObject private var pipelines: PipelinesStore

    @LocalState private var contentHeight: CGFloat = 0
    private static let maxListHeight: CGFloat = 560

    private var rows: Int {
        switch page {
        case .sprint: max(sprint.board?.myWork.count ?? 0, 2)
        default: max(pipelines.statuses.count, 2)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                section
                    .padding(.bottom, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .panelListHeight(contentHeight, max: Self.maxListHeight)
            Divider()
            footer
        }
        .panelFrame(width: MenuPanelView.width)
    }

    @ViewBuilder
    private var section: some View {
        switch page {
        case .sprint: SprintWidgetSection(rows: rows, draggable: false)
        default: PipelinesWidgetSection(rows: rows, draggable: false)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if page == .sprint {
                Button {
                    sprint.openBoard()
                } label: {
                    Label("Open Task Board", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .disabled(sprint.board == nil)
                .help("Open the sprint's task board in Azure DevOps")
            }
            Spacer()
            Menu {
                SettingsMenuContent()
            } label: {
                Image(systemName: "gearshape")
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
