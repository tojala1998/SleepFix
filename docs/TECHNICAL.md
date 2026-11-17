# Implementation notes

## Scope of the fix

The reviewed `SleepTimer::_checkSleepTimer` implementation requests Screen On
when the remaining interval reaches one minute, then creates its warning
popup. The patch changes only that call site, at file offset `0x3099e`.
It replaces `4d f0 bd fb` with `00 bf 00 bf`: a Thumb-2 branch becomes two
Thumb NOP instructions. The popup and final sleep power-off path remain
unchanged. Full input/output hashes are in `profiles/c1-03.53.45.json`.

The original shell package was physically tested: Screen Off persisted through
the warning, audio continued, and the normal `sleepTimer` shutdown reached
Active Standby. The patched image was also observed running after reboot.
Those observations establish the narrow patch's behavior on one tested TV;
they do not establish this new application's UI integration or every firmware.

## Application and root boundary

The web app uses the built-in `PalmServiceBridge` to call
`luna://org.webosbrew.hbchannel.service/exec`. It sends only one of five fixed
commands: status, start, stop, boot-on, and boot-off. No user-entered text is
concatenated into a root shell command. The application has no HTTP listener,
download function, telemetry, or separate privileged Node service.

Homebrew Channel 0.7.3 supplies `stdoutString`, `stderrString`, and
`returnValue` for `/exec`. A pending service activity keeps the request alive
until the child exits. The UI retains its bridge, polls status, and treats a
lost response as unknown rather than claiming an operation has been undone.
The controller never trusts a UI status value to authorize a mutation.

Primary interface sources:

- [HBC 0.7.3 service](https://github.com/webosbrew/webos-homebrew-channel/blob/v0.7.3/services/service.ts)
- [HBC protocol](https://github.com/webosbrew/webos-homebrew-channel/blob/v0.7.3/services/protocol.ts)
- [Pinned webos-service dispatch](https://github.com/webosose/nodejs-module-webos-service/blob/1dd2c9d6cd21eb5d84f7619432ed6d2784bb56f9/lib/service.js)
- [LG native bridge sample](https://github.com/webOS-TV-app-samples/LunaService/blob/main/lib/webOSTVjs-1.2.4/webOSTV.js)

## Applying and removing

The controller validates root access, the executable hash, overlay ownership,
the actual daemon PID, and its systemd unit's executable and restart policy.
It refuses a foreign or stacked file overlay. It also requires the same mount
namespace as PID 1, and checks the actual system view of the executable.

For a fresh installation, it builds a private copy of the TV's executable,
checks the four original bytes, replaces them, then validates the entire
result against the expected patched hash. Neither binary is shipped publicly.
An existing verified payload is reused instead of rewritten.

The patched copy is bind-mounted over the system executable path. PID 1 must
see the new inode/hash before the daemon is restarted. Only the validated
`tv-reservation-agent` unit is restarted. The controller checks the running
executable hash and observes a stable service PID for eight samples.

Stop first stops the validated reservation agent, removes the owned overlay,
checks that both its own and PID 1's views show the original executable, and
starts the original service. It does not restart `tvpowerd`. It does not use
forced or lazy unmounts. A detached patched process is also treated as a
recoverable partial state rather than being reported as normal stock behavior.

Operations use a root-owned, non-truncating file lock. Failure during apply
disables automatic application and attempts restoration. Stop errors disable
automatic application and report the incomplete state. A full reboot is the
fallback when a service or mount cannot be restored normally.

## Boot and package lifecycle

The stored boot preference and current running state are independent. A user
may stop the patch now while retaining application on the next full boot.
Switching the boot setting off does not disrupt a currently running timer.

The startup registration is a symlink at
`/var/lib/webosbrew/init.d/99-lgc1-sleepfix` pointing to the boot script inside
the installed app. The hook validates that the app/controller still exist,
sets an explicit PATH, removes inherited LD_PRELOAD, and starts a detached,
bounded boot application without holding up later Homebrew startup hooks.

The original standalone package's hook target is recognized and migrated on
Start or enabling boot. Unrecognized hook files are not overwritten. The
payload, original reference, and logs remain in the existing writable state
directory so the tested standalone installation can be adopted without
altering its verified data.

The platform does not provide a dependable uninstall hook for this workflow.
Users should stop and disable the fix before uninstalling. Direct removal
after adoption prevents future boot execution because the symlink target is
gone; an already-running bind mount remains until stopped or rebooted.

See the official [publishing rules](https://www.webosbrew.org/develop/guides/publishing/rules/)
and [overlay guidance](https://github.com/webosbrew/pages/blob/main/content/pages/hacking/overlays.md).

## Extending support

Do not add a firmware by accepting a wider model name or bypassing the hash.
Review the new binary's warning call and shutdown path, define a separate
input/output hash pair and patch recipe, then test rollback, normal shutdown,
Screen Off, startup, and package lifecycle on that hardware. A failed full
hash check must remain a refusal, not a request for an unsafe force option.
