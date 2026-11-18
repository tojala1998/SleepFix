LG C1 Clean Wake 1.2
====================

Purpose
-------
When the C1 is woken through a YouTube, Netflix, Prime Video, or Disney+ app
button, suppress the plain app title / Loading text without adding any
new graphics. The OLED panel stays ON and displays CoverUI's existing black
background until the app is ready. Other wake destinations retain LG's text.

This is NOT a power-management change. It does not make the app load faster in
any meaningful way, alter noSplash, skip CoverUI, change fade timings, or
change the app hotkey mappings.

No LG proprietary QML is included. The installer constructs a modified
copy from your own TV's StartUpUI.qml, stores it on writable webOS Homebrew
storage, and bind-mounts that ONE file over the runtime QML path. Protected
system partitions are not written or modified.

From Windows PowerShell (GitHub repository checked out or ZIP extracted):
-----------------------------------------------------------------------------
# Run from the LGFixes repository directory:
scp -r ".\lgc1-clean-wake" root@TV_IP:/tmp/
ssh root@TV_IP

From the TV's root SSH shell:
-----------------------------
sh /tmp/lgc1-clean-wake/splashctl.sh install
sh /var/lib/webosbrew/lgc1-branded-wake-splash/splashctl.sh apply
sh /var/lib/webosbrew/lgc1-branded-wake-splash/splashctl.sh status

The install step automatically calls the existing v1.0/v1.1 controller to
safely disable boot persistence and rollback its overlay before upgrading.
If any check fails, stop and inspect output; do not force unmounts.

Test in standby and press the remapped YouTube button. The display should
be black during CoverUI and then show YouTube. If no change appears, capture
status BEFORE rolling back. Boot persistence is OFF by default.

Rollback:
sh /var/lib/webosbrew/lgc1-branded-wake-splash/splashctl.sh rollback

After a successful test, OPTIONAL persistence:
sh /var/lib/webosbrew/lgc1-branded-wake-splash/splashctl.sh enable-boot

Full TV reboots naturally clear any nonpersistent bind mounts.

Works only when installed root QML has the expected structure. Stop if
firmware paths, mounted owner, or saved SHA checks don't match.
