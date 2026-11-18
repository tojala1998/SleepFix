#!/bin/sh
# LG C1 sleep-warning screen-wake fix 1.0.0.
# Only a bind mount is used. This script NEVER writes to TARGET.
# A matching process image + validated systemd unit are required before restart.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
ROOT=/var/lib/webosbrew/lgc1-sleepfix
PROC=/proc
TARGET=/usr/sbin/tv-reservation-agent
PATCH="$ROOT/tv-reservation-agent.sleepfix"
REF="$ROOT/reference/tv-reservation-agent.original"
HOOK=/var/lib/webosbrew/init.d/99-lgc1-sleepfix
LOCK=/tmp/lgc1-sleepfix.lock
LOG="$ROOT/deploy.log"
ORIGINAL_SHA=6bee2e9fbe9836addede0a3f2e33342fb1914ff5f1793d2bffa030bfc0e38330
PATCH_SHA=23bb2fe19594d1b42d4dfdbcf3d40b675f225ac15990b9d2a5cb2c0b571cd40f
UNIT=
PID=
IN_TRANSITION=0
LOCKED=0

say() { printf '%s\n' "$*"; }
log() {
    _line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    say "$_line"
    [ ! -d "$ROOT" ] || printf '%s\n' "$_line" >>"$LOG"
}
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
hash_file() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
require_root() {
    [ "$(id -u)" = 0 ] || fail 'Run in the TV root SSH shell.'
    [ ! -L "$ROOT" ] || fail 'Install directory must not be a symlink.'
}
require_tools() {
    for _cmd in sha256sum awk sed grep stat readlink flock systemctl mount umount sleep date; do
        command -v "$_cmd" >/dev/null 2>&1 || fail "Required command unavailable: $_cmd"
    done
}
lock_changes() {
    exec 9>"$LOCK" || fail 'Cannot open operation lock.'
    flock -n 9 || fail 'Another SleepFix operation is in progress.'
    LOCKED=1
}
mount_count() {
    awk -v p="$TARGET" '$5 == p {n++} END {print n+0}' "$PROC/self/mountinfo"
}
inode_id() { stat -Lc '%d:%i' "$1" 2>/dev/null; }
our_mount() {
    [ "$(mount_count)" = 1 ] || return 1
    _a=$(inode_id "$TARGET") || return 1
    _b=$(inode_id "$PATCH") || _b=
    if [ -n "$_a" ] && [ "$_a" = "$_b" ]; then return 0; fi
    # Allows rollback even if the mounted payload file was deleted later.
    _saved=$(cat "$ROOT/mounted-inode" 2>/dev/null) || _saved=
    [ -n "$_a" ] && [ "$_a" = "$_saved" ]
}
verify_payload() {
    [ -f "$PATCH" ] && [ ! -L "$PATCH" ] || fail 'Missing or symlinked patched payload.'
    [ "$(hash_file "$PATCH")" = "$PATCH_SHA" ] || fail 'Patched payload checksum mismatch.'
    [ "$(hash_file "$REF")" = "$ORIGINAL_SHA" ] || fail 'Reference original checksum mismatch.'
    [ -x "$PATCH" ] || fail 'Patched payload is not executable.'
}
verify_target() {
    [ -f "$TARGET" ] && [ ! -L "$TARGET" ] || fail 'Unexpected system executable path/type.'
    _count=$(mount_count)
    case "$_count" in
        0) [ "$(hash_file "$TARGET")" = "$ORIGINAL_SHA" ] ||
               fail 'TV executable differs from the audited original. No patch applied.' ;;
        1) our_mount || fail 'Another overlay owns the executable. Refusing to replace it.'
           [ "$(hash_file "$TARGET")" = "$PATCH_SHA" ] || fail 'Mounted payload is damaged. Use rollback.' ;;
        *) fail 'Multiple overlays on the executable; refusing to guess which to undo.' ;;
    esac
}
find_daemon() {
    _found=
    for _exe in "$PROC"/[0-9]*/exe; do
        [ -e "$_exe" ] || continue
        _link=$(readlink "$_exe" 2>/dev/null) || continue
        case "$_link" in
            "$TARGET"|"$TARGET (deleted)"|"$PATCH"|"$PATCH (deleted)")
                _p=${_exe%/exe}; _p=${_p##*/}
                _found="$_found $_p" ;;
        esac
    done
    set -- $_found
    [ "$#" = 1 ] || return 1
    PID=$1
    _sha=$(hash_file "$PROC/$PID/exe")
    [ "$_sha" = "$ORIGINAL_SHA" ] || [ "$_sha" = "$PATCH_SHA" ] || return 1
}
prop() {
    systemctl show "$UNIT" -p "$1" 2>/dev/null | sed -n "s/^$1=//p"
}
valid_unit_name() {
    case "$UNIT" in ''|*[!a-zA-Z0-9_.@:-]*) return 1;; esac
    case "$UNIT" in *.service) return 0;; *) return 1;; esac
}
validate_unit() {
    valid_unit_name || return 1
    _exec=$(prop ExecStart)
    # Match the executable field exactly, not an argument containing the path.
    printf '%s\n' "$_exec" | grep -F "path=$TARGET " >/dev/null ||
      printf '%s\n' "$_exec" | grep -F "path=$TARGET;" >/dev/null || return 1
    [ "$(prop LoadState)" = loaded ] || return 1
}
detect_unit() {
    find_daemon || fail 'Expected one running, known tv-reservation-agent. See status; nothing changed.'
    UNIT=$(awk -F: '$2 == "name=systemd" || $1 == "0" {
        n=split($3,a,"/"); for(i=1;i<=n;i++) if(a[i] ~ /\.service$/) print a[i]
    }' "$PROC/$PID/cgroup" | head -n 1)
    # A fallback name is accepted only if ExecStart and MainPID prove ownership.
    [ -n "$UNIT" ] || UNIT=tv-reservation-agent.service
    validate_unit || fail 'Cannot validate the daemon systemd unit. No service will be guessed/restarted.'
    [ "$(prop MainPID)" = "$PID" ] || fail 'systemd MainPID does not match the inspected process.'
}
check_restart_policy() {
    [ "$(prop RefuseManualStop)" != yes ] || fail 'Unit refuses manual stop/restart.'
    _onfailure=$(prop OnFailure)
    [ -z "$_onfailure" ] || fail "Unit has OnFailure handlers ($_onfailure); review before restarting."
    for _p in FailureAction StartLimitAction; do
        _v=$(prop "$_p")
        case "$_v" in ''|none) ;; *) fail "Unit $_p=$_v could affect the TV; refusing restart.";; esac
    done
}
save_unit() {
    printf '%s\n' "$UNIT" >"$ROOT/unit.tmp" && mv "$ROOT/unit.tmp" "$ROOT/unit" || fail 'Cannot record recovery unit.'
    systemctl show "$UNIT" -p Id -p MainPID -p ExecStart -p FragmentPath -p Type -p Restart -p OnFailure -p FailureAction -p StartLimitAction >"$ROOT/unit-info.txt" 2>&1 || :
}
load_recovery_unit() {
    UNIT=$(cat "$ROOT/unit" 2>/dev/null) || UNIT=
    validate_unit
}
disarm() {
    rm -f "$ROOT/enabled" || return 1
    if [ -L "$HOOK" ] && [ "$(readlink "$HOOK")" = "$ROOT/boot-hook.sh" ]; then
        rm -f "$HOOK" || return 1
    elif [ -e "$HOOK" ] || [ -L "$HOOK" ]; then
        log 'An unrelated file occupies the hook name; left untouched.'
        return 1
    fi
    return 0
}
wait_healthy() {
    _want=$1
    _stable=0; _last=; _try=0
    # Bounded startup observation, NOT a full functional timer test.
    while [ "$_try" -lt 30 ]; do
        _try=$((_try+1))
        _pid=$(prop MainPID)
        case "$_pid" in ''|0|*[!0-9]*) _stable=0;;
            *)
                if systemctl is-active --quiet "$UNIT" &&
                   [ "$(hash_file "$PROC/$_pid/exe")" = "$_want" ]; then
                    if [ "$_pid" = "$_last" ]; then _stable=$((_stable+1)); else _stable=1; fi
                    _last=$_pid
                    [ "$_stable" -lt 8 ] || { PID=$_pid; return 0; }
                else _stable=0; fi ;;
        esac
        sleep 1
    done
    return 1
}
wait_stopped() {
    _stop_try=0
    while [ "$_stop_try" -lt 30 ]; do
        _stop_try=$((_stop_try+1))
        _spid=$(prop MainPID)
        _state=$(prop ActiveState)
        if [ "${_spid:-0}" = 0 ]; then
            case "$_state" in
                inactive|failed)
                    _left=0
                    for _exe in "$PROC"/[0-9]*/exe; do
                        [ -e "$_exe" ] || continue
                        _link=$(readlink "$_exe" 2>/dev/null) || continue
                        case "$_link" in
                            "$TARGET"|"$TARGET (deleted)"|"$PATCH"|"$PATCH (deleted)") _left=1;;
                        esac
                    done
                    [ "$_left" != 0 ] || return 0 ;;
            esac
        fi
        sleep 1
    done
    return 1
}
restore_stock() {
    # Stop the service BEFORE unmounting: a running executable can pin a bind mount.
    # No dependency on the patched checksum: a damaged payload must be removable.
    _count=$(mount_count)
    _stopped=0
    if [ "$_count" != 0 ]; then
        our_mount || { log 'Rollback refused: executable overlay is not identifiable as ours.'; return 1; }
        load_recovery_unit || { log 'Cannot validate saved unit. Disable persistence and fully reboot.'; return 1; }
        log "Stopping only $UNIT before removing its executable overlay."
        systemctl --no-block stop "$UNIT" || { log 'Service stop request failed.'; return 1; }
        wait_stopped || { log 'Service did not stop. No forced kill/unmount attempted; fully reboot.'; return 1; }
        _stopped=1
        umount "$TARGET" || { log 'Unmount failed. Service left stopped; fully reboot. No forced/lazy unmount used.'; return 1; }
    fi
    [ "$(hash_file "$TARGET")" = "$ORIGINAL_SHA" ] || {
        log 'Underlying executable has an unexpected hash; will not start an unknown image.'; return 1;
    }
    rm -f "$ROOT/mounted-inode"
    if find_daemon && [ "$(hash_file "$PROC/$PID/exe")" = "$ORIGINAL_SHA" ]; then
        log "Original daemon is running (PID $PID)."; return 0
    fi
    load_recovery_unit || { log 'Cannot validate saved unit. A full reboot restores the unmounted original.'; return 1; }
    if [ "$_stopped" = 1 ]; then
        systemctl --no-block start "$UNIT" || { log 'Original service start request failed.'; return 1; }
    else
        systemctl --no-block restart "$UNIT" || { log 'Original service restart request failed.'; return 1; }
    fi
    wait_healthy "$ORIGINAL_SHA" || { log 'Original did not pass startup observation; reboot and inspect logs.'; return 1; }
    log "Original daemon restored and running (PID $PID)."
}
finish() {
    _rc=$?
    trap - EXIT HUP INT TERM
    if [ "$IN_TRANSITION" = 1 ]; then
        log 'Apply did not complete: disarming persistence and attempting stock rollback.'
        disarm || log 'WARNING: could not fully remove persistence; inspect the boot hook.'
        restore_stock || log 'Recovery incomplete: perform a full reboot; do not rewrite system partitions.'
        _rc=1
    fi
    exit "$_rc"
}
preflight() {
    verify_payload
    verify_target
    detect_unit
    check_restart_policy
    say "unit=$UNIT"
    say "pid=$PID"
    say "system_executable_sha256=$(hash_file "$TARGET")"
    say "running_image_sha256=$(hash_file "$PROC/$PID/exe")"
    say "payload_sha256=$PATCH_SHA"
    say "exact_file_overlay_count=$(mount_count)"
    say 'Preflight passed. No service has been restarted.'
}
apply_patch() {
    preflight
    save_unit
    IN_TRANSITION=1
    if [ "$(mount_count)" = 0 ]; then
        mount --bind "$PATCH" "$TARGET" || fail 'Bind mount failed.'
        inode_id "$TARGET" >"$ROOT/mounted-inode" || fail 'Cannot record mount identity.'
    fi
    our_mount && [ "$(hash_file "$TARGET")" = "$PATCH_SHA" ] || fail 'Overlay verification failed.'
    if [ "$(hash_file "$PROC/$PID/exe")" != "$PATCH_SHA" ]; then
        log "Restarting only $UNIT to load the patched image. tvpowerd is NOT restarted."
        systemctl --no-block restart "$UNIT" || fail 'Service restart request failed.'
    fi
    wait_healthy "$PATCH_SHA" || fail 'Patched daemon did not pass startup observation.'
    IN_TRANSITION=0
    printf '%s\n' "$PATCH_SHA" >"$ROOT/trial-started" || fail 'Cannot record trial startup.'
    log "Patched daemon running (PID $PID). Startup check passed; timer behavior is NOT yet verified."
}
status() {
    say "system_executable_sha256=$(hash_file "$TARGET")"
    say "exact_file_overlay_count=$(mount_count)"
    if our_mount; then say 'overlay=ours'; else say 'overlay=not_ours_or_absent'; fi
    if [ -f "$ROOT/enabled" ] && [ -L "$HOOK" ] && [ "$(readlink "$HOOK")" = "$ROOT/boot-hook.sh" ]; then
        say 'boot_reapply=enabled'
    elif [ -f "$ROOT/enabled" ]; then
        say 'boot_reapply=marker_present_but_hook_missing_or_different'
    else say 'boot_reapply=disabled'; fi
    if find_daemon; then
        say "pid=$PID"
        say "running_image_sha256=$(hash_file "$PROC/$PID/exe")"
    else say 'running_image=not_identified'; fi
    if load_recovery_unit; then
        say "unit=$UNIT"
        say "unit_state=$(prop ActiveState)/$(prop SubState)"
    fi
}
usage() {
    cat <<'EOF'
Usage: sh sleepfixctl.sh check|status|logs
       sh sleepfixctl.sh test --timers-off
       sh sleepfixctl.sh enable --tested --timers-off
       sh sleepfixctl.sh rollback
       sh sleepfixctl.sh disable

check/status are diagnostic. test is temporary until a full reboot.
--timers-off acknowledges there are no active sleep timers, recordings,
  or imminent scheduled TV events; restarting the agent may reset them.
--tested acknowledges YOU observed no warning wake AND normal timed shutdown.
rollback/disable remove our boot hook, unmount our override, and restart stock.
No operation copies bytes into /usr/sbin/tv-reservation-agent.
EOF
}

