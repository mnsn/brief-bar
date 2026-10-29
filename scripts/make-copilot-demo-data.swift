// Creates a fake Copilot data directory with sessions in every state, one with the checkpoints Copilot
// writes in a long session, and the logs of the tasks the Azure DevOps demo sent to Copilot, for trying
// the app and for screenshots that don't show your own sessions:
//
//   swift scripts/make-copilot-demo-data.swift build/demo/copilot
//   BRIEFBAR_COPILOT_DIR=build/demo/copilot BriefBar --demo
//
// `make demo` and `make screenshots` do both. All names and text are made up. Timestamps are
// relative to now, so the data is regenerated each time.
import Foundation
import SQLite3

let marker = ".briefbar-copilot-demo"
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/demo/copilot", isDirectory: true)
    .standardizedFileURL
let fileManager = FileManager.default

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-copilot-demo-data: \(message)\n".utf8))
    exit(1)
}

// The directory is replaced, so refuse to touch anything this script didn't create (like ~/.copilot).
var isDirectory: ObjCBool = false
if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
    guard isDirectory.boolValue else {
        fail("\(root.path) exists and isn't a directory, so it won't be replaced")
    }
    let contents: [String]
    do {
        contents = try fileManager.contentsOfDirectory(atPath: root.path)
    } catch {
        fail("couldn't check what's in \(root.path): \(error.localizedDescription)")
    }
    guard contents.isEmpty || contents.contains(marker) else {
        fail("\(root.path) exists and wasn't created by this script, so it won't be replaced")
    }
    do {
        try fileManager.removeItem(at: root)
    } catch {
        fail("couldn't remove the old demo data in \(root.path): \(error.localizedDescription)")
    }
}
try fileManager.createDirectory(at: root.appending(path: "session-state"), withIntermediateDirectories: true)
try Data().write(to: root.appending(path: marker))

let now = Date()
let minute: TimeInterval = 60
let hour: TimeInterval = 3_600
let day: TimeInterval = 86_400

func ago(_ seconds: TimeInterval) -> Date {
    now.addingTimeInterval(-seconds)
}

