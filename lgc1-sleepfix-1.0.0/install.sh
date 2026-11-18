#!/bin/sh
# Stage source-only SleepFix from the owner's exact audited TV binary.
# Does not mount, restart services, enable boot persistence, or overwrite firmware.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH
umask 077
ROOT=/var/lib/webosbrew/lgc1-sleepfix
TARGET=/usr/sbin/tv-reservation-agent
SOURCE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo 'Run as root on the TV.' >&2; exit 1; }
case "$(uname -m)" in arm*|aarch64) ;; *) echo 'This package is for the ARM LG TV.' >&2; exit 1;; esac
[ -f "$TARGET" ] && [ ! -L "$TARGET" ] || { echo 'Missing or symlinked stock executable.' >&2; exit 1; }
MOUNT_COUNT=$(awk -v p="$TARGET" '$5==p {n++} END{print n+0}' /proc/self/mountinfo)
[ "$MOUNT_COUNT" = 0 ] || { echo 'An executable overlay is already mounted. Stop and inspect; no files changed.' >&2; exit 1; }
if [ -e "$ROOT" ] || [ -L "$ROOT" ]; then
    echo "Existing installation at $ROOT; refusing to replace. Use its controller to check/status/rollback." >&2
    exit 1
fi
(cd "$SOURCE" && sha256sum -c SHA256SUMS) || { echo 'Source package checksum verification failed.' >&2; exit 1; }
STAGE=/var/lib/webosbrew/lgc1-sleepfix.stage.$$
[ ! -e "$STAGE" ] && [ ! -L "$STAGE" ] || exit 1
mkdir -p /var/lib/webosbrew
mkdir -m 700 "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cp -R "$SOURCE"/. "$STAGE"/
mkdir -p "$STAGE/reference"
sh "$STAGE/tools/build-from-tv.sh" "$TARGET" "$STAGE/reference/tv-reservation-agent.original" "$STAGE/tv-reservation-agent.sleepfix"
(cd "$STAGE" && sha256sum -c SHA256SUMS) || { echo 'Staged source checksum verification failed.' >&2; exit 1; }
chmod 700 "$STAGE" "$STAGE/install.sh" "$STAGE/sleepfixctl.sh" "$STAGE/boot-hook.sh"
chmod 555 "$STAGE/tv-reservation-agent.sleepfix"
chmod 400 "$STAGE/reference/tv-reservation-agent.original"
chown -R 0:0 "$STAGE"
mv "$STAGE" "$ROOT"
trap - EXIT HUP INT TERM
printf 'Staged at %s. No TV service, mount, or boot behavior changed.\n' "$ROOT"
printf 'Next: sh %s/sleepfixctl.sh check\n' "$ROOT"
