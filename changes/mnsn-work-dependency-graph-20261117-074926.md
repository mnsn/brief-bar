- **My Work's Map.** **Board | Map**, in My Work's header, draws your pull requests, your work items with no pull
  request yet with + Sprint Tasks or + All My Tasks, and steps, work with no pull request yet such as API tests or
  enabling it in production, as a graph of what holds what, in columns from **Done** to **Now**, **Then** and **Later**.
  **By Mission** draws each mission's graph under its header, with what it's joined to in other missions, dimmed; **All**
  draws every graph together, their columns lined up, then a grid of what nothing joins yet. Drag from a card onto what
  waits for it to draw a line, which joins two graphs; click a line to take it away; right-click a card for **Waits
  For**, **Add Step After…** and **Hide on Map**; **+ Step** adds one, and a step's circle marks it done. Each change has
  **Undo**, and only the Map changes: no order, stage or Up Next does. Lines run only from the nearest of what holds each,
  and hovering a card lights up all it waits for and all that waits for it. Search works on the Map too.
- **Ask Copilot what waits for what.** **✨ Ask Copilot**, on a mission's graph, sends one of its sessions, or a fork of
  it, what's there, to read the code and work out what waits for what, and the steps left, such as tests and enabling it
  in each environment; or copies the prompt for a new session. As the session tells BriefBar, the Map draws it, saying
  which session told it, and you can change any of it.

## Descriptions

Azure DevOps: only with My Work Page, the cards and steps you hide on My Work's Map, and the steps and lines you add or
take away there, kept in BriefBar's preferences, by reference and the names you give steps, never a title, until you
change them, choose Forget All Orders… or turn Azure DevOps off; none of it goes to Azure DevOps. As ✨ Ask Copilot asks
one of a mission's sessions what waits for what, with Send Work to Copilot on, what the window that sends work reads of
the Copilot app's sessions, for that one; its prompt, with the titles and links of what's on that part of the Map, goes
only to the session you choose, or to your clipboard.

Agents: with Pull Request Order on, `work_map`, the steps and the lines you and sessions added or took away on My Work's
Map, with who and when, and `tell_dependencies`, for sessions to tell what waits for what there and add, rename, mark
done or delete steps; both change only BriefBar's Map.

After this update: on My Work's Map, BriefBar keeps the cards you hide and the steps and lines you add, in its
preferences, and sends none of it to Azure DevOps; ✨ Ask Copilot sends a prompt only to the session you choose; and
agents can read and tell what waits for what there.
