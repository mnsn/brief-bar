#!/bin/bash
# Checks the boundaries that keep what BriefBar reads on your Mac, and what it does there, module by module:
# - Only the Azure DevOps and GitHub sources' cores (AzureDevOpsCore and GitHubCore) use networking APIs.
#   Teams and Copilot make no network requests, and nothing else in the app does either.
# - Only BriefBarCore starts programs, through ProcessRunner and RunningProgram, which keep them from using
#   BriefBar's privacy permissions, Full Disk Access included.
# - Only ThisMac (Sources/BriefBarUI/ThisMac.swift) opens links, files, apps and System Settings, brings another app
#   forward, shows files in the Finder, writes the clipboard, asks in alerts and panels, and makes SwiftUI's links and
#   what opens them: in a test process it refuses each, so that no test does any of them on your Mac.
# The app's binary combines every module, so this reads the debug build's object files, module by
# module: what their code calls, however it's spelled. (A release build's cross-module optimization could inline one
# module's code into another's.) Every module in Sources must have them, or it fails.
#   scripts/check-boundaries.sh   (after `swift build`)
set -euo pipefail
cd "$(dirname "$0")/.."

NETWORK_MODULES="AzureDevOpsCore GitHubCore"
# Foundation's URL loading, CFNetwork, sockets and Network.framework (C and Swift).
NETWORK='URLSession|URLRequest|NSURLConnection|CFNetwork|CFHTTP|CFSocket|^_nw_|s7Network'
PROCESS_MODULE="BriefBarCore"
# Starting programs: posix_spawn, Foundation's Process (NSTask), the C library's other ways, and the script tasks
# and AppleScript, which run scripts and programs on BriefBar's behalf.
PROCESSES='^_(posix_spawnp?|popen|system|execv|execve|execvp|execl|execle|execlp|fork|vfork)$|NSTask|NSUser[A-Za-z]*Task|NSAppleScript|OSAScript'
THIS_MAC_MODULE="BriefBarUI"
THIS_MAC="ThisMac"
# What only ThisMac does: the Objective-C messages the code sends for each of them, and the SwiftUI types it uses.
ON_THIS_MAC='^_objc_msgSend\$('
ON_THIS_MAC+='open(URL|URLs|File|Application|SystemSettings)[A-Za-z:]*|launchApplication[A-Za-z:]*|'  # links, files, apps
ON_THIS_MAC+='activateWithOptions:|activateFromApplication:options:|'                                # another app forward
ON_THIS_MAC+='activateFileViewerSelectingURLs:|selectFile:inFileViewerRootedAtPath:|'                 # the Finder
ON_THIS_MAC+='clearContents|declareTypes:owner:|writeObjects:|set(String|Data|PropertyList):forType:|' # the clipboard
ON_THIS_MAC+='runModal[A-Za-z:]*|beginModalSessionForWindow:|'                                      # alerts and panels,
ON_THIS_MAC+='beginSheetModalForWindow:[A-Za-z:]*|beginWithCompletionHandler:'                      # their sheets too
# SwiftUI's Link, and OpenURLAction, what opens links, Link's and those in text, as its environment value sets it.
ON_THIS_MAC+=')$|^_\$s7SwiftUI4LinkV|13OpenURLActionV'
# What ThisMac's own object file has to show, one of each kind, or the compiled code no longer says what this looks
# for, as with another compiler, and this check couldn't tell ThisMac from the rest.
THIS_MAC_SHOWS='^_objc_msgSend\$openURL:$ ^_\$s7SwiftUI4LinkV 13OpenURLActionV'

LIST="$(mktemp)"
SYMBOLS="$(mktemp)"
trap 'rm -f "$LIST" "$SYMBOLS"' EXIT
# One line per object file: its module, then its path. Swift 6.3 and later lay out builds as
# .../Debug/<Module>-t.build/Objects-normal/<arch>/*.o; earlier versions as .../debug/<Module>.build/*.o.
find .build \( -path '*/Debug/*' -o -path '*/debug/*' \) -name '*.o' | while IFS= read -r object; do
    module="$(printf '%s\n' "$object" | sed -E -n \
        -e 's#.*/Debug/([^/]+)-[tp]\.build/Objects-normal/.*#\1#p' \
        -e 's#.*/debug/([^/]+)\.build/.*#\1#p' | head -n 1)"
    case "$module" in
        "" | *Tests | *PackageTests | *PackageDiscoveredTests) continue ;;
    esac
    printf '%s\t%s\n' "$module" "$object"
done | sort > "$LIST"

if [[ ! -s "$LIST" ]]; then
    echo "check-boundaries: no object files in .build. Run 'swift build' first." >&2
    exit 1
fi

