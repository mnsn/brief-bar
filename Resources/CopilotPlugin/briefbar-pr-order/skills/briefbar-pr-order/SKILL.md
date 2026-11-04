---
name: briefbar-pr-order
description: Tell BriefBar, the user's macOS menu-bar app, the order the pull requests you open must merge in, so that it shows them which can merge next and which wait, and for what. Use it once you've opened two or more pull requests that go together, such as a stack or the pull requests of the sessions you coordinate, and again whenever their order changes.
---

# Pull request order, for BriefBar

With Pull Request Order on in BriefBar's Settings, BriefBar's MCP server, `briefbar`, keeps the order that pull
requests going together must merge in, and its Pull Requests pages show the user which can merge next and which wait.
Some clients show its tools with its name first, as briefbar-order_pull_requests.

- If `order_pull_requests` isn't there, do nothing more here, and don't mention it. Only the user turns Pull Request
  Order on, in BriefBar's Settings: never ask them to, and never change BriefBar's settings or files.
- If it answers that Pull Request Order is off in BriefBar, or that agents are, stop there: don't try again in this
  session.
- Telling BriefBar is best effort: never hold up your work for it. Say BriefBar has the order only once
  `order_pull_requests` answered that it keeps it.

## When to tell it

- Once the pull requests exist, from the session that coordinates them: after you opened them, or after the sessions
  you coordinate did. Send them all in one call. A session working on one of them tells no order of its own.
- Again whenever the order changes: a pull request added, closed or retargeted, or an order you got wrong.
- Not for a pull request on its own, or for ones that don't go together.

## What to send

- `pull_requests`: each pull request that goes together, by its `link`, as Azure DevOps or GitHub gives it, in the
  order they should merge.
- `after`: for each one, the pull requests in the list that must merge before it, by their links or their numbers.
  Name only what must merge first, such as the pull request whose branch a stacked one targets, or one whose change it
  needs in the target branch; leave it out for one that can merge any time. Never invent an order for pull requests
  that don't depend on each other.
- If you track the work as todos with dependencies, each pull request's `after` is the pull requests of the todos its
  own todo depends on: in `todo_deps`, its `todo_id` depends on each `depends_on`.
- `review`, only to advise when to review it, which never holds up merging: `when` is `now`, or `after`, with the pull
  requests to review first and a `reason`: `builds_on_changes`, `same_code`, `stacked_diff` or `needs_decision`.

## Keeping it

- BriefBar answers with the order's ID and its revision: keep both, such as in your todos.
- To change it, send the whole order again, with `order` set to its ID and `revision` to the revision you last read.
  If BriefBar answers that it changed since, read it with `pull_request_order`, then send it again.
- If you lost its ID, `pull_request_order` lists the orders BriefBar keeps, each with the session that told it, and
  says which are your session's. Telling the very same order again also answers with the one BriefBar keeps.
- Once its pull requests no longer go together, call `forget_pull_request_order` with its ID. BriefBar forgets an order
  on its own two weeks after it saw the last of its pull requests merge or close.
