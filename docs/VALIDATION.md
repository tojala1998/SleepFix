# Validation record — SleepFix 0.1.0

## Completed for this build

| Check | Result | Scope |
| --- | --- | --- |
| Controller/recovery suite | 43 passed under `/bin/dash` | Synthetic executables and mocked processes, mounts, namespaces, and systemd. |
| UI/native-bridge suite | 15 passed | Simulated DOM and PalmServiceBridge; fixed commands, status, errors, controls, and remote keys. |
| JavaScript and shell syntax | Passed | Host Node and dash parsers. |
| Official LG CLI package build | Passed | `@webos-tools/cli` 3.2.6, webOS TV profile. |
| Store YAML and release manifest schemas | Passed | Current `webosbrew/apps-repo` schemas retrieved during preparation. |
| Embedded package inspection | Passed | Correct app ID/version, unmodified controller/UI sources, executable hook permissions. |
| Public IPK content inspection | Passed | No ELF executable or original/patched LG firmware binary. |
| Actual patch-byte verification | Passed | On the supplied original executable, the shell patch recipe changed exactly four bytes and produced the previously tested patched hash. |

The LG packager printed its advisory about the newer `requiredACG` field. The
targeted app uses Homebrew Channel's root-public interface; successful package
construction is not a physical-device permission test.

The controller and boot-hook source hashes tested were:

```text
17eee6ee2ed888238fd08071e739621e626d6cd37ab0d1adebeeb7d8827cda1c  app/bin/sleepfixctl.sh
81084f606542d04b1a244b09f0ad29a488df570204b7583875b7ce500b671f0c  app/bin/boot-hook.sh
```

Detailed outputs are in `tests/controller-results.txt`, `tests/ui-results.txt`,
and `tests/package-results.txt`. The release checksum is in `dist/SHA256SUMS`.

## Existing real-TV evidence

Before this GUI was built, Tyler tested the same binary patch on his LG C1:

- The warning period did not wake a screen that was turned off.
- Audio continued until the sleep timer ended.
- The power-state subscription showed `reason: sleepTimer` progressing from
  Screen Off to Active Standby.
- Following a reboot and completion of startup, both the visible and running
  executable hashes matched the patch and the overlay was identified as ours.

That validates the previous shell deployment. It does **not** certify this
new GUI IPK, its remote layout, root-service integration, or uninstall behavior.

## Physical-TV validation still required

Use the normal installer and the remote on the TV. Record the exact model,
firmware, Homebrew Channel version, and `/etc/starfish-release` before the PR.

- [ ] Install the IPK and open it from the TV's launcher.
- [ ] Check text size, visibility, pointer operation, arrow navigation, Enter,
      and Back using the actual remote.
- [ ] Confirm the initial screen only reads state and recognizes the existing
      SSH installation if present.
- [ ] With timers and recordings inactive, press Start. Confirm Running and
      the patched process hash. For the existing installation, verify the
      boot symlink now points into the app.
- [ ] Press Stop. Confirm the original daemon is running and the boot setting
      remains as selected.
- [ ] Switch launch-at-boot off and on while observing that the current
      service is not restarted just to change that preference.
- [ ] Start the fix, set a new two-minute native sleep timer, turn Screen Off,
      and verify continued audio, no warning wake, and normal final shutdown.
- [ ] With launch-at-boot on, fully reboot, allow Homebrew startup to finish,
      and confirm the fix returns automatically.
- [ ] With launch-at-boot off, fully reboot and confirm stock behavior remains.
- [ ] Stop and disable the fix, remove the app, and verify that a subsequent
      full reboot leaves the original service intact.
- [ ] Test a clean app installation without a prior standalone payload, in
      addition to the existing-installation adoption path.
- [ ] Have a human developer review the complete generated source and record
      the reviewer and any corrections before making the store declaration.

The current build has not been executed on an ARM TV in this environment.
BusyBox ash was unavailable, so the new controller was exercised under dash.
Chromium rendering was unavailable in this environment; the UI results above
are DOM/bridge tests, not a screenshot or an emulator run.

## Store submission status

The registration YAML and PR draft are prepared. No public repository, release,
or pull request has been created by this build. Proposed GitHub URLs in the
release manifest are publication targets, not evidence that those resources
currently exist. Public link validation and human/TV review remain required.

## 0.1.1 display regression

The 0.1.0 IPK was visually confirmed on a real LG C1 to render essentially unstyled, with very small browser-default controls and unreadable dark text. The precise console failure was not captured. The 0.1.1 build inlines its CSS and classic JS into the packaged HTML, uses an inline-only policy, and keeps the UI static/offline. Browser-simulated visual checks passed at both 1920×1080 and 1280×720. Physical-TV visual and control testing of 0.1.1 remains pending.
