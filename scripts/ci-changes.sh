#!/bin/bash
# Says which of BriefBar's apps a CI run builds, as GitHub Actions step outputs: `windows=true` when BriefBar for
# Windows changed (windows/ or its workflow), `mac=true` when anything else did, and both for the repository's
# .editorconfig and .gitattributes. A pull request is compared with the branch it goes into: GitHub checks out the
# commit that would merge it, whose first parent is that branch. A push is compared with the commit the branch was at
# before it. Anything else, or a push whose earlier commit isn't here, as when it started the branch, builds both.
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

mac=false
windows=false
if [[ -z "$from" ]]; then
  mac=true
  windows=true
else
  # NUL-separated and without renames, so every path, before and after a move, comes as it is.
  changed="$(mktemp)"
  git diff -z --name-only --no-renames "$from" HEAD > "$changed"
  while IFS= read -r -d '' path; do
    case "$path" in
      # The repository's own settings: windows/.editorconfig adds to the root one, which the Windows format check
      # applies, and both apps are checked out with the same line endings.
      .editorconfig | .gitattributes) mac=true; windows=true ;;
      windows/* | .github/workflows/windows.yml) windows=true ;;
      *) mac=true ;;
    esac
  done < "$changed"
  rm -f "$changed"
fi

echo "Builds the Mac app: $mac. Builds BriefBar for Windows: $windows."
outputs="mac=$mac
windows=$windows"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "$outputs" >> "$GITHUB_OUTPUT"
else
  echo "$outputs"
fi
