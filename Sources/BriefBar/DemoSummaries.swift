import BriefBarCore
import BriefBarUI
import Foundation

/// Made-up summaries for the demo, which never runs Copilot: what Copilot might write of the demo sprint's work items with
/// links, of one of its pull requests and of one of its sessions, in the form the prompt asks for, by what the prompt is
/// about.
enum DemoSummaries {
    static let write: StorySummaries.Writer = { prompt, _ in
        .success(answer(to: prompt))
    }

    static func answer(to prompt: String) -> String {
        // The data's first line about a thing names what it's about: "WORK ITEM 5110: Coupon totals…", after who reads it
        // and what they see, in a block of their own.
        let data = prompt.components(separatedBy: "<data>\n").last ?? prompt
        let first = data.components(separatedBy: "\n\n")
            .first { !$0.hasPrefix("READER:") && !$0.hasPrefix("SHOWN:") }
            .flatMap { $0.split(whereSeparator: \.isNewline).first.map(String.init) } ?? ""
        for (subject, answer) in answers where first.hasPrefix(subject) {
            return answer
        }
        return """
            HEADLINE: Work on it is under way across its linked pull requests and sessions, and nothing blocks it.
            NEXT FOR: Nobody
            NEXT: Nothing
            SUMMARY:
            - **Status:** Its linked pull requests and Copilot sessions are moving along, and nothing waits on you yet.
            """
    }

    private static let answers: [(String, String)] = [
        ("WORK ITEM 5101:", """
            HEADLINE: Guests should get a sign-in prompt, but Copilot hid Save for later from them.
            NEXT FOR: you
            NEXT: Ask Copilot to show guests a prompt to sign in instead of hiding the button.
            SUMMARY:
            - **Differs:** You told Priya Shah that guests get a prompt to sign in, but Copilot's session on the \
            saved-items branch hides the button from them.
            - **Built:** Sam's !4120 adds the `saved_items` table and its API to the cart service; showing saved items \
            and moving one back to the cart are tasks of their own.
            """),
        ("WORK ITEM 5110:", """
            HEADLINE: Copilot's fix rounds half up, so $19.99 with SAVE15 now comes to $16.99.
            NEXT FOR: you
            NEXT: Complete !4091.
            SUMMARY:
            - **Cause:** Totals with a coupon came out a cent low: `CouponService` cut discounted amounts short instead of \
            rounding them.
            - **Fix:** It now rounds half up to each currency's minor units, with a test for every currency.
            - **Then:** Once !4091 is completed, the bug and its task, 5112, can be closed.
            """),
        ("WORK ITEM 5112:", """
            HEADLINE: Done in code: the task closes once !4091 is completed.
            NEXT FOR: you
            NEXT: Complete !4091.
            SUMMARY:
            - **Done:** Copilot changed `CouponService` to round discounted totals half up, with a test for every currency.
            - **Then:** Bug 5110 can be closed with it.
            """),
        ("WORK ITEM 5103:", """
            HEADLINE: Copilot built the saved-items list; nothing's committed until the cart tests pass.
            NEXT FOR: Copilot
            NEXT: Finish the cart tests, then open a pull request.
            SUMMARY:
            - **Done:** `SavedItemsList` reads saved items from the cart service and shows each with `CartItemRow`, \
            without the quantity stepper, and says "Nothing saved yet" when there are none.
            - **Needs:** The cart service's saved-items API from Sam's !4120, which isn't completed yet.
            """),
        ("PULL REQUEST !4102:", """
            HEADLINE: Sam Rivera's required vote waits on a cap for the backoff.
            NEXT FOR: you
            NEXT: Cap the backoff, then reply to Sam on PaymentsClient.cs.
            SUMMARY:
            - **Change:** Exponential backoff for the payments client: 200 ms at first, doubling, with no cap yet.
            - **Review:** Sam Rivera is required and hasn't voted; Priya Shah approved.
            """),
        ("PULL REQUEST !4091:", """
            HEADLINE: Completing it closes bug 5110 and task 5112.
            NEXT FOR: you
            NEXT: Complete !4091.
            SUMMARY:
            - **Change:** `CouponService` now rounds discounted totals half up to each currency's minor units, with a test \
            for every currency.
            - **From:** Copilot opened it from task 5112.
            """),
        ("COPILOT SESSION: Save items for later", """
            HEADLINE: Save for later works, but it hides the button from guests instead of asking them to sign in.
            NEXT FOR: you
            NEXT: Ask Copilot to show guests a prompt to sign in, as you told Priya.
            SUMMARY:
            - **Done:** A Save for later button on each cart item, next to Remove, pushed to !4120's branch; all 112 tests \
            pass.
            - **Then:** Copilot says showing saved items under the cart, 5103, comes next.
            """),
        ("COPILOT SESSION: Add dark mode to settings", """
            HEADLINE: Nothing's changed yet: it needs your answer before it edits the settings page.
            NEXT FOR: you
            NEXT: Answer its question in the session.
            SUMMARY:
            - **Read:** shop-web's settings page and its theme code, on the dark-mode branch.
            """),
    ]
}
