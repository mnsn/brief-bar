- **Copilot sessions keep your pull requests' stages current.** With Pull Request Order and agents on, the Copilot
  sessions that work on your Azure DevOps pull requests tell BriefBar their stages as they go, without you asking:
  In progress as they start fixing one, Your review once they've pushed their work, Teammate's review once you tell
  them you've reviewed it. The latest stage set wins, yours or a session's, and its label says who set it, such as
  **‘Cart’ says it's ready**; where a session's replaced yours, **Put Yours Back** is in its menu. Can merge, Waits
  and Merged still come only from what BriefBar sees. What a session set counts only while the Copilot app lists the
  session, and **Forget Stages…** forgets it too.
- **BriefBar's prompts ask for the stage.** While Pull Request Order is on, Send Work to Copilot's prompt, and a pull
  request's Fix Comments, Fix the Build, Resolve Conflicts and Push & Reply, end asking the session to tell BriefBar
  the pull request is ready for your review once it pushed, if it has the tool to. A review's doesn't.
- **Agents know what you set.** With Pull Request Order on, agents get each Azure DevOps pull request's stage, why,
  and who set it: `needs_me` lists them as the Board does, and `pull_request` says its stage. When a session tells or
  reads an order, BriefBar tells it what you changed in that order, to keep: a later change of its that goes against
  yours shows instead, and you can put yours back.

## Descriptions

Azure DevOps: with Pull Request Order and agents on, the stages Copilot sessions set on your pull requests, kept in
BriefBar's preferences for each session, by reference, with only what would end each, for 30 days at most, which count
only while the Copilot app lists the session.

Agents: with Pull Request Order on, a tool for sessions to set the stages of the Azure DevOps pull requests they work
on, `pull_request_stage`; each Azure DevOps pull request's stage, why, and who set it, in `needs_me` and
`pull_request`; and, in the order tools' answers, what you changed in the orders sessions told, which still holds.

After this update: with Pull Request Order and agents on, Copilot sessions tell Azure DevOps' pull requests' stages,
which BriefBar keeps for each session, never in Azure DevOps; and agents get each pull request's stage, and what you
changed in the orders sessions told.
