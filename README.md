# ScreenSleep

A macOS menu bar app that dims your display to black after a period of inactivity, and
snaps it back the instant you touch the keyboard or trackpad.

Out of the box: **dim after 15 minutes idle, fading to 0% brightness over 3 seconds.**
Everything is configurable from the menu.

It is not a screensaver and not a lock screen — it only moves the backlight, so whatever
was on screen is still there when it comes back, exactly as you left it.

- macOS 13 Ventura or later, Apple silicon or Intel
- No Accessibility, Input Monitoring, or Screen Recording permissions required
- Menu bar only, no Dock icon (`LSUIElement`)

---

## Install

```bash
git clone https://github.com/AlaShiban/screensleep.git
cd screensleep
./build.sh --install --run
```

That builds the app, copies it to `/Applications`, and launches it. Look for the **sun
icon** in the menu bar.

`build.sh` flags:

| Command | Result |
| --- | --- |
| `./build.sh` | Builds `build/ScreenSleep.app` only |
| `./build.sh --install` | Also copies it to `/Applications` (replacing any existing copy) |
| `./build.sh --run` | Also relaunches the app |

Requires the Swift toolchain — full Xcode or just the Command Line Tools
(`xcode-select --install`). There is no Xcode project; it builds with SwiftPM and the
`.app` bundle is assembled by the script.

To start it automatically at login, tick **Launch at Login** in the menu.

---

## Using it

Click the menu bar icon:

| Item | What it does |
| --- | --- |
| *status line* | Live state — "Dims in 12m 30s", "Dimming…", or "Screen dimmed" |
| **Auto Dimmer** | Master on/off. Off cancels any dim in progress. |
| **Dim Now** / **Restore Brightness** | Dim immediately, or cancel a dim and go back to your previous level. A dim you trigger here **holds** — typing won't undo it. |
| **Undim to N%** | Jump straight to a fixed level (default 50%), *ignoring* the remembered brightness. Works from any state — also an escape hatch if a restore ever lands somewhere too dark. |
| **Dim After** | 1, 2, 5, 10, 15, 30, 45, 60 minutes, or **Custom…** — decimals allowed, `0.5` = 30 seconds |
| **Dim To** | How dark to go: Black (0%), 5%, 10%, 20% |
| **Undim To** | Level the **Undim** command targets: 25%, 50%, 75%, 100% |
| **Fade Over** | Fade duration: Instant, 1s, 3s, 5s, 10s |
| **Wake on Activity** | Whether an *automatic* dim ends the moment you touch the keyboard or mouse (on by default). Off means the screen stays dark until you restore it from the menu. |
| **Include External Displays** | Also dim external monitors that expose a software brightness control |
| **Launch at Login** | Registers the app as a login item via `SMAppService` |

**Waking it up.** An *automatic* dim ends on the first keypress, mouse move, or trackpad
touch (specifically: input arriving *after* the dim began). A dim you asked for with **Dim
Now** is different — you chose darkness, so it **holds through typing** and ends only when
you pick *Restore Brightness* or *Undim*. Turn off **Wake on Activity** to make automatic
dims hold the same way.

**Menu bar icon** — `sun.max` while armed and awake, `moon.zzz` while dimmed, and a sun
with a warning badge when Auto Dimmer is switched off.

### Settings

Preferences live in `UserDefaults` under **`com.local.screensleep`** and can also be read
or scripted with `defaults`:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | Bool | `true` | Master switch |
| `idleMinutes` | Double | `15` | Idle minutes before dimming (floor of 5 seconds) |
| `targetBrightness` | Double | `0` | Dim target, `0.0`–`1.0` |
| `undimBrightness` | Double | `0.5` | **Undim** target, `0.0`–`1.0` |
| `fadeSeconds` | Double | `3` | Fade duration; `0` is instant |
| `dimExternal` | Bool | `true` | Include external displays |
| `wakeOnActivity` | Bool | `true` | Automatic dims end on input; hand-triggered dims always hold |

```bash
defaults read com.local.screensleep                    # show current settings
defaults write com.local.screensleep idleMinutes -float 5
```

Values written this way apply from the next poll; the app re-reads preferences each tick.

---

## How it works

- **Idle detection** — `CGEventSource.secondsSinceLastEventType(.hidSystemState, …)`,
  polled once a second. This is the system's own HID idle clock: it reports *how long*
  since the last input, never *what* the input was. The app cannot see your keystrokes,
  which is also why it needs no privacy permissions.
- **Brightness** — macOS ships no public brightness API, so `Brightness.swift` binds
  `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness` at runtime with `dlsym`,
  falling back to `CoreDisplay_Display_{Get,Set}UserBrightness`. See
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#brightness-the-private-api-problem) for why,
  and what happens when Apple eventually moves them.
- **Restoring the right level** — brightness is sampled continuously while you're present,
  so if macOS has already begun its own pre-sleep fade when the timer fires, ScreenSleep
  still restores the level *you* chose rather than the faded one.
- **Hands off if you take over** — if the brightness at restore time isn't what the app
  last wrote, it assumes you adjusted it yourself and leaves your choice alone.
- **Sleep/wake** — control is released on wake and the timer re-arms.

Full design notes, including the state machine and the edge cases each rule exists for:
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

---

## Good to know

- **0% is not truly black.** It's the darkest the panel goes; on Apple laptops the
  backlight is still faintly lit. For a genuinely black screen, pair ScreenSleep with a
  short **Display Sleep** timeout in System Settings › Lock Screen — the fade runs first,
  then macOS cuts the backlight.
- **External displays vary.** Many only respond to their own hardware buttons. Any display
  the app can't both read and write is skipped silently.
- **Ad-hoc signed.** The binary is signed with `-` (no Developer ID), so Gatekeeper may ask
  you to right-click › **Open** the first time.
- **It won't fight you.** Adjust brightness by hand while dimmed and ScreenSleep backs off
  rather than yanking it back.

## Troubleshooting

Start with **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**. The app logs its
tick-by-tick state, so most questions are answered by:

```bash
log show --last 5m --info --predicate 'subsystem == "com.local.screensleep"' --style compact
```

## Uninstall

```bash
pkill -x ScreenSleep
rm -rf /Applications/ScreenSleep.app
defaults delete com.local.screensleep
```

If **Launch at Login** was on, untick it first, or remove the entry in System Settings ›
General › Login Items.

## Repository layout

```
Sources/ScreenSleep/
  main.swift          NSApplication bootstrap (.accessory — no Dock icon)
  AppDelegate.swift   Status item, menu, preferences UI, launch-at-login
  Dimmer.swift        Idle polling, snapshot/fade/restore state machine
  Brightness.swift    Private-API brightness get/set
  Preferences.swift   UserDefaults wrapper
Resources/Info.plist  LSUIElement bundle metadata
build.sh              Builds the .app, optional --install / --run
docs/                 Architecture and troubleshooting notes
```

## License

None yet — all rights reserved by default. Add a `LICENSE` file if you want others to be
able to reuse this.
