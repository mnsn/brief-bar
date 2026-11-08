---
name: briefbar-pr-order
description: Keep BriefBar, the user's macOS menu-bar app, current on your pull requests without being asked, with the order pull requests that go together merge in and each one's stage. Use it whenever you open, push to or hand off a pull request, split work into several, or the user tells you they reviewed one.
---

# Pull request order and stages, for BriefBar

With Pull Request Order on in BriefBar's Settings, BriefBar's MCP server, `briefbar`, keeps the order that pull
requests going together must merge in, and each Azure DevOps pull request's stage: in progress, waiting for the user's
review or their teammates', ready to merge, or waiting for another. Its Pull Requests pages show the user what's next
for them, so tell BriefBar as you work, without being asked. Some clients show its tools with its name first, as
briefbar-order_pull_requests.

- If `order_pull_requests` isn't there, do nothing more here, and don't mention it. Only the user turns Pull Request
  Order on, in BriefBar's Settings: never ask them to, and never change BriefBar's settings or files.
- If it answers that Pull Request Order is off in BriefBar, or that agents are, stop there: don't try again in this
  session.
- Telling BriefBar is best effort: never hold up your work for it. Say BriefBar has the order only once
  `order_pull_requests` answered that it keeps it, and a stage only once `pull_request_stage` answered that it shows it.

## The order

### When to tell it

- Only the session that owns the plan tells it: the one that coordinates the pull requests, or one splitting its own
  work into several. A session working on part of another's plan never tells an order: each would make a plan of its
  own, and plans don't merge.
- As soon as the second pull request exists, then again, whole, as each later one opens or the order changes: a pull
  request added, closed or retargeted, or an order you got wrong. Send them all in one call.
- Not for a pull request on its own, or for ones that don't go together.

### What to send

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

### Keeping it

- BriefBar answers with the order's ID and its revision: keep both, such as in your todos.
- To change it, send the whole order again, with `order` set to its ID and `revision` to the revision you last read.
  If BriefBar answers that it changed since, read it with `pull_request_order`, then send it again.
- If you lost its ID, `pull_request_order` lists the orders BriefBar keeps, each with the session that told it, and
  says which are your session's. Telling the very same order again also answers with the one BriefBar keeps.
- Once its pull requests no longer go together, call `forget_pull_request_order` with its ID. BriefBar forgets an order
  on its own two weeks after it saw the last of its pull requests merge or close.

## Each one's stage

- Only the session that did the work on a pull request tells its stage, with `pull_request_stage`: Azure DevOps' pull
  requests only, for now. If `pull_request_stage` isn't there, leave stages to BriefBar, which works them out itself.
- `user_review` at the end of a turn that pushed the work: it's the user's turn to review it.
- `in_progress` as you start fixing it again.
- `teammate_review` once the user tells you they've reviewed it, or you reviewed it together. If they name reviewers,
  add them in Azure DevOps with your own tools: BriefBar sees them there.
- `clear` to leave its stage to BriefBar again.
- `pull_requests`: each by its link, or its number with `organization`. Leave `session` out: BriefBar knows which
  session you are.
- Never claim a pull request can merge, waits or merged: BriefBar sees those itself, from Azure DevOps and the order.

## What the user set

- BriefBar's answers say what the user changed: where pull requests go in an order, and the stages they set. Keep it,
  in the order you tell and the stages you set, unless you and the user decided otherwise in this session.
- The latest change shows, the user's or a session's, and BriefBar shows who made it: the user can put theirs back.
