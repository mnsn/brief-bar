import BriefBarCore
import BriefBarUI
import Foundation

/// Made-up summaries for the demo, which never runs Copilot: what Copilot might write of the demo sprint's work items with
/// links, in the form the prompt asks for, by the work item the prompt is about.
enum DemoSummaries {
    static let write: StorySummaries.Writer = { prompt, _ in
        .success(answer(to: prompt))
    }

    static func answer(to prompt: String) -> String {
        // The data's first line names the work item: "WORK ITEM 5110: Coupon totals…".
        let data = prompt.components(separatedBy: "<data>\n").last ?? prompt
        let first = data.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        for (id, answer) in answers where first.hasPrefix("WORK ITEM \(id):") {
            return answer
        }
        return """
            HEADLINE: Work on it is under way across its linked pull requests and sessions.
            NEXT: Nothing
            SUMMARY: Its linked pull requests and Copilot sessions are moving along, and nothing waits on you yet.
            """
    }

    private static let answers: [(Int, String)] = [
        (5101, """
            HEADLINE: Saving items works end to end; showing them under the cart is under way.
            NEXT: Sam Rivera: get !4120 reviewed and merged.
            SUMMARY: Sam's pull request !4120 adds a saved_items table and an API to the cart service, and waits for \
            reviewers. Copilot's session on its branch added a Save for later button to each cart item, hidden from guests, \
            with the cart and cart service tests passing. Showing saved items under the cart, 5103, is in progress with \
            Copilot, and moving one back to the cart, 5104, hasn't started.
            """),
        (5110, """
            HEADLINE: Fixed in !4091, which is approved and ready to complete.
            NEXT: You: complete !4091.
            SUMMARY: Copilot traced the bug to totals being truncated, and made CouponService round discounted totals half up \
            to each currency's minor units, so a $19.99 item with SAVE15 now comes to $16.99. It added tests for every \
            currency, which pass, and opened !4091. Priya Shah and Chen Wei approved it, and its payments-api CI build passed.
            """),
        (5112, """
            HEADLINE: Done: coupon totals round half up, in !4091.
            NEXT: You: complete !4091.
            SUMMARY: Copilot changed CouponService to round half up and added a test for every currency, which pass. Its pull \
            request, !4091, is approved by Priya Shah and Chen Wei, and its build passed.
            """),
        (5103, """
            HEADLINE: Copilot is building the saved items list under the cart.
            NEXT: Copilot: run the cart tests, then open a pull request for 5103.
            SUMMARY: Copilot added SavedItemsList, which reads saved items from the cart service and shows each with \
            CartItemRow, without the quantity stepper, and says Nothing saved yet when there are none. It's on the cart page \
            now, and the cart tests are running before it commits and opens a pull request.
            """),
    ]
}