FAILED=false
MODULES="$(cut -f 1 "$LIST" | sort -u)"
# Every module in Sources, or a build that stopped partway would pass with the modules it got to.
for folder in Sources/*/; do
    module="$(basename "$folder")"
    if [[ $'\n'"$MODULES"$'\n' != *$'\n'"$module"$'\n'* ]]; then
        echo "check-boundaries: $module has no object files in .build, so this can't check it. Run 'swift build' first." >&2
        FAILED=true
    fi
done
$FAILED && exit 1

# Every object file's undefined symbols, what its code calls, read with one nm for them all: its module, its path,
# then a symbol, a line each.
cut -f 2 "$LIST" | tr '\n' '\0' | xargs -0 nm -uA 2>/dev/null | awk -F '\t' '
    NR == FNR { module[$2] = $1; next }
    { at = index($0, ".o: "); path = substr($0, 1, at + 1) }
    at > 0 && path in module { print module[path] "\t" path "\t" substr($0, at + 4) }
' "$LIST" - > "$SYMBOLS" || true
if [[ ! -s "$SYMBOLS" ]]; then
    echo "check-boundaries: nm read nothing from the object files in .build, so this can't check them." >&2
    exit 1
fi

# The undefined symbols of a module's object files that match a pattern, a few of them.
uses() {
    awk -F '\t' -v module="$1" '$1 == module { print $3 }' "$SYMBOLS" | grep -E "$2" | sort -u | head -n 5 || true
}

for module in $MODULES; do
    for check in "network:$NETWORK_MODULES:networking APIs" "processes:$PROCESS_MODULE:ways to start programs"; do
        kind="${check%%:*}"
        rest="${check#*:}"
        allowed="${rest%%:*}"
        what="${rest#*:}"
        pattern="$NETWORK"
        [[ "$kind" == processes ]] && pattern="$PROCESSES"
        found="$(uses "$module" "$pattern")"
        if [[ " $allowed " == *" $module "* ]]; then
            if [[ -z "$found" ]]; then
                echo "check-boundaries: $module uses no $what, so this check can't tell them apart anymore." >&2
                FAILED=true
            fi
        elif [[ -n "$found" ]]; then
            echo "check-boundaries: $module uses $what, which only ${allowed// / and } may:" >&2
            printf '  %s\n' $found >&2
            FAILED=true
        fi
    done
done

# ThisMac's boundary is a file's, not a module's: BriefBarUI's other files may not do what it does either. ThisMac's own
# object files, by their name in either layout: one for each build in .build, and for each architecture.
THIS_MAC_OBJECTS="$(awk -F '\t' -v module="$THIS_MAC_MODULE" -v name="$THIS_MAC" '$1 == module {
    count = split($2, parts, "/"); if (parts[count] == name ".o" || parts[count] == name ".swift.o") print $2
}' "$LIST")"
# The symbols that do what only ThisMac may, as the symbol table has them: matched alone, then found by their line.
ON_THIS_MAC_FOUND="$(cut -f 3 "$SYMBOLS" | grep -nE "$ON_THIS_MAC" | cut -d : -f 1 \
    | awk 'NR == FNR { wanted[$1]; next } FNR in wanted' - "$SYMBOLS" || true)"
while IFS=$'\t' read -r module object; do
    if [[ -z "$object" ]] || grep -qxF "$object" <<< "$THIS_MAC_OBJECTS"; then
        continue
    fi
    name="$(basename "$object")"
    name="${name%.o}"
    # With its path, since an older build's object files, left in .build, count too.
    echo "check-boundaries: $module's ${name%.swift} does on your Mac what only $THIS_MAC may, which refuses it in tests ($object):" >&2
    awk -F '\t' -v object="$object" '$2 == object { print "  " $3 }' <<< "$ON_THIS_MAC_FOUND" | sort -u | head -n 5 >&2
    FAILED=true
done < <(cut -f 1,2 <<< "$ON_THIS_MAC_FOUND" | sort -u)
if [[ -z "$THIS_MAC_OBJECTS" ]]; then
    echo "check-boundaries: $THIS_MAC_MODULE has no object file of its own for $THIS_MAC, so this can't tell it from the rest." >&2
    FAILED=true
else
    THIS_MAC_SYMBOLS="$(awk -F '\t' 'NR == FNR { ours[$0]; next } $2 in ours { print $3 }' - "$SYMBOLS" <<< "$THIS_MAC_OBJECTS")"
    for shown in $THIS_MAC_SHOWS; do
        if ! grep -qE "$shown" <<< "$THIS_MAC_SYMBOLS"; then
            echo "check-boundaries: $THIS_MAC's object files have nothing like $shown, so this check can't see what it does anymore." >&2
            FAILED=true
        fi
    done
fi
$FAILED && exit 1
echo "check-boundaries passed: only ${NETWORK_MODULES// / and } use networking APIs, only $PROCESS_MODULE starts programs, and only $THIS_MAC opens, copies or asks anything on your Mac ($(echo $MODULES | wc -w | tr -d ' ') modules)"
