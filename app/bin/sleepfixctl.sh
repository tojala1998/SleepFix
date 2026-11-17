#!/bin/sh
# SleepFix app controller 0.1.0. SPDX-License-Identifier: MIT
# Only a bind mount is used. This script NEVER writes to TARGET.
# A matching process image + validated systemd unit are required before restart.
set -u
unset LD_PRELOAD
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
APP=/media/developer/apps/usr/palm/applications/io.github.tojala1998.sleepfix
ROOT=/var/lib/webosbrew/lgc1-sleepfix
PROC=/proc
HOST_TARGET=/proc/1/root/usr/sbin/tv-reservation-agent
HOST_MOUNTS=/proc/1/mountinfo
TARGET=/usr/sbin/tv-reservation-agent
PATCH="$ROOT/tv-reservation-agent.sleepfix"
REF="$ROOT/reference/tv-reservation-agent.original"
BOOT="$APP/bin/boot-hook.sh"
LEGACY_BOOT="$ROOT/boot-hook.sh"
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
    validate_state_paths
}
require_tools() {
    for _cmd in sha256sum awk sed grep stat readlink flock systemctl mount umount sleep date dd od cp chmod mv mkdir head tail tr wc id; do
        command -v "$_cmd" >/dev/null 2>&1 || fail "Required command unavailable: $_cmd"
    done
}
lock_changes() {
    [ ! -L "$LOCK" ] || fail 'Operation lock must not be a symlink.'
    if [ ! -e "$LOCK" ]; then
        ( set -C; : >"$LOCK" ) 2>/dev/null || fail 'Cannot create operation lock.'
    fi
    [ -f "$LOCK" ] && [ ! -L "$LOCK" ] &&
        [ "$(stat -Lc '%u' "$LOCK")" = 0 ] &&
        [ "$(stat -Lc '%h' "$LOCK")" = 1 ] || fail 'Operation lock has unexpected type or ownership.'
    exec 9<>"$LOCK" || fail 'Cannot open operation lock.'
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
    [ "$(prop RefuseManualStop)" != yes ] || { log 'Unit refuses manual stop/restart.'; return 1; }
    _onfailure=$(prop OnFailure)
    [ -z "$_onfailure" ] || { log "Unit has OnFailure handlers ($_onfailure); review before restarting."; return 1; }
    for _p in FailureAction StartLimitAction; do
        _v=$(prop "$_p")
        case "$_v" in ''|none) ;; *) log "Unit $_p=$_v could affect the TV; refusing restart."; return 1;; esac
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
    if owned_hook; then
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
    same_mount_namespace || { log 'Separate mount namespace; use root SSH to restore SleepFix.'; return 1; }
    verify_host_view || { log 'System mount view differs; restore refused before stopping any service.'; return 1; }
    _count=$(mount_count)
    _stopped=0
    if [ "$_count" != 0 ]; then
        our_mount || { log 'Rollback refused: executable overlay is not identifiable as ours.'; return 1; }
        load_recovery_unit || { log 'Cannot validate saved unit. Disable persistence and fully reboot.'; return 1; }
        check_restart_policy || return 1
        log "Stopping only $UNIT before removing its executable overlay."
        systemctl --no-block stop "$UNIT" || { log 'Service stop request failed.'; return 1; }
        wait_stopped || { log 'Service did not stop. No forced kill/unmount attempted; fully reboot.'; return 1; }
        _stopped=1
        umount "$TARGET" || { log 'Unmount failed. Service left stopped; fully reboot. No forced/lazy unmount used.'; return 1; }
    fi
    [ "$(hash_file "$TARGET")" = "$ORIGINAL_SHA" ] || {
        log 'Underlying executable has an unexpected hash; will not start an unknown image.'; return 1;
    }
    verify_host_view || { log 'System still sees a different image; no service will be started. Reboot to restore stock.'; return 1; }
    [ "$(hash_file "$HOST_TARGET")" = "$ORIGINAL_SHA" ] || {
        log 'System view is not the original executable; no unknown image will be started.'; return 1;
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
    same_mount_namespace || fail 'Separate mount namespace; use root SSH to control SleepFix.'
    verify_host_view || fail 'Cannot verify system executable visibility.'
    detect_unit
    check_restart_policy || fail 'Service restart policy is not compatible.'
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
        if ! host_sees_overlay; then
            log 'The TV system cannot see this mount; no daemon restart was requested.'
            if umount "$TARGET"; then
                rm -f "$ROOT/mounted-inode"
                IN_TRANSITION=0
            fi
            fail 'Mount isolation detected. Use the documented root SSH command instead.'
        fi
    fi
    our_mount && [ "$(hash_file "$TARGET")" = "$PATCH_SHA" ] || fail 'Overlay verification failed.'
    if [ "$(hash_file "$PROC/$PID/exe")" != "$PATCH_SHA" ]; then
        log "Restarting only $UNIT to load the patched image. tvpowerd is NOT restarted."
        systemctl --no-block restart "$UNIT" || fail 'Service restart request failed.'
    fi
    wait_healthy "$PATCH_SHA" || fail 'Patched daemon did not pass startup observation.'
    IN_TRANSITION=0
    printf '%s\n' "$PATCH_SHA" >"$ROOT/trial-started" || fail 'Cannot record trial startup.'
    log "SleepFix is running (PID $PID); executable and service startup verified."
}
validate_state_paths() {
    if [ -d "$ROOT" ]; then
        [ "$(stat -Lc '%u' "$ROOT")" = 0 ] || fail 'State directory is not root-owned.'
    fi
    for _state_path in reference reference/tv-reservation-agent.original tv-reservation-agent.sleepfix unit unit.tmp unit-info.txt mounted-inode enabled enabled.tmp trial-started deploy.log boot-output.log; do
        [ ! -L "$ROOT/$_state_path" ] || fail "Symlink in state path: $_state_path"
    done
}
init_state() {
    mkdir -p "$ROOT/reference" || fail 'Cannot create SleepFix state directory.'
    chmod 700 "$ROOT" "$ROOT/reference" || fail 'Cannot secure state directory.'
}
owned_hook() {
    [ -L "$HOOK" ] || return 1
    _hook_link=$(readlink "$HOOK") || return 1
    [ "$_hook_link" = "$BOOT" ] || [ "$_hook_link" = "$LEGACY_BOOT" ]
}
check_hook_name() {
    if [ -e "$HOOK" ] || [ -L "$HOOK" ]; then
        owned_hook || fail 'Another file owns the SleepFix startup hook name.'
    fi
}
boot_wanted() { [ "$(cat "$ROOT/enabled" 2>/dev/null)" = "$PATCH_SHA" ]; }
install_hook() {
    check_hook_name
    [ -f "$BOOT" ] && [ -x "$BOOT" ] || fail 'Packaged startup script is missing or not executable.'
    [ -f "$APP/bin/sleepfixctl.sh" ] || fail 'Packaged controller is missing.'
    mkdir -p "${HOOK%/*}" || fail 'Cannot create startup hook directory.'
    printf '%s\n' "$PATCH_SHA" >"$ROOT/enabled.tmp" && mv "$ROOT/enabled.tmp" "$ROOT/enabled" || fail 'Cannot save boot setting.'
    _new_hook="$HOOK.pending.$$"
    ln -s "$BOOT" "$_new_hook" || fail 'Cannot stage startup hook.'
    mv -f "$_new_hook" "$HOOK" || { rm -f "$_new_hook"; fail 'Cannot install startup hook.'; }
}
same_mount_namespace() {
    _self_ns=$(readlink "$PROC/self/ns/mnt" 2>/dev/null) || return 1
    _init_ns=$(readlink "$PROC/1/ns/mnt" 2>/dev/null) || return 1
    [ -n "$_self_ns" ] && [ "$_self_ns" = "$_init_ns" ]
}
verify_host_view() {
    [ -r "$HOST_MOUNTS" ] && [ -f "$HOST_TARGET" ] || return 1
    [ "$(inode_id "$TARGET")" = "$(inode_id "$HOST_TARGET")" ]
}
host_sees_overlay() {
    [ "$(inode_id "$HOST_TARGET")" = "$(inode_id "$PATCH")" ] &&
    [ "$(hash_file "$HOST_TARGET")" = "$PATCH_SHA" ] &&
    [ "$(awk -v p="$TARGET" '$5==p {n++} END {print n+0}' "$HOST_MOUNTS")" = 1 ]
}
prepare_payload() {
    # Build exclusively from the TV's own exact audited executable.
    # No proprietary executable is distributed in the IPK or source release.
    verify_target
    same_mount_namespace || fail 'Separate mount namespace; use root SSH to control SleepFix.'
    verify_host_view || fail 'Cannot verify the TV system executable view.'
    init_state
    if [ -f "$PATCH" ] && [ -f "$REF" ]; then
        verify_payload
        return 0
    fi
    [ "$(mount_count)" = 0 ] || fail 'Existing mounted payload is incomplete; stop the fix before rebuilding.'
    [ "$(hash_file "$TARGET")" = "$ORIGINAL_SHA" ] || fail 'Unsupported executable; nothing will be patched.'
    _build_dir="$ROOT/build.$$"
    mkdir -m 700 "$_build_dir" || fail 'Cannot create patch build directory.'
    cp "$TARGET" "$_build_dir/original" || { rm -rf "$_build_dir"; fail 'Cannot read TV executable.'; }
    [ "$(hash_file "$_build_dir/original")" = "$ORIGINAL_SHA" ] || { rm -rf "$_build_dir"; fail 'Original changed while copying.'; }
    _old_bytes=$(dd if="$_build_dir/original" bs=1 skip=199070 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ "$_old_bytes" = 4df0bdfb ] || { rm -rf "$_build_dir"; fail 'Expected Thumb branch not found.'; }
    cp "$_build_dir/original" "$_build_dir/patched" || { rm -rf "$_build_dir"; fail 'Cannot prepare patched copy.'; }
    # 0x3099e: BL requestTurnOnScreen -> two Thumb NOP instructions.
    printf '\000\277\000\277' | dd of="$_build_dir/patched" bs=1 seek=199070 conv=notrunc 2>/dev/null || {
        rm -rf "$_build_dir"; fail 'Cannot patch writable copy.';
    }
    [ "$(hash_file "$_build_dir/patched")" = "$PATCH_SHA" ] || { rm -rf "$_build_dir"; fail 'Generated patch checksum mismatch.'; }
    chmod 400 "$_build_dir/original" && chmod 555 "$_build_dir/patched" || { rm -rf "$_build_dir"; fail 'Cannot set payload permissions.'; }
    mv "$_build_dir/original" "$REF" && mv "$_build_dir/patched" "$PATCH" || { rm -rf "$_build_dir"; fail 'Cannot store generated payload.'; }
    rmdir "$_build_dir" || :
    log 'Generated the exact supported patch from this TV; original system file was not written.'
    verify_payload
}
operation_busy() {
    [ -f "$LOCK" ] || return 1
    ( exec 8<"$LOCK" && flock -n 8 ) >/dev/null 2>&1 && return 1
    return 0
}
json_string() {
    # Input here is constrained system metadata, but escape every JSON special byte.
    printf '%s' "$1" | awk 'BEGIN {printf "\""} {
        if(NR>1) printf "\\n";
        for(i=1;i<=length($0);i++) {
            c=substr($0,i,1);
            if(c=="\\") printf "\\\\";
            else if(c=="\"") printf "\\\"";
            else if(c=="\r") printf "\\r";
            else if(c=="\t") printf "\\t";
            else printf "%s",c;
        }
    } END {printf "\""}'
}
status() {
    STATUS_TARGET=$(hash_file "$TARGET")
    STATUS_RUN=
    STATUS_COUNT=$(mount_count)
    STATUS_OVERLAY=absent
    [ "$STATUS_COUNT" = 0 ] || STATUS_OVERLAY=other
    our_mount && STATUS_OVERLAY=ours
    STATUS_PID=null
    STATUS_STATE=unknown
    STATUS_RUNNING=false
    STATUS_SUPPORTED=false
    STATUS_BOOT=false
    STATUS_HOOK=false
    STATUS_LEGACY=false
    STATUS_BUSY=false
    STATUS_CAN_START=false
    STATUS_CAN_STOP=false
    STATUS_MESSAGE='SleepFix is stopped. LG timer behavior is unchanged.'
    boot_wanted && STATUS_BOOT=true
    owned_hook && [ -x "$HOOK" ] && STATUS_HOOK=true
    if owned_hook && [ "$(readlink "$HOOK")" = "$LEGACY_BOOT" ]; then STATUS_LEGACY=true; fi
    operation_busy && STATUS_BUSY=true
    if find_daemon; then
        STATUS_PID=$PID
        STATUS_RUN=$(hash_file "$PROC/$PID/exe")
        if ! load_recovery_unit; then UNIT=tv-reservation-agent.service; fi
        if validate_unit && [ "$(prop MainPID)" = "$PID" ]; then
            STATUS_STATE="$(prop ActiveState)/$(prop SubState)"
        fi
    fi
    if [ "$STATUS_TARGET" = "$ORIGINAL_SHA" ] ||
       { [ "$STATUS_OVERLAY" = ours ] && [ "$STATUS_TARGET" = "$PATCH_SHA" ]; }; then
        STATUS_SUPPORTED=true
    fi
    if [ "$STATUS_OVERLAY" = ours ] && [ "$STATUS_RUN" = "$PATCH_SHA" ] &&
       [ "$STATUS_STATE" = active/running ]; then
        STATUS_RUNNING=true
        STATUS_MESSAGE='SleepFix is running. The sleep warning will not request Screen On.'
    elif [ "$STATUS_OVERLAY" = ours ]; then
        STATUS_MESSAGE='An overlay exists, but the patched service is not confirmed running. Stop can restore the original.'
    elif [ "$STATUS_RUN" = "$PATCH_SHA" ]; then
        STATUS_MESSAGE='The patched process is still running without its overlay. Stop will reload the original.'
    fi
    if [ "$STATUS_SUPPORTED" = true ] && [ "$STATUS_OVERLAY" != other ]; then STATUS_CAN_START=true; fi
    { [ "$STATUS_OVERLAY" = ours ] || [ "$STATUS_RUN" = "$PATCH_SHA" ]; } && STATUS_CAN_STOP=true
    if [ "$STATUS_SUPPORTED" = false ]; then STATUS_MESSAGE='This executable is not the tested version. Start is unavailable.'; fi
    if [ "$STATUS_OVERLAY" = other ]; then STATUS_MESSAGE='Another overlay occupies the timer executable. SleepFix will not replace it.'; fi
    if [ "$STATUS_BOOT" = true ] && [ "$STATUS_HOOK" = false ]; then
        STATUS_MESSAGE='Launch at boot is selected, but its startup link is missing. Toggle it off and on to repair.'
    fi
    if ! same_mount_namespace; then
        STATUS_CAN_START=false
        STATUS_CAN_STOP=false
        STATUS_MESSAGE='The root service uses a separate mount namespace. Use root SSH to control SleepFix.'
    fi
    if [ "$STATUS_BUSY" = true ]; then STATUS_MESSAGE='A SleepFix operation is in progress. Please wait.'; fi
    if [ "${ACTION:-}" = status-json ]; then
        printf '{"returnValue":true,"version":"0.1.0","root":true,"supported":%s,"running":%s,"bootEnabled":%s,"bootHookValid":%s,"legacyHook":%s,"operationInProgress":%s,"canStart":%s,"canStop":%s,"pid":%s,"overlayCount":%s,' "$STATUS_SUPPORTED" "$STATUS_RUNNING" "$STATUS_BOOT" "$STATUS_HOOK" "$STATUS_LEGACY" "$STATUS_BUSY" "$STATUS_CAN_START" "$STATUS_CAN_STOP" "$STATUS_PID" "$STATUS_COUNT"
        printf '"overlay":'; json_string "$STATUS_OVERLAY"
        printf ',"serviceState":'; json_string "$STATUS_STATE"
        printf ',"systemSha256":'; json_string "$STATUS_TARGET"
        printf ',"runningSha256":'; json_string "$STATUS_RUN"
        printf ',"message":'; json_string "$STATUS_MESSAGE"
        printf '}\n'
    else
        say "system_executable_sha256=$STATUS_TARGET"
        say "running_image_sha256=$STATUS_RUN"
        say "exact_file_overlay_count=$STATUS_COUNT"
        say "overlay=$STATUS_OVERLAY"
        say "running=$STATUS_RUNNING"
        say "boot_reapply=$STATUS_BOOT"
        say "boot_hook_valid=$STATUS_HOOK"
        say "legacy_hook=$STATUS_LEGACY"
        say "pid=$STATUS_PID"
        say "unit_state=$STATUS_STATE"
        say "operation_in_progress=$STATUS_BUSY"
        say "$STATUS_MESSAGE"
    fi
}
usage() {
    cat <<'EOF'
SleepFix 0.1.0
  status | status-json | logs | check
  start --timers-off       Apply SleepFix now; does not change boot preference.
  stop --timers-off        Restore stock timer service; keep boot preference.
  boot-on                 Apply on future full boots; does not start now.
  boot-off                Disable future boot application; does not stop now.
  rollback                Disable boot application and restore stock now.

Start/Stop refer to SleepFix. The LG timer service is left running normally.
--timers-off acknowledges active timers/recordings have been cancelled.
Only a writable copy is patched, with a reversible bind mount over its path.
EOF
}