func iso(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

func json(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Event logs

/// Builds `events.jsonl` like the Copilot CLI writes it, including its top-level key order
/// (`type, data, id, timestamp, parentId`).
struct Log {
    private(set) var lines: [String] = []
    private var count = 0

    private mutating func add(_ type: String, _ data: [String: Any] = [:], raw: String? = nil, at date: Date) {
        let line = #"{"type":"\#(type)","data":\#(raw ?? json(data)),"id":"\#(UUID().uuidString.lowercased())","timestamp":"\#(iso(date))","parentId":null}"#
        lines.append(line)
    }

    private mutating func nextId(_ prefix: String) -> String {
        count += 1
        return "\(prefix)_\(count)"
    }

    /// A new session whose first turn starts with `prompt`.
    mutating func start(_ prompt: String, at date: Date) {
        add("session.start", ["producer": "copilot-agent", "version": 1], at: date)
        add("user.message", ["content": prompt], at: date.addingTimeInterval(1))
        add("assistant.turn_start", ["turnId": "0"], at: date.addingTimeInterval(2))
    }

    /// The agent calls a tool, which is still running unless `finished`, saying `message` as it does.
    mutating func tool(
        _ name: String, _ arguments: [String: Any] = [:], title: String? = nil, saying message: String = "", at date: Date,
        finished: Bool = true
    ) {
        let id = nextId("call")
        let request: [String: Any] = ["toolCallId": id, "name": name, "arguments": arguments, "type": "function"]
        add("assistant.message", ["messageId": UUID().uuidString, "content": message, "toolRequests": [request]],
            at: date.addingTimeInterval(-1))
        var data: [String: Any] = ["toolCallId": id, "toolName": name, "arguments": arguments, "turnId": "0"]
        if let title { data["toolTitle"] = title }
        add("tool.execution_start", data, at: date)
        if finished {
            add("tool.execution_complete", raw: #"{"toolCallId":"\#(id)","success":true}"#, at: date.addingTimeInterval(3))
        }
    }

    mutating func permission(_ request: [String: Any], at date: Date) {
        add("permission.requested",
            ["requestId": nextId("permission"), "permissionRequest": request, "agentMode": "interactive"], at: date)
    }

    /// The agent calls the task done with `summary`, then says `message`, if there's one.
    mutating func finish(_ summary: String, saying message: String? = nil, at date: Date) {
        add("assistant.message", ["messageId": UUID().uuidString, "content": summary, "toolRequests": [[String: Any]]()],
            at: date.addingTimeInterval(-1))
        add("session.task_complete", ["summary": summary, "success": true], at: date)
        if let message {
            add("assistant.message", ["messageId": UUID().uuidString, "content": message, "toolRequests": [[String: Any]]()],
                at: date.addingTimeInterval(1))
        }
        add("assistant.turn_end", ["turnId": "0"], at: date.addingTimeInterval(message == nil ? 1 : 2))
    }

    mutating func error(_ message: String, at date: Date) {
        add("session.error", ["errorType": "query", "message": message], at: date)
    }
}

// MARK: - Sessions

struct Session {
    var id: String
    var name: String
    var project: String?  // nil for a chat
    var branch = "main"
    var mode = "interactive"
    /// The app's "a turn is in progress" flag, which stays on while the agent waits for you.
    var running = false
    var createdAt: Date
    var updatedAt: Date
    /// Context-window tokens in use, and the model's limit.
    var context: (tokens: Int, limit: Int)
    var log: Log
}

var sessions: [Session] = []

func session(
    _ id: String, _ name: String, project: String?, branch: String = "main", mode: String = "interactive",
    running: Bool = false, started: Date, updated: Date? = nil, context: (Int, Int), _ build: (inout Log) -> Void
) {
    var log = Log()
    log.start(name, at: started)
    build(&log)
    sessions.append(Session(id: id, name: name, project: project, branch: branch, mode: mode, running: running,
                            createdAt: started, updatedAt: updated ?? started, context: context, log: log))
}

/// The checkpoints Copilot writes as it compacts a long session's conversation, by session: each one's title, when it
/// was written, and its Markdown, a section in each tag.
var checkpoints: [String: [(title: String, at: Date, text: String)]] = [:]

/// Tasks the Azure DevOps demo sent to the Copilot CLI (`CopilotTaskEntry.demo`): their logs and checkpoints only,
/// since the app doesn't list them.
var sentTasks: [(id: String, log: Log)] = []

func sentTask(_ id: String, _ prompt: String, started: Date, _ build: (inout Log) -> Void) {
    var log = Log()
    log.start(prompt, at: started)
    build(&log)
    sentTasks.append((id, log))
}

/// What BriefBar sends a work item to Copilot with (`PromptTemplate.standard`).
func taskPrompt(_ id: Int, _ type: String, _ title: String) -> String {
    """
    Fix Azure DevOps \(type) \(id): \(title)
    https://dev.azure.com/contoso/Storefront/_workitems/edit/\(id)

    1. Read the work item with your Azure DevOps tools: its description, acceptance criteria, comments and \
    attachments, and its parent's.
    2. You're in a new git worktree of this repository, detached at origin/main. Create a branch for this work, named \
    the way this repository names its branches.
    3. Make the change, following the repository's instructions and conventions. Build, and run the tests that cover \
    what you changed.
    4. Commit, push the branch, and open a pull request into main in Azure DevOps that's published, ready for review, \
    and linked to work item \(id).

    Work on your own, without asking questions. If something stops you, say what and why. End with the pull request's \
    link.
    """
}

// Needs you: a question, a plan to approve and a permission prompt.
session("0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01", "Add dark mode to settings", project: "shop-web", branch: "dark-mode",
        running: true, started: ago(9 * minute), context: (46_000, 200_000)) { log in
    log.tool("view", ["path": "src/settings/SettingsPage.tsx"], at: ago(8 * minute))
    log.tool("ask_user", [
        "question": "Should dark mode follow the system appearance?",
        "choices": ["Yes, follow the system", "No, add a switch in settings", "Both, defaulting to the system"],
    ], at: ago(4 * minute), finished: false)
}
session("5d2e8a90-1f3b-4e7c-8a26-7b9c0d4e5f02", "Move sign-in to OAuth 2.1", project: "acme-api", branch: "oauth",
        mode: "plan", running: true, started: ago(14 * minute), context: (160_000, 272_000)) { log in
    log.tool("grep", ["pattern": "session_cookie"], at: ago(12 * minute))
    log.tool("exit_plan_mode", [
        "summary": "Replace cookie sessions with OAuth 2.1 and PKCE.",
    ], at: ago(2 * minute), finished: false)
}
session("9a4f2b17-c3d8-4e61-b5a0-2e8d7c6b4a03", "Release 2.4.0", project: "acme-api", branch: "release-2.4",
        running: true, started: ago(6 * minute), context: (31_000, 128_000)) { log in
    log.tool("bash", ["command": "npm version 2.4.0", "description": "Bump the version"], at: ago(5 * minute))
    log.tool("bash", ["command": "git push origin main --follow-tags", "description": "Push the release"],
             at: ago(1 * minute + 2), finished: false)
    log.permission(["kind": "shell", "fullCommandText": "git push origin main --follow-tags"], at: ago(1 * minute))
}

// Running: a project session and a chat.
session("3c7e9d21-8b4a-4f10-a6e2-5d1c0b9a8e04", "Fix flaky checkout test", project: "shop-web", branch: "fix-flaky-checkout",
        running: true, started: ago(7 * minute), context: (152_000, 200_000)) { log in
    log.tool("view", ["path": "tests/checkout.spec.ts"], at: ago(6 * minute))
    log.tool("bash", ["command": "for i in $(seq 20); do npm test -- checkout; done",
                      "description": "Run the checkout tests 20 times"],
             at: ago(40), finished: false)
}
session("e81b5c63-2d9f-4a7e-9c34-1f6a8b2d0c05", "When to use an actor instead of a lock?", project: nil,
        running: true, started: ago(25), context: (9_000, 200_000)) { log in
    log.tool("web_fetch", ["url": "https://docs.swift.org/swift-book/"], title: "Reading the Swift book",
             at: ago(10), finished: false)
}

// Done and stopped, recently enough to be highlighted.
session("6f0d3a85-4e2c-4b9a-8d17-9c5e2a1b3f06", "Update README screenshots", project: "website",
        started: ago(19 * minute), updated: ago(12 * minute), context: (88_000, 200_000)) { log in
    log.tool("bash", ["command": "make screenshots", "description": "Render the screenshots"], at: ago(17 * minute))
    log.finish("Replaced all four README screenshots.", at: ago(12 * minute))
}
session("b2a9e4c7-5f1d-4c38-a0b6-8e3d9f2c1a07", "Upgrade to Node 24", project: "shop-web", branch: "node-24",
        started: ago(26 * minute), updated: ago(20 * minute), context: (61_000, 128_000)) { log in
    log.tool("bash", ["command": "npm install", "description": "Install dependencies"], at: ago(24 * minute))
    log.error("Lost the connection to the model. Try again.", at: ago(20 * minute))
}

// Idle: ended a while ago.
session("47c1d8e2-9a3b-4f65-b8d0-6c2e1a9f4b08", "Set up CI", project: "website", branch: "ci",
        started: ago(3 * hour + 20 * minute), updated: ago(3 * hour), context: (54_000, 200_000)) { log in
    log.finish("Added a workflow that builds and deploys the site on every push to main.", at: ago(3 * hour))
}
session("d5e3a7b9-1c4f-4d82-9e6a-3b8f0c2d5e09", "Regex for semver tags", project: nil,
        started: ago(day + 2 * hour), updated: ago(day + 2 * hour - 90), context: (4_000, 200_000)) { log in
    log.finish("Use ^v(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)$ to match tags like v1.2.3.", at: ago(day + 2 * hour - 90))
}
session("8b2f6c4d-7e1a-4b93-a5c8-0d9e3f1b6a10", "Bump dependencies", project: "acme-api", branch: "deps",
        started: ago(2 * day + hour), updated: ago(2 * day), context: (132_000, 272_000)) { log in
    log.finish("Updated 14 packages to their latest minor versions. All tests pass.", at: ago(2 * day))
}

// A long one, with checkpoints, on the branch of the Azure DevOps demo's pull request !4120, so Show Links links them.
let savedItems = "c3e8f1a2-6b4d-4e97-a1c5-2f7d9b0e8a11"
session(savedItems, "Save items for later", project: "shop-web", branch: "saved-items", mode: "autopilot",
        started: ago(5 * hour), updated: ago(2 * hour + 55 * minute), context: (141_000, 200_000)) { log in
    log.tool("view", ["path": "src/server/cart/CartService.ts"], at: ago(4 * hour + 55 * minute))
    log.tool("grep", ["pattern": "cart_items"], at: ago(4 * hour + 50 * minute))
    log.tool("bash", ["command": "npm run db:migrate", "description": "Create the saved items table"],
             at: ago(4 * hour + 15 * minute))
    log.tool("bash", ["command": "npm test -- server/cart", "description": "Run the cart service tests"],
             at: ago(4 * hour))
    log.tool("edit", ["path": "src/web/cart/CartItemRow.tsx"], at: ago(3 * hour + 35 * minute))
    log.tool("bash", ["command": "npm test -- cart", "description": "Run the cart tests"],
             at: ago(3 * hour + 15 * minute))
    log.tool("bash", ["command": "git push origin saved-items", "description": "Push the branch"], at: ago(3 * hour))
    log.finish("""
        Shoppers can save cart items for later: a saved items table and API in the cart service, and a Save for later \
        button on each cart item, with tests.
        """, saying: """
        Pushed the saved-items branch, so Sam's pull request !4120 has all of it. Showing saved items under the cart, \
        work item 5103, comes next.
        """, at: ago(2 * hour + 55 * minute))
}
checkpoints[savedItems] = [
    ("Planning saved items for the cart", ago(4 * hour + 35 * minute), """
        <overview>
        The user wants shoppers to save cart items for later (user story 5101), on the saved-items branch of \
        Sam's pull request !4120. We read the cart service and the cart page, and agreed on a plan: a \
        saved_items table next to cart_items, an API to save an item and to list saved ones, and a Save for \
        later button on each cart item. Only signed-in shoppers can save items; guests are asked to sign in.
        </overview>

        <history>
        1. **Read the user story and the pull request**
           - User story 5101, and its tasks 5102 to 5105
           - Pull request !4120 has Sam's design notes, and no code yet
        2. **Explored the cart service**
           - `CartService` keeps items in `cart_items`, by shopper
           - Migrations are numbered, in `db/migrations`
        3. **Agreed on the plan with the user**
           - Signed-in shoppers only, as the story's comments say
        </history>

        <work_done>
        - Nothing changed yet: this is the plan
        </work_done>

        <technical_details>
        - The cart service queries and migrates with Knex
        - A cart item keeps the price it was added at; a saved item should too
        - The cart's API is under `/api/cart`
        </technical_details>

        <important_files>
        - `src/server/cart/CartService.ts`: the cart's queries
        - `src/server/cart/routes.ts`: the cart's API
        - `src/web/cart/CartItemRow.tsx`: a cart item's row
        </important_files>

        <next_steps>
        1. Add a `saved_items` table, with a migration
        2. Add `POST /api/cart/items/:id/save` and `GET /api/cart/saved`
           - For signed-in shoppers only
        3. Add a **Save for later** button to each cart item
        </next_steps>
        """),
    ("Saved items table and API added", ago(3 * hour + 50 * minute), """
        <overview>
        Saved items now have a home in the cart service: a saved_items table, and an API to save a cart item and \
        to list what's saved. Saving takes the item out of the cart and keeps the price it had. Only signed-in \
        shoppers can save: a guest gets a 401, and the page asks them to sign in. The cart service tests pass.
        </overview>

        <history>
        1. **Planned saved items for the cart** (the previous checkpoint)
        2. **Added the saved_items table**
           - Migration `0042_saved_items.ts`, with an index on the shopper
        3. **Added the API**
           - `POST /api/cart/items/:id/save` moves an item from the cart to saved items
           - `GET /api/cart/saved` lists them, newest first
        4. **Ran the cart service tests**
           - All 48 pass, 6 of them new
        </history>

        <work_done>
        **Cart service**
        - Added the `saved_items` table and its migration
        - Added `SavedItemsRepository`, with `save`, `list` and `remove`
        - Added `POST /api/cart/items/:id/save` and `GET /api/cart/saved`
          - A guest gets a 401

        **Tests**
        - Added 6 tests for saving and listing
        </work_done>

        <technical_details>
        - Saving is one transaction: a delete from `cart_items` and an insert into `saved_items`
        - `saved_items` keeps the cart item's `price_cents` and `currency`
        - The list stops at 50 items
        </technical_details>

        <important_files>
        - `db/migrations/0042_saved_items.ts`
        - `src/server/cart/SavedItemsRepository.ts`
        - `src/server/cart/routes.ts`
        - `src/server/cart/__tests__/savedItems.test.ts`
        </important_files>

        <next_steps>
        1. Add a **Save for later** button to each cart item
           - Hide it from guests
        2. Show saved items under the cart (work item 5103)
        3. Move a saved item back to the cart (work item 5104)
        </next_steps>
        """),
    ("Save for later added to cart items", ago(3 * hour + 5 * minute), """
        <overview>
        Each item in the cart now has a Save for later button, which saves it through the new API and takes it \
        out of the cart; guests don't see it. The cart and cart service tests pass. Showing saved items under \
        the cart, and moving one back, are work items of their own, so they're left for later.
        </overview>

        <history>
        1. **Added the saved items table and API** (the previous checkpoints)
        2. **Added the Save for later button**
           - In `CartItemRow`, next to Remove
           - It calls `POST /api/cart/items/:id/save`, then refreshes the cart
        3. **Ran the cart tests**
           - The row's snapshot test failed, as expected with a new button
           - Updated the snapshot: all 112 tests pass
        </history>

        <work_done>
        **Cart page**
        - Added a **Save for later** button to `CartItemRow`, hidden from guests
        - Refreshed the cart's total after an item is saved
        - Updated the `CartItemRow` snapshot

        **Cart service**
        - Added the `saved_items` table and its migration
        - Added `POST /api/cart/items/:id/save` and `GET /api/cart/saved`
        </work_done>

        <technical_details>
        - The button uses the cart's `useCartMutation`, so the total refreshes with the cart
        - A save that fails shows the cart's usual error banner
        </technical_details>

        <important_files>
        - `src/web/cart/CartItemRow.tsx`
        - `src/web/cart/useCartMutation.ts`
        - `src/server/cart/routes.ts`
        </important_files>

        <next_steps>
        1. Push the saved-items branch to Sam's pull request !4120
        2. Show saved items under the cart (work item 5103)
           - Reuse `CartItemRow`, without the quantity stepper
        3. Move a saved item back to the cart (work item 5104)
        4. Test saving with an empty cart (work item 5105)
        </next_steps>
        """),
]

// Sent to Copilot from the Azure DevOps demo's sprint: one that opened the coupon pull request, and one still working.
let couponTask = "1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01"
sentTask(couponTask, taskPrompt(5112, "Task", "Round half up in the coupon service"),
         started: ago(41 * minute)) { log in
    log.tool("wit_get_work_item", ["id": 5112, "project": "Storefront", "expand": "relations"],
             title: "Read work item 5112", at: ago(40 * minute))
    log.tool("view", ["path": "src/Coupons/CouponService.cs"], at: ago(38 * minute))
    log.tool("bash", ["command": "git switch -c coupon-rounding", "description": "Create a branch"],
             at: ago(36 * minute))
    log.tool("edit", ["path": "src/Coupons/CouponService.cs"], at: ago(28 * minute))
    log.tool("bash", ["command": "dotnet test tests/Coupons.Tests", "description": "Run the coupon tests"],
             at: ago(22 * minute))
    log.tool("bash", ["command": "git push -u origin coupon-rounding", "description": "Push the branch"],
             at: ago(16 * minute))
    log.tool("bash", ["command": "az repos pr create --source-branch coupon-rounding --work-items 5112",
                      "description": "Open the pull request"], at: ago(14 * minute))
    log.finish("Coupon totals now round half up, with tests for every currency. Opened pull request 4091.",
               at: ago(12 * minute))
}
checkpoints[couponTask] = [
    ("Coupon rounding traced to truncation", ago(31 * minute), """
        <overview>
        The task is work item 5112: round discounted totals half up to the cent in the coupon service, instead \
        of truncating them, as finance asked in bug 5110. CouponService.Apply truncates the discounted total to \
        cents, so a $19.99 item with the coupon SAVE15 comes to $16.98 instead of $16.99. The fix is to round \
        half up, to each currency's minor units, with tests for every currency.
        </overview>

        <history>
        1. **Read work item 5112 and bug 5110**
           - Expected $16.99 for a $19.99 item with `SAVE15`, got $16.98
        2. **Created the branch** `coupon-rounding` from origin/main
        3. **Found the cause**
           - `CouponService.Apply` truncates: `decimal.Truncate(total * 100) / 100`
        </history>

        <work_done>
        - Found why coupon totals are a cent short
        </work_done>

        <technical_details>
        - `CurrencyInfo` has each currency's minor units: JPY has none, so it rounds to the yen
        - `MidpointRounding.AwayFromZero` rounds half up for the positive totals coupons make
        </technical_details>

        <important_files>
        - `src/Coupons/CouponService.cs`
        - `src/Coupons/CurrencyInfo.cs`
        - `tests/Coupons.Tests/CouponServiceTests.cs`
        </important_files>

        <next_steps>
        1. Round half up in `CouponService.Apply`, to each currency's minor units
        2. Add tests for every currency, with one for a currency without minor units
        3. Run the coupon tests, then push and open a pull request linked to work item 5112
        </next_steps>
        """),
    ("Coupon totals round half up", ago(18 * minute), """
        <overview>
        CouponService.Apply now rounds discounted totals half up to each currency's minor units, instead of \
        truncating them: a $19.99 item with SAVE15 comes to $16.99, as bug 5110 expects. New tests cover every \
        currency the service supports, JPY included, and all 86 coupon tests pass. What's left is to push the \
        coupon-rounding branch and open the pull request.
        </overview>

        <history>
        1. **Traced the rounding error to truncation** (the previous checkpoint)
        2. **Rounded half up in `CouponService.Apply`**
           - `Math.Round(total, currency.MinorUnits, MidpointRounding.AwayFromZero)`
        3. **Added tests for every currency**
           - A case for each currency in `CurrencyInfo.All`
        4. **Ran the coupon tests**
           - All 86 pass, 12 of them new
        </history>

        <work_done>
        **Coupon service**
        - Rounded discounted totals half up in `CouponService.Apply`
        - Rounded to each currency's minor units, so JPY rounds to the yen

        **Tests**
        - Added `RoundsHalfUpForEveryCurrency`, with a case for each currency
        - Added bug 5110's case: a $19.99 item with `SAVE15` comes to $16.99
        </work_done>

        <technical_details>
        - The tests take the currencies from `CurrencyInfo.All`, so a new currency gets a case of its own
        </technical_details>

        <important_files>
        - `src/Coupons/CouponService.cs`
        - `tests/Coupons.Tests/CouponServiceTests.cs`
        </important_files>

        <next_steps>
        1. Commit, and push the `coupon-rounding` branch
        2. Open a pull request into main, linked to work item 5112
           - Mention bug 5110 in its description
        </next_steps>
        """),
]
let savedItemsTask = "1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b02"
sentTask(savedItemsTask, taskPrompt(5103, "Task", "Show saved items under the cart"), started: ago(6 * minute)) { log in
    log.tool("wit_get_work_item", ["id": 5103, "project": "Storefront", "expand": "relations"],
             title: "Read work item 5103", at: ago(5 * minute + 40))
    log.tool("view", ["path": "src/web/cart/CartPage.tsx"], at: ago(5 * minute))
    log.tool("bash", ["command": "git switch -c show-saved-items", "description": "Create a branch"],
             at: ago(4 * minute + 30))
    log.tool("create", ["path": "src/web/cart/SavedItemsList.tsx"], at: ago(4 * minute))
    log.tool("edit", ["path": "src/web/cart/CartPage.tsx"], at: ago(2 * minute))
    log.tool("bash", ["command": "npm test -- cart", "description": "Run the cart tests"],
             saying: "Saved items now show under the cart. Running the cart tests.", at: ago(1 * minute),
             finished: false)
}
checkpoints[savedItemsTask] = [
    ("Saved items listed for the cart", ago(3 * minute), """
        <overview>
        The task is work item 5103: show the Saved for later list under the cart's items. The cart service \
        already lists saved items, at GET /api/cart/saved. A new SavedItemsList reads them and shows each with \
        CartItemRow, without the quantity stepper, and says Nothing saved yet when there are none. It isn't on \
        the cart page yet.
        </overview>

        <history>
        1. **Read work item 5103 and its user story, 5101**
           - Reuse `CartItemRow`, without the quantity stepper
           - Use the cart's 48 pt thumbnails, as Alex asked
        2. **Created the branch** `show-saved-items` from origin/main
        3. **Added `SavedItemsList`**
           - It reads `GET /api/cart/saved` with `useSavedItems`
        </history>

        <work_done>
        - Added `useSavedItems`, which reads saved items from the cart service
        - Added `SavedItemsList`, which says **Nothing saved yet** when there are none
        - Added a `showsQuantity` option to `CartItemRow`, on by default
        </work_done>

        <technical_details>
        - Thumbnails are 48 pt, as in the cart
        - Saved items show newest first, as the API lists them
        </technical_details>

        <important_files>
        - `src/web/cart/SavedItemsList.tsx`
        - `src/web/cart/useSavedItems.ts`
        - `src/web/cart/CartItemRow.tsx`
        - `src/web/cart/CartPage.tsx`
        </important_files>

        <next_steps>
        1. Show `SavedItemsList` under the cart's items, on `CartPage`
        2. Run the cart tests
        3. Commit, push, and open a pull request linked to work item 5103
        </next_steps>
        """),
]

// MARK: - Files

for (id, log) in sessions.map({ (id: $0.id, log: $0.log) }) + sentTasks {
    let directory = root.appending(path: "session-state/\(id)")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(log.lines.map { $0 + "\n" }.joined().utf8).write(to: directory.appending(path: "events.jsonl"))
}

// Each one's checkpoints, named as Copilot names them, from their number and title, and changed last when they were
// written; and their index.
for (id, list) in checkpoints {
    let directory = root.appending(path: "session-state/\(id)/checkpoints")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    var index = """
        # Checkpoint History

        Checkpoints are listed in chronological order. Checkpoint 1 is the oldest, higher numbers are more recent.

        | # | Title | File |
        |---|-------|------|

        """
    for (offset, checkpoint) in list.enumerated() {
        let words = checkpoint.title.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        let name = String(format: "%03d", offset + 1) + "-\(words.prefix(30)).md"
        let file = directory.appending(path: name)
        try Data((checkpoint.text + "\n").utf8).write(to: file)
        try fileManager.setAttributes([.modificationDate: checkpoint.at], ofItemAtPath: file.path)
        index += "| \(offset + 1) | \(checkpoint.title) | \(name) |\n"
    }
    let file = directory.appending(path: "index.md")
    try Data(index.utf8).write(to: file)
    if let last = list.last {
        try fileManager.setAttributes([.modificationDate: last.at], ofItemAtPath: file.path)
    }
}

/// SQL string literal, or NULL.
func sql(_ value: String?) -> String {
    guard let value else { return "NULL" }
    return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
}

// Only the tables and columns BriefBar reads from the app's database.
var statements = """
    CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
    CREATE TABLE sessions (
        id TEXT PRIMARY KEY NOT NULL, title TEXT, session_type TEXT NOT NULL DEFAULT 'workspace', mode TEXT,
        is_running INTEGER NOT NULL DEFAULT 0, was_interrupted INTEGER NOT NULL DEFAULT 0,
        interruption_reason TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT);
    CREATE TABLE workspaces (
        id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL, session_id TEXT, branch TEXT NOT NULL,
        name TEXT NOT NULL, creator_session_id TEXT, archived_at TEXT, updated_at TEXT NOT NULL);
    CREATE TABLE activity_items (
        id TEXT PRIMARY KEY NOT NULL, session_id TEXT, activity_type TEXT NOT NULL,
        preview TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL);
    CREATE TABLE app_state (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE session_context_usage (
        id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, ts_ms INTEGER NOT NULL,
        current_tokens INTEGER NOT NULL, token_limit INTEGER NOT NULL);

    """
for project in Set(sessions.compactMap(\.project)).sorted() {
    statements += "INSERT INTO projects (id, name) VALUES (\(sql("project-\(project)")), \(sql(project)));\n"
}
for (index, session) in sessions.enumerated() {
    statements += """
        INSERT INTO sessions (id, title, session_type, mode, is_running, created_at, updated_at)
        VALUES (\(sql(session.id)), \(sql(session.name)), \(sql(session.project == nil ? "general_chat" : "project")),
                \(sql(session.mode)), \(session.running ? 1 : 0), \(sql(iso(session.createdAt))), \(sql(iso(session.updatedAt))));
        INSERT INTO session_context_usage (session_id, ts_ms, current_tokens, token_limit)
        VALUES (\(sql(session.id)), \(Int(session.updatedAt.timeIntervalSince1970 * 1_000)), \(session.context.tokens),
                \(session.context.limit));

        """
    if let project = session.project {
        statements += """
            INSERT INTO workspaces (id, project_id, session_id, branch, name, updated_at)
            VALUES (\(sql("workspace-\(index + 1)")), \(sql("project-\(project)")), \(sql(session.id)),
                    \(sql(session.branch)), \(sql(session.name)), \(sql(iso(session.updatedAt))));

            """
    }
}

var database: OpaquePointer?
guard sqlite3_open(root.appending(path: "data.db").path, &database) == SQLITE_OK else {
    fail("couldn't create data.db")
}
var message: UnsafeMutablePointer<CChar>?
guard sqlite3_exec(database, "BEGIN;\n" + statements + "COMMIT;", nil, nil, &message) == SQLITE_OK else {
    fail(message.map { String(cString: $0) } ?? "SQLite error")
}
sqlite3_close(database)

print("Created \(sessions.count) demo sessions, and the logs of \(sentTasks.count) tasks sent to Copilot, in",
      root.path)
