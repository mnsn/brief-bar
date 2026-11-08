- **Fix with Copilot… on notifications.** With **Send Work to Copilot** on, a notification that your pull request's
  build failed, that it has merge conflicts, or that someone commented, replied, mentioned you or wants changes has
  **Fix with Copilot…**, which opens the Send to Copilot window with the fix's prompt, going where that pull request's
  work goes, as its menu would. It's there while the menu would offer that fix, so not while Copilot's last task on the
  pull request is still under way. On the Notifications page, it's in the entry's right-click menu.
- **Sessions can wait on your pull request's build, for up to two hours.** For one of your open pull requests, an
  agent's `pull_request` now gives a command, `BriefBar --wait <link> --timeout <minutes>`, which a session starts in
  the background. It reads that pull request every minute, and ends on its next build's result, comments that wait on
  you, merge conflicts or its closing, printing what happened with the prompt to fix it; or at its timeout, 90 minutes
  unless it says otherwise. BriefBar's skill for Copilot has a session end its turn once it pushes, rather than wait on
  a pipeline, since BriefBar's notifications follow that for you, and wait only on a short build that its next step
  needs.

## Descriptions

Agents: BriefBar --wait, for one of your pull requests, read every minute for up to two hours until its next build
passes or fails, comments wait on you, it has merge conflicts or it closes.

After this update: agents can wait on one of your pull requests, for up to two hours, until its next build passes or
fails, comments wait on you, or it has merge conflicts.
