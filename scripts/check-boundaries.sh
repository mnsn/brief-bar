#!/bin/bash
# Checks the two boundaries that keep what BriefBar reads on your Mac, module by module:
# - Only the Azure DevOps and GitHub sources' cores (AzureDevOpsCore and GitHubCore) use networking APIs.
#   Teams and Copilot make no network requests, and nothing else in the app does either.
# - Only BriefBarCore starts programs, through ProcessRunner and RunningProgram, which keep them from using
#   BriefBar's privacy permissions, Full Disk Access included.
# The app's binary combines every module, so this reads the debug build's object files, module by
# module. (A release build's cross-module optimization could inline one module's code into another's.)
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

LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
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

# The undefined symbols of a module's object files that match a pattern, a few of them.
uses() {
    awk -F '\t' -v module="$1" '$1 == module { print $2 }' "$LIST" | while IFS= read -r object; do
        nm -u "$object" 2>/dev/null || true
    done | grep -E "$2" | sort -u | head -n 5 || true
}

FAILED=false
MODULES="$(cut -f 1 "$LIST" | sort -u)"
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
$FAILED && exit 1
echo "check-boundaries passed: only ${NETWORK_MODULES// / and } use networking APIs, and only $PROCESS_MODULE starts programs ($(echo $MODULES | wc -w | tr -d ' ') modules)"
