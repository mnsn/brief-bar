#!/bin/bash
# Shows that BriefBar's updater, which turns library validation off to load Sparkle, can't use BriefBar's privacy
# permissions, and that a copy of BriefBar with other code in place of Sparkle never runs that code as BriefBar.
# It works on a copy of a build, opened by macOS as you'd open it; never use it on your installed app, whose copy
# could get your Full Disk Access.
# 1. A control: an app that macOS opens, and that starts a program the usual way, has macOS attribute that program
#    to it, so the program could use the app's permissions. Started the way BriefBar starts its updater
#    (RunningProgram), the program is responsible for itself.
# 2. BriefBar, opened the same way, loads only Apple's libraries, and starts its updater responsible for itself
#    (`BriefBar --check-updater`).
# 3. A library of our own, signed ad hoc, takes Sparkle's place in the updater, and in BriefBar's Frameworks, where
#    0.1.0 had Sparkle, and DYLD_INSERT_LIBRARIES names it. It notes each process that runs it: only the updater,
#    responsible for itself, and never BriefBar.
#   scripts/test-updater-isolation.sh [app]   (default: build/BriefBar.app)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/BriefBar.app}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
WORK="$(mktemp -d)"
cleanup() {
    for app in "$WORK"/*.app; do
        "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT
fail() {
    echo "test-updater-isolation: $1" >&2
    exit 1
}
[[ -x "$APP/Contents/MacOS/BriefBar" ]] || fail "no app at $APP. Run make app first."
ARCH_FLAGS=()
for arch in $(lipo -archs "$APP/Contents/Helpers/BriefBar Updater.app/Contents/MacOS/BriefBarUpdater"); do
    ARCH_FLAGS+=(-arch "$arch")
done

# Opens an app the way Finder does (open's options, the app, then --args and its own), waits for it to quit, and
# prints what it wrote.
open_app() {
    local output="$WORK/output.$RANDOM"
    open -W -n -g --stdout "$output" --stderr "$output" "$@"
    cat "$output"
}

# 1. The control: an app that starts /bin/sleep twice, the usual way and responsible for itself, and prints its
# process ID and what each process is attributed to.
CONTROL="$WORK/Control.app"
mkdir -p "$CONTROL/Contents/MacOS"
cat > "$WORK/control.c" <<'C'
#include <dlfcn.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
static pid_t start(bool disclaimed) {
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    if (disclaimed) {
        int (*disclaim)(posix_spawnattr_t *, bool) = dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
        if (disclaim == NULL || disclaim(&attributes, true) != 0) return -1;
    }
    char *argv[] = {"/bin/sleep", "10", NULL};
    pid_t pid = -1;
    posix_spawn(&pid, "/bin/sleep", NULL, &attributes, argv, environ);
    posix_spawnattr_destroy(&attributes);
    return pid;
}
int main(void) {
    pid_t (*responsible)(pid_t) = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    pid_t me = getpid(), usual = start(false), disclaimed = start(true);
    printf("%d %d %d %d %d %d\n", me, responsible(me), usual, responsible(usual), disclaimed, responsible(disclaimed));
    kill(usual, SIGKILL);
    kill(disclaimed, SIGKILL);
    waitpid(usual, NULL, 0);
    waitpid(disclaimed, NULL, 0);
    return 0;
}
C
clang -O2 -o "$CONTROL/Contents/MacOS/control" "$WORK/control.c"
cat > "$CONTROL/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>control</string>
	<key>CFBundleIdentifier</key>
	<string>com.asaf.BriefBar.isolation-control</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSBackgroundOnly</key>
	<true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$CONTROL" 2>/dev/null
read -r ME ME_TO USUAL USUAL_TO DISCLAIMED DISCLAIMED_TO <<< "$(open_app "$CONTROL")" || true
[[ -n "${DISCLAIMED_TO:-}" ]] || fail "the control app didn't report (macOS didn't open it?)."
[[ "$ME_TO" == "$ME" ]] || fail "control: an app macOS opened is attributed to process $ME_TO, not itself."
[[ "$USUAL_TO" == "$ME" ]] ||
    fail "control: macOS here doesn't attribute a program to the app that started it ($USUAL is attributed to $USUAL_TO), so this check can't tell the difference."
[[ "$DISCLAIMED_TO" == "$DISCLAIMED" ]] || fail "control: a program started responsible for itself is attributed to $DISCLAIMED_TO."
echo "Control: in an app macOS opened (process $ME), a program started the usual way is attributed to the app; one started responsible for itself isn't."

# 2. A copy of BriefBar, opened the same way.
COPY="$WORK/BriefBar.app"
ditto "$APP" "$COPY"
check_updater() {
    local report
    report="$(open_app "$@" "$COPY" --args --check-updater)"
    printf '%s\n' "$report" | sed 's/^/  /'
    [[ "$report" != *FAILED* ]] || fail "BriefBar --check-updater failed."
    BRIEFBAR_PID="$(printf '%s\n' "$report" | sed -n 's/^BriefBar: process \([0-9]*\), attributed to itself$/\1/p')"
    UPDATER_PID="$(printf '%s\n' "$report" | sed -n 's/^Updater: process \([0-9]*\), .*, attributed to itself$/\1/p')"
    [[ -n "$BRIEFBAR_PID" ]] || fail "BriefBar, opened by macOS, isn't attributed to itself."
    [[ -n "$UPDATER_PID" && "$UPDATER_PID" != "$BRIEFBAR_PID" ]] || fail "BriefBar's updater isn't attributed to itself."
    [[ "$report" == *"BriefBar loaded only Apple's libraries"* ]] || fail "BriefBar loaded other libraries."
}
echo "BriefBar, opened by macOS:"
check_updater

# 3. A library that notes each process that runs it, with what macOS attributes the process to. It defines the
# Sparkle classes the updater uses, empty, so that the updater loads it.
{
    echo '#import <Foundation/Foundation.h>'
    echo '#include <dlfcn.h>'
    echo '#include <stdio.h>'
    echo '#include <unistd.h>'
    nm -m -u -arch "$(lipo -archs "$COPY/Contents/Helpers/BriefBar Updater.app/Contents/MacOS/BriefBarUpdater" | cut -d ' ' -f 1)" \
        "$COPY/Contents/Helpers/BriefBar Updater.app/Contents/MacOS/BriefBarUpdater" |
        awk '/\(from Sparkle\)/ { print $(NF-2) }' | sort -u | while IFS= read -r symbol; do
            case "$symbol" in
                '_OBJC_CLASS_$_'*) name="${symbol#_OBJC_CLASS_\$_}"; echo "@interface $name : NSObject @end @implementation $name @end" ;;
                '_OBJC_METACLASS_$_'*) ;;
                _*) echo "const void *const ${symbol#_} = 0;" ;;
            esac
        done
    cat <<'C'
__attribute__((constructor)) static void note(void) {
    pid_t (*responsible)(pid_t) = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    FILE *notes = fopen(NOTES, "a");
    if (notes != NULL) {
        fprintf(notes, "%d %d %s\n", getpid(), responsible != NULL ? responsible(getpid()) : -1, getprogname());
        fclose(notes);
    }
}
C
} > "$WORK/stand-in.m"
clang -dynamiclib -fobjc-arc -framework Foundation "${ARCH_FLAGS[@]}" -Wno-objc-root-class \
    -install_name @rpath/Sparkle.framework/Versions/B/Sparkle -compatibility_version 1.6.0 -current_version 2.10.0 \
    -DNOTES="\"$WORK/notes\"" -o "$WORK/Sparkle" "$WORK/stand-in.m"
codesign --force --sign - "$WORK/Sparkle" 2>/dev/null
cp "$WORK/Sparkle" "$COPY/Contents/Helpers/BriefBar Updater.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
mkdir -p "$COPY/Contents/Frameworks/Sparkle.framework/Versions/B"
cp "$WORK/Sparkle" "$COPY/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
echo "The copy, with an ad-hoc library in place of Sparkle, and DYLD_INSERT_LIBRARIES naming it:"
check_updater --env "DYLD_INSERT_LIBRARIES=$WORK/Sparkle"
[[ -s "$WORK/notes" ]] || fail "the library never ran, so this test shows nothing: did the updater load it?"
while read -r pid responsible name; do
    echo "  The library ran in process $pid ($name), attributed to $([[ "$responsible" == "$pid" ]] && echo itself || echo "$responsible")."
    [[ "$pid" != "$BRIEFBAR_PID" && "$name" != BriefBar ]] || fail "the library ran in BriefBar."
    [[ "$pid" == "$UPDATER_PID" && "$responsible" == "$pid" ]] || fail "the library ran in process $pid, attributed to $responsible."
done < "$WORK/notes"
echo "test-updater-isolation passed: BriefBar loads only Apple's libraries; other code in place of Sparkle runs only in the updater, which macOS holds responsible for itself, not BriefBar."
