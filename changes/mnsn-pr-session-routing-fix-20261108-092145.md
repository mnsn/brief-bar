- **A session that starts working on a pull request takes its work over.** With Updates from Copilot Sessions and Show
  Links on, once another Copilot session starts telling BriefBar it's working on a pull request, after you chose a
  session for its work, its work goes to that session from then on, as it does once a task starts on it in another
  session. What you chose is forgotten, so it doesn't come back when that session stops saying so. A session that only
  tells BriefBar again what it began before you chose leaves your choice be.
- **Agents' `pull_request` names the session the pull request's details do.** It now counts what sessions told BriefBar
  they're working on and opened, as the details do with Show Links on, so a session that said it opened a pull request,
  or works on it, is its session for agents too, rather than none, or a guess at another that only mentions it.
