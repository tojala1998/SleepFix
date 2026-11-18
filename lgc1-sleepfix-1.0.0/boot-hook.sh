#!/bin/sh
# Return immediately to run-parts; never stall Homebrew startup.
ROOT=/var/lib/webosbrew/lgc1-sleepfix
[ -f "$ROOT/enabled" ] || exit 0
[ -f "$ROOT/sleepfixctl.sh" ] || exit 0
(
    trap '' HUP
    exec sh "$ROOT/sleepfixctl.sh" boot
) </dev/null >>"$ROOT/boot-output.log" 2>&1 &
exit 0
