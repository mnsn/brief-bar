#!/bin/bash
# Tests scripts/update-homebrew-cask.sh, the release workflow's last step, against a tap of its own in a temporary
# folder, with no network and no key: it sets the cask's version and SHA-256 in one commit and changes nothing
# else, the same release again changes nothing, an older release never replaces a newer one, and it refuses
# another zip for the same version, a cask it can't read, and arguments that aren't a version and a SHA-256.
# CI runs it (make homebrew-cask-check).
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() {
    echo "test-homebrew-cask failed: $*" >&2
    exit 1
}

OLD_SHA="$(printf 'a%.0s' {1..64})"
NEW_SHA="$(printf 'b%.0s' {1..64})"
OTHER_SHA="$(printf 'c%.0s' {1..64})"
TAP="$WORK/tap.git"

# make_tap <cask>: a tap whose main branch has that cask, in one commit.
make_tap() {
    rm -rf "$TAP" "$WORK/seed"
    git init --quiet --bare --initial-branch=main "$TAP"
    git init --quiet --initial-branch=main "$WORK/seed"
    mkdir "$WORK/seed/Casks"
    printf '%s\n' "$1" > "$WORK/seed/Casks/briefbar.rb"
    git -C "$WORK/seed" add --all
    git -C "$WORK/seed" -c user.name=Test -c user.email=test@example.com commit --quiet --message "Add the cask"
    git -C "$WORK/seed" push --quiet "$TAP" main
}
update() { BRIEFBAR_TAP_URL="file://$TAP" ./scripts/update-homebrew-cask.sh "$@" < /dev/null; }
cask() { git --git-dir="$TAP" show main:Casks/briefbar.rb; }
commits() { git --git-dir="$TAP" rev-list --count main; }

CASK_090="cask \"briefbar\" do
  version \"0.9.0\"
  sha256 \"$OLD_SHA\"

  url \"https://github.com/mnsn/brief-bar/releases/download/v#{version}/BriefBar.zip\"
  name \"BriefBar\"
end"
make_tap "$CASK_090"

update 0.9.1 "$NEW_SHA" > /dev/null || fail "it didn't update the cask to 0.9.1."
EXPECTED="${CASK_090/version \"0.9.0\"/version \"0.9.1\"}"
EXPECTED="${EXPECTED/$OLD_SHA/$NEW_SHA}"
[[ "$(cask)" == "$EXPECTED" ]] || fail "the cask isn't what it should be after 0.9.1:
$(cask)"
[[ "$(commits)" == 2 ]] || fail "it made $(( $(commits) - 1 )) commits for 0.9.1, not one."
[[ "$(git --git-dir="$TAP" log -1 --format=%s main)" == "briefbar 0.9.1" ]] ||
    fail "its commit says \"$(git --git-dir="$TAP" log -1 --format=%s main)\"."

update 0.9.1 "$NEW_SHA" > /dev/null || fail "the same release again failed."
[[ "$(commits)" == 2 && "$(cask)" == "$EXPECTED" ]] || fail "the same release again changed the cask."

update 0.9.0 "$OLD_SHA" > /dev/null || fail "an older release failed, rather than leaving the cask."
[[ "$(commits)" == 2 && "$(cask)" == "$EXPECTED" ]] || fail "an older release replaced a newer one."

! update 0.9.1 "$OTHER_SHA" 2> /dev/null || fail "it accepted another zip for 0.9.1."
[[ "$(commits)" == 2 && "$(cask)" == "$EXPECTED" ]] || fail "another zip for 0.9.1 changed the cask."

update 0.10.0 "$OTHER_SHA" > /dev/null || fail "it didn't update the cask to 0.10.0."
[[ "$(cask)" == *'version "0.10.0"'* ]] || fail "0.10.0 didn't count as newer than 0.9.1."

for args in "1.0 $NEW_SHA" "v1.0.0 $NEW_SHA" "1.0.0 ${NEW_SHA:1}" "1.0.0 $(printf 'B%.0s' {1..64})" "1.0.0"; do
    # shellcheck disable=SC2086 # Split on purpose: each case is a list of arguments.
    ! update $args 2> /dev/null || fail "it accepted the arguments $args."
done
[[ "$(cask)" == *'version "0.10.0"'* ]] || fail "arguments it refused changed the cask."

make_tap "${CASK_090/  sha256 \"$OLD_SHA\"/  sha256 arm: \"$OLD_SHA\", intel: \"$OLD_SHA\"}"
! update 0.9.1 "$NEW_SHA" 2> /dev/null || fail "it updated a cask with a SHA-256 for each architecture."
[[ "$(commits)" == 1 ]] || fail "a cask it can't read changed."

echo "test-homebrew-cask passed: the cask follows newer releases only, one commit each, with their SHA-256."