ACTION=${1:-help}
case "$ACTION" in help|-h|--help) usage; exit 0;; esac
if [ "$(id -u)" != 0 ] && [ "$ACTION" = status-json ]; then
    say '{"returnValue":false,"root":false,"errorText":"Root access through Homebrew Channel is required."}'
    exit 0
fi
require_root
require_tools
case "$ACTION" in
    status|status-json) status; exit 0;;
    logs) tail -n 100 "$LOG" 2>/dev/null; exit 0;;
    check)
        verify_target
        same_mount_namespace || fail 'Separate mount namespace; use root SSH to control SleepFix.'
        verify_host_view || fail 'Cannot verify the TV system executable view.'
        detect_unit
        check_restart_policy || fail 'Service restart policy is not compatible.'
        say 'Supported executable and service verified; no files or services changed.'; exit 0;;
    start|stop)
        [ "${2:-}" = --timers-off ] || fail 'Cancel active timers/recordings, then pass --timers-off.';;
    boot-on|boot-off|rollback) ;;
    boot)
        boot_wanted || exit 0
        [ -f "$APP/bin/sleepfixctl.sh" ] && [ -f "$BOOT" ] || exit 0
        trap '' HUP
        sleep 5;;
    *) usage; exit 2;;
esac
lock_changes
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[ "$ACTION" = boot ] || trap 'exit 129' HUP
case "$ACTION" in
    start)
        check_hook_name
        prepare_payload
        apply_patch
        if boot_wanted; then install_hook; fi
        log 'SleepFix started. Boot preference is unchanged.';;
    stop)
        if ! restore_stock; then
            disarm || :
            fail 'Restore did not complete; automatic boot application has been disabled. See logs.'
        fi
        if boot_wanted; then install_hook; fi
        log 'SleepFix stopped; original LG timer service is running. Boot preference is unchanged.';;
    boot-on)
        prepare_payload
        preflight
        install_hook
        log 'Launch at boot enabled. Current service state is unchanged.';;
    boot-off)
        disarm || fail 'Could not remove the owned boot hook.'
        log 'Launch at boot disabled. Current service state is unchanged.';;
    boot)
        IN_TRANSITION=1
        prepare_payload
        apply_patch
        log 'Boot application completed.';;
    rollback)
        disarm || fail 'Could not remove the owned boot hook.'
        restore_stock || fail 'Restore incomplete; full reboot is the fallback.'
        log 'SleepFix stopped and launch at boot disabled.';;
esac
