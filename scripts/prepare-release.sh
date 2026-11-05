#!/bin/bash
# Prepares a release for its version commit, "Prepare BriefBar X.Y.Z": gathers the notes that pull requests wrote in
# changes/ into a section for the version at the top of CHANGELOG.md, in the order they merged, raises the version of
# each description they changed, with its doc line, ends the section with the "After this update" bullet when one
# changed, sets the version in Resources/Info.plist and deletes the notes. It changes only those files, in the working
# tree, and nothing unless it can do all of it. See "Release notes" and "Releasing" in CONTRIBUTING.md.
#   scripts/prepare-release.sh [--main <ref>] <version> [<date>]
#       such as 0.17.0 2026-11-30; the date defaults to today. It needs the whole history, the last release's tag, and
#       HEAD to have all of <ref>, the branch the pull requests merged into, whose history orders their notes
#       (origin/main by default).
#   scripts/prepare-release.sh --check [--fetch]
#       checks the notes in changes/, and that no pull request changed a description's version, against the last
#       release's tag, which --fetch fetches from origin when it isn't here, as in CI. It changes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
# Bytes, so that sorting and awk work the same everywhere; awk counts a line's characters by their UTF-8 lead bytes.
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

CHANGELOG=CHANGELOG.md
PLIST=Resources/Info.plist
NOTES=changes
WIDTH=120
# What a pull request's notes can say changed, under "## Descriptions", in the order the app lists the sources, and
# agents last: by key, its name there, the file that declares its version, that version's name, and its name in the
# "After this update" bullet.
SOURCES="teams azure-devops copilot github agents"
LABELS="Teams|Azure DevOps|Copilot|GitHub|Agents"
KEYS="teams|azure-devops|copilot|github|agents"
file_of() {
    case "$1" in
        teams) echo Sources/TeamsUI/TeamsSource.swift ;;
        azure-devops) echo Sources/AzureDevOpsUI/AzureDevOpsSource.swift ;;
        copilot) echo Sources/CopilotUI/CopilotSource.swift ;;
        github) echo Sources/GitHubUI/GitHubSource.swift ;;
        agents) echo Sources/BriefBarCore/AgentAccess.swift ;;
    esac
}
variable_of() {
    case "$1" in
        agents) echo version ;;
        *) echo descriptionVersion ;;
    esac
}
name_of() {
    case "$1" in
        teams) echo Teams ;;
        azure-devops) echo "Azure DevOps" ;;
        copilot) echo Copilot ;;
        github) echo GitHub ;;
        agents) echo agents ;;
    esac
}

fail() {
    echo "prepare-release: $*" >&2
    exit 1
}
usage() {
    echo "Usage: scripts/prepare-release.sh [--main <ref>] <version> [<date>], such as 0.17.0 2026-11-30" >&2
    echo "       scripts/prepare-release.sh --check [--fetch]" >&2
    exit 2
}

