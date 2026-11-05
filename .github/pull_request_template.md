## What and why

<!-- What does this change, and what problem does it solve? Link related issues, for example "Fixes #12". -->

## Testing

<!-- How did you check it? For UI changes, add before and after screenshots made with `make screenshots`, which shows made-up data. Never include screenshots, names, messages, titles or IDs from your own chats, pull requests or sessions; for Teams, share `--diagnose` output instead. -->

## Checklist

- [ ] `make test`, `make check-boundaries` and `make demo-check` pass
- [ ] What users will notice is in `changes/<branch>.md`, not `CHANGELOG.md` (see "Release notes" in CONTRIBUTING.md)
- [ ] Every source is still off until it's turned on, and reads nothing while it's off
- [ ] A source that reads something new says so in its description, and in its release notes under Descriptions, without raising its version
- [ ] Only Azure DevOps uses the network, with GET requests, and the changes `ADOWrite` lists only behind Make Changes in Azure DevOps, when you click them
- [ ] Nothing about chats, pull requests or sessions goes to the log, or is saved apart from what each source documents
- [ ] No real names, messages, titles, IDs or screenshots of real data in code, tests, comments or this pull request
- [ ] The README or `docs/how-it-works.md` is updated if behavior or settings changed
