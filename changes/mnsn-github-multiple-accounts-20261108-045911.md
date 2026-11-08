- **GitHub reads every account you're signed in to.** When the GitHub CLI is signed in to more than one account on
  github.com, such as your work account and your own, GitHub's list has the pull requests of each, each once, and its
  foot names them all. **Add Account…**, on GitHub's page in Settings, signs the GitHub CLI in to another account in
  Terminal, keeping the account it uses there as it was, and its pull requests show within a minute. When an account
  can't be read, the list says why, and the others' pull requests stay. It takes GitHub CLI 2.81 or later; with an
  older one, BriefBar reads the account it uses, as before. Still no personal access token: the GitHub CLI keeps every
  sign-in.

## Descriptions

GitHub: the pull requests of every account the GitHub CLI is signed in to on github.com, with one query for each
account each refresh, and which accounts those are, every half hour, which the GitHub CLI checks with GitHub as it lists
them.

After this update: GitHub reads the pull requests of every account the GitHub CLI is signed in to, not only of the one
it uses.
