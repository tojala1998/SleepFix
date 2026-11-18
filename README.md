# LGFixes — standalone LG C1 webOS patches

Two small, reversible **root SSH fixes** for a rooted LG C1 running webOS 6. Tested on one LG C1 reporting firmware **03.53.45**. They address different problems and can be installed independently.

| Fix | What it does | Verified scope |
| --- | --- | --- |
| [SleepFix 1.0.0](lgc1-sleepfix-1.0.0/README.md) | Stops the native sleep timer's one-minute warning from explicitly waking the OLED panel while Screen Off is enabled. Leaves the warning and timer expiry/shutdown paths intact. | Exact supported `/usr/sbin/tv-reservation-agent` SHA-256 only; physically tested on one C1. |
| [Clean Wake 1.2](lgc1-clean-wake/README.txt) | Suppresses the plain app-name / Loading text while waking directly to YouTube, Netflix, Prime Video, or Disney+. Uses the existing black CoverUI background. | Tested on one C1. Not a power-management or app-loading speed tweak. |

**Source only.** This repository contains no LG proprietary executables or QML, no GUI app or IPK, and no Homebrew Store submission. Each installer works from the TV's own verified files, uses reversible bind mounts over the runtime path, and stores its changes under `/var/lib/webosbrew/`. **Neither fix writes to protected firmware partitions.**

## Requirements

- Rooted LG C1 with root SSH access and Homebrew Channel startup hooks for optional persistence.
- Windows PowerShell with `scp`/`ssh` (or another SSH/SCP client).
- SleepFix: the **exact** audited 953,888-byte LG reservation-agent binary, identified by its full SHA-256, not merely model or firmware version. Installer refuses unknown hashes.
- Clean Wake: the expected `StartUpUI.qml` structure and `/usr/bin/node` on the TV. Patch builder refuses unexpected layouts or foreign overlays.

These are narrowly tested changes, not universal firmware patches. **Do not overwrite system partitions or force-unmount unknown overlays.** Keep an SSH connection available for diagnostics and rollback.

## Get the source and transfer to the TV

Choose **Code → Download ZIP** on this GitHub repository and extract it, or clone the repo. From **local Windows PowerShell** (replace the local folder and `TV_IP` as needed):

```powershell
# From the directory where you extracted or cloned this repository:
scp -r .\lgc1-clean-wake root@TV_IP:/tmp/
scp -r .\lgc1-sleepfix-1.0.0 root@TV_IP:/tmp/
ssh root@TV_IP
```

Run **only the fix you want**. Commands below run at the **TV's root SSH prompt**, not in Windows PowerShell.

## Clean Wake — install, test, persist

```sh
sh /tmp/lgc1-clean-wake/splashctl.sh install
sh /var/lib/webosbrew/lgc1-branded-wake-splash/splashctl.sh apply
sh /var/lib/webosbrew/lgc1-branded-wake-splash/splashctl.sh status
```

Put the TV in standby and wake it via the YouTube shortcut. The screen should stay black until the app appears. The original app lifecycle, hotkey mapping and power behavior are unchanged. Persistence is **off by default**; enable it only after visually confirming it works:

```sh
sh /var/lib/webosbrew/lgc1-branded-wake-splash/splashctl.sh enable-boot
```

A full reboot may be needed to clear an earlier loaded CoverUI component. **Rollback:**

```sh
sh /var/lib/webosbrew/lgc1-branded-wake-splash/splashctl.sh rollback
```

The Clean Wake 1.2 installer recognizes and migrates older v1.0/v1.1 controllers at the same install path. If it refuses an overlay, stop and inspect rather than forcing it.

## SleepFix — stage, test, persist

First, **cancel any active sleep timers** and avoid recordings or imminent scheduled TV events: restarting the reservation agent can reset them.

```sh
sh /tmp/lgc1-sleepfix-1.0.0/install.sh
sh /var/lib/webosbrew/lgc1-sleepfix/sleepfixctl.sh check
```

Staging builds the four-byte patch from the **owner's TV** and verifies both original and patched checksums. Staging alone does not change a mount, restart a daemon, or install a boot hook. The exact supported original is SHA-256 `6bee2e9fbe9836addede0a3f2e33342fb1914ff5f1793d2bffa030bfc0e38330`.

To run a temporary test:

```sh
sh /var/lib/webosbrew/lgc1-sleepfix/sleepfixctl.sh test --timers-off
sh /var/lib/webosbrew/lgc1-sleepfix/sleepfixctl.sh status
```

With media playing, set a **new** two-minute native sleep timer and select LG's **Screen Off**. Verify the warning does not light up the OLED, audio continues, and the timer still powers down the TV. `--timers-off` acknowledges that you manually cleared timers; it does not cancel them for you.

**Only after the real-TV test succeeds**, enable automatic reapply after full boots:

```sh
sh /var/lib/webosbrew/lgc1-sleepfix/sleepfixctl.sh enable --tested --timers-off
```

Then reboot and re-check status and timer behavior. The installer refuses an existing installation rather than replacing an executable that could be in use. **Rollback:**

```sh
sh /var/lib/webosbrew/lgc1-sleepfix/sleepfixctl.sh rollback
```

The rollback disables the owned startup hook, unmounts the verified override and reloads the stock agent. Do **not** delete staged files while the override may still be mounted. A full reboot generally clears temporary mounts, but is not a guaranteed recovery path.

## Source and testing

- The original Clean Wake **1.2** patch generator and `splashctl.sh` are preserved from the on-TV-tested package.
- The original SleepFix **1.0.0** controller and boot hook are preserved; for public, source-only distribution, `install.sh` now builds the same verified payload from the TV instead of shipping LG binaries.
- Offline checks verify shell syntax, builder rejection of wrong input, and that the generated binary is byte-for-byte identical to the original tested four-byte patch. Offline checks cannot validate behavior on every TV or firmware.
- The [SleepFix technical analysis](lgc1-sleepfix-1.0.0/ANALYSIS.md) and [patch manifest](lgc1-sleepfix-1.0.0/manifest.json) identify the precise patch scope and target hashes.

**Use at your own risk.** These independent projects are unaffiliated with LG or the webOS Homebrew Store.
