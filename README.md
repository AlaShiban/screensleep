# ScreenSleep

A macOS menu bar app that dims your display to black after a period of inactivity, and
snaps it back the instant you touch the keyboard or trackpad.

Default: **dim after 15 minutes idle, fading to 0% brightness over 3 seconds.**

## Build & install

```bash
./build.sh                  # builds build/ScreenSleep.app
./build.sh --install --run  # copies to /Applications and launches it
```

Requires the Swift toolchain (Xcode or Command Line Tools). No Xcode project needed.

## Menu

| Item | What it does |
| --- | --- |
| *status line* | Live countdown — "Dims in 12m 30s", or "Screen dimmed" |
| **Auto Dimmer** | Master on/off |
| **Dim Now / Restore Brightness** | Trigger or cancel a dim by hand |
| **Undim to N%** | Jump straight to a fixed level (default 50%), ignoring the remembered brightness — works from any state |
| **Dim After** | 1, 2, 5, 10, 15, 30, 45, 60 minutes, or Custom… (decimals allowed — `0.5` = 30s) |
| **Dim To** | Black (0%), 5%, 10%, or 20% |
| **Undim To** | Level the Undim command targets: 25%, 50%, 75%, 100% |
| **Fade Over** | Instant, 1s, 3s, 5s, 10s |
| **Include External Displays** | Also dim externals that expose a brightness control |
| **Launch at Login** | Registers via `SMAppService` |

Settings persist in `UserDefaults` under `com.local.screensleep`.

## How it works

- **Idle detection** — `CGEventSource.secondsSinceLastEventType(.hidSystemState, …)`, polled
  once a second. This is the same HID idle clock the system uses; it needs no Accessibility
  or Input Monitoring permission, and the app never sees your keystrokes.
- **Brightness** — macOS exposes no public brightness API, so `Brightness.swift` binds
  `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness` (with
  `CoreDisplay_Display_*UserBrightness` as a fallback) at runtime via `dlsym`. Verified
  working on macOS 26 / Apple silicon. These are private symbols, so a future macOS could
  move them — the app shows an alert and exits rather than failing silently if they vanish.
- **Restoring the right level** — the app samples your brightness continuously while you're
  present, so if macOS has already started its own pre-sleep fade when the timer fires, it
  still restores the level *you* chose, not the faded one.
- **Hands off if you take over** — if the brightness at restore time isn't what the app last
  wrote, it assumes you adjusted it yourself and leaves it alone.
- Sleep/wake is handled: the app releases control on wake and re-arms.

## Notes

- 0% is the darkest the panel goes; on Apple laptops the backlight is still faintly on at
  that level. If you want a truly black screen, pair this with a short Display Sleep timeout
  in System Settings › Lock Screen — ScreenSleep's fade will run first.
- The app is ad-hoc signed. Gatekeeper may need one right-click › Open on first launch if
  you move it around.

## Layout

```
Sources/ScreenSleep/
  main.swift          NSApplication bootstrap (.accessory — no Dock icon)
  AppDelegate.swift   Status item, menu, preferences UI, launch-at-login
  Dimmer.swift        Idle polling, snapshot/fade/restore state machine
  Brightness.swift    Private-API brightness get/set
  Preferences.swift   UserDefaults wrapper
Resources/Info.plist  LSUIElement bundle metadata
build.sh              Builds the .app, optional --install / --run
```
