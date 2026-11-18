#!/bin/sh
# Rebuilds the exact audited SleepFix executable from a copy of the owner's TV binary.
# No firmware image is bundled, and the input is NEVER modified.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH
[ "$#" = 3 ] || { echo 'Usage: build-from-tv.sh SYSTEM_ORIGINAL BACKUP_OUTPUT PATCH_OUTPUT' >&2; exit 2; }
SOURCE=$1
BACKUP=$2
PATCH=$3
ORIGINAL_SHA=6bee2e9fbe9836addede0a3f2e33342fb1914ff5f1793d2bffa030bfc0e38330
PATCH_SHA=23bb2fe19594d1b42d4dfdbcf3d40b675f225ac15990b9d2a5cb2c0b571cd40f
sha() { sha256sum "$1" | awk '{print $1}'; }
fail() { echo "ERROR: $*" >&2; exit 1; }
[ -f "$SOURCE" ] && [ ! -L "$SOURCE" ] || fail 'Input must be a regular, non-symlink file.'
[ ! -e "$BACKUP" ] && [ ! -L "$BACKUP" ] && [ ! -e "$PATCH" ] && [ ! -L "$PATCH" ] || fail 'Output already exists.'
[ "$(sha "$SOURCE")" = "$ORIGINAL_SHA" ] || fail 'Unsupported source executable SHA-256; refusing to patch.'
[ "$(wc -c < "$SOURCE" | tr -d '[:space:]')" = 953888 ] || fail 'Unexpected source size.'
cp "$SOURCE" "$BACKUP" || fail 'Failed to save original.'
[ "$(sha "$BACKUP")" = "$ORIGINAL_SHA" ] || fail 'Original changed during copy.'
cp "$BACKUP" "$PATCH" || fail 'Failed to make writable copy.'
BEFORE=$(dd if="$PATCH" bs=1 skip=199070 count=4 2>/dev/null | od -An -tx1 | tr -d '[:space:]')
[ "$BEFORE" = 4df0bdfb ] || fail 'Unexpected instruction bytes.'
printf '\000\277\000\277' | dd of="$PATCH" bs=1 seek=199070 conv=notrunc 2>/dev/null || fail 'Failed to write four bytes to staged copy.'
[ "$(sha "$PATCH")" = "$PATCH_SHA" ] || fail 'Patched SHA-256 mismatch.'
chmod 400 "$BACKUP"
chmod 555 "$PATCH"
echo 'Verified exact supported four-byte patch in writable staging copy; TV firmware untouched.'
