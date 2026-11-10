- **BriefBar checks each push of its Push & Reply tasks itself.** In a Push & Reply that BriefBar runs, with Copilot
  CLI 1.0.57 or later, the CLI asks BriefBar about each shell command before it runs it. A push goes only as the
  prompt says, in a command of its own: the commit the task's worktree has, to the pull request's branch alone,
  without tags or submodules, once nothing in it merged in what the branch the prompt names doesn't have, and Azure
  DevOps says the pull request is still active and merges into that branch. A push in another form doesn't run, and
  Copilot is told the exact command to run instead. One that would force, delete or push more than the branch, or that
  BriefBar can't check, is stopped, and the task fails, with why, even if Copilot says it pushed. With an older CLI,
  Push & Reply goes as before, with the checks it already had.

## Descriptions

Azure DevOps: in a Push & Reply that BriefBar runs itself, each shell command Copilot is about to run, which the Copilot
CLI gives BriefBar to check, keeping nothing of it; and, for a push in the form its prompt names, that branch and the
pull request's, fetched with git into the task's worktree, with which commits a merge in what it would push brings in,
and whether git's configuration there would push tags or submodules' commits with it; then the pull request, with one
request, for the branch it merges into and whether it's still active.

After this update: in a Push & Reply that BriefBar runs itself, Azure DevOps checks each push as Copilot makes it,
reading the pull request again and fetching its branches with git.
