# Static analysis and deployment review — LG C1 SleepFix 1.0.0

## Result and evidence boundaries

The owner's actual `tv-reservation-agent` ELF was inspected, not substituted with
a different firmware image. The four-byte candidate was independently confirmed
by ELF parsing, symbol lookup, LLVM Thumb disassembly, manual control-flow review,
and a separate Python Thumb BL-immediate decoder. The original file is unchanged.

A patched ELF and a reversible deployment controller are included. **No connection
to the TV was made, no patch has been deployed by this analysis, and no ARM firmware
execution or complete system emulation was performed.** The final user-visible
behaviour remains an on-device acceptance test.

## Uploaded evidence

The owner's Luna trace (`Pasted text(20261117-223522).txt`) showed:

```
4062.566  com.webos.app.quicksettings -> tvpower /power/turnOffScreen
4062.523  tvpower -> panelcontroller //setScreenOnOff {"OnOff":false}
4115.002  com.webos.service.tvReservationAgent.tvpowerd -> tvpower /power/turnOnScreen {}
4115.019  tvpower -> panelcontroller //setScreenOnOff {"OnOff":true}
```

TX/RX display order is not a perfect time ordering; the two-stage sequence and
caller identity are nevertheless explicit. The roughly 52.5-second gap between
Screen Off and the later request is consistent with the owner's two-minute timer
test and one-minute warning. The other earlier voiceconductor calls were rejected
because the TV was already Active; they are not the wake event being patched.

## Binary identity

* Length: 953,888 bytes.
* ELF32, little-endian ARM, EABI5; position-independent executable.
* ELF flags: `0x5000200` (EABI5, soft-float ABI).
* Interpreter: `/lib/ld-linux.so.3`.
* Original GNU build ID: `416c53cfb66851896327541f33b80fce431884fa`.
* Stripped ELF, but useful C++ function names remain in `.dynsym`.
* Original SHA-256:
  `6bee2e9fbe9836addede0a3f2e33342fb1914ff5f1793d2bffa030bfc0e38330`.
* Patched SHA-256:
  `23bb2fe19594d1b42d4dfdbcf3d40b675f225ac15990b9d2a5cb2c0b571cd40f`.

The ELF build-ID note is intentionally unchanged to keep the edit to four bytes;
it must NOT be used to distinguish the two images. The full SHA-256 is used instead.
Function symbol values are odd because of the Thumb-state bit; instruction
addresses below are the corresponding even code addresses.

## 1. Warning branch

`SleepTimer::_checkSleepTimer(void*)` begins at `0x307cc` and spans 792 bytes
(including literal data). Near `0x307f6`, it decrements a countdown field, compares
the result with zero and another field with one, then branches to the warning
block at `0x30958`. This is consistent with the minute/second timer state and
corroborated by the explicitly named sleep-timer popup function.

The critical original sequence is:

```asm
0x30998   ldr  r3, [pc, #0x130]
0x3099a   ldr  r7, [r5, r3]
0x3099c   mov  r0, r7
0x3099e   bl   0x7e11c  ; ReservationPowerMgr::requestTurnOnScreen()
0x309a2   mov  r0, r4
0x309a4   bl   0x2fb34  ; SleepTimer::_createSleepTimerAlertPopup()
0x309a8   ldr  r3, [r4, #0x7c]
0x309aa   b    0x30804
```

The return value of the wake call is not used: r0 is explicitly overwritten with
the SleepTimer object before the alert call. There is no conditional branch based
on the removed call's flags at this site. The surrounding function preserves its
return address on the stack, and the following BL establishes its own link value.

`ReservationPowerMgr::requestTurnOnScreen()` forwards to
`TvpowerManager::requestTurnOnScreen()`. The adapter code contains the exact URI
`luna://com.webos.service.tvpower/power/turnOnScreen`, matching the captured trace.

## 2. Patch

At file offset / ELF virtual offset `0x3099e`:

```
4d f0 bd fb  ->  00 bf 00 bf
```

This replaces one 32-bit Thumb BL with two 16-bit NOPs. The file mapping was checked
against the executable PT_LOAD segment and `.text`, rather than assuming that a
virtual address is always a file offset. No relocation overlaps these four bytes.
All other bytes, section sizes, program headers, dynamic dependencies, and strings
are identical. No offsets after the edit move, and no new library is needed.

The patch removes this one sleep-warning screen-on request regardless of the
current screen state. It does not create a new global Screen Off rule. When the
screen is already on, the popup call still executes; when it is off, the explicit
wake call is skipped. Actual notification-system behaviour must still be tested.

## 3. Shutdown and popup paths remain intact

