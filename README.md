# SleepFix for webOS

A small Homebrew app that keeps a supported LG TV's sleep-timer warning from
requesting Screen On while audio continues with **Screen Off** enabled.

**Version 0.1.0 is a first GUI test build.** The underlying four-byte patch and
its automatic boot application were tested on Tyler's LG C1. The new IPK's
installation, remote control, and Homebrew Channel integration still need a
physical-TV test before this app is submitted to the store.

## Controls

| Control | Result |
| --- | --- |
| SleepFix enabled | Applies or removes the fix for the current session. |
| Start service | Generates the verified patch if necessary, applies its overlay, and loads it. Also adopts a recognized existing SSH boot setup. |
| Stop service | Removes the overlay and restores the original LG timer service. The launch-at-boot preference stays unchanged. |
| Running status | Checks the mounted file, running executable hash, and systemd service state. It does not infer success from a saved preference. |
| Launch at boot | Silently reapplies the fix on future full boots through Homebrew Channel. Changing this setting does not immediately start or stop the fix. |

The main switch and Start/Stop buttons operate the same fix. There is no extra
resident SleepFix daemon: the app controls the existing reservation agent.
The native sleep timer and final power-off remain available.

## Requirements and scope

- Rooted TV with Homebrew Channel root access. Integration targets its 0.7.3
  `/exec` interface.
- The **exact** `tv-reservation-agent` build tested on an LG C1 with reported
  firmware **03.53.45**. This is not a promise that every C1 or webOS 6 build
  is supported.
- A root command context in the same mount namespace as PID 1. The app refuses
  service mutations in a separate namespace; root SSH can be used instead.
- Standard tools already used by the original controller, including `flock`,
  `sha256sum`, `systemctl`, `mount`, `umount`, `dd`, and `od`.

Compatibility is authorized by the complete original SHA-256:

```text
6bee2e9fbe9836addede0a3f2e33342fb1914ff5f1793d2bffa030bfc0e38330
```

The expected patched SHA-256 is:

```text
23bb2fe19594d1b42d4dfdbcf3d40b675f225ac15990b9d2a5cb2c0b571cd40f
```

The IPK and this source tree contain no LG executable. The app copies and
patches the TV's own verified executable in writable storage. It does not
write to the system executable or flash partitions. No network connection is
needed while using the app, and the app sends no telemetry.

## Install over SSH from Windows

Download `io.github.tojala1998.sleepfix_0.1.0_all.ipk`, then run in PowerShell.
Replace `TV_IP` with your TV's local IP address:

```powershell
New-Item -ItemType Directory -Force "C:\Tools\LG-C1\SleepFix" | Out-Null
Copy-Item "$env:USERPROFILE\Downloads\io.github.tojala1998.sleepfix_0.1.0_all.ipk" "C:\Tools\LG-C1\SleepFix\"
scp "C:\Tools\LG-C1\SleepFix\io.github.tojala1998.sleepfix_0.1.0_all.ipk" root@TV_IP:/tmp/
ssh root@TV_IP
```

At the TV's `root@LGwebOSTV` prompt:

```sh
luna-send -i -f 'luna://com.webos.appInstallService/dev/install' '{"id":"com.ares.defaultName","ipkUrl":"/tmp/io.github.tojala1998.sleepfix_0.1.0_all.ipk","subscribe":true}'
```

Wait for the installer to report `SUCCESS` or `installed`. If the subscription
keeps the terminal occupied, press **Ctrl+C after that success response**.
Then launch:

```sh
luna-send -n 1 'luna://com.webos.service.applicationManager/launch' '{"id":"io.github.tojala1998.sleepfix"}'
```

Installing or opening the app reads status; it does not automatically restart
the timer service. Turn off active sleep timers and recordings before using
Start or Stop; restarting the reservation agent can reset pending events.
The UI asks for this confirmation when a restart is needed.

