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
            SUMMARY: Its linked pull requests and Copilot sessions are moving along, and nothing waits on you yet.
            """
    }

    private static let answers: [(String, String)] = [
        ("WORK ITEM 5101:", """
            HEADLINE: Guests should get a sign-in prompt, but Copilot hid Save for later from them.
            NEXT FOR: you
            NEXT: Ask Copilot to show guests a prompt to sign in instead of hiding the button.
            SUMMARY: You told Priya Shah that only signed-in shoppers save items and that guests get a prompt to sign in, \
            but Copilot's session on the saved-items branch hides the button from guests. Sam's !4120 adds the saved_items \
            table and an API to the cart service, and nobody has picked it up for review. Showing saved items under the \
            cart, 5103, is with Copilot now; moving one back to the cart, 5104, hasn't started.
            """),
        ("WORK ITEM 5110:", """
            HEADLINE: Completing !4091 is all that's left: the rounding fix is approved.
            NEXT FOR: you
            NEXT: Complete !4091.
            SUMMARY: Totals with a coupon came out a cent low, because CouponService cut discounted amounts short instead \
            of rounding them. Copilot made it round half up to each currency's minor units, so a $19.99 item with SAVE15 \
            now comes to $16.99, with a test for every currency. Priya Shah and Chen Wei approved !4091; once it's \
            completed, the bug and its task, 5112, can be closed.
            """),
        ("WORK ITEM 5112:", """
            HEADLINE: Done in code; the task closes once !4091 is completed.
            NEXT FOR: you
            NEXT: Complete !4091.
            SUMMARY: Copilot changed CouponService to round half up and added a test for every currency. Priya Shah and \
            Chen Wei approved its pull request, !4091, so completing it is all that's left.
            """),
        ("WORK ITEM 5103:", """
            HEADLINE: Saved items show under the cart; Copilot opens a pull request once tests pass.
            NEXT FOR: Copilot
            NEXT: Finish the cart tests, then open a pull request for 5103.
            SUMMARY: Copilot added SavedItemsList, which reads saved items from the cart service and shows each with \
            CartItemRow, without the quantity stepper, and says Nothing saved yet when there are none. Nothing is \
            committed yet: it commits and opens a pull request once the cart tests pass.
            """),
        ("PULL REQUEST !4102:", """
            HEADLINE: Sam's required vote waits on capping the backoff at 30 seconds.
            NEXT FOR: you
            NEXT: Cap the backoff at 30 seconds, then reply to Sam on PaymentsClient.cs.
            SUMMARY: !4102 adds exponential backoff to the payments client, starting at 200 ms and doubling. Priya Shah \
            approved it. Sam Rivera, who's required, asks for a 30-second cap, since the load balancer gives up after 60 \
            seconds anyway, and hasn't voted.
            """),
        ("PULL REQUEST !4091:", """
            HEADLINE: Approved by both reviewers; completing it closes bug 5110 and task 5112.
            NEXT FOR: you
            NEXT: Complete !4091.
            SUMMARY: Copilot opened !4091 from task 5112: CouponService now rounds discounted totals half up to each \
            currency's minor units, with a test for every currency. Priya Shah and Chen Wei approved it.
            """),
        ("COPILOT SESSION: Save items for later", """
            HEADLINE: Save for later works, but it hides the button from guests instead of prompting.
            NEXT FOR: you
            NEXT: Ask Copilot to show guests a prompt to sign in, as you told Priya.
            SUMMARY: On !4120's branch, Copilot added a Save for later button to each cart item and hid it from guests, \
            and the cart and cart service tests pass. Story 5101's comments say guests should get a prompt to sign in \
            instead.
            """),
        ("COPILOT SESSION: Add dark mode to settings", """
            HEADLINE: It's waiting for you to choose how dark mode is picked; nothing's changed yet.
            NEXT FOR: you
            NEXT: Answer it in the session: follow the system, add a switch, or both.
            SUMMARY: The session on shop-web's dark-mode branch read the settings page and stopped to ask whether dark \
            mode should follow the system, have a switch of its own, or both. It goes on once you answer.
            """),
    ]
}
