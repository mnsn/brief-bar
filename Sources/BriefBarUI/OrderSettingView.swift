import BriefBarCore
import SwiftUI

/// Pull Request Order, on the Pull Requests page in Settings, as rows of its form: off until you turn it on, what it does and
/// reads; Forget All Orders…, which forgets, on or off, every order sessions told BriefBar, what it saw become of their
/// pull requests, the mission you focus on, and your changes to missions; and Forget Stages…, which forgets the stages you
/// set.
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
        it, or your lists. While it's on, BriefBar also reads, from GitHub, each pull request's base branch, whether it's \
        from a fork, its repository's default branch and its place in a stack, in its usual refresh; and, from the Copilot \
        app, which pull request each session opened. On Azure DevOps' pull requests, in the window and the menu bar, it \
        also shows each one's stage, In progress, Your review, Teammate's review, Can merge or Waits for another PR, as \
        BriefBar works it out from Azure DevOps and Copilot, or as you set it; what's next, at the top of the Pull \
        Requests page; and a Board beside List and Map. With agents on, sessions get the tools to tell BriefBar an order \
        as they start, and Copilot gets a skill that says when to. It keeps the orders and your changes to missions, by \
        reference, and the stages you set, for each Azure DevOps account you sign in with, with only what would end each: \
        for In progress, its commit; for Teammate's review, the votes it was set over, never who cast them (on someone \
        else's, your own vote and its commit); until they end or you forget them. What you change or set of a pull \
        request sent to you in a chat stays in memory only. None of it goes to Azure DevOps or GitHub. Turning it off \
        keeps them, unused, until you forget them.
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
                    focus on, and your changes to missions. Sessions that name an order are told it's forgotten.
                    """)
            }
        Button("Forget Stages…") { confirmsForgetStages = true }
            .disabled(!order.keepsStages)
            .confirmationDialog("Forget the stages you set?", isPresented: $confirmsForgetStages) {
                Button("Forget Stages", role: .destructive) { order.forgetStages() }
            } message: {
                Text("""
                    BriefBar forgets the stages you set on pull requests, for every account, and works each one's stage out \
                    again from Azure DevOps and Copilot.
                    """)
            }
    }
}