The installation method is documented in the
[webOSBrew command reference](https://www.webosbrew.org/pages/commands-cheatsheet.html).
Do not reinstall the official LG Developer Mode app for this workflow.

## Existing standalone SleepFix 1.0.0 installation

The app recognizes the existing state at:

```text
/var/lib/webosbrew/lgc1-sleepfix
```

It reuses the known, hash-checked payload and original reference. After first
launch, select **Start service once**, even if the readout already says
Running. An already-correct patched process is not restarted; the controller
verifies it and changes the existing boot symlink to point into this app.

Until that adoption, the older standalone installation remains independently
configured. The UI labels it as an existing SSH setup. The new controller
does not delete the old installer, documentation, or reference files.

After adoption, use this app or its packaged controller for changes. The old
standalone controller does not recognize the new app-owned hook target.

## SSH status and recovery

Read status:

```sh
sh /media/developer/apps/usr/palm/applications/io.github.tojala1998.sleepfix/bin/sleepfixctl.sh status
```

Apply or stop for the current session, after cancelling timers/recordings:

```sh
sh /media/developer/apps/usr/palm/applications/io.github.tojala1998.sleepfix/bin/sleepfixctl.sh start --timers-off
sh /media/developer/apps/usr/palm/applications/io.github.tojala1998.sleepfix/bin/sleepfixctl.sh stop --timers-off
```

Choose one command; do not run both as a setup sequence.

To disable startup and restore the original service together:

```sh
sh /media/developer/apps/usr/palm/applications/io.github.tojala1998.sleepfix/bin/sleepfixctl.sh rollback
```

Logs:

```sh
tail -n 80 /var/lib/webosbrew/lgc1-sleepfix/deploy.log
tail -n 60 /var/lib/webosbrew/lgc1-sleepfix/boot-output.log
```

SSH can become available before Homebrew's startup scripts finish. A brief
stock-running state after a reboot is expected; wait for the running patched
hash and owned overlay rather than treating the boot preference as success.

## Removal

In the app, turn **Launch at boot off**, then **Stop service**. Remove SleepFix
normally from the TV's app list.

The boot hook is a symlink into the app. Once the app has adopted the hook,
removing the app makes that hook unusable. An already-running overlay can
remain active until stopped or until a full reboot. Writable state and logs
are retained; they are not an independently executing startup mechanism.

If the app was removed while running, a full reboot removes the temporary
overlay. Do not try to rewrite `/usr/sbin/tv-reservation-agent`.

## Build and test

Run the complete build and test workflow on Linux or in WSL with Node.js 20
or newer, Python 3, and dash. The TV itself needs neither Node dependencies
nor Python for this app.

```sh
npm ci --ignore-scripts
npm run check
python3 -m unittest discover -s tests -v
node tests/test_ui.js
npm run build
```

Native Windows can use the installation instructions above. The controller
test harness requires Unix facilities such as `fcntl` and `/bin/dash`.
The build uses pinned official `@webos-tools/cli` 3.2.6. Outputs are placed in
`dist/`: IPK, release manifest, and checksum. Application scripts are kept
readable. The LG CLI may print its newer `requiredACG` advisory; this app uses
Homebrew Channel's root-public service interface on the targeted rooted TV.

Controller tests use synthetic data, mocked services, and mock mounts in a
temporary directory. They never control a development machine's actual
systemd services. There are no environment-variable bypasses in the production
controller. UI tests use a simulated DOM and native bridge; see
[validation](docs/VALIDATION.md) for their limits and the TV test list.

Open `app/index.html?preview=1` in a browser for an explicitly labeled mock
preview. Opening it without that query shows that the TV bridge is missing.
Preview mode never calls Homebrew Channel.

## Store submission

The target is [webosbrew/apps-repo](https://github.com/webosbrew/apps-repo).
Source is available at [tojala1998/SleepFix](https://github.com/tojala1998/SleepFix).
Prepared store-registration files are in `submission/`. The application has
not yet been submitted to `webosbrew/apps-repo`.

Before filing the PR: complete the physical-TV GUI tests, have a human
developer review the generated code, publish a release, and
verify the public IPK/manifest/icon links. Record AI assistance honestly.
The store's [publishing rules](https://www.webosbrew.org/develop/guides/publishing/rules/)
require human review/testing and a real TV test. The earlier shell-patch test
does not substitute for testing this GUI package.

Our own code is MIT-licensed. Homebrew Channel and LG's CLI are separate
projects; their source and libraries are not bundled in the installed app.
