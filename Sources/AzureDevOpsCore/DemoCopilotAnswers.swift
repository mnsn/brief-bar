import Foundation

extension DemoData {
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
