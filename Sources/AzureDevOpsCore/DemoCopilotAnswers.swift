import Foundation

extension DemoData {
    /// What the demo says a Copilot session answers Ask…: where it stands, or, to your own question, why it did what it did,
    /// made up, as the rest of the demo's data is, never asked of Copilot. For the demo's sessions that the window shows
    /// most: the one that wrote !4102's retry backoff, the one saving cart items for later, on !4120's branch, and the one
    /// adding dark mode to the settings page, which waits for your answer; any other says it in general.
    /// - Parameters:
    ///   - session: the session's ID.
    ///   - question: what you asked, in your words; nil for where it stands.
    public static func sessionAnswer(session: String, question: String?) -> String {
        let (stands, why) = sessionAnswers[session.lowercased()] ?? (genericStand, genericWhy)
        return question == nil ? stands : why
    }

    /// Where each of the demo's sessions stands, and why it did what it did, by its ID.
    private static let sessionAnswers: [String: (stands: String, why: String)] = [
        "2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a14": (
            """
            **Done:** `PaymentsClient` retries with exponential backoff, from 200 ms, doubling each time, with tests in \
            `PaymentsClientTests`. It's pushed to payments-retry, and !4102 is open for it.

            **Left:** Sam's comment on the delay: he wants it capped, so that a long outage doesn't stretch a retry past the \
            load balancer's 60 seconds. I haven't changed it yet.

            **Waiting on:** you, to say where to cap it; then Sam's review.
            """,
            """
            I didn't change the delay you asked for: it starts at 200 ms and doubles, as your first message said. What I \
            added is the jitter, up to 20% of each wait, so that clients that failed together don't all retry at the same \
            moment.

            Without a cap, the eighth retry waits about 25 seconds, and the ninth 51, which is what Sam's comment is about. \
            Capping it at 30 seconds would keep every retry under the load balancer's 60.
            """
        ),
        "c3e8f1a2-6b4d-4e97-a1c5-2f7d9b0e8a11": (
            """
            **Done:** the `saved_items` table and its migration, and the API to save a cart item and list the saved ones, \
            keeping the price each had in the cart, as you asked, with tests.

            **Left:** the **Save for later** button on each cart item, and asking guests to sign in first.

            **Waiting on:** nothing: I'll go on with the button once you say so.
            """,
            """
            A saved item keeps the price it had in the cart because you asked for that: a shopper who saves something on \
            sale should find it at that price when they come back. So `saved_items` has its own `price` column, rather \
            than reading the product's price, and the API returns it.
            """
        ),
        "0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01": (
            """
            **Done:** the dark palette, in `theme.ts`, and the settings page reads its colors from it.

            **Left:** how it's switched on: whether dark mode follows the system's appearance, has a switch in settings, \
            or both.

            **Waiting on:** you: I asked in the session which you want.
            """,
            """
            The settings page reads its colors from `theme.ts` now, rather than having them in its styles, so that the \
            dark palette can replace them all at once, and the other pages can follow later without changing their own.
            """
        ),
    ]

    /// Where any other session stands, in general.
    private static let genericStand = """
        **Done:** what this session set out to do, as far as its last turn went, and its tests pass.

        **Left:** nothing I know of, but a review of the change.

        **Waiting on:** you, to look it over.
        """

    /// Why any other session did what it did, in general.
    private static let genericWhy = """
        I did it that way because it's the smallest change that does what you asked for in this session, and the tests \
        that cover it pass. Ask about a file or a decision by name, and I'll say more.
        """

    /// What the demo says a Copilot session answers when you ask it why a pull request's build failed, with Explain: made up,
    /// as the rest of the demo's data is, never asked of Copilot. For !4088, whose shop-web CI fails two delivery estimate
    /// tests, as main's latest run does.
    public static func buildExplanation(pullRequest number: Int) -> String {
        guard number == 4088 else {
            return """
                The build fails in a step this pull request's change runs: its first error is in code the change touches, \
                and the pipeline passes on the target branch, so it's this change rather than a flaky test or the build's \
                infrastructure.
                """
        }
        return """
            Two tests in `DeliveryEstimateTests` fail in **Run unit tests**:

            - `EstimateSkipsWeekends` expects Monday and gets Saturday.
            - `EstimateUsesTheWarehouseTimeZone` expects 2 days and gets 3.

            It isn't this change. Both test the dates `DeliveryEstimate` works out, which this pull request doesn't touch: it \
            only shows the estimate on the product page. main's latest run fails the same two tests, the same way. They \
            aren't flaky either: each fails on every run, with fixed dates.

            What broke them is on main: `AddBusinessDays` counts calendar days now, so Thursday plus two business days lands \
            on Saturday, and the cutoff is compared in UTC rather than in the warehouse's time zone. Fixing that here would \
            carry main's fix in this pull request; once main's fixed, merging it in turns this build green.
            """
    }
}