# Reads notes files, in the order given, into the folder `out`: their bullets' lines into `bullets`, what each
# source's doc line says into `doc-<key>`, and what After this update says into `after`, a pull request a line. Says
# what's wrong with them as file:line: message, and fails then.
IFS= read -r -d '' PARSE <<'AWK' || true
function report(line, message) {
    printf "%s:%d: %s\n", file, line, message > "/dev/stderr"
    failed = 1
}
function trim(text) {
    sub(/^ +/, "", text)
    sub(/ +$/, "", text)
    return text
}
# A sentence's end: a full stop, ! or ?, then perhaps closing brackets, quotes, backticks or bold.
function ends_a_sentence(text) {
    return text ~ /[.!?]([)*"'`]|\342\200\231|\342\200\235)*$/
}
# The paragraph under ## Descriptions that ends here.
function flush(    key) {
    if (label == "") return
    if (paragraph == "") {
        report(paragraph_line, "says nothing after \"" label ":\".")
    } else if (label == "After this update") {
        if (after) {
            report(paragraph_line, "has a second After this update: say it all in one.")
        } else if (paragraph ~ /^(\*\*)?[Aa]fter this update/) {
            report(paragraph_line, "repeats \"After this update\": the release writes that sentence, so say what changed.")
        } else if (!ends_a_sentence(paragraph)) {
            report(paragraph_line, "doesn't end its After this update with a full stop.")
        } else {
            print paragraph >> (out "/after")
        }
        after = paragraph_line
    } else {
        key = key_of[label]
        if (key in named) {
            report(paragraph_line, "names " label " twice: say it all in one.")
        } else if (paragraph ~ /^[0-9]+:/) {
            report(paragraph_line, "numbers " label "'s doc line: leave the number out, since the release gives it.")
        } else if (!ends_a_sentence(paragraph)) {
            report(paragraph_line, "doesn't end " label "'s doc line with a full stop.")
        } else {
            print paragraph >> (out "/doc-" key)
        }
        named[key] = 1
        sources++
    }
    label = ""
    paragraph = ""
}
function end_file() {
    flush()
    if (descriptions && !sources) report(descriptions, "has a ## Descriptions that names no source.")
    if (sources && !after) report(descriptions, "needs an After this update: under ## Descriptions, saying what changed.")
    if (!bullets && !sources) report(last_line, "has no notes.")
}
BEGIN {
    count = split(labels, label_list, "|")
    split(keys, key_list, "|")
    for (i = 1; i <= count; i++) key_of[label_list[i]] = key_list[i]
    named_labels = "\"" label_list[1] ":\""
    for (i = 2; i <= count; i++) named_labels = named_labels ", \"" label_list[i] ":\""
}
FNR == 1 {
    if (file != "") end_file()
    file = FILENAME
    descriptions = 0; bullets = 0; open = 0; sources = 0; after = 0; label = ""; paragraph = ""
    split("", named)
}
{
    last_line = FNR
    sub(/\r$/, "")
    sub(/ +$/, "")
}
/\t/ {
    report(FNR, "has a tab: indent with spaces.")
    next
}
/^#/ {
    if ($0 == "## Descriptions" && !descriptions) { descriptions = FNR; next }
    if ($0 == "## Descriptions") report(FNR, "has a second ## Descriptions.")
    else report(FNR, "has a heading other than ## Descriptions: the release writes the version's.")
    next
}
# The notes: bullets, each with a bold lead, and the lines that continue them, indented by two spaces.
!descriptions {
    if ($0 == "") { open = 0; next }
    if ($0 ~ /^- \*\*/) {
        if ($0 ~ /^- \*\*After this update/) {
            report(FNR, "has an After this update bullet, which the release writes: say what changed under Descriptions.")
            next
        }
        print >> (out "/bullets")
        bullets++
        open = 1
        next
    }
    if ($0 ~ /^  / && open) { print >> (out "/bullets"); next }
    if ($0 ~ /^[-*+] /) report(FNR, "has a bullet without a bold lead, such as \"- **What changed.** And how.\"")
    else if ($0 ~ /^  /) report(FNR, "continues no bullet: a bullet has no blank lines.")
    else report(FNR, "isn't a bullet, or a line that continues one, indented by two spaces.")
    next
}
# ## Descriptions: a paragraph for each source whose description changed, which starts with its name, and one that
# starts with "After this update:". A line that starts with one of them starts a paragraph.
{
    if ($0 == "") { flush(); next }
    if ($0 ~ /^ *[-*+] /) { report(FNR, "has a bullet under ## Descriptions: bullets go above it."); next }
    starts = ""
    for (i = 1; i <= count; i++) if (index($0, label_list[i] ":") == 1) starts = label_list[i]
    if (index($0, "After this update:") == 1) starts = "After this update"
    if (starts == "" && label != "") { paragraph = paragraph " " trim($0); next }
    flush()
    if (starts == "") {
        report(FNR, "doesn't start with " named_labels " or \"After this update:\".")
        next
    }
    label = starts
    paragraph = trim(substr($0, length(label) + 2))
    paragraph_line = FNR
}
END {
    if (file != "") end_file()
    exit failed
}
AWK

