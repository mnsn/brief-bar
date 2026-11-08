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
    /// 12: a pull request's build, when you open it in its details: its steps and errors, its log's end, its tests, and
    /// the pipeline's other runs.
    /// 13: the Copilot sessions a pull request's work could go to, as its details show on screen, and the one you
    /// choose for it.
    /// 14: a pull request's whole change, in its details' Files: which files it touched, and each one before and after it.
    /// 15: asking a session about a comment, which sends its conversation, with the comment and its code, to GitHub Copilot;
    /// the forks BriefBar still has to delete; and following a prompt about comments in the Copilot app's session it went to.
    /// 16: asking a session about a failed build, and having Copilot fix it, which send what its details read of it: its
    /// errors, the messages and stack traces of the first tests that failed, and the end of its log; and the builds and
    /// conflicts that tasks and prompts take on.
    /// 17: which files conflict with a pull request's target branch, and how, as its details show it; and asking a
    /// session about them, or having Copilot resolve them, which send those files' paths and how each conflicts.
    /// 18: Make Changes in Azure DevOps, the first changes BriefBar makes there: your reply in a pull request's comment
    /// thread, and a thread's status, each when you click it; what you write in a reply, kept in memory until it's sent;
    /// and Fix Grammar, which sends the reply to GitHub Copilot when you choose a Copilot model for it.
    /// 19: pull requests' tags: those their lists carry, and, for one read on its own, one request as its details show; with
    /// Make Changes in Azure DevOps, a tag you add or remove, when you click it, and the tags you add, kept to suggest them.
    /// 21: with Updates from Copilot Sessions on, what a Copilot session says it changed in Azure DevOps, read again sooner
    /// than the next refresh. (20 went unused.)
    /// 22: the comment threads you mark as read in a pull request's details, kept with what you've seen.
    /// 23: what's read again, as it was all along: a pull request's updates and Files while its details show, whenever its
    /// branch or its target moves; a build you opened, when Azure DevOps merges its pull request again as its target moves;
    /// and tags whose read failed, half a minute later, while they show.
    /// 24: with Make Changes in Azure DevOps, your own comment edited, a PATCH of what it says, or deleted, a DELETE of it,
    /// each when you click it; what you write in place of one, kept in memory until it's saved; and Fix Grammar there, which
    /// sends it to GitHub Copilot when you choose a Copilot model for it.
    nonisolated package static let descriptionVersion = 24

    package let id = SourceID.azureDevOps
    package let name = "Azure DevOps"
    package let symbol = "arrow.triangle.pull"
    package let description = SourceDescription(
        version: AzureDevOpsSource.descriptionVersion,
        summary: "Your pull requests: which need you, which are failing and which are ready to complete; and your team's sprint and your pipelines",
        reads: "Your pull requests and the ones you review, in the organizations you choose, and the ones you watch, by their links, with their tags, builds, policies and comment threads, from Azure DevOps; and, after you merge one, while Done keeps it, the runs of the pipelines that build its merge and of the ones those start, unless you turn Follow Pipelines After You Merge off. While its Sprint or Pipelines section is on screen: your team's current sprint, with its stories, bugs and tasks and who has them, and the recent runs of the pipelines you pin; for Pipelines, also the latest validation runs of each active pull request you authored, including their stages, failure details and commit information. When you open one of its work items: its fields, description and other text, the work items it links to, its attachments' names and its latest comments, which BriefBar keeps in memory only, and forgets a quarter of an hour after reading them unless they're still on screen. New: when you open a pull request's details: for each comment thread on lines of code, as it comes on screen, the file it's on, before and after the change the comment was made on, and which files each update of the pull request changed, read again whenever its branch or its target moves, which BriefBar keeps in memory only, while those details show. New: as their Files come on screen, which files the pull request's change touched, all of it or what changed since you last looked, again whenever its branch or its target moves; and, one file at a time, each file whose row comes on screen, before and after the change, to count the lines it adds and removes, and the file you open, to show its changes, which BriefBar keeps in memory only too. New: when you open a pull request's build that failed or is still going, in its details: its run, its steps and their errors, the last 200 lines of the log of the step that failed, the tests it published, with the names, messages and stack traces of the first that failed, and the pipeline's other runs on the pull request and its latest on the target branch, to tell whether the failure is the change's doing, again as it finishes or runs again, and whether it ran again as its pull request or its target moves. BriefBar keeps them in memory only, for the last 20 builds you opened, until you open others, someone else signs in or you turn Azure DevOps off. New: when you open the details of a pull request that has merge conflicts: which files conflict with its target branch, and how, read again once its branch or its target moves, which BriefBar keeps in memory only, while those details show. New: your pull requests' tags, which the lists BriefBar reads carry; and, for a pull request they don't carry, such as one sent to you or that you watch, its tags, with one request as its details come on screen in BriefBar's window, every ten minutes while they stay there, and half a minute after a read of them failed. BriefBar keeps which pull requests you've seen, your organizations, the pull requests you watch, your team and your pipelines. New: it keeps the comment threads you mark as read in a pull request's details too, by their IDs, with what you've seen of it, and forgets them with it; for a pull request sent to you in a chat, in memory only. When Apple Intelligence is on, a brief of what needs you is written on your Mac by Apple's on-device model. Only if you turn on Pull Requests Sent in Chats: the notifications every app posts to Notification Center, for links to pull requests, of which BriefBar keeps only the links, with who sent them, in which app and when, never the messages, and only in memory. Only if you turn on Send Work to Copilot, and send a work item or a pull request: the git repository you choose, and Copilot's log of the session it starts or goes on with, until it ends; for a pull request's failed build, the run's timeline, for its errors; and, as the window that sends it opens, the Copilot app's sessions it could go to instead, read-only from ~/.copilot: their names, projects and branches, the pull requests the app records with them and which run a turn now, from its database; the folder each works in, from its session state; which ones the app has open; and which of those active lately link to it in their logs. Only if you also turn on Send Prompts to Copilot Sessions, in Settings › Agents, and send a prompt to a session or a fork of it, or stop what one you sent is at there: which sessions BriefBar's extension listens in, and what it says became of the prompt, or of stopping it, from files only you can read in BriefBar's own folder, which the prompt goes through too, until the extension is done with it; and, for a fork, which session the Copilot app records it came from, and when it was made. BriefBar keeps which work items and pull requests you sent, what for, where, with which model, and the pull request Copilot opened; and, in a file only you can read, what Copilot printed when it ended. New: right before a Push & Reply goes to a session, the pull request, with one request, for the branch it merges into, and again once git has checked, and, when Azure DevOps names another than the list has read, your lists again then, with that pull request's details, rather than at their next refresh; the pull request's branch and that one, fetched with git into the clone that session works in, and which commits a merge in what it would push brings in, to check that none is missing from that branch; and, for one of the Copilot app's sessions, which of them run a turn now, from its database, until the prompt goes. Nothing goes when one is missing, when the pull request merges into another branch than its prompt names, while a turn runs in that session or in its checkout, or when BriefBar can't tell. New: only if you turn on Send Work to Copilot, as a pull request's details come on screen and every ten seconds while they stay there: what the window that sends work reads of the Copilot app's sessions it could go to, to name the one its work goes to; and, only if you also turn on Send Prompts to Copilot Sessions, which sessions BriefBar's extension listens in, to say how a prompt would reach that one. BriefBar keeps the session you choose for a pull request's work, by its ID only. New: only if you turn on Send Work to Copilot: when you send a prompt about a pull request's comments, builds or merge conflicts to one of the Copilot app's sessions, or to a fork of it, or BriefBar copies it for you to paste there, every few seconds from then until Copilot is done with it, to say on each comment or build, or on the conflicts, what became of it: that session's log and whether something has it open, with, for one it copied, the messages sent the session since, to tell the one you pasted it in, which BriefBar compares in memory only; which of the app's sessions run a turn now, from its database; and, for one copied as /fork, the fork the app records it made of the session, and when. When you ask a session about a comment with Explain, the session's conversation, which the Copilot CLI copies into a fork it deletes after, goes to GitHub Copilot with the comment and its code, and the answer stays in memory only. New: when you ask a session about a failed build with Explain the Failure, the same goes with what BriefBar read of the build as you opened it in its details: its errors, the messages and stack traces of the first tests that failed, the last 40 lines of the log of the step that failed, and whether it's the change's doing; and the prompt that has Copilot fix a build you opened there quotes them too. New: when you ask a session about a pull request's merge conflicts with Explain, the same goes with which files conflict and how, as its details read them; and the prompt that has Copilot resolve them lists them too. BriefBar keeps the comment threads, builds and conflicts each task or prompt took on, and which session a prompt about them went to and when, by their IDs only, with, for conflicts, the name of the branch the pull request targeted then, to tell when it targets another; when each Push & Reply in a task's session ran, and how it ended; and the IDs of the forks it made to ask a session about a comment, a build or merge conflicts, until it has deleted them. New: only if you turn on Make Changes in Azure DevOps, BriefBar keeps what you write in a reply to a pull request's comment thread, or in place of a comment of yours as you edit it, in memory only, until you send or save it, turn it off or quit; resolving a thread there sees its pull request, as opening it does; and BriefBar keeps the tags you add to pull requests, up to 20 for each project, by the project's ID, in its settings, to suggest them as you add one, until you turn it off. Only if you turn on Show Links: the work items linked to each of your pull requests, the pull requests linked to the sprint's work items while the sprint is on screen, and what the linked work items and pull requests that your lists don't show are; BriefBar keeps the links you add or hide, as references only, never titles. New: only if you turn on Pull Request Order as well as Show Links: for the work items linked to your pull requests, also their parent and their place in the backlog, and, to name a story's mission, what those parents are when BriefBar hasn't read them already, read as the linked work items are. BriefBar keeps none of it. New: only if you turn on Pull Request Order: while Apple Intelligence is on, Apple's on-device model names its missions, on this Mac, from the titles of their pull requests, work items and stories, and of the Copilot sessions on them, and, from the same titles, suggests splitting a mission whose pull requests look like different pieces of work, which moves nothing until you click Split. BriefBar keeps those names and suggestions in memory only, and, in its preferences, the names you give missions and the suggestions you keep together, each as digests of what its mission is made of, never a title. Only when a summary is written, or, for one ten minutes old or more, again as you open it, to tell whether it's still current: for the things it sums up, each pull request's description and comment threads, and each work item's details, as when you open one. With Apple Intelligence, what a summary is written from stays on this Mac; with a Copilot model, BriefBar sends it to GitHub Copilot through the Copilot CLI, which keeps a copy in its session history. BriefBar keeps none of it. New: only if you turn on Updates from Copilot Sessions, in Settings › Agents: when a Copilot session tells BriefBar it changed something in Azure DevOps, BriefBar reads it again then, rather than at its next refresh: the same requests its lists, the sprint and Show Links make, for the pull requests and work items the session names, at most every 30 seconds. New: only if you turn on Pull Request Order: each pull request's stage, In progress, Your review, Teammate's review, Can merge or Waits for another PR, worked out from what BriefBar reads already and what Copilot's sessions do; and the stages you set, kept in its preferences for each Azure DevOps account you sign in with, or in memory only for a pull request someone sent you in a chat, by reference, with only what would end each: for In progress, its commit; for Teammate's review, the votes it was set over, never who cast them (on someone else's, your own vote and its commit); until new commits or votes end them, you change them, the pull request merges or closes, or no list has had it for 30 days. None of it goes to Azure DevOps.",
        network: "Azure DevOps only: dev.azure.com, and app.vssps.visualstudio.com to find your organizations, with your Azure CLI sign-in. Every request is a GET, so it changes nothing there, but, new, only if you turn on Make Changes in Azure DevOps, six changes, each only when you click it in a pull request's details, as you: your reply in a comment thread, a POST of it, a thread's status, a PATCH of it, and a comment of yours, edited, a PATCH of what it says, or deleted, a DELETE of it, after which BriefBar reads the pull request again, two requests; and a tag you add to a pull request, a POST of its name, or take off it, a DELETE, after which BriefBar reads its tags again, one request; never anything else, by itself, or for agents. About 10 to 25 small requests a minute, a few more while the Sprint or Pipelines section is on screen, two or three when you open a work item's details and when it changes while they show, one for the tags of a pull request your lists don't carry, such as one sent to you or that you watch, as its details come on screen, every ten minutes while they stay there, and half a minute after a read of them failed, a few for each comment thread on code that comes on screen in a pull request's details (its updates and the files they changed, read once, and again whenever its branch or its target moves, and the file before and after the change, each read once, up to 1 MB), and for their Files, two to list the files the change touched, again whenever its branch or its target moves, and two for each file, one file at a time, as its row comes on screen or you open it (the file before and after the change, each read once, up to 1 MB), about ten when you open a pull request's build in its details, up to fourteen for one with hundreds of test runs, and again once it finished or runs again, or when you open it again, someone pushes to its pull request or retargets it, or its target moves and Azure DevOps merges it again, but then at most one, to tell whether it ran again since, within ten minutes of reading it, or half a minute while it's going, one when you open the details of a pull request with merge conflicts, to list the files that conflict, or one for each hundred of them, and again once its branch or its target moves, two as a Push & Reply goes, to read which branch its pull request merges into right before git checks what it would push and again right after, and, when that's another than the list has read, a refresh then rather than at the next, with that pull request's details, a few more after you merge a pull request, while its pipelines run, and, with Show Links on, one for each pull request's work items every quarter of an hour, a few for the sprint's links while it's on screen, with Pull Request Order on too one more for every 200 stories BriefBar hasn't read already, every quarter of an hour, and, as a summary is written, or checked as you open one ten minutes old or more, up to two for each pull request it sums up and two or three for each work item whose details aren't on screen. When a summary is written with a Copilot model, the Copilot CLI sends what it covers to GitHub Copilot. When you ask a Copilot session about a comment, a failed build or merge conflicts, the Copilot CLI sends the session's conversation, with the comment and its code, what BriefBar read of the build, or which files conflict and how, to GitHub Copilot, as one premium request. New: when you choose a Copilot model for Fix Grammar, in a reply or a comment you edit, and use it, the Copilot CLI sends what you wrote to GitHub Copilot, as one premium request, in a session it keeps, named BriefBar grammar fix; with Apple Intelligence, it stays on this Mac. When you send a work item or a pull request to Copilot, BriefBar itself still connects nowhere, but the programs it starts for you do: git fetches the repository, and, right before a Push & Reply goes, the pull request's branch and the one it merges into, into the clone its session works in; and the Copilot CLI uses GitHub Copilot and your MCP servers, pushes a branch, opens a pull request or replies on one, as you.",
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
    /// What writes its store's brief; nil for one that asks the on-device model.
    private let summarizer: Summarizer?
    /// Made when Azure DevOps starts, so its notifications count from then.
    private(set) var store: PRStore?
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
    /// The builds opened in a pull request's details, and what's read of them.
    private var buildInvestigations: BuildInvestigationStore?
    /// The code that pull requests' comment threads are on, read as they come on screen in their details.
    private var pullRequestCode: PullRequestCodeStore?
    /// Pull requests' changed files and their diffs, read as their Files come on screen, through the same readers.
    private var pullRequestFiles: PullRequestFilesStore?
    /// The files that conflict with pull requests' target branches, read as their details show them, while the code store
    /// lets them read.
    private var pullRequestConflicts: PullRequestConflictsStore?
    /// The Copilot session of the pull request whose details show.
    private var pullRequestSessions: PullRequestSessions?
    /// What you ask Copilot sessions about pull requests' comment threads with Explain, and their answers, in memory.
    private var copilotQuestions: CopilotQuestions?
    /// Your replies in pull requests' threads and their statuses, with Make Changes in Azure DevOps on, and what you write.
    private var threadChanges: ThreadChanges?
    /// Pull requests' tags as you change them, with Make Changes in Azure DevOps on, and the tags their lists don't carry.
    private var tagChanges: TagChanges?
    /// What you wrote in pull requests' details' Copilot composers, and where the threads you changed there were.
    private(set) var detailsDrafts: DetailsDrafts?
    /// For `--render`: each picture has drafts of its own, as if it were the only one shown, rather than what an earlier
    /// picture of the same pull request left there, such as its resolved threads unfolded.
    private var picturesHaveTheirOwnDrafts = false
    /// Tells Pull Request Order what Azure DevOps shows, while it's on.
    private var orderFacts: PullRequestOrderFacts?
    /// Reads again sooner what Copilot sessions say they changed, with Updates from Copilot Sessions on.
    private var agentRereads: AgentRereads?
    /// For `--render`: the Sprint page with a story's details, and with a task's.
    private var renderedDetails: [(name: String, details: WorkItemDetailsStore)] = []
    /// For `--render`: a pull request's details with a build open, one that failed and one still going.
    private var renderedInvestigations: [(name: String, item: PRSnapshot, investigations: BuildInvestigationStore)] = []
    /// For `--render`, in the demo: lists of their own, each with your reply or a status made on a thread, what makes them,
    /// and the thread.
    private var renderedChanges: [(name: String, store: PRStore, changes: ThreadChanges, pullRequest: PRKey, thread: Int)] = []
    /// For `--render`, in the demo: a list of its own, as the demo's, with settings of its own, where a resolved thread that
    /// waits on you is marked as read, the pull request and the thread.
    private var renderedReading: (store: PRStore, settings: AppSettings, changes: ThreadChanges, item: PRSnapshot, thread: PullRequestPanel.Thread)?
    private let changes = PassthroughSubject<Void, Never>()
    /// What a list by state shows changed: any pull request or pipeline, not only the counts.
    private let rowChanges = PassthroughSubject<Void, Never>()
    private var cancellables: Set<AnyCancellable> = []
    /// Fix with Copilot…, clicked as the click started BriefBar: it waits for the list to be read.
    private var pendingFix: AnyCancellable?
    /// Hears about the pull requests and pipelines an agent watches or pins through `--mcp`.
    private var agentChanges: AnyObject?

    package convenience init(services: AppServices, chats: ChatReading = .inert) {
        self.init(services: services, chats: chats, summarizer: nil)
    }

    /// - Parameter summarizer: writes the brief of its pull requests, rather than one that asks the on-device model:
    ///   tests pass one that never does.
    init(services: AppServices, chats: ChatReading = .inert, summarizer: Summarizer?) {
        self.services = services
        self.chats = chats
        self.summarizer = summarizer
        settings = AppSettings(defaults: services.defaults)
    }

    /// The groups counted in the menu bar: what to act on. Waiting and Done only show in the list.
    static func shownGroups(showToReview: Bool) -> [PRGroup] {
        showToReview ? [.needsYou, .failing, .ready, .toReview] : [.needsYou, .failing, .ready]
    }

    private func environment<V: View>(_ view: V) -> AnyView {
        guard let store, let sprint, let pipelines, let copilot, let details, let pullRequestDetails, let buildInvestigations,
              let pullRequestCode, let pullRequestFiles, let pullRequestConflicts, let pullRequestSessions, let copilotQuestions,
              let threadChanges, let tagChanges, let detailsDrafts
        else {
            return AnyView(EmptyView())
        }
        return AnyView(view
            .interfaceOptions(from: services)
            .environmentObject(store)
            .environment(\.prStore, store)
            .environmentObject(sprint)
            .environmentObject(details)
            .environmentObject(pullRequestDetails)
            .environmentObject(buildInvestigations)
            .environmentObject(pullRequestCode)
            .environmentObject(pullRequestFiles)
            .environmentObject(pullRequestConflicts)
            .environmentObject(pullRequestSessions)
            .environmentObject(copilotQuestions)
            .environmentObject(threadChanges)
            .environmentObject(tagChanges)
            .environmentObject(picturesHaveTheirOwnDrafts ? DetailsDrafts() : detailsDrafts)
            .environmentObject(pipelines)
            .environmentObject(copilot)
            .environmentObject(settings)
            .environmentObject(services)
            .environmentObject(services.pullRequestOrder)
            .environmentObject(services.loginItem))
    }

    /// The pull requests' store, and the Sprint and Pipelines sections' stores, sharing its client.
    private func makeStores(notifier: Notifier?) -> PRStore {
        let store = PRStore(
            settings: settings, summarizer: summarizer ?? Summarizer(), notifier: notifier, mode: services.isDemo ? .demo : .live,
            chats: chats
        )
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
        copilot.linkedSessions = { [weak links = services.links, weak updates = services.sessionUpdates] ref in
            (links?.connections(of: ref) ?? []).filter { $0.item.ref.kind == .session }.map {
                LinkedSession(
                    id: $0.item.ref.id, origins: $0.origins, isThrough: $0.via != nil,
                    began: $0.origins.contains(.session) ? updates?.reports[$0.item.ref]?.workingOnBegan[ref] : nil
                )
            }
        }
        // What sessions tell BriefBar they work on, as Show Links shows it, and Send Work to Copilot: a session that began
        // to tell it after you chose another for a pull request's work takes that one's place for good.
        services.links.$graph.map { _ in () }
            .merge(with: services.sessionUpdates.$reports.map { _ in () }, copilot.settings.$copilotEnabled.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak copilot] _ in
                MainActor.assumeIsolated {
                    guard let copilot else { return }
                    Task { await copilot.forgetChoicesToldSince() }
                }
            }
            .store(in: &cancellables)
        self.copilot = copilot
        // Its notifications about what Copilot can fix offer to, as the Actions menu would then (Fix with Copilot…).
        store.offersCopilot = { [weak store, weak copilot] key, action in
            guard let store, let copilot, let item = store.items.first(where: { $0.key == key }) else { return false }
            return store.copilotCan(action, item, copilot: copilot)
        }
        workLinks = WorkLinksStore(
            links: services.links, stories: services.stories, store: store, sprint: sprint, copilot: copilot, settings: settings,
            order: services.pullRequestOrder
        )
        let details = WorkItemDetailsStore(mode: store.mode, client: store.client, board: sprint.$board.eraseToAnyPublisher())
        details.hasPage = { [services] in services.hasPage(.azureDevOpsSprint) }
        details.openPage = { [services] in services.openWindow(.azureDevOpsSprint) }
        let pullRequestDetails = makePullRequestDetails(store: store)
        let buildInvestigations = BuildInvestigationStore(mode: store.mode, client: store.client)
        // Fix the Build quotes what was read of a build that's open in its details, as it is now.
        store.investigation = { [weak buildInvestigations] check, pullRequest in
            check.buildId.flatMap { buildInvestigations?.current($0, check: check, of: pullRequest) }
        }
        // The details beside the list stop showing a pull request: its builds fold, unless another's opened since, such as on
        // a pull request's page in a work item's details.
        pullRequestDetails.$selected.map { $0?.key }.removeDuplicates()
            .scan((previous: PRKey?.none, current: PRKey?.none)) { pair, key in (previous: pair.current, current: key) }
            .sink { [weak buildInvestigations] pair in
                MainActor.assumeIsolated {
                    if let previous = pair.previous { buildInvestigations?.close(previous) }
                }
            }
            .store(in: &cancellables)
        let pullRequestCode = PullRequestCodeStore(demo: store.mode == .demo, client: store.client)
        pullRequestCode.follow(pullRequestDetails)
        self.pullRequestCode = pullRequestCode
        pullRequestFiles = PullRequestFilesStore(code: pullRequestCode)
        let pullRequestConflicts = PullRequestConflictsStore(code: pullRequestCode, demo: store.mode == .demo, client: store.client)
        self.pullRequestConflicts = pullRequestConflicts
        // What Resolve Conflicts lists, from the details' Actions menu too, once they read it, as the pull request is then.
        store.conflicts = { [weak pullRequestConflicts, weak store] key in
            await pullRequestConflicts?.forPrompt(key) { store?.record(for: key) }
        }
        // Someone else signed in to the Azure CLI: the details read as the last one go, and what was told of them.
        store.$authoredPullRequestList.map(\.account).removeDuplicates()
            .sink { [weak self, weak details, weak workLinks, weak pullRequestDetails, weak buildInvestigations, weak pullRequestConflicts] account in
                MainActor.assumeIsolated {
                    details?.accountChanged(account)
                    workLinks?.accountChanged(account)
                    pullRequestDetails?.accountChanged(account)
                    buildInvestigations?.accountChanged(account)
                    pullRequestConflicts?.accountChanged(account)
                    self?.threadChanges?.accountChanged(account)
                    self?.tagChanges?.accountChanged(account)
                    self?.detailsDrafts?.accountChanged(account)
                }
            }
            .store(in: &cancellables)
        self.details = details
        self.pullRequestDetails = pullRequestDetails
        self.buildInvestigations = buildInvestigations
        workLinks?.details = details
        let sessions = PullRequestSessions(copilot: copilot, links: services.links)
        sessions.record = { [weak store] key in store?.record(for: key) }
        pullRequestSessions = sessions
        let questions = CopilotQuestions(copilot: copilot)
        copilotQuestions = questions
        threadChanges = ThreadChanges(store: store, settings: settings)
        tagChanges = TagChanges(store: store, settings: settings)
        let drafts = DetailsDrafts(settings: settings)
        // Where the threads you changed were stays while the details show their pull request, the pages over them included:
        // beside the list, and as a page over a work item's details.
        drafts.follow(pullRequestDetails, pagesOver: details)
        detailsDrafts = drafts
        // Each time the pull requests are read again, whether their rows changed or not, as when an optional build passed:
        // what Copilot took on of a build that a run passed after is over, so its fix doesn't come back as a later run fails,
        // and so is what it took on of conflicts that are gone, or with another target branch; and what a session answered
        // about a build's run, or attempt, that isn't the one its details list any more goes.
        store.refreshed
            .receive(on: DispatchQueue.main)
            .sink { [weak store, weak copilot, weak questions] in
                MainActor.assumeIsolated {
                    guard let store else { return }
                    let records = store.items.compactMap { store.record(for: $0.key) }
                    copilot?.endWorkThatsOver(in: records)
                    questions?.dismissStale(of: records)
                }
            }
            .store(in: &cancellables)
        // A pull request that a task or a link names shows in its details, on the window's page, while the list has it, at
        // what its row is about.
        copilot.canShowPullRequest = { [weak store, weak pullRequestDetails] key in
            guard let store, let pullRequestDetails else { return false }
            return pullRequestDetails.hasPage() && store.items.contains { $0.key == key }
        }
        copilot.showPullRequest = { [weak pullRequestDetails] key in pullRequestDetails?.revealAtWhatItsAbout(key) ?? false }
        copilot.currentTarget = { [weak store] key in store?.record(for: key)?.pullRequest.targetBranch }
        copilot.readTarget = { [weak store] key in
            guard let store else { throw CopilotTasksStore.TargetUnread() }
            return try await store.readTarget(of: key)
        }
        copilot.rereadPullRequest = { [weak store] key in store?.reread([key]) }
        workLinks?.showPullRequest = { [weak pullRequestDetails] key in pullRequestDetails?.revealAtWhatItsAbout(key) ?? false }
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
        // Before any notification has it: Notification Center shows a button only once its category is registered.
        services.notifier.register([PRStore.copilotButton])
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
        orderFacts = PullRequestOrderFacts(
            order: services.pullRequestOrder, store: store, settings: settings, details: pullRequestDetails, workLinks: workLinks,
            showWorkItem: { [weak self] item in self?.details?.reveal(item) }, copilot: copilot
        ).started()
        agentRereads = AgentRereads(
            updates: services.sessionUpdates, store: store, sprint: sprint, workLinks: workLinks, details: details, tags: tagChanges
        ).started()
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
        pendingFix = nil
        agentChanges = nil
        store?.stop()
        sprint?.stop()
        pipelines?.stop()
        copilot?.stop()
        workLinks?.stop()
        orderFacts?.stop()
        agentRereads?.stop()
        details?.stop()
        pullRequestDetails?.stop()
        buildInvestigations?.stop()
        pullRequestCode?.stop()
        pullRequestConflicts?.stop()
        pullRequestSessions?.stopAll()
        copilotQuestions?.stopAll()
        threadChanges?.forgetAll()
        tagChanges?.stop()
        detailsDrafts?.stop()
        services.sentTasks.withdraw(.azureDevOps)
        services.summaries.setYourName(.azureDevOps, nil)
        store = nil
        sprint = nil
        pipelines = nil
        copilot = nil
        workLinks = nil
        orderFacts = nil
        agentRereads = nil
        details = nil
        pullRequestDetails = nil
        buildInvestigations = nil
        pullRequestCode = nil
        pullRequestFiles = nil
        pullRequestConflicts = nil
        pullRequestSessions = nil
        copilotQuestions = nil
        threadChanges = nil
        tagChanges = nil
        detailsDrafts = nil
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
        // The tags you added, which adding one suggested.
        settings.usedTags = UsedTags()
        // Its pull requests' places in orders, and what BriefBar saw become of them.
        services.pullRequestOrder.forget(.azureDevOps)
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
        // page: the code their comments are on, the Copilot sessions their work could go to, and tags their lists don't
        // carry, are read only while the window they're in shows that page on screen.
        if viewer.kind == .window, section == .azureDevOpsPullRequests || section == .azureDevOpsSprint {
            let page = PullRequestCodeStore.page(section, window: viewer.id)
            pullRequestCode?.setVisible(isShowing, for: page)
            pullRequestSessions?.setVisible(isShowing, for: page)
            tagChanges?.setVisible(isShowing, for: page)
        }
        // By Mission names its missions only while a window shows them on screen.
        if viewer.kind == .window, section == .azureDevOpsPullRequests {
            services.pullRequestOrder.setVisible(isShowing, for: PullRequestOrder.page(section, window: viewer.id))
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

    /// Fix with Copilot…, on a notification about your pull request: the composer, for what it says, as the Actions menu opens
    /// it, with BriefBar's usual pick of where it goes, while Copilot can still do that; or else the notification opens, as
    /// a click on it does. Clicked as the click started BriefBar, once the list is read, or a minute has gone by.
    package func notificationButton(_ id: String, userInfo: [String: String]) {
        guard id == PRStore.copilotButton.id, let store,
              let action = userInfo[PRStore.copilotActionKey].flatMap(PullRequestAction.init(rawValue:)) else {
            openNotification(userInfo)
            return
        }
        pendingFix = store.onceLoaded(within: Self.firstLoadWait) { [weak self] in
            self?.pendingFix = nil
            self?.fixWithCopilot(action, userInfo: userInfo)
        }
    }

    /// How long Fix with Copilot… waits for the list, in seconds, when its click started BriefBar.
    static let firstLoadWait = 60

    private func fixWithCopilot(_ action: PullRequestAction, userInfo: [String: String]) {
        // By its key, in which an organization's name is the same in any letter case, as Azure DevOps has it.
        guard let store, let copilot, let key = userInfo["pullRequest"].flatMap(PRKey.init(description:)),
              let item = store.items.first(where: { $0.key == key }), store.copilotCan(action, item, copilot: copilot)
        else {
            openNotification(userInfo)
            return
        }
        store.markSeen(item)
        if let composingFix {
            composingFix(action, item)
        } else {
            store.composeCopilot(action, for: item, copilot: copilot)
        }
    }

    /// For tests: what Fix with Copilot… asks the composer for, rather than opening its window.
    var composingFix: ((PullRequestAction, PRSnapshot) -> Void)?

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
        environment(AzureDevOpsSettings(place: .ownPage))
    }

    /// Those about its pull requests, on the Pull Requests page in Settings: with its store while it's on, and, while it's
    /// off or paused, from its settings alone, disabled, as they do nothing then.
    package func pullRequestSettingsView(state: SourceState) -> AnyView? {
        let settings = AzureDevOpsSettings(place: .pullRequestsPage)
        if state == .on, store != nil {
            return environment(settings)
        }
        return AnyView(settings
            .disabled(true)
            .interfaceOptions(from: services)
            .environmentObject(self.settings)
            .environmentObject(services))
    }

    package var pullRequestSettings: [String] {
        AzureDevOpsSettings.Place.pullRequestsPage.settings.map(\.title)
    }

    package func statusView() -> AnyView? {
        guard store != nil else { return nil }
        return environment(SignInStatusView().environmentObject(services.notifier))
    }

    // MARK: Rendering

    package func loadForRendering() async {
        picturesHaveTheirOwnDrafts = true
        let store = makeStores(notifier: nil)
        await store.loadOnce()
        await sprint?.loadOnce()
        await loadDetailsForRendering(store: store)
        await loadInvestigationsForRendering(store: store)
        await loadCodeForRendering(store: store)
        await loadFilesForRendering(store: store)
        await loadConflictsForRendering(store: store)
        await loadChangesForRendering(store: store)
        await loadReadingForRendering(store: store)
        await pipelines?.loadOnce()
        await workLinks?.loadOnce()
        orderFacts = PullRequestOrderFacts(
            order: services.pullRequestOrder, store: store, settings: settings, details: pullRequestDetails, workLinks: workLinks,
            showWorkItem: { [weak self] item in self?.details?.reveal(item) }, copilot: copilot
        ).loadOnce()
        // Before Copilot's list loads, which shows them with the sessions.
        publishSentTasks()
        // The Copilot sessions of the pull requests whose details are drawn, read once: the first of yours that needs you,
        // the first that's failing, and those whose builds show; and, in the demo, which makes them up and reads nothing,
        // every one, for the one whose sessions ask which is its and the one whose session waits for your answer. Show
        // Links' sessions are told later, and they follow.
        var drawn = renderedPullRequests(store)
        drawn += renderedInvestigations.map { $0.item }
        await pullRequestSessions?.prepare(store.mode == .demo ? store.items : drawn)
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
        renderings += buildInvestigationRenderings()
        renderings += pullRequestThreadRenderings()
        renderings += commentActionRenderings()
        renderings += threadChangeRenderings()
        renderings += threadReadingRenderings()
        renderings += tagRenderings()
        renderings += buildCopilotRenderings()
        renderings += pullRequestFilesRenderings()
        renderings += pullRequestConflictRenderings()
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
        if let store {
            renderings += PullRequestsByMission.renderings(store: store, services: services) { self.environment($0) }
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
    /// the first work item linked to it over them; the first that's failing; the first of yours set to complete by itself;
    /// for the line of its Copilot session, the first of yours with merge conflicts, whose two sessions ask which is its,
    /// and the one whose session waits for your answer; the first review you're asked for, at its reviewers, as it opens
    /// from anywhere but beside the list; and, with Pull Request Order on, the first whose stage you set, for its track.
    /// Each in a store of its own, so the window's own picture of the page shows none.
    private func pullRequestDetailsRenderings() -> [(name: String, view: AnyView)] {
        guard let store else { return [] }
        // The sessions as Show Links has them now that every source told it.
        pullRequestSessions?.updateAll()
        let yours = store.items.first { $0.group == .needsYou && $0.role == .author } ?? store.items.first
        let failing = store.items.first { $0.group == .failing }
        let completing = store.items.first { $0.role == .author && store.record(for: $0.key)?.pullRequest.autoComplete == true }
        let asking = store.items.first { item in
            if case .ask? = pullRequestSessions?.session(for: item.key)?.pick { return true }
            return false
        }
        let waiting = store.items.first { item in
            guard let choice = pullRequestSessions?.session(for: item.key)?.session, let ref = ItemRef.session(choice.id) else { return false }
            return services.links.describe(ref).state == .needsYou
        }
        let reviewing = store.items.first { $0.reason == .reviewRequested } ?? store.items.first(where: \.isAboutYourReview)
        let staged = store.items.first { services.pullRequestOrder.stage(of: $0.key.linkRef)?.isSetByYou == true }
        let wide = CGSize(width: 1_000, height: 720)
        let shown: [(name: String, item: PRSnapshot?, sizes: [(suffix: String, size: CGSize)], page: ItemRef.Kind?, about: Bool)] = [
            ("pull-requests-details", yours, [
                ("", wide), ("-medium", CGSize(width: 820, height: 680)), ("-narrow", CGSize(width: 560, height: 720)),
                ("-tall", CGSize(width: 1_000, height: 1_500)),
            ], nil, false),
            ("pull-requests-details-page", yours, [("", wide)], .workItem, false),
            ("pull-requests-failing-details", failing, [("", wide), ("-tall", CGSize(width: 1_000, height: 1_100))], nil, false),
            ("pull-requests-completing-details", completing, [("", wide)], nil, false),
            ("pull-requests-session-question", asking, [("", wide), ("-narrow", CGSize(width: 560, height: 720))], nil, false),
            ("pull-requests-session-waiting", waiting, [("", wide)], nil, false),
            ("pull-requests-review-details", reviewing, [("", wide), ("-narrow", CGSize(width: 560, height: 720))], nil, true),
            ("pull-requests-stage-details", staged, [("", wide), ("-narrow", CGSize(width: 560, height: 720))], nil, false),
        ]
        var renderings: [(name: String, view: AnyView)] = []
        for (name, item, sizes, page, about) in shown {
            guard let item else { continue }
            let linked = page.flatMap { page in services.links.connections(of: item.key.linkRef).first { $0.item.ref.kind == page } }
            if page != nil, linked == nil { continue }
            for (suffix, size) in sizes {
                // A store for each picture: each goes where it's asked to once.
                let details = PullRequestDetailsStore()
                details.readRecord = { [weak store] key in store?.record(for: key) }
                details.itemsChanged(store.items)
                details.show(item, at: about ? details.about(item) : nil)
                if let linked { details.open(page: linked.item.ref) }
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
        // One sent to you in a chat that you've seen, which left your lists but which the list still reads: over the list,
        // which would show its row otherwise.
        if let sent = store.items.first(where: { $0.role == .linked }) {
            let details = PullRequestDetailsStore()
            details.readRecord = { [weak store] key in store?.record(for: key) }
            details.itemsChanged(store.items.filter { $0.key != sent.key })
            details.show(sent)
            let view = PullRequestsPage()
                .environmentObject(details)
                .environment(\.panelStyle, .page)
                .textSize(from: services)
                .frame(width: 560, height: 720)
                .background(WindowBackdrop())
                .environment(\.isRendering, true)
            renderings.append((name: "pull-requests-details-left-the-lists-narrow", view: environment(view)))
        }
        return renderings
    }

    /// For `--render`: the first of the pull requests' builds that failed, and the first that's still going, each open in a
    /// store of its own, read once.
    private func loadInvestigationsForRendering(store: PRStore) async {
        renderedInvestigations = []
        for (name, state) in [("pull-requests-build-failure", ItemState.failing), ("pull-requests-build-running", .running)] {
            let found = store.items.lazy.compactMap { item -> (item: PRSnapshot, pullRequest: PullRequest, line: PullRequestPanel.CheckLine)? in
                guard let record = store.record(for: item.key),
                      let line = PullRequestPanel(item, record: record).checks.first(where: { $0.canInvestigate && $0.run.state == state })
                else { return nil }
                return (item, record.pullRequest, line)
            }.first
            guard let found, let buildId = found.line.buildId else { continue }
            let investigations = BuildInvestigationStore(mode: store.mode, client: store.client)
            await investigations.expandAndWait(buildId, of: found.pullRequest, check: found.line.check)
            renderedInvestigations.append((name, found.item, investigations))
        }
    }

    /// The Pull Requests page with a pull request's build open in its details: one that failed, beside the list as in a big
    /// window and over it in a narrow one, tall enough for all of it; and one that's still going.
    private func buildInvestigationRenderings() -> [(name: String, view: AnyView)] {
        guard let store else { return [] }
        var renderings: [(name: String, view: AnyView)] = []
        for (name, item, investigations) in renderedInvestigations {
            let details = PullRequestDetailsStore()
            details.readRecord = { [weak store] key in store?.record(for: key) }
            details.itemsChanged(store.items)
            details.show(item)
            let sizes: [(suffix: String, size: CGSize)] = name.hasSuffix("-failure")
                ? [("", CGSize(width: 1_000, height: 2_100)), ("-narrow", CGSize(width: 560, height: 2_100))]
                : [("", CGSize(width: 1_000, height: 1_200))]
            for (suffix, size) in sizes {
                let view = PullRequestsPage()
                    .environmentObject(details)
                    .environmentObject(investigations)
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
    /// a fork of it; fixed; failing; sent, how it went unknown; and Fix All's composer open. In a narrow window too, for the first two. Each from made-up
    /// states, through `CopilotActionsPreview`: nothing's sent or asked.
    func commentActionRenderings() -> [(name: String, view: AnyView)] {
        guard let store, store.mode == .demo, let item = renderedPullRequests(store).first, let record = store.record(for: item.key) else {
            return []
        }
        let threads = PullRequestPanel(item, record: record).threads
        guard let waiting = threads.waitingOnYou.first(where: { ThreadCode.isOnLines($0.thread) }) else { return [] }
        let suggested = threads.open.first { CommentSuggestion.latest(in: $0.thread, me: record.me) != nil }
        // As of the demo's now, which the threads' lines count from, however long rendering takes.
        let now = store.now
        let session = SentPrompt.demoSession
        let fork = "5c1e7a90-3b2d-4f68-9a1c-2e8d7b6f4a05"
        func work(_ state: CopilotWork.State, ago minutes: Double, forkedFrom: String? = nil) -> CopilotWork {
            CopilotWork(
                part: .thread(waiting.id), purpose: .fix, state: state, session: forkedFrom == nil ? session : fork, forkedFrom: forkedFrom, isTask: false,
                since: now.addingTimeInterval(-minutes * 60)
            )
        }
        let question = "Isn't 30 seconds too short when the provider is down for minutes?"
        let how = "Cap it with a MaxDelay on RetryOptions, as Priya suggests, 30 seconds by default"
        let ready = suggested.map { [ReadyFixes(session: session, forkedFrom: nil, isTask: false, parts: [.thread(waiting.id), .thread($0.id)], latest: now)] }
        var shown: [(name: String, thread: Int, preview: CopilotActionsPreview, sizes: [(suffix: String, size: CGSize)])] = [
            ("pull-requests-comment-actions", waiting.id, CopilotActionsPreview(), [("", CGSize(width: 1_000, height: 900)), ("-narrow", CGSize(width: 560, height: 900))]),
            ("pull-requests-comment-explain", waiting.id, CopilotActionsPreview(composers: [
                .init(part: .thread(waiting.id), ask: .explain, text: question, destination: .session(session)),
            ]), [("", CGSize(width: 1_000, height: 900)), ("-narrow", CGSize(width: 560, height: 900))]),
            ("pull-requests-comment-explaining", waiting.id, CopilotActionsPreview(questions: [
                .thread(waiting.id): .init(session: session, asked: question, askedAt: now.addingTimeInterval(-40), state: .asking),
            ]), [("", CGSize(width: 1_000, height: 900))]),
            ("pull-requests-comment-answer", waiting.id, CopilotActionsPreview(questions: [
                .thread(waiting.id): .init(
                    session: session, asked: question, askedAt: now.addingTimeInterval(-150),
                    state: .answered(DemoData.explanation(ofThread: waiting.id, pullRequest: item.key.number)), endedAt: now.addingTimeInterval(-90)
                ),
            ]), [("", CGSize(width: 1_000, height: 1_100)), ("-narrow", CGSize(width: 560, height: 1_100))]),
            // Fix, building on what the session answered.
            ("pull-requests-comment-fix-answer", waiting.id, CopilotActionsPreview(
                composers: [.init(part: .thread(waiting.id), ask: .fix, text: "The second way, with 45 seconds by default", destination: .session(session))],
                questions: [
                    .thread(waiting.id): .init(
                        session: session, asked: question, askedAt: now.addingTimeInterval(-150),
                        state: .answered(DemoData.explanation(ofThread: waiting.id, pullRequest: item.key.number)), endedAt: now.addingTimeInterval(-90)
                    ),
                ]
            ), [("", CGSize(width: 1_000, height: 1_500))]),
            ("pull-requests-comment-fix", waiting.id, CopilotActionsPreview(composers: [
                .init(part: .thread(waiting.id), ask: .fix, text: how, destination: .session(session)),
            ]), [("", CGSize(width: 1_000, height: 900)), ("-narrow", CGSize(width: 560, height: 900))]),
            ("pull-requests-comment-fixing", waiting.id, CopilotActionsPreview(work: [.thread(waiting.id): work(.working("Run PaymentsClientTests"), ago: 2)]),
             [("", CGSize(width: 1_000, height: 900))]),
            ("pull-requests-comment-fork", waiting.id, CopilotActionsPreview(work: [.thread(waiting.id): work(.working(nil), ago: 2, forkedFrom: session)]),
             [("", CGSize(width: 1_000, height: 900))]),
            ("pull-requests-comment-fixed", waiting.id, CopilotActionsPreview(
                work: [.thread(waiting.id): work(.done("Capped the backoff at RetryOptions.MaxDelay, 30 seconds by default. The tests pass."), ago: 1)],
                ready: ready
            ), [("", CGSize(width: 1_000, height: 900))]),
            ("pull-requests-comment-failed", waiting.id, CopilotActionsPreview(
                work: [.thread(waiting.id): work(.failed("The build failed: CS0103 The name 'MaxDelay' does not exist in the current context."), ago: 3)]
            ), [("", CGSize(width: 1_000, height: 900))]),
            // Another prompt went to the session before its turn ended: how it went isn't known.
            ("pull-requests-comment-unknown", waiting.id, CopilotActionsPreview(work: [.thread(waiting.id): work(.unknown(copied: false), ago: 6)], ready: []),
             [("", CGSize(width: 1_000, height: 900))]),
            // Pushed with the rest of what its session changed, by a Push & Reply whose prompt didn't list it: no reply on it.
            ("pull-requests-comment-pushed", waiting.id, CopilotActionsPreview(
                work: [.thread(waiting.id): CopilotWork(
                    part: .thread(waiting.id), purpose: .pushAndReply, state: .done(nil), session: session, isTask: false,
                    since: now.addingTimeInterval(-2 * 60), replies: false
                )],
                ready: []
            ), [("", CGSize(width: 1_000, height: 900)), ("-narrow", CGSize(width: 560, height: 900))]),
        ]
        if let suggested {
            shown.append(("pull-requests-comment-suggestion", suggested.id, CopilotActionsPreview(
                composers: [.init(part: .thread(suggested.id), ask: .fix, text: "", destination: .session(session), appliesSuggestion: true)],
                quiet: [.thread(suggested.id)], ready: []
            ), [("", CGSize(width: 1_000, height: 900))]))
        }
        var renderings: [(name: String, view: AnyView)] = []
        for (name, thread, preview, sizes) in shown {
            for (suffix, size) in sizes {
                renderings.append((name: name + suffix, view: environment(commentsPage(item, at: thread, preview: preview, size: size))))
            }
        }
        // Fix All's composer, under the comments' heading.
        let fixAll = CopilotActionsPreview(composers: [.init(part: nil, ask: .fixAll, text: "Keep the public API as it is", destination: .session(session))])
        let details = PullRequestDetailsStore()
        details.readRecord = { [weak store] key in store?.record(for: key) }
        details.itemsChanged(store.items)
        details.show(item, at: .section(.comments))
        renderings.append((name: "pull-requests-comments-fix-all", view: environment(page(details, preview: fixAll, size: CGSize(width: 1_000, height: 900)))))
        return renderings
    }

    /// The Pull Requests page with a pull request's details taken to one of its threads, in a store of its own, since each
    /// scrolls its details there once.
    private func commentsPage(_ item: PRSnapshot, at thread: Int, preview: CopilotActionsPreview, size: CGSize) -> some View {
        let details = PullRequestDetailsStore()
        details.readRecord = { [weak store] key in store?.record(for: key) }
        details.itemsChanged(store?.items ?? [])
        details.show(item, at: .thread(thread))
        return page(details, preview: preview, size: size)
    }

    private func page(_ details: PullRequestDetailsStore, preview: CopilotActionsPreview, size: CGSize) -> some View {
        PullRequestsPage()
            .environmentObject(details)
            .environment(\.copilotActionsPreview, preview)
            .environment(\.panelStyle, .page)
            .textSize(from: services)
            .frame(width: size.width, height: size.height)
            .background(WindowBackdrop())
            .environment(\.isRendering, true)
    }
}

// MARK: - Asking Copilot about a failed build, for --render

extension AzureDevOpsSource {
    /// The Pull Requests page with the details of the first failing pull request taken to its build that failed, open, with
    /// what you can ask Copilot about it, in each state: Explain the Failure and Fix, under where it failed; Explain's
    /// composer open, then asking, then answered; Fix's composer open, building on the answer; Copilot fixing it, as the
    /// demo's Fix the Build task does; fixed, with the fixes ready to push at the foot; and failing. In a narrow window too,
    /// for the first three. Each from made-up states, through `CopilotActionsPreview`: nothing's sent or asked.
    func buildCopilotRenderings() -> [(name: String, view: AnyView)] {
        guard let store, store.mode == .demo,
              let (_, item, investigations) = renderedInvestigations.first(where: { $0.name == "pull-requests-build-failure" }),
              let record = store.record(for: item.key),
              let line = PullRequestPanel(item, record: record).checks.first(where: { $0.canInvestigate && $0.run.state == .failing }),
              let part = line.check?.part, let buildId = line.buildId
        else { return [] }
        let now = store.now
        // The demo's Fix the Build task on it (`CopilotTaskEntry.demo`).
        let task = "1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b03"
        func work(_ state: CopilotWork.State, ago minutes: Double) -> CopilotWork {
            CopilotWork(part: part, purpose: .fix, state: state, session: task, forkedFrom: nil, isTask: true, since: now.addingTimeInterval(-minutes * 60))
        }
        let question = "Did this pull request break it, or was it broken on main?"
        let answered = CopilotQuestions.Question(
            session: task, asked: nil, askedAt: now.addingTimeInterval(-150), state: .answered(DemoData.buildExplanation(pullRequest: item.key.number)),
            endedAt: now.addingTimeInterval(-90), run: buildId
        )
        let how = "Fix it here: skip weekends in AddBusinessDays, and compare the cutoff in the warehouse's time zone"
        let wide = CGSize(width: 1_000, height: 1_100), narrow = CGSize(width: 560, height: 1_100)
        let fixed = work(.done("AddBusinessDays skips weekends, and the cutoff is compared in the warehouse's time zone. The tests pass."), ago: 1)
        let shown: [(name: String, preview: CopilotActionsPreview, sizes: [(suffix: String, size: CGSize)])] = [
            ("pull-requests-build-actions", CopilotActionsPreview(quiet: [part], ready: []), [("", wide), ("-narrow", narrow)]),
            ("pull-requests-build-explain", CopilotActionsPreview(
                composers: [.init(part: part, ask: .explain, text: question, destination: .session(task))], quiet: [part], ready: []
            ), [("", wide), ("-narrow", narrow)]),
            ("pull-requests-build-explaining", CopilotActionsPreview(
                quiet: [part],
                questions: [part: .init(session: task, asked: question, askedAt: now.addingTimeInterval(-40), state: .asking, run: buildId)],
                ready: []
            ), [("", wide)]),
            ("pull-requests-build-answer", CopilotActionsPreview(quiet: [part], questions: [part: answered], ready: []), [("", wide), ("-narrow", narrow)]),
            // Where it goes unless you choose: a fork of the task, which is busy.
            ("pull-requests-build-fix", CopilotActionsPreview(
                composers: [.init(part: part, ask: .fix, text: how, destination: nil)], quiet: [part], questions: [part: answered], ready: []
            ), [("", CGSize(width: 1_000, height: 1_500))]),
            ("pull-requests-build-fixing", CopilotActionsPreview(work: [part: work(.working("Run DeliveryEstimateTests"), ago: 9)], ready: []), [("", wide)]),
            ("pull-requests-build-fixed", CopilotActionsPreview(
                work: [part: fixed], ready: [ReadyFixes(session: task, forkedFrom: nil, isTask: true, parts: [part], latest: now.addingTimeInterval(-60))]
            ), [("", wide)]),
            ("pull-requests-build-fix-failed", CopilotActionsPreview(
                work: [part: work(.failed("The tests still fail: EstimateUsesTheWarehouseTimeZone expects 2 days and gets 3."), ago: 2)], ready: []
            ), [("", wide)]),
            // Closed, its row says them: what it answered since it fixed it, then the fix.
            ("pull-requests-build-closed", CopilotActionsPreview(
                work: [part: work(.done("AddBusinessDays skips weekends, and the cutoff is compared in the warehouse's time zone. The tests pass."), ago: 12)],
                questions: [part: answered],
                ready: [ReadyFixes(session: task, forkedFrom: nil, isTask: true, parts: [part], latest: now.addingTimeInterval(-720))]
            ), [("", wide), ("-narrow", narrow)]),
        ]
        var renderings: [(name: String, view: AnyView)] = []
        for (name, preview, sizes) in shown {
            for (suffix, size) in sizes {
                // A store for each, since each scrolls its details to its builds once.
                let details = PullRequestDetailsStore()
                details.readRecord = { [weak store] key in store?.record(for: key) }
                details.itemsChanged(store.items)
                details.show(item, at: .section(.checks))
                // Closed, in a store that hasn't opened it.
                let opened = name.hasSuffix("-closed") ? BuildInvestigationStore(mode: store.mode, client: store.client) : investigations
                let view = PullRequestsPage()
                    .environmentObject(details)
                    .environmentObject(opened)
                    .environment(\.copilotActionsPreview, preview)
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

// MARK: - Replying and setting a thread's status, for --render

extension AzureDevOpsSource {
    /// For `--render`, in the demo: lists of their own, as the demo's, on the first thread that waits on you on the first of
    /// your pull requests that needs you, one with your reply made with Reply & Resolve, one with the thread set to Won't
    /// Fix, and one with your comment there edited, made as the demo makes them, in their made-up data only.
    private func loadChangesForRendering(store: PRStore) async {
        renderedChanges = []
        guard store.mode == .demo else { return }
        for name in ["pull-requests-replied-resolved", "pull-requests-status-wont-fix", "pull-requests-comment-edited"] {
            // Settings of its own, so what it sees and changes leaves the other pictures as they are.
            let own = AppSettings(defaults: MemoryDefaults())
            // The other pictures' brief, as their list's.
            let list = PRStore(settings: own, summarizer: store.summarizer, mode: .demo)
            await list.loadOnce()
            let changes = ThreadChanges(store: list, settings: own)
            guard let item = renderedPullRequests(list).first, let record = list.record(for: item.key),
                  let waiting = PullRequestPanel(item, record: record).threads.waitingOnYou.first(where: { ThreadCode.isOnLines($0.thread) })
            else { return }
            if name.hasSuffix("-resolved") {
                await changes.reply(Self.renderedReply, then: .fixed, to: waiting.thread, of: item.key)
            } else if name.hasSuffix("-edited") {
                guard let mine = waiting.comments.first(where: { $0.isEditable(by: record.me) }) else { return }
                await changes.edit(Self.renderedEdit, of: mine, in: waiting.thread, of: item.key)
            } else {
                await changes.setStatus(.wontFix, of: waiting.thread, in: item.key)
            }
            renderedChanges.append((name, list, changes, item.key, waiting.id))
        }
    }

    /// What you reply in the demo's pictures, and what Fix Grammar makes of it.
    private static let renderedReply = "Capped it at RetryOptions.MaxDelay, 30 seconds by default. Thanks @Priya!"
    private static let renderedDraft = "i capped teh backoff at `RetryOptions.MaxDelay` , its 30 seconds by default"
    /// What your comment says once you edit it in the demo's pictures, as you do and once you saved it.
    private static let renderedEdit = "I went with exponential backoff, starting at 200 ms and doubling each time, up to "
        + "`RetryOptions.MaxDelay`: 30 seconds by default."
    /// What your comment said as you began to edit it, in the demo's picture of one that changed since, as in Azure DevOps.
    private static let renderedBegan = "I went with exponential backoff."

    /// The Pull Requests page with the details of the first of your pull requests that needs you, taken to its first
    /// thread that waits on you, with Reply and its status beside Explain and Fix; your reply open there, with what you
    /// wrote, with Fix Grammar's suggestion, once you used it, with a Copilot model chosen, and when it couldn't go; a
    /// status that couldn't be set; your comment there with its ⋯ menu open, as you edit it, once it changed since you
    /// began, as you delete it, and when it couldn't be deleted; then, from the demo's list with them made, the thread
    /// replied to and resolved, another set to Won't Fix, and your comment edited; and Make Changes in Azure DevOps in
    /// Settings. In a narrow window too. Each from made-up states, through `ThreadChangesPreview`, or made as the demo
    /// makes them: nothing's sent.
    func threadChangeRenderings() -> [(name: String, view: AnyView)] {
        guard let store, store.mode == .demo, let item = renderedPullRequests(store).first, let record = store.record(for: item.key) else {
            return []
        }
        let threads = PullRequestPanel(item, record: record).threads
        guard let waiting = threads.waitingOnYou.first(where: { ThreadCode.isOnLines($0.thread) }) else { return [] }
        let corrected = GrammarFix.madeUp(Self.renderedDraft)
        let suggestion = GrammarSuggestion(original: Self.renderedDraft, corrected: corrected, model: StorySummaries.appleIntelligenceModel)
        let wide = CGSize(width: 1_000, height: 900), narrow = CGSize(width: 560, height: 900)
        let reply = ThreadChangesPreview.Reply(text: Self.renderedReply)
        // Your comment in that thread.
        let mine = waiting.comments.first { $0.isEditable(by: record.me) }.map { PreviewComment(thread: waiting.id, comment: $0.id) }
        let yours: [(name: String, preview: ThreadChangesPreview, sizes: [(suffix: String, size: CGSize)])] = mine.map { mine in [
            ("pull-requests-comment-menu", ThreadChangesPreview(menu: mine), [("", wide), ("-narrow", narrow)]),
            ("pull-requests-comment-edit", ThreadChangesPreview(edits: [mine: .init(text: Self.renderedEdit)]),
             [("", wide), ("-narrow", narrow)]),
            // Begun when it said less, and edited since, as in Azure DevOps: it says so, with what it says now.
            ("pull-requests-comment-changed", ThreadChangesPreview(edits: [mine: .init(text: Self.renderedEdit, began: Self.renderedBegan)]),
             [("", wide), ("-narrow", narrow)]),
            ("pull-requests-comment-delete", ThreadChangesPreview(deleting: mine), [("", wide), ("-narrow", narrow)]),
            ("pull-requests-comment-delete-failed", ThreadChangesPreview(states: [waiting.id: .failed(.notAllowed, .delete(comment: mine.comment))]),
             [("", wide), ("-narrow", narrow)]),
        ] } ?? []
        let shown: [(name: String, preview: ThreadChangesPreview, sizes: [(suffix: String, size: CGSize)])] = yours + [
            ("pull-requests-reply", ThreadChangesPreview(replies: [waiting.id: reply]), [("", wide), ("-narrow", narrow)]),
            ("pull-requests-reply-grammar", ThreadChangesPreview(replies: [
                waiting.id: .init(text: Self.renderedDraft, suggestion: suggestion),
            ]), [("", wide), ("-narrow", narrow)]),
            ("pull-requests-reply-corrected", ThreadChangesPreview(replies: [
                waiting.id: .init(text: corrected, undo: suggestion),
            ]), [("", wide)]),
            ("pull-requests-reply-grammar-unavailable", ThreadChangesPreview(replies: [
                waiting.id: .init(text: Self.renderedDraft, grammarProblem: GrammarFixer.unavailable(.notEnabled)),
            ]), [("", wide)]),
            ("pull-requests-reply-failed", ThreadChangesPreview(
                replies: [waiting.id: reply], states: [waiting.id: .failed(.offline, .reply(then: nil))]
            ), [("", wide), ("-narrow", narrow)]),
            ("pull-requests-status-failed", ThreadChangesPreview(states: [waiting.id: .failed(.notAllowed, .status(.fixed))]),
             [("", wide), ("-narrow", narrow)]),
            // A status that didn't change, set from the card's menu while your reply is open: above it.
            ("pull-requests-reply-status-failed", ThreadChangesPreview(
                replies: [waiting.id: reply], states: [waiting.id: .failed(.notAllowed, .status(.wontFix))]
            ), [("", wide), ("-narrow", narrow)]),
            // As for a pull request that left your lists as you resolved a thread: read-only, which says why.
            ("pull-requests-read-only", ThreadChangesPreview(
                states: [waiting.id: .failed(.notListed, .status(.fixed))], readOnly: ThreadChanges.notListed
            ), [("", wide), ("-narrow", narrow)]),
        ]
        var renderings: [(name: String, view: AnyView)] = []
        for (name, preview, sizes) in shown {
            for (suffix, size) in sizes {
                // A store for each, since each scrolls its details to the thread once.
                let details = PullRequestDetailsStore()
                details.readRecord = { [weak store] key in store?.record(for: key) }
                details.itemsChanged(store.items)
                details.show(item, at: .thread(waiting.id))
                let view = PullRequestsPage()
                    .environmentObject(details)
                    .environment(\.threadChangesPreview, preview)
                    .environment(\.panelStyle, .page)
                    .textSize(from: services)
                    .frame(width: size.width, height: size.height)
                    .background(WindowBackdrop())
                    .environment(\.isRendering, true)
                renderings.append((name: name + suffix, view: environment(view)))
            }
        }
        // The same, with a Copilot model chosen for Fix Grammar: what it costs, and where your reply goes.
        if let copilotModel = services.summaries.models.first(where: { $0.id != StorySummaries.appleIntelligenceModel }) {
            let chosen = AppSettings(defaults: MemoryDefaults())
            chosen.makesChanges = true
            chosen.grammarModel = copilotModel.id
            let details = PullRequestDetailsStore()
            details.readRecord = { [weak store] key in store?.record(for: key) }
            details.itemsChanged(store.items)
            details.show(item, at: .thread(waiting.id))
            let view = PullRequestsPage()
                .environmentObject(details)
                .environment(\.threadChangesPreview, ThreadChangesPreview(replies: [waiting.id: .init(text: Self.renderedDraft)]))
                .environment(\.panelStyle, .page)
                .textSize(from: services)
                .frame(width: wide.width, height: wide.height)
                .background(WindowBackdrop())
                .environment(\.isRendering, true)
            renderings.append((name: "pull-requests-reply-copilot-model", view: environment(view.environmentObject(chosen))))
        }
        // As the demo makes them: replied to and resolved, and set to Won't Fix, either of which unfolds the resolved threads.
        for (name, list, changes, key, thread) in renderedChanges {
            guard let changed = list.items.first(where: { $0.key == key }) else { continue }
            for (suffix, size) in [("", wide), ("-narrow", narrow)] {
                let details = PullRequestDetailsStore()
                details.readRecord = { [weak list] key in list?.record(for: key) }
                details.itemsChanged(list.items)
                details.show(changed, at: .thread(thread))
                let view = PullRequestsPage()
                    .environmentObject(details)
                    .environmentObject(list)
                    .environmentObject(changes)
                    .environment(\.panelStyle, .page)
                    .textSize(from: services)
                    .frame(width: size.width, height: size.height)
                    .background(WindowBackdrop())
                    .environment(\.isRendering, true)
                renderings.append((name: name + suffix, view: environment(view)))
            }
        }
        let setting = Form { MakeChangesSetting() }
            .formStyle(.grouped)
            .environment(\.inSettingsForm, true)
            .frame(width: 600)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
        renderings.append((name: "make-changes-settings", view: environment(setting)))
        return renderings
    }
}

// MARK: - A pull request's tags, for --render

extension AzureDevOpsSource {
    /// The Pull Requests page with the details of the first of your pull requests that needs you, at their top: its tags
    /// under its heading, with ✕ and Add Tag; the field that adds one, with what you typed and its suggestions; a change
    /// Azure DevOps didn't allow, and one that couldn't go while offline; Undo, after a tag was taken off; and the tags as they
    /// show without Make Changes in Azure DevOps. In a narrow window too. Each from made-up states, through `TagsPreview`:
    /// nothing's sent.
    func tagRenderings() -> [(name: String, view: AnyView)] {
        guard let store, store.mode == .demo, let item = renderedPullRequests(store).first else { return [] }
        let wide = CGSize(width: 1_000, height: 640), narrow = CGSize(width: 560, height: 760)
        let shown: [(name: String, preview: TagsPreview, sizes: [(suffix: String, size: CGSize)])] = [
            ("pull-requests-tags", TagsPreview(), [("", wide), ("-narrow", narrow)]),
            ("pull-requests-tags-add", TagsPreview(typed: "dep", highlighted: 0), [("", wide), ("-narrow", narrow)]),
            ("pull-requests-tags-failed", TagsPreview(state: .failed(.notAllowed, .add("deploy-us"))), [("", wide), ("-narrow", narrow)]),
            ("pull-requests-tags-offline", TagsPreview(state: .failed(.offline, .remove(PullRequestTag("needs-qa")))), [("", wide)]),
            ("pull-requests-tags-removed", TagsPreview(removed: PullRequestTag("hotfix")), [("", wide), ("-narrow", narrow)]),
            ("pull-requests-tags-read-only", TagsPreview(canChange: false), [("", wide)]),
        ]
        var renderings: [(name: String, view: AnyView)] = []
        for (name, preview, sizes) in shown {
            for (suffix, size) in sizes {
                let details = PullRequestDetailsStore()
                details.readRecord = { [weak store] key in store?.record(for: key) }
                details.itemsChanged(store.items)
                details.show(item)
                let view = PullRequestsPage()
                    .environmentObject(details)
                    .environment(\.tagsPreview, preview)
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

// MARK: - Marking a thread as read, and Active | All, for --render

extension AzureDevOpsSource {
    /// The first pull request in Needs You with a resolved thread that waits on you, and that thread: in the demo, the review
    /// on which the assistant's closed thread mentions you.
    private func readingPullRequest(_ store: PRStore) -> (item: PRSnapshot, thread: PullRequestPanel.Thread)? {
        for item in store.items where item.group == .needsYou {
            let threads = PullRequestPanel(item, record: store.record(for: item.key)).threads
            if let thread = threads.waitingOnYou.first(where: \.isResolved) { return (item, thread) }
        }
        return nil
    }

    /// For `--render`, in the demo: a list of its own, as the demo's, with settings of its own, so that what it sees and
    /// marks as read leaves the other pictures as they are, for the details to show that thread once it's marked as read.
    private func loadReadingForRendering(store: PRStore) async {
        renderedReading = nil
        guard store.mode == .demo else { return }
        let own = AppSettings(defaults: MemoryDefaults())
        // The other pictures' brief, as their list's.
        let list = PRStore(settings: own, summarizer: store.summarizer, mode: .demo)
        await list.loadOnce()
        guard let (item, thread) = readingPullRequest(list) else { return }
        renderedReading = (list, own, ThreadChanges(store: list, settings: own), item, thread)
    }

    /// The Pull Requests page with the details of the first pull request in Needs You with a resolved thread that waits on
    /// you, at its comments: Mark as Read by its chip; and the same once it's marked as read, from a list of its own, the chip
    /// and the dot gone, and the thread where it was. Then the first of your pull requests that needs you at its comments,
    /// with Active, which says how many it hides, and with All; and a file's page with Active. In a narrow window too. In the
    /// demo only: nothing's kept.
    func threadReadingRenderings() -> [(name: String, view: AnyView)] {
        guard let store, store.mode == .demo, let (item, thread) = readingPullRequest(store) else { return [] }
        let wide = CGSize(width: 1_000, height: 720), narrow = CGSize(width: 560, height: 720)
        func page(_ details: PullRequestDetailsStore, size: CGSize) -> some View {
            PullRequestsPage()
                .environmentObject(details)
                .environment(\.panelStyle, .page)
                .textSize(from: services)
                .frame(width: size.width, height: size.height)
                .background(WindowBackdrop())
                .environment(\.isRendering, true)
        }
        /// Settings of its own, as the demo's, showing only the active threads or all of them.
        func showing(_ filter: PullRequestPanel.CommentFilter) -> AppSettings {
            let own = AppSettings(defaults: MemoryDefaults())
            own.pullRequestOrder = settings.pullRequestOrder
            own.pullRequestDetailsWidth = settings.pullRequestDetailsWidth
            own.showToReview = settings.showToReview
            own.commentFilter = filter
            return own
        }
        var renderings: [(name: String, view: AnyView)] = []
        for (suffix, size) in [("", wide), ("-narrow", narrow)] {
            // A store for each, since each scrolls its details once.
            let details = PullRequestDetailsStore()
            details.readRecord = { [weak store] key in store?.record(for: key) }
            details.itemsChanged(store.items)
            details.show(item, at: .section(.comments))
            renderings.append((name: "pull-requests-mark-as-read" + suffix, view: environment(page(details, size: size))))
        }
        if let (list, own, changes, item, thread) = renderedReading {
            for (suffix, size) in [("", wide), ("-narrow", narrow)] {
                let details = PullRequestDetailsStore()
                details.use(list)
                // Unseen, as for the other pictures, which light and dark draw the same.
                details.markSeen = { _ in }
                details.show(item, at: .section(.comments))
                details.markRead(thread)
                let view = page(details, size: size)
                    .environmentObject(list)
                    .environmentObject(own)
                    .environmentObject(changes)
                renderings.append((name: "pull-requests-marked-as-read" + suffix, view: environment(view)))
            }
        }
        guard let yours = renderedPullRequests(store).first else { return renderings }
        let tall = CGSize(width: 1_000, height: 1_100), tallNarrow = CGSize(width: 560, height: 1_100)
        for (name, filter) in [("pull-requests-comments-active", PullRequestPanel.CommentFilter.active), ("pull-requests-comments-all", .all)] {
            for (suffix, size) in [("", tall), ("-narrow", tallNarrow)] {
                let details = PullRequestDetailsStore()
                details.readRecord = { [weak store] key in store?.record(for: key) }
                details.itemsChanged(store.items)
                details.show(yours, at: .section(.comments))
                renderings.append((name: name + suffix, view: environment(page(details, size: size).environmentObject(showing(filter)))))
            }
        }
        // Its file's page, which follows the choice.
        if let files = pullRequestFiles, case .read(let changes)? = files.list(of: yours.key, .whole),
           let file = renderedFile(in: changes, of: yours, store) {
            for (suffix, size) in [("", wide), ("-narrow", narrow)] {
                let details = PullRequestDetailsStore()
                details.readRecord = { [weak store] key in store?.record(for: key) }
                details.itemsChanged(store.items)
                details.show(yours)
                details.open(file: file.path)
                renderings.append((name: "pull-requests-file-active" + suffix, view: environment(page(details, size: size).environmentObject(showing(.active)))))
            }
        }
        return renderings
    }
}

// MARK: - A pull request's files, for --render

extension AzureDevOpsSource {
    /// The file whose page `--render` draws: in the demo, the payments client, which a thread waits on you on, and the
    /// picture the change adds, which isn't text; else the first file a thread that waits on you is on, or the first file.
    private static let renderedFiles = ["/src/PaymentsClient.cs", "/docs/retry-backoff.png"]

    /// When `--render` says you last looked at the pull request whose Files it draws since then: before its latest update.
    private static let renderedLook: TimeInterval = -4 * 3_600

    /// The demo's upgrade to .NET 9, whose Files and lock file `--render` draws too: a file that changed in more places
    /// than BriefBar lines up exactly, whose count is only about right.
    private static let renderedUpgrade = (number: 4110, file: "/agents/packages.lock.json")

    /// Reads the change of the first of your pull requests that needs you before `--render` draws its Files and a file's
    /// page: its files, all of the change and, in the demo, since its first update, each one's lines counted, up to twenty,
    /// and the diffs of the files it draws.
    func loadFilesForRendering(store: PRStore) async {
        guard let files = pullRequestFiles, let code = pullRequestCode, let item = renderedPullRequests(store).first,
              let record = store.record(for: item.key)
        else { return }
        // Held while `--render` draws.
        _ = code.hold(item.key)
        let isDemo = store.mode == .demo
        await files.readAll(
            of: record.pullRequest, scopes: isDemo ? [.whole, .since(1)] : [.whole], diffs: isDemo ? Self.renderedFiles : [], counting: 20
        )
        if isDemo, let upgrade = store.items.first(where: { $0.key.number == Self.renderedUpgrade.number }),
           let upgradeRecord = store.record(for: upgrade.key) {
            _ = code.hold(upgrade.key)
            await files.readAll(of: upgradeRecord.pullRequest, diffs: [Self.renderedUpgrade.file])
        }
        // From your own, the file its pictures show, which takes its files to choose.
        guard !isDemo, case .read(let changes)? = files.list(of: item.key, .whole), let file = renderedFile(in: changes, of: item, store)
        else { return }
        await files.readAll(of: record.pullRequest, diffs: [file.path], counting: 0)
    }

    /// The file whose page `--render` draws: the demo's, or else the first with a thread on it, or else the first.
    private func renderedFile(in changes: ChangedFiles, of item: PRSnapshot, _ store: PRStore) -> FileChange? {
        changes.files.first { FileChange.ID(path: Self.renderedFiles[0]) == $0.id }
            ?? changes.files.first { file in store.record(for: item.key)?.details?.threads.contains { $0.filePath == file.path } == true }
            ?? changes.files.first
    }

    /// The Pull Requests page with the details of the first of your pull requests that needs you at their Files, all of the
    /// change and, for the demo's, what changed since you last looked; and a file's page, beside the list, over it in a
    /// narrow window, filling the page, at the comment on it that waits on you, and for a file that isn't text. In the demo,
    /// the Files and the lock file of its upgrade to .NET 9 too, whose counts are only about right.
    func pullRequestFilesRenderings() -> [(name: String, view: AnyView)] {
        guard let store, let files = pullRequestFiles, let item = renderedPullRequests(store).first,
              case .read(let changes)? = files.list(of: item.key, .whole)
        else { return [] }
        let page = renderedFile(in: changes, of: item, store)
        let binary = changes.files.first { FileChange.ID(path: Self.renderedFiles[1]) == $0.id }
        // The thread on it that waits on you, for its page to go to.
        let thread = page.flatMap { page in
            PullRequestPanel(item, record: store.record(for: item.key)).threads.waitingOnYou.first { thread in
                thread.thread.filePath.map { FileChange.ID(path: $0) == page.id } ?? false
            }?.id
        }
        let wide = CGSize(width: 1_000, height: 720)
        var shown: [(name: String, item: PRSnapshot, file: FileChange?, thread: Int?, since: Bool, fills: Bool, size: CGSize)] = [
            ("pull-requests-details-files", item, nil, nil, false, false, wide),
            ("pull-requests-details-files-since", item, nil, nil, true, false, wide),
            ("pull-requests-file", item, page, nil, false, false, wide),
            ("pull-requests-file-narrow", item, page, nil, false, false, CGSize(width: 560, height: 720)),
            ("pull-requests-file-filled", item, page, nil, false, true, wide),
            ("pull-requests-file-comment", item, page, thread, false, false, wide),
            ("pull-requests-file-binary", item, binary, nil, false, false, CGSize(width: 1_000, height: 560)),
        ]
        if store.mode == .demo, let upgrade = store.items.first(where: { $0.key.number == Self.renderedUpgrade.number }),
           case .read(let upgradeChanges)? = files.list(of: upgrade.key, .whole) {
            let lock = upgradeChanges.files.first { FileChange.ID(path: Self.renderedUpgrade.file) == $0.id }
            shown.append(("pull-requests-details-files-approximate", upgrade, nil, nil, false, false, wide))
            shown.append(("pull-requests-file-approximate", upgrade, lock, nil, false, false, wide))
        }
        var renderings: [(name: String, view: AnyView)] = []
        for (name, item, file, thread, since, fills, size) in shown {
            if name.hasPrefix("pull-requests-file"), file == nil { continue }
            // What changed since you last looked is read ahead only for the demo's.
            if since, store.mode != .demo { continue }
            // A store for each, since each scrolls its details once.
            let details = PullRequestDetailsStore()
            details.readRecord = { [weak store] key in store?.record(for: key) }
            details.itemsChanged(store.items)
            if since {
                // As if you'd last looked before its latest update, and as the list has it otherwise.
                let looked = Date().addingTimeInterval(Self.renderedLook)
                details.cutoffs = { [weak store] key in
                    store.map { .init(seen: $0.seenCutoff(for: key), dismissed: $0.dismissedCutoff(for: key), looked: looked) }
                }
                details.classify = { [weak store] record, seen in store?.snapshot(of: record, seenAt: seen) }
            }
            details.show(item, at: file == nil ? .files : nil)
            if since, let update = changes.lastSeenUpdate(at: details.lastLooked) { details.scope = .since(update) }
            if let file { details.open(file: file.path, at: thread) }
            details.fillsPage = fills
            let view = PullRequestsPage()
                .environmentObject(details)
                .environment(\.panelStyle, .page)
                .textSize(from: services)
                .frame(width: size.width, height: size.height)
                .background(WindowBackdrop())
                .environment(\.isRendering, true)
            renderings.append((name: name, view: environment(view)))
        }
        return renderings
    }
}

// MARK: - A pull request's merge conflicts, for --render

extension AzureDevOpsSource {
    /// The first of your open pull requests whose merge conflicts, whose details `--render` draws at them.
    private func conflictingPullRequest(_ store: PRStore) -> PRSnapshot? {
        store.items.first { item in
            guard item.role == .author, let pullRequest = store.record(for: item.key)?.pullRequest else { return false }
            return pullRequest.status == .active && pullRequest.hasConflicts
        }
    }

    /// Reads which files conflict before `--render` draws them, as the details would as they come on screen in a window
    /// that shows them: in the demo, for each pull request with conflicts; otherwise for those whose details it draws. And
    /// the files of the one whose details it draws at its conflicts, which show under them.
    func loadConflictsForRendering(store: PRStore) async {
        guard let code = pullRequestCode, let conflicts = pullRequestConflicts else { return }
        let drawn = conflictingPullRequest(store)
        let items = store.mode == .demo ? store.items : renderedPullRequests(store) + [drawn].compactMap { $0 }
        for item in items {
            guard let pullRequest = store.record(for: item.key)?.pullRequest, pullRequest.hasConflicts else { continue }
            // Held while `--render` draws.
            _ = code.hold(item.key)
            await conflicts.readAll(of: pullRequest)
        }
        if let drawn, let pullRequest = store.record(for: drawn.key)?.pullRequest, pullRequestFiles?.list(of: drawn.key, .whole) == nil {
            await pullRequestFiles?.readAll(of: pullRequest, counting: 20)
        }
    }

    /// The Pull Requests page with the details of the first of your pull requests whose merge conflicts, taken to its
    /// conflicts, as What's Left takes them there, beside the list as in a big window and over it in a narrow one; and, in
    /// the demo, with what you can ask Copilot about them in each state: Resolve's composer open, with your words, Copilot
    /// resolving them in the pull request's session, resolved and not pushed, with the fix ready to push at the foot, and
    /// what the session explained of them. Each from made-up states, through `CopilotActionsPreview`: nothing's sent or
    /// asked.
    func pullRequestConflictRenderings() -> [(name: String, view: AnyView)] {
        guard let store, let item = conflictingPullRequest(store) else { return [] }
        let wide = CGSize(width: 1_000, height: 900)
        let narrow = CGSize(width: 560, height: 900)
        var shown: [(name: String, preview: CopilotActionsPreview?, sizes: [(suffix: String, size: CGSize)])] = [
            ("pull-requests-conflicts", nil, [("", wide), ("-narrow", narrow)]),
        ]
        if store.mode == .demo {
            // As of the demo's now, however long rendering takes.
            let now = store.now
            let session = Self.renderedConflictsSession
            func work(_ state: CopilotWork.State, ago minutes: Double) -> CopilotWork {
                CopilotWork(
                    part: .conflicts, purpose: .fix, state: state, session: session, forkedFrom: nil, isTask: false,
                    since: now.addingTimeInterval(-minutes * 60)
                )
            }
            let how = "Keep main's Refunded, under the new names, and drop the legacy mapper as main did"
            shown += [
                ("pull-requests-conflicts-resolve", CopilotActionsPreview(composers: [
                    .init(part: .conflicts, ask: .fix, text: how, destination: .session(session)),
                ]), [("", wide), ("-narrow", narrow)]),
                ("pull-requests-conflicts-resolving", CopilotActionsPreview(
                    work: [.conflicts: work(.working("Run the order tests"), ago: 3)], ready: []
                ), [("", wide)]),
                ("pull-requests-conflicts-resolved", CopilotActionsPreview(
                    work: [.conflicts: work(.done(
                        "Merged main in: kept Refunded under the new names, let LegacyOrderMapper go as main did, and put both sets of tests in OrderStatusTests.cs. The tests pass."
                    ), ago: 1)],
                    ready: [ReadyFixes(session: session, forkedFrom: nil, isTask: false, parts: [.conflicts], latest: now)]
                ), [("", wide)]),
                ("pull-requests-conflicts-explained", CopilotActionsPreview(questions: [
                    .conflicts: .init(
                        session: session, asked: nil, askedAt: now.addingTimeInterval(-150),
                        state: .answered(DemoData.conflictsExplanation(pullRequest: item.key.number)), endedAt: now.addingTimeInterval(-90)
                    ),
                ], ready: []), [("", CGSize(width: 1_000, height: 1_100))]),
            ]
        }
        var renderings: [(name: String, view: AnyView)] = []
        for (name, preview, sizes) in shown {
            for (suffix, size) in sizes {
                // A store for each, since each scrolls its details there once.
                let details = PullRequestDetailsStore()
                details.readRecord = { [weak store] key in store?.record(for: key) }
                details.itemsChanged(store.items)
                details.show(item, at: .section(.conflicts))
                let view = PullRequestsPage()
                    .environmentObject(details)
                    .environment(\.copilotActionsPreview, preview)
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

    /// The Copilot demo's session that renamed !4079's enum, ‘Rename the order status enum’ (scripts/make-copilot-demo-data.swift).
    private static let renderedConflictsSession = "7b1c9d3e-5f2a-4b8c-9d6e-0a1b2c3d4e15"
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
