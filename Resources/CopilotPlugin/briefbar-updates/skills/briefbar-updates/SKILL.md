---
name: briefbar-updates
description: Tell BriefBar, the user's macOS menu-bar app, which Azure DevOps work items and pull requests you're working on, and what you just changed in Azure DevOps, so that it shows the user at once. Use it as you start or stop working on a work item or pull request, and right after you open a pull request, push to or reply on one, or create or change work items in Azure DevOps.
---

# Updates from Copilot Sessions, for BriefBar

With Updates from Copilot Sessions on in BriefBar's Settings, BriefBar's MCP server, `briefbar`, hears what your session
works on and what you change in Azure DevOps with your own tools. It shows your session on that work, in the sprint and
on the pull requests, and reads what you changed again at once rather than at its next refresh. Some clients show its
tools with its name first, as briefbar-working_on.

- If `working_on` and `changed_in_azure_devops` aren't there, do nothing more here, and don't mention it. Only the user
  turns Updates from Copilot Sessions on, in BriefBar's Settings: never ask them to, and never change BriefBar's
  settings or files.
- If one answers that Updates from Copilot Sessions is off in BriefBar, or that agents are, stop there: don't try again
  in this session.
- Telling BriefBar is best effort: never hold up your work for it, and never call it in place of making the change.
  BriefBar changes nothing in Azure DevOps: you make every change there with your own tools.

## Who tells

- Only the session doing the work tells BriefBar about it. A session that coordinates others doesn't claim their work
  items or pull requests: each of them tells its own.
- Leave `session` out: BriefBar knows which session you are. Send it only when an answer says BriefBar can't tell, and
  then only your own session's ID.

## What you work on: `working_on`

- As you start changing a work item or a pull request: the ones you're working on now, not those you only read or
  review.
- Send the whole list each time it changes, and an empty one, `{}`, once you finish or hand the work off.
- `work_items` and `pull_requests`: each by its link, as Azure DevOps or GitHub gives it, or an Azure DevOps one by its
  number, such as `5124` or `!4102`, with `organization`.

## What you changed: `changed_in_azure_devops`

- Right after you change something in Azure DevOps, once after a batch of changes, never before you make them.
- `opened`: only the pull requests you opened yourself, so that BriefBar shows them as your session's.
- `pull_requests`: others you changed: pushed to, replied on, resolved threads of, or changed the tags, reviewers or
  description of.
- `work_items`: those you created, or changed the state, fields or links of. For many under one, such as a story's new
  tasks, the one they're under is enough.
- Link a pull request to its work items in Azure DevOps, with your own tools, as you open it: BriefBar shows what Azure
  DevOps says, not what you tell it.

## With the order of pull requests

If you also tell BriefBar the order pull requests merge in, with `order_pull_requests`, go on doing that: neither
replaces the other. After you push, also tell BriefBar the pull request's stage with `pull_request_stage`, if it's there.