# Wraps a line of words at WIDTH characters: the first line after `first`, the others after `rest`. A line never
# starts with a word that Markdown would read as a list's item, a heading or a quote.
IFS= read -r -d '' WRAP <<'AWK' || true
function characters(text) {
    gsub(/[\200-\277]/, "", text)
    return length(text)
}
{
    line = first; size = characters(first); words = 0
    count = split($0, word, / +/)
    for (i = 1; i <= count; i++) {
        if (word[i] == "") continue
        if (words && size + 1 + characters(word[i]) > width && word[i] !~ /^([-+*>#|]+|[0-9]+[.)])$/) {
            print line
            line = rest; size = characters(rest); words = 0
        }
        line = line (words ? " " : "") word[i]
        size += (words ? 1 : 0) + characters(word[i])
        words++
    }
    if (words) print line
}
AWK
wrap() { # <first> <rest> <text>
    printf '%s\n' "$3" | awk -v first="$1" -v rest="$2" -v width="$WIDTH" "$WRAP"
}

# Joins what pull requests said, a line each, into one text, each starting a sentence; the first too, with capitalize.
JOIN='{ first = substr($0, 1, 1); if ((NR > 1 || capitalize) && first ~ /[a-z]/) $0 = toupper(first) substr($0, 2) }
    { text = (NR > 1 ? text " " : "") $0 } END { print text }'

# The line that declares a version, such as "    nonisolated package static let descriptionVersion = 23".
DECLARATION='$0 ~ ("^ +([a-z]+ )*static let " variable " = [0-9]+$")'
declaration() { # <file> <variable>: prints its one declaration, or fails
    local lines
    [[ -f "$1" ]] || fail "$1 is missing."
    lines="$(awk -v variable="$2" "$DECLARATION" "$1")"
    if [[ -z "$lines" || "$lines" == *$'\n'* ]]; then
        fail "$1 needs exactly one line like \"static let $2 = 1\", for a release to raise."
    fi
    printf '%s\n' "$lines"
}

# Fails unless each version is the one in the release that tag names: only a release changes them.
same_versions_as() { # <tag>
    local key file variable line released files=()
    for key in $SOURCES; do files+=("$(file_of "$key")"); done
    git grep -E -e "^ +([a-z]+ )*static let [A-Za-z]+ = [0-9]+\$" "$1" -- "${files[@]}" > "$WORK/released" || true
    for key in $SOURCES; do
        file="$(file_of "$key")"
        variable="$(variable_of "$key")"
        line="$(declaration "$file" "$variable")"
        released="$(awk -v prefix="$1:$file:" -v variable="$variable" \
            "index(\$0, prefix) == 1 { \$0 = substr(\$0, length(prefix) + 1); if ($DECLARATION) print }" "$WORK/released")"
        if [[ -z "$released" || "$released" == *$'\n'* ]]; then
            fail "$1 has no line like \"static let $variable = 1\" in $file to compare with."
        fi
        if [[ "${line##* = }" != "${released##* = }" ]]; then
            fail "$file's $variable is ${line##* = }, but ${released##* = } in $1: only a release changes it." \
                "Put it back, take out the doc line added for it, and say what changed in the pull request's notes," \
                "under ## Descriptions (\"Release notes\" in CONTRIBUTING.md)."
        fi
    done
}

# The last release's version, from CHANGELOG.md's first section, which is dated: pull requests never add a section.
last_release() {
    local heading
    local pattern='^## ([0-9]+\.[0-9]+\.[0-9]+) - [0-9]{4}-[0-9]{2}-[0-9]{2}$'
    [[ -f "$CHANGELOG" ]] || fail "$CHANGELOG is missing."
    [[ "$(head -n 1 "$CHANGELOG")" == "# Changelog" ]] || fail "$CHANGELOG doesn't start with \"# Changelog\"."
    if grep -Eiq '^##+ *unreleased' "$CHANGELOG"; then
        fail "$CHANGELOG has an Unreleased section. A pull request writes its notes in $NOTES/ instead: move them" \
            "there (\"Release notes\" in CONTRIBUTING.md)."
    fi
    awk 'NR > 1 && /^## / { exit } NR > 1 && NF { bad = 1; exit } END { exit bad }' "$CHANGELOG" ||
        fail "$CHANGELOG has something between its title and its first section."
    heading="$(grep -m 1 '^## ' "$CHANGELOG" || true)"
    [[ "$heading" =~ $pattern ]] ||
        fail "$CHANGELOG's first section isn't a release's, like \"## 1.2.3 - 2026-11-30\": it's \"$heading\"."
    echo "${BASH_REMATCH[1]}"
}

# The notes files in changes/, by name, each named after its pull request's branch. changes/README.md isn't one.
notes_files() {
    local path
    local pattern="^$NOTES/[A-Za-z0-9][A-Za-z0-9._-]*\\.md\$"
    [[ -d "$NOTES" ]] || fail "$NOTES/ is missing."
    for path in "$NOTES"/*; do
        [[ -e "$path" && "$path" != "$NOTES/README.md" ]] || continue
        [[ -f "$path" && "$path" =~ $pattern ]] ||
            fail "$path isn't a notes file: $NOTES/ holds files named after branches, such as $NOTES/my-branch.md."
        [[ -s "$path" ]] || fail "$path is empty."
        echo "$path"
    done
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/prepare-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

parse() { # <files...>: into $WORK, or fails
    awk -v out="$WORK" -v labels="$LABELS" -v keys="$KEYS" "$PARSE" "$@" ||
        fail "fix the notes above, as \"Release notes\" in CONTRIBUTING.md says."
}

CHECK=0
FETCH=0
MAIN_REF=origin/main
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK=1 ;;
        --fetch) FETCH=1 ;;
        --main) [[ $# -ge 2 ]] || usage; MAIN_REF="$2"; shift ;;
        --main=*) MAIN_REF="${1#--main=}" ;;
        -*) usage ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done

if [[ "$CHECK" == 1 ]]; then
    [[ ${#ARGS[@]} -eq 0 ]] || usage
    LAST="$(last_release)"
    TAG="v$LAST"
    for key in $SOURCES; do
        declaration "$(file_of "$key")" "$(variable_of "$key")" > /dev/null
    done
    if [[ "$FETCH" == 1 ]] && ! git rev-parse --verify --quiet "refs/tags/$TAG^{commit}" > /dev/null; then
        # 2: origin has no such tag, as while a release's own pull request is checked.
        status=0
        git ls-remote --exit-code --tags origin "refs/tags/$TAG" > /dev/null || status=$?
        if [[ $status -eq 0 ]]; then
            git fetch --quiet --no-tags --depth=1 origin "+refs/tags/$TAG:refs/tags/$TAG" || fail "couldn't fetch $TAG."
        elif [[ $status -ne 2 ]]; then
            fail "couldn't ask origin for $TAG."
        fi
    fi
    if git rev-parse --verify --quiet "refs/tags/$TAG^{commit}" > /dev/null; then
        same_versions_as "$TAG"
        VERSIONS="The descriptions' versions are $TAG's."
    elif [[ "$FETCH" == 1 ]]; then
        VERSIONS="$TAG isn't tagged yet, so the descriptions' versions are its own."
    else
        VERSIONS="The descriptions' versions aren't compared with $TAG's, which isn't here: git fetch --tags."
    fi
    FILES="$(notes_files)"
    if [[ -z "$FILES" ]]; then
        echo "No release notes in $NOTES/. $VERSIONS"
        exit 0
    fi
    LIST=()
    while IFS= read -r path; do LIST+=("$path"); done <<< "$FILES"
    parse "${LIST[@]}"
    echo "The release notes in $NOTES/ are fine: ${#LIST[@]} pull requests'. $VERSIONS"
    exit 0
fi

[[ ${#ARGS[@]} -ge 1 && ${#ARGS[@]} -le 2 && "$FETCH" == 0 ]] || usage
VERSION="${ARGS[0]}"
DATE="${ARGS[1]:-$(date +%Y-%m-%d)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version, $VERSION, isn't like 1.2.3."
DAY="$(date -j -f %Y-%m-%d "$DATE" +%Y-%m-%d 2>/dev/null || date -d "$DATE" +%Y-%m-%d 2>/dev/null || true)"
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$DAY" == "$DATE" ]] || fail "the date, $DATE, isn't a day like 2026-11-30."

LAST="$(last_release)"
[[ "$LAST" != "$VERSION" ]] || fail "$CHANGELOG has a section for $VERSION already: it's prepared."
if [[ "$(printf '%s\n%s\n' "$LAST" "$VERSION" | sort -V | tail -n 1)" != "$VERSION" ]]; then
    fail "$VERSION isn't higher than the last release in $CHANGELOG, $LAST."
fi

# Resources/Info.plist's version: the last release's, or this one's already.
PLIST_VERSION='key && /<string>/ { value = $0; sub(/.*<string>/, "", value); sub(/<\/string>.*/, "", value); print value }
    { key = 0 } /<key>CFBundleShortVersionString<\/key>/ { key = 1 }'
PLIST_SET='key { sub(/<string>[^<]*<\/string>/, "<string>" version "</string>") } { key = 0; print }
    /<key>CFBundleShortVersionString<\/key>/ { key = 1 }'
[[ -f "$PLIST" ]] || fail "$PLIST is missing."
CURRENT="$(awk "$PLIST_VERSION" "$PLIST")"
[[ "$CURRENT" == "$LAST" || "$CURRENT" == "$VERSION" ]] ||
    fail "$PLIST's version is \"$CURRENT\", neither the last release's, $LAST, nor $VERSION."

# The history that orders the notes, all of it, with all of main's notes, and nothing here that isn't committed.
[[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" == true ]] || fail "this isn't a git checkout."
[[ "$(git rev-parse --is-shallow-repository)" == false ]] ||
    fail "this checkout is shallow: the notes' order needs the whole history (git fetch --unshallow)."
git rev-parse --verify --quiet "$MAIN_REF^{commit}" > /dev/null ||
    fail "there's no $MAIN_REF: fetch it, or name the branch the pull requests merged into with --main."
git merge-base --is-ancestor "$MAIN_REF" HEAD ||
    fail "HEAD doesn't have all of $MAIN_REF: merge it first, for every pull request's notes."
git rev-parse --verify --quiet "refs/tags/v$LAST^{commit}" > /dev/null ||
    fail "there's no tag v$LAST, for the last release in $CHANGELOG: fetch the tags (git fetch --tags)."
same_versions_as "v$LAST"
EDITS=("$CHANGELOG" "$PLIST" "$NOTES")
for key in $SOURCES; do EDITS+=("$(file_of "$key")"); done
DIRTY="$(git status --porcelain --untracked-files=all -- "${EDITS[@]}")"
[[ -z "$DIRTY" ]] || fail "commit or undo these changes first:"$'\n'"$DIRTY"
MAIN_NOTES="$(git ls-tree --name-only "$MAIN_REF" -- "$NOTES/")"
while IFS= read -r path; do
    [[ -z "$path" || -e "$path" ]] || fail "$MAIN_REF has $path, which HEAD deleted."
done <<< "$MAIN_NOTES"
FILES="$(notes_files)"
[[ -n "$FILES" ]] || fail "there are no release notes in $NOTES/."

# In the order their pull requests merged: those on main by the commit of main's that added them, then any that are
# only here, such as the last pull request's, by the commit that added them; by name, where that's the same. A note
# added more than once, as after a release deleted another of its name, counts from the latest time.
git rev-list --first-parent --reverse "$MAIN_REF" > "$WORK/main"
git log --first-parent --no-renames --diff-filter=A --format='commit %H' --name-only "$MAIN_REF" -- "$NOTES/" \
    > "$WORK/main-added"
git log --no-renames --diff-filter=A --format='time %ct' --name-only HEAD -- "$NOTES/" > "$WORK/added"
printf '%s\n' "$MAIN_NOTES" > "$WORK/main-notes"
printf '%s\n' "$FILES" | awk -v main_notes="$WORK/main-notes" -v main="$WORK/main" -v main_added="$WORK/main-added" \
    -v added="$WORK/added" '
    BEGIN {
        while ((getline line < main_notes) > 0) on_main[line] = 1
        while ((getline line < main) > 0) position[line] = ++commits
        while ((getline line < main_added) > 0) {
            if (line ~ /^commit /) at = position[substr(line, 8)]
            else if (line != "" && !(line in main_at)) main_at[line] = at
        }
        while ((getline line < added) > 0) {
            if (line ~ /^time /) at = substr(line, 6) + 0
            else if (line != "" && !(line in here_at)) here_at[line] = at
        }
    }
    {
        if ($0 in on_main) {
            if (!main_at[$0]) { print "no commit of main'"'"'s added " $0 > "/dev/stderr"; exit 1 }
            printf "0 %012d %s\n", main_at[$0], $0
        } else {
            if (!here_at[$0]) { print "no commit added " $0 > "/dev/stderr"; exit 1 }
            printf "1 %012d %s\n", here_at[$0], $0
        }
    }' > "$WORK/order" || fail "couldn't tell when those notes were added to $MAIN_REF, or here."
LIST=()
while IFS= read -r path; do LIST+=("$path"); done <<< "$(sort -k1,1n -k2,2n -k3,3 "$WORK/order" | cut -d ' ' -f 3)"
parse "${LIST[@]}"

# Each description that changed rises by one, with a doc line that says what each pull request said, in order.
BUMP="$DECLARATION"' { while ((getline doc_line < doc) > 0) print doc_line; sub(/[0-9]+$/, version) } { print }'
CHANGED=()
RAISED=()
for key in $SOURCES; do
    [[ -s "$WORK/doc-$key" ]] || continue
    file="$(file_of "$key")"
    variable="$(variable_of "$key")"
    line="$(declaration "$file" "$variable")"
    next=$((${line##* = } + 1))
    indent="${line%%[! ]*}"
    wrap "$indent/// $next: " "$indent/// " "$(awk -v capitalize=0 "$JOIN" "$WORK/doc-$key")" > "$WORK/lines-$key"
    awk -v variable="$variable" -v version="$next" -v doc="$WORK/lines-$key" "$BUMP" "$file" > "$WORK/new-$key"
    [[ "$(declaration "$WORK/new-$key" "$variable")" == "${line% = *} = $next" ]] || fail "couldn't raise $file's $variable."
    CHANGED+=("$key")
    RAISED+=("$file: $variable $next.")
done

# "After this update, Azure DevOps and Copilot ask you once to look at what they read, and wait until you have."
after_this_update() {
    local names="" count=$# agents=0 index=0 key
    for key in "$@"; do
        index=$((index + 1))
        if [[ "$key" == agents ]]; then agents=1; fi
        if [[ $index -eq 1 ]]; then
            names="$(name_of "$key")"
        elif [[ $index -eq $count ]]; then
            names="$names and $(name_of "$key")"
        else
            names="$names, $(name_of "$key")"
        fi
    done
    if [[ $count -eq 1 && $agents -eq 1 ]]; then
        echo "After this update, agents ask you once to look at what they get, and wait until you have."
    elif [[ $count -eq 1 ]]; then
        echo "After this update, $names asks you once to look at what it reads, and waits until you have."
    elif [[ $agents -eq 1 ]]; then
        echo "After this update, $names ask you once to look at what they read and get, and wait until you have."
    else
        echo "After this update, $names ask you once to look at what they read, and wait until you have."
    fi
}

{
    printf '# Changelog\n\n## %s - %s\n\n' "$VERSION" "$DATE"
    if [[ -s "$WORK/bullets" ]]; then cat "$WORK/bullets"; fi
    if [[ ${#CHANGED[@]} -gt 0 ]]; then
        wrap "- " "  " "**$(after_this_update "${CHANGED[@]}")** $(awk -v capitalize=1 "$JOIN" "$WORK/after")"
    fi
    echo
    sed -n '/^## /,$p' "$CHANGELOG"
} > "$WORK/CHANGELOG.md"

if [[ "$CURRENT" != "$VERSION" ]]; then
    awk -v version="$VERSION" "$PLIST_SET" "$PLIST" > "$WORK/Info.plist"
    if [[ "$(awk "$PLIST_VERSION" "$WORK/Info.plist")" != "$VERSION" ]] || ! plutil -lint -s "$WORK/Info.plist"; then
        fail "couldn't set the version in $PLIST."
    fi
fi

# Everything's ready: only now does anything here change.
cat "$WORK/CHANGELOG.md" > "$CHANGELOG"
if [[ -f "$WORK/Info.plist" ]]; then cat "$WORK/Info.plist" > "$PLIST"; fi
for key in ${CHANGED[@]+"${CHANGED[@]}"}; do
    cat "$WORK/new-$key" > "$(file_of "$key")"
done
rm -f -- "${LIST[@]}"

BULLETS="$(grep -c '^- ' "$WORK/bullets" 2>/dev/null || true)"
echo "Prepared BriefBar $VERSION, of $DATE, from the notes of ${#LIST[@]} pull requests, in the order they merged:"
printf '  %s\n' "${LIST[@]}"
if [[ ${#CHANGED[@]} -gt 0 ]]; then
    echo "$CHANGELOG: a section for $VERSION, with ${BULLETS:-0} bullets and After this update."
else
    echo "$CHANGELOG: a section for $VERSION, with ${BULLETS:-0} bullets."
fi
echo "$PLIST: version $VERSION."
if [[ ${#RAISED[@]} -gt 0 ]]; then printf '%s\n' "${RAISED[@]}"; fi
echo "It deleted those notes. Review it all, then commit it, the deletions too: git commit -a"
