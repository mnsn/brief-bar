#!/bin/bash
# Checks that only the Azure DevOps source's core (AzureDevOpsCore) uses networking APIs: Teams and
# Copilot make no network requests, and nothing else in the app does either. The app's binary combines
# every module, so this reads the debug build's object files, module by module. (A release build's
# cross-module optimization could inline one module's code into another's.)
#   scripts/check-networking.sh   (after `swift build`)
set -euo pipefail
cd "$(dirname "$0")/.."

ALLOWED="AzureDevOpsCore"
# Foundation's URL loading, CFNetwork, sockets and Network.framework (C and Swift).
PATTERN='URLSession|URLRequest|NSURLConnection|CFNetwork|CFHTTP|CFSocket|[[:space:]]_nw_|s7Network'

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
    echo "check-networking: no object files in .build. Run 'swift build' first." >&2
    exit 1
fi

FAILED=false
MODULES="$(cut -f 1 "$LIST" | sort -u)"
for module in $MODULES; do
    USES="$(awk -F '\t' -v module="$module" '$1 == module { print $2 }' "$LIST" | while IFS= read -r object; do
        nm -u "$object" 2>/dev/null || true
    done | grep -E "$PATTERN" | sort -u | head -n 5 || true)"
    if [[ "$module" == "$ALLOWED" ]]; then
        if [[ -z "$USES" ]]; then
            echo "check-networking: $module uses no networking APIs, so this check can't tell them apart anymore." >&2
            FAILED=true
        fi
    elif [[ -n "$USES" ]]; then
        echo "check-networking: $module uses networking APIs, which only $ALLOWED may:" >&2
        printf '  %s\n' $USES >&2
        FAILED=true
    fi
done
$FAILED && exit 1
echo "check-networking passed: only $ALLOWED uses networking APIs ($(echo $MODULES | wc -w | tr -d ' ') modules)"
