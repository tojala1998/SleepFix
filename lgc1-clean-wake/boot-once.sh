#!/bin/sh
# Non-persistent one-shot test, self-removes the hook before applying.
HOOK='/var/lib/webosbrew/init.d/55-lgc1-branded-wake-splash-once'
if [ -L "$HOOK" ] && [ "$(readlink "$HOOK")" = '/var/lib/webosbrew/lgc1-branded-wake-splash/boot-once.sh' ]; then
  rm "$HOOK"
fi
[ -x /var/lib/webosbrew/lgc1-branded-wake-splash/splashctl.sh ] || exit 0
/var/lib/webosbrew/lgc1-branded-wake-splash/splashctl.sh apply > /tmp/lgc1-clean-wake-boot-once.log 2>&1 || true
exit 0
