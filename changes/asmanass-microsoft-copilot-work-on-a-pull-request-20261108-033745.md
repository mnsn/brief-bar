- **Stop, try again or clear what Copilot does, from its line.** With Send Work to Copilot on, the line that says what
  Copilot does about a comment, a build or a pull request's merge conflicts has **⋯**, as its right-click menu does, and
  VoiceOver's actions: **Stop** while Copilot is at it, which stops one of BriefBar's tasks, or the turn of a prompt you
  sent to a Copilot app session, through BriefBar's extension there, as the app's own Stop does; **Try Again** for a fix
  that failed or stopped, with the same words, to where it went; and **Clear**, to let the line go. **Fix** waits while
  Copilot fixes it.
- **Push & Reply ships one session's fixes, wherever you start it.** **Push & Reply with Copilot…**, in a pull request's
  ⋯ and right-click menus, offers each session's fixes, as the bar at the foot of its details does, rather than replying
  on every comment from its last task's session; and it always starts in the session the fixes are in, even before the
  details have found its sessions. Fixes of no comment, such as a build's alone, say **Push…**. A comment fixed in a
  session whose Push & Reply didn't list it, which pushes all the session changed, says **Pushed from ‘Retry backoff’,
  without a reply**, rather than staying ready to push, and stays so after a later push fails.
- **A resolution of conflicts that are gone goes too.** Copilot's resolution of a pull request's merge conflicts ends
  once the pull request merges cleanly, or targets another branch, rather than coming back, ready to push, as it
  conflicts again.
- **Push & Reply won't push another branch's work.** Right before a Push & Reply goes, BriefBar asks Azure DevOps which
  branch the pull request merges into, fetches it and the pull request's branch into the folder its session works in,
  checks each merge it would push, and asks Azure DevOps again: when a merge brought in what that branch doesn't have,
  as when Copilot resolved the conflicts against main and the pull request was then retargeted to release/x, nothing
  goes, and BriefBar says why, so you can fix it in a new session. Nothing goes either when Azure DevOps, or the list by
  then, says the pull request merges into another branch than its prompt names: the list reads it again at once, so the
  window, opened again, writes a prompt that names that branch. Nor when BriefBar can't read which it is; nor to a
  Copilot app session while a turn runs in it, or in its checkout, or while BriefBar can't tell whether one does. After
  that, the prompt has Copilot check the same right before it pushes, and again after a rebase, stop if it finds a merge
  of any other branch or, with tools that read the pull request, that it merges into another now, and push the commit it
  checked. BriefBar's own pull_request tool reads the branch it merges into each time it's asked, for that check.
- **Comments you'll paste to Copilot stay on Needs You until you do.** When BriefBar copies a prompt for you to paste in
  a Copilot app session, the comments it quotes leave Needs You once BriefBar sees you pasted it there, not as it's
  copied, nor when you send the session something else. A prompt whose session waits overnight for your answer says to
  see the session, rather than going.
- **A fix in a fork stays on the side.** Fixing something in a fork of the pull request's session no longer makes the
  fork its session: it keeps the one it had, or the one you chose, unless you choose the fork.
- **What's Left says what Copilot is on.** While Copilot pushes comments' fixes, What's Left no longer says it's on the
  builds and conflicts that push doesn't ship.

## Descriptions

Azure DevOps: stopping the turn of a prompt sent to one of the Copilot app's sessions, through BriefBar's extension
there; the messages sent a session since BriefBar copied a prompt for you to paste there, to tell the one you pasted
it in; for a pull request's conflicts that a task or prompt takes on, the name of the branch it targets then; when
each Push & Reply in a task's session ran, and how it ended; and, right before a Push & Reply goes, the pull request,
with one request before git checks and one after, for the branch it merges into, and, when Azure DevOps names another
than the list has read, your lists again then, with that pull request's details, rather than at their next refresh;
that branch and the pull request's, fetched with git into the clone its session works in, to check that it pushes no
merge of what that branch doesn't have; and, for one of the Copilot app's sessions, which of them run a turn now, from
its database, until the prompt goes.

After this update: Azure DevOps stops a prompt's turn through BriefBar's extension in the session; to tell that you
pasted a prompt BriefBar copied, it reads the messages sent the session since; BriefBar keeps the branch a pull
request's conflicts were with, for those Copilot took on, and when each Push & Reply in a task's session ran, and how
it ended; and right before a Push & Reply goes, Azure DevOps reads which branch the pull request merges into, twice,
and your lists again when that's another than they have, git fetches that branch and the pull request's into the clone
its session works in, and, for a Copilot app session, BriefBar reads which of the app's sessions run a turn.
