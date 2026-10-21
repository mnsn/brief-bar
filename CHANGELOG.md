# Changelog

## 0.1.0 - Unreleased

The first version: Teams Pulse, ADO Pulse and Copilot Pulse in one menu-bar app.

- **Three sources, each off until you turn it on.** Microsoft Teams (unread chats), Azure DevOps (pull
  requests) and GitHub Copilot (app sessions) work as their Pulse apps did. Each first says what it
  reads, where it connects and what it needs. Turning one off deletes what it saved.
- **Permissions once.** Full Disk Access and notifications are BriefBar's, granted once, and used only
  by the sources you turn on. An update never turns a source on, and one that starts reading more
  pauses until you've looked.
- **Menu bar, widgets and windows, arranged as you like.** Each section (Teams' Chats and Group
  Chats, pull requests, sessions) can share a menu-bar item, a desktop widget or a window with
  others, have one of its own, or be hidden from any of them. Settings › Menu Bar, Widgets and
  Windows also put everything in one, or give each its own.
- **A window** with a page for each section, and a sidebar with their counts. BriefBar shows a Dock
  icon only while it's open.
- **Widgets for every source**, each with its own position and size. Teams' start hidden.
- **Settings in a window of their own**, and in each list's gear menu.
- **Programs it starts can't use its permissions:** the Azure CLI and the login shell that finds it
  run responsible for themselves.
- **Builds are always signed with a certificate**, whose key no app may use without asking, so Full
  Disk Access survives rebuilds. The app has no entitlements, so library validation stays on.
- **No in-app updates yet**, and no releases: while the repository is private, BriefBar is built from
  source.
