#!/bin/sh
# SPDX-License-Identifier: MIT
# Symlink this packaged file into init.d; never copy it outside the app.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset LD_PRELOAD
APP=/media/developer/apps/usr/palm/applications/io.github.tojala1998.sleepfix
ROOT=/var/lib/webosbrew/lgc1-sleepfix
[ -f "$APP/appinfo.json" ] || exit 0
[ -f "$APP/bin/sleepfixctl.sh" ] || exit 0
[ -f "$ROOT/enabled" ] || exit 0
[ ! -L "$ROOT" ] && [ ! -L "$ROOT/boot-output.log" ] || exit 0
(
    trap '' HUP
    exec /bin/sh "$APP/bin/sleepfixctl.sh" boot
) </dev/null >>"$ROOT/boot-output.log" 2>&1 &
exit 0