The unchanged expiry path is:

```text
0x3090a  SleepTimer::_checkSleepTimer -> _startSleepTimerEvent (0x30708)
0x30752  _startSleepTimerEvent -> _checkSleepTimerRestriction (0x303e4)
0x30790  if unrestricted: -> _requestPowerOff (0x30008)
0x3003e  _requestPowerOff -> ReservationPowerMgr::requestPowerOff (0x7ec5c)
```

The timer's restriction checks, cancellation, popup close logic and requestPowerOff
code are byte-for-byte preserved. The popup function at `0x2fb34` calls the existing
reservation alert implementation, which remains untouched. This avoids inventing
an alternative timer or disabling the reservation daemon and other scheduled work.

Static analysis cannot guarantee that a separate service won't wake the screen
because it receives the popup. If that occurs in the TV test, obtain a fresh Luna
trace before changing anything else. A polling script that turns the screen back
off after it wakes is intentionally not included: it could visibly flash first.

## 4. Why a patched copy plus temporary overlay

Runtime instrumentation would require process attachment, correct ARM ABI/library
compatibility, symbol interception and detach/recovery logic. A four-byte patched
copy is easier to reproduce and audit for this exact executable.

The controller uses `mount --bind` with the payload as source and the existing
executable path as destination. It does not write bytes to that path, edit the
systemd unit or remount a system partition writable. It then requests a restart
of the daemon's verified systemd unit so that a new process loads the overlay.
`tvpowerd` is not the restart target.

The restart is a real change and can reset current timers or disrupt reservation
work. `--timers-off` explicitly acknowledges this. It does not cancel timers itself.
The actual TV systemd unit has not been supplied; preflight detects and verifies
it from the running process, cgroup, ExecStart and MainPID before any restart.
It refuses unknown/multiple processes, a mismatched image/unit, a foreign mount,
RefuseManualStop, OnFailure handlers, and non-none FailureAction/StartLimitAction.

## 5. Rollback and persistence

The first `test` action does not install a boot hook. The overlay is temporary
until a full reboot. Standby/Quick Start+ is not necessarily a full reboot.

Startup validation observes eight consecutive samples of the expected process
image and active unit, within a 30-sample window. It is not a complete functional
test or a permanent crash watchdog. A detected application failure triggers an
attempt to remove this package's persistence, stop the validated agent, unmount
its own overlay, and start the verified original. No forced/lazy unmount is used.

Rollback validates ownership by mount count and inode identity, so a corrupt or
deleted payload does not require a matching patched hash to undo the overlay.
If the original underlying hash is unexpected, or a different overlay owns the
path, it refuses rather than replacing or starting unverified code.

Persistence requires a previous successful trial startup and explicit
`enable --tested --timers-off`. This is the owner's confirmation of the real-TV
result, not machine proof. The optional Homebrew startup hook returns immediately
and runs the checked apply procedure in the background. It disarms itself on a
detected apply failure. A later crash or total webOS boot failure is not guaranteed
to be recoverable by this script.

## 6. Offline validation

46 automated tests passed under **dash** and again under **BusyBox ash**.
The two complete outputs are included under `test-results/`.

The checks cover byte identities, deterministic regeneration, correct call-target
and neighbouring instructions, unchanged popup/expiry/power-off calls, corrupt or
already patched input refusal, staging-only installation, collision checks,
actual-unit identification, unrelated overlay refusal, startup-failure rollback,
corrupted/deleted-payload rollback, stop/unmount failures, idempotent operations,
explicit persistence gating and boot disarming on bad payloads.

Service and mount tests use temporary directories plus mocks for systemctl, mounts
and /proc. They do not exercise the actual TV's kernel, filesystem restrictions,
LG watchdogs, firmware integrity rules, service dependencies or display hardware.
The tests and patch builder are included for inspection and reproduction.

## 7. Acceptance criteria on the actual TV

The deployment is successful only when the owner confirms all of these:

* The patched hash is the RUNNING daemon image, not merely the pathname's image.
* A new sleep timer with Screen Off does not produce a warning-triggered panel wake.
* Audio continues through the warning point.
* The native timer still powers off the TV at expiry.
* Normal remote screen wake works, and the warning is still usable with the panel on.
* After optional persistence, a cold boot reapplies the patch without startup errors.

## Reference documentation

The binary analysis is based on the owner's upload and trace. General deployment
mechanics were checked against these upstream manuals:

```
https://man7.org/linux/man-pages/man8/mount.8.html
https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
```

The manuals describe bind mounts, systemctl show and service restart semantics;
they are not evidence that this modified proprietary daemon is tested on webOS.
