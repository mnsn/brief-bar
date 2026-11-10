- **A fix sent to push and reply says whether it pushed.** A comment's **Fix** or **Fix All** with **Push and reply
  once it's fixed** checked says **Fixed, pushed and replied in ‘Retry backoff’** only when git, in the checkout its
  session works in, shows the session pushed a commit of its own by the time Copilot was done, and else **Fixed in
  ‘Retry backoff’, but not pushed**, with what Copilot said, as when the tests still failed, its push was rejected or
  someone else pushed first. BriefBar tells once, as Copilot is done, so a push since, from anywhere, doesn't change it,
  and the session's other fixes leave the bar of what's ready only once it pushed. It doesn't push or reply when the
  pull request was completed, abandoned or retargeted meanwhile. Like Push & Reply, it pushes all its session changed,
  so other fixes there that you haven't pushed go too, without a reply, which the composer names as you send it; when
  it changed nothing, it pushes nothing. **Try Again** sends a thread's own Fix again as it went, pushing and replying
  or not as it did, until BriefBar quits; after that, or for a thread Fix All took on, it opens the thread's Fix where
  that went, for you to write and send, with the box as you last left it.

## Descriptions

Azure DevOps: right before a Push & Reply, or a comment's Fix or Fix All with Push and reply once it's fixed checked,
goes, whether its pull request is still active, from the request that reads the branch it merges into; and, for such a
fix, the name of its pull request's branch and the commit git fetched it at, in the clone its session works in, kept
with it, and, once it's done, from git's logs in that clone, whether the commit the clone was at as it ended, which that
branch didn't have as the fix went, had come to it by then by a push from the clone, fetching the branch again first
when the clone's fetch settings don't name it, to tell whether it pushed a commit of its own, kept with it too.

After this update: Azure DevOps reads whether a pull request is still active right before a Push & Reply, or a comment's
Fix or Fix All with Push and reply once it's fixed checked, goes; BriefBar keeps the name of such a fix's branch and the
commit git fetched it at as it went, and, once it's done, asks git in its session's clone whether it pushed a commit of
its own, fetching the branch again only when the clone's fetch settings don't name it, and keeps the answer.
