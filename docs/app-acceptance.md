# Runbook: acceptance of the app on the agent (wave 2D-2)

What was verified without running the app: unit tests against a fake agent,
`make build-app`, `make smoke-app`, `codesign --verify`. What only a person at
the Mac can verify is below: starting the agent from the signed bundle, the CPU
budget at idle (Z4, #418, architecture §10) and the helper. Nothing here is
automated, and none of it has been run yet.

**Before you start**

- The installed Swift app has the same bundle id (`com.symaira.cockpit`) and
  shares its `UserDefaults`. Quit it first. Do not run two copies.
- The new bundle has an agent only for arm64 (`Contents/MacOS/symcockpit`,
  `lipo -archs` prints `arm64`).
- Known gaps of this version, so they are not mistaken for defects:
  - **Fan profile and Cool target cannot be set yet.** The agent's register
    describes `fan.profile` and `fan.target` without an argument (wave 2D-1
    makes the setters native). The app reads the register: until the argument
    exists the card says "This Cockpit agent cannot change this fan setting
    yet." and changes nothing. With the argument the change comes back as a
    plan, the card shows it, and only "Confirm" applies it.
  - **No wake re-assert.** After sleep the app no longer re-applies display
    overrides (boost, warmth) or the charge limit; the agent has no command for
    it. Check after waking the Mac: is the boost gone?
  - **AI usage:** the agent's `ai-usage` asks every catalog provider (the app
    keeps only the enabled ones), and the consent-based recorded-history readers
    and the snapshot cache are not available through the agent.
  - **Brightness keys** (opt-in): the key is answered by the agent only if it
    replies within 0.3 s; otherwise macOS handles it.

## 1. Build and sign

```bash
cd <worktree c2-w2d-app>
EXPECTED_TEAM_ID=M4744F3TAA \
CODE_SIGN_IDENTITY="Developer ID Application: Daniel Justus (M4744F3TAA)" \
OUTPUT_DIR=build/app-signed make build-app
codesign --verify --deep --strict --verbose=2 "build/app-signed/Symaira Cockpit.app"
EXPECTED_TEAM_ID=M4744F3TAA ./scripts/smoke-app.sh "build/app-signed/Symaira Cockpit.app"
```

Expected: `valid on disk`, `satisfies its Designated Requirement`, and
`Bundle smoke check passed`. `codesign -dvv "…/Contents/MacOS/symcockpit"` shows
`Identifier=com.symaira.cockpit.symcockpit`, `TeamIdentifier=M4744F3TAA`, and the
helper `Identifier=com.symaira.symtune-helper`.

## 2. The agent refuses a parent that is not the app (safe, no app)

```bash
"build/app-signed/Symaira Cockpit.app/Contents/MacOS/symcockpit" agent --stdio < /dev/null; echo "exit=$?"
```

Expected: a reason on stderr (the parent is a shell, not the signed
`com.symaira.cockpit`) and `exit=3`.

## 3. Start from the signed bundle

```bash
open "build/app-signed/Symaira Cockpit.app"
sleep 5
pgrep -fl "Symaira Cockpit|symcockpit agent --stdio"
ps -o pid,ppid,command -p "$(pgrep -f 'symcockpit agent --stdio')"
```

Expected: the menu-bar item shows CPU/memory within about 5 s (the first CPU
figure needs a second sample); exactly one `symcockpit agent --stdio`, and its
`ppid` is the app's pid. No red "Cockpit agent …" card in the popover or the
window. If the item stays on its icon and the popover shows a card, the card
names the reason (for example "Cockpit agent refused to start" with the
signature message): note the text.

## 4. Z4: idle CPU (≤ 1 %)

With the popover and the window closed, for 60 s:

```bash
APP=$(pgrep -f "Symaira Cockpit.app/Contents/MacOS/SymCockpitApp"); AGENT=$(pgrep -f 'symcockpit agent --stdio')
ps -o pid,cputime,%cpu -p "$APP,$AGENT"; sleep 60; ps -o pid,cputime,%cpu -p "$APP,$AGENT"
```

Expected: the CPU time of app and agent together grows by at most 0.6 s over the
60 s (≤ 1 % of one core); the agent samples `metrics` every 10 s only. Then open
the popover: the agent samples `status`, `brightness.get`, `awake.status` and
`fan.status` every 3 s (the interval from Preferences); close it: the CPU time
flattens again. Record the numbers for #418.

## 5. Diagnosis and restart

1. `pkill -f "symcockpit agent --stdio"` — within a second the popover shows
   "Cockpit agent stopped" ("exited with status 0": the agent ends cleanly on SIGTERM), the readings disappear,
   the menu bar falls back to its icon. No old value stays.
2. Press "Restart agent": readings and menu-bar text return, again with one
   agent process.
3. Quit with ⌘Q: `pgrep -f "symcockpit agent --stdio"` finds nothing after 2 s
   (the agent ends when its stdin closes).

## 6. Actions

- Screen Brightness, Color Warmth, Beyond Normal: take effect at once and the
  slider keeps the value (reversible commands, no confirmation).
- Keep Awake: `pmset -g assertions` lists an assertion by the agent while it is
  on, none after "Stop" or after quitting the app.
- Fan (needs the agent change above): after moving the slider, a block "Nothing
  has changed yet. Confirm to apply it …" with Cancel and Confirm. Cancel: the
  slider snaps back, nothing changed. Confirm: applied, or — without helper
  rights — the hint to turn the privileged helper on, with a button to its
  preferences.

## 7. Helper (only with a Developer-ID build)

Preferences → privileged fan helper → on. System Settings → Login Items asks
for approval. Then:

```bash
launchctl print system/com.symaira.symtune-helper | head
```

Expected: the service is loaded, program
`…/Contents/Library/LaunchServices/com.symaira.symtune-helper`. The helper is
now the Rust `symcockpit-helper` (same identity and plist as before; it serves
only a peer signed as `com.symaira.cockpit` by team `M4744F3TAA`). A fan change
confirmed in the app must then work without a password prompt.

## Way back

1. Quit the app. Turn the helper off in Preferences (this unregisters it) or
   remove it in System Settings → Login Items.
2. `symcockpit fan auto` (any `symcockpit`) returns the fans to the system
   curve. Keep-awake and display overrides were held by the agent process and
   should end with it: check `pmset -g assertions` and the screen.
3. Delete `build/app-signed` and reinstall the previous release of the app
   (the Swift app). No preference was renamed: `com.symaira.symtune` and its
   keys are unchanged, so the previous app reads the same settings.
