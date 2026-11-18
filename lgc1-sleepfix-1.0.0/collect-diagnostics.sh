#!/bin/sh
# Read-only diagnostic output; no writes, mounts, or service changes.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
ROOT=/var/lib/webosbrew/lgc1-sleepfix
printf '\n=== RELEASE ===\n'
uname -a
cat /etc/starfish-release 2>/dev/null
printf '\n=== PATCH STATUS ===\n'
sh "$ROOT/sleepfixctl.sh" status
printf '\n=== MATCHING EXECUTABLE PROCESSES ===\n'
for exe in /proc/[0-9]*/exe; do
    dest=$(readlink "$exe" 2>/dev/null) || continue
    case "$dest" in
        /usr/sbin/tv-reservation-agent*|"$ROOT"/tv-reservation-agent.sleepfix*)
            pid=${exe%/exe}; pid=${pid##*/}
            printf 'PID=%s EXE=%s\n' "$pid" "$dest"
            cat "/proc/$pid/cgroup"
            sha256sum "$exe"
            ;;
    esac
done
printf '\n=== MOUNT DETAILS ===\n'
awk '$5 == "/usr/sbin/tv-reservation-agent" {print}' /proc/self/mountinfo
printf '\n=== SAVED UNIT INFO ===\n'
cat "$ROOT/unit-info.txt" 2>/dev/null
printf '\n=== RECENT CONTROLLER LOG ===\n'
tail -n 80 "$ROOT/deploy.log" 2>/dev/null
printf '\n=== RECENT BOOT HOOK LOG ===\n'
tail -n 60 "$ROOT/boot-output.log" 2>/dev/null
exit 0