require_root
require_tools
ACTION=${1:-help}
case "$ACTION" in
    help|-h|--help) usage; exit 0;;
    logs) tail -n 100 "$LOG" 2>/dev/null; exit 0;;
    status) status; exit 0;;
    check) preflight; exit 0;;
    test)
        [ "${2:-}" = --timers-off ] || fail 'Cancel active timers/recordings first, then pass --timers-off.'
        [ ! -f "$ROOT/enabled" ] || fail 'Persistent mode is enabled. Use rollback before starting a fresh temporary test.' ;;
    enable)
        [ "${2:-}" = --tested ] && [ "${3:-}" = --timers-off ] ||
            fail 'After a successful real-TV test, use: enable --tested --timers-off'
        [ "$(cat "$ROOT/trial-started" 2>/dev/null)" = "$PATCH_SHA" ] ||
            fail 'No successful trial startup recorded. Run test first.' ;;
    rollback|disable) ;;
    boot)
        [ "$(cat "$ROOT/enabled" 2>/dev/null)" = "$PATCH_SHA" ] || exit 0
        trap '' HUP
        sleep 5 ;;
    *) usage; exit 2;;
esac
lock_changes
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[ "$ACTION" = boot ] || trap 'exit 129' HUP
case "$ACTION" in
    test)
        apply_patch
        log 'Temporary test only. No boot hook installed. Set a NEW two-minute sleep timer now.' ;;
    enable)
        if [ -e "$HOOK" ] || [ -L "$HOOK" ]; then
            [ -L "$HOOK" ] && [ "$(readlink "$HOOK")" = "$ROOT/boot-hook.sh" ] || fail 'Boot hook name already used by another file.'
        fi
        apply_patch
        mkdir -p "${HOOK%/*}" || fail 'Cannot create hook directory.'
        printf '%s\n' "$PATCH_SHA" >"$ROOT/enabled" || fail 'Cannot write enable marker.'
        ln -sf "$ROOT/boot-hook.sh" "$HOOK" || { rm -f "$ROOT/enabled"; fail 'Cannot install boot hook.'; }
        log 'Boot reapply enabled after your confirmation. Keep rollback command accessible.' ;;
    boot)
        # A failed boot attempt is disarmed so it is not retried every boot.
        IN_TRANSITION=1
        apply_patch
        log 'Boot reapply completed.' ;;
    rollback|disable)
        disarm || fail 'Could not remove owned boot hook.'
        restore_stock || fail 'Rollback incomplete. See messages above; full reboot is the fallback.'
        rm -f "$ROOT/trial-started"
        log 'SleepFix disabled. No boot reapply remains.' ;;
esac
