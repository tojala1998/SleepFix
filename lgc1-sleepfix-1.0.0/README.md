# LG C1 SleepFix 1.0.0 — standalone SSH patch

Suppress the native sleep-timer warning's explicit **Screen On** request while keeping the warning and eventual sleep shutdown in the audited `tv-reservation-agent` build. Tested on one rooted LG C1 (reported 03.53.45 / webOS 6). **Not a general LG firmware patch.**

No LG binaries are redistributed. `install.sh` copies your TV's own executable to private writable storage, makes the same four-byte NOP patch, and verifies the entire patched SHA-256 before staging. It never writes the firmware binary.

Supported stock SHA-256: `6bee2e9fbe9836addede0a3f2e33342fb1914ff5f1793d2bffa030bfc0e38330`  
Expected patched SHA-256: `23bb2fe19594d1b42d4dfdbcf3d40b675f225ac15990b9d2a5cb2c0b571cd40f`

## Install from Windows PowerShell

Download the repository ZIP using GitHub **Code → Download ZIP** or clone the repository. From the repository directory in local PowerShell:

```powershell
scp -r ".\lgc1-sleepfix-1.0.0" root@TV_IP:/tmp/
ssh root@TV_IP
```

On the TV, cancel active timers and make sure nothing is recording or scheduled to record imminently. At the `root@LGwebOSTV` shell:

```sh
sh /tmp/lgc1-sleepfix-1.0.0/install.sh
sh /var/lib/webosbrew/lgc1-sleepfix/sleepfixctl.sh check
```

If the hash, systemd unit, or mount checks fail, **stop**. Do not bypass them. Staging does not apply the patch, restart the agent, or enable boot reapply.

## Apply and test

```sh
sh /var/lib/webosbrew/lgc1-sleepfix/sleepfixctl.sh test --timers-off
sh /var/lib/webosbrew/lgc1-sleepfix/sleepfixctl.sh status
```

`--timers-off` is an acknowledgement that you manually canceled timers and avoided recordings, **not** a command that cancels them. With a video playing, set a new two-minute native sleep timer and choose **Screen Off**. Verify that sound continues, the one-minute warning does not wake the panel, and the TV still shuts down at expiry. Check normal remote behavior and the warning with the panel on as well.

**After this physical-TV test passes**, enable persistence:

```sh
sh /var/lib/webosbrew/lgc1-sleepfix/sleepfixctl.sh enable --tested --timers-off
```

The owned Homebrew startup symlink `/var/lib/webosbrew/init.d/99-lgc1-sleepfix` re-applies after full boots. Run `status` and repeat the functional test after reboot. Standby is not the same as a full reboot.

## Rollback / disable

```sh
sh /var/lib/webosbrew/lgc1-sleepfix/sleepfixctl.sh rollback
```

This disables persistence, verifies mount ownership, restores the original executable view, and restarts only the validated agent unit. It never writes `/usr/sbin/tv-reservation-agent`. Do not delete the install folder while its patch may be mounted. A full reboot can clear a temporary bind mount if normal rollback is impossible, but is not a guaranteed recovery mechanism.

Read-only diagnostics:

```sh
sh /var/lib/webosbrew/lgc1-sleepfix/sleepfixctl.sh status
sh /var/lib/webosbrew/lgc1-sleepfix/sleepfixctl.sh logs
sh /var/lib/webosbrew/lgc1-sleepfix/collect-diagnostics.sh
```

The source package includes the original tested 1.0.0 controller, boot hook, reproducible Python reference patcher, manifest, and shell build helper. No GUI app or Homebrew Store integration is included. Do not overwrite kernel, ROOTFS, TVSERVICE, or any protected system partition.
