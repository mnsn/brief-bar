import BriefBarCore
import SwiftUI

/// Pull Request Order, on the Pull Requests page in Settings, as rows of its form: off until you turn it on, what it does and
/// reads; Forget All Orders…, which forgets, on or off, every order sessions told BriefBar, what it saw become of their
/// pull requests, the mission you focus on, your changes to missions, the names you gave missions, the suggested splits
/// you kept together and the order you put your work in on My Work; and Forget Stages…, which forgets the stages you and sessions set, how far each of your pull requests
/// got, and the pull requests you chose in Up Next.
package struct PullRequestOrderSettingView: View {
    @ObservedObject private var order: PullRequestOrder
    /// Tells the rest of the app, such as Agents, which adds Pull Request Order's skill to Copilot while both are on.
    private let changed: (Bool) -> Void

    @LocalState private var confirmsForget = false
    @LocalState private var confirmsForgetStages = false

    package init(order: PullRequestOrder, changed: @escaping (Bool) -> Void = { _ in }) {
        self.order = order
        self.changed = changed
    }

    nonisolated package static let title = "Pull Request Order"
    package static let explanation = """
        Lists your pull requests By Mission, on the Pull Requests pages of BriefBar's window: the ones that go together, in \
        the order they should merge, as a graph and on a map, with the order on each row. The order comes from stacks \
        BriefBar sees, and from what Copilot sessions tell it, which may be incomplete or late. On Azure DevOps' pull \
        requests, you can change a mission yourself, from a pull request's menu: which merges next, what it merges after, \
        and which mission it's in. A session's later change wins only where it goes against yours, and says who made \
        it; you can put yours back. It never changes a pull request's status, what's left before you can complete \
        it, or your lists. With Show Links on too, Azure DevOps' pull requests whose work items are for the same story \
        go together, as that story's mission, in its tasks' order, unless you, a session's order or a stack say \
        otherwise: for that, Show Links also reads the parent and place in the backlog of the work items linked to your \
        pull requests, and what those stories are when BriefBar hasn't read them already. While Apple Intelligence is \
        on, it names each mission on this Mac, from its pull requests', work items' and sessions' titles; you can rename \
        one. Apple Intelligence also suggests splitting a mission whose pull requests look like different work; nothing \
        moves until you click Split. BriefBar keeps the suggestions you keep together, until you forget them. While it's \
        on, BriefBar also reads, from GitHub, each pull request's base branch, whether it's from a fork, \
        its repository's default branch and its place in a stack, in its usual refresh; and, from the Copilot app, which \
        pull request each session opened. On Azure DevOps' pull requests, in the window and the menu bar, it also shows \
        each one's stage, In progress, Your review, Teammate's review, Approved, Can merge or Waits for another PR, as \
        BriefBar works it out from Azure DevOps and Copilot, never moving one of yours back on its own, or as you or a \
        session set it, the latest winning; what's next, at \
        the top of the Pull Requests page, where you can choose which pull request each kind shows; and a Board beside \
        List and Map. With agents on, sessions get the tools to tell BriefBar an order, and each pull request's stage, as \
        they work, and Copilot gets a skill that says when to. It keeps the orders and your changes to missions, by \
        reference, the names you give missions, and the pull request you choose for each kind of next, by reference, with \
        the account you chose it with, until it moves on; how far each of your pull requests got, for each account, by \
        reference, until it merges or closes; and the stages you set, for each Azure DevOps account you sign \
        in with, and those each session set, as references only, with only what would end each: for In progress, its \
        commit; for Teammate's review, the votes it was set over, never who cast them (on someone else's, your own vote \
        and its commit); until they end or you forget them; what a session set shows only while the Copilot app lists \
        it. What you change, set or choose of a pull request sent to you in a chat stays in memory only. None of it goes \
        to Azure DevOps or GitHub. Turning it off keeps them, unused, until you forget them.
        """

    package var body: some View {
        Toggle(isOn: Binding(get: { order.isOn }, set: { on in
            order.setOn(on)
            changed(on)
        })) {
            Text(Self.title)
            Text(Self.explanation)
        }
        Button("Forget All Orders…") { confirmsForget = true }
            .disabled(!order.keepsAnything)
            .confirmationDialog("Forget all orders?", isPresented: $confirmsForget) {
                Button("Forget All Orders", role: .destructive) { order.forgetAll() }
            } message: {
                Text("""
                    BriefBar forgets every order sessions told it, what it saw become of their pull requests, the mission you \
                    focus on, your changes to missions, the names you gave missions, the suggested splits you kept together, \
                    and the order you put your work in on My Work. Sessions that name an order are told it's forgotten.
                    """)
            }
        Button("Forget Stages…") { confirmsForgetStages = true }
            .disabled(!order.keepsStages)
            .confirmationDialog("Forget the stages you and sessions set?", isPresented: $confirmsForgetStages) {
                Button("Forget Stages", role: .destructive) { order.forgetStages() }
            } message: {
                Text("""
                    BriefBar forgets the stages you set on pull requests, for every account, those Copilot sessions set, how \
                    far each of your pull requests got, and the pull requests you chose in Up Next, and works each one's stage \
                    out again from Azure DevOps and Copilot.
                    """)
            }
    }
}

/// My Work Page, on the Pull Requests page in Settings, first among Azure DevOps' own, as it shows only Azure DevOps' pull
/// requests: off until you turn it on, what it does and reads; disabled while Pull Request Order is off, which it needs,
/// saying so.
package struct MyWorkPageSettingView: View {
    @ObservedObject private var order: PullRequestOrder

    package init(order: PullRequestOrder) {
        self.order = order
    }

    nonisolated package static let title = "My Work Page (preview)"
    package static let explanation = """
        Moves Up Next and the Board from Azure DevOps' Pull Requests page in BriefBar's window to a page of their own, My \
        Work, just before it; Pull Requests keeps List, Map and By Status. With + Sprint Tasks, at the top of My Work, the \
        Board shows your sprint work too: what hasn't started in To start, a column before In progress, and what has, \
        without a pull request, in In progress. Work items and their pull requests go together only through Show Links' \
        links, which it needs. While My Work shows your sprint tasks, BriefBar reads your team's current sprint, as while \
        its Sprint page is on screen, and the pull requests linked to its work items. BriefBar keeps the order you put your \
        work in on My Work, in To start and In progress, by reference, and none of it goes to Azure DevOps. A preview: it \
        may still change.
        """
    package static let needsOrder = "It needs Pull Request Order, above: turn that on first."

    package var body: some View {
        Toggle(isOn: Binding(get: { order.myWorkPage }, set: { order.setMyWorkPage($0) })) {
            Text(Self.title)
            Text(Self.explanation)
        }
        .disabled(!order.isOn)
        if !order.isOn {
            Label(Self.needsOrder, systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
    }
}
