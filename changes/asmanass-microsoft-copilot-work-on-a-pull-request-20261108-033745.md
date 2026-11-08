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
- **Push & Reply won't push another branch's work.** Right before a Push & Reply goes, BriefBar fetches the pull
  request's branch and the one it merges into, in the folder its session works in, and checks each merge it would push:
  when one merged in what that branch doesn't have, as when Copilot resolved the conflicts against main and the pull
  request was then retargeted to release/x, nothing goes, and BriefBar says why, so you can fix it in a new session.
  Push & Reply's prompt names the branch it merges into too, and has Copilot stop if it finds a merge of any other; once
  the pull request merges into another branch than its prompt names, nothing goes either, until you open the window
  again for a prompt that names it.
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
there; the messages sent a session since BriefBar copied a prompt for you to paste there, to tell the one you pasted it
in; for a pull request's conflicts that a task or prompt takes on, the name of the branch it targets then; when each
Push & Reply in a task's session ran, and how it ended; and, right before a Push & Reply goes, the pull request's
branch and the one it merges into, fetched with git into the clone its session works in, to check that it pushes no
merge of what that branch doesn't have.

After this update: Azure DevOps stops a prompt's turn through BriefBar's extension in the session; to tell that you
pasted a prompt BriefBar copied, it reads the messages sent the session since; BriefBar keeps the branch a pull
request's conflicts were with, for those Copilot took on, and when each Push & Reply in a task's session ran, and how it
ended; and right before a Push & Reply goes, git fetches the pull request's branch and the one it merges into, into the
clone its session works in.
