// BriefBar's extension for the GitHub Copilot app's sessions, from the briefbar-sessions plugin, which BriefBar installs
// only when you turn on Send Prompts to Copilot Sessions in its Settings › Agents. It runs in each session the app
// opens and does nothing until BriefBar asks: then it sends this session a prompt, forks it, stops its turn, or starts a
// new session of the app's with a prompt, and, for a prompt BriefBar asks it to report, tells BriefBar how that prompt's
// turn goes and what Copilot said as it ended (./outbox.mjs, ./turn.mjs). It has no tools, hooks or commands.
import { joinSession } from "@github/copilot-sdk/extension";
import { start } from "./outbox.mjs";

await start(await joinSession());
