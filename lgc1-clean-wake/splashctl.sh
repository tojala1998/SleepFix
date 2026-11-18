#!/bin/sh
# LG C1 Clean Wake 1.2: black active CoverUI during four streaming hotkey wakes.
# Verifies source and target, uses reversible bind mount, never writes system partitions.
set -eu
BASE='/var/lib/webosbrew/lgc1-branded-wake-splash'  # Reuses v1.x controller path safely.
TARGET='/usr/lib/qml/CoverUI/StartUpUI.qml'
SOURCE='/tmp/lgc1-clean-wake'
ORIG="$BASE/original.qml"
PATCH="$BASE/patched.qml"
HOOK='/var/lib/webosbrew/init.d/55-lgc1-branded-wake-splash'
ONCE_HOOK='/var/lib/webosbrew/init.d/55-lgc1-branded-wake-splash-once'

fail() { echo "ERROR: $*" >&2; exit 1; }
sha() { sha256sum "$1" | awk '{print $1}'; }
mount_count() { awk -v p="$TARGET" '$5==p {n++} END{print n+0}' /proc/self/mountinfo; }
require_installed() {
  [ "$(id -u)" -eq 0 ] || fail 'Root SSH required.'
  [ -f "$BASE/build-patch.js" ] && [ -f "$TARGET" ] || fail 'Run install first, or this firmware has no matching target.'
  grep -q 'LGC1_CLEAN_WAKE_V1_2' "$BASE/build-patch.js" || fail 'Controller is not installed at version 1.2.'
}
check_overlay_owner() {
  N="$(mount_count)"
  [ "$N" -le 1 ] || fail "Multiple mounts on target ($N). Refusing to unmount or modify."
  if [ "$N" -eq 1 ]; then
    [ -f "$PATCH" ] || fail 'Mounted QML has no known source file.'
    [ "$(sha "$TARGET")" = "$(sha "$PATCH")" ] || fail 'Mounted QML is not this package. Refusing to interfere.'
  fi
}
remove_known_hooks() {
  if [ -L "$HOOK" ] && [ "$(readlink "$HOOK")" = "$BASE/boot.sh" ]; then
    rm "$HOOK"
  elif [ -e "$HOOK" ] || [ -L "$HOOK" ]; then
    fail 'Unknown persistent startup hook; refusing to overwrite.'
  fi
  if [ -L "$ONCE_HOOK" ] && [ "$(readlink "$ONCE_HOOK")" = "$BASE/boot-once.sh" ]; then
    rm "$ONCE_HOOK"
  elif [ -e "$ONCE_HOOK" ] || [ -L "$ONCE_HOOK" ]; then
    fail 'Unknown one-time startup hook; refusing to overwrite.'
  fi
}
install_files() {
  [ "$(id -u)" -eq 0 ] || fail 'Root SSH required.'
  [ -f "$SOURCE/build-patch.js" ] && [ -f "$SOURCE/splashctl.sh" ] || fail 'Transfer lgc1-clean-wake directory to /tmp first.'
  [ -f "$TARGET" ] || fail 'The expected system QML is not installed on this firmware.'

  # Migrate v1.0 / v1.1 safely: use the currently installed controller to
  # verify ownership and remove any existing overlay before replacing scripts.
  # Never overwrite patched.qml while it may be bind-mounted.
  if [ -f "$BASE/splashctl.sh" ]; then
    echo 'Migrating existing wake-splash version: disabling old boot hook and removing its overlay.'
    sh "$BASE/splashctl.sh" disable-boot
    sh "$BASE/splashctl.sh" rollback
    [ "$(mount_count)" -eq 0 ] || fail 'Old overlay is still mounted.'
  else
    [ "$(mount_count)" -eq 0 ] || fail 'Unknown overlay is active on startup UI.'
  fi
  remove_known_hooks
  if [ -f "$ORIG" ]; then
    [ "$(sha "$ORIG")" = "$(sha "$TARGET")" ] || fail 'Existing firmware backup does not match visible QML. No changes made.'
  else
    mkdir -p "$BASE"
    cp "$TARGET" "$ORIG"
    chmod 644 "$ORIG"
  fi
  cp "$SOURCE/build-patch.js" "$SOURCE/splashctl.sh" "$SOURCE/boot.sh" "$SOURCE/boot-once.sh" "$BASE/"
  chmod 755 "$BASE/splashctl.sh" "$BASE/boot.sh" "$BASE/boot-once.sh"
  echo 'Clean Wake 1.2 installed. Old images and diagnostics are unused; no overlay applied yet.'
}
prepare() {
  require_installed
  check_overlay_owner
  if [ "$(mount_count)" -eq 0 ]; then
    [ -f "$ORIG" ] || fail 'Missing original QML backup.'
    [ "$(sha "$ORIG")" = "$(sha "$TARGET")" ] || fail 'Installed firmware QML has changed; refusing to apply patch.'
    /usr/bin/node "$BASE/build-patch.js" "$ORIG" "$PATCH"
    chmod 644 "$PATCH"
  else
    echo 'Verified active overlay; not replacing bind-mounted source inode.'
  fi
}
apply() {
  prepare
  if [ "$(mount_count)" -eq 1 ]; then
    echo 'Clean Wake overlay already applied.'
    return
  fi
  mount --bind "$PATCH" "$TARGET" || fail 'Bind mount failed; no firmware changes made.'
  if [ "$(mount_count)" -ne 1 ] || [ "$(sha "$TARGET")" != "$(sha "$PATCH")" ]; then
    umount "$TARGET" 2>/dev/null || true
    fail 'Post-apply verification failed. Attempted rollback.'
  fi
  echo 'Clean Wake overlay active: no image, app label, diagnostic strip, or spinner added.'
}
rollback() {
  require_installed
  # Disable both boot hooks first: a reboot must not bring the patch back.
  remove_known_hooks
  check_overlay_owner
  if [ "$(mount_count)" -eq 1 ]; then
    umount "$TARGET" || fail 'Unmount failed; QML overlay may still be in use.'
  fi
  [ "$(mount_count)" -eq 0 ] || fail 'Overlay still mounted.'
  echo 'Original LG startup UI file restored. If CoverUI cached the component, it refreshes on next load.'
}
status() {
  require_installed
  N="$(mount_count)"
  echo "overlay_count=$N"
  if [ "$N" -eq 0 ]; then
    echo 'overlay=original'
  elif [ "$N" -eq 1 ] && [ -f "$PATCH" ] && [ "$(sha "$TARGET")" = "$(sha "$PATCH")" ]; then
    echo 'overlay=ours (clean black wake)'
  else
    echo 'overlay=unknown (do not unmount blindly)'
  fi
  if [ -L "$HOOK" ] && [ "$(readlink "$HOOK")" = "$BASE/boot.sh" ]; then
    echo 'boot_reapply=enabled'
  else
    echo 'boot_reapply=disabled'
  fi
  if [ -L "$ONCE_HOOK" ] && [ "$(readlink "$ONCE_HOOK")" = "$BASE/boot-once.sh" ]; then
    echo 'next_full_boot_test=armed'
  else
    echo 'next_full_boot_test=not_armed'
  fi
  echo "visible_sha256=$(sha "$TARGET")"
}
enable_boot() {
  require_installed
  check_overlay_owner
  [ "$(mount_count)" -eq 1 ] || fail 'Apply and test before enabling automatic reapply.'
  [ ! -e "$ONCE_HOOK" ] && [ ! -L "$ONCE_HOOK" ] || fail 'Cancel one-time hook first.'
  mkdir -p /var/lib/webosbrew/init.d
  if [ -e "$HOOK" ] || [ -L "$HOOK" ]; then
    [ -L "$HOOK" ] && [ "$(readlink "$HOOK")" = "$BASE/boot.sh" ] || fail 'An unknown boot hook exists.'
  else
    ln -s "$BASE/boot.sh" "$HOOK"
  fi
  echo 'Auto-reapply enabled; system power behavior unchanged.'
}
arm_once() {
  require_installed
  [ ! -e "$HOOK" ] && [ ! -L "$HOOK" ] || fail 'Disable automatic reapply before arming a one-time test.'
  prepare
  mkdir -p /var/lib/webosbrew/init.d
  if [ -e "$ONCE_HOOK" ] || [ -L "$ONCE_HOOK" ]; then
    [ -L "$ONCE_HOOK" ] && [ "$(readlink "$ONCE_HOOK")" = "$BASE/boot-once.sh" ] || fail 'An unknown one-shot hook exists.'
  else
    ln -s "$BASE/boot-once.sh" "$ONCE_HOOK"
  fi
  echo 'One-time test armed. Its boot hook automatically removes itself.'
}
disable_boot() {
  require_installed
  remove_known_hooks
  echo 'Boot hooks disabled.'
}
case "${1:-help}" in
  install) install_files ;;
  prepare) prepare ;;
  apply) apply ;;
  rollback) rollback ;;
  status) status ;;
  enable-boot) enable_boot ;;
  arm-once) arm_once ;;
  disable-boot|cancel-once) disable_boot ;;
  uninstall) rollback ; echo 'Disabled; files retained for audit.' ;;
  *) echo 'Usage: splashctl.sh {install|apply|rollback|status|arm-once|enable-boot|disable-boot|uninstall}' ;;
esac
