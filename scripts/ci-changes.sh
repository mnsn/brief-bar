#!/bin/bash
# Says which of BriefBar's apps a CI run builds, as GitHub Actions step outputs: `windows=true` when BriefBar for
# Windows changed (windows/ or its workflow), `mac=true` when anything else did, and both for the repository's
# .editorconfig and .gitattributes. A pull request is compared with the branch it goes into: GitHub checks out the
# commit that would merge it, whose first parent is that branch. A push is compared with the commit the branch was at
# before it. Anything else, or a push whose earlier commit isn't here, as when it started the branch, builds both.
# `package=true` when the run packages the Mac app and checks the package: always, but for a pull request that changes
# nothing that packaging uses beyond what the tests build and check (see packaging_uses).
#   PUSHED_FROM=<the push's earlier commit> scripts/ci-changes.sh   (writes to $GITHUB_OUTPUT, or prints them)
set -euo pipefail
cd "$(dirname "$0")/.."

from=''
case "${GITHUB_EVENT_NAME:-}" in
  pull_request)
    from='HEAD^1'
    ;;
  push)
    if [[ ! "${PUSHED_FROM:-}" =~ ^0*$ ]] && git cat-file -e "${PUSHED_FROM}^{commit}" 2>/dev/null; then
      from="$PUSHED_FROM"
    fi
    ;;
esac

# CHANGELOG.md from the first version's heading on: the released versions' notes, where scripts/package.sh finds the
# current version's. Only a release changes them: a pull request writes its own notes in changes/ instead.
released_notes() {
  git show "$1:CHANGELOG.md" 2>/dev/null | sed -n '/^## [0-9]/,$p'
}

# Whether packaging the app, or checking the package, uses a path that a pull request changed, beyond what the tests
# build and check. They use the app's Swift code only to build it, optimized, which every push to main still does, but
# for the updater's, which they run. They don't use the tests, the documentation, or a pull request's own notes, in
# changes/ or CHANGELOG.md. Anything else counts, so a new kind of file packages the app until it's listed here.
packaging_uses() {
  case "$1" in
    # The updater, and the code that starts it and talks to it, which the package's checks run: BriefBar's
    # --check-updater (scripts/check-app.sh), in a copy that macOS opens (scripts/test-updater-isolation.sh), and an
    # update through the updater (scripts/update-rehearsal.sh).
    Sources/BriefBarUpdater/* | Sources/BriefBar/Updater.swift | Sources/BriefBar/CLI.swift | Sources/BriefBar/main.swift | \
      Sources/BriefBarCore/UpdaterMessage.swift | Sources/BriefBarCore/RunningProgram.swift | \
      Sources/BriefBarCore/ProcessRunner.swift | Sources/BriefBarCore/Attribution.swift | \
      Sources/BriefBarCore/LaunchEnvironment.swift)
      return 0 ;;
    Sources/*.swift | Tests/* | docs/* | changes/* | .github/ISSUE_TEMPLATE/* | .github/pull_request_template.md | LICENSE)
      return 1 ;;
    CHANGELOG.md)
      [[ "$(released_notes "$from")" != "$(released_notes HEAD)" ]]
      return ;;
  esac
  # Markdown at the top, such as README.md, but not files in other folders, such as the plugins' skills in Resources.
  [[ "$1" == */* || "$1" != *.md ]]
}

mac=false
windows=false
package=true
if [[ -z "$from" ]]; then
  mac=true
  windows=true
else
  [[ "${GITHUB_EVENT_NAME:-}" != pull_request ]] || package=false
  # NUL-separated and without renames, so every path, before and after a move, comes as it is.
  changed="$(mktemp)"
  git diff -z --name-only --no-renames "$from" HEAD > "$changed"
  while IFS= read -r -d '' path; do
    case "$path" in
      # The repository's own settings: windows/.editorconfig adds to the root one, which the Windows format check
      # applies, and both apps are checked out with the same line endings.
      .editorconfig | .gitattributes) mac=true; windows=true ;;
      windows/* | .github/workflows/windows.yml) windows=true; continue ;;
      *) mac=true ;;
    esac
    if [[ "$package" == false ]] && packaging_uses "$path"; then
      package=true
    fi
  done < "$changed"
  rm -f "$changed"
fi
[[ "$mac" == true ]] || package=false

echo "Builds the Mac app: $mac. Packages it: $package. Builds BriefBar for Windows: $windows."
outputs="mac=$mac
package=$package
windows=$windows"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "$outputs" >> "$GITHUB_OUTPUT"
else
  echo "$outputs"
fi
