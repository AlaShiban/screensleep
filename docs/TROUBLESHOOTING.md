# Troubleshooting

## First: read the log

ScreenSleep narrates what it's doing. This answers most questions in one command:

```bash
log show --last 5m --info --predicate 'subsystem == "com.local.screensleep"' --style compact
```

```
dim() starting, 1 display(s), target=0.050000
dimmed, panel now at 0.050
restore() from state=dimmed idle=0.6s
tick idle=22.9s threshold=900.000000s state=idleWatching enabled=true displays=1
```

`--info` is required — those entries are memory-backed and won't appear without it. To
watch live instead: `log stream --predicate 'subsystem == "com.local.screensleep"'`.

> If your shell prints `too many arguments` for `log`, something is shadowing it (zsh
> plugins often define a `log` function). Use `/usr/bin/log` explicitly.

---

## It never dims

**Check the app is running.**

```bash
pgrep -lf ScreenSleep
```

**Check the threshold and that it's enabled.** A `tick` line shows both:

```bash
defaults read com.local.screensleep
```

`enabled = 1`, and `idleMinutes` is what you expect. Remember 15 minutes means 15 minutes
of *no input at all* — anything that moves the cursor resets the clock, including some
Bluetooth peripherals that emit events on their own.

**Watch the idle number climb.** In the `tick` lines, `idle=` should grow by ~10s between
entries while you're away. If it keeps resetting to near zero, something is generating HID
events: a jittery mouse sensor, a drifting trackball, a KVM, a screen-sharing session, or a
utility injecting mouse moves to keep the Mac awake (caffeinate-style tools, some
conferencing apps).

**Check displays aren't zero.** `displays=0` in a tick line, or `dim() aborted: no
controllable displays`, means nothing on this machine exposes a software brightness control
— see *External monitor doesn't dim* below.

## It dims and immediately un-dims

Expected if you touched something after the dim began — that's the wake rule working.
The log makes the difference obvious:

```
dim() starting, 1 display(s), target=0.050000
restore() from state=dimming idle=0.4s      ← input 0.4s ago, i.e. you moved
```

If `idle=` at restore time is *large* (say 900s) and you definitely weren't there, that's a
bug worth reporting — it would mean the idle clock jumped.

Historical note: before the wake rule compared against the dim start, **Dim Now** cancelled
itself within a second, because the click that requested the dim counted as recent input.
Fixed — see [ARCHITECTURE.md](ARCHITECTURE.md#the-wake-rule).

## It restores to the wrong brightness

Use **Undim to 50%** to get back to a usable screen immediately — it ignores the remembered
level entirely.

The remembered level is sampled while you're present. If you changed brightness within the
last few seconds before walking away, that newest value is what comes back. If a display's
level at restore time doesn't match what the app last wrote, the app deliberately leaves it
alone, assuming you took over — so a manual adjustment while dimmed will "stick" and no
restore happens for that display.

## The screen isn't fully black at 0%

That's the panel, not the app. 0% is the minimum backlight level macOS exposes; Apple
laptop displays remain faintly lit. For a truly dark screen, set a short **Display Sleep**
timeout in System Settings › Lock Screen — ScreenSleep's fade runs first, then macOS cuts
the backlight entirely.

## External monitor doesn't dim

Most external displays only accept brightness changes over DDC/CI from their own buttons or
a dedicated utility. ScreenSleep includes an external display only if it can *read* its
brightness through the system frameworks; otherwise it skips it silently. Confirm with the
`displays=N` count in a tick line — if `N` is 1 with a monitor attached, only the built-in
panel is controllable.

**Include External Displays** must also be ticked (it is by default).

## "Can't control display brightness" alert on launch

The private brightness symbols couldn't be resolved on this macOS version — the app tells
you rather than pretending to work. This is the expected failure mode if Apple relocates
`DisplayServicesSetBrightness` / `CoreDisplay_Display_SetUserBrightness` in a future
release. There's no user-side workaround; `Brightness.swift` needs updating.

## Gatekeeper won't open it

The app is ad-hoc signed (`codesign -s -`), not notarized. Right-click the app ›
**Open** › **Open**, once. If it was quarantined by a download:

```bash
xattr -dr com.apple.quarantine /Applications/ScreenSleep.app
```

## Launch at Login fails

`SMAppService` registration wants a stable, properly located bundle. Run
`./build.sh --install` so the app lives in `/Applications`, then tick the item again. You
can always add it by hand in System Settings › General › Login Items.

## Two icons in the menu bar

Two copies are running — typically one from `build/` and one from `/Applications`:

```bash
pgrep -lf ScreenSleep     # shows the paths
pkill -x ScreenSleep      # kill all, then relaunch the one you want
open /Applications/ScreenSleep.app
```

`./build.sh --run` does this for you.

## Start over

```bash
pkill -x ScreenSleep
defaults delete com.local.screensleep
open /Applications/ScreenSleep.app
```

Back to stock: enabled, 15 minutes, dim to black, 3-second fade.
