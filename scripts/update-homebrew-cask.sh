#!/bin/bash
# Points BriefBar's Homebrew cask, Casks/briefbar.rb in mnsn/homebrew-tap, at a published release: its version, and
# its zip's SHA-256, which Homebrew checks the download against. The release workflow runs it once the release is
# published, with the tap's deploy key, which can push to that repository only.
#   scripts/update-homebrew-cask.sh <version> <SHA-256>   with the deploy key's private key on standard input
# The key goes to an ssh-agent of the script's own, never to a file or an argument, and ssh connects only to the
# host with GitHub's key. The cask never goes back to an older version, so releases approved out of order end at
# the newest, and the same release again changes nothing. BRIEFBAR_TAP_URL names another repository to update,
# without a key, as scripts/test-homebrew-cask.sh does.
set -euo pipefail

VERSION="${1:?Usage: $0 <version> <SHA-256>}"
SHA256="${2:?Usage: $0 <version> <SHA-256>}"
TAP_URL="${BRIEFBAR_TAP_URL:-git@github.com:mnsn/homebrew-tap.git}"
CASK="Casks/briefbar.rb"
# From https://api.github.com/meta.
GITHUB_HOST_KEY="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Not a version like 1.2.3: \"$VERSION\"." >&2
    exit 1
fi
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Not a SHA-256 in lowercase hex, as shasum prints it: \"$SHA256\"." >&2
    exit 1
fi

WORK="$(mktemp -d)"
AGENT_PID=""
cleanup() {
    if [[ -n "$AGENT_PID" ]]; then
        kill "$AGENT_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -z "${BRIEFBAR_TAP_URL:-}" ]]; then
    eval "$(ssh-agent -s)" >/dev/null
    AGENT_PID="$SSH_AGENT_PID"
    if ! ssh-add -q - 2>/dev/null; then
        echo "No deploy key for mnsn/homebrew-tap on standard input." >&2
        exit 1
    fi
    printf '%s\n' "$GITHUB_HOST_KEY" > "$WORK/known_hosts"
    export GIT_SSH_COMMAND="ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$WORK/known_hosts"
fi

# value <stanza>: what the cask's one line `  <stanza> "..."` says. Fails if it has none, or more than one, such
# as a SHA-256 for each architecture, which this script doesn't know how to update.
value() {
    local lines
    lines="$(grep -E "^  $1 \"[^\"]*\"\$" "$WORK/tap/$CASK" || true)"
    if [[ -z "$lines" || "$lines" == *$'\n'* ]]; then
        echo "$CASK doesn't have exactly one line like '  $1 \"...\"'." >&2
        return 1
    fi
    printf '%s\n' "$lines" | sed -E "s/^  $1 \"([^\"]*)\"\$/\1/"
}

# Again from a fresh clone if the push loses a race with another release's.
for attempt in 1 2 3; do
    rm -rf "$WORK/tap"
    git clone --quiet --depth 1 "$TAP_URL" "$WORK/tap"
    CURRENT="$(value version)"
    CURRENT_SHA256="$(value sha256)"
    if [[ "$CURRENT" == "$VERSION" ]]; then
        if [[ "$CURRENT_SHA256" != "$SHA256" ]]; then
            echo "The cask is at $VERSION already, for a zip with another SHA-256: $CURRENT_SHA256." >&2
            exit 1
        fi
        echo "The Homebrew cask is at $VERSION already."
        exit 0
    fi
    if [[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -n 1)" != "$VERSION" ]]; then
        echo "The Homebrew cask is at $CURRENT, which is newer than $VERSION, so it stays there."
        exit 0
    fi

    sed -i '' -E -e "s/^  version \"[^\"]*\"\$/  version \"$VERSION\"/" \
        -e "s/^  sha256 \"[^\"]*\"\$/  sha256 \"$SHA256\"/" "$WORK/tap/$CASK"
    if [[ "$(value version)" != "$VERSION" || "$(value sha256)" != "$SHA256" ]]; then
        echo "Couldn't set the version and SHA-256 in $CASK." >&2
        exit 1
    fi
    git -C "$WORK/tap" -c user.name="github-actions[bot]" \
        -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit --quiet --all --message "briefbar $VERSION"
    if git -C "$WORK/tap" push --quiet origin HEAD:main; then
        echo "Updated the Homebrew cask from $CURRENT to $VERSION."
        exit 0
    fi
    echo "Pushing the cask failed (attempt $attempt of 3)." >&2
done
exit 1
