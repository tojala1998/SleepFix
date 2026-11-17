# Draft: Add SleepFix

**Preparation draft. Do not submit until the unchecked validation and public
release items below are completed.**

#### Application description

SleepFix prevents a supported LG TV's sleep-timer warning from requesting
Screen On while audio continues with Screen Off enabled. It provides a TV
remote-friendly enable toggle, Start/Stop controls, verified running status,
and an independent launch-at-boot setting.

The initial supported executable was tested on an LG C1 with firmware
03.53.45. Support is gated on a complete SHA-256 match, not the model label.
The app generates the patched copy from the TV's own executable; no LG binary
is distributed. It uses a reversible file bind mount and restores the native
timer service when stopped. Startup uses an app-owned symlink.

#### Submission checklist

- [ ] I have tested this application on a real webOS TV.
- [ ] I confirm that this submission complies with the repository rules.

#### AI-use declaration

- [ ] No AI tools were used.
- [ ] AI tools were used for limited assistance.
- [ ] AI tools were used for research or planning; the application was developed by a human.
- [ ] AI coding agents were used; an experienced developer has reviewed and tested all generated code.
- [ ] The application was produced primarily by AI without meaningful human development or review.
- [x] Other: AI coding agents substantially implemented and reviewed this first build. Human review of the complete application and physical-TV testing of the new IPK are still pending. This is a preparation draft, not a completed submission.

The earlier shell-based patch and reboot application were tested by Tyler on
his TV. That result does not mean the new GUI package has been tested.
Before submission, replace the pending declaration with the accurate final
human review/testing account; never check a review statement merely because
automated tests or an AI review passed.

#### Validation record to complete

- Tester and human code reviewer: **pending**.
- Model: **LG C1**; reported firmware: **03.53.45**.
- Exact `/etc/starfish-release` output: **pending**.
- Clean IPK installation and remote navigation: **pending**.
- Existing standalone installation adoption: **pending**.
- Start/Stop, Screen Off sleep-timer behavior, boot on/off, removal: **pending**.
- Offline source/controller/UI tests: see `docs/VALIDATION.md`.

#### Publication checklist

- [x] Publish the MIT-licensed app source under the submitting account.
- [ ] Publish IPK and matching generated release manifest together.
- [ ] Check that source, icon, manifest, and IPK URLs are public and correct.
- [ ] Add an actual TV screenshot if available.
- [ ] Copy `io.github.tojala1998.sleepfix.yml` into apps-repo `packages/`.
- [ ] Run the store's current validation workflow and submit the completed PR.

Source repository: `https://github.com/tojala1998/SleepFix`.
