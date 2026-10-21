# Changelog

## 0.1.0 - Unreleased

The first version: Teams Pulse, ADO Pulse and Copilot Pulse in one menu-bar app.

- **Three sources, each off until you turn it on.** Microsoft Teams (unread chats), Azure DevOps (pull
  requests) and GitHub Copilot (app sessions) work as their Pulse apps did. Each first says what it
  reads, where it connects and what it needs. Turning one off deletes what it saved.
- **Permissions once.** Full Disk Access and notifications are BriefBar's, granted once, and used only
  by the sources you turn on. An update never turns a source on, and one that starts reading more
  pauses until you've looked.
- **Several sources in one menu-bar item.** Settings › Menu Bar puts sections together, or all of
  them in one item, with their counts side by side and a tab for each, and hides the ones you don't
  need.
- **Settings in a window of their own**, and in each list's gear menu.
- **Programs it starts can't use its permissions:** the Azure CLI and the login shell that finds it
  run responsible for themselves.
- **Builds are always signed with a certificate**, whose key no app may use without asking, so Full
  Disk Access survives rebuilds. The app has no entitlements, so library validation stays on.
- **No in-app updates yet**, and no releases: while the repository is private, BriefBar is built from
  source.
