#!/bin/sh
# Auto-reapply only if explicitly enabled by the TV owner.
[ -x /var/lib/webosbrew/lgc1-branded-wake-splash/splashctl.sh ] || exit 0
/var/lib/webosbrew/lgc1-branded-wake-splash/splashctl.sh apply > /tmp/lgc1-clean-wake-boot.log 2>&1 || true
exit 0
