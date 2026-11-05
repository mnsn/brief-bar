import BriefBarCore
import SwiftUI

/// Pull Request Order, on the Pull Requests page in Settings, as rows of its form: off until you turn it on, what it does and
/// reads, and Forget All Orders…, which forgets, on or off, every order sessions told BriefBar, what it saw become of their
/// pull requests, the mission you focus on, and the names you gave missions.
package struct PullRequestOrderSettingView: View {
    @ObservedObject private var order: PullRequestOrder
    /// Tells the rest of the app, such as Agents, which adds Pull Request Order's skill to Copilot while both are on.
    private let changed: (Bool) -> Void

    @LocalState private var confirmsForget = false

    package init(order: PullRequestOrder, changed: @escaping (Bool) -> Void = { _ in }) {
        self.order = order
        self.changed = changed
    }

    nonisolated package static let title = "Pull Request Order"
    package static let explanation = """
        Lists your pull requests By Mission, on the Pull Requests pages of BriefBar's window: the ones that go together, in \
        the order they should merge, as a graph and on a map, with the order on each row. The order comes from stacks \
        BriefBar sees, and from what Copilot sessions tell it, which may be incomplete or late. It never changes a pull \
        request's status, what's left before you can complete it, or your lists. With Show Links on too, Azure DevOps' pull \
        requests whose work items are for the same story go together, as that story's mission, in its tasks' order, unless \
        a stack or a session's order says otherwise: for that, Show Links also reads the parent and place in the backlog of \
        the work items linked to your pull requests, and what those stories are when BriefBar hasn't read them already. While \
        Apple Intelligence is on, it names each mission on this Mac, from its pull requests', work items' and sessions' \
        titles; you can rename one. While it's on, BriefBar also reads, from GitHub, each pull request's base branch, \
        whether it's from a fork, its repository's default branch and its place in a stack, in its usual refresh; and, from \
        the Copilot app, which pull request each session opened. With agents on, sessions get the tools to tell BriefBar an \
        order as they start, and Copilot gets a skill that says when to. It keeps references only, and the names you give \
        missions. Turning it off keeps the orders and the names, unused, until you forget them.
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
                    focus on, and the names you gave missions. Sessions that name an order are told it's forgotten.
                    """)
            }
    }
}
